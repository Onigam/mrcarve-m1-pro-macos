import Foundation
import CoreGraphics
import MRCarveKit

/// Helpers shared by the Engine*Tests suites.
enum EngineTestKit {
    /// Distance from `p` to the segment ab.
    static func distance(_ p: Vec2, _ a: Vec2, _ b: Vec2) -> Double {
        let d = b - a
        let l2 = d.dot(d)
        guard l2 > 0 else { return p.distance(to: a) }
        let t = max(0, min(1, (p - a).dot(d) / l2))
        return p.distance(to: a + d * t)
    }

    /// Distance from `p` to the polyline (closing edge included for closed polylines).
    static func distance(_ p: Vec2, to polyline: Polyline) -> Double {
        let pts = polyline.traversal
        guard pts.count > 1 else { return pts.first.map { p.distance(to: $0) } ?? .infinity }
        var best = Double.infinity
        for i in 1..<pts.count { best = min(best, distance(p, pts[i - 1], pts[i])) }
        return best
    }

    static func cubic(_ p0: Vec2, _ p1: Vec2, _ p2: Vec2, _ p3: Vec2, _ t: Double) -> Vec2 {
        let mt = 1 - t
        return p0 * (mt * mt * mt) + p1 * (3 * mt * mt * t) + p2 * (3 * mt * t * t) + p3 * (t * t * t)
    }

    static func square(_ x: Double, _ y: Double, _ size: Double) -> Polyline {
        Rect2(minX: x, minY: y, maxX: x + size, maxY: y + size).outline
    }

    static func circle(_ c: Vec2, _ r: Double, segments: Int = 64) -> Polyline {
        Polyline((0..<segments).map { i in
            let a = Double(i) / Double(segments) * 2 * .pi
            return Vec2(c.x + r * cos(a), c.y + r * sin(a))
        }, closed: true)
    }

    static func totalLength(_ lines: [Polyline]) -> Double { lines.reduce(0) { $0 + $1.length } }

    /// Seconds taken by `body`.
    static func time(_ body: () -> Void) -> Double {
        let t0 = DispatchTime.now().uptimeNanoseconds
        body()
        return Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e9
    }

    /// Deterministic pseudo-random numbers in [0, 1).
    struct LCG {
        var state: UInt64
        mutating func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53)
        }
    }
}

enum EngineGeometryTests {
    static func register() {
        test("geometry: bounds, translate, fit") {
            let lines = [Polyline([Vec2(1, 2), Vec2(3, 6)]), Polyline([Vec2(-1, 0)])]
            expectEqual(GeometryOps.bounds(lines), Rect2(minX: -1, minY: 0, maxX: 3, maxY: 6))
            expect(GeometryOps.bounds([]) == nil)
            let moved = GeometryOps.translated(lines, by: Vec2(1, 0))
            expectEqual(GeometryOps.bounds(moved), Rect2(minX: 0, minY: 0, maxX: 4, maxY: 6))
            let target = Rect2(minX: 0, minY: 0, maxX: 10, maxY: 10)
            let fitted = GeometryOps.bounds(GeometryOps.fitted(lines, into: target))!
            expectClose(fitted.height, 10, tolerance: 1e-9)
            expectClose(fitted.width, 4 * 10 / 6, tolerance: 1e-9)
            expectClose(fitted.center.x, 5, tolerance: 1e-9)
            let stretched = GeometryOps.bounds(GeometryOps.fitted(lines, into: target, keepAspect: false))!
            expectClose(stretched.width, 10, tolerance: 1e-9)
        }

        test("geometry: area, containment, simplification, travel") {
            let sq = EngineTestKit.square(0, 0, 10)
            expectClose(GeometryOps.signedArea(sq), 100)
            expectClose(GeometryOps.signedArea(Polyline(sq.points.reversed(), closed: true)), -100)
            let hole = EngineTestKit.square(3, 3, 4)
            expect(GeometryOps.contains(Vec2(1, 1), in: [sq, hole]))
            expect(!GeometryOps.contains(Vec2(5, 5), in: [sq, hole]))
            expect(!GeometryOps.contains(Vec2(11, 5), in: [sq, hole]))
            let wiggly = Polyline((0...100).map { Vec2(Double($0) * 0.1, sin(Double($0)) * 1e-4) })
            let simple = GeometryOps.simplified(wiggly, tolerance: 0.01)
            expectEqual(simple.points.count, 2)
            let simplifiedSquare = GeometryOps.simplified(
                Polyline([Vec2(0, 0), Vec2(5, 0), Vec2(10, 0), Vec2(10, 10), Vec2(0, 10)], closed: true), tolerance: 0.01)
            expectEqual(simplifiedSquare.points.count, 4)
            expect(simplifiedSquare.isClosed)
            let travel = GeometryOps.travelLength([Polyline([Vec2(1, 0), Vec2(2, 0)]), Polyline([Vec2(2, 3), Vec2(5, 3)])])
            expectClose(travel, 1 + 3)
        }
    }
}

