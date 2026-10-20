import Foundation
import MRCarveKit

enum EngineImportTests {
    static func svg(_ body: String, root: String = #"width="100mm" height="100mm" viewBox="0 0 100 100""#) throws -> [Polyline] {
        let doc = #"<?xml version="1.0"?><svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" "#
            + root + ">" + body + "</svg>"
        return try VectorImporter.load(data: Data(doc.utf8), fileExtension: "svg")
    }

    static func size(_ p: [Polyline]) -> (Double, Double) {
        let b = GeometryOps.bounds(p)!
        return (b.width, b.height)
    }

    /// DXF text from (code, value) pairs.
    static func dxf(_ entities: [(Int, String)], header: [(Int, String)] = [], tables: [(Int, String)] = [],
                    blocks: [(Int, String)] = []) throws -> [Polyline] {
        var pairs: [(Int, String)] = []
        if !header.isEmpty { pairs += [(0, "SECTION"), (2, "HEADER")] + header + [(0, "ENDSEC")] }
        if !tables.isEmpty { pairs += [(0, "SECTION"), (2, "TABLES")] + tables + [(0, "ENDSEC")] }
        if !blocks.isEmpty { pairs += [(0, "SECTION"), (2, "BLOCKS")] + blocks + [(0, "ENDSEC")] }
        pairs += [(0, "SECTION"), (2, "ENTITIES")] + entities + [(0, "ENDSEC"), (0, "EOF")]
        let text = pairs.map { "  \($0.0)\r\n\($0.1)" }.joined(separator: "\r\n") + "\r\n"
        return try VectorImporter.load(data: Data(text.utf8), fileExtension: "DXF")
    }

