import Foundation
import MRCarveKit

enum EngineTextTests {
    static func bounds(_ p: [Polyline]) -> Rect2 { GeometryOps.bounds(p) ?? Rect2(minX: 0, minY: 0, maxX: 0, maxY: 0) }

    static func register() {
        test("text: MR Carve outlines and metrics") {
            let lines = TextOutliner.polylines(text: "MR Carve", fontName: "Helvetica", height: 10)
            expect(lines.count >= 8, "contours: \(lines.count)")
            expect(lines.allSatisfy { $0.isClosed && $0.points.count >= 3 })
            let b = bounds(lines)
            // Helvetica: cap height ≈ 0.72 em, no descenders in "MR Carve", M starts near x = 0.
            expect(b.maxY > 6.5 && b.maxY < 7.8, "cap height \(b.maxY)")
            expect(b.minY > -0.4 && b.minY < 0.1, "baseline \(b.minY)")
            expect(b.minX >= 0 && b.minX < 1.5, "left \(b.minX)")
            expect(b.width > 35 && b.width < 55, "width \(b.width)")
            // Scales linearly with the em size.
            let small = bounds(TextOutliner.polylines(text: "MR Carve", fontName: "Helvetica", height: 2))
            expectClose(small.width, b.width / 5, tolerance: 0.02)
        }

        test("text: accents, fallback font and empty input") {
            let accented = TextOutliner.polylines(text: "Évry à l'été", fontName: "Helvetica", height: 10)
            let plain = TextOutliner.polylines(text: "Evry a l'ete", fontName: "Helvetica", height: 10)
            expect(accented.count > plain.count, "\(accented.count) vs \(plain.count)")
            expect(bounds(accented).maxY > bounds(plain).maxY + 1, "accents above cap height")
            expect(bounds(accented).minY < -1.5, "descender of y")

            let unknown = TextOutliner.polylines(text: "Abc", fontName: "No Such Font 123", height: 5)
            let helvetica = TextOutliner.polylines(text: "Abc", fontName: "Helvetica", height: 5)
            expectEqual(unknown, helvetica)
            // PostScript names work too.
            let bold = TextOutliner.polylines(text: "Abc", fontName: "Helvetica-Bold", height: 5)
            expect(!bold.isEmpty && bold != helvetica)
            // Characters missing from the font come from a CoreText fallback font.
            expect(!TextOutliner.polylines(text: "日本", fontName: "Helvetica", height: 5).isEmpty)
            expect(TextOutliner.polylines(text: "", fontName: "Helvetica", height: 5).isEmpty)
            expect(TextOutliner.polylines(text: "A", fontName: "Helvetica", height: 0).isEmpty)
            expect(TextOutliner.polylines(text: "   ", fontName: "Helvetica", height: 5).isEmpty)
        }

        test("text: multiline, line spacing and alignment") {
            let two = TextOutliner.polylines(text: "HI\nHI", fontName: "Helvetica", height: 10, lineSpacing: 1.5)
            let one = TextOutliner.polylines(text: "HI", fontName: "Helvetica", height: 10)
            expectEqual(two.count, 2 * one.count)
            let b = bounds(two), b1 = bounds(one)
            expectClose(b.minY, -15, tolerance: 1e-6)          // second baseline, flat-bottomed letters
            expectClose(b.maxY, b1.maxY, tolerance: 1e-9)
            // CRLF counts as one line break; an empty line still advances.
            let crlf = bounds(TextOutliner.polylines(text: "HI\r\n\r\nHI", fontName: "Helvetica", height: 10))
            expectClose(crlf.minY, -24, tolerance: 1e-6)

            let centred = bounds(TextOutliner.polylines(text: "HHH\nH", fontName: "Helvetica", height: 10, alignment: .center))
            expect(abs(centred.center.x) < 0.3, "centre \(centred.center.x)")
            let right = TextOutliner.polylines(text: "HHH\nH ", fontName: "Helvetica", height: 10, alignment: .right)
            let rb = bounds(right)
            expect(rb.maxX <= 0 && rb.maxX > -1.5, "right edge \(rb.maxX)")
            // Both lines end at the same x (trailing whitespace ignored).
            let firstLine = right.filter { ($0.bounds?.minY ?? 0) > -1 }, secondLine = right.filter { ($0.bounds?.maxY ?? 0) < -1 }
            expectClose(bounds(firstLine).maxX, bounds(secondLine).maxX, tolerance: 1e-6)
        }

        test("text: letter spacing") {
            let base = bounds(TextOutliner.polylines(text: "HHHH", fontName: "Helvetica", height: 10))
            let spaced = bounds(TextOutliner.polylines(text: "HHHH", fontName: "Helvetica", height: 10, letterSpacing: 2))
            expectClose(spaced.width - base.width, 6, tolerance: 1e-6)
            let centred = bounds(TextOutliner.polylines(text: "HHHH", fontName: "Helvetica", height: 10, letterSpacing: 2,
                                                        alignment: .center))
            expect(abs(centred.center.x) < 0.3)
        }

        test("text: font families") {
            let families = TextOutliner.availableFontFamilies()
            expect(families.count > 10)
            expect(families.contains("Helvetica"))
            expect(!families.contains { $0.hasPrefix(".") })
            expectEqual(families, families.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending })
        }
    }
}
