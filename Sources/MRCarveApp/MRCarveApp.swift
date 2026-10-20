import SwiftUI
import AppKit
import MRCarveKit

@main
struct MRCarveApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup(L("MR Carve"), id: "editor", for: URL.self) { $url in
            ContentView(fileURL: $url)
        }
        .defaultSize(width: 1280, height: 820)
        .windowToolbarStyle(.unified)
        .commands { AppCommands() }

        Settings {
            SettingsView()
        }
    }
}

/// App-level behaviour that SwiftUI does not cover: laser hot keys, open-from-Finder and quit confirmation.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var keyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if Bundle.main.bundleIdentifier == nil, let icon = Bundle.app.image(forResource: "AppIcon") {
            NSApp.applicationIconImage = icon  // `swift run` without an app bundle
        }
        DeviceViewModel.shared.start()
        installKeyMonitor()
    }

    /// Files opened from Finder are taken over at the Apple-event level: SwiftUI would otherwise create a
    /// throwaway window per event and skip the initial window when launched with a document.
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleOpenDocuments(_:withReplyEvent:)),
                                                     forEventClass: AEEventClass(kCoreEventClass),
                                                     andEventID: AEEventID(kAEOpenDocuments))
    }

    @objc private func handleOpenDocuments(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        guard let direct = event.paramDescriptor(forKeyword: keyDirectObject) else { return }
        var urls: [URL] = []
        if direct.numberOfItems > 0 {
            for i in 1...direct.numberOfItems { if let url = direct.atIndex(i)?.fileURLValue { urls.append(url) } }
        } else if let url = direct.fileURLValue {
            urls.append(url)
        }
        MainActor.assumeIsolated {
            for url in urls where url.pathExtension.lowercased() == Project.fileExtension {
                AppRouter.shared.open(url)
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if DebugFlags.noPrompts {
            DeviceViewModel.shared.stop()
            return .terminateNow
        }
        if DeviceViewModel.shared.isBusy {
            let alert = NSAlert()
            alert.messageText = L("The laser is still running.")
            alert.informativeText = L("Stop the laser before quitting?")
            alert.addButton(withTitle: L("Stop and Quit"))
            alert.addButton(withTitle: L("Cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
            DeviceViewModel.shared.stop()
        }
        for document in DocumentRegistry.shared.documents where document.isDirty {
            if !UnsavedChanges.confirm(document) { return .terminateCancel }
        }
        return .terminateNow
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// F1 (frame), F2 (mark) like the vendor software, and Esc to stop while the laser is busy.
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let handled = MainActor.assumeIsolated { AppDelegate.handle(event) }
            return handled ? nil : event
        }
    }

    @MainActor
    private static func handle(_ event: NSEvent) -> Bool {
        let device = DeviceViewModel.shared
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        switch event.keyCode {
        case 53 where device.isBusy && modifiers.isEmpty:  // Esc
            device.stop()
            return true
        case 122 where modifiers.isEmpty:  // F1
            guard let document = DocumentRegistry.shared.keyDocument, NSApp.keyWindow?.attachedSheet == nil else { return false }
            document.toggleFraming()
            return true
        case 120:  // F2, ⇧F2 = selection only
            guard let document = DocumentRegistry.shared.keyDocument, NSApp.keyWindow?.attachedSheet == nil else { return false }
            document.requestMark(selectionOnly: modifiers == .shift)
            return true
        default:
            return false
        }
    }
}
