import Foundation
import CoreGraphics

// MARK: - Number scanning

/// Scanner for SVG number lists (`d`, `points`, `viewBox`, `transform` arguments).
/// Accepts the SVG number grammar: sign, digits, optional fraction, optional exponent; "1.5.5" is two numbers.
struct SVGScanner {
    let bytes: [UInt8]
    var index = 0

    init(_ string: String) { bytes = Array(string.utf8) }

    var isAtEnd: Bool { index >= bytes.count }
    var peek: UInt8? { index < bytes.count ? bytes[index] : nil }

    static func isSpace(_ c: UInt8) -> Bool { c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D || c == 0x0C }
    static func isDigit(_ c: UInt8) -> Bool { c >= 0x30 && c <= 0x39 }

    mutating func skipSpaces() {
        while index < bytes.count, Self.isSpace(bytes[index]) { index += 1 }
    }

    /// Skips whitespace and at most one comma.
    mutating func skipSeparators() {
        skipSpaces()
        if index < bytes.count, bytes[index] == UInt8(ascii: ",") { index += 1; skipSpaces() }
    }

    private static let powers: [Double] = (0...22).map { pow(10, Double($0)) }

    mutating func number() -> Double? {
        skipSeparators()
        let start = index
        var i = index
        var negative = false
        if i < bytes.count, bytes[i] == UInt8(ascii: "+") || bytes[i] == UInt8(ascii: "-") {
            negative = bytes[i] == UInt8(ascii: "-")
            i += 1
        }
        var mantissa: UInt64 = 0
        var digits = 0, fractionDigits = 0, anyDigit = false
        while i < bytes.count, Self.isDigit(bytes[i]) {
            if digits < 19 { mantissa = mantissa &* 10 &+ UInt64(bytes[i] - 0x30); digits += 1 } else { fractionDigits -= 1 }
            anyDigit = true
            i += 1
        }
        if i < bytes.count, bytes[i] == UInt8(ascii: ".") {
            i += 1
            while i < bytes.count, Self.isDigit(bytes[i]) {
                if digits < 19 { mantissa = mantissa &* 10 &+ UInt64(bytes[i] - 0x30); digits += 1; fractionDigits += 1 }
                anyDigit = true
                i += 1
            }
        }
        guard anyDigit else { index = start; return nil }
        var exponent = 0
        if i < bytes.count, bytes[i] == UInt8(ascii: "e") || bytes[i] == UInt8(ascii: "E") {
            var j = i + 1
            var expNegative = false
            if j < bytes.count, bytes[j] == UInt8(ascii: "+") || bytes[j] == UInt8(ascii: "-") {
                expNegative = bytes[j] == UInt8(ascii: "-")
                j += 1
            }
            if j < bytes.count, Self.isDigit(bytes[j]) {
                var e = 0
                while j < bytes.count, Self.isDigit(bytes[j]) {
                    if e < 10_000 { e = e * 10 + Int(bytes[j] - 0x30) }
                    j += 1
                }
                exponent = expNegative ? -e : e
                i = j
            }
        }
        index = i
        let scale = exponent - fractionDigits
        var value: Double
        if digits <= 15, abs(scale) <= 22 {
            // Exact fast path: both operands are exactly representable.
            value = scale >= 0 ? Double(mantissa) * Self.powers[scale] : Double(mantissa) / Self.powers[-scale]
        } else {
            let text = String(decoding: bytes[start..<i], as: UTF8.self)
            if let exact = Double(text) { return exact }
            value = Double(mantissa) * pow(10, Double(scale))
        }
        if negative { value = -value }
        return value
    }

    /// Arc flags may be written without separators ("a1 1 0 00 1 1").
    mutating func flag() -> Bool? {
        skipSeparators()
        guard index < bytes.count else { return nil }
        switch bytes[index] {
        case UInt8(ascii: "0"): index += 1; return false
        case UInt8(ascii: "1"): index += 1; return true
        default: return nil
        }
    }

    mutating func numbers() -> [Double] {
        var out: [Double] = []
        while let v = number() { out.append(v) }
        return out
    }
}

// MARK: - Path data

