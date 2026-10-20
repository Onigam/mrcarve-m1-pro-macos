import Foundation

/// Named machine profiles (lens + red light + source calibration) the user can choose from.
/// Stored as JSON in `~/Library/Application Support/MRCarve/MachineProfiles.json`.
public struct MachineProfileLibrary: Codable, Hashable, Sendable {
    public static let fiberName = "M1 Pro (Fiber)"
    public static let blueName = "M1 Pro (Blue)"

    public var profiles: [MachineProfile]
    /// Profile used for new projects and when a project's profile is missing.
    public var defaultProfileName: String

    public init(profiles: [MachineProfile] = MachineProfileLibrary.builtInProfiles,
                defaultProfileName: String = MachineProfileLibrary.fiberName) {
        self.profiles = profiles.isEmpty ? MachineProfileLibrary.builtInProfiles : profiles
        self.defaultProfileName = defaultProfileName
    }

    private enum CodingKeys: String, CodingKey { case profiles, defaultProfileName }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let profiles = try c.decodeIfPresent([TolerantMachineProfile].self, forKey: .profiles)?.map(\.profile) ?? []
        self.init(profiles: profiles,
                  defaultProfileName: try c.decodeIfPresent(String.self, forKey: .defaultProfileName) ?? MachineProfileLibrary.fiberName)
    }

    /// Factory profiles for the two laser sources of the M1 Pro.
    public static var builtInProfiles: [MachineProfile] {
        [MachineProfile(name: fiberName, source: .fiber), MachineProfile(name: blueName, source: .blue)]
    }

    /// The profile named `name`, else the default profile, else the first one.
    public func profile(named name: String?) -> MachineProfile {
        if let name, let p = profiles.first(where: { $0.name == name }) { return p }
        return profiles.first { $0.name == defaultProfileName } ?? profiles.first ?? MachineProfile()
    }

    public var defaultProfile: MachineProfile { profile(named: defaultProfileName) }

    /// Inserts or replaces the profile with the same name.
    public mutating func upsert(_ profile: MachineProfile) {
        if let i = profiles.firstIndex(where: { $0.name == profile.name }) {
            profiles[i] = profile
        } else {
            profiles.append(profile)
        }
    }

    /// A name not used by any profile, derived from `base`.
    public func uniqueName(_ base: String) -> String {
        guard profiles.contains(where: { $0.name == base }) else { return base }
        var n = 2
        while profiles.contains(where: { $0.name == "\(base) \(n)" }) { n += 1 }
        return "\(base) \(n)"
    }

    public static var defaultURL: URL {
        PenPresetLibrary.defaultURL.deletingLastPathComponent().appendingPathComponent("MachineProfiles.json")
    }

    /// Loads the library, falling back to the built-in profiles.
    public static func load(from url: URL = defaultURL) -> MachineProfileLibrary {
        guard let data = try? Data(contentsOf: url),
              let library = try? JSONDecoder().decode(MachineProfileLibrary.self, from: data),
              !library.profiles.isEmpty else { return MachineProfileLibrary() }
        return library
    }

    public func save(to url: URL = defaultURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
