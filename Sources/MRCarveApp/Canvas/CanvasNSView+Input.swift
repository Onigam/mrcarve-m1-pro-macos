import AppKit
import MRCarveKit

extension CanvasNSView {
    // MARK: Helpers

    private func snapped(_ p: Vec2) -> Vec2 {
        guard settings.snapToGrid else { return p }
        let s = settings.snapStep
        return Vec2((p.x / s).rounded() * s, (p.y / s).rounded() * s)
    }

    private func placements(of ids: some Sequence<UUID>) -> [UUID: Placement] {
        var result: [UUID: Placement] = [:]
        for id in ids { if let o = document.project.object(id) { result[id] = o.placement } }
        return result
    }

    private var movableSelection: [UUID] {
        document.selectedObjects.filter { !$0.isLocked && $0.isVisible }.map(\.id)
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let v = convert(event.locationInWindow, from: nil)
        lastMouseLocation = v
        pendingSoleSelection = nil
        let flags = event.modifierFlags

        if spaceDown || event.buttonNumber == 2 {
            interaction = .pan(start: v, startPan: pan)
            NSCursor.closedHand.set()
            return
        }

        switch editor.tool {
        case .select:
            if event.clickCount == 2, let o = hitObject(at: v), o.kind.isText {
                document.select([o.id])
                editor.wantsTextFocus = true
                return
            }
            if let hit = hitHandle(at: v) {
                let (handle, frame) = hit
                let originals = placements(of: movableSelection)
                document.beginInteraction()
                if handle.isRotation {
                    let p = toField(v)
                    interaction = .rotate(startAngle: atan2(p.y - frame.center.y, p.x - frame.center.x),
                                          originals: originals, frame: frame)
                } else {
                    interaction = .scale(handle: handle, originals: originals, frame: frame)
                }
                return
            }
            let additive = flags.contains(.shift) || flags.contains(.command)
            if let o = hitObject(at: v) {
                if additive {
                    var s = document.selection
                    if s.contains(o.id) { s.remove(o.id) } else { s.insert(o.id) }
                    document.select(s)
                } else if !document.selection.contains(o.id) {
                    document.select([o.id])
                } else if document.selection.count > 1 {
                    pendingSoleSelection = o.id
                }
                guard let frame = selectionFrame(), document.selection.contains(o.id) else { return }
                interaction = .move(start: toField(v), originals: placements(of: movableSelection), frame: frame,
                                    dragged: false, duplicate: flags.contains(.option))
            } else {
                let base = additive ? document.selection : []
                if !additive { document.clearSelection() }
                interaction = .marquee(start: v, current: v, base: base)
            }
        case .text:
            let p = snapped(toField(v))
            var object = DesignObject.text(L("Text"), at: p, content: lastTextContent(), penID: document.currentPenID)
            object.name = L("Text")
            document.add([object], actionName: L("Add Text"))
            editor.tool = .select
            editor.wantsTextFocus = true
        case .rectangle, .ellipse, .polygon, .line:
            let p = snapped(toField(v))
            interaction = .create(tool: editor.tool, start: p, current: p)
        }
        needsDisplay = true
    }

    /// Font settings of the most recent text object, so new text matches.
    private func lastTextContent() -> TextContent? {
        for o in document.project.objects.reversed() {
            if case .text(let t) = o.kind { return t }
        }
        return TextContent(string: "", fontFamily: FontList.defaultFamily, height: 5)
    }

