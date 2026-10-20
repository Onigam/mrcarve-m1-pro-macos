import Foundation
import CoreGraphics

// Public engine API used by the app. Signatures are the contract between the engine and the UI:
// implementations may change freely, signatures may only gain parameters with default values.
// All geometry is in millimetres, +Y up (see `Vec2`).
//
// Implementations live next to this file (PathBuilder, TextLayout, Hatcher, GreedyRouter, SVGImporter,
// DXFImporter, HPGLImporter, Raster, GeometryOps); `VendorConfig` lives in Config/VendorConfig.swift.

// MARK: - Path flattening

public enum PathFlattener {
    /// Flattens a CGPath (lines, quad/cubic Béziers, arcs) into polylines with max chord error `tolerance` (mm).
    /// Each subpath becomes one polyline; `closeSubpath` yields `isClosed = true`.
    /// Cubics are subdivided adaptively (the distance between curve and chord is bounded by `tolerance`),
    /// quadratics are sampled uniformly with the exact error bound. Consecutive duplicate points, a closing
    /// point equal to the start, and single-point subpaths are dropped.
    public static func polylines(from path: CGPath, tolerance: Double = 0.01) -> [Polyline] {
        var builder = PathBuilder(tolerance: tolerance)
        builder.append(path)
        return builder.finish()
    }
}

// MARK: - Text

public enum TextAlignment: String, Codable, Hashable, Sendable, CaseIterable { case left, center, right }

public enum TextOutliner {
    /// Outlines `text` (may contain newlines) using an installed font. `height` is the em size in mm.
    /// Result: closed glyph contours, first line's baseline at y = 0, starting at x = 0 (before alignment).
    ///
    /// - `fontName`: a family name ("Helvetica Neue"), PostScript name ("Helvetica-Bold") or full name;
    ///   unknown names fall back to Helvetica. Characters missing from the font use CoreText's fallback fonts.
    /// - `letterSpacing`: extra space after each character except the last of a line, mm.
    /// - `lineSpacing`: baseline-to-baseline distance as a multiple of `height` (line n has its baseline at
    ///   y = −n·lineSpacing·height).
    /// - `alignment`: per line, relative to x = 0 (left: starts at 0, center: centred on 0, right: ends at 0);
    ///   trailing whitespace is ignored for alignment.
    public static func polylines(text: String, fontName: String, height: Double,
                                 letterSpacing: Double = 0, lineSpacing: Double = 1.2,
                                 alignment: TextAlignment = .left, tolerance: Double = 0.01) -> [Polyline] {
        TextLayout.outline(text: text, fontName: fontName, height: height, letterSpacing: letterSpacing,
                           lineSpacing: lineSpacing, alignment: alignment, tolerance: tolerance)
    }

    /// Family names of installed fonts, sorted, for the font picker.
    public static func availableFontFamilies() -> [String] { TextLayout.familyNames() }
}

// MARK: - Hatch fill

/// Geometry produced by a hatch layer.
public enum HatchPattern: String, Codable, Hashable, Sendable, CaseIterable {
    /// Parallel lines at `angle`, `spacing` apart (optionally cross-hatched).
    case lines
    /// Closed rings following the outline, `spacing` apart (vendor "circular" fill).
    case concentric
}

public struct HatchLayer: Codable, Hashable, Sendable {
    public var isEnabled: Bool = true
    public var angle: Double = 0            // degrees, counter-clockwise from +X (0 = horizontal lines)
    public var spacing: Double = 0.05       // mm between lines
    public var crossHatch: Bool = false     // add a second pass at angle + 90°
    public var bidirectional: Bool = true   // alternate line direction (zig-zag order)
    public var borderOffset: Double = 0     // mm, inset from the outline before hatching (negative = outset)
    public var startOffset: Double = 0      // mm, offset of the first line
    public var autoRotateAngle: Double = 0  // degrees added per loop/pass (0 = off)
    public var penID: Int? = nil            // nil = use the object's pen
    /// mm, distance of the last line from the far side of the shape (vendor "End Offset").
    public var endOffset: Double = 0
    /// Spread the lines evenly over the shape's extent across the hatch direction: the spacing is adjusted
    /// slightly so the first and last lines sit half a spacing from the (offset) outline
    /// (vendor "Evenly Distributed Fill Line"). `startOffset` / `endOffset` still shrink the extent.
    public var evenDistribution: Bool = false
    /// Lines (default) or concentric rings.
    public var pattern: HatchPattern = .lines
    public init() {}
}

