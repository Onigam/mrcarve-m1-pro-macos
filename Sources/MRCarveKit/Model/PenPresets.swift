import Foundation

/// A named set of laser parameters that can be applied to any pen.
public struct PenPreset: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    /// Laser source the values were tuned for (nil = any).
    public var source: LaserSource?
    /// Free-form notes (material, finish, hatch spacing that worked, …).
    public var notes: String
    /// Built-in material starting point (not user-tested values); shown with a warning and not deletable.
    public var isStartingPoint: Bool
    /// Suggested hatch / raster line spacing in mm, if any.
    public var suggestedLineSpacing: Double?
    /// The parameters; `id`, `name`, `colorRGB` and `isEnabled` are ignored when applying.
    public var parameters: PenParameters

    public init(id: UUID = UUID(), name: String, source: LaserSource? = nil, notes: String = "",
                isStartingPoint: Bool = false, suggestedLineSpacing: Double? = nil, parameters: PenParameters) {
        self.id = id
        self.name = name
        self.source = source
        self.notes = notes
        self.isStartingPoint = isStartingPoint
        self.suggestedLineSpacing = suggestedLineSpacing
        self.parameters = parameters
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, source, notes, isStartingPoint, suggestedLineSpacing, parameters
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        source = try c.decodeIfPresent(LaserSource.self, forKey: .source)
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        isStartingPoint = try c.decodeIfPresent(Bool.self, forKey: .isStartingPoint) ?? false
        suggestedLineSpacing = try c.decodeIfPresent(Double.self, forKey: .suggestedLineSpacing)
        parameters = try c.decode(TolerantPen.self, forKey: .parameters).pen
    }

    /// Creates a preset from a pen's current parameters.
    public init(name: String, from pen: PenParameters, source: LaserSource? = nil, notes: String = "") {
        self.init(name: name, source: source, notes: notes, parameters: pen)
    }

    /// `pen` with this preset's laser parameters, keeping its identity, name, colour and enabled state.
    public func applied(to pen: PenParameters) -> PenParameters {
        var p = parameters
        p.id = pen.id
        p.name = pen.name
        p.colorRGB = pen.colorRGB
        p.isEnabled = pen.isEnabled
        return p
    }
}

/// The user's pen preset collection plus built-in material starting points.
/// Stored as JSON in `~/Library/Application Support/MRCarve/PenPresets.json`.
public struct PenPresetLibrary: Codable, Hashable, Sendable {
    /// User presets (built-in starting points are not stored).
    public var userPresets: [PenPreset]

    public init(userPresets: [PenPreset] = []) { self.userPresets = userPresets }

    /// Built-in starting points followed by user presets.
    public var allPresets: [PenPreset] { PenPresetLibrary.startingPoints + userPresets }

    /// Default location of the library file.
    public static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("MRCarve", isDirectory: true).appendingPathComponent("PenPresets.json")
    }

    /// Loads the library; a missing or unreadable file yields an empty user library.
    public static func load(from url: URL = defaultURL) -> PenPresetLibrary {
        guard let data = try? Data(contentsOf: url),
              let library = try? JSONDecoder().decode(PenPresetLibrary.self, from: data) else { return PenPresetLibrary() }
        return library
    }

    /// Writes the library, creating the folder if needed.
    public func save(to url: URL = defaultURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    /// Material starting points. Fiber values follow the parameter table in the M1 operations manual;
    /// blue-laser values are conservative guesses. Always test on scrap material first.
    public static let startingPoints: [PenPreset] = {
        func preset(_ uuid: String, _ name: String, _ source: LaserSource, speed: Double, power: Double,
                    frequency: Double, loops: Int = 1, spacing: Double?, notes: String) -> PenPreset {
            var p = PenParameters(id: 0, name: name)
            p.markSpeed = speed
            p.power = power
            p.frequency = frequency
            p.loopCount = loops
            return PenPreset(id: UUID(uuidString: uuid)!, name: name, source: source, notes: notes,
                             isStartingPoint: true, suggestedLineSpacing: spacing, parameters: p)
        }
        return [
            preset("6D1B0A10-0000-4000-8000-000000000001", "Metal — engrave", .fiber, speed: 300, power: 100,
                   frequency: 30, spacing: 0.01, notes: "Stainless steel, aluminium, brass. Manual: line spacing 0.01 or 0.005 mm."),
            preset("6D1B0A10-0000-4000-8000-000000000002", "Painted metal — remove coating", .fiber, speed: 500, power: 100,
                   frequency: 30, spacing: 0.005, notes: "Anodised or painted surfaces."),
            preset("6D1B0A10-0000-4000-8000-000000000003", "Plastic", .fiber, speed: 1000, power: 100,
                   frequency: 30, spacing: 0.05, notes: "ABS and similar; 1000–1500 mm/s."),
            preset("6D1B0A10-0000-4000-8000-000000000004", "Leather", .fiber, speed: 1000, power: 100,
                   frequency: 30, spacing: 0.05, notes: "1000–1500 mm/s, spacing 0.05 or 0.01 mm."),
            preset("6D1B0A10-0000-4000-8000-000000000005", "Stone", .fiber, speed: 500, power: 100,
                   frequency: 30, spacing: 0.01, notes: "Slate, granite."),
            preset("6D1B0A10-0000-4000-8000-000000000006", "Painted glass", .fiber, speed: 500, power: 100,
                   frequency: 30, spacing: 0.05, notes: "Removes paint from glass; bare glass cannot be marked."),
            preset("6D1B0A10-0000-4000-8000-000000000007", "Wood — engrave", .blue, speed: 300, power: 80,
                   frequency: 30, spacing: 0.05, notes: "Rough guess for the blue diode; adjust speed first."),
            preset("6D1B0A10-0000-4000-8000-000000000008", "Cardboard / paper", .blue, speed: 800, power: 40,
                   frequency: 30, spacing: 0.08, notes: "Rough guess for the blue diode; watch for flare-ups."),
        ]
    }()
}