    override func mouseDragged(with event: NSEvent) {
        let v = convert(event.locationInWindow, from: nil)
        lastMouseLocation = v
        let p = toField(v)
        editor.cursor = p
        let flags = event.modifierFlags
        guard let current = interaction else { return }
        switch current {
        case .pan(let start, let startPan):
            pan = CGPoint(x: startPan.x + v.x - start.x, y: startPan.y + v.y - start.y)
            userAdjustedView = true
            viewChanged()

        case .marquee(let start, _, let base):
            interaction = .marquee(start: start, current: v, base: base)
            let r = CGRect(x: min(start.x, v.x), y: min(start.y, v.y), width: abs(v.x - start.x), height: abs(v.y - start.y))
            let hits = document.project.objects.filter { o in
                o.isVisible && !o.isLocked && cache.fieldBounds(o).cgRect.applying(fieldToView).intersects(r)
            }.map(\.id)
            document.select(base.union(hits))

        case .create(let tool, let start, _):
            interaction = .create(tool: tool, start: start, current: snapped(p))

        case .move(let start, var originals, let frame, let dragged, let duplicate):
            var delta = p - start
            if !dragged {
                // Ignore tiny jitters before a drag really starts.
                if CGFloat(delta.length) * scale < 3 { return }
                pendingSoleSelection = nil
                document.beginInteraction()
                if duplicate {
                    let copies = document.duplicateInPlace()
                    originals = placements(of: copies)
                }
            }
            if flags.contains(.shift) { if abs(delta.x) > abs(delta.y) { delta.y = 0 } else { delta.x = 0 } }
            if settings.snapToGrid { delta = snapped(frame.center + delta) - frame.center }
            document.setPlacements(originals.mapValues { var q = $0; q.center = q.center + delta; return q })
            interaction = .move(start: start, originals: originals, frame: frame, dragged: true, duplicate: duplicate)

        case .scale(let handle, let originals, let frame):
            let placements = scaledPlacements(handle: handle, originals: originals, frame: frame, mouse: p,
                                              keepAspect: flags.contains(.shift) != editor.aspectLocked,
                                              fromCenter: flags.contains(.option))
            document.setPlacements(placements)

        case .rotate(let startAngle, let originals, let frame):
            var delta = (atan2(p.y - frame.center.y, p.x - frame.center.x) - startAngle) * 180 / .pi
            if flags.contains(.shift) {
                if originals.count == 1, let o = originals.values.first {
                    delta = ((o.rotation + delta) / 15).rounded() * 15 - o.rotation
                } else {
                    delta = (delta / 15).rounded() * 15
                }
            }
            let a = delta * .pi / 180
            document.setPlacements(originals.mapValues { o in
                var q = o
                let d = o.center - frame.center
                q.center = frame.center + Vec2(d.x * cos(a) - d.y * sin(a), d.x * sin(a) + d.y * cos(a))
                q.rotation = Placement(width: 0, height: 0, rotation: o.rotation + delta).normalizedRotation
                return q
            })
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let v = convert(event.locationInWindow, from: nil)
        defer {
            interaction = nil
            needsDisplay = true
            updateCursor(at: v)
        }
        guard let current = interaction else { return }
        switch current {
        case .move(_, _, _, let dragged, let duplicate):
            if dragged {
                document.endInteraction(duplicate ? L("Duplicate") : L("Move"))
            } else if let id = pendingSoleSelection {
                document.select([id])
            }
        case .scale:
            document.endInteraction(L("Resize"))
        case .rotate:
            document.endInteraction(L("Rotate"))
        case .create(let tool, let start, let end):
            if var object = creationObject(tool: tool, start: start, current: end, final: true) {
                object.name = object.kindTitle
                document.add([object], actionName: L("Add %@", object.kindTitle))
            }
            editor.tool = .select
        case .marquee, .pan:
            break
        }
        pendingSoleSelection = nil
    }

    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.rightMouseDown(with: event)
    }

    override func otherMouseDown(with event: NSEvent) { mouseDown(with: event) }
    override func otherMouseDragged(with event: NSEvent) { mouseDragged(with: event) }
    override func otherMouseUp(with event: NSEvent) { mouseUp(with: event) }

    override func mouseMoved(with event: NSEvent) {
        let v = convert(event.locationInWindow, from: nil)
        // The window sends mouse-moved events to the first responder even when the pointer is elsewhere.
        guard bounds.contains(v) else {
            if editor.cursor != nil { editor.cursor = nil }
            if hoveredID != nil { hoveredID = nil; needsDisplay = true }
            return
        }
        lastMouseLocation = v
        editor.cursor = toField(v)
        let hovered = editor.tool == .select ? hitObject(at: v)?.id : nil
        if hovered != hoveredID {
            hoveredID = hovered
            needsDisplay = true
        }
        updateCursor(at: v)
    }

    override func mouseExited(with event: NSEvent) {
        editor.cursor = nil
        if hoveredID != nil { hoveredID = nil; needsDisplay = true }
    }

    override func cursorUpdate(with event: NSEvent) {
        updateCursor(at: convert(event.locationInWindow, from: nil))
    }

