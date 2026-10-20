import Foundation
import CoreGraphics
import CoreText

/// CoreText implementation behind `TextOutliner`.
enum TextLayout {
    /// Typographic points per millimetre. Fonts are laid out at their physical point size
    /// (so optical-size variants match the engraved size) and scaled back to mm.
    static let pointsPerMM = 72.0 / 25.4

    static func outline(text: String, fontName: String, height: Double, letterSpacing: Double,
                        lineSpacing: Double, alignment: TextAlignment, tolerance: Double) -> [Polyline] {
        guard height > 0, height.isFinite, !text.isEmpty else { return [] }
        let pointSize = height * pointsPerMM
        let font = resolveFont(named: fontName, size: pointSize)
        let mmPerPoint = 1 / pointsPerMM
        let kern = letterSpacing * pointsPerMM

        var result: [Polyline] = []
        // `Character.isNewline` treats "\r\n" as one separator.
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        for (index, lineText) in lines.enumerated() {
            let baseline = -Double(index) * lineSpacing * height
            let string = String(lineText)
            guard !string.isEmpty, let line = makeLine(string, font: font, kern: kern) else { continue }
            let width = (CTLineGetTypographicBounds(line, nil, nil, nil) - CTLineGetTrailingWhitespaceWidth(line)) * mmPerPoint
            let x0: Double
            switch alignment {
            case .left: x0 = 0
            case .center: x0 = -width / 2
            case .right: x0 = -width
            }
            appendGlyphOutlines(of: line, origin: Vec2(x0, baseline), scale: mmPerPoint, tolerance: tolerance, into: &result)
        }
        return result
    }

    /// Family names of installed fonts (hidden system families starting with "." are omitted).
    static func familyNames() -> [String] {
        let names = (CTFontManagerCopyAvailableFontFamilyNames() as? [String]) ?? []
        return Array(Set(names.filter { !$0.hasPrefix(".") }))
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Resolves `name` as a family name, then as a PostScript / full font name; falls back to Helvetica.
    static func resolveFont(named name: String, size: Double) -> CTFont {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            let attributes = [kCTFontFamilyNameAttribute: trimmed] as CFDictionary
            let descriptor = CTFontDescriptorCreateWithAttributes(attributes)
            let mandatory = Set([kCTFontFamilyNameAttribute as String]) as CFSet
            if let matched = CTFontDescriptorCreateMatchingFontDescriptor(descriptor, mandatory) {
                let font = CTFontCreateWithFontDescriptor(matched, size, nil)
                if matches(font, trimmed) { return font }
            }
            let byName = CTFontCreateWithName(trimmed as CFString, size, nil)
            if matches(byName, trimmed) { return byName }
        }
        return CTFontCreateWithName("Helvetica" as CFString, size, nil)
    }

    private static func matches(_ font: CTFont, _ name: String) -> Bool {
        let candidates = [CTFontCopyFamilyName(font) as String, CTFontCopyPostScriptName(font) as String,
                          CTFontCopyFullName(font) as String, CTFontCopyDisplayName(font) as String]
        return candidates.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// One CTLine with extra tracking after every character except the last
    /// (so trailing tracking does not shift centred / right-aligned lines).
    private static func makeLine(_ string: String, font: CTFont, kern: Double) -> CTLine? {
        let attributed = NSMutableAttributedString(
            string: string, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
        let ns = string as NSString
        if kern != 0, ns.length > 0 {
            let last = ns.rangeOfComposedCharacterSequence(at: ns.length - 1)
            if last.location > 0 {
                attributed.addAttribute(NSAttributedString.Key(kCTKernAttributeName as String),
                                        value: NSNumber(value: kern), range: NSRange(location: 0, length: last.location))
            }
        }
        return CTLineCreateWithAttributedString(attributed as CFAttributedString)
    }

    private static func appendGlyphOutlines(of line: CTLine, origin: Vec2, scale: Double, tolerance: Double,
                                            into result: inout [Polyline]) {
        guard let runs = CTLineGetGlyphRuns(line) as? [CTRun] else { return }
        let fontKey = kCTFontAttributeName as String
        for run in runs {
            let count = CTRunGetGlyphCount(run)
            guard count > 0 else { continue }
            let attributes = CTRunGetAttributes(run) as NSDictionary
            // CoreText substitutes fallback fonts per run for characters the requested font lacks.
            guard let fontValue = attributes[fontKey] as CFTypeRef?, CFGetTypeID(fontValue) == CTFontGetTypeID() else { continue }
            let runFont = unsafeDowncast(fontValue, to: CTFont.self)
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
            let textMatrix = CTRunGetTextMatrix(run)
            for i in 0..<count {
                let place = CGAffineTransform(translationX: positions[i].x, y: positions[i].y)
                    .concatenating(CGAffineTransform(scaleX: scale, y: scale))
                    .concatenating(CGAffineTransform(translationX: origin.x, y: origin.y))
                var matrix = textMatrix.concatenating(place)
                guard let path = CTFontCreatePathForGlyph(runFont, glyphs[i], &matrix) else { continue }
                var builder = PathBuilder(tolerance: tolerance)
                builder.append(path)
                for var contour in builder.finish() where contour.points.count >= 3 {
                    contour.isClosed = true  // glyph contours are always closed
                    result.append(contour)
                }
            }
        }
    }
}
