import AppKit
import MRCarveKit

/// Canvas colours (dynamic, light/dark).
enum CanvasColors {
    static let background = NSColor.dynamic(light: NSColor(white: 0.90, alpha: 1), dark: NSColor(white: 0.09, alpha: 1))
    static let field = NSColor.dynamic(light: .white, dark: NSColor(white: 0.15, alpha: 1))
    static let fieldBorder = NSColor.dynamic(light: NSColor(white: 0, alpha: 0.25), dark: NSColor(white: 1, alpha: 0.22))
    static let gridMinor = NSColor.dynamic(light: NSColor(white: 0, alpha: 0.05), dark: NSColor(white: 1, alpha: 0.05))
    static let gridMid = NSColor.dynamic(light: NSColor(white: 0, alpha: 0.09), dark: NSColor(white: 1, alpha: 0.09))
    static let gridMajor = NSColor.dynamic(light: NSColor(white: 0, alpha: 0.15), dark: NSColor(white: 1, alpha: 0.14))
    static let warning = NSColor.systemRed
    static let redLight = NSColor(srgbRed: 1, green: 0.15, blue: 0.1, alpha: 1)
}

/// Draws one frame of the canvas. Reads all state through the view so that observation tracking sees it.
@MainActor
struct CanvasRenderer {
    let view: CanvasNSView
    let ctx: CGContext

    private var document: DocumentModel { view.document }
    private var scale: CGFloat { view.scale }
    private var isDark: Bool { view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }

    func render() {
        let project = document.project
        _ = view.cache.revision  // redraw when background previews arrive
        let settings = view.settings
        let field = document.machine.field

        ctx.setFillColor(CanvasColors.background.cgColor)
        ctx.fill(view.bounds)

        drawField(field, showGrid: settings.showGrid, rulers: settings.showRulers)

        let device = DeviceViewModel.shared
        let pens = Dictionary(project.pens.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for object in project.objects where object.isVisible {
            drawObject(object, pens: pens, field: field, showFill: settings.showFillPreview)
        }

        if let hovered = view.hoveredID, !document.selection.contains(hovered),
           let o = project.object(hovered), o.isVisible, view.interaction == nil {
            strokeBox(o.placement, color: NSColor.controlAccentColor.withAlphaComponent(0.6), width: 1)
        }

        drawSelection()
        drawInteraction()

        if device.isFraming, device.ownerID == document.id, let b = device.framingBounds {
            drawFraming(b)
        }
    }

    // MARK: Field & grid

    private func drawField(_ field: Rect2, showGrid: Bool, rulers: Bool) {
        let rect = field.cgRect.applying(view.fieldToView)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -1), blur: 6, color: NSColor.black.withAlphaComponent(isDark ? 0.5 : 0.18).cgColor)
        ctx.setFillColor(CanvasColors.field.cgColor)
        ctx.fill(rect)
        ctx.restoreGState()

        ctx.saveGState()
        ctx.clip(to: rect)
        if showGrid {
            if scale * 1 >= 6 { drawGrid(field, step: 1, color: CanvasColors.gridMinor) }
            if scale * 5 >= 6 { drawGrid(field, step: 5, color: CanvasColors.gridMid) }
            drawGrid(field, step: 10, color: CanvasColors.gridMajor)
        }
        // Centre crosshair.
        let o = view.toView(.zero)
        let arm: CGFloat = max(10, min(40, scale * 4))
        ctx.setStrokeColor(NSColor.controlAccentColor.withAlphaComponent(0.55).cgColor)
        ctx.setLineWidth(1)
        ctx.strokeLineSegments(between: [CGPoint(x: o.x - arm, y: o.y), CGPoint(x: o.x + arm, y: o.y),
                                         CGPoint(x: o.x, y: o.y - arm), CGPoint(x: o.x, y: o.y + arm)])
        ctx.strokeEllipse(in: CGRect(x: o.x - 3, y: o.y - 3, width: 6, height: 6))
        ctx.restoreGState()

        ctx.setStrokeColor(CanvasColors.fieldBorder.cgColor)
        ctx.setLineWidth(1)
        ctx.stroke(rect.insetBy(dx: -0.5, dy: -0.5))

