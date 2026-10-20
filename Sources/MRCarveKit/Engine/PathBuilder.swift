import Foundation
import CoreGraphics

/// Incremental path → polyline flattener shared by `PathFlattener`, `TextOutliner` and the importers.
///
/// Points passed to the drawing calls are in *local* coordinates; they are mapped through `transform`
/// before flattening, so the chord error bound `tolerance` holds in the output space (mm).
/// Béziers are transformed by their control points (exact for affine maps) and flattened adaptively;
/// elliptical arcs are sampled in local parameter space with a step derived from the transformed radius.
struct PathBuilder {
    /// Max chord error in output units.
    let tolerance: Double
    /// Local → output transform.
    var transform: CGAffineTransform = .identity

    private(set) var polylines: [Polyline] = []
    private var points: [Vec2] = []
    /// Current point and subpath start, in local coordinates.
    private(set) var current: Vec2 = .zero
    private(set) var subpathStart: Vec2 = .zero
    private var isOpen = false

    /// Consecutive output points closer than this are merged (mm).
    static let mergeDistance = 1e-7

    init(tolerance: Double, transform: CGAffineTransform = .identity) {
        self.tolerance = max(tolerance, 1e-6)
        self.transform = transform
    }

    // MARK: Drawing

    mutating func move(to p: Vec2) {
        flush(closed: false)
        current = p
        subpathStart = p
        points = [map(p)]
        isOpen = true
    }

    mutating func line(to p: Vec2) {
        beginIfNeeded()
        append(map(p))
        current = p
    }

    mutating func quad(_ c: Vec2, _ p: Vec2) {
        beginIfNeeded()
        let p0 = points.last ?? map(current), p1 = map(c), p2 = map(p)
        // Uniform sampling: error ≤ h²/8·|B''| with |B''| = 2|p0 − 2p1 + p2|.
        let dd = (p0 - p1 * 2 + p2).length
        let n = dd > 0 ? min(4096, max(1, Int((dd / (4 * tolerance)).squareRoot().rounded(.up)))) : 1
        if n > 1 {
            for i in 1..<n {
                let t = Double(i) / Double(n), mt = 1 - t
                append(p0 * (mt * mt) + p1 * (2 * mt * t) + p2 * (t * t))
            }
        }
        append(p2)
        current = p
    }

    mutating func cubic(_ c1: Vec2, _ c2: Vec2, _ p: Vec2) {
        beginIfNeeded()
        let p0 = points.last ?? map(current)
        subdivideCubic(p0, map(c1), map(c2), map(p), depth: 0)
        current = p
    }

    /// Elliptical arc in local coordinates: centre `c`, radii `rx`/`ry`, x-axis rotation `phi` (radians),
    /// from parameter angle `theta1` sweeping `delta` (radians, positive = counter-clockwise in local space).
    /// Starts a subpath at the arc start if none is open, otherwise connects to it with a line.
    /// `end`, when given, replaces the last sample to avoid drift (e.g. the SVG arc end point).
    mutating func arc(center c: Vec2, rx: Double, ry: Double, phi: Double, theta1: Double, delta: Double, end: Vec2? = nil) {
        let cosPhi = cos(phi), sinPhi = sin(phi)
        func point(_ t: Double) -> Vec2 {
            let x = rx * cos(t), y = ry * sin(t)
            return Vec2(c.x + x * cosPhi - y * sinPhi, c.y + x * sinPhi + y * cosPhi)
        }
        let start = point(theta1)
        if isOpen { line(to: start) } else { move(to: start) }
        let radius = max(abs(rx), abs(ry)) * Self.maxScale(transform)
        // Uniform parameter sampling of a curve with |C''| ≤ radius: chord error ≤ step²·radius/8.
        var step = radius > 0 ? (8 * tolerance / radius).squareRoot() : .pi / 2
        step = min(step, .pi / 8)
        var n = min(100_000, max(1, Int((abs(delta) / step).rounded(.up))))
        // Full turns: a multiple of 4 samples hits the axis extremes of axis-aligned ellipses exactly.
        if abs(delta) >= 2 * .pi - 1e-9 { n = (n + 3) / 4 * 4 }
        for i in 1...n {
            let q = (i == n) ? (end ?? point(theta1 + delta)) : point(theta1 + delta * Double(i) / Double(n))
            append(map(q))
            current = q
        }
    }