enum SVGPathData {
    /// Parses SVG path data into `builder` (local coordinates). Stops silently at the first error,
    /// keeping what was parsed so far (as SVG renderers do).
    static func parse(_ d: String, into builder: inout PathBuilder) {
        var s = SVGScanner(d)
        var command: UInt8 = 0
        var current = Vec2.zero, start = Vec2.zero
        var lastCubicControl: Vec2?, lastQuadControl: Vec2?
        var firstInSequence = false

        loop: while true {
            s.skipSeparators()
            guard let c = s.peek else { break }
            if (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) {
                command = c
                s.index += 1
                firstInSequence = true
            } else if command == 0 {
                break
            } else {
                firstInSequence = false
            }
            let relative = command >= 0x61
            let base = relative ? current : .zero
            let upper = relative ? command - 0x20 : command
            var nextCubic: Vec2?, nextQuad: Vec2?
            switch upper {
            case UInt8(ascii: "M"):
                guard let x = s.number(), let y = s.number() else { break loop }
                let p = base + Vec2(x, y)
                if firstInSequence {
                    builder.move(to: p)
                    start = p
                } else {
                    builder.line(to: p)  // implicit lineto after the first moveto pair
                }
                current = p
            case UInt8(ascii: "L"):
                guard let x = s.number(), let y = s.number() else { break loop }
                current = base + Vec2(x, y)
                builder.line(to: current)
            case UInt8(ascii: "H"):
                guard let x = s.number() else { break loop }
                current = Vec2(base.x + x, current.y)
                builder.line(to: current)
            case UInt8(ascii: "V"):
                guard let y = s.number() else { break loop }
                current = Vec2(current.x, base.y + y)
                builder.line(to: current)
            case UInt8(ascii: "C"):
                guard let x1 = s.number(), let y1 = s.number(), let x2 = s.number(), let y2 = s.number(),
                      let x = s.number(), let y = s.number() else { break loop }
                let c1 = base + Vec2(x1, y1), c2 = base + Vec2(x2, y2), p = base + Vec2(x, y)
                builder.cubic(c1, c2, p)
                current = p
                nextCubic = c2
            case UInt8(ascii: "S"):
                guard let x2 = s.number(), let y2 = s.number(), let x = s.number(), let y = s.number() else { break loop }
                let c1 = lastCubicControl.map { current * 2 - $0 } ?? current
                let c2 = base + Vec2(x2, y2), p = base + Vec2(x, y)
                builder.cubic(c1, c2, p)
                current = p
                nextCubic = c2
            case UInt8(ascii: "Q"):
                guard let x1 = s.number(), let y1 = s.number(), let x = s.number(), let y = s.number() else { break loop }
                let c1 = base + Vec2(x1, y1), p = base + Vec2(x, y)
                builder.quad(c1, p)
                current = p
                nextQuad = c1
            case UInt8(ascii: "T"):
                guard let x = s.number(), let y = s.number() else { break loop }
                let c1 = lastQuadControl.map { current * 2 - $0 } ?? current
                let p = base + Vec2(x, y)
                builder.quad(c1, p)
                current = p
                nextQuad = c1
            case UInt8(ascii: "A"):
                guard let rx = s.number(), let ry = s.number(), let rotation = s.number(),
                      let large = s.flag(), let sweep = s.flag(), let x = s.number(), let y = s.number() else { break loop }
                let p = base + Vec2(x, y)
                arc(from: current, to: p, rx: rx, ry: ry, rotation: rotation, largeArc: large, sweep: sweep, into: &builder)
                current = p
            case UInt8(ascii: "Z"):
                builder.close()
                current = start
                command = 0x5A  // further numbers without a command are an error
                lastCubicControl = nil; lastQuadControl = nil
                s.skipSeparators()
                if let n = s.peek, !((n >= 0x41 && n <= 0x5A) || (n >= 0x61 && n <= 0x7A)) { break loop }
                continue loop
            default:
                break loop
            }
            lastCubicControl = nextCubic
            lastQuadControl = nextQuad
        }
    }