    func updateCursor(at v: CGPoint) {
        if spaceDown { NSCursor.openHand.set(); return }
        switch editor.tool {
        case .select:
            if let hit = hitHandle(at: v) {
                let (handle, frame) = hit
                if hit.0.isRotation { NSCursor.crosshair.set(); return }
                NSCursor.frameResize(position: resizePosition(handle, frame: frame), directions: .all).set()
            } else {
                NSCursor.arrow.set()
            }
        case .text: NSCursor.iBeam.set()
        default: NSCursor.crosshair.set()
        }
    }

    /// Cursor position for a handle, taking the frame's rotation into account.
    private func resizePosition(_ h: Handle, frame: SelectionFrame) -> NSCursor.FrameResizePosition {
        let angle = atan2(Double(h.ay) * max(frame.height, 1e-6), Double(h.ax) * max(frame.width, 1e-6)) + frame.rotation * .pi / 180
        let octant = Int(((angle * 180 / .pi) + 360 + 22.5).truncatingRemainder(dividingBy: 360) / 45)
        let positions: [NSCursor.FrameResizePosition] = [.right, .topRight, .top, .topLeft, .left, .bottomLeft, .bottom, .bottomRight]
        return positions[max(0, min(7, octant))]
    }

    // MARK: Scale math

    /// New placements when dragging `handle` of `frame` to `mouse` (field coords).
    func scaledPlacements(handle: Handle, originals: [UUID: Placement], frame: SelectionFrame, mouse: Vec2,
                          keepAspect: Bool, fromCenter: Bool) -> [UUID: Placement] {
        let minSize = 0.1
        let m = mouse.applying(frame.transform.inverted())
        let hw = frame.width / 2, hh = frame.height / 2
        var minX = -hw, maxX = hw, minY = -hh, maxY = hh
        let ax = handle.ax, ay = handle.ay
        if fromCenter {
            if ax != 0 { let h = max(abs(m.x), minSize / 2); minX = -h; maxX = h }
            if ay != 0 { let h = max(abs(m.y), minSize / 2); minY = -h; maxY = h }
        } else {
            if ax == 1 { maxX = max(m.x, minX + minSize) }
            if ax == -1 { minX = min(m.x, maxX - minSize) }
            if ay == 1 { maxY = max(m.y, minY + minSize) }
            if ay == -1 { minY = min(m.y, maxY - minSize) }
        }
        var w = maxX - minX, h = maxY - minY
        let uniform = frame.isGroup || (keepAspect && !frame.isLine)
        if uniform, frame.width > 1e-9 || frame.height > 1e-9 {
            let sx = frame.width > 1e-9 ? w / frame.width : 1
            let sy = frame.height > 1e-9 ? h / frame.height : 1
            let s = ax != 0 && ay != 0 ? max(sx, sy) : (ax != 0 ? sx : sy)
            w = frame.width * s
            h = frame.height * s
            if fromCenter {
                minX = -w / 2; maxX = w / 2; minY = -h / 2; maxY = h / 2
            } else {
                switch ax { case 1: maxX = minX + w; case -1: minX = maxX - w; default: minX = -w / 2; maxX = w / 2 }
                switch ay { case 1: maxY = minY + h; case -1: minY = maxY - h; default: minY = -h / 2; maxY = h / 2 }
            }
        }
        let localCenter = Vec2((minX + maxX) / 2, (minY + maxY) / 2)
        if !frame.isGroup, let first = originals.first {
            let (id, original) = (first.key, first.value)
            var p = original
            p.center = localCenter.applying(frame.transform)
            p.width = w
            if !frame.isLine { p.height = h }
            return [id: p]
        }
        // Group: uniform scale about the fixed point.
        let s = frame.width > 1e-9 ? w / frame.width : (frame.height > 1e-9 ? h / frame.height : 1)
        let anchorLocal = fromCenter ? Vec2.zero : Vec2(ax == 0 ? 0 : -Double(ax) * hw, ay == 0 ? 0 : -Double(ay) * hh)
        let anchor = anchorLocal.applying(frame.transform)
        return originals.mapValues { o in
            var q = o
            q.center = anchor + (o.center - anchor) * s
            q.width = o.width * s
            q.height = o.height * s
            return q
        }
    }

    // MARK: Creation

