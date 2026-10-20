import Foundation
import CoreGraphics
import MRCarveKit

enum EngineRasterTests {
    /// 8-bit gray image filled by `value(x, y)` (0 = black, 255 = white), row 0 at the top.
    static func grayImage(_ w: Int, _ h: Int, _ value: (Int, Int) -> UInt8) -> CGImage {
        var bytes = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h { for x in 0..<w { bytes[y * w + x] = value(x, y) } }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: w,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    /// RGBA image with every pixel `rgba`.
    static func rgbaImage(_ w: Int, _ h: Int, _ rgba: [UInt8]) -> CGImage {
        let bytes = (0..<(w * h)).flatMap { _ in rgba }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    static func settings(_ dither: DitherMode, interval: Double = 0.1) -> RasterSettings {
        var s = RasterSettings()
        s.dither = dither
        s.lineInterval = interval
        return s
    }

    static func register() {
        test("raster: grid size and gradient coverage ≈ 50 % for every dither") {
            let gradient = grayImage(256, 64) { x, _ in UInt8(x) }
            for mode in DitherMode.allCases {
                let bmp = RasterEngraver.bitmap(from: gradient, widthMM: 25.6, heightMM: 6.4, settings: settings(mode))
                expectEqual(bmp.width, 256)
                expectEqual(bmp.height, 64)
                let tol = mode == .atkinson ? 0.06 : 0.03  // Atkinson drops 1/4 of the error by design
                expect(abs(bmp.coverage - 0.5) < tol, "\(mode): coverage \(bmp.coverage)")
                // Dark (left) side is denser than the light side.
                var left = 0, right = 0
                for y in 0..<bmp.height {
                    for x in 0..<64 where bmp[x, y] { left += 1 }
                    for x in 192..<256 where bmp[x, y] { right += 1 }
                }
                expect(left > 3 * right, "\(mode): left \(left) right \(right)")
            }
            // Uniform mid-gray through ordered dithering is exactly half on.
            let mid = grayImage(64, 64) { _, _ in 128 }
            let ordered = RasterEngraver.bitmap(from: mid, widthMM: 6.4, heightMM: 6.4, settings: settings(.ordered))
            expect(abs(ordered.coverage - 0.5) < 0.02, "ordered \(ordered.coverage)")
            // Resampling follows widthMM / lineInterval.
            let small = RasterEngraver.bitmap(from: mid, widthMM: 10, heightMM: 5, settings: settings(.threshold, interval: 0.05))
            expectEqual(small.width, 200); expectEqual(small.height, 100)
            expectEqual(RasterEngraver.bitmap(from: mid, widthMM: 0, heightMM: 5, settings: settings(.threshold)).width, 0)
        }

        test("raster: tone controls, transparency, row order") {
            let black = grayImage(10, 10) { _, _ in 0 }
            var s = settings(.floydSteinberg)
            expectClose(RasterEngraver.bitmap(from: black, widthMM: 1, heightMM: 1, settings: s).coverage, 1)
            s.invert = true
            expectClose(RasterEngraver.bitmap(from: black, widthMM: 1, heightMM: 1, settings: s).coverage, 0)
            s.invert = false
            s.brightness = 1
            expectClose(RasterEngraver.bitmap(from: black, widthMM: 1, heightMM: 1, settings: s).coverage, 0)
            // Contrast pushes mid-gray (slightly dark) to black; gamma > 1 lightens.
            let gray = grayImage(10, 10) { _, _ in 120 }
            var t = settings(.floydSteinberg)
            t.contrast = 0.9
            expectClose(RasterEngraver.bitmap(from: gray, widthMM: 1, heightMM: 1, settings: t).coverage, 1)
            t.contrast = 0
            t.gamma = 3
            expect(RasterEngraver.bitmap(from: gray, widthMM: 1, heightMM: 1, settings: t).coverage < 0.3)
            // Fully transparent pixels count as white.
            let clear = rgbaImage(10, 10, [0, 0, 0, 0])
            expectClose(RasterEngraver.bitmap(from: clear, widthMM: 1, heightMM: 1, settings: settings(.threshold)).coverage, 0)
            // Threshold: pixels darker than the threshold are on.
            var th = settings(.threshold)
            th.threshold = 0.3
            expectClose(RasterEngraver.bitmap(from: gray, widthMM: 1, heightMM: 1, settings: th).coverage, 0)
            th.threshold = 0.6
            expectClose(RasterEngraver.bitmap(from: gray, widthMM: 1, heightMM: 1, settings: th).coverage, 1)
            // Row 0 is the top of the image: top half black.
            let topBlack = grayImage(10, 10) { _, y in y < 5 ? 0 : 255 }
            let bmp = RasterEngraver.bitmap(from: topBlack, widthMM: 1, heightMM: 1, settings: settings(.threshold))
            expect(bmp[3, 0] && !bmp[3, 9])
        }

        test("raster: scan lines, directions and preview") {
            // 4×3: row 0 = XX.X, row 1 = ...., row 2 = .XX.
            let px: [Bool] = [true, true, false, true, false, false, false, false, false, true, true, false]
            let bmp = Bitmap(width: 4, height: 3, pixels: px)
            let frame = Rect2(minX: 0, minY: 0, maxX: 4, maxY: 3)
            var s = RasterSettings()
            s.lineInterval = 1
            let lines = RasterEngraver.scanLines(bmp, frame: frame, settings: s)
            expectEqual(lines, [Polyline([Vec2(0, 2.5), Vec2(2, 2.5)]), Polyline([Vec2(3, 2.5), Vec2(4, 2.5)]),
                                Polyline([Vec2(3, 0.5), Vec2(1, 0.5)])])
            s.bidirectional = false
            let uni = RasterEngraver.scanLines(bmp, frame: frame, settings: s)
            expect(uni.allSatisfy { $0.points[1].x > $0.points[0].x })
            expectEqual(uni.count, 3)
            // Frame scaling: 2 mm per pixel horizontally.
            let wide = RasterEngraver.scanLines(bmp, frame: Rect2(minX: 10, minY: 0, maxX: 18, maxY: 3), settings: s)
            expectEqual(wide[0], Polyline([Vec2(10, 2.5), Vec2(14, 2.5)]))

            // Angled scanning of a full bitmap covers the frame with lines lineInterval apart.
            let full = Bitmap(width: 100, height: 100, pixels: [Bool](repeating: true, count: 10_000))
            var a = RasterSettings()
            a.lineInterval = 0.1
            let h = RasterEngraver.scanLines(full, frame: Rect2(minX: 0, minY: 0, maxX: 10, maxY: 10), settings: a)
            expectEqual(h.count, 100)
            a.scanAngle = 90
            let v = RasterEngraver.scanLines(full, frame: Rect2(minX: 0, minY: 0, maxX: 10, maxY: 10), settings: a)
            expect(v.allSatisfy { abs($0.points[0].x - $0.points[1].x) < 1e-9 })
            expectClose(EngineTestKit.totalLength(v), 1000, tolerance: 15)
            a.scanAngle = 45
            let d = RasterEngraver.scanLines(full, frame: Rect2(minX: 0, minY: 0, maxX: 10, maxY: 10), settings: a)
            expectClose(EngineTestKit.totalLength(d) * 0.1, 100, tolerance: 3)
            for l in d { for p in l.points { expect(p.x > -1e-9 && p.x < 10 + 1e-9 && p.y > -1e-9 && p.y < 10 + 1e-9) } }

            guard let image = RasterEngraver.previewImage(bmp) else { expect(false, "no preview"); return }
            expectEqual(image.width, 4); expectEqual(image.height, 3)
            let data = image.dataProvider!.data! as Data
            expectEqual(Array(data.prefix(4)), [0, 0, 255, 0])
            expect(RasterEngraver.previewImage(Bitmap(width: 0, height: 0, pixels: [])) == nil)
        }

        test("raster: large image performance") {
            let image = grayImage(1400, 1400) { x, y in UInt8((x ^ y) & 0xFF) }
            var s = RasterSettings()
            s.lineInterval = 0.02  // 70 mm → 3500 × 3500
            var bmp = Bitmap(width: 0, height: 0, pixels: [])
            let seconds = EngineTestKit.time { bmp = RasterEngraver.bitmap(from: image, widthMM: 70, heightMM: 70, settings: s) }
            var lines: [Polyline] = []
            let scan = EngineTestKit.time { lines = RasterEngraver.scanLines(bmp, frame: Rect2(minX: -35, minY: -35, maxX: 35, maxY: 35), settings: s) }
            print("    raster: \(bmp.width)×\(bmp.height) dithered in \(String(format: "%.2f", seconds)) s, \(lines.count) scan segments in \(String(format: "%.2f", scan)) s")
            expectEqual(bmp.width, 3500)
            expect(seconds < 30)
        }
    }
}
