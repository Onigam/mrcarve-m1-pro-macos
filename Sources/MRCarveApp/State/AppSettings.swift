import Foundation
import Observation
import MRCarveKit

/// Which controller the app talks to.
enum DeviceMode: String, CaseIterable, Identifiable {
    case simulator, usb
    var id: String { rawValue }
    var title: String { self == .simulator ? L("Simulator") : L("USB device") }
}

/// What the red light traces when framing.
enum FrameMode: String, CaseIterable, Identifiable {
    case boundingBox, outline
    var id: String { rawValue }
    var title: String { self == .boundingBox ? L("Bounding Box") : L("Outline") }
    var symbolName: String { self == .boundingBox ? "square.dashed" : "scribble" }
}

/// User preferences, persisted in `UserDefaults`.
@MainActor @Observable
final class AppSettings {
    static let shared = AppSettings()

    @ObservationIgnored private let defaults = UserDefaults.standard

    var deviceMode: DeviceMode { didSet { defaults.set(deviceMode.rawValue, forKey: "deviceMode") } }
    var autoConnect: Bool { didSet { defaults.set(autoConnect, forKey: "autoConnect") } }
    var frameMode: FrameMode { didSet { defaults.set(frameMode.rawValue, forKey: "frameMode") } }
    var units: LengthUnit { didSet { defaults.set(units.rawValue, forKey: "units") } }
    var showGrid: Bool { didSet { defaults.set(showGrid, forKey: "showGrid") } }
    var snapToGrid: Bool { didSet { defaults.set(snapToGrid, forKey: "snapToGrid") } }
    /// Snap increment in mm.
    var snapStep: Double { didSet { defaults.set(snapStep, forKey: "snapStep") } }
    var showFillPreview: Bool { didSet { defaults.set(showFillPreview, forKey: "showFillPreview") } }
    var showRulers: Bool { didSet { defaults.set(showRulers, forKey: "showRulers") } }

    private init() {
        defaults.register(defaults: [
            "deviceMode": DeviceMode.simulator.rawValue, "autoConnect": true, "frameMode": FrameMode.boundingBox.rawValue,
            "units": LengthUnit.millimeters.rawValue, "showGrid": true, "snapToGrid": false, "snapStep": 0.5,
            "showFillPreview": true, "showRulers": true,
        ])
        deviceMode = DeviceMode(rawValue: defaults.string(forKey: "deviceMode") ?? "") ?? .simulator
        autoConnect = defaults.bool(forKey: "autoConnect")
        frameMode = FrameMode(rawValue: defaults.string(forKey: "frameMode") ?? "") ?? .boundingBox
        units = LengthUnit(rawValue: defaults.string(forKey: "units") ?? "") ?? .millimeters
        showGrid = defaults.bool(forKey: "showGrid")
        snapToGrid = defaults.bool(forKey: "snapToGrid")
        snapStep = max(0.01, defaults.double(forKey: "snapStep"))
        showFillPreview = defaults.bool(forKey: "showFillPreview")
        showRulers = defaults.bool(forKey: "showRulers")
    }
}

/// Machine profiles (lens / red-light calibration), persisted in Application Support.
@MainActor @Observable
final class MachineStore {
    static let shared = MachineStore()

    var library: MachineProfileLibrary {
        didSet { if library != oldValue { try? library.save() } }
    }

    private init() { library = MachineProfileLibrary.load() }

    var profileNames: [String] { library.profiles.map(\.name) }

    func profile(named name: String?) -> MachineProfile { library.profile(named: name) }

    /// Imports a vendor `LmcPar_*.cfg` (source guessed from the file name) and returns the profile name.
    /// The profile of the same name (e.g. the factory "M1 Pro (Fiber)") is replaced by the imported calibration.
    func importVendorConfig(_ url: URL) throws -> String {
        let stem = url.deletingPathExtension().lastPathComponent
        let source: LaserSource = stem.localizedCaseInsensitiveContains("blue") ? .blue : .fiber
        var profile = try VendorConfig.machineProfile(fromLmcPar: url, source: source)
        if profile.name.isEmpty { profile.name = source == .fiber ? MachineProfileLibrary.fiberName : MachineProfileLibrary.blueName }
        library.upsert(profile)
        return profile.name
    }
}

/// Pen presets, persisted in Application Support.
@MainActor @Observable
final class PresetStore {
    static let shared = PresetStore()

    var library: PenPresetLibrary {
        didSet { if library != oldValue { try? library.save() } }
    }

    private init() { library = PenPresetLibrary.load() }

    var all: [PenPreset] { library.allPresets }

    func add(name: String, pen: PenParameters, source: LaserSource?) {
        library.userPresets.append(PenPreset(name: name, from: pen, source: source))
    }

    func remove(_ id: UUID) {
        library.userPresets.removeAll { $0.id == id }
    }
}
