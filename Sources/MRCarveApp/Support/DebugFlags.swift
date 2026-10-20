import Foundation

/// Switches for automated test launches. Always off in release builds.
enum DebugFlags {
    /// `MRCARVE_NO_PROMPTS=1` (or `--args -MRCarveNoPrompts YES`): skip the unsaved-changes, quit and safety prompts
    /// so scripted launches never leave modal UI on screen. Unsaved changes are discarded.
    static let noPrompts: Bool = {
        #if DEBUG
        ProcessInfo.processInfo.environment["MRCARVE_NO_PROMPTS"] == "1" || UserDefaults.standard.bool(forKey: "MRCarveNoPrompts")
        #else
        false
        #endif
    }()
}
