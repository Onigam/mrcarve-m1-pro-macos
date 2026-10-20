import Foundation

/// HPGL (`.plt` / `.hpgl`) → polylines. 1 plotter unit = 0.025 mm, +Y up.
///
/// Supported: IN, PU, PD, PA, PR, CI, AA, AR, EA, ER. Other instructions (SP, LT, VS, ...) are ignored;
/// LB labels are skipped up to their terminator. Scaling (SC) and rotation (RO) are not supported.
enum HPGLImporter {
    static let mmPerUnit = 0.025

    static func load(data: Data, tolerance: Double) throws -> [Polyline] {
        let bytes = [UInt8](data)
        var builder = PathBuilder(tolerance: tolerance, transform: CGAffineTransform(scaleX: mmPerUnit, y: mmPerUnit))
        var pen = Vec2.zero
        var penDown = false, absolute = true, drawing = false
        var labelTerminator: UInt8 = 0x03
        var sawInstruction = false
        var i = 0

        func isLetter(_ c: UInt8) -> Bool { (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) }

        /// Numeric parameters up to the next instruction or terminator.
        func parameters() -> [Double] {
            var values: [Double] = []
            while i < bytes.count {
                let c = bytes[i]
                if c == UInt8(ascii: ";") { i += 1; break }
                if isLetter(c) { break }
                if c == UInt8(ascii: "-") || c == UInt8(ascii: "+") || c == UInt8(ascii: ".") || SVGScanner.isDigit(c) {
                    let start = i
                    i += 1
                    while i < bytes.count, SVGScanner.isDigit(bytes[i]) || bytes[i] == UInt8(ascii: ".") { i += 1 }
                    if let v = Double(String(decoding: bytes[start..<i], as: UTF8.self)) { values.append(v) }
                } else {
                    i += 1
                }
            }
            return values
        }

        func moveOrDraw(to p: Vec2) {
            if penDown {
                if !drawing { builder.move(to: pen); drawing = true }
                builder.line(to: p)
            } else if drawing {
                closeIfLooped()
                drawing = false
            }
            pen = p
        }

        /// Ends the drawn subpath, closing it when it returned to its start.
        func closeIfLooped() {
            if builder.current.distance(to: builder.subpathStart) < 1e-9 { builder.close() } else { builder.endSubpath() }
        }

        func arc(center: Vec2, sweepDegrees: Double) {
            let r = pen.distance(to: center)
            guard r > 0 else { return }
            let a0 = atan2(pen.y - center.y, pen.x - center.x)
            let delta = sweepDegrees * .pi / 180
            let end = Vec2(center.x + r * cos(a0 + delta), center.y + r * sin(a0 + delta))
            if penDown {
                if !drawing { builder.move(to: pen); drawing = true }
                builder.arc(center: center, rx: r, ry: r, phi: 0, theta1: a0, delta: delta, end: end)
            }
            pen = end
        }

        while i < bytes.count {
            let c = bytes[i]
            guard isLetter(c), i + 1 < bytes.count, isLetter(bytes[i + 1]) else { i += 1; continue }
            let mnemonic = String(decoding: bytes[i..<(i + 2)], as: UTF8.self).uppercased()
            i += 2
            sawInstruction = true
            switch mnemonic {
            case "IN":
                _ = parameters()
                if drawing { closeIfLooped(); drawing = false }
                pen = .zero; penDown = false; absolute = true
            case "PA", "PR", "PU", "PD":
                if mnemonic == "PA" { absolute = true }
                if mnemonic == "PR" { absolute = false }
                if mnemonic == "PU" {
                    if drawing { closeIfLooped(); drawing = false }
                    penDown = false
                }
                if mnemonic == "PD" { penDown = true }
                let v = parameters()
                var k = 0
                while k + 1 < v.count {
                    let p = absolute ? Vec2(v[k], v[k + 1]) : pen + Vec2(v[k], v[k + 1])
                    moveOrDraw(to: p)
                    k += 2
                }
            case "CI":
                let v = parameters()
                guard let r = v.first, r != 0 else { continue }
                let r0 = abs(r)
                var circle = PathBuilder(tolerance: tolerance, transform: CGAffineTransform(scaleX: mmPerUnit, y: mmPerUnit))
                circle.arc(center: pen, rx: r0, ry: r0, phi: 0, theta1: 0, delta: 2 * .pi, end: Vec2(pen.x + r0, pen.y))
                circle.close()
                let circles = circle.finish()
                builder.appendFinished(circles)
            case "AA", "AR":
                let v = parameters()
                guard v.count >= 3 else { continue }
                let center = mnemonic == "AA" ? Vec2(v[0], v[1]) : pen + Vec2(v[0], v[1])
                arc(center: center, sweepDegrees: v[2])
            case "EA", "ER":
                let v = parameters()
                guard v.count >= 2 else { continue }
                let corner = mnemonic == "EA" ? Vec2(v[0], v[1]) : pen + Vec2(v[0], v[1])
                var rect = PathBuilder(tolerance: tolerance, transform: CGAffineTransform(scaleX: mmPerUnit, y: mmPerUnit))
                rect.move(to: pen)
                rect.line(to: Vec2(corner.x, pen.y)); rect.line(to: corner); rect.line(to: Vec2(pen.x, corner.y))
                rect.close()
                builder.appendFinished(rect.finish())
            case "DT":
                if i < bytes.count, bytes[i] != UInt8(ascii: ";") { labelTerminator = bytes[i]; i += 1 }
                if i < bytes.count, bytes[i] == UInt8(ascii: ";") { i += 1 }
            case "LB":
                while i < bytes.count, bytes[i] != labelTerminator { i += 1 }
                i += 1
            default:
                _ = parameters()
            }
        }
        guard sawInstruction else { throw VectorImportError.unreadable("no HPGL instructions found") }
        if drawing { closeIfLooped() }
        return builder.finish()
    }
}
