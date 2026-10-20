import SwiftUI
import MRCarveKit

/// Menu bar: File, Edit additions, Object, View and Laser menus.
struct AppCommands: Commands {
    @FocusedValue(\.document) private var document
    @FocusedValue(\.editor) private var editor
    @Environment(\.openWindow) private var openWindow
    private var device: DeviceViewModel { .shared }
    private var settings: AppSettings { .shared }
    private var recents: RecentFiles { .shared }

    var body: some Commands {
        // Lets AppKit-side code (open-from-Finder at launch) create windows before any window exists.
        let _ = AppRouter.shared.adopt(openWindow)
        CommandGroup(replacing: .newItem) {
            Button(L("New")) { openWindow(id: "editor") }
                .keyboardShortcut("n")
            Button(L("Open…")) {
                AppRouter.shared.openWindow = openWindow
                AppRouter.shared.showOpenPanel()
            }
            .keyboardShortcut("o")
            Menu(L("Open Recent")) {
                ForEach(recents.urls, id: \.self) { url in
                    Button(url.deletingPathExtension().lastPathComponent) {
                        AppRouter.shared.openWindow = openWindow
                        AppRouter.shared.open(url)
                    }
                }
                Divider()
                Button(L("Clear Menu")) { recents.clear() }
                    .disabled(recents.urls.isEmpty)
            }
        }

        CommandGroup(replacing: .saveItem) {
            Button(L("Save")) { document?.save() }
                .keyboardShortcut("s")
                .disabled(document == nil)
            Button(L("Save As…")) { document?.saveAs() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(document == nil)
            Divider()
            Button(L("Import…")) { document?.importWithPanel() }
                .keyboardShortcut("i")
                .disabled(document == nil)
        }

        CommandGroup(after: .pasteboard) {
            Divider()
            Button(L("Duplicate")) { document?.duplicateSelection() }
                .keyboardShortcut("d")
                .disabled(document?.selection.isEmpty ?? true)
        }

        CommandMenu(L("Object")) {
            Menu(L("Add")) {
                ForEach(CanvasTool.allCases.filter { $0 != .select }) { tool in
                    Button(tool.title) { editor?.tool = tool }
                }
            }
            .disabled(editor == nil)
            Divider()
            Button(L("Center in Field")) { document?.centerSelectionInField() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(document?.selection.isEmpty ?? true)
            Menu(L("Align")) {
                Button(L("Align Left")) { document?.alignSelection(.left) }
                Button(L("Align Centers Horizontally")) { document?.alignSelection(.hCenter) }
                Button(L("Align Right")) { document?.alignSelection(.right) }
                Divider()
                Button(L("Align Top")) { document?.alignSelection(.top) }
                Button(L("Align Centers Vertically")) { document?.alignSelection(.vCenter) }
                Button(L("Align Bottom")) { document?.alignSelection(.bottom) }
            }
            .disabled((document?.selection.count ?? 0) < 2)
            Menu(L("Mark Order")) {
                Button(L("Mark First")) { document?.reorderSelection(.first) }
                    .keyboardShortcut("[", modifiers: [.command, .shift])
                Button(L("Mark Earlier")) { document?.reorderSelection(.earlier) }
                    .keyboardShortcut("[")
                Button(L("Mark Later")) { document?.reorderSelection(.later) }
                    .keyboardShortcut("]")
                Button(L("Mark Last")) { document?.reorderSelection(.last) }
                    .keyboardShortcut("]", modifiers: [.command, .shift])
            }
            .disabled(document?.selection.isEmpty ?? true)
            Divider()
            Button(L("Hide")) {
                guard let document else { return }
                document.updateObjects(document.selection, L("Hide")) { $0.isVisible = false }
                document.clearSelection()
            }
            .keyboardShortcut("h", modifiers: [.command, .control])
            .disabled(document?.selection.isEmpty ?? true)
            Button(L("Show All")) {
                guard let document else { return }
                document.updateObjects(document.project.objects.map(\.id), L("Show All")) { $0.isVisible = true }
            }
            .disabled(document == nil)
            Button(L("Lock")) {
                guard let document else { return }
                document.updateObjects(document.selection, L("Lock")) { $0.isLocked = true }
            }
            .keyboardShortcut("l", modifiers: [.command, .control])
            .disabled(document?.selection.isEmpty ?? true)
            Button(L("Unlock All")) {
                guard let document else { return }
                document.updateObjects(document.project.objects.map(\.id), L("Unlock All")) { $0.isLocked = false }
            }
            .disabled(document == nil)
        }

        CommandGroup(before: .sidebar) {
            Button(L("Zoom In")) { editor?.canvas?.zoom(by: 1.25) }
                .keyboardShortcut("+")
            Button(L("Zoom Out")) { editor?.canvas?.zoom(by: 0.8) }
                .keyboardShortcut("-")
            Button(L("Zoom to Fit")) {
                editor?.canvas?.userAdjustedView = false
                editor?.canvas?.zoomToFit()
            }
            .keyboardShortcut("0")
            Button(L("Zoom to Selection")) { editor?.canvas?.zoomToSelection() }
                .keyboardShortcut("9")
            Button(L("Actual Size")) { editor?.canvas?.zoomToActualSize() }
                .keyboardShortcut("1")
            Divider()
            Toggle(L("Show Fill & Raster Preview"), isOn: Binding(get: { settings.showFillPreview }, set: { settings.showFillPreview = $0 }))
                .keyboardShortcut("p", modifiers: [.command, .option])
            Toggle(L("Show Grid"), isOn: Binding(get: { settings.showGrid }, set: { settings.showGrid = $0 }))
                .keyboardShortcut("'")
            Toggle(L("Snap to Grid"), isOn: Binding(get: { settings.snapToGrid }, set: { settings.snapToGrid = $0 }))
                .keyboardShortcut("'", modifiers: [.command, .shift])
            Divider()
            Button(editor?.isInspectorPresented ?? true ? L("Hide Inspector") : L("Show Inspector")) {
                editor?.isInspectorPresented.toggle()
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            Divider()
        }

        CommandMenu(L("Laser")) {
            Button(device.connection.isConnected ? L("Disconnect") : L("Connect")) {
                device.toggleConnection(owner: document?.id)
            }
            .disabled(device.isBusy || device.connection == .connecting)
            Picker(L("Device"), selection: Binding(get: { device.mode }, set: { device.setMode($0) })) {
                ForEach(DeviceMode.allCases) { Text($0.title).tag($0) }
            }
            Divider()
            Button(device.isFraming ? L("Stop Framing") : L("Frame (F1)")) { document?.toggleFraming() }
                .keyboardShortcut("l")
                .disabled(document == nil || device.isMarking)
            Picker(L("Frame Shape"), selection: Binding(get: { settings.frameMode }, set: { mode in
                settings.frameMode = mode
                if device.isFraming { document?.refreshFraming() }
            })) {
                ForEach(FrameMode.allCases) { Text($0.title).tag($0) }
            }
            Divider()
            Button(L("Mark (F2)")) { document?.requestMark() }
                .keyboardShortcut(.return)
                .disabled(document == nil || device.isMarking)
            Button(L("Mark Selection Only (⇧F2)")) { document?.requestMark(selectionOnly: true) }
                .keyboardShortcut(.return, modifiers: [.command, .shift])
                .disabled(document?.selection.isEmpty ?? true || device.isMarking)
            Divider()
            Button(L("Stop (Esc)")) { device.stop() }
                .keyboardShortcut(".")
                .disabled(!device.isBusy)
        }
    }
}