enum EngineFlattenTests {
    static func register() {
        test("flatten: cubic stays within tolerance of the curve") {
            let p0 = Vec2(0, 0), p1 = Vec2(10, 30), p2 = Vec2(20, -30), p3 = Vec2(30, 0)
            for tol in [0.1, 0.01, 0.001] {
                let path = CGMutablePath()
                path.move(to: p0.cgPoint)
                path.addCurve(to: p3.cgPoint, control1: p1.cgPoint, control2: p2.cgPoint)
                let lines = PathFlattener.polylines(from: path, tolerance: tol)
                expectEqual(lines.count, 1)
                guard let line = lines.first else { continue }
                expect(!line.isClosed)
                expectEqual(line.points.first, p0)
                expectEqual(line.points.last, p3)
                var worst = 0.0
                for i in 0...2000 {
                    worst = max(worst, EngineTestKit.distance(EngineTestKit.cubic(p0, p1, p2, p3, Double(i) / 2000), to: line))
                }
                expect(worst <= tol, "chord error \(worst) > \(tol)")
                // Adaptive, not absurdly dense: within ~4x of the optimum for a curve of this size.
                expect(line.points.count < Int(400 / tol.squareRoot()), "too many points: \(line.points.count)")
            }
        }

        test("flatten: quadratic and circle error bound") {
            let path = CGMutablePath()
            path.move(to: CGPoint(x: 0, y: 0))
            path.addQuadCurve(to: CGPoint(x: 20, y: 0), control: CGPoint(x: 10, y: 20))
            let quad = PathFlattener.polylines(from: path, tolerance: 0.005)[0]
            var worst = 0.0
            for i in 0...1000 {
                let t = Double(i) / 1000, mt = 1 - t
                let p = Vec2(0, 0) * (mt * mt) + Vec2(10, 20) * (2 * mt * t) + Vec2(20, 0) * (t * t)
                worst = max(worst, EngineTestKit.distance(p, to: quad))
            }
            expect(worst <= 0.005, "quad error \(worst)")

            let circle = CGPath(ellipseIn: CGRect(x: -10, y: -10, width: 20, height: 20), transform: nil)
            let lines = PathFlattener.polylines(from: circle, tolerance: 0.01)
            expectEqual(lines.count, 1)
            expect(lines[0].isClosed)
            // Vertices lie on the Bézier approximation (≤ 0.03 % off the true circle).
            for p in lines[0].points { expectClose(p.length, 10, tolerance: 0.004) }
            // Edge midpoints are within tolerance (+ the Bézier circle error).
            let t = lines[0].traversal
            for i in 1..<t.count { expect(10 - ((t[i - 1] + t[i]) * 0.5).length <= 0.01 + 0.004) }
        }

        test("flatten: subpaths, closing and degenerate points") {
            let path = CGMutablePath()
            path.addRect(CGRect(x: 0, y: 0, width: 10, height: 5))
            path.move(to: CGPoint(x: 20, y: 0))
            path.addLine(to: CGPoint(x: 20, y: 0))     // duplicate
            path.addLine(to: CGPoint(x: 30, y: 0))
            path.addLine(to: CGPoint(x: 30, y: 10))
            path.move(to: CGPoint(x: 50, y: 50))       // lone moveto: dropped
            path.move(to: CGPoint(x: 40, y: 0))
            path.addLine(to: CGPoint(x: 45, y: 0))
            path.addLine(to: CGPoint(x: 40, y: 0))     // explicit return to start, then close
            path.closeSubpath()
            path.addLine(to: CGPoint(x: 40, y: 7))     // after close: new subpath from the start point
            let lines = PathFlattener.polylines(from: path)
            expectEqual(lines.map(\.isClosed), [true, false, true, false])
            expectEqual(lines.map(\.points.count), [4, 3, 2, 2])
            expectEqual(lines[0].length, 30)
            expectEqual(lines[3].points.first, Vec2(40, 0))
            expect(PathFlattener.polylines(from: CGMutablePath()).isEmpty)
        }
    }
}
