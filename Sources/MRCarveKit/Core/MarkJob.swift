import Foundation

/// How the laser should traverse an item's geometry.
public enum MarkItemKind: Codable, Hashable, Sendable {
    /// Trace each polyline with the laser on (outlines, hatch lines, text strokes).
    case vector
    /// Fire a dot at every point of every polyline (bitmap / dot-matrix engraving).
    /// `dwell` is the per-point laser-on time in ms; `nil` uses the pen's `pointDwell`.
    case dots(dwell: Double?)
}

/// A batch of geometry marked with a single pen. Order of polylines is the order of marking.
public struct MarkItem: Codable, Hashable, Sendable {
    public var pen: PenParameters
    public var kind: MarkItemKind
    public var polylines: [Polyline]

    public init(pen: PenParameters, kind: MarkItemKind = .vector, polylines: [Polyline]) {
        self.pen = pen
        self.kind = kind
        self.polylines = polylines
    }

    public var bounds: Rect2? {
        polylines.compactMap(\.bounds).reduce(nil) { $0?.union($1) ?? $1 }
    }
}

/// Device-independent description of what to mark. Produced by the document/engine layer,
/// consumed by a `LaserController`, which owns lens correction and command encoding.
/// All coordinates are millimetres in machine field coordinates (see `Vec2`).
public struct MarkJob: Codable, Hashable, Sendable {
    public var items: [MarkItem]
    /// Repeat the whole job this many times (in addition to per-pen loop counts).
    public var repeatCount: Int

    public init(items: [MarkItem], repeatCount: Int = 1) {
        self.items = items
        self.repeatCount = repeatCount
    }

    public var isEmpty: Bool { items.allSatisfy { $0.polylines.isEmpty } }

    public var bounds: Rect2? {
        items.compactMap(\.bounds).reduce(nil) { $0?.union($1) ?? $1 }
    }

    /// Total laser-on path length in mm (vector items only), including pen loop counts.
    public var markLength: Double {
        items.reduce(0) { acc, item in
            guard case .vector = item.kind else { return acc }
            return acc + item.polylines.reduce(0) { $0 + $1.length } * Double(max(1, item.pen.loopCount))
        }
    }
}