    /// Endpoint → centre parameterisation (SVG 1.1 F.6.5/F.6.6), then flattened by the builder.
    static func arc(from p0: Vec2, to p1: Vec2, rx rxIn: Double, ry ryIn: Double, rotation: Double,
                    largeArc: Bool, sweep: Bool, into builder: inout PathBuilder) {
        if p0 == p1 { return }
        var rx = abs(rxIn), ry = abs(ryIn)
        guard rx > 0, ry > 0 else { builder.line(to: p1); return }
        let phi = rotation * .pi / 180
        let cosPhi = cos(phi), sinPhi = sin(phi)
        let dx2 = (p0.x - p1.x) / 2, dy2 = (p0.y - p1.y) / 2
        let x1p = cosPhi * dx2 + sinPhi * dy2
        let y1p = -sinPhi * dx2 + cosPhi * dy2
        let lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
        if lambda > 1 { let k = lambda.squareRoot(); rx *= k; ry *= k }
        let num = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p
        let den = rx * rx * y1p * y1p + ry * ry * x1p * x1p
        var coef = den > 0 ? max(0, num / den).squareRoot() : 0
        if largeArc == sweep { coef = -coef }
        let cxp = coef * rx * y1p / ry
        let cyp = -coef * ry * x1p / rx
        let center = Vec2(cosPhi * cxp - sinPhi * cyp + (p0.x + p1.x) / 2,
                          sinPhi * cxp + cosPhi * cyp + (p0.y + p1.y) / 2)
        func angle(_ ux: Double, _ uy: Double, _ vx: Double, _ vy: Double) -> Double {
            atan2(ux * vy - uy * vx, ux * vx + uy * vy)
        }
        let ux = (x1p - cxp) / rx, uy = (y1p - cyp) / ry
        let vx = (-x1p - cxp) / rx, vy = (-y1p - cyp) / ry
        let theta1 = angle(1, 0, ux, uy)
        var delta = angle(ux, uy, vx, vy)
        if !sweep, delta > 0 { delta -= 2 * .pi }
        if sweep, delta < 0 { delta += 2 * .pi }
        builder.arc(center: center, rx: rx, ry: ry, phi: phi, theta1: theta1, delta: delta, end: p1)
    }
}

// MARK: - Transforms

enum SVGTransform {
    /// Parses a transform list; the result maps local coordinates to the parent's.
    static func parse(_ text: String) -> CGAffineTransform {
        var result = CGAffineTransform.identity
        var s = SVGScanner(text)
        while true {
            s.skipSeparators()
            let nameStart = s.index
            while let c = s.peek, (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) { s.index += 1 }
            guard s.index > nameStart else { break }
            let name = String(decoding: s.bytes[nameStart..<s.index], as: UTF8.self)
            s.skipSpaces()
            guard s.peek == UInt8(ascii: "(") else { break }
            s.index += 1
            let args = s.numbers()
            s.skipSpaces()
            guard s.peek == UInt8(ascii: ")") else { break }
            s.index += 1
            let t: CGAffineTransform
            switch (name, args.count) {
            case ("matrix", 6):
                t = CGAffineTransform(a: args[0], b: args[1], c: args[2], d: args[3], tx: args[4], ty: args[5])
            case ("translate", 1): t = CGAffineTransform(translationX: args[0], y: 0)
            case ("translate", 2): t = CGAffineTransform(translationX: args[0], y: args[1])
            case ("scale", 1): t = CGAffineTransform(scaleX: args[0], y: args[0])
            case ("scale", 2): t = CGAffineTransform(scaleX: args[0], y: args[1])
            case ("rotate", 1): t = CGAffineTransform(rotationAngle: args[0] * .pi / 180)
            case ("rotate", 3):
                t = CGAffineTransform(translationX: -args[1], y: -args[2])
                    .concatenating(CGAffineTransform(rotationAngle: args[0] * .pi / 180))
                    .concatenating(CGAffineTransform(translationX: args[1], y: args[2]))
            case ("skewX", 1): t = CGAffineTransform(a: 1, b: 0, c: tan(args[0] * .pi / 180), d: 1, tx: 0, ty: 0)
            case ("skewY", 1): t = CGAffineTransform(a: 1, b: tan(args[0] * .pi / 180), c: 0, d: 1, tx: 0, ty: 0)
            default: return result  // invalid list: keep what was valid
            }
            // "A B" applies B first, then A.
            result = t.concatenating(result)
        }
        return result
    }
}

// MARK: - Document

final class SVGNode {
    let name: String
    let attributes: [String: String]
    var children: [SVGNode] = []
    weak var parent: SVGNode?

    init(name: String, attributes: [String: String]) {
        self.name = name
        self.attributes = attributes
    }

    /// Attribute, or the same property from the inline `style` declaration (which takes precedence).
    func property(_ key: String) -> String? {
        if let style = attributes["style"], let v = SVGNode.styleValue(style, key) { return v }
        return attributes[key]
    }

