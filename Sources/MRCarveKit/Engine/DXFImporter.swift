import Foundation
import CoreGraphics

/// ASCII DXF → polylines.
///
/// Entities: LINE, LWPOLYLINE (with bulges), POLYLINE/VERTEX (2D/3D, curve-fit vertices; meshes skipped),
/// CIRCLE, ARC, ELLIPSE, SPLINE (NURBS evaluated adaptively; fit-point-only splines become polylines through
/// the fit points), INSERT (blocks, scale, rotation, MINSERT arrays, nesting). Paper-space entities and
/// entities on frozen/off layers are skipped. OCS is honoured for extrusion (0,0,−1) (mirrored entities);
/// other extrusion directions are treated as (0,0,1). `$INSUNITS` selects the unit (unitless = mm).
enum DXFImporter {
    struct Pair { var code: Int; var value: String }

    struct Entity {
        var type: String
        var pairs: [Pair]
        var vertices: [Entity] = []  // POLYLINE → VERTEX

        func string(_ code: Int) -> String? { pairs.first { $0.code == code }?.value }
        func double(_ code: Int, _ fallback: Double = 0) -> Double {
            string(code).flatMap { Double($0.trimmingCharacters(in: .whitespaces)) } ?? fallback
        }
        func int(_ code: Int, _ fallback: Int = 0) -> Int {
            string(code).flatMap { Int($0.trimmingCharacters(in: .whitespaces)) ?? Double($0.trimmingCharacters(in: .whitespaces)).map { Int($0) } } ?? fallback
        }
        func doubles(_ code: Int) -> [Double] {
            pairs.compactMap { $0.code == code ? Double($0.value.trimmingCharacters(in: .whitespaces)) : nil }
        }
    }

    struct Block { var base: Vec2; var entities: [Entity] }

    static func load(data: Data, tolerance: Double) throws -> [Polyline] {
        let text: String
        if let s = String(data: data, encoding: .utf8) { text = s } else if let s = String(data: data, encoding: .windowsCP1252) { text = s } else {
            text = String(decoding: data, as: UTF8.self)
        }
        if text.hasPrefix("AutoCAD Binary DXF") { throw VectorImportError.unsupported("binary DXF") }
        let pairs = try readPairs(text)
        var header: [String: [Pair]] = [:]
        var blocks: [String: Block] = [:]
        var entities: [Entity] = []
        var hiddenLayers: Set<String> = []

        var i = 0
        while i < pairs.count {
            guard pairs[i].code == 0, pairs[i].value == "SECTION", i + 1 < pairs.count, pairs[i + 1].code == 2 else { i += 1; continue }
            let name = pairs[i + 1].value.uppercased()
            i += 2
            var section: [Pair] = []
            while i < pairs.count, !(pairs[i].code == 0 && pairs[i].value == "ENDSEC") { section.append(pairs[i]); i += 1 }
            i += 1
            switch name {
            case "HEADER": header = parseHeader(section)
            case "TABLES": hiddenLayers = parseHiddenLayers(section)
            case "BLOCKS": blocks = parseBlocks(section)
            case "ENTITIES": entities = groupEntities(section)
            default: break
            }
        }
        if entities.isEmpty, blocks.isEmpty, pairs.contains(where: { $0.code == 0 && $0.value == "SECTION" }) == false {
            throw VectorImportError.unreadable("not a DXF file")
        }

        let unit = header["$INSUNITS"]?.first { $0.code == 70 }.flatMap { Int($0.value.trimmingCharacters(in: .whitespaces)) } ?? 0
        var context = Context(tolerance: tolerance, blocks: blocks, hiddenLayers: hiddenLayers)
        let scale = unitScale(unit)
        context.draw(entities, transform: CGAffineTransform(scaleX: scale, y: scale), depth: 0)
        return context.polylines
    }

    /// Millimetres per drawing unit for `$INSUNITS` (0 = unitless, treated as mm).
    static func unitScale(_ code: Int) -> Double {
        switch code {
        case 1: return 25.4            // inches
        case 2: return 304.8           // feet
        case 3: return 1_609_344       // miles
        case 4: return 1               // mm
        case 5: return 10              // cm
        case 6: return 1000            // m
        case 7: return 1_000_000       // km
        case 8: return 25.4e-6         // microinches
        case 9: return 0.0254          // mils
        case 10: return 914.4          // yards
        case 11: return 1e-7           // ångström
        case 12: return 1e-6           // nm
        case 13: return 1e-3           // µm
        case 14: return 100            // dm
        case 15: return 10_000         // dam
        case 16: return 100_000        // hm
        default: return 1
        }
    }

