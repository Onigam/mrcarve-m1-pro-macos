import Foundation
import MRCarveKit

enum EngineOptimizerTests {
    static func randomSegments(_ count: Int, seed: UInt64, size: Double = 70) -> [Polyline] {
        var rng = EngineTestKit.LCG(state: seed)
        return (0..<count).map { _ in
            let a = Vec2(rng.next() * size - size / 2, rng.next() * size - size / 2)
            let b = a + Vec2(rng.next() - 0.5, rng.next() - 0.5) * 4
            return Polyline([a, b])
        }
    }

    /// True when `output` is a permutation of `input` up to reversal of open and rotation of closed polylines.
    static func isRearrangement(_ output: [Polyline], of input: [Polyline]) -> Bool {
        guard output.count == input.count else { return false }
        func key(_ p: Polyline) -> [Vec2] {
            if p.isClosed {
                guard let start = p.points.indices.min(by: { (p.points[$0].x, p.points[$0].y) < (p.points[$1].x, p.points[$1].y) })
                else { return [] }
                return Array(p.points[start...] + p.points[..<start])
            }
            let r = Array(p.points.reversed())
            return (p.points.first.map { ($0.x, $0.y) } ?? (0, 0)) <= (r.first.map { ($0.x, $0.y) } ?? (0, 0)) ? p.points : r
        }
        let a = output.map(key).map { $0.map(\.description).joined(separator: ";") }.sorted()
        let b = input.map(key).map { $0.map(\.description).joined(separator: ";") }.sorted()
        return a == b
    }

    static func register() {
        test("optimizer: reduces travel and keeps every polyline") {
            let input = randomSegments(2000, seed: 42)
            let output = PathOptimizer.order(input, start: .zero)
            expect(isRearrangement(output, of: input))
            let before = GeometryOps.travelLength(input), after = GeometryOps.travelLength(output)
            expect(after < before * 0.1, "travel \(before) → \(after)")
            let fixed = PathOptimizer.order(input, start: .zero, allowReverse: false)
            expect(Set(fixed.map { $0.points.description }) == Set(input.map { $0.points.description }))
            expect(GeometryOps.travelLength(fixed) < before * 0.15)
        }

        test("optimizer: reversal, start point and closed rotation") {
            let a = Polyline([Vec2(0, 0), Vec2(10, 0)])
            let b = Polyline([Vec2(20, 0), Vec2(11, 0)])
            let c = Polyline([Vec2(50, 50), Vec2(60, 50)])
            let out = PathOptimizer.order([c, b, a], start: Vec2(-1, 0))
            expectEqual(out, [a, Polyline([Vec2(11, 0), Vec2(20, 0)]), c])
            let noReverse = PathOptimizer.order([c, b, a], start: Vec2(-1, 0), allowReverse: false)
            expectEqual(noReverse.first, a)
            expect(noReverse.contains(b))

            let square = EngineTestKit.square(0, 0, 10)  // (0,0) (10,0) (10,10) (0,10)
            let rotated = PathOptimizer.order([square], start: Vec2(11, 11))
            expectEqual(rotated, [Polyline([Vec2(10, 10), Vec2(0, 10), Vec2(0, 0), Vec2(10, 0)], closed: true)])
            let empty = Polyline([])
            let withEmpty = PathOptimizer.order([empty, a, c], start: .zero)
            expectEqual(withEmpty, [a, c, empty])
            expectEqual(PathOptimizer.order([], start: .zero), [])
            expectEqual(PathOptimizer.order([b]), [b])  // single open polyline is returned as is
        }

        test("optimizer: start far outside, duplicates and clusters") {
            var input = randomSegments(300, seed: 7, size: 10)
            input += randomSegments(300, seed: 8, size: 10).map { $0.applying(.init(translationX: 1000, y: 1000)) }
            input += Array(repeating: Polyline([Vec2(5, 5), Vec2(6, 5)]), count: 20)
            let out = PathOptimizer.order(input, start: Vec2(-5000, 300))
            expect(isRearrangement(out, of: input))
            // Visits one cluster completely before the other: exactly one long jump between them.
            var longJumps = 0
            for i in 1..<out.count where out[i - 1].points.last!.distance(to: out[i].points[0]) > 500 { longJumps += 1 }
            expectEqual(longJumps, 1)
        }

        test("optimizer: 20k segments") {
            let input = randomSegments(20_000, seed: 1)
            var output: [Polyline] = []
            let seconds = EngineTestKit.time { output = PathOptimizer.order(input) }
            print("    optimizer: 20000 segments in \(String(format: "%.3f", seconds)) s, travel \(Int(GeometryOps.travelLength(input))) → \(Int(GeometryOps.travelLength(output))) mm")
            expectEqual(output.count, input.count)
            expect(seconds < 5, "too slow: \(seconds) s")  // debug build
        }
    }
}