    static func styleValue(_ style: String, _ key: String) -> String? {
        for declaration in style.split(separator: ";") {
            let parts = declaration.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            if parts[0].trimmingCharacters(in: .whitespaces) == key {
                return parts[1].replacingOccurrences(of: "!important", with: "").trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }
}

final class SVGTreeBuilder: NSObject, XMLParserDelegate {
    var root: SVGNode?
    private var stack: [SVGNode] = []
    var ids: [String: SVGNode] = [:]

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let local = elementName.split(separator: ":").last.map(String.init) ?? elementName
        let node = SVGNode(name: local, attributes: attributeDict)
        if let id = attributeDict["id"] { ids[id] = node }
        if let parent = stack.last {
            node.parent = parent
            parent.children.append(node)
        } else if root == nil {
            root = node
        }
        stack.append(node)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        _ = stack.popLast()
    }
}

// MARK: - Importer

/// SVG → polylines. Supports path / rect / circle / ellipse / line / polyline / polygon, nested `g` and `svg`
/// with transform lists and viewports, and `use` references. Skips `display:none`, hidden elements, `defs`,
/// `clipPath`, `mask`, `text`, `symbol` (unless referenced), markers, patterns and images.
/// CSS rules in `<style>` sheets are not evaluated (only presentation attributes and inline `style`).
enum SVGImporter {
    static let pxToMM = 25.4 / 96

    static let skipped: Set<String> = [
        "defs", "clipPath", "mask", "text", "symbol", "marker", "pattern", "style", "script", "metadata", "title",
        "desc", "linearGradient", "radialGradient", "filter", "foreignObject", "image", "font", "font-face",
        "namedview", "sodipodi:namedview",
    ]

    static func load(data: Data, tolerance: Double) throws -> [Polyline] {
        let parser = XMLParser(data: data)
        let tree = SVGTreeBuilder()
        parser.delegate = tree
        parser.shouldResolveExternalEntities = false
        guard parser.parse() else {
            throw VectorImportError.unreadable("invalid XML: " + (parser.parserError?.localizedDescription ?? "parse error"))
        }
        guard let root = tree.root, root.name == "svg" else { throw VectorImportError.unreadable("no <svg> root element") }
        var context = Context(tolerance: tolerance, ids: tree.ids)
        // User units → mm, then flip to +Y up.
        let rootViewport = context.rootTransform(root)
        let flip = CGAffineTransform(scaleX: 1, y: -1)
        context.renderChildren(of: root, ctm: rootViewport.transform.concatenating(flip),
                               viewport: rootViewport.size, visible: true, depth: 0)
        return context.polylines
    }

    struct Context {
        let tolerance: Double
        let ids: [String: SVGNode]
        var polylines: [Polyline] = []

        // MARK: Lengths

        /// Length in user units (absolute units use 96 px per inch); `percentOf` resolves "%".
        static func length(_ text: String?, percentOf reference: Double = 0) -> Double? {
            guard let raw = text?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
            var s = SVGScanner(raw)
            guard let v = s.number() else { return nil }
            let unit = String(decoding: s.bytes[s.index...], as: UTF8.self).trimmingCharacters(in: .whitespaces).lowercased()
            switch unit {
            case "", "px": return v
            case "mm": return v / SVGImporter.pxToMM
            case "cm": return v * 10 / SVGImporter.pxToMM
            case "in": return v * 96
            case "pt": return v * 96 / 72
            case "pc": return v * 16
            case "q": return v * 0.25 / SVGImporter.pxToMM
            case "em": return v * 16
            case "ex": return v * 8
            case "%": return v / 100 * reference
            default: return v
            }
        }

        /// Root viewport → mm transform (y down) and the viewport size in user units.
        func rootTransform(_ svg: SVGNode) -> (transform: CGAffineTransform, size: CGSize) {
            let widthPx = Self.isPercent(svg.attributes["width"]) ? nil : Self.length(svg.attributes["width"])
            let heightPx = Self.isPercent(svg.attributes["height"]) ? nil : Self.length(svg.attributes["height"])
            if let vb = Self.viewBox(svg.attributes["viewBox"]) {
                var w = widthPx, h = heightPx
                if w == nil, let h0 = h { w = h0 * vb.width / vb.height }
                if h == nil, let w0 = w { h = w0 * vb.height / vb.width }
                // Without width/height the viewport equals the viewBox, i.e. one user unit is one px.
                let mapping = Self.viewBoxTransform(vb, width: w ?? vb.width, height: h ?? vb.height,
                                                    aspect: svg.attributes["preserveAspectRatio"])
                let pxToMM = CGAffineTransform(scaleX: SVGImporter.pxToMM, y: SVGImporter.pxToMM)
                return (mapping.concatenating(pxToMM), vb.size)
            }
            let size = CGSize(width: widthPx ?? 100, height: heightPx ?? 100)
            return (CGAffineTransform(scaleX: SVGImporter.pxToMM, y: SVGImporter.pxToMM), size)
        }

