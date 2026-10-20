import Foundation
import CoreGraphics

/// Small geometry helpers on polyline sets (all in mm).
public enum GeometryOps {
    /// Joint bounds of all points, or nil when there are none.
    public static func bounds(_ polylines: [Polyline]) -> Rect2? {
        var r: Rect2?
        for p in polylines {
            for v in p.points {
                if r == nil { r = Rect2(minX: v.x, minY: v.y, maxX: v.x, maxY: v.y) } else { r!.include(v) }
            }
        }
        return r
    }

    /// Applies an affine transform to every point.
    public static func transformed(_ polylines: [Polyline], by t: CGAffineTransform) -> [Polyline] {
        polylines.map { $0.applying(t) }
    }

    /// Moves every point by `offset`.
    public static func translated(_ polylines: [Polyline], by offset: Vec2) -> [Polyline] {
        polylines.map { Polyline($0.points.map { $0 + offset }, closed: $0.isClosed) }
    }

    /// Transform mapping `source` into `target`: scaled to fit (uniformly when `keepAspect`) and centred.
    /// A degenerate source dimension is not scaled.
    public static func fitTransform(from source: Rect2, into target: Rect2, keepAspect: Bool = true) -> CGAffineTransform {
        var sx = source.width > 1e-12 ? target.width / source.width : 1
        var sy = source.height > 1e-12 ? target.height / source.height : 1
        if keepAspect {
            let s: Double
            switch (source.width > 1e-12, source.height > 1e-12) {
            case (true, true): s = min(sx, sy)
            case (true, false): s = sx
            case (false, true): s = sy
            case (false, false): s = 1
            }
            sx = s; sy = s
        }
        let c = source.center, d = target.center
        return CGAffineTransform(translationX: -c.x, y: -c.y)
            .concatenating(CGAffineTransform(scaleX: sx, y: sy))
            .concatenating(CGAffineTransform(translationX: d.x, y: d.y))
    }

    /// Scales and centres `polylines` into `target`.
    public static func fitted(_ polylines: [Polyline], into target: Rect2, keepAspect: Bool = true) -> [Polyline] {
        guard let b = bounds(polylines) else { return polylines }
        return transformed(polylines, by: fitTransform(from: b, into: target, keepAspect: keepAspect))
    }

    /// Signed area (positive = counter-clockwise, +Y up) of a polyline taken as closed.
    public static func signedArea(_ polyline: Polyline) -> Double {
        let p = polyline.points
        guard p.count >= 3 else { return 0 }
        var a = 0.0
        for i in 0..<p.count {
            let q = p[i], r = p[(i + 1) % p.count]
            a += q.x * r.y - r.x * q.y
        }
        return a / 2
    }

    /// Even-odd point-in-region test over the closed contours.
    public static func contains(_ point: Vec2, in contours: [Polyline]) -> Bool {
        var inside = false
        for c in contours where c.isClosed && c.points.count >= 3 {
            let p = c.points
            var j = p.count - 1
            for i in 0..<p.count {
                let a = p[i], b = p[j]
                if (a.y > point.y) != (b.y > point.y),
                   point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x {
                    inside.toggle()
                }
                j = i
            }
        }
        return inside
    }

    /// Ramer–Douglas–Peucker simplification keeping every point farther than `tolerance` from the result.
    public static func simplified(_ polyline: Polyline, tolerance: Double) -> Polyline {
        let pts = polyline.isClosed ? polyline.traversal : polyline.points
        guard pts.count > 2, tolerance > 0 else { return polyline }
        var keep = [Bool](repeating: false, count: pts.count)
        keep[0] = true; keep[pts.count - 1] = true
        var stack = [(0, pts.count - 1)]
        while let (lo, hi) = stack.popLast() {
            guard hi > lo + 1 else { continue }
            let a = pts[lo], b = pts[hi], d = b - a, len = d.length
            var worst = -1.0, index = lo
            for i in (lo + 1)..<hi {
                let dist = len > 0 ? abs(d.cross(pts[i] - a)) / len : pts[i].distance(to: a)
                if dist > worst { worst = dist; index = i }
            }
            if worst > tolerance {
                keep[index] = true
                stack.append((lo, index)); stack.append((index, hi))
            }
        }
        var out = zip(pts, keep).compactMap { $1 ? $0 : nil }
        if polyline.isClosed {
            out.removeLast()  // the repeated closing point
            if out.count < 3 { return polyline }
        }
        return Polyline(out, closed: polyline.isClosed)
    }

    /// Total laser-off travel to mark `polylines` in order, starting at `start`.
    public static func travelLength(_ polylines: [Polyline], start: Vec2 = .zero) -> Double {
        var p = start, total = 0.0
        for line in polylines {
            guard let first = line.points.first else { continue }
            total += p.distance(to: first)
            p = line.traversal.last ?? first
        }
        return total
    }
}
