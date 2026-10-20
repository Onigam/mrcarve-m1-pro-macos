#if DEBUG
import AppKit
import MRCarveKit

/// In-app checks of the editing pipeline (undo/redo, coalescing, interactions, import), run with
/// `-MRCarveDebugAction selftest` in debug builds. Results go to the unified log ("MRCSELFTEST").
@MainActor
enum DebugSelfTest {
    static func run(_ doc: DocumentModel) {
        var failures: [String] = []
        func check(_ ok: Bool, _ what: String) { if !ok { failures.append(what) } }
        guard let undo = doc.undoManager, let first = doc.project.objects.first else {
            NSLog("MRCSELFTEST FAIL: no undo manager or no objects"); return
        }
        let original = doc.project
        let start = first.placement.center
        let window = NSApp.windows.first { DocumentRegistry.shared.document(for: $0) === doc }
        check(window?.delegate is WindowCloseGuard, "close guard installed")

        doc.select([first.id])
        doc.nudge(Vec2(1, 0)); doc.nudge(Vec2(1, 0)); doc.nudge(Vec2(0, 1))
        check(doc.project.object(first.id)?.placement.center == start + Vec2(2, 1), "nudge moves")
        undo.undo()
        check(doc.project == original, "coalesced nudges undo in one step")
        undo.redo()
        check(doc.project.object(first.id)?.placement.center == start + Vec2(2, 1), "redo nudges")
        undo.undo()

        doc.duplicateSelection()
        check(doc.project.objects.count == original.objects.count + 1, "duplicate adds")
        undo.undo()
        check(doc.project == original, "undo duplicate")

        doc.beginInteraction()
        var p = first.placement
        for i in 1...5 { p.rotation = Double(i) * 10; doc.setPlacements([first.id: p]) }
        doc.endInteraction("Rotate")
        check(doc.project.object(first.id)?.placement.rotation == 50, "interaction applies")
        undo.undo()
        check(doc.project == original, "interaction is one undo step")

        doc.perform("Pen") { $0.updatePen(0) { $0.markSpeed = 1234 } }
        check(doc.project.pen(0).markSpeed == 1234, "pen edit")
        undo.undo()
        check(doc.project.pen(0).markSpeed == original.pen(0).markSpeed, "undo pen edit")

        doc.copySelection()
        doc.paste()
        check(doc.project.objects.count == original.objects.count + 1, "copy/paste adds")
        undo.undo()

        doc.reorderSelection(.last)
        check(doc.project.objects.last?.id == first.id, "reorder to last")
        undo.undo()
        check(doc.project.objects.first?.id == first.id, "undo reorder")

        // Import an SVG and a PNG written to a temporary folder.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mrcarve-selftest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let svg = dir.appendingPathComponent("square.svg")
        try? #"<svg xmlns="http://www.w3.org/2000/svg" width="20mm" height="10mm" viewBox="0 0 20 10"><rect x="0" y="0" width="20" height="10"/><circle cx="10" cy="5" r="3"/></svg>"#
            .write(to: svg, atomically: true, encoding: .utf8)
        let png = dir.appendingPathComponent("dot.png")
        if let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 32, bitsPerSample: 8, samplesPerPixel: 4,
                                      hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
           let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: png)
        }
        let before = doc.project.objects.count
        doc.importFiles([svg, png], at: Vec2(5, 5))
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            let added = doc.project.objects.dropFirst(before)
            check(added.count == 2, "import adds 2 objects (got \(added.count), alert: \(doc.alert?.message ?? "none"))")
            if let v = added.first(where: { if case .vector = $0.kind { true } else { false } }) {
                check(abs(v.placement.width - 20) < 0.01 && abs(v.placement.height - 10) < 0.01,
                      "svg imported at 20×10 mm (got \(v.placement.width)×\(v.placement.height))")
            } else {
                failures.append("svg imported as vector")
            }
            check(added.contains { $0.kind.isImage }, "png imported as image")
            undo.undo()
            check(doc.project.objects.count == before, "undo import")
            check(window?.isDocumentEdited == true, "window shows edited state")
            check(window?.delegate is WindowCloseGuard, "close guard still installed")
            try? FileManager.default.removeItem(at: dir)
            NSLog("MRCSELFTEST %@", failures.isEmpty ? "PASS" : "FAIL: " + failures.joined(separator: "; "))
        }
    }
}
#endif