    static func register() {
        test("svg: units, viewBox and Y flip") {
            var p = try svg(#"<rect x="0" y="0" width="200" height="100"/>"#,
                            root: #"width="100mm" height="50mm" viewBox="0 0 200 100""#)
            expectClose(size(p).0, 100, tolerance: 1e-9); expectClose(size(p).1, 50, tolerance: 1e-9)
            p = try svg(#"<rect width="96" height="48"/>"#, root: #"width="96" height="96""#)
            expectClose(size(p).0, 25.4, tolerance: 1e-9); expectClose(size(p).1, 12.7, tolerance: 1e-9)
            p = try svg(#"<rect width="10" height="10"/>"#, root: #"width="1in" height="1in" viewBox="0 0 10 10""#)
            expectClose(size(p).0, 25.4, tolerance: 1e-9)
            p = try svg(#"<rect width="10" height="10"/>"#, root: #"width="72pt" height="2.54cm" viewBox="0 0 10 10""#)
            expectClose(size(p).0, 25.4, tolerance: 1e-9)
            p = try svg(#"<rect width="10mm" height="1cm"/>"#, root: "")  // absolute units in content
            expectClose(size(p).0, 10, tolerance: 1e-9); expectClose(size(p).1, 10, tolerance: 1e-9)
            p = try svg(#"<rect width="10" height="10"/>"#, root: #"viewBox="0 0 10 10""#)  // no size: px
            expectClose(size(p).0, 10 * 25.4 / 96, tolerance: 1e-9)
            // preserveAspectRatio meet keeps the aspect, none stretches.
            p = try svg(#"<rect width="10" height="10"/>"#, root: #"width="40mm" height="20mm" viewBox="0 0 10 10""#)
            expectClose(size(p).0, 20, tolerance: 1e-9)
            p = try svg(#"<rect width="10" height="10"/>"#,
                        root: #"width="40mm" height="20mm" viewBox="0 0 10 10" preserveAspectRatio="none""#)
            expectClose(size(p).0, 40, tolerance: 1e-9); expectClose(size(p).1, 20, tolerance: 1e-9)
            // y down in SVG → y up; bounds min at the origin.
            p = try svg(#"<line x1="10" y1="10" x2="20" y2="30"/>"#)
            expectEqual(p.count, 1)
            expect(p[0].points[0].distance(to: Vec2(0, 20)) < 1e-9 && p[0].points[1].distance(to: Vec2(10, 0)) < 1e-9)
        }

        test("svg: path grammar") {
            // Relative commands, H/V, implicit repeats, compact numbers and exponents.
            var p = try svg(#"<path d="M10,10 h10 v1e1 H10 z m 30 0 l 5 0 5 5 L60-5.5.5-5"/>"#)
            expectEqual(p.count, 2)
            expect(p[0].isClosed && p[0].points.count == 4)
            expectClose(p[0].length, 40, tolerance: 1e-9)
            expect(!p[1].isClosed)
            expectEqual(p[1].points.count, 5)
            // M with several pairs = moveto + implicit linetos.
            p = try svg(#"<path d="M0 0 10 0 10 10"/>"#)
            expectEqual(p[0].points.count, 3)
            p = try svg(#"<path d="m0 0 10 0 0 10z"/>"#)
            expect(p[0].isClosed)
            expectClose(p[0].length, 10 + 10 + 200.0.squareRoot(), tolerance: 1e-9)
            // Smooth curves: S reflects the previous control point (symmetric S-curve).
            p = try svg(#"<path d="M0 0 C 0 10 10 10 10 0 S 20 -10 20 0"/>"#)
            let b = GeometryOps.bounds(p)!
            expectClose(b.height, 2 * 7.5, tolerance: 0.02)  // each lobe peaks at 3/4 of the control height
            // Quadratic + T.
            p = try svg(#"<path d="M0 0 Q 10 20 20 0 T 40 0"/>"#)
            expectClose(GeometryOps.bounds(p)!.height, 20, tolerance: 0.02)  // two lobes of height 10
            // Errors stop parsing but keep what came before.
            p = try svg(#"<path d="M0 0 L10 0 L 20 oops 30 0"/>"#)
            expectEqual(p[0].points.count, 2)
        }

        test("svg: arcs") {
            // Semicircle of radius 10 around (10, 0), bulging up on screen = +Y after the flip.
            var p = try svg(#"<path d="M0 50 A10 10 0 0 1 20 50"/>"#)
            var b = GeometryOps.bounds(p)!
            expectClose(b.width, 20, tolerance: 1e-6)
            expectClose(b.height, 10, tolerance: 0.011)
            let centre = Vec2(10, 0)
            for q in p[0].points { expectClose(q.distance(to: centre), 10, tolerance: 1e-9) }
            expectClose(p[0].length, .pi * 10, tolerance: 0.02)
            expect(p[0].points[1].y > 0)
            // Radii too small are scaled up (same semicircle); sweep 0 bulges the other way.
            p = try svg(#"<path d="M0 50 a1 1 0 0 0 20 0"/>"#)
            expectClose(p[0].length, .pi * 10, tolerance: 0.02)
            // Large-arc flag: 270° of a radius-10 circle; flags without separators.
            for d in ["M0 0 A10 10 0 1 1 10 10", "M0 0 A10 10 0 1 0 10 10", "M0 0A10 10 0 1110 10"] {
                p = try svg(#"<path d=""# + d + #""/>"#)
                expectClose(p[0].length, 1.5 * .pi * 10, tolerance: 0.03)
            }
            // Rotated elliptical arc keeps its radii: full ellipse from two arcs.
            p = try svg(#"<path d="M-10 0 A10 5 0 1 0 10 0 A10 5 0 1 0 -10 0Z" transform="translate(50 50) rotate(30)"/>"#)
            expect(p[0].isClosed)
            b = GeometryOps.bounds(p)!
            let c = b.center
            let radii = p[0].points.map { $0.distance(to: c) }
            expectClose(radii.max()!, 10, tolerance: 0.02)
            expectClose(radii.min()!, 5, tolerance: 0.02)
            expectClose(b.width, 2 * (100 * 0.75 + 25 * 0.25).squareRoot(), tolerance: 0.02)  // rotated by 30°
            // Zero radius → straight line.
            p = try svg(#"<path d="M0 0 A0 5 0 0 1 10 0"/>"#)
            expectEqual(p[0].points.count, 2)
        }

        test("svg: transforms and nested viewports") {
            // Reference line at the origin keeps the normalisation from hiding offsets.
            // Coordinates relative to a reference line at the SVG origin (the importer normalises bounds).
            let ref = #"<line x1="0" y1="0" x2="1" y2="0"/>"#
            func relative(_ p: [Polyline]) -> [Polyline] { GeometryOps.translated(Array(p.dropFirst()), by: Vec2(0, 0) - p[0].points[0]) }
            func near(_ a: Rect2, _ b: Rect2) -> Bool {
                abs(a.minX - b.minX) < 1e-9 && abs(a.minY - b.minY) < 1e-9 && abs(a.maxX - b.maxX) < 1e-9 && abs(a.maxY - b.maxY) < 1e-9
            }
            var p = relative(try svg(ref + #"<g transform="translate(10,0) scale(2)"><rect width="5" height="5"/></g>"#))
            expect(near(GeometryOps.bounds(p)!, Rect2(minX: 10, minY: -10, maxX: 20, maxY: 0)))
            // List order: translate is applied after rotate.
            p = relative(try svg(ref + #"<line x1="5" y1="0" x2="6" y2="0" transform="translate(10 0) rotate(90)"/>"#))
            expect(p[0].points[0].distance(to: Vec2(10, -5)) < 1e-9)
            p = relative(try svg(ref + #"<g transform="matrix(1 0 0 1 3 4)"><g transform="rotate(90 5 5)"><line x1="0" y1="5" x2="1" y2="5"/></g></g>"#))
            expect(p[0].points[0].distance(to: Vec2(8, -4)) < 1e-9)
            p = relative(try svg(ref + #"<rect width="10" height="10" transform="skewX(45)"/>"#))
            expectClose(GeometryOps.bounds(p)!.width, 20, tolerance: 1e-9)
            // Nested <svg> viewport with its own viewBox.
            p = relative(try svg(ref + #"<svg x="10" y="10" width="20" height="20" viewBox="0 0 10 10"><rect width="10" height="10"/></svg>"#))
            expect(near(GeometryOps.bounds(p)!, Rect2(minX: 10, minY: -30, maxX: 30, maxY: -10)))
            // use + defs.
            let used = try svg(ref + ##"<defs><rect id="r" width="5" height="5"/></defs><use xlink:href="#r" x="10"/><use href="#r" y="10"/>"##)
            expectEqual(used.count, 3)
        }

        test("svg: shapes and skipped content") {
            var p = try svg(#"<circle cx="50" cy="50" r="5"/><ellipse cx="0" cy="0" rx="10" ry="4"/>"#)
            expectEqual(p.count, 2)
            expect(p.allSatisfy(\.isClosed))
            let circleCentre = GeometryOps.bounds([p[0]])!.center
            for q in p[0].points { expectClose(q.distance(to: circleCentre), 5, tolerance: 1e-9) }
            let e = GeometryOps.bounds([p[1]])!
            expectClose(e.width, 20, tolerance: 1e-9); expectClose(e.height, 8, tolerance: 1e-9)
            p = try svg(#"<rect width="20" height="10" rx="2"/>"#)
            let roundedPerimeter: Double = 60 - 16 + 4 * Double.pi  // 2(w + h) − 8r + 2πr
            expectClose(p[0].length, roundedPerimeter, tolerance: 0.03)  // chords are slightly short
            p = try svg(#"<polyline points="0,0 10,0 10,10"/><polygon points="20 0 30 0 30 10"/>"#)
            expectEqual(p.map(\.isClosed), [false, true])
            p = try svg(#"""
                <rect width="1" height="1"/>
                <rect width="5" height="5" display="none"/>
                <g style="display:none"><rect width="50" height="50"/></g>
                <rect width="6" height="6" visibility="hidden"/>
                <g visibility="hidden"><rect width="7" height="7" visibility="visible"/></g>
                <defs><rect width="60" height="60"/></defs>
                <clipPath><rect width="70" height="70"/></clipPath>
                <mask><rect width="80" height="80"/></mask>
                <text x="0" y="0">Hello</text>
                <symbol id="s"><rect width="90" height="90"/></symbol>
                """#)
            expectEqual(p.count, 2)
            expectEqual(size(p).0, 7)
            do {
                _ = try VectorImporter.load(data: Data("<svg><rect".utf8), fileExtension: "svg")
                expect(false, "unterminated XML should fail")
            } catch {}
            do {
                _ = try VectorImporter.load(data: Data("<html/>".utf8), fileExtension: "svg")
                expect(false, "non-SVG root should fail")
            } catch {}
            do {
                _ = try VectorImporter.load(data: Data(), fileExtension: "ai")
                expect(false, "unsupported extension should fail")
            } catch VectorImportError.unsupported {} catch { expect(false, "wrong error \(error)") }
            expect(VectorImporter.supportedExtensions.contains("dxf"))
        }

        test("dxf: lines, polylines with bulges, units") {
            var p = try dxf([(0, "LINE"), (8, "0"), (10, "0"), (20, "0"), (11, "1"), (21, "0")],
                            header: [(9, "$INSUNITS"), (70, "1")])
            expectClose(p[0].length, 25.4, tolerance: 1e-9)
            // Closed LWPOLYLINE 10×10 whose top edge is a semicircle (bulge 1 = 180°, counter-clockwise).
            p = try dxf([(0, "LWPOLYLINE"), (90, "4"), (70, "1"),
                         (10, "0"), (20, "0"), (10, "10"), (20, "0"), (10, "10"), (20, "10"), (42, "1"), (10, "0"), (20, "10")])
            expectEqual(p.count, 1)
            expect(p[0].isClosed)
            expectClose(p[0].length, 30 + .pi * 5, tolerance: 0.02)
            // CCW bulge from (10,10) to (0,10) bulges upwards.
            expectClose(GeometryOps.bounds(p)!.height, 15, tolerance: 0.01)
            // Old-style POLYLINE + VERTEX + SEQEND.
            p = try dxf([(0, "POLYLINE"), (66, "1"), (70, "1"),
                         (0, "VERTEX"), (10, "0"), (20, "0"), (0, "VERTEX"), (10, "4"), (20, "0"),
                         (0, "VERTEX"), (10, "0"), (20, "3"), (0, "SEQEND"),
                         (0, "LINE"), (10, "0"), (20, "0"), (11, "0"), (21, "-1")])
            expectEqual(p.count, 2)
            expect(p[0].isClosed)
            expectClose(p[0].length, 12, tolerance: 1e-9)
        }

        test("dxf: circles, arcs, ellipses, splines") {
            var p = try dxf([(0, "CIRCLE"), (10, "5"), (20, "5"), (40, "5"),
                             (0, "ARC"), (10, "0"), (20, "0"), (40, "10"), (50, "0"), (51, "90")])
            expectEqual(p.count, 2)
            expect(p[0].isClosed)
            // After normalisation the circle centre is at (5 + 0, 5 + 0) − min: arc spans x 0…10 → min (0, 0).
            let cc = GeometryOps.bounds([p[0]])!.center
            for q in p[0].points { expectClose(q.distance(to: cc), 5, tolerance: 1e-9) }
            expect(!p[1].isClosed)
            expectClose(p[1].length, .pi * 5, tolerance: 0.02)
            // Arc across 0°: 350° → 10°.
            p = try dxf([(0, "ARC"), (10, "0"), (20, "0"), (40, "10"), (50, "350"), (51, "10")])
            expectClose(p[0].length, 20.0 / 180 * .pi * 10, tolerance: 0.01)
            // Full ellipse, major axis along X (length 10), ratio 0.5.
            p = try dxf([(0, "ELLIPSE"), (10, "0"), (20, "0"), (11, "10"), (21, "0"), (40, "0.5"), (41, "0"), (42, "6.283185307179586")])
            expect(p[0].isClosed)
            expectClose(size(p).0, 20, tolerance: 1e-6); expectClose(size(p).1, 10, tolerance: 1e-6)
            // Cubic B-spline with 4 control points and a clamped knot vector = one Bézier segment.
            let ctrl = [Vec2(0, 0), Vec2(10, 30), Vec2(20, -30), Vec2(30, 0)]
            var pairs: [(Int, String)] = [(0, "SPLINE"), (70, "8"), (71, "3"), (72, "8"), (73, "4")]
            pairs += ["0", "0", "0", "0", "1", "1", "1", "1"].map { (40, $0) }
            for c in ctrl { pairs += [(10, "\(c.x)"), (20, "\(c.y)"), (30, "0")] }
            p = try dxf(pairs)
            let offset = GeometryOps.bounds(p)!
            var curveMin = Vec2(Double.infinity, Double.infinity)
            for i in 0...1000 {
                let q = EngineTestKit.cubic(ctrl[0], ctrl[1], ctrl[2], ctrl[3], Double(i) / 1000)
                curveMin = Vec2(min(curveMin.x, q.x), min(curveMin.y, q.y))
            }
            let shift = Vec2(offset.minX, offset.minY) - curveMin
            var worst = 0.0
            for i in 0...1000 {
                let q = EngineTestKit.cubic(ctrl[0], ctrl[1], ctrl[2], ctrl[3], Double(i) / 1000) + shift
                worst = max(worst, EngineTestKit.distance(q, to: p[0]))
            }
            expect(worst < 0.02, "spline error \(worst)")
            // Fit-points-only spline → polyline through the fit points.
            p = try dxf([(0, "SPLINE"), (71, "3"), (74, "3"), (11, "0"), (21, "0"), (11, "5"), (21, "5"), (11, "10"), (21, "0")])
            expectEqual(p[0].points.count, 3)
        }

        test("dxf: blocks, inserts, layers") {
            let block: [(Int, String)] = [(0, "BLOCK"), (2, "SQ"), (10, "0"), (20, "0"),
                                          (0, "LWPOLYLINE"), (90, "4"), (70, "1"),
                                          (10, "0"), (20, "0"), (10, "1"), (20, "0"), (10, "1"), (20, "1"), (10, "0"), (20, "1"),
                                          (0, "ENDBLK")]
            let layers: [(Int, String)] = [(0, "TABLE"), (2, "LAYER"),
                                           (0, "LAYER"), (2, "VISIBLE"), (70, "0"), (62, "7"),
                                           (0, "LAYER"), (2, "OFF"), (70, "0"), (62, "-7"),
                                           (0, "LAYER"), (2, "FROZEN"), (70, "1"), (62, "1"),
                                           (0, "ENDTAB")]
            let p = try dxf([(0, "INSERT"), (8, "VISIBLE"), (2, "SQ"), (10, "100"), (20, "0"), (41, "3"), (42, "2"), (50, "90"),
                             (0, "INSERT"), (8, "VISIBLE"), (2, "SQ"), (10, "0"), (20, "0"), (70, "2"), (71, "1"), (44, "5"),
                             (0, "LINE"), (8, "OFF"), (10, "0"), (20, "0"), (11, "500"), (21, "0"),
                             (0, "LINE"), (8, "FROZEN"), (10, "0"), (20, "0"), (11, "500"), (21, "0"),
                             (0, "LINE"), (67, "1"), (10, "0"), (20, "0"), (11, "500"), (21, "0")],
                            tables: layers, blocks: block)
            expectEqual(p.count, 3)
            // Scaled 3×2 then rotated 90°: 2 wide, 3 high.
            let s = GeometryOps.bounds([p[0]])!
            expectClose(s.width, 2, tolerance: 1e-9); expectClose(s.height, 3, tolerance: 1e-9)
            // MINSERT columns 5 apart.
            let a = GeometryOps.bounds([p[1]])!, b = GeometryOps.bounds([p[2]])!
            expectClose(b.minX - a.minX, 5, tolerance: 1e-9)
            do {
                _ = try VectorImporter.load(data: Data("hello\nworld\n".utf8), fileExtension: "dxf")
                expect(false, "garbage should fail")
            } catch {}
        }

        test("plt: HPGL pen moves, circles, arcs") {
            let text = "IN;SP1;PU0,0;PD400,0,400,400,0,400,0,0;PU;PA800,0;PD;PR400,0;PU;PA2000,2000;CI200;PU0,1000;PD;AA0,800,180;PU;"
            let p = try VectorImporter.load(data: Data(text.utf8), fileExtension: "plt")
            expectEqual(p.count, 4)
            expect(p[0].isClosed)
            expectClose(p[0].length, 40, tolerance: 1e-9)
            expectClose(p[1].length, 10, tolerance: 1e-9)
            expect(p[2].isClosed)
            expectClose(p[2].length, 2 * .pi * 5, tolerance: 0.03)
            expectClose(p[3].length, .pi * 5, tolerance: 0.02)
        }
    }
}
