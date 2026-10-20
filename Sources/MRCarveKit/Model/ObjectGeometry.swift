import Foundation
import CoreGraphics

/// Default chord tolerance (mm) used when flattening curves.
public let defaultFlatteningTolerance = 0.01

extension DesignObject {
    // MARK: Outlines

    /// Outline polylines in field coordinates (mm). Images return their frame rectangle (which is not marked).
    public func outlines(tolerance: Double = defaultFlatteningTolerance) -> [Polyline] {
        let t = placement.transform
        return localOutlines(tolerance: tolerance).map { $0.applying(t) }
    }

    /// Outline polylines in the local frame: centred on the origin and already at the placement size.
    public func localOutlines(tolerance: Double = defaultFlatteningTolerance) -> [Polyline] {
        let w = placement.width, h = placement.height
        switch kind {
        case .rectangle(let radius):
            return [ShapeGeometry.roundedRectangle(width: w, height: h, cornerRadius: radius, tolerance: tolerance)]
        case .ellipse:
            return [ShapeGeometry.ellipse(width: w, height: h, tolerance: tolerance)]
        case .line:
            return [Polyline([Vec2(-w / 2, 0), Vec2(w / 2, 0)])]
        case .image:
            return [placement.localBox.outline]
        case .polygon, .text, .vector:
            let natural = naturalOutlines(tolerance: tolerance)
            return ShapeGeometry.fit(natural, width: w, height: h)
        }
    }

    /// Geometry in the object's own units before it is fitted into the placement box
    /// (text at its font size, vectors at their imported size, polygons in a unit circle).
    public func naturalOutlines(tolerance: Double = defaultFlatteningTolerance) -> [Polyline] {
        switch kind {
        case .text(let t):
            guard !t.string.isEmpty else { return [] }
            return TextOutliner.polylines(text: t.string, fontName: t.fontFamily, height: t.height,
                                          letterSpacing: t.letterSpacing, lineSpacing: t.lineSpacing,
                                          alignment: t.alignment, tolerance: tolerance)
        case .vector(let v):
            return v.polylines
        case .polygon(let sides, let star):
            return [ShapeGeometry.polygon(sides: sides, starRatio: star)]
        default:
            return localOutlines(tolerance: tolerance)
        }
    }

    /// Sets the placement size to the natural size of the content (1:1), keeping the centre.
    /// Text without available glyph outlines gets an estimated box so it stays selectable.
    public mutating func fitToContent() {
        switch kind {
        case .text(let t):
            if let b = naturalBounds, b.width > 0 || b.height > 0 {
                placement.width = b.width
                placement.height = b.height
            } else {
                let lines = t.string.components(separatedBy: .newlines)
                let longest = lines.map(\.count).max() ?? 1
                placement.width = max(t.height * 0.6 * Double(max(1, longest)), t.height * 0.5)
                placement.height = t.height * (1 + Double(max(0, lines.count - 1)) * t.lineSpacing)
            }
        case .vector:
            if let b = naturalBounds {
                placement.width = b.width
                placement.height = b.height
            }
        case .image(let img):
            let area = placement.width * placement.height
            let aspect = img.aspectRatio
            placement.width = (area * aspect).squareRoot()
            placement.height = placement.width / aspect
        default:
            break
        }
    }

    /// Bounds of `naturalOutlines`, if any.
    public var naturalBounds: Rect2? {
        naturalOutlines().compactMap(\.bounds).reduce(nil) { $0?.union($1) ?? $1 }
    }

    /// Axis-aligned bounds of the outline in field coordinates (falls back to the placement box).
    public func fieldBounds(tolerance: Double = 0.05) -> Rect2 {
        outlines(tolerance: tolerance).compactMap(\.bounds).reduce(nil) { $0?.union($1) ?? $1 } ?? placement.boundingBox
    }

    // MARK: Fill & raster

    /// Hatch lines for one fill layer, in field coordinates. The hatch angle is absolute (field X axis).
    public func hatchLines(layer: HatchLayer, tolerance: Double = defaultFlatteningTolerance) -> [Polyline] {
        guard kind.supportsFill else { return [] }
        let contours = outlines(tolerance: tolerance).filter { $0.isClosed && $0.points.count > 2 }
        guard !contours.isEmpty else { return [] }
        return HatchFill.hatch(contours, layer: layer)
    }

    /// The image resampled and dithered to the scan grid, or nil for non-image objects.
    public func rasterBitmap() -> Bitmap? {
        guard case .image(let img) = kind, let cg = img.cgImage,
              placement.width > 0, placement.height > 0 else { return nil }
        let bitmap = RasterEngraver.bitmap(from: cg, widthMM: placement.width, heightMM: placement.height, settings: img.raster)
        return bitmap.width > 0 && bitmap.height > 0 ? bitmap : nil
    }