public struct FillSettings: Codable, Hashable, Sendable {
    public var layers: [HatchLayer] = [HatchLayer()]   // the vendor UI offers up to 4
    public var markOutline: Bool = true
    public var outlineFirst: Bool = true
    public init() {}
}

public enum HatchFill {
    /// Hatches the area enclosed by `contours` (even-odd rule) and returns the hatch lines, ordered for marking.
    ///
    /// - Only closed polylines with at least 3 points take part; open polylines are ignored.
    /// - Lines run along `angle` (direction (cos a, sin a)); in the frame rotated by −angle they lie at
    ///   y = minY + startOffset + k·spacing (or evenly distributed, see `HatchLayer.evenDistribution`).
    ///   Lines exactly on a vertex or horizontal edge are resolved with half-open edges.
    /// - `borderOffset` erodes (or, negative, dilates) the region by a disk before hatching — exact,
    ///   equivalent to a round-join offset of the outline; holes grow accordingly.
    /// - Each result is a 2-point polyline. Lines are grouped into bands of overlapping lines on consecutive
    ///   scanlines; each band is marked zig-zag (`bidirectional`) or always in the +angle direction, and bands
    ///   are ordered by nearest neighbour. With `crossHatch`, the pass at angle + 90° follows the first pass.
    /// - `isEnabled` and `autoRotateAngle` are not applied here (the job compiler handles passes).
    /// - `.concentric`: closed rings at inset distances borderOffset + startOffset + k·spacing, k ≥ 1
    ///   (so with the outline marked, rings are evenly pitched from the outline inwards); angle, cross-hatch,
    ///   direction and end offset do not apply. Rings are ordered by nearest neighbour.
    public static func hatch(_ contours: [Polyline], layer: HatchLayer) -> [Polyline] {
        if layer.pattern == .concentric {
            return OffsetFill.rings(contours, spacing: layer.spacing,
                                    first: layer.borderOffset + layer.startOffset + layer.spacing)
        }
        var params = Hatcher.Parameters(angle: layer.angle, spacing: layer.spacing)
        params.startOffset = layer.startOffset
        params.endOffset = layer.endOffset
        params.evenDistribution = layer.evenDistribution
        params.borderOffset = layer.borderOffset
        params.bidirectional = layer.bidirectional
        let first = Hatcher.hatch(contours, params)
        guard layer.crossHatch else { return first.lines }
        params.angle += 90
        let second = Hatcher.hatch(contours, params, start: first.end)
        return first.lines + second.lines
    }
}

// MARK: - Path ordering

public enum PathOptimizer {
    /// Reorders (and optionally reverses open) polylines to minimise laser-off travel, starting near `start`.
    ///
    /// Greedy nearest neighbour over a spatial grid (≈ O(n log n)). Open polylines may be entered from
    /// either end when `allowReverse`; closed polylines are rotated to start at their vertex nearest to the
    /// current position (regardless of `allowReverse`; their direction is kept). Empty polylines go last.
    public static func order(_ polylines: [Polyline], start: Vec2 = .zero, allowReverse: Bool = true) -> [Polyline] {
        guard polylines.count > 1 || polylines.first?.isClosed == true else { return polylines }
        var entries: [GreedyRouter.Entry] = []
        entries.reserveCapacity(polylines.count * 2)
        for (i, p) in polylines.enumerated() where !p.points.isEmpty {
            if p.isClosed {
                for (k, v) in p.points.enumerated() { entries.append(.init(point: v, item: Int32(i), variant: Int32(k))) }
            } else {
                entries.append(.init(point: p.points[0], item: Int32(i), variant: 0))
                if allowReverse, p.points.count > 1 {
                    entries.append(.init(point: p.points[p.points.count - 1], item: Int32(i), variant: 1))
                }
            }
        }
        let route = GreedyRouter.route(entries: entries, itemCount: polylines.count, start: start) { i, v in
            let p = polylines[i]
            if p.isClosed { return p.points[v] }
            return v == 0 ? p.points[p.points.count - 1] : p.points[0]
        }
        var result: [Polyline] = []
        result.reserveCapacity(polylines.count)
        for (i, v) in route {
            let p = polylines[i]
            if p.isClosed {
                result.append(v == 0 ? p : Polyline(Array(p.points[v...] + p.points[..<v]), closed: true))
            } else {
                result.append(v == 0 ? p : Polyline(p.points.reversed(), closed: false))
            }
        }
        result += polylines.filter { $0.points.isEmpty }
        return result
    }
}

