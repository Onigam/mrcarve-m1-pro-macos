import Foundation

/// A design document: ordered objects (array order = mark order), the pen table and job settings.
/// Saved as versioned JSON with the `.mrcarve` extension.
public struct Project: Codable, Hashable, Sendable {
    /// File extension of saved projects.
    public static let fileExtension = "mrcarve"
    /// Uniform type identifier declared by the app for project files.
    public static let typeIdentifier = "com.onigam.mrcarve.project"
    /// Version written by this build. Files with a higher version are rejected.
    public static let formatVersion = 1
    /// Number of pens in a new project (the vendor software offers pens 0…15 by default).
    public static let defaultPenCount = 16
    private static let formatMarker = "mrcarve-project"

    public var objects: [DesignObject]
    public var pens: [PenParameters]
    /// Name of the `MachineProfile` the design is meant for.
    public var machineProfileName: String
    /// Number of times the whole job is repeated.
    public var repeatCount: Int

    public init(objects: [DesignObject] = [], pens: [PenParameters] = Project.defaultPens(),
                machineProfileName: String = MachineProfileLibrary.fiberName, repeatCount: Int = 1) {
        self.objects = objects
        self.pens = pens
        self.machineProfileName = machineProfileName
        self.repeatCount = repeatCount
    }

    /// The 16 default pens with the vendor palette.
    public static func defaultPens() -> [PenParameters] {
        (0..<defaultPenCount).map { PenParameters(id: $0) }
    }

    // MARK: Pens

    /// The pen with `id`, or a default pen if the table has no such entry.
    public func pen(_ id: Int) -> PenParameters {
        pens.first { $0.id == id } ?? PenParameters(id: id)
    }

    /// Mutates the pen with `id`, creating it if needed.
    public mutating func updatePen(_ id: Int, _ body: (inout PenParameters) -> Void) {
        if let i = pens.firstIndex(where: { $0.id == id }) {
            body(&pens[i])
        } else {
            var pen = PenParameters(id: id)
            body(&pen)
            pens.append(pen)
            pens.sort { $0.id < $1.id }
        }
    }

    // MARK: Objects

    public func index(of id: UUID) -> Int? { objects.firstIndex { $0.id == id } }

    public func object(_ id: UUID) -> DesignObject? { objects.first { $0.id == id } }

    /// Mutates the object with `id` if present.
    public mutating func updateObject(_ id: UUID, _ body: (inout DesignObject) -> Void) {
        if let i = index(of: id) { body(&objects[i]) }
    }

    /// Number of objects using `penID` for their outline or any hatch layer.
    public func usageCount(ofPen penID: Int) -> Int {
        objects.filter { o in
            o.penID == penID || (o.fill?.layers.contains { $0.isEnabled && $0.penID == penID } ?? false)
        }.count
    }

    // MARK: File format

    private enum CodingKeys: String, CodingKey { case format, version, objects, pens, machineProfileName, repeatCount }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard try c.decodeIfPresent(String.self, forKey: .format) == Project.formatMarker else {
            throw ProjectFileError.notAProject
        }
        let version = try c.decode(Int.self, forKey: .version)
        guard version <= Project.formatVersion else { throw ProjectFileError.newerVersion(version) }
        objects = try c.decodeIfPresent([DesignObject].self, forKey: .objects) ?? []
        pens = try c.decodeIfPresent([TolerantPen].self, forKey: .pens)?.map(\.pen) ?? Project.defaultPens()
        machineProfileName = try c.decodeIfPresent(String.self, forKey: .machineProfileName) ?? MachineProfileLibrary.fiberName
        repeatCount = max(1, try c.decodeIfPresent(Int.self, forKey: .repeatCount) ?? 1)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Project.formatMarker, forKey: .format)
        try c.encode(Project.formatVersion, forKey: .version)
        try c.encode(objects, forKey: .objects)
        try c.encode(pens, forKey: .pens)
        try c.encode(machineProfileName, forKey: .machineProfileName)
        try c.encode(repeatCount, forKey: .repeatCount)
    }

    /// JSON representation written to `.mrcarve` files.
    public func fileData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    /// Decodes a project from `.mrcarve` JSON.
    public init(fileData data: Data) throws {
        do {
            self = try JSONDecoder().decode(Project.self, from: data)
        } catch let error as ProjectFileError {
            throw error
        } catch {
            throw ProjectFileError.corrupt(String(describing: error))
        }
    }

    public init(contentsOf url: URL) throws {
        try self.init(fileData: try Data(contentsOf: url))
    }

    /// Atomically writes the project to `url`.
    public func write(to url: URL) throws {
        try fileData().write(to: url, options: .atomic)
    }
}

/// Errors reading `.mrcarve` files.
public enum ProjectFileError: Error, LocalizedError, Sendable, Equatable {
    case notAProject
    case newerVersion(Int)
    case corrupt(String)

    public var errorDescription: String? {
        switch self {
        case .notAProject: "The file is not an MR Carve project."
        case .newerVersion(let v): "The project was saved by a newer version of MR Carve (format \(v))."
        case .corrupt(let m): "The project file is damaged (\(m))."
        }
    }
}