    /// The object the creation tool would make for a drag from `start` to `current`.
    /// With `final`, a click without drag yields a default-sized object.
    func creationObject(tool: CanvasTool, start: Vec2, current: Vec2, final: Bool) -> DesignObject? {
        let flags = NSEvent.modifierFlags
        var d = current - start
        let tiny = CGFloat(d.length) * scale < 4
        if tiny && !final { return nil }
        let penID = document.currentPenID
        if tool == .line {
            if tiny { return DesignObject.line(from: start - Vec2(10, 0), to: start + Vec2(10, 0), penID: penID) }
            if flags.contains(.shift) {
                let a = (atan2(d.y, d.x) / (.pi / 4)).rounded() * (.pi / 4)
                d = Vec2(cos(a), sin(a)) * d.length
            }
            return DesignObject.line(from: start, to: start + d, penID: penID)
        }
        var rect: Rect2
        if tiny {
            rect = Rect2(minX: start.x - 10, minY: start.y - 10, maxX: start.x + 10, maxY: start.y + 10)
        } else {
            if flags.contains(.shift) {
                let s = max(abs(d.x), abs(d.y))
                d = Vec2(d.x < 0 ? -s : s, d.y < 0 ? -s : s)
            }
            if flags.contains(.option) {
                rect = Rect2(minX: start.x - abs(d.x), minY: start.y - abs(d.y), maxX: start.x + abs(d.x), maxY: start.y + abs(d.y))
            } else {
                rect = Rect2(enclosing: [start, start + d])!
            }
        }
        switch tool {
        case .rectangle: return DesignObject.rectangle(rect, penID: penID)
        case .ellipse: return DesignObject.ellipse(rect, penID: penID)
        case .polygon: return DesignObject.polygon(rect, sides: 6, penID: penID)
        default: return nil
        }
    }

    // MARK: Scroll & gestures

