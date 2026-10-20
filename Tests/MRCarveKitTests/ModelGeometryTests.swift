import Foundation
import MRCarveKit

enum ModelGeometryTests {
    static func bounds(_ polylines: [Polyline]) -> Rect2? {
        polylines.compactMap(\.bounds).reduce(nil) { $0?.union($1) ?? $1 }
    }

    static func expectRect(_ r: Rect2?, _ e: Rect2, tolerance: Double = 1e-6, file: StaticString = #fileID, line: UInt = #line) {
        guard let r else { expect(false, "no bounds", file: file, line: line); return }
        expectClose(r.minX, e.minX, tolerance: tolerance, file: file, line: line)
        expectClose(r.minY, e.minY, tolerance: tolerance, file: file, line: line)
        expectClose(r.maxX, e.maxX, tolerance: tolerance, file: file, line: line)
        expectClose(r.maxY, e.maxY, tolerance: tolerance, file: file, line: line)
    }

    static func register() {
        test("model: rectangle outline in field coordinates") {
            let rect = DesignObject.rectangle(Rect2(minX: 0, minY: 3, maxX: 10, maxY: 7))
            let outline = rect.outlines()
            expectEqual(outline.count, 1)
            expect(outline[0].isClosed)
            expectEqual(outline[0].points.count, 4)
            expectRect(bounds(outline), Rect2(minX: 0, minY: 3, maxX: 10, maxY: 7))
            expectClose(outline[0].length, 28)
        }

        test("model: rotation and mirroring") {
            var rect = DesignObject.rectangle(Rect2(minX: -5, minY: -2, maxX: 5, maxY: 2))
            rect.placement.rotation = 90
            expectRect(bounds(rect.outlines()), Rect2(minX: -2, minY: -5, maxX: 2, maxY: 5))
            expectRect(rect.placement.boundingBox, Rect2(minX: -2, minY: -5, maxX: 2, maxY: 5))

            // Right triangle with its right angle at the bottom-left; mirroring X moves it to the bottom-right.
            var tri = DesignObject.vector([Polyline([Vec2(0, 0), Vec2(4, 0), Vec2(0, 2)], closed: true)], sourceName: "t")
            expectClose(tri.placement.width, 4)
            expectClose(tri.placement.height, 2)
            tri.placement.center = Vec2(10, 10)
            expect(tri.outlines()[0].points.contains { $0.distance(to: Vec2(8, 9)) < 1e-9 })
            tri.placement.mirrorX = true
            expect(tri.outlines()[0].points.contains { $0.distance(to: Vec2(12, 9)) < 1e-9 })
            expect(tri.outlines()[0].points.contains { $0.distance(to: Vec2(12, 11)) < 1e-9 })
            // localPoint inverts the transform.
            let p = tri.placement.localPoint(Vec2(12, 11))
            expectClose(p.x, -2)
            expectClose(p.y, 1)
        }

        test("model: rounded rectangle stays inside its box") {
            let rect = DesignObject.rectangle(Rect2(minX: -10, minY: -5, maxX: 10, maxY: 5), cornerRadius: 3)
            let outline = rect.outlines(tolerance: 0.01)[0]
            expect(outline.points.count > 8)
            expectRect(outline.bounds, Rect2(minX: -10, minY: -5, maxX: 10, maxY: 5), tolerance: 1e-9)
            // Perimeter of a rounded rectangle: 2(w + h) - 8r + 2πr.
            expectClose(outline.length, 60 - 24 + 2 * .pi * 3, tolerance: 0.05)
            // The radius is clamped to half the short side (a stadium).
            let pill = DesignObject.rectangle(Rect2(minX: -10, minY: -5, maxX: 10, maxY: 5), cornerRadius: 50).outlines()[0]
            expectRect(pill.bounds, Rect2(minX: -10, minY: -5, maxX: 10, maxY: 5), tolerance: 1e-9)
        }

        test("model: ellipse respects chord tolerance") {
            let e = DesignObject.ellipse(Rect2(minX: -10, minY: -10, maxX: 10, maxY: 10))
            let outline = e.outlines(tolerance: 0.01)[0]
            expect(outline.isClosed)
            for p in outline.points { expectClose(p.length, 10, tolerance: 1e-9) }
            // Mid-chord points must be within tolerance of the circle.
            let pts = outline.traversal
            for i in 1..<pts.count { expect(10 - ((pts[i - 1] + pts[i]) / 2).length <= 0.0101) }
            expectRect(outline.bounds, Rect2(minX: -10, minY: -10, maxX: 10, maxY: 10), tolerance: 0.01)
        }

        test("model: polygon and star fill their box") {
            let star = DesignObject.polygon(Rect2(minX: 0, minY: 0, maxX: 20, maxY: 10), sides: 5, starRatio: 0.5)
            let outline = star.outlines()[0]
            expectEqual(outline.points.count, 10)
            expectRect(outline.bounds, Rect2(minX: 0, minY: 0, maxX: 20, maxY: 10), tolerance: 1e-9)
            let tri = DesignObject.polygon(Rect2(minX: -1, minY: -1, maxX: 1, maxY: 1), sides: 2)
            expectEqual(tri.outlines()[0].points.count, 3)  // clamped to 3 sides
        }

        test("model: line from two points") {
            let line = DesignObject.line(from: Vec2(-3, -4), to: Vec2(3, 4))
            let outline = line.outlines()
            expectEqual(outline.count, 1)
            expect(!outline[0].isClosed)
            expectClose(outline[0].length, 10)
            expectClose(line.placement.rotation, atan2(8.0, 6.0) * 180 / .pi)
            expectRect(bounds(outline), Rect2(minX: -3, minY: -4, maxX: 3, maxY: 4))
        }

        test("model: vector import is fitted into its placement") {
            var v = DesignObject.vector([Polyline([Vec2(0, 0), Vec2(10, 0)]), Polyline([Vec2(0, 5), Vec2(10, 5)])],
                                        sourceName: "lines.svg", at: Vec2(1, 1))
            expectRect(v.fieldBounds(), Rect2(minX: -4, minY: -1.5, maxX: 6, maxY: 3.5))
            v.placement.width = 20
            v.placement.height = 2.5
            expectRect(bounds(v.outlines()), Rect2(minX: -9, minY: -0.25, maxX: 11, maxY: 2.25))
        }

        test("model: image frame and text fallback size") {
            let img = DesignObject.image(try ImageContent(imageData: ModelProjectTests.tinyPNG()), longestSide: 40)
            expectClose(img.placement.width, 40)
            expectClose(img.placement.height, 20)
            expectRect(bounds(img.outlines()), Rect2(minX: -20, minY: -10, maxX: 20, maxY: 10))

            let text = DesignObject.text("ABC", content: TextContent(string: "", height: 10))
            expect(text.placement.width > 0 && text.placement.height > 0)
            expect(text.kind.isText)
        }
    }
}
