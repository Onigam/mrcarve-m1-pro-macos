import Foundation

extension Bundle {
    /// The app's SwiftPM resource bundle (localizations, icon).
    ///
    /// The generated `Bundle.module` only looks next to the `.app` folder and in the build directory, which breaks
    /// once the bundle is copied into `Contents/Resources` of a signed app. Look there first, then fall back.
    static let app: Bundle = {
        let name = "MRCarve_MRCarveApp.bundle"
        let bases = [Bundle.main.resourceURL, Bundle.main.bundleURL, Bundle.main.executableURL?.deletingLastPathComponent()]
        for case let base? in bases {
            if let bundle = Bundle(url: base.appendingPathComponent(name)) { return bundle }
        }
        return Bundle.module
    }()
}

extension Bundle {
    /// The `.lproj` of `Bundle.app` matching the user's languages. Chosen explicitly because a bare SwiftPM
    /// executable (no app Info.plist) would otherwise only ever get the development language.
    static let appStrings: Bundle = {
        let available = Bundle.app.localizations.filter { $0 != "Base" }
        if let language = Bundle.preferredLocalizations(from: available, forPreferences: Locale.preferredLanguages).first,
           let path = Bundle.app.path(forResource: language, ofType: "lproj"), let bundle = Bundle(path: path) {
            return bundle
        }
        return Bundle.app
    }()
}

/// Localized UI string; the key is the English text.
func L(_ key: String) -> String {
    Bundle.appStrings.localizedString(forKey: key, value: key, table: nil)
}

/// Localized format string (`%@`, `%d`, `%.1f`, …) with arguments.
func L(_ key: String, _ args: CVarArg...) -> String {
    String(format: L(key), locale: Locale.current, arguments: args)
}

/// Localized count string choosing the singular or plural key (French uses the singular for 0 and 1).
func L(count: Int, one: String, other: String) -> String {
    let french = Bundle.appStrings.bundlePath.hasSuffix("fr.lproj")
    let singular = french ? abs(count) <= 1 : count == 1
    return L(singular ? one : other, count)
}
