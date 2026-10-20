import SwiftUI
import MRCarveKit

/// One editor window: sidebar, canvas, inspector, toolbar, status bar and laser sheets.
struct ContentView: View {
    /// File shown by this window (window restoration / File ▸ Open).
    @Binding var fileURL: URL?
    @State private var document = DocumentModel()
    @State private var editor = EditorState()
    @State private var cache = PreviewCache()
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    private var device: DeviceViewModel { .shared }
    private var router: AppRouter { .shared }

    var body: some View {
        NavigationSplitView {
            Sidebar(document: document)
                .navigationSplitViewColumnWidth(min: 210, ideal: 250, max: 360)
        } detail: {
            canvas
                .inspector(isPresented: $editor.isInspectorPresented) {
                    InspectorView(document: document, editor: editor, cache: cache)
                        .inspectorColumnWidth(min: 280, ideal: 310, max: 440)
                }
        }
        .toolbar { MainToolbar(document: document, editor: editor) }
        .navigationTitle(document.displayName)
        .focusedSceneValue(\.document, document)
        .focusedSceneValue(\.editor, editor)
        .background(WindowAccessor(document: document))
        .sheet(isPresented: $document.isSafetySheetPresented) { SafetySheet(document: document) }
        .sheet(isPresented: progressSheet) { MarkProgressSheet(document: document) }
        .alert(document.alert?.title ?? "", isPresented: documentAlert, presenting: document.alert) { _ in
            Button(L("OK")) { document.alert = nil }
        } message: { info in
            Text(info.message)
        }
        .alert(L("Laser"), isPresented: deviceAlert) {
            Button(L("OK")) { device.errorMessage = nil }
        } message: {
            Text(device.errorMessage ?? "")
        }
        .task { start() }
        .onChange(of: document.fileURL) { _, url in if fileURL != url { fileURL = url } }
        .onChange(of: router.pending) { _, _ in consumePendingOpens() }
        .onChange(of: document.project.objects.map(\.id)) { _, ids in cache.prune(keeping: Set(ids)) }
        .frame(minWidth: 900, minHeight: 560)
    }

    private var canvas: some View {
        CanvasView(document: document, editor: editor, cache: cache)
            .overlay(alignment: .top) { fieldWarning }
            .overlay(alignment: .bottomTrailing) { CanvasControls(editor: editor).padding(12) }
            .safeAreaInset(edge: .bottom, spacing: 0) { StatusBar(document: document, editor: editor) }
            .accessibilityLabel(L("Design canvas"))
    }

    @ViewBuilder
    private var fieldWarning: some View {
        if !document.outsideField.isEmpty {
            Label(L(count: document.outsideField.count, one: "%d object extends beyond the marking field and cannot be marked.",
                     other: "%d objects extend beyond the marking field and cannot be marked."),
                  systemImage: "exclamationmark.triangle.fill")
                .font(.callout.weight(.medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.red.opacity(0.85), in: Capsule())
                .padding(.top, 10)
                .allowsHitTesting(false)
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    // MARK: Presentation bindings

    private var progressSheet: Binding<Bool> {
        Binding(get: { device.ownerID == document.id && (device.isMarking || device.outcome != nil) },
                set: { shown in if !shown && !device.isMarking { device.outcome = nil } })
    }

    private var documentAlert: Binding<Bool> {
        Binding(get: { document.alert != nil }, set: { if !$0 { document.alert = nil } })
    }

    private var deviceAlert: Binding<Bool> {
        Binding(get: { device.errorMessage != nil && (device.ownerID == nil || device.ownerID == document.id) },
                set: { if !$0 { device.errorMessage = nil } })
    }

    // MARK: Opening files

    private func start() {
        router.openWindow = openWindow
        if let url = fileURL, document.fileURL != url {
            open(url)
        }
        consumePendingOpens()
    }

    private func open(_ url: URL) {
        do {
            try document.load(url)
            #if DEBUG
            runDebugActions()
            #endif
        } catch {
            document.alert = AlertInfo(title: L("Could not open “%@”", url.lastPathComponent), message: error.localizedDescription)
            fileURL = nil
        }
    }

    #if DEBUG
    /// Screenshot aids for debug builds, e.g. `open -a "MR Carve" file.mrcarve --args -MRCarveDebugSelect 1,2
    /// -MRCarveDebugAction mark` (actions: frame, mark, markNow, settings, pen:N).
    private func runDebugActions() {
        let defaults = UserDefaults.standard
        if let spec = defaults.string(forKey: "MRCarveDebugSelect") {
            let indices = spec.split(separator: ",").compactMap { Int($0) }
            document.select(Set(indices.compactMap { document.project.objects.indices.contains($0) ? document.project.objects[$0].id : nil }))
        }
        guard let action = defaults.string(forKey: "MRCarveDebugAction") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            switch action {
            case "frame": document.toggleFraming()
            case "mark": document.requestMark()
            case "markNow": device.safetyAcknowledged = true; document.requestMark()
            case "settings": openSettings()
            case "selftest": DebugSelfTest.run(document)
            default:
                if action.hasPrefix("pen:"), let id = Int(action.dropFirst(4)) { document.selection = []; document.inspectedPenID = id }
            }
        }
    }
    #endif

    /// URLs queued by `AppRouter` before a window could take them.
    private func consumePendingOpens() {
        guard !router.pending.isEmpty, router.isKeyOrOnly(document) else { return }
        var urls = router.pending.filter { !DocumentRegistry.shared.focusWindow(showing: $0) }
        router.pending = []
        if document.isPristine, let first = urls.first {
            urls.removeFirst()
            open(first)
        }
        for url in urls { openWindow(value: url) }
    }
}

/// Floating canvas controls: fill/raster preview toggle and zoom.
private struct CanvasControls: View {
    let editor: EditorState
    private var settings: AppSettings { .shared }

    var body: some View {
        HStack(spacing: 2) {
            control(settings.showFillPreview ? "eye.square.fill" : "eye.square", L("Show Fill & Raster Preview")) {
                settings.showFillPreview.toggle()
            }
            Divider().frame(height: 16)
            control("minus.magnifyingglass", L("Zoom Out")) { editor.canvas?.zoom(by: 0.8) }
            control("arrow.up.left.and.down.right.magnifyingglass", L("Zoom to Fit")) {
                editor.canvas?.userAdjustedView = false
                editor.canvas?.zoomToFit()
            }
            control("plus.magnifyingglass", L("Zoom In")) { editor.canvas?.zoom(by: 1.25) }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.separator))
        .shadow(color: .black.opacity(0.12), radius: 4, y: 1)
    }

    private func control(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 24, height: 22)
        }
        .buttonStyle(.borderless)
        .help(help)
        .accessibilityLabel(help)
    }
}

// MARK: - Focused values

struct FocusedDocumentKey: FocusedValueKey { typealias Value = DocumentModel }
struct FocusedEditorKey: FocusedValueKey { typealias Value = EditorState }

extension FocusedValues {
    var document: DocumentModel? {
        get { self[FocusedDocumentKey.self] }
        set { self[FocusedDocumentKey.self] = newValue }
    }

    var editor: EditorState? {
        get { self[FocusedEditorKey.self] }
        set { self[FocusedEditorKey.self] = newValue }
    }
}
