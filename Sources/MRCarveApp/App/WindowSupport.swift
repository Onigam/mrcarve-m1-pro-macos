import AppKit
import SwiftUI
import Observation
import MRCarveKit

/// Routes files opened from Finder (or File ▸ Open) to windows.
@MainActor @Observable
final class AppRouter {
    static let shared = AppRouter()
    /// URLs waiting for a window.
    var pending: [URL] = []
    @ObservationIgnored var openWindow: OpenWindowAction?

    /// Opens `url`: brings its window forward if already open, else loads it into the frontmost window
    /// if that is empty, else opens a new window.
    func open(_ url: URL) {
        if DocumentRegistry.shared.focusWindow(showing: url) { return }
        if let doc = DocumentRegistry.shared.keyDocument, doc.isPristine {
            do { try doc.load(url) } catch {
                doc.alert = AlertInfo(title: L("Could not open “%@”", url.lastPathComponent), message: error.localizedDescription)
            }
        } else if let openWindow {
            openWindow(value: url)
        } else {
            // Very early during launch: wait for a window (restored or new) to pick it up from `pending`.
            pending.append(url)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { AppRouter.shared.flushPending() }
        }
    }

    /// Opens queued URLs in new windows when no window took them (launch by opening a file shows no window).
    func flushPending() {
        guard !pending.isEmpty, DocumentRegistry.shared.documents.isEmpty else { return }
        let urls = pending.filter { !DocumentRegistry.shared.focusWindow(showing: $0) }
        if let openWindow {
            pending = []
            urls.forEach { openWindow(value: $0) }
        } else if let (menu, index) = AppRouter.newWindowMenuItem() {
            menu.performActionForItem(at: index)  // the new window consumes `pending`
        }
    }

    /// File ▸ New (⌘N) in the main menu.
    private static func newWindowMenuItem() -> (NSMenu, Int)? {
        for top in NSApp.mainMenu?.items ?? [] {
            guard let menu = top.submenu else { continue }
            if let i = menu.items.firstIndex(where: { $0.keyEquivalent == "n" && $0.keyEquivalentModifierMask == .command }) {
                return (menu, i)
            }
        }
        return nil
    }

    /// Whether `document` should handle pending opens (it is in the key window, or the only window).
    func isKeyOrOnly(_ document: DocumentModel) -> Bool {
        let registry = DocumentRegistry.shared
        return registry.keyDocument === document || registry.documents.count <= 1
    }

    /// Keeps the first `OpenWindowAction` seen (from the menu bar's environment).
    func adopt(_ action: OpenWindowAction) {
        if openWindow == nil { openWindow = action }
    }

    /// File ▸ Open… panel.
    func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [DocumentModel.projectType]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        panel.urls.forEach(open)
    }
}

/// Weak registry of open documents and their windows (for Quit confirmation and keyboard shortcuts).
@MainActor
final class DocumentRegistry {
    static let shared = DocumentRegistry()

    private struct Entry {
        weak var document: DocumentModel?
        weak var window: NSWindow?
    }

    private var entries: [Entry] = []

    func register(_ document: DocumentModel, window: NSWindow) {
        entries.removeAll { $0.document == nil || $0.window == nil || $0.document === document }
        entries.append(Entry(document: document, window: window))
    }

    var documents: [DocumentModel] {
        entries.compactMap { $0.window?.isVisible == true ? $0.document : nil }
    }

    func document(for window: NSWindow?) -> DocumentModel? {
        guard let window else { return nil }
        return entries.first { $0.window === window }?.document
    }

    var keyDocument: DocumentModel? { document(for: NSApp.keyWindow) ?? document(for: NSApp.mainWindow) }

    /// Brings forward the window showing `url`, if any.
    func focusWindow(showing url: URL) -> Bool {
        guard let entry = entries.first(where: { $0.document?.fileURL?.standardizedFileURL == url.standardizedFileURL }),
              let window = entry.window else { return false }
        window.makeKeyAndOrderFront(nil)
        return true
    }
}

/// Connects a SwiftUI window to its document: edited dot, proxy icon, registry and close confirmation.
struct WindowAccessor: NSViewRepresentable {
    let document: DocumentModel

    func makeNSView(context: Context) -> WindowTrackingView {
        WindowTrackingView(document: document)
    }

    func updateNSView(_ view: WindowTrackingView, context: Context) {}
}

final class WindowTrackingView: NSView {
    let document: DocumentModel
    private var closeGuard: WindowCloseGuard?

    init(document: DocumentModel) {
        self.document = document
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        DocumentRegistry.shared.register(document, window: window)
        window.tabbingMode = .preferred
        if closeGuard == nil || closeGuard?.window !== window {
            closeGuard = WindowCloseGuard(window: window, document: document)
        }
        observe()
    }

    /// Keeps the window's edited state and represented file in sync with the document.
    private func observe() {
        withObservationTracking {
            window?.isDocumentEdited = document.isDirty
            window?.representedURL = document.fileURL
        } onChange: { [weak self] in
            DispatchQueue.main.async { self?.observe() }
        }
    }
}

/// Wraps SwiftUI's window delegate to ask about unsaved changes before closing.
/// Every other delegate message is forwarded to the original delegate.
final class WindowCloseGuard: NSObject, NSWindowDelegate {
    weak var window: NSWindow?
    private weak var original: NSWindowDelegate?
    private weak var document: DocumentModel?

    init(window: NSWindow, document: DocumentModel) {
        self.window = window
        self.original = window.delegate
        self.document = document
        super.init()
        window.delegate = self
    }

    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || (original?.responds(to: selector) ?? false)
    }

    override func forwardingTarget(for selector: Selector!) -> Any? {
        original?.responds(to: selector) == true ? original : nil
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if let document, document.isDirty, !UnsavedChanges.confirm(document) { return false }
        return original?.windowShouldClose?(sender) ?? true
    }
}

/// "Do you want to save the changes…" prompt.
@MainActor
enum UnsavedChanges {
    /// Returns true when it is OK to discard the document (saved or user chose Don't Save).
    static func confirm(_ document: DocumentModel) -> Bool {
        if DebugFlags.noPrompts { return true }
        let alert = NSAlert()
        alert.messageText = L("Do you want to save the changes made to “%@”?", document.displayName)
        alert.informativeText = L("Your changes will be lost if you don't save them.")
        alert.addButton(withTitle: L("Save"))
        alert.addButton(withTitle: L("Cancel"))
        alert.addButton(withTitle: L("Don't Save"))
        switch alert.runModal() {
        case .alertFirstButtonReturn: return document.save()
        case .alertThirdButtonReturn: return true
        default: return false
        }
    }
}