// MARK: - Vector import

public enum VectorImportError: Error, LocalizedError, Sendable {
    case unreadable(String)
    case unsupported(String)
    public var errorDescription: String? {
        switch self { case .unreadable(let m): "Cannot read file: \(m)"; case .unsupported(let m): "Unsupported: \(m)" }
    }
}

public enum VectorImporter {
    /// File extensions accepted by `load(url:)` (lower case).
    public static let supportedExtensions: [String] = ["svg", "dxf", "plt", "hpgl"]

    /// Loads an SVG (and other supported formats) as polylines in mm, +Y up, bounds' min at the origin.
    ///
    /// - SVG: shapes and paths (full path grammar incl. arcs), nested groups / viewports with transforms,
    ///   `use`; units from width/height + viewBox (px = 1/96 in). Skips `display:none`, `defs`, `clipPath`,
    ///   `mask`, `text` and images. CSS style sheets are not evaluated.
    /// - DXF (ASCII): LINE, LWPOLYLINE, POLYLINE, CIRCLE, ARC, ELLIPSE, SPLINE, INSERT; `$INSUNITS`.
    /// - PLT/HPGL: PU/PD/PA/PR, CI, AA/AR, EA/ER (0.025 mm per unit).
    public static func load(url: URL, tolerance: Double = 0.01) throws -> [Polyline] {
        let data: Data
        do { data = try Data(contentsOf: url) } catch { throw VectorImportError.unreadable(error.localizedDescription) }
        return try load(data: data, fileExtension: url.pathExtension, tolerance: tolerance)
    }

    /// Same as `load(url:)` for in-memory data; `fileExtension` selects the format (e.g. "svg").
    public static func load(data: Data, fileExtension: String, tolerance: Double = 0.01) throws -> [Polyline] {
        let polylines: [Polyline]
        switch fileExtension.lowercased() {
        case "svg": polylines = try SVGImporter.load(data: data, tolerance: tolerance)
        case "dxf": polylines = try DXFImporter.load(data: data, tolerance: tolerance)
        case "plt", "hpgl", "hgl": polylines = try HPGLImporter.load(data: data, tolerance: tolerance)
        default: throw VectorImportError.unsupported(fileExtension.isEmpty ? "file without extension" : fileExtension)
        }
        guard let b = GeometryOps.bounds(polylines) else { return [] }
        return GeometryOps.translated(polylines, by: Vec2(-b.minX, -b.minY))
    }
}

// MARK: - Raster (bitmap) engraving

public enum DitherMode: String, Codable, Hashable, Sendable, CaseIterable {
    case threshold, floydSteinberg, jarvis, stucki, atkinson, ordered
}

public struct RasterSettings: Codable, Hashable, Sendable {
    public var lineInterval: Double = 0.05  // mm between scan lines (≈ 508 DPI)
    public var dither: DitherMode = .floydSteinberg
    public var threshold: Double = 0.5      // 0...1, for .threshold
    public var invert: Bool = false
    public var brightness: Double = 0       // -1...1
    public var contrast: Double = 0         // -1...1
    public var gamma: Double = 1
    public var bidirectional: Bool = true
    public var scanAngle: Double = 0        // degrees (0 = horizontal lines)
    public init() {}
}

/// 1-bit image, row-major, row 0 at the TOP of the image. `true` = laser on.
public struct Bitmap: Hashable, Sendable {
    public var width: Int
    public var height: Int
    public var pixels: [Bool]
    public init(width: Int, height: Int, pixels: [Bool]) { self.width = width; self.height = height; self.pixels = pixels }
    public subscript(x: Int, y: Int) -> Bool { pixels[y * width + x] }

    /// Fraction of pixels that are on (0 for an empty bitmap).
    public var coverage: Double {
        pixels.isEmpty ? 0 : Double(pixels.reduce(0) { $0 + ($1 ? 1 : 0) }) / Double(pixels.count)
    }
}

public enum RasterEngraver {
    /// Resamples `image` to the scan grid of a `widthMM`×`heightMM` placement and dithers it.
    ///
    /// Grid: round(widthMM / lineInterval) × round(heightMM / lineInterval) pixels (≥ 1, ≤ 16384 per side).
    /// Transparent pixels become white (laser off). Tone, in order: v + brightness, contrast factor
    /// (1 + c) / (1 − c) around 0.5, clamp, v^(1/gamma) (gamma > 1 lightens), invert. Dark = laser on:
    /// `.threshold` turns on pixels below `threshold`; error diffusion (Floyd–Steinberg, Jarvis–Judice–Ninke,
    /// Stucki, Atkinson) runs serpentine; `.ordered` uses an 8×8 Bayer matrix.
    public static func bitmap(from image: CGImage, widthMM: Double, heightMM: Double, settings: RasterSettings) -> Bitmap {
        Raster.bitmap(from: image, widthMM: widthMM, heightMM: heightMM, settings: settings)
    }