    override func scrollWheel(with event: NSEvent) {
        let v = convert(event.locationInWindow, from: nil)
        if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.option) || !event.hasPreciseScrollingDeltas {
            let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY * 0.01 : event.scrollingDeltaY * 0.1
            zoom(by: exp(delta), around: v)
        } else {
            pan.x += event.scrollingDeltaX
            pan.y -= event.scrollingDeltaY
            userAdjustedView = true
            viewChanged()
        }
    }

    override func magnify(with event: NSEvent) {
        zoom(by: 1 + event.magnification, around: convert(event.locationInWindow, from: nil))
    }

    override func smartMagnify(with event: NSEvent) {
        if editor.zoom < 2 {
            zoom(by: 2.5, around: convert(event.locationInWindow, from: nil))
        } else {
            userAdjustedView = false
            zoomToFit()
        }
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let step = event.modifierFlags.contains(.shift) ? 1.0 : 0.1
        switch event.keyCode {
        case 123: document.nudge(Vec2(-step, 0)); return   // ←
        case 124: document.nudge(Vec2(step, 0)); return    // →
        case 125: document.nudge(Vec2(0, -step)); return   // ↓
        case 126: document.nudge(Vec2(0, step)); return    // ↑
        case 51, 117: document.deleteSelection(); return   // ⌫, ⌦
        case 53:                                           // Esc
            if interaction != nil {
                if document.isInteracting { document.cancelInteraction() }
                interaction = nil
                needsDisplay = true
            } else if editor.tool != .select {
                editor.tool = .select
            } else {
                document.clearSelection()
            }
            return
        case 36, 76:                                       // Return: edit text
            if document.singleSelection?.kind.isText == true { editor.wantsTextFocus = true; return }
        case 49:                                           // Space: hand tool while held
            if !event.isARepeat { spaceDown = true; NSCursor.openHand.set() }
            return
        default: break
        }
        if flags.isEmpty, let c = event.charactersIgnoringModifiers?.lowercased().first,
           let tool = CanvasTool.allCases.first(where: { $0.key == c }) {
            editor.tool = tool
            return
        }
        super.keyDown(with: event)
    }

    override func keyUp(with event: NSEvent) {
        if event.keyCode == 49 {
            spaceDown = false
            if let v = lastMouseLocation { updateCursor(at: v) }
            return
        }
        super.keyUp(with: event)
    }

    // MARK: Responder actions (Edit menu)

    @objc override func selectAll(_ sender: Any?) { document.selectAll() }
    @objc func delete(_ sender: Any?) { document.deleteSelection() }
    @objc func copy(_ sender: Any?) { document.copySelection() }
    @objc func cut(_ sender: Any?) { document.cutSelection() }
    @objc func paste(_ sender: Any?) { document.paste() }

    // MARK: Context menu

    override func menu(for event: NSEvent) -> NSMenu? {
        let v = convert(event.locationInWindow, from: nil)
        if let o = hitObject(at: v), !document.selection.contains(o.id) { document.select([o.id]) }
        let menu = NSMenu()
        if document.selection.isEmpty {
            menu.addItem(withTitle: L("Paste"), action: #selector(paste(_:)), keyEquivalent: "")
            menu.addItem(.separator())
            menu.addItem(withTitle: L("Zoom to Fit"), action: #selector(menuZoomToFit), keyEquivalent: "")
            return menu
        }
        menu.addItem(withTitle: L("Cut"), action: #selector(cut(_:)), keyEquivalent: "")
        menu.addItem(withTitle: L("Copy"), action: #selector(copy(_:)), keyEquivalent: "")
        menu.addItem(withTitle: L("Duplicate"), action: #selector(menuDuplicate), keyEquivalent: "")
        menu.addItem(withTitle: L("Delete"), action: #selector(delete(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: L("Center in Field"), action: #selector(menuCenter), keyEquivalent: "")
        let order = NSMenu()
        order.addItem(withTitle: L("Mark First"), action: #selector(menuOrderFirst), keyEquivalent: "")
        order.addItem(withTitle: L("Mark Earlier"), action: #selector(menuOrderEarlier), keyEquivalent: "")
        order.addItem(withTitle: L("Mark Later"), action: #selector(menuOrderLater), keyEquivalent: "")
        order.addItem(withTitle: L("Mark Last"), action: #selector(menuOrderLast), keyEquivalent: "")
        let orderItem = menu.addItem(withTitle: L("Mark Order"), action: nil, keyEquivalent: "")
        orderItem.submenu = order
        let pens = NSMenu()
        for pen in document.project.pens {
            let item = pens.addItem(withTitle: pen.displayName, action: #selector(menuSetPen(_:)), keyEquivalent: "")
            item.tag = pen.id
            item.image = PenColor.swatchImage(pen.colorRGB)
            item.state = document.selectedObjects.allSatisfy { $0.penID == pen.id } ? .on : .off
        }
        let penItem = menu.addItem(withTitle: L("Pen"), action: nil, keyEquivalent: "")
        penItem.submenu = pens
        menu.addItem(.separator())
        menu.addItem(withTitle: L("Hide"), action: #selector(menuHide), keyEquivalent: "")
        menu.addItem(withTitle: L("Lock"), action: #selector(menuLock), keyEquivalent: "")
        return menu
    }

    @objc private func menuZoomToFit() { userAdjustedView = false; zoomToFit() }
    @objc private func menuDuplicate() { document.duplicateSelection() }
    @objc private func menuCenter() { document.centerSelectionInField() }
    @objc private func menuOrderFirst() { document.reorderSelection(.first) }
    @objc private func menuOrderEarlier() { document.reorderSelection(.earlier) }
    @objc private func menuOrderLater() { document.reorderSelection(.later) }
    @objc private func menuOrderLast() { document.reorderSelection(.last) }
    @objc private func menuSetPen(_ sender: NSMenuItem) { document.setPen(sender.tag) }
    @objc private func menuHide() {
        document.updateObjects(document.selection, L("Hide")) { $0.isVisible = false }
        document.clearSelection()
    }
    @objc private func menuLock() { document.updateObjects(document.selection, L("Lock")) { $0.isLocked = true } }

    // MARK: Drag & drop

    private func importableURLs(_ info: NSDraggingInfo) -> [URL] {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                       options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        let allowed = Set(DocumentModel.importableExtensions)
        return urls.filter { allowed.contains($0.pathExtension.lowercased()) }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        importableURLs(sender).isEmpty ? [] : .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        importableURLs(sender).isEmpty ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = importableURLs(sender)
        guard !urls.isEmpty else { return false }
        document.importFiles(urls, at: toField(convert(sender.draggingLocation, from: nil)))
        return true
    }
}

extension CanvasNSView: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)), #selector(cut(_:)), #selector(delete(_:)): !document.selection.isEmpty
        case #selector(paste(_:)): document.canPaste
        case #selector(selectAll(_:)): !document.project.objects.isEmpty
        default: true
        }
    }
}