    /// Group code / value pairs (byte-level line splitting; CRLF, LF or CR line ends).
    static func readPairs(_ text: String) throws -> [Pair] {
        let bytes = Array(text.utf8)
        var lines: [Range<Int>] = []
        var start = 0, i = 0
        while i < bytes.count {
            let c = bytes[i]
            if c == 0x0A || c == 0x0D {
                lines.append(start..<i)
                if c == 0x0D, i + 1 < bytes.count, bytes[i + 1] == 0x0A { i += 1 }
                start = i + 1
            }
            i += 1
        }
        if start < bytes.count { lines.append(start..<bytes.count) }
        func trimmed(_ r: Range<Int>) -> String {
            var lo = r.lowerBound, hi = r.upperBound
            while lo < hi, bytes[lo] == 0x20 || bytes[lo] == 0x09 { lo += 1 }
            while hi > lo, bytes[hi - 1] == 0x20 || bytes[hi - 1] == 0x09 { hi -= 1 }
            return String(decoding: bytes[lo..<hi], as: UTF8.self)
        }
        var pairs: [Pair] = []
        pairs.reserveCapacity(lines.count / 2)
        var k = 0
        while k + 1 < lines.count {
            let codeText = trimmed(lines[k])
            if codeText.isEmpty, k + 2 > lines.count { break }
            guard let code = Int(codeText) else {
                throw VectorImportError.unreadable("invalid DXF group code at line \(k + 1)")
            }
            pairs.append(Pair(code: code, value: trimmed(lines[k + 1])))
            k += 2
        }
        return pairs
    }

    static func parseHeader(_ pairs: [Pair]) -> [String: [Pair]] {
        var result: [String: [Pair]] = [:]
        var current: String?
        for p in pairs {
            if p.code == 9 { current = p.value; result[p.value] = [] } else if let c = current { result[c, default: []].append(p) }
        }
        return result
    }

    /// Layers that are off (negative colour) or frozen (flag bit 1).
    static func parseHiddenLayers(_ pairs: [Pair]) -> Set<String> {
        var hidden: Set<String> = []
        for entity in groupEntities(pairs) where entity.type == "LAYER" {
            guard let name = entity.string(2) else { continue }
            if entity.int(62, 7) < 0 || entity.int(70) & 1 != 0 { hidden.insert(name) }
        }
        return hidden
    }

    static func parseBlocks(_ pairs: [Pair]) -> [String: Block] {
        var blocks: [String: Block] = [:]
        let all = groupEntities(pairs)
        var i = 0
        while i < all.count {
            guard all[i].type == "BLOCK", let name = all[i].string(2) else { i += 1; continue }
            let base = Vec2(all[i].double(10), all[i].double(20))
            var body: [Entity] = []
            i += 1
            while i < all.count, all[i].type != "ENDBLK" { body.append(all[i]); i += 1 }
            blocks[name] = Block(base: base, entities: body)
            i += 1
        }
        return blocks
    }

    /// Splits pairs at code-0 markers into entities, attaching VERTEX entities to their POLYLINE.
    static func groupEntities(_ pairs: [Pair]) -> [Entity] {
        var flat: [Entity] = []
        for p in pairs {
            if p.code == 0 { flat.append(Entity(type: p.value.uppercased(), pairs: [])) } else if !flat.isEmpty { flat[flat.count - 1].pairs.append(p) }
        }
        var result: [Entity] = []
        var i = 0
        while i < flat.count {
            var e = flat[i]
            i += 1
            if e.type == "POLYLINE" {
                while i < flat.count, flat[i].type == "VERTEX" { e.vertices.append(flat[i]); i += 1 }
                if i < flat.count, flat[i].type == "SEQEND" { i += 1 }
            }
            result.append(e)
        }
        return result
    }

    struct Context {
        let tolerance: Double
        let blocks: [String: Block]
        let hiddenLayers: Set<String>
        var polylines: [Polyline] = []