    /// Raster scan-line segments in field coordinates (empty for non-image objects).
    public func rasterScanLines() -> [Polyline] {
        guard case .image(let img) = kind, let bitmap = rasterBitmap() else { return [] }
        let t = placement.transform
        return RasterEngraver.scanLines(bitmap, frame: placement.localBox, settings: img.raster).map { $0.applying(t) }
    }
}

/// Analytic generators for the built-in shapes (no dependency on the engine).
public enum ShapeGeometry {
    /// Number of segments for an arc of `radius` spanning `angle` radians with max chord error `tolerance`.
    public static func segmentCount(radius: Double, angle: Double, tolerance: Double) -> Int {
        guard radius > tolerance, tolerance > 0 else { return 1 }
        let step = 2 * acos(max(-1, min(1, 1 - tolerance / radius)))
        guard step > 0 else { return 64 }
        return min(4096, max(2, Int((abs(angle) / step).rounded(.up))))
    }

    /// Closed rectangle centred on the origin, counter-clockwise from the bottom-left corner.
    public static func roundedRectangle(width w: Double, height h: Double, cornerRadius: Double, tolerance: Double) -> Polyline {
        let r = max(0, min(cornerRadius, min(w, h) / 2))
        let x0 = -w / 2, x1 = w / 2, y0 = -h / 2, y1 = h / 2
        guard r > 1e-9 else {
            return Polyline([Vec2(x0, y0), Vec2(x1, y0), Vec2(x1, y1), Vec2(x0, y1)], closed: true)
        }
        let n = max(2, segmentCount(radius: r, angle: .pi / 2, tolerance: tolerance))
        var points: [Vec2] = []
        // Corner centres, each arc swept counter-clockwise starting at the given angle.
        let corners: [(Vec2, Double)] = [
            (Vec2(x1 - r, y0 + r), -.pi / 2),  // bottom-right
            (Vec2(x1 - r, y1 - r), 0),         // top-right
            (Vec2(x0 + r, y1 - r), .pi / 2),   // top-left
            (Vec2(x0 + r, y0 + r), .pi),       // bottom-left
        ]
        for (c, start) in corners {
            for i in 0...n {
                let a = start + Double(i) / Double(n) * .pi / 2
                points.append(Vec2(c.x + r * cos(a), c.y + r * sin(a)))
            }
        }
        // Drop zero-length edges where adjacent arcs meet (full-radius sides).
        var cleaned: [Vec2] = []
        for p in points where cleaned.last.map({ $0.distance(to: p) > 1e-9 }) ?? true { cleaned.append(p) }
        if let f = cleaned.first, let l = cleaned.last, cleaned.count > 1, f.distance(to: l) <= 1e-9 { cleaned.removeLast() }
        return Polyline(cleaned, closed: true)
    }

    /// Closed ellipse inscribed in a `w`×`h` box centred on the origin, counter-clockwise from +X.
    public static func ellipse(width w: Double, height h: Double, tolerance: Double) -> Polyline {
        let rx = w / 2, ry = h / 2
        let n = max(16, segmentCount(radius: max(rx, ry), angle: 2 * .pi, tolerance: tolerance))
        let points = (0..<n).map { i -> Vec2 in
            let a = Double(i) / Double(n) * 2 * .pi
            return Vec2(rx * cos(a), ry * sin(a))
        }
        return Polyline(points, closed: true)
    }

    /// Regular polygon (or star) in the unit circle, first vertex pointing up.
    public static func polygon(sides: Int, starRatio: Double?) -> Polyline {
        let n = max(3, sides)
        var points: [Vec2] = []
        if let ratio = starRatio {
            let inner = max(0.01, min(1, ratio))
            for i in 0..<(2 * n) {
                let a = .pi / 2 + Double(i) * .pi / Double(n)
                let r = i.isMultiple(of: 2) ? 1 : inner
                points.append(Vec2(r * cos(a), r * sin(a)))
            }
        } else {
            for i in 0..<n {
                let a = .pi / 2 + Double(i) * 2 * .pi / Double(n)
                points.append(Vec2(cos(a), sin(a)))
            }
        }
        return Polyline(points, closed: true)
    }

    /// Scales `polylines` so their joint bounds fill a `w`×`h` box centred on the origin.
    /// A degenerate dimension (e.g. a horizontal path) is centred without scaling.
    public static func fit(_ polylines: [Polyline], width w: Double, height h: Double) -> [Polyline] {
        guard let b = polylines.compactMap(\.bounds).reduce(nil, { $0?.union($1) ?? $1 }) else { return [] }
        let sx = b.width > 1e-9 ? w / b.width : 1
        let sy = b.height > 1e-9 ? h / b.height : 1
        let c = b.center
        let t = CGAffineTransform(scaleX: sx, y: sy).translatedBy(x: -c.x, y: -c.y)
        return polylines.map { $0.applying(t) }
    }
}