        if rulers { drawRulerLabels(field, rect: rect) }
    }

    private func drawGrid(_ field: Rect2, step: Double, color: NSColor) {
        var segments: [CGPoint] = []
        var x = (field.minX / step).rounded(.up) * step
        while x <= field.maxX + 1e-9 {
            segments.append(view.toView(Vec2(x, field.minY)))
            segments.append(view.toView(Vec2(x, field.maxY)))
            x += step
        }
        var y = (field.minY / step).rounded(.up) * step
        while y <= field.maxY + 1e-9 {
            segments.append(view.toView(Vec2(field.minX, y)))
            segments.append(view.toView(Vec2(field.maxX, y)))
            y += step
        }
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(1)
        ctx.strokeLineSegments(between: segments)
    }

    private func drawRulerLabels(_ field: Rect2, rect: CGRect) {
        let step: Double = scale * 10 >= 28 ? 10 : (scale * 20 >= 28 ? 20 : 35)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        var v = (field.minX / step).rounded(.up) * step
        while v <= field.maxX + 1e-9 {
            let s = NSAttributedString(string: Format.number(v, digits: 0), attributes: attrs)
            let p = view.toView(Vec2(v, field.minY))
            s.draw(at: CGPoint(x: p.x - s.size().width / 2, y: rect.minY - s.size().height - 3))
            v += step
        }
        v = (field.minY / step).rounded(.up) * step
        while v <= field.maxY + 1e-9 {
            let s = NSAttributedString(string: Format.number(v, digits: 0), attributes: attrs)
            let p = view.toView(Vec2(field.minX, v))
            s.draw(at: CGPoint(x: rect.minX - s.size().width - 4, y: p.y - s.size().height / 2))
            v += step
        }
    }

    // MARK: Objects

    private func penColor(_ pens: [Int: PenParameters], _ id: Int) -> NSColor {
        PenColor.display(pens[id]?.colorRGB ?? PenParameters(id: id).colorRGB, dark: isDark)
    }

    private func path(_ polylines: [Polyline], transform: CGAffineTransform) -> CGPath {
        let path = CGMutablePath()
        for pl in polylines where pl.points.count > 1 {
            path.addLines(between: pl.points.map(\.cgPoint), transform: transform)
            if pl.isClosed { path.closeSubpath() }
        }
        return path
    }

    private func drawObject(_ object: DesignObject, pens: [Int: PenParameters], field: Rect2, showFill: Bool) {
        let cache = view.cache
        let toView = object.placement.transform.concatenating(view.fieldToView)
        let pen = pens[object.penID]
        let penEnabled = pen?.isEnabled ?? true
        let color = penColor(pens, object.penID).withAlphaComponent(penEnabled ? 1 : 0.3)

        if case .image(let content) = object.kind {
            drawImage(object, content: content, transform: toView, showPreview: showFill)
        }

        // Hatch preview.
        if showFill, let fill = object.fill, object.kind.supportsFill {
            for (index, layer) in fill.layers.prefix(FillSettings.maxLayers).enumerated() where layer.isEnabled {
                guard let lines = cache.localHatch(object, layerIndex: index, layer: layer), !lines.isEmpty else { continue }
                let layerPen = layer.penID ?? object.penID
                let enabled = pens[layerPen]?.isEnabled ?? true
                ctx.addPath(path(lines, transform: toView))
                ctx.setStrokeColor(penColor(pens, layerPen).withAlphaComponent(enabled ? 0.75 : 0.2).cgColor)
                ctx.setLineWidth(scale > 30 ? 0.75 : 0.5)
                ctx.strokePath()
            }
        }

        // Outline.
        let outlines = cache.localOutlines(object)
        if object.kind.isImage {
            ctx.addPath(path(outlines, transform: toView))
            ctx.setStrokeColor(NSColor.secondaryLabelColor.withAlphaComponent(0.5).cgColor)
            ctx.setLineWidth(0.75)
            ctx.setLineDash(phase: 0, lengths: [3, 3])
            ctx.strokePath()
            ctx.setLineDash(phase: 0, lengths: [])
        } else if outlines.isEmpty, case .text(let text) = object.kind {
            drawTextPlaceholder(object, text: text, transform: toView, color: color)
        } else {
            let marksOutline = object.fill?.markOutline ?? true
            ctx.addPath(path(outlines, transform: toView))
            ctx.setStrokeColor(color.withAlphaComponent(marksOutline ? color.alphaComponent : 0.35).cgColor)
            ctx.setLineWidth(marksOutline ? 1.25 : 0.75)
            if !marksOutline { ctx.setLineDash(phase: 0, lengths: [2, 2]) }
            ctx.setLineJoin(.round)
            ctx.strokePath()
            ctx.setLineDash(phase: 0, lengths: [])
        }

        // Out-of-field warning.
        let b = cache.fieldBounds(object)
        if b.minX < field.minX - 1e-6 || b.minY < field.minY - 1e-6 || b.maxX > field.maxX + 1e-6 || b.maxY > field.maxY + 1e-6 {
            let r = b.cgRect.applying(view.fieldToView).insetBy(dx: -2, dy: -2)
            ctx.setFillColor(CanvasColors.warning.withAlphaComponent(0.08).cgColor)
            ctx.fill(r)
            ctx.setStrokeColor(CanvasColors.warning.cgColor)
            ctx.setLineWidth(1)
            ctx.setLineDash(phase: 0, lengths: [4, 3])
            ctx.stroke(r)
            ctx.setLineDash(phase: 0, lengths: [])
        }
    }

    private func drawImage(_ object: DesignObject, content: ImageContent, transform: CGAffineTransform, showPreview: Bool) {
        let box = object.placement.localBox.cgRect
        ctx.saveGState()
        ctx.concatenate(transform)
        ctx.interpolationQuality = scale > 20 ? .none : .medium
        var drewPreview = false
        if showPreview {
            let preview = view.cache.rasterPreview(object)
            if let image = preview.image {
                ctx.draw(image, in: box)
                drewPreview = true
            }
        }
        if !drewPreview, let image = ImageThumbnailCache.shared.image(for: object.id, content: content) {
            ctx.setAlpha(showPreview ? 0.45 : 0.85)
            ctx.draw(image, in: box)
        }
        ctx.restoreGState()
    }

    private func drawTextPlaceholder(_ object: DesignObject, text: TextContent, transform: CGAffineTransform, color: NSColor) {
        // Shown when glyph outlines are unavailable (font missing, or engine not ready).
        let box = object.placement.localBox.cgRect
        ctx.saveGState()
        ctx.addPath(CGPath(rect: box, transform: [transform]))
        ctx.setStrokeColor(color.withAlphaComponent(0.6).cgColor)
        ctx.setLineDash(phase: 0, lengths: [3, 2])
        ctx.setLineWidth(1)
        ctx.strokePath()
        ctx.concatenate(transform)
        let fontSize = max(1, CGFloat(text.height))
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont(name: text.fontFamily, size: fontSize) ?? NSFont.systemFont(ofSize: fontSize),
            .foregroundColor: color.withAlphaComponent(0.7),
        ]
        let s = NSAttributedString(string: text.string, attributes: attrs)
        let size = s.size()
        let sx = size.width > 0 ? box.width / size.width : 1
        let sy = size.height > 0 ? box.height / size.height : 1
        ctx.translateBy(x: box.minX, y: box.minY)
        ctx.scaleBy(x: sx, y: sy)
        let gc = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = gc
        s.draw(at: .zero)
        NSGraphicsContext.restoreGraphicsState()
        ctx.restoreGState()
    }

    private func strokeBox(_ placement: Placement, color: NSColor, width: CGFloat) {
        let pts = placement.corners.map { view.toView($0) }
        ctx.addLines(between: pts)
        ctx.closePath()
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(width)
        ctx.strokePath()
    }

    // MARK: Selection

    private func drawSelection() {
        guard let frame = view.selectionFrame() else { return }
        let accent = NSColor.controlAccentColor
        let corners = [frame.point(-1, -1), frame.point(1, -1), frame.point(1, 1), frame.point(-1, 1)].map { view.toView($0) }
        ctx.addLines(between: corners)
        ctx.closePath()
        ctx.setStrokeColor(accent.cgColor)
        ctx.setLineWidth(1)
        if frame.isGroup { ctx.setLineDash(phase: 0, lengths: [4, 3]) }
        ctx.strokePath()
        ctx.setLineDash(phase: 0, lengths: [])

        // Individual boxes inside a group selection.
        if frame.isGroup {
            for o in document.selectedObjects where o.isVisible {
                strokeBox(o.placement, color: accent.withAlphaComponent(0.45), width: 0.75)
            }
        }

        let handles = view.handles(for: frame)
        guard !handles.isEmpty else { return }
        if handles.contains(.rotation) {
            let knob = view.viewPosition(of: .rotation, in: frame)
            let top = view.toView(frame.point(0, 1))
            ctx.setStrokeColor(accent.cgColor)
            ctx.strokeLineSegments(between: [top, knob])
            let r = CGRect(x: knob.x - 4.5, y: knob.y - 4.5, width: 9, height: 9)
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fillEllipse(in: r)
            ctx.strokeEllipse(in: r)
        }
        for h in handles where !h.isRotation {
            let p = view.viewPosition(of: h, in: frame)
            let r = CGRect(x: p.x - 3.5, y: p.y - 3.5, width: 7, height: 7)
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fill(r)
            ctx.setStrokeColor(accent.cgColor)
            ctx.setLineWidth(1)
            ctx.stroke(r)
        }
    }

    // MARK: Interaction overlays

    private func drawInteraction() {
        guard let interaction = view.interaction else { return }
        let accent = NSColor.controlAccentColor
        switch interaction {
        case .marquee(let start, let current, _):
            let r = CGRect(x: min(start.x, current.x), y: min(start.y, current.y),
                           width: abs(current.x - start.x), height: abs(current.y - start.y))
            ctx.setFillColor(accent.withAlphaComponent(0.1).cgColor)
            ctx.fill(r)
            ctx.setStrokeColor(accent.withAlphaComponent(0.8).cgColor)
            ctx.setLineWidth(1)
            ctx.stroke(r)
        case .create(let tool, let start, let current):
            guard let object = view.creationObject(tool: tool, start: start, current: current, final: false) else { return }
            let pts = object.outlines(tolerance: 0.05)
            ctx.addPath(path(pts, transform: view.fieldToView))
            ctx.setStrokeColor(accent.cgColor)
            ctx.setLineWidth(1.25)
            ctx.setLineDash(phase: 0, lengths: [5, 3])
            ctx.strokePath()
            ctx.setLineDash(phase: 0, lengths: [])
            let units = view.settings.units
            let label = tool == .line
                ? units.format(object.placement.width, digits: 1) + "  " + Format.number(object.placement.rotation, digits: 1) + "°"
                : units.format(object.placement.width, digits: 1) + " × " + units.format(object.placement.height, digits: 1)
            drawBadge(label, near: view.toView(current))
        case .scale(_, _, _):
            if let frame = view.selectionFrame() {
                let units = view.settings.units
                drawBadge(units.format(frame.width, digits: 2) + " × " + units.format(frame.height, digits: 2),
                          near: view.lastMouseLocation ?? view.toView(frame.center))
            }
        case .rotate:
            if let o = document.singleSelection {
                drawBadge(Format.number(o.placement.normalizedRotation, digits: 1) + "°",
                          near: view.lastMouseLocation ?? view.toView(o.placement.center))
            }
        case .move(_, _, let frame, let dragged, _):
            if dragged, let now = view.selectionFrame() {
                let units = view.settings.units
                let d = now.center - frame.center
                drawBadge("Δ " + units.format(d.x, digits: 2) + ", " + units.format(d.y, digits: 2),
                          near: view.lastMouseLocation ?? view.toView(now.center))
            }
        case .pan:
            break
        }
    }

    private func drawBadge(_ text: String, near p: CGPoint) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let s = NSAttributedString(string: text, attributes: attrs)
        let size = s.size()
        var r = CGRect(x: p.x + 14, y: p.y - size.height - 14, width: size.width + 12, height: size.height + 6)
        if r.maxX > view.bounds.maxX - 4 { r.origin.x = p.x - r.width - 14 }
        if r.minY < view.bounds.minY + 4 { r.origin.y = p.y + 14 }
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: 5, cornerHeight: 5, transform: nil))
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.75).cgColor)
        ctx.fillPath()
        s.draw(at: CGPoint(x: r.minX + 6, y: r.minY + 3))
    }

    private func drawFraming(_ bounds: Rect2) {
        let r = bounds.cgRect.applying(view.fieldToView).insetBy(dx: -1, dy: -1)
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 8, color: CanvasColors.redLight.withAlphaComponent(0.9).cgColor)
        ctx.setStrokeColor(CanvasColors.redLight.cgColor)
        ctx.setLineWidth(1.5)
        ctx.setLineDash(phase: 0, lengths: [6, 4])
        ctx.stroke(r)
        ctx.restoreGState()
    }
}

/// Decoded images for drawing (decoding PNG data every frame would be slow).
@MainActor
final class ImageThumbnailCache {
    static let shared = ImageThumbnailCache()
    private var images: [UUID: (count: Int, image: CGImage)] = [:]

    func image(for id: UUID, content: ImageContent) -> CGImage? {
        if let hit = images[id], hit.count == content.pngData.count { return hit.image }
        guard let image = content.cgImage else { return nil }
        images[id] = (content.pngData.count, image)
        return image
    }
}