        mutating func draw(_ entities: [Entity], transform: CGAffineTransform, depth: Int) {
            guard depth < 32 else { return }
            for e in entities {
                if e.int(67) == 1 { continue }  // paper space
                if let layer = e.string(8), hiddenLayers.contains(layer) { continue }
                // OCS: extrusion (0,0,-1) mirrors X.
                let ocs = e.double(230, 1) < 0 ? CGAffineTransform(scaleX: -1, y: 1).concatenating(transform) : transform
                switch e.type {
                case "LINE":
                    var b = PathBuilder(tolerance: tolerance, transform: transform)
                    b.move(to: Vec2(e.double(10), e.double(20)))
                    b.line(to: Vec2(e.double(11), e.double(21)))
                    polylines += b.finish()
                case "LWPOLYLINE":
                    var vertices: [(Vec2, Double)] = []
                    for p in e.pairs {
                        switch p.code {
                        case 10: vertices.append((Vec2(Double(p.value) ?? 0, 0), 0))
                        case 20: if !vertices.isEmpty { vertices[vertices.count - 1].0.y = Double(p.value) ?? 0 }
                        case 42: if !vertices.isEmpty { vertices[vertices.count - 1].1 = Double(p.value) ?? 0 }
                        default: break
                        }
                    }
                    polyline(vertices, closed: e.int(70) & 1 != 0, ocs)
                case "POLYLINE":
                    let flags = e.int(70)
                    guard flags & (16 | 64) == 0 else { continue }  // polygon / polyface meshes
                    let vertices = e.vertices.filter { $0.int(70) & 16 == 0 }  // skip spline frame points
                        .map { (Vec2($0.double(10), $0.double(20)), $0.double(42)) }
                    polyline(vertices, closed: flags & 1 != 0, flags & 8 != 0 ? transform : ocs)
                case "CIRCLE":
                    let r = e.double(40)
                    guard r > 0 else { continue }
                    let c = Vec2(e.double(10), e.double(20))
                    var b = PathBuilder(tolerance: tolerance, transform: ocs)
                    b.arc(center: c, rx: r, ry: r, phi: 0, theta1: 0, delta: 2 * .pi, end: Vec2(c.x + r, c.y))
                    b.close()
                    polylines += b.finish()
                case "ARC":
                    let r = e.double(40)
                    guard r > 0 else { continue }
                    let a0 = e.double(50) * .pi / 180
                    var sweep = (e.double(51) - e.double(50)).truncatingRemainder(dividingBy: 360)
                    if sweep <= 0 { sweep += 360 }
                    var b = PathBuilder(tolerance: tolerance, transform: ocs)
                    b.arc(center: Vec2(e.double(10), e.double(20)), rx: r, ry: r, phi: 0, theta1: a0, delta: sweep * .pi / 180)
                    polylines += b.finish()
                case "ELLIPSE":
                    let major = Vec2(e.double(11), e.double(21))
                    let a = major.length, ratio = e.double(40, 1)
                    guard a > 0, ratio > 0 else { continue }
                    let t0 = e.double(41, 0)
                    var t1 = e.double(42, 2 * .pi)
                    while t1 <= t0 { t1 += 2 * .pi }
                    let full = abs(t1 - t0 - 2 * .pi) < 1e-6
                    // ELLIPSE points are in WCS; a negative extrusion reverses the parameter direction.
                    let mirrored = e.double(230, 1) < 0
                    var b = PathBuilder(tolerance: tolerance, transform: transform)
                    b.arc(center: Vec2(e.double(10), e.double(20)), rx: a, ry: a * ratio, phi: atan2(major.y, major.x),
                          theta1: mirrored ? -t0 : t0, delta: mirrored ? -(t1 - t0) : (t1 - t0))
                    if full { b.close() }
                    polylines += b.finish()
                case "SPLINE":
                    spline(e, transform)
                case "INSERT":
                    insert(e, ocs, depth: depth)
                default:
                    break
                }
            }
        }

        /// Vertex list with per-vertex bulges (bulge = tan(θ/4), positive = counter-clockwise).
        mutating func polyline(_ vertices: [(Vec2, Double)], closed: Bool, _ transform: CGAffineTransform) {
            guard vertices.count >= 2 else { return }
            var b = PathBuilder(tolerance: tolerance, transform: transform)
            b.move(to: vertices[0].0)
            let segmentCount = closed ? vertices.count : vertices.count - 1
            for k in 0..<segmentCount {
                let (p, bulge) = vertices[k]
                let q = vertices[(k + 1) % vertices.count].0
                if abs(bulge) > 1e-12, p != q {
                    let theta = 4 * atan(bulge)
                    let d = q - p
                    let mid = (p + q) * 0.5
                    let center = mid + Vec2(-d.y, d.x) * ((1 - bulge * bulge) / (4 * bulge))
                    let r = center.distance(to: p)
                    let a0 = atan2(p.y - center.y, p.x - center.x)
                    b.arc(center: center, rx: r, ry: r, phi: 0, theta1: a0, delta: theta, end: q)
                } else {
                    b.line(to: q)
                }
            }
            if closed { b.close() }
            polylines += b.finish()
        }

        mutating func insert(_ e: Entity, _ transform: CGAffineTransform, depth: Int) {
            guard let name = e.string(2), let block = blocks[name] else { return }
            let sx = e.double(41, 1), sy = e.double(42, 1)
            let rotation = e.double(50) * .pi / 180
            let columns = max(1, e.int(70, 1)), rows = max(1, e.int(71, 1))
            let dx = e.double(44), dy = e.double(45)
            let position = Vec2(e.double(10), e.double(20))
            for row in 0..<rows {
                for column in 0..<columns {
                    let t = CGAffineTransform(translationX: -block.base.x, y: -block.base.y)
                        .concatenating(CGAffineTransform(scaleX: sx, y: sy))
                        .concatenating(CGAffineTransform(translationX: Double(column) * dx, y: Double(row) * dy))
                        .concatenating(CGAffineTransform(rotationAngle: rotation))
                        .concatenating(CGAffineTransform(translationX: position.x, y: position.y))
                    draw(block.entities, transform: t.concatenating(transform), depth: depth + 1)
                }
            }
        }

