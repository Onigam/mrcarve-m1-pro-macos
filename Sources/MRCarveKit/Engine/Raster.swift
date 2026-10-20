import Foundation
import CoreGraphics

/// Implementation behind `RasterEngraver`.
enum Raster {
    /// Largest scan grid accepted (pixels per side), ~0.005 mm over the 70 mm field.
    static let maxDimension = 16_384

    static func gridSize(widthMM: Double, heightMM: Double, interval: Double) -> (Int, Int)? {
        guard widthMM > 0, heightMM > 0, interval > 0, widthMM.isFinite, heightMM.isFinite else { return nil }
        let w = Int((widthMM / interval).rounded()), h = Int((heightMM / interval).rounded())
        return (min(maxDimension, max(1, w)), min(maxDimension, max(1, h)))
    }

    /// Renders `image` into an 8-bit gray buffer of `width`×`height`, row 0 at the top, transparency → white.
    static func grayscale(_ image: CGImage, width: Int, height: Int) -> [UInt8]? {
        var buffer = [UInt8](repeating: 255, count: width * height)
        let ok = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.setFillColor(gray: 1, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return ok ? buffer : nil
    }

    /// Lookup table applying brightness, contrast, gamma and invert to 8-bit luminance (0 = black, 1 = white).
    static func toneCurve(_ s: RasterSettings) -> [Float] {
        let c = max(-1, min(0.99, s.contrast))
        let contrast = (1 + c) / (1 - c)
        let gamma = s.gamma > 0 && s.gamma.isFinite ? s.gamma : 1
        return (0..<256).map { i in
            var v = Double(i) / 255 + s.brightness
            v = (v - 0.5) * contrast + 0.5
            v = min(1, max(0, v))
            v = pow(v, 1 / gamma)
            if s.invert { v = 1 - v }
            return Float(v)
        }
    }

    /// Dithers 8-bit gray pixels, mapped through `curve` (0 = black = laser on), into on/off pixels.
    static func dither(_ gray: [UInt8], curve: [Float], width: Int, height: Int, settings s: RasterSettings) -> [Bool] {
        switch s.dither {
        case .threshold:
            let t = Float(s.threshold)
            let on = curve.map { $0 < t }
            return gray.map { on[Int($0)] }
        case .ordered:
            var out = [Bool](repeating: false, count: gray.count)
            for y in 0..<height {
                for x in 0..<width {
                    // Darkness above the cell's threshold (k + 0.5) / 64 turns the pixel on.
                    let t = (Float(bayer8[(y & 7) * 8 + (x & 7)]) + 0.5) / 64
                    out[y * width + x] = 1 - curve[Int(gray[y * width + x])] > t
                }
            }
            return out
        case .floydSteinberg:
            return diffuse(gray, curve, width, height, kernel: floydSteinberg, divisor: 16)
        case .jarvis:
            return diffuse(gray, curve, width, height, kernel: jarvis, divisor: 48)
        case .stucki:
            return diffuse(gray, curve, width, height, kernel: stucki, divisor: 42)
        case .atkinson:
            return diffuse(gray, curve, width, height, kernel: atkinson, divisor: 8)
        }
    }

    typealias Kernel = [(dx: Int, dy: Int, w: Float)]
    static let floydSteinberg: Kernel = [(1, 0, 7), (-1, 1, 3), (0, 1, 5), (1, 1, 1)]
    static let jarvis: Kernel = [(1, 0, 7), (2, 0, 5),
                                 (-2, 1, 3), (-1, 1, 5), (0, 1, 7), (1, 1, 5), (2, 1, 3),
                                 (-2, 2, 1), (-1, 2, 3), (0, 2, 5), (1, 2, 3), (2, 2, 1)]
    static let stucki: Kernel = [(1, 0, 8), (2, 0, 4),
                                 (-2, 1, 2), (-1, 1, 4), (0, 1, 8), (1, 1, 4), (2, 1, 2),
                                 (-2, 2, 1), (-1, 2, 2), (0, 2, 4), (1, 2, 2), (2, 2, 1)]
    /// Atkinson diffuses only 6/8 of the error (by design).
    static let atkinson: Kernel = [(1, 0, 1), (2, 0, 1), (-1, 1, 1), (0, 1, 1), (1, 1, 1), (0, 2, 1)]

    static let bayer8: [UInt8] = [
        0, 32, 8, 40, 2, 34, 10, 42,
        48, 16, 56, 24, 50, 18, 58, 26,
        12, 44, 4, 36, 14, 46, 6, 38,
        60, 28, 52, 20, 62, 30, 54, 22,
        3, 35, 11, 43, 1, 33, 9, 41,
        51, 19, 59, 27, 49, 17, 57, 25,
        15, 47, 7, 39, 13, 45, 5, 37,
        63, 31, 55, 23, 61, 29, 53, 21,
    ]

    /// Serpentine error diffusion with a 3-row rolling error buffer (memory O(width)).
    static func diffuse(_ gray: [UInt8], _ curve: [Float], _ width: Int, _ height: Int,
                        kernel: Kernel, divisor: Float) -> [Bool] {
        var out = [Bool](repeating: false, count: width * height)
        let pad = 2, stride = width + 2 * pad
        var errors = [Float](repeating: 0, count: 3 * stride)
        let taps = kernel.map { (dx: $0.dx, dy: $0.dy, w: $0.w / divisor) }
        gray.withUnsafeBufferPointer { src in
            curve.withUnsafeBufferPointer { lut in
                out.withUnsafeMutableBufferPointer { dst in
                    errors.withUnsafeMutableBufferPointer { err in
                        for y in 0..<height {
                            let forward = y.isMultiple(of: 2)
                            let rowBase = [(y % 3) * stride, ((y + 1) % 3) * stride, ((y + 2) % 3) * stride]
                            for step in 0..<width {
                                let x = forward ? step : width - 1 - step
                                let i = y * width + x
                                let v = lut[Int(src[i])] + err[rowBase[0] + x + pad]
                                let on = v < 0.5
                                dst[i] = on
                                let e = v - (on ? 0 : 1)
                                for t in taps {
                                    err[rowBase[t.dy] + x + pad + (forward ? t.dx : -t.dx)] += e * t.w
                                }
                            }
                            // The current row becomes the row two below: clear it.
                            for k in 0..<stride { err[rowBase[0] + k] = 0 }
                        }
                    }
                }
            }
        }
        return out
    }

    static func bitmap(from image: CGImage, widthMM: Double, heightMM: Double, settings: RasterSettings) -> Bitmap {
        guard let (w, h) = gridSize(widthMM: widthMM, heightMM: heightMM, interval: settings.lineInterval),
              let gray = grayscale(image, width: w, height: h) else {
            return Bitmap(width: 0, height: 0, pixels: [])
        }
        let pixels = dither(gray, curve: toneCurve(settings), width: w, height: h, settings: settings)
        return Bitmap(width: w, height: h, pixels: pixels)
    }

    // MARK: Scan lines

    static func scanLines(_ bitmap: Bitmap, frame: Rect2, settings: RasterSettings) -> [Polyline] {
        guard bitmap.width > 0, bitmap.height > 0, bitmap.pixels.count == bitmap.width * bitmap.height,
              frame.width > 0, frame.height > 0 else { return [] }
        let angle = settings.scanAngle.truncatingRemainder(dividingBy: 360)
        if abs(angle) < 1e-9 { return horizontalScanLines(bitmap, frame: frame, bidirectional: settings.bidirectional) }
        return angledScanLines(bitmap, frame: frame, settings: settings)
    }

    /// One segment per run of "on" pixels, from the left edge of the first pixel to the right edge of the last.
    static func horizontalScanLines(_ bitmap: Bitmap, frame: Rect2, bidirectional: Bool) -> [Polyline] {
        let px = frame.width / Double(bitmap.width), py = frame.height / Double(bitmap.height)
        var lines: [Polyline] = []
        var emittedRows = 0
        var runs: [(Int, Int)] = []
        for row in 0..<bitmap.height {
            runs.removeAll(keepingCapacity: true)
            let base = row * bitmap.width
            var x = 0
            while x < bitmap.width {
                if bitmap.pixels[base + x] {
                    let s = x
                    while x < bitmap.width, bitmap.pixels[base + x] { x += 1 }
                    runs.append((s, x))
                } else {
                    x += 1
                }
            }
            guard !runs.isEmpty else { continue }
            let y = frame.maxY - (Double(row) + 0.5) * py
            let reverse = bidirectional && !emittedRows.isMultiple(of: 2)
            emittedRows += 1
            let ordered = reverse ? runs.reversed() : runs
            for (s, e) in ordered {
                let a = Vec2(frame.minX + Double(s) * px, y), b = Vec2(frame.minX + Double(e) * px, y)
                lines.append(Polyline(reverse ? [b, a] : [a, b]))
            }
        }
        return lines
    }

    /// Scan lines at `scanAngle` (degrees, counter-clockwise), `lineInterval` apart, sampling the bitmap
    /// (nearest pixel) every `lineInterval / 2` along each line.
    static func angledScanLines(_ bitmap: Bitmap, frame: Rect2, settings: RasterSettings) -> [Polyline] {
        let theta = settings.scanAngle * .pi / 180
        let u = Vec2(cos(theta), sin(theta)), n = Vec2(-sin(theta), cos(theta))
        let pitch = settings.lineInterval > 0 ? settings.lineInterval : min(frame.width / Double(bitmap.width),
                                                                           frame.height / Double(bitmap.height))
        let step = pitch / 2
        let corners = [Vec2(frame.minX, frame.minY), Vec2(frame.maxX, frame.minY),
                       Vec2(frame.maxX, frame.maxY), Vec2(frame.minX, frame.maxY)]
        let offsets = corners.map { $0.dot(n) }
        let nMin = offsets.min()!, nMax = offsets.max()!
        let px = frame.width / Double(bitmap.width), py = frame.height / Double(bitmap.height)
        func isOn(_ p: Vec2) -> Bool {
            let col = Int(((p.x - frame.minX) / px).rounded(.down))
            let row = Int(((frame.maxY - p.y) / py).rounded(.down))
            guard col >= 0, col < bitmap.width, row >= 0, row < bitmap.height else { return false }
            return bitmap.pixels[row * bitmap.width + col]
        }
        var lines: [Polyline] = []
        var emitted = 0
        // From the top of the frame (largest normal offset) downwards, like horizontal rows.
        var offset = nMax - pitch / 2
        while offset > nMin {
            // Clip the infinite line {offset·n + t·u} to the frame.
            var tMin = -Double.infinity, tMax = Double.infinity
            let origin = n * offset
            for (o, d, lo, hi) in [(origin.x, u.x, frame.minX, frame.maxX), (origin.y, u.y, frame.minY, frame.maxY)] {
                if abs(d) < 1e-12 {
                    if o < lo || o > hi { tMin = .infinity }
                } else {
                    let t0 = (lo - o) / d, t1 = (hi - o) / d
                    tMin = max(tMin, min(t0, t1)); tMax = min(tMax, max(t0, t1))
                }
            }
            if tMin < tMax {
                var runs: [(Double, Double)] = []
                let count = Int(((tMax - tMin) / step).rounded(.down))
                var runStart: Double?
                for i in 0...max(0, count) {
                    let t = tMin + (Double(i) + 0.5) * step
                    if t >= tMax { break }
                    let on = isOn(origin + u * t)
                    if on, runStart == nil { runStart = t - step / 2 }
                    if !on, let s = runStart { runs.append((s, t - step / 2)); runStart = nil }
                }
                if let s = runStart { runs.append((s, tMax)) }
                if !runs.isEmpty {
                    let reverse = settings.bidirectional && !emitted.isMultiple(of: 2)
                    emitted += 1
                    for (s, e) in reverse ? runs.reversed() : runs {
                        let a = origin + u * s, b = origin + u * e
                        lines.append(Polyline(reverse ? [b, a] : [a, b]))
                    }
                }
            }
            offset -= pitch
        }
        return lines
    }

    // MARK: Preview

    static func previewImage(_ bitmap: Bitmap) -> CGImage? {
        guard bitmap.width > 0, bitmap.height > 0, bitmap.pixels.count == bitmap.width * bitmap.height else { return nil }
        let bytes = bitmap.pixels.map { $0 ? UInt8(0) : UInt8(255) }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: bitmap.width, height: bitmap.height, bitsPerComponent: 8, bitsPerPixel: 8,
                       bytesPerRow: bitmap.width, space: CGColorSpaceCreateDeviceGray(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