    /// Closes the current subpath; the next drawing call without `move(to:)` starts at the subpath start.
    mutating func close() {
        flush(closed: true)
        current = subpathStart
    }

    /// Ends the current subpath without closing it.
    mutating func endSubpath() {
        flush(closed: false)
    }

    /// Adds already finished polylines (e.g. drawn by another builder) to the output.
    mutating func appendFinished(_ extra: [Polyline]) {
        polylines += extra
    }

    /// Finishes the last subpath and returns all polylines.
    mutating func finish() -> [Polyline] {
        flush(closed: false)
        return polylines
    }

    // MARK: Helpers

    /// Largest singular value of the linear part of `t` (how much it can stretch a length).
    static func maxScale(_ t: CGAffineTransform) -> Double {
        let a = Double(t.a), b = Double(t.b), c = Double(t.c), d = Double(t.d)
        let s = a * a + b * b + c * c + d * d
        let det = a * d - b * c
        let disc = max(0, s * s - 4 * det * det)
        return ((s + disc.squareRoot()) / 2).squareRoot()
    }

    private func map(_ p: Vec2) -> Vec2 {
        let t = transform
        return Vec2(Double(t.a) * p.x + Double(t.c) * p.y + Double(t.tx),
                    Double(t.b) * p.x + Double(t.d) * p.y + Double(t.ty))
    }

    private mutating func beginIfNeeded() {
        if !isOpen {
            points = [map(current)]
            subpathStart = current
            isOpen = true
        }
    }

    private mutating func append(_ p: Vec2) {
        if let last = points.last, abs(last.x - p.x) <= Self.mergeDistance, abs(last.y - p.y) <= Self.mergeDistance { return }
        points.append(p)
    }

    /// Recursive de Casteljau subdivision until the curve is within `tolerance` of its chord
    /// (Willcocks' bound on the distance between the curve and the linearly parametrised chord).
    private mutating func subdivideCubic(_ p0: Vec2, _ p1: Vec2, _ p2: Vec2, _ p3: Vec2, depth: Int) {
        let ux = 3 * p1.x - 2 * p0.x - p3.x, uy = 3 * p1.y - 2 * p0.y - p3.y
        let vx = 3 * p2.x - 2 * p3.x - p0.x, vy = 3 * p2.y - 2 * p3.y - p0.y
        let flatness = max(ux * ux, vx * vx) + max(uy * uy, vy * vy)
        if depth >= 18 || !(flatness > 16 * tolerance * tolerance) {
            append(p3)
            return
        }
        let p01 = (p0 + p1) * 0.5, p12 = (p1 + p2) * 0.5, p23 = (p2 + p3) * 0.5
        let p012 = (p01 + p12) * 0.5, p123 = (p12 + p23) * 0.5
        let mid = (p012 + p123) * 0.5
        subdivideCubic(p0, p01, p012, mid, depth: depth + 1)
        subdivideCubic(mid, p123, p23, p3, depth: depth + 1)
    }

    private mutating func flush(closed: Bool) {
        defer { points = []; isOpen = false }
        guard isOpen else { return }
        var pts = points
        if closed, pts.count > 1, let f = pts.first, let l = pts.last,
           abs(f.x - l.x) <= Self.mergeDistance, abs(f.y - l.y) <= Self.mergeDistance {
            pts.removeLast()
        }
        guard pts.count >= 2 else { return }
        polylines.append(Polyline(pts, closed: closed))
    }
}

extension PathBuilder {
    /// Feeds every element of `path` into the builder (CGPath arcs are already cubic Béziers).
    mutating func append(_ path: CGPath) {
        var builder = self
        path.applyWithBlock { element in
            let e = element.pointee
            switch e.type {
            case .moveToPoint:
                builder.move(to: Vec2(e.points[0]))
            case .addLineToPoint:
                builder.line(to: Vec2(e.points[0]))
            case .addQuadCurveToPoint:
                builder.quad(Vec2(e.points[0]), Vec2(e.points[1]))
            case .addCurveToPoint:
                builder.cubic(Vec2(e.points[0]), Vec2(e.points[1]), Vec2(e.points[2]))
            case .closeSubpath:
                builder.close()
            @unknown default:
                break
            }
        }
        self = builder
    }
}
