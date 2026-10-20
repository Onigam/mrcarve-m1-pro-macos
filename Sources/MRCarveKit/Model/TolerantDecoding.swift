import Foundation

/// Generic JSON value, used to merge stored data over current defaults.
enum JSONValue: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    /// `self` with the keys of `other` recursively laid over it (arrays and scalars are replaced).
    func merged(with other: JSONValue) -> JSONValue {
        guard case .object(var base) = self, case .object(let top) = other else { return other }
        for (key, value) in top { base[key] = base[key].map { $0.merged(with: value) } ?? value }
        return .object(base)
    }
}

/// Decoding that survives types gaining fields (e.g. `PenParameters` growing new protocol parameters):
/// when the strict decode fails, the stored keys are merged over `defaults` and decoded again.
enum TolerantDecoding {
    static func decode<T: Codable>(_ type: T.Type, from decoder: Decoder, defaults: (JSONValue) -> T) throws -> T {
        do {
            return try T(from: decoder)
        } catch {
            let stored = try JSONValue(from: decoder)
            let base = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(defaults(stored)))
            return try JSONDecoder().decode(T.self, from: JSONEncoder().encode(base.merged(with: stored)))
        }
    }
}

/// `PenParameters` decoded tolerantly (missing keys take the default pen's values).
struct TolerantPen: Codable {
    var pen: PenParameters

    init(_ pen: PenParameters) { self.pen = pen }

    init(from decoder: Decoder) throws {
        pen = try TolerantDecoding.decode(PenParameters.self, from: decoder) { stored in
            if case .object(let o) = stored, case .number(let id)? = o["id"] { return PenParameters(id: Int(id)) }
            return PenParameters(id: 0)
        }
    }

    func encode(to encoder: Encoder) throws { try pen.encode(to: encoder) }
}

/// `MachineProfile` decoded tolerantly (missing keys take the factory values).
struct TolerantMachineProfile: Codable {
    var profile: MachineProfile

    init(_ profile: MachineProfile) { self.profile = profile }

    init(from decoder: Decoder) throws {
        profile = try TolerantDecoding.decode(MachineProfile.self, from: decoder) { stored in
            if case .object(let o) = stored, case .string(let s)? = o["source"], let source = LaserSource(rawValue: s) {
                return MachineProfile(source: source)
            }
            return MachineProfile()
        }
    }

    func encode(to encoder: Encoder) throws { try profile.encode(to: encoder) }
}
