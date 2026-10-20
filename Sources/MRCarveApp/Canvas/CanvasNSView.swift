import AppKit
import SwiftUI
import Observation
import MRCarveKit

/// SwiftUI wrapper of the AppKit canvas.
struct CanvasView: NSViewRepresentable {
    let document: DocumentModel
    let editor: EditorState
    let cache: PreviewCache

    func makeNSView(context: Context) -> CanvasNSView {
        let view = CanvasNSView(document: document, editor: editor, cache: cache)
        editor.canvas = view
        return view
    }

    func updateNSView(_ view: CanvasNSView, context: Context) {}
}

/// The selection's frame: the object's own (rotated) box for a single object, the joint bounds for several.
struct SelectionFrame {
    var center: Vec2
    var width: Double
    var height: Double
    /// Degrees, counter-clockwise.
    var rotation: Double
    var isGroup: Bool
    var isLine: Bool

    var transform: CGAffineTransform {
        CGAffineTransform(translationX: center.x, y: center.y).rotated(by: rotation * .pi / 180)
    }

    /// Point at (`ax`, `ay`) ∈ [-1, 1]² of the frame, in field coordinates.
    func point(_ ax: Double, _ ay: Double) -> Vec2 {
        Vec2(ax * width / 2, ay * height / 2).applying(transform)
    }
}

/// A selection handle: scale handles at (`ax`, `ay`) ∈ {-1, 0, 1}², or the rotation knob.
struct Handle: Hashable {
    var ax: Int
    var ay: Int
    var isRotation = false
    static let rotation = Handle(ax: 0, ay: 1, isRotation: true)
}

/// Canvas drawn with CoreGraphics in field coordinates (mm, origin at the field centre, +Y up).
/// The view is not flipped, so view +Y is up as well; `scale` is points per millimetre.
final class CanvasNSView: NSView {
    let document: DocumentModel
    let editor: EditorState
    let cache: PreviewCache
    let settings = AppSettings.shared

    /// Points per millimetre.
    var scale: CGFloat = 8
    /// Offset of the field origin from the view centre, points.
    var pan: CGPoint = .zero
    /// The user zoomed or panned manually; until then the field is fitted on resize.
    var userAdjustedView = false

    enum Interaction {
        case move(start: Vec2, originals: [UUID: Placement], frame: SelectionFrame, dragged: Bool, duplicate: Bool)
        case scale(handle: Handle, originals: [UUID: Placement], frame: SelectionFrame)
        case rotate(startAngle: Double, originals: [UUID: Placement], frame: SelectionFrame)
        case marquee(start: CGPoint, current: CGPoint, base: Set<UUID>)
        case create(tool: CanvasTool, start: Vec2, current: Vec2)
        case pan(start: CGPoint, startPan: CGPoint)
    }

    var interaction: Interaction?
    /// Object under the cursor (hover highlight).
    var hoveredID: UUID?
    var spaceDown = false
    var lastMouseLocation: CGPoint?
    /// Clicked object that should become the sole selection if the click ends without dragging.
    var pendingSoleSelection: UUID?

