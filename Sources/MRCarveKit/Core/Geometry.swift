import Foundation
import CoreGraphics

/// A 2D point in **millimetres**, in machine field coordinates:
/// origin at the centre of the galvo field, +X to the right, +Y up (away from the operator).
public struct Vec2: Hashable, Codable, Sendable, CustomStringConvertible {
    public var x: Double
    public var y: Double

    public init(_ x: Double, _ y: Double) { self.x = x; self.y = y }
    public init(x: Double, y: Double) { self.x = x; self.y = y }
    public init(_ p: CGPoint) { x = Double(p.x); y = Double(p.y) }

    public static let zero = Vec2(0, 0)

    public var cgPoint: CGPoint { CGPoint(x: x, y: y) }
    public var length: Double { (x * x + y * y).squareRoot() }
    public var description: String { String(format: "(%.4f, %.4f)", x, y) }

    public static func + (a: Vec2, b: Vec2) -> Vec2 { Vec2(a.x + b.x, a.y + b.y) }
    public static func - (a: Vec2, b: Vec2) -> Vec2 { Vec2(a.x - b.x, a.y - b.y) }
    public static func * (a: Vec2, s: Double) -> Vec2 { Vec2(a.x * s, a.y * s) }
    public static func / (a: Vec2, s: Double) -> Vec2 { Vec2(a.x / s, a.y / s) }
    public func distance(to o: Vec2) -> Double { (self - o).length }
    public func dot(_ o: Vec2) -> Double { x * o.x + y * o.y }
    public func cross(_ o: Vec2) -> Double { x * o.y - y * o.x }
    public func applying(_ t: CGAffineTransform) -> Vec2 { Vec2(cgPoint.applying(t)) }
}

/// An open or closed sequence of points (mm). Closed polylines do NOT repeat the first point.
public struct Polyline: Hashable, Codable, Sendable {
    public var points: [Vec2]
    public var isClosed: Bool

    public init(_ points: [Vec2], closed: Bool = false) {
        self.points = points
        self.isClosed = closed
    }

    /// Points to visit in order, including the closing point for closed polylines.
    public var traversal: [Vec2] {
        guard isClosed, let first = points.first, points.count > 1 else { return points }
        return points + [first]
    }

    public var length: Double {
        let p = traversal
        guard p.count > 1 else { return 0 }
        var total = 0.0
        for i in 1..<p.count { total += p[i - 1].distance(to: p[i]) }
        return total
    }

    public var bounds: Rect2? { Rect2(enclosing: points) }

    public func applying(_ t: CGAffineTransform) -> Polyline {
        Polyline(points.map { $0.applying(t) }, closed: isClosed)
    }
}

/// Axis-aligned rectangle in mm.
public struct Rect2: Hashable, Codable, Sendable {
    public var minX: Double, minY: Double, maxX: Double, maxY: Double

    public init(minX: Double, minY: Double, maxX: Double, maxY: Double) {
        self.minX = minX; self.minY = minY; self.maxX = maxX; self.maxY = maxY
    }

    public init?(enclosing points: [Vec2]) {
        guard let f = points.first else { return nil }
        var r = Rect2(minX: f.x, minY: f.y, maxX: f.x, maxY: f.y)
        for p in points.dropFirst() { r.include(p) }
        self = r
    }

    public var width: Double { maxX - minX }
    public var height: Double { maxY - minY }
    public var center: Vec2 { Vec2((minX + maxX) / 2, (minY + maxY) / 2) }
    public var cgRect: CGRect { CGRect(x: minX, y: minY, width: width, height: height) }

    public mutating func include(_ p: Vec2) {
        minX = min(minX, p.x); minY = min(minY, p.y)
        maxX = max(maxX, p.x); maxY = max(maxY, p.y)
    }

    public func union(_ o: Rect2) -> Rect2 {
        Rect2(minX: min(minX, o.minX), minY: min(minY, o.minY), maxX: max(maxX, o.maxX), maxY: max(maxY, o.maxY))
    }

    /// Closed rectangular outline (counter-clockwise), used e.g. for red-light framing.
    public var outline: Polyline {
        Polyline([Vec2(minX, minY), Vec2(maxX, minY), Vec2(maxX, maxY), Vec2(minX, maxY)], closed: true)
    }
}