        static func isPercent(_ s: String?) -> Bool { s?.trimmingCharacters(in: .whitespaces).hasSuffix("%") ?? false }

        static func viewBox(_ text: String?) -> CGRect? {
            guard let text else { return nil }
            var s = SVGScanner(text)
            let v = s.numbers()
            guard v.count == 4, v[2] > 0, v[3] > 0 else { return nil }
            return CGRect(x: v[0], y: v[1], width: v[2], height: v[3])
        }

        /// viewBox → viewport (`width`×`height` at the origin) honouring preserveAspectRatio.
        static func viewBoxTransform(_ vb: CGRect, width: Double, height: Double, aspect: String?) -> CGAffineTransform {
            var sx = width / vb.width, sy = height / vb.height
            let parts = (aspect ?? "xMidYMid meet").split(separator: " ").map(String.init).filter { $0 != "defer" }
            let align = parts.first ?? "xMidYMid"
            var tx = -vb.minX * sx, ty = -vb.minY * sy
            if align != "none" {
                let s = parts.count > 1 && parts[1] == "slice" ? max(sx, sy) : min(sx, sy)
                sx = s; sy = s
                tx = -vb.minX * s; ty = -vb.minY * s
                let extraX = width - vb.width * s, extraY = height - vb.height * s
                if align.contains("xMid") { tx += extraX / 2 } else if align.contains("xMax") { tx += extraX }
                if align.contains("YMid") { ty += extraY / 2 } else if align.contains("YMax") { ty += extraY }
            }
            return CGAffineTransform(a: sx, b: 0, c: 0, d: sy, tx: tx, ty: ty)
        }

        // MARK: Traversal

        mutating func renderChildren(of node: SVGNode, ctm: CGAffineTransform, viewport: CGSize, visible: Bool, depth: Int) {
            for child in node.children { render(child, ctm: ctm, viewport: viewport, visible: visible, depth: depth + 1) }
        }