    init(document: DocumentModel, editor: EditorState, cache: PreviewCache) {
        self.document = document
        self.editor = editor
        self.cache = cache
        super.init(frame: .zero)
        registerForDraggedTypes([.fileURL])
        setAccessibilityRole(.group)
        setAccessibilityLabel(L("Design canvas"))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }
    override var isOpaque: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        document.undoManager = window.undoManager
        window.acceptsMouseMovedEvents = true
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            if !(window.firstResponder is NSTextView) { window.makeFirstResponder(self) }
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect, .cursorUpdate],
                                       owner: self))
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if !userAdjustedView { zoomToFit(animated: false) }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    // MARK: Coordinates

    var originInView: CGPoint { CGPoint(x: bounds.midX + pan.x, y: bounds.midY + pan.y) }

    func toView(_ p: Vec2) -> CGPoint {
        CGPoint(x: originInView.x + CGFloat(p.x) * scale, y: originInView.y + CGFloat(p.y) * scale)
    }

    func toField(_ v: CGPoint) -> Vec2 {
        Vec2(Double((v.x - originInView.x) / scale), Double((v.y - originInView.y) / scale))
    }

    var fieldToView: CGAffineTransform {
        CGAffineTransform(translationX: originInView.x, y: originInView.y).scaledBy(x: scale, y: scale)
    }

    var field: Rect2 { document.machine.field }

    // MARK: Zoom

    static let minScale: CGFloat = 1
    static let maxScale: CGFloat = 400

    /// Points per millimetre at 100 % (physical size on the main display).
    static let physicalScale: CGFloat = {
        guard let screen = NSScreen.main,
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return 72 / 25.4 }
        let mm = CGDisplayScreenSize(CGDirectDisplayID(number.uint32Value))
        return mm.width > 0 ? screen.frame.width / mm.width : 72 / 25.4
    }()

    func zoomToFit(animated: Bool = false) {
        guard bounds.width > 10, bounds.height > 10 else { return }
        let f = field
        let margin: CGFloat = settings.showRulers ? 36 : 24
        let sx = (bounds.width - 2 * margin) / CGFloat(f.width)
        let sy = (bounds.height - 2 * margin) / CGFloat(f.height)
        scale = max(Self.minScale, min(Self.maxScale, min(sx, sy)))
        pan = CGPoint(x: -CGFloat(f.center.x) * scale, y: -CGFloat(f.center.y) * scale)
        viewChanged()
    }

    /// Zooms to the selection (or everything) with some margin.
    func zoomToSelection() {
        let objects = document.selectedObjects.isEmpty ? document.project.objects : document.selectedObjects
        guard let b = objects.filter(\.isVisible).map({ cache.fieldBounds($0) }).reduce(nil, { $0?.union($1) ?? $1 }),
              b.width > 0 || b.height > 0 else { zoomToFit(); return }
        let s = min((bounds.width - 80) / CGFloat(max(b.width, 1)), (bounds.height - 80) / CGFloat(max(b.height, 1)))
        scale = max(Self.minScale, min(Self.maxScale, s))
        pan = CGPoint(x: -CGFloat(b.center.x) * scale, y: -CGFloat(b.center.y) * scale)
        userAdjustedView = true
        viewChanged()
    }

    /// Multiplies the zoom by `factor`, keeping the field point under `anchor` (view coords) fixed.
    func zoom(by factor: CGFloat, around anchor: CGPoint? = nil) {
        let a = anchor ?? CGPoint(x: bounds.midX, y: bounds.midY)
        let p = toField(a)
        scale = max(Self.minScale, min(Self.maxScale, scale * factor))
        pan = CGPoint(x: a.x - bounds.midX - CGFloat(p.x) * scale, y: a.y - bounds.midY - CGFloat(p.y) * scale)
        userAdjustedView = true
        viewChanged()
    }

    /// Zoom so that 1 mm on screen is 1 mm in reality.
    func zoomToActualSize() {
        zoom(by: Self.physicalScale / scale)
    }

    func viewChanged() {
        editor.zoom = Double(scale / Self.physicalScale)
        needsDisplay = true
    }

    // MARK: Selection frame & handles

    func selectionFrame() -> SelectionFrame? {
        let objects = document.selectedObjects.filter(\.isVisible)
        if objects.count == 1, let o = objects.first {
            let p = o.placement
            return SelectionFrame(center: p.center, width: p.width, height: p.height, rotation: p.rotation,
                                  isGroup: false, isLine: o.kind.isLine)
        }
        guard let b = objects.map({ cache.fieldBounds($0) }).reduce(nil, { $0?.union($1) ?? $1 }) else { return nil }
        return SelectionFrame(center: b.center, width: b.width, height: b.height, rotation: 0, isGroup: true, isLine: false)
    }

    /// Handles available for `frame`, depending on its kind and on-screen size.
    func handles(for frame: SelectionFrame) -> [Handle] {
        if document.selectedObjects.allSatisfy(\.isLocked) { return [] }
        var result: [Handle] = []
        if frame.isLine {
            result = [Handle(ax: -1, ay: 0), Handle(ax: 1, ay: 0)]
        } else {
            result = [Handle(ax: -1, ay: -1), Handle(ax: 1, ay: -1), Handle(ax: 1, ay: 1), Handle(ax: -1, ay: 1)]
            let small = CGFloat(min(frame.width, frame.height)) * scale < 24
            if !frame.isGroup && !small {
                result += [Handle(ax: 0, ay: -1), Handle(ax: 1, ay: 0), Handle(ax: 0, ay: 1), Handle(ax: -1, ay: 0)]
            }
        }
        result.append(.rotation)
        return result
    }

    /// View position of a handle.
    func viewPosition(of handle: Handle, in frame: SelectionFrame) -> CGPoint {
        if handle.isRotation {
            let top = toView(frame.point(0, 1))
            let a = frame.rotation * .pi / 180
            return CGPoint(x: top.x - CGFloat(sin(a)) * 24, y: top.y + CGFloat(cos(a)) * 24)
        }
        return toView(frame.point(Double(handle.ax), Double(handle.ay)))
    }

    func hitHandle(at v: CGPoint) -> (Handle, SelectionFrame)? {
        guard let frame = selectionFrame() else { return nil }
        for h in handles(for: frame).reversed() {
            let p = viewPosition(of: h, in: frame)
            if hypot(p.x - v.x, p.y - v.y) <= 7 { return (h, frame) }
        }
        return nil
    }

    /// Topmost visible, unlocked object whose box contains the point (with a few points of slack).
    func hitObject(at v: CGPoint) -> DesignObject? {
        let p = toField(v)
        let slack = Double(4 / scale)
        for o in document.project.objects.reversed() where o.isVisible && !o.isLocked {
            let l = o.placement.localPoint(p)
            if abs(l.x) <= o.placement.width / 2 + slack && abs(l.y) <= o.placement.height / 2 + slack { return o }
        }
        return nil
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        withObservationTracking {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                CanvasRenderer(view: self, ctx: ctx).render()
            }
        } onChange: { [weak self] in
            DispatchQueue.main.async { self?.needsDisplay = true }
        }
    }
}