    /// Converts a bitmap placed in `frame` (mm) into scan-line segments (runs of "on" pixels).
    ///
    /// Row r (0 = top) is scanned at y = frame.maxY − (r + ½)·pitch with pitch = frame.height / height;
    /// a run spans from the left edge of its first pixel to the right edge of its last one. With
    /// `bidirectional`, every other non-empty row runs right-to-left. A non-zero `scanAngle` resamples the
    /// bitmap (nearest pixel) along lines at that angle, `lineInterval` apart, clipped to `frame`.
    public static func scanLines(_ bitmap: Bitmap, frame: Rect2, settings: RasterSettings) -> [Polyline] {
        Raster.scanLines(bitmap, frame: frame, settings: settings)
    }

    /// Renders a bitmap as a CGImage for on-screen preview (black = laser on).
    public static func previewImage(_ bitmap: Bitmap) -> CGImage? { Raster.previewImage(bitmap) }
}

// MARK: - Tolerant decoding
// Documents saved by an older build may lack fields added later: missing keys decode to the defaults.

extension HatchLayer {
    private enum CodingKeys: String, CodingKey {
        case isEnabled, angle, spacing, crossHatch, bidirectional, borderOffset, startOffset, autoRotateAngle, penID
        case endOffset, evenDistribution, pattern
    }

    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? isEnabled
        angle = try c.decodeIfPresent(Double.self, forKey: .angle) ?? angle
        spacing = try c.decodeIfPresent(Double.self, forKey: .spacing) ?? spacing
        crossHatch = try c.decodeIfPresent(Bool.self, forKey: .crossHatch) ?? crossHatch
        bidirectional = try c.decodeIfPresent(Bool.self, forKey: .bidirectional) ?? bidirectional
        borderOffset = try c.decodeIfPresent(Double.self, forKey: .borderOffset) ?? borderOffset
        startOffset = try c.decodeIfPresent(Double.self, forKey: .startOffset) ?? startOffset
        autoRotateAngle = try c.decodeIfPresent(Double.self, forKey: .autoRotateAngle) ?? autoRotateAngle
        penID = try c.decodeIfPresent(Int.self, forKey: .penID)
        endOffset = try c.decodeIfPresent(Double.self, forKey: .endOffset) ?? endOffset
        evenDistribution = try c.decodeIfPresent(Bool.self, forKey: .evenDistribution) ?? evenDistribution
        pattern = try c.decodeIfPresent(HatchPattern.self, forKey: .pattern) ?? pattern
    }
}

extension FillSettings {
    private enum CodingKeys: String, CodingKey { case layers, markOutline, outlineFirst }

    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        layers = try c.decodeIfPresent([HatchLayer].self, forKey: .layers) ?? layers
        markOutline = try c.decodeIfPresent(Bool.self, forKey: .markOutline) ?? markOutline
        outlineFirst = try c.decodeIfPresent(Bool.self, forKey: .outlineFirst) ?? outlineFirst
    }
}

extension RasterSettings {
    private enum CodingKeys: String, CodingKey {
        case lineInterval, dither, threshold, invert, brightness, contrast, gamma, bidirectional, scanAngle
    }

    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lineInterval = try c.decodeIfPresent(Double.self, forKey: .lineInterval) ?? lineInterval
        dither = try c.decodeIfPresent(DitherMode.self, forKey: .dither) ?? dither
        threshold = try c.decodeIfPresent(Double.self, forKey: .threshold) ?? threshold
        invert = try c.decodeIfPresent(Bool.self, forKey: .invert) ?? invert
        brightness = try c.decodeIfPresent(Double.self, forKey: .brightness) ?? brightness
        contrast = try c.decodeIfPresent(Double.self, forKey: .contrast) ?? contrast
        gamma = try c.decodeIfPresent(Double.self, forKey: .gamma) ?? gamma
        bidirectional = try c.decodeIfPresent(Bool.self, forKey: .bidirectional) ?? bidirectional
        scanAngle = try c.decodeIfPresent(Double.self, forKey: .scanAngle) ?? scanAngle
    }
}