        mutating func spline(_ e: Entity, _ transform: CGAffineTransform) {
            let flags = e.int(70)
            let degree = max(1, e.int(71, 3))
            let xs = e.doubles(10), ys = e.doubles(20)
            let control = zip(xs, ys).map { Vec2($0, $1) }
            let closed = flags & 1 != 0
            var b = PathBuilder(tolerance: tolerance, transform: transform)
            if control.count < degree + 1 {
                // Fit points only: approximate by the polyline through them.
                let fit = zip(e.doubles(11), e.doubles(21)).map { Vec2($0, $1) }
                guard fit.count >= 2 else { return }
                b.move(to: fit[0])
                for p in fit.dropFirst() { b.line(to: p) }
                if closed { b.close() }
                polylines += b.finish()
                return
            }
            var knots = e.doubles(40)
            if knots.count != control.count + degree + 1 { knots = Self.clampedKnots(count: control.count, degree: degree) }
            var weights = e.doubles(41)
            if weights.count != control.count || weights.contains(where: { $0 <= 0 }) {
                weights = [Double](repeating: 1, count: control.count)
            }
            let nurbs = NURBS(degree: degree, knots: knots, control: control, weights: weights)
            let u0 = knots[degree], u1 = knots[control.count]
            guard u1 > u0 else { return }
            // Chord test in output units.
            let scale = PathBuilder.maxScale(transform)
            let tol = tolerance / max(scale, 1e-12)
            b.move(to: nurbs.point(u0))
            for span in degree..<control.count where knots[span + 1] > knots[span] {
                let a = knots[span], c = knots[span + 1]
                // At least 4 pieces per knot span so features are not skipped by the midpoint test.
                for k in 0..<4 {
                    let s0 = a + (c - a) * Double(k) / 4, s1 = a + (c - a) * Double(k + 1) / 4
                    refine(nurbs, s0, nurbs.point(s0), s1, nurbs.point(s1), tol, 0, &b)
                }
            }
            if closed { b.close() }
            polylines += b.finish()
        }

        func refine(_ n: NURBS, _ u0: Double, _ p0: Vec2, _ u1: Double, _ p1: Vec2, _ tol: Double, _ depth: Int,
                    _ b: inout PathBuilder) {
            let um = (u0 + u1) / 2
            let pm = n.point(um)
            let chord = p1 - p0
            let len = chord.length
            let deviation = len > 0 ? abs(chord.cross(pm - p0)) / len : pm.distance(to: p0)
            if depth < 14, deviation > tol {
                refine(n, u0, p0, um, pm, tol, depth + 1, &b)
                refine(n, um, pm, u1, p1, tol, depth + 1, &b)
            } else {
                b.line(to: p1)
            }
        }

        static func clampedKnots(count: Int, degree: Int) -> [Double] {
            let inner = max(0, count - degree - 1)
            var k = [Double](repeating: 0, count: degree + 1)
            if inner > 0 { for i in 1...inner { k.append(Double(i) / Double(inner + 1)) } }
            k += [Double](repeating: 1, count: degree + 1)
            return k
        }
    }

    /// Rational B-spline evaluated with de Boor's algorithm in homogeneous coordinates.
    struct NURBS {
        let degree: Int
        let knots: [Double]
        let control: [Vec2]
        let weights: [Double]

        func point(_ uIn: Double) -> Vec2 {
            let n = control.count
            let u = min(max(uIn, knots[degree]), knots[n])
            var span = degree
            while span < n - 1, u >= knots[span + 1] { span += 1 }
            var d: [(x: Double, y: Double, w: Double)] = (0...degree).map { j in
                let i = span - degree + j
                let w = weights[i]
                return (control[i].x * w, control[i].y * w, w)
            }
            if degree >= 1 {
                for r in 1...degree {
                    for j in stride(from: degree, through: r, by: -1) {
                        let i = span - degree + j
                        let denom = knots[i + degree - r + 1] - knots[i]
                        let alpha = denom > 0 ? (u - knots[i]) / denom : 0
                        d[j] = (d[j - 1].x * (1 - alpha) + d[j].x * alpha,
                                d[j - 1].y * (1 - alpha) + d[j].y * alpha,
                                d[j - 1].w * (1 - alpha) + d[j].w * alpha)
                    }
                }
            }
            let w = d[degree].w
            return w != 0 ? Vec2(d[degree].x / w, d[degree].y / w) : Vec2(d[degree].x, d[degree].y)
        }
    }
}