        mutating func render(_ node: SVGNode, ctm parent: CGAffineTransform, viewport: CGSize, visible inherited: Bool,
                             depth: Int, viaUse: Bool = false) {
            guard depth < 64 else { return }
            if SVGImporter.skipped.contains(node.name), !(viaUse && node.name == "symbol") { return }
            if node.property("display") == "none" { return }
            var visible = inherited
            if let v = node.property("visibility") { visible = (v != "hidden" && v != "collapse") }
            var ctm = parent
            if let t = node.attributes["transform"] { ctm = SVGTransform.parse(t).concatenating(parent) }

            let vw = Double(viewport.width), vh = Double(viewport.height)
            let diag = ((vw * vw + vh * vh) / 2).squareRoot()
            func len(_ key: String, _ ref: Double) -> Double { Context.length(node.attributes[key], percentOf: ref) ?? 0 }

            switch node.name {
            case "svg", "symbol":
                // Nested viewport.
                let x = len("x", vw), y = len("y", vh)
                let w = Context.length(node.attributes["width"], percentOf: vw) ?? vw
                let h = Context.length(node.attributes["height"], percentOf: vh) ?? vh
                var inner = CGAffineTransform(translationX: x, y: y)
                var size = CGSize(width: w, height: h)
                if let vb = Context.viewBox(node.attributes["viewBox"]) {
                    inner = Context.viewBoxTransform(vb, width: w, height: h, aspect: node.attributes["preserveAspectRatio"])
                        .concatenating(inner)
                    size = vb.size
                }
                renderChildren(of: node, ctm: inner.concatenating(ctm), viewport: size, visible: visible, depth: depth)
            case "g", "a", "switch":
                renderChildren(of: node, ctm: ctm, viewport: viewport, visible: visible, depth: depth)
            case "use":
                let href = node.attributes["href"] ?? node.attributes["xlink:href"] ?? ""
                guard href.hasPrefix("#"), let target = ids[String(href.dropFirst())] else { return }
                // Guard against self-references.
                var ancestor: SVGNode? = node
                while let a = ancestor { if a === target { return }; ancestor = a.parent }
                let shifted = CGAffineTransform(translationX: len("x", vw), y: len("y", vh)).concatenating(ctm)
                render(target, ctm: shifted, viewport: viewport, visible: visible, depth: depth + 1, viaUse: true)
            case "path":
                guard visible, let d = node.attributes["d"] else { return }
                var b = PathBuilder(tolerance: tolerance, transform: ctm)
                SVGPathData.parse(d, into: &b)
                polylines += b.finish()
            case "rect":
                guard visible else { return }
                let x = len("x", vw), y = len("y", vh), w = len("width", vw), h = len("height", vh)
                guard w > 0, h > 0 else { return }
                var rx = Context.length(node.property("rx"), percentOf: vw)
                var ry = Context.length(node.property("ry"), percentOf: vh)
                if rx == nil { rx = ry }
                if ry == nil { ry = rx }
                let rxv = min(max(0, rx ?? 0), w / 2), ryv = min(max(0, ry ?? 0), h / 2)
                var b = PathBuilder(tolerance: tolerance, transform: ctm)
                if rxv > 0, ryv > 0 {
                    // y down: corners clockwise on screen starting top-left.
                    b.move(to: Vec2(x + rxv, y))
                    b.line(to: Vec2(x + w - rxv, y))
                    b.arc(center: Vec2(x + w - rxv, y + ryv), rx: rxv, ry: ryv, phi: 0, theta1: -.pi / 2, delta: .pi / 2)
                    b.line(to: Vec2(x + w, y + h - ryv))
                    b.arc(center: Vec2(x + w - rxv, y + h - ryv), rx: rxv, ry: ryv, phi: 0, theta1: 0, delta: .pi / 2)
                    b.line(to: Vec2(x + rxv, y + h))
                    b.arc(center: Vec2(x + rxv, y + h - ryv), rx: rxv, ry: ryv, phi: 0, theta1: .pi / 2, delta: .pi / 2)
                    b.line(to: Vec2(x, y + ryv))
                    b.arc(center: Vec2(x + rxv, y + ryv), rx: rxv, ry: ryv, phi: 0, theta1: .pi, delta: .pi / 2)
                } else {
                    b.move(to: Vec2(x, y)); b.line(to: Vec2(x + w, y)); b.line(to: Vec2(x + w, y + h)); b.line(to: Vec2(x, y + h))
                }
                b.close()
                polylines += b.finish()
            case "circle":
                guard visible else { return }
                let r = len("r", diag)
                guard r > 0 else { return }
                ellipse(Vec2(len("cx", vw), len("cy", vh)), r, r, ctm)
            case "ellipse":
                guard visible else { return }
                let rx = len("rx", vw), ry = len("ry", vh)
                guard rx > 0, ry > 0 else { return }
                ellipse(Vec2(len("cx", vw), len("cy", vh)), rx, ry, ctm)
            case "line":
                guard visible else { return }
                var b = PathBuilder(tolerance: tolerance, transform: ctm)
                b.move(to: Vec2(len("x1", vw), len("y1", vh)))
                b.line(to: Vec2(len("x2", vw), len("y2", vh)))
                polylines += b.finish()
            case "polyline", "polygon":
                guard visible, let text = node.attributes["points"] else { return }
                var s = SVGScanner(text)
                let v = s.numbers()
                guard v.count >= 4 else { return }
                var b = PathBuilder(tolerance: tolerance, transform: ctm)
                b.move(to: Vec2(v[0], v[1]))
                var i = 2
                while i + 1 < v.count { b.line(to: Vec2(v[i], v[i + 1])); i += 2 }
                if node.name == "polygon" { b.close() }
                polylines += b.finish()
            default:
                // Unknown container-like elements are ignored entirely.
                break
            }
        }

        mutating func ellipse(_ c: Vec2, _ rx: Double, _ ry: Double, _ ctm: CGAffineTransform) {
            var b = PathBuilder(tolerance: tolerance, transform: ctm)
            b.arc(center: c, rx: rx, ry: ry, phi: 0, theta1: 0, delta: 2 * .pi, end: Vec2(c.x + rx, c.y))
            b.close()
            polylines += b.finish()
        }
    }
}
