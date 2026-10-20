import Foundation
import MRCarveKit

enum EngineHatchTests {
    static func layer(spacing: Double, angle: Double = 0) -> HatchLayer {
        var l = HatchLayer()
        l.spacing = spacing
        l.angle = angle
        return l
    }

    /// Every segment's midpoint and near-end points lie inside the even-odd region.
    static func allInside(_ lines: [Polyline], _ contours: [Polyline]) -> Bool {
        lines.allSatisfy { l in
            let a = l.points[0], b = l.points[1]
            return [0.5, 0.01, 0.99].allSatisfy { GeometryOps.contains(a + (b - a) * $0, in: contours) }
        }
    }

    static func register() {
        test("hatch: 10×10 square at 1 mm") {
            let sq = EngineTestKit.square(0, 0, 10)
            let lines = HatchFill.hatch([sq], layer: layer(spacing: 1))
            // Lines at y = 0…9: y = 10 touches only the top edge (half-open edges).
            expectEqual(lines.count, 10)
            expectEqual(lines.map { $0.points[0].y }, (0..<10).map(Double.init))
            for (i, l) in lines.enumerated() {
                expectEqual(l.points.count, 2)
                expectClose(l.length, 10, tolerance: 1e-9)
                // Zig-zag: even lines left→right, odd lines right→left.
                expect((l.points[1].x > l.points[0].x) == i.isMultiple(of: 2))
            }
            var even = layer(spacing: 1)
            even.evenDistribution = true
            expectEqual(HatchFill.hatch([sq], layer: even).map { $0.points[0].y }.sorted(), (0..<10).map { Double($0) + 0.5 })
            var offsets = layer(spacing: 1)
            offsets.startOffset = 0.25
            offsets.endOffset = 2
            expectEqual(HatchFill.hatch([sq], layer: offsets).map { $0.points[0].y }.sorted(),
                        (0..<8).map { Double($0) + 0.25 })
            var uni = layer(spacing: 1)
            uni.bidirectional = false
            expect(HatchFill.hatch([sq], layer: uni).allSatisfy { $0.points[1].x > $0.points[0].x })
        }

        test("hatch: ring with a hole") {
            let outer = EngineTestKit.square(0, 0, 10)
            let hole = Polyline(EngineTestKit.square(3, 3, 4).points.reversed(), closed: true)
            for contours in [[outer, hole], [hole, outer], [outer, EngineTestKit.square(3, 3, 4)]] {
                let lines = HatchFill.hatch(contours, layer: layer(spacing: 0.5))
                // 20 lines; the 8 crossing the hole (y = 3 … 6.5) are split in two 3 mm pieces.
                expectEqual(lines.count, 12 + 16)
                expectClose(EngineTestKit.totalLength(lines), 12 * 10 + 8 * 6, tolerance: 1e-9)
                expect(allInside(lines, contours))
            }
            // Bands on both sides of the hole are marked one after the other, not alternately.
            let lines = HatchFill.hatch([outer, hole], layer: layer(spacing: 0.5))
            let travel = GeometryOps.travelLength(lines, start: lines[0].points[0])
            expect(travel < 40, "travel \(travel)")
        }

        test("hatch: 45°, 90° and cross-hatch") {
            let sq = EngineTestKit.square(0, 0, 10)
            let lines = HatchFill.hatch([sq], layer: layer(spacing: 0.5, angle: 45))
            expect(!lines.isEmpty)
            let u = Vec2(1, 1) / 2.0.squareRoot(), n = Vec2(-u.y, u.x)
            for l in lines {
                let d = (l.points[1] - l.points[0]) / l.length
                expectClose(abs(d.dot(u)), 1, tolerance: 1e-9)
                for p in l.points { expect(EngineTestKit.distance(p, to: sq) < 1e-9) }  // ends on the outline
            }
            // Offsets across the hatch direction are 0.5 apart.
            let offsets = Set(lines.map { ($0.points[0].dot(n) * 1e6).rounded() / 1e6 }).sorted()
            for i in 1..<offsets.count { expectClose(offsets[i] - offsets[i - 1], 0.5, tolerance: 1e-6) }
            // Hatched length ≈ area / spacing.
            expectClose(EngineTestKit.totalLength(lines) * 0.5, 100, tolerance: 2)

            let vertical = HatchFill.hatch([sq], layer: layer(spacing: 1, angle: 90))
            expectEqual(vertical.count, 10)
            expect(vertical.allSatisfy { abs($0.points[0].x - $0.points[1].x) < 1e-9 })

            var cross = layer(spacing: 1)
            cross.crossHatch = true
            let both = HatchFill.hatch([sq], layer: cross)
            expectEqual(both.count, 20)
            expect(both.prefix(10).allSatisfy { abs($0.points[0].y - $0.points[1].y) < 1e-9 })
            expect(both.suffix(10).allSatisfy { abs($0.points[0].x - $0.points[1].x) < 1e-9 })
            // The second pass starts next to where the first one ended.
            expect(both[9].points[1].distance(to: both[10].points[0]) < 1.5)
        }

        test("hatch: vertex hits and concave shapes") {
            let diamond = Polyline([Vec2(0, -5), Vec2(5, 0), Vec2(0, 5), Vec2(-5, 0)], closed: true)
            var l = layer(spacing: 1)
            let lines = HatchFill.hatch([diamond], layer: l)
            // y = -5 is a single vertex (zero length, dropped); y = 5 is excluded.
            expectEqual(lines.count, 9)
            expect(lines.contains { abs($0.points[0].y) < 1e-12 && abs($0.length - 10) < 1e-9 })
            // "W"-like shape: local minimum vertex inside the scan range.
            let w = Polyline([Vec2(0, 0), Vec2(2, 0), Vec2(3, 2), Vec2(4, 0), Vec2(6, 0), Vec2(6, 4), Vec2(0, 4)], closed: true)
            l.spacing = 0.5
            let wl = HatchFill.hatch([w], layer: l)
            expect(allInside(wl, [w]))
            // Exact length: area / spacing with lines at 0, 0.5, … 3.5 (sample the width at each line).
            var expected = 0.0
            for k in 0..<8 {
                let y = Double(k) * 0.5
                expected += y < 2 ? 4 + y : 6  // the notch is 2 − y wide at height y < 2
            }
            expectClose(EngineTestKit.totalLength(wl), expected, tolerance: 1e-9)
        }

        test("hatch: border offset erodes and dilates exactly") {
            let sq = EngineTestKit.square(0, 0, 10)
            var l = layer(spacing: 0.5)
            l.borderOffset = 1
            let lines = HatchFill.hatch([sq], layer: l)
            expectEqual(lines.count, 17)  // y = 1, 1.5, … 9
            for line in lines {
                for p in line.points {
                    expect(p.x >= 1 - 1e-9 && p.x <= 9 + 1e-9 && p.y >= 1 - 1e-9 && p.y <= 9 + 1e-9)
                }
                expectClose(line.length, 8, tolerance: 1e-9)
            }
            // Ring: the hole grows by the offset too.
            let hole = EngineTestKit.square(3, 3, 4)
            let ring = HatchFill.hatch([sq, hole], layer: l)
            for line in ring {
                let a = line.points[0], b = line.points[1]
                for t in stride(from: 0.0, through: 1.0, by: 0.05) {
                    let p = a + (b - a) * t
                    expect(EngineTestKit.distance(p, to: sq) >= 1 - 1e-9 && EngineTestKit.distance(p, to: hole) >= 1 - 1e-9)
                }
            }
            // Rounded corners: near the corner, lines are shortened along a 1 mm arc around (3, 3).
            let corner = ring.filter { abs($0.points[0].y - 2.5) < 1e-9 }
            let reach = corner.flatMap(\.points).filter { $0.x > 2 && $0.x < 8 }.map(\.x)
            expectClose(reach.min() ?? 0, 3 - (1 - 0.25).squareRoot(), tolerance: 1e-9)
            // A shape thinner than twice the offset disappears.
            expect(HatchFill.hatch([Rect2(minX: 0, minY: 0, maxX: 10, maxY: 1.5).outline], layer: l).isEmpty)
            // Negative offset grows the square by 1 mm on all sides.
            l.borderOffset = -1
            let grown = HatchFill.hatch([sq], layer: l)
            let gb = GeometryOps.bounds(grown)!
            expectClose(gb.minX, -1, tolerance: 1e-9)
            expectClose(gb.maxX, 11, tolerance: 1e-9)
            expectClose(gb.minY, -1, tolerance: 1e-9)
        }

        test("hatch: glyphs with holes (O, A, B, é) and open polylines") {
            for letter in ["O", "A", "B", "é", "8"] {
                let contours = TextOutliner.polylines(text: letter, fontName: "Helvetica", height: 20)
                let lines = HatchFill.hatch(contours, layer: layer(spacing: 0.1, angle: 30))
                expect(!lines.isEmpty)
                expect(allInside(lines, contours), "\(letter): segment outside the glyph")
                let area = abs(contours.reduce(0) { $0 + GeometryOps.signedArea($1) })
                let hatched = EngineTestKit.totalLength(lines) * 0.1
                expect(abs(hatched - area) / area < 0.03, "\(letter): hatched \(hatched) vs area \(area)")
            }
            let open = Polyline([Vec2(0, 0), Vec2(10, 0), Vec2(10, 10), Vec2(0, 10)])
            expect(HatchFill.hatch([open], layer: layer(spacing: 1)).isEmpty)
            expect(HatchFill.hatch([EngineTestKit.square(0, 0, 10)], layer: layer(spacing: 0)).isEmpty)
            expect(HatchFill.hatch([], layer: layer(spacing: 1)).isEmpty)
        }

        test("hatch: concentric rings") {
            var l = layer(spacing: 0.5)
            l.pattern = .concentric
            let sq = EngineTestKit.square(0, 0, 10)
            let rings = HatchFill.hatch([sq], layer: l)
            // Insets 0.5 … 4.5 (5.0 is the centre point).
            expectEqual(rings.count, 9)
            expect(rings.allSatisfy(\.isClosed))
            for ring in rings {
                let d = ring.points.map { EngineTestKit.distance($0, to: sq) }
                let level = (d.max()! * 2).rounded() / 2
                expect(d.allSatisfy { abs($0 - level) < 0.05 }, "ring at \(level): \(d.min()!)…\(d.max()!)")
                let side = 10 - 2 * level
                expectClose(ring.length, 4 * side, tolerance: 0.1)
                expect(ring.points.count < 40, "not simplified: \(ring.points.count) points")
            }
            // borderOffset / startOffset shift the first ring.
            l.borderOffset = 1
            l.startOffset = 0.25
            let shifted = HatchFill.hatch([sq], layer: l)
            let outer = shifted.map { GeometryOps.bounds([$0])!.width }.max()!
            expectClose(outer, 10 - 2 * 1.75, tolerance: 0.05)

            // Ring with a hole: two loops per level (around the outline and around the hole).
            var r = layer(spacing: 0.4)
            r.pattern = .concentric
            let hole = EngineTestKit.square(3, 3, 4)
            let annulus = HatchFill.hatch([sq, hole], layer: r)
            // Levels 0.4, 0.8, 1.2 have two loops each; 1.6 survives only in the four corner pockets
            // (the widest points of the annulus are 1.757 mm from both outlines, on the diagonals).
            expectEqual(annulus.count, 10)
            for ring in annulus {
                for p in ring.points {
                    let d = min(EngineTestKit.distance(p, to: sq), EngineTestKit.distance(p, to: hole))
                    expect(abs(d - (d / 0.4).rounded() * 0.4) < 0.04 && d > 0.3)
                }
            }
            // Glyphs: rings stay inside, holes respected.
            for letter in ["O", "B"] {
                let contours = TextOutliner.polylines(text: letter, fontName: "Helvetica", height: 20)
                let glyphRings = HatchFill.hatch(contours, layer: r)
                expect(!glyphRings.isEmpty)
                expect(glyphRings.allSatisfy { $0.points.allSatisfy { GeometryOps.contains($0, in: contours) } }, letter)
            }
            expect(HatchFill.hatch([Polyline([Vec2(0, 0), Vec2(5, 0), Vec2(5, 5)])], layer: l).isEmpty)
            var dense = layer(spacing: 0.05)
            dense.pattern = .concentric
            let text = TextOutliner.polylines(text: "MR Carve", fontName: "Helvetica", height: 10)
            var out: [Polyline] = []
            let seconds = EngineTestKit.time { out = HatchFill.hatch(text, layer: dense) }
            print("    concentric: \(out.count) rings, \(out.reduce(0) { $0 + $1.points.count }) points in \(String(format: "%.3f", seconds)) s")
        }

        test("hatch: dense 70 mm field at 0.02 mm") {
            // 400 circles + text: a few hundred contours over the whole field.
            var contours: [Polyline] = []
            for i in 0..<20 {
                for j in 0..<20 {
                    contours.append(EngineTestKit.circle(Vec2(-33.25 + 3.5 * Double(i), -33.25 + 3.5 * Double(j)), 1.6, segments: 48))
                }
            }
            contours += TextOutliner.polylines(text: "MR Carve\nÉvry", fontName: "Helvetica", height: 12)
            contours.append(EngineTestKit.square(-35, -35, 70))
            var lines: [Polyline] = []
            let seconds = EngineTestKit.time { lines = HatchFill.hatch(contours, layer: layer(spacing: 0.02, angle: 15)) }
            print("    dense hatch: \(contours.count) contours, \(lines.count) lines in \(String(format: "%.3f", seconds)) s")
            expect(lines.count > 3000)
            expect(seconds < 10, "too slow: \(seconds) s")  // debug build; release is far below 1 s
        }
    }
}
