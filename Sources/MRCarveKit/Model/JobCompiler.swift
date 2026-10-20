import Foundation

/// Turns a `Project` into a device-independent `MarkJob`.
///
/// For each visible object, in project order: outlines (when there is no fill or the fill marks its outline),
/// one hatch pass per enabled fill layer (with the layer's pen or the object's), and raster scan lines for images.
/// `FillSettings.outlineFirst` decides whether outlines come before or after the hatch. Outline and hatch parts are
/// path-optimised (raster scan lines keep the engine's row order),
/// consecutive parts with the same pen are merged, and parts whose pen is disabled are skipped.
public enum JobCompiler {
    public struct Options: Sendable {
        /// Restrict the job to these objects (nil = all visible objects).
        public var selection: Set<UUID>?
        /// Chord tolerance for curves, mm.
        public var tolerance: Double
        /// Run `PathOptimizer.order` on each part.
        public var optimizePaths: Bool

        public init(selection: Set<UUID>? = nil, tolerance: Double = defaultFlatteningTolerance, optimizePaths: Bool = true) {
            self.selection = selection
            self.tolerance = tolerance
            self.optimizePaths = optimizePaths
        }
    }

    /// One pen's worth of geometry for an object, before merging.
    struct Part {
        var pen: PenParameters
        var polylines: [Polyline]
        var allowReverse: Bool
        /// Raster scan lines arrive ordered (and can be millions of segments): never re-ordered.
        var optimize = true
    }

    /// Compiles `project` into a mark job.
    public static func compile(_ project: Project, options: Options = Options()) -> MarkJob {
        var items: [MarkItem] = []
        var cursor = Vec2.zero
        for object in project.objects where object.isVisible && (options.selection?.contains(object.id) ?? true) {
            for var part in parts(for: object, in: project, tolerance: options.tolerance)
            where part.pen.isEnabled && !part.polylines.isEmpty {
                if options.optimizePaths && part.optimize {
                    part.polylines = PathOptimizer.order(part.polylines, start: cursor, allowReverse: part.allowReverse)
                }
                if let end = part.polylines.last?.traversal.last { cursor = end }
                if let last = items.last, last.pen == part.pen, last.kind == .vector {
                    items[items.count - 1].polylines += part.polylines
                } else {
                    items.append(MarkItem(pen: part.pen, kind: .vector, polylines: part.polylines))
                }
            }
        }
        return MarkJob(items: items, repeatCount: max(1, project.repeatCount))
    }

    /// The parts of one object in marking order (pens not yet filtered).
    static func parts(for object: DesignObject, in project: Project, tolerance: Double) -> [Part] {
        let pen = project.pen(object.penID)
        if case .image(let img) = object.kind {
            return [Part(pen: pen, polylines: object.rasterScanLines(), allowReverse: img.raster.bidirectional, optimize: false)]
        }
        let outlines = object.outlines(tolerance: tolerance)
        guard let fill = object.fill, object.kind.supportsFill else {
            return [Part(pen: pen, polylines: outlines, allowReverse: true)]
        }
        var hatchParts: [Part] = []
        for layer in fill.layers.prefix(FillSettings.maxLayers) where layer.isEnabled {
            let layerPen = project.pen(layer.penID ?? object.penID)
            if layer.autoRotateAngle != 0 && layerPen.loopCount > 1 {
                // Each loop becomes its own pass with a rotated hatch angle.
                var single = layerPen
                single.loopCount = 1
                for pass in 0..<layerPen.loopCount {
                    var rotated = layer
                    rotated.angle = layer.angle + Double(pass) * layer.autoRotateAngle
                    hatchParts.append(Part(pen: single, polylines: object.hatchLines(layer: rotated, tolerance: tolerance),
                                           allowReverse: layer.bidirectional))
                }
            } else {
                hatchParts.append(Part(pen: layerPen, polylines: object.hatchLines(layer: layer, tolerance: tolerance),
                                       allowReverse: layer.bidirectional))
            }
        }
        guard fill.markOutline else { return hatchParts }
        let outlinePart = Part(pen: pen, polylines: outlines, allowReverse: true)
        return fill.outlineFirst ? [outlinePart] + hatchParts : hatchParts + [outlinePart]
    }

    /// Outline-only job for red-light framing: object outlines (image frames for images), one neutral pen.
    public static func framingJob(_ project: Project, selection: Set<UUID>? = nil,
                                  tolerance: Double = 0.05) -> MarkJob {
        let polylines = project.objects
            .filter { $0.isVisible && (selection?.contains($0.id) ?? true) }
            .flatMap { $0.outlines(tolerance: tolerance) }
        guard !polylines.isEmpty else { return MarkJob(items: []) }
        return MarkJob(items: [MarkItem(pen: project.pen(0), polylines: polylines)])
    }

    // MARK: Checks

    /// Returns the job bounds when they exceed `field`, nil when the job fits.
    public static func fieldViolation(_ job: MarkJob, field: Rect2, tolerance: Double = 1e-6) -> Rect2? {
        guard let b = job.bounds else { return nil }
        return Self.exceeds(b, field, tolerance) ? b : nil
    }

    /// Identifiers of visible objects that extend beyond `field`.
    public static func objectsOutsideField(_ project: Project, field: Rect2) -> [UUID] {
        project.objects.filter { $0.isVisible && exceeds($0.fieldBounds(), field, 1e-6) }.map(\.id)
    }

    static func exceeds(_ b: Rect2, _ f: Rect2, _ tol: Double) -> Bool {
        b.minX < f.minX - tol || b.minY < f.minY - tol || b.maxX > f.maxX + tol || b.maxY > f.maxY + tol
    }

    // MARK: Time estimate

    /// Estimates how long `job` takes to mark from vector lengths, pen speeds and delays.
    public static func estimate(_ job: MarkJob, start: Vec2 = .zero) -> JobEstimate {
        var e = JobEstimate()
        var cursor = start
        for item in job.items {
            let pen = item.pen
            let loops = Double(max(1, pen.loopCount))
            var once = JobEstimate()
            var c = cursor
            for polyline in item.polylines {
                guard let first = polyline.points.first else { continue }
                let jump = c.distance(to: first)
                once.travelLength += jump
                once.duration += jump / max(1, pen.jumpSpeed) + jumpDelay(pen, distance: jump) * 1e-6
                switch item.kind {
                case .vector:
                    let length = polyline.length
                    once.markLength += length
                    let corners = max(0, polyline.traversal.count - 2)
                    once.duration += length / max(1, pen.markSpeed)
                        + (pen.laserOnDelay + pen.laserOffDelay + pen.endMarkDelay + Double(corners) * pen.cornerDelay) * 1e-6
                case .dots(let dwell):
                    let ms = dwell ?? pen.pointDwell
                    once.duration += Double(polyline.points.count) * ms * 1e-3
                    once.duration += polyline.length / max(1, pen.jumpSpeed)
                }
                once.polylineCount += 1
                c = polyline.traversal.last ?? first
            }
            e.markLength += once.markLength * loops
            e.travelLength += once.travelLength * loops
            e.duration += once.duration * loops
            e.polylineCount += once.polylineCount
            cursor = c
        }
        let repeats = Double(max(1, job.repeatCount))
        e.markLength *= repeats
        e.travelLength *= repeats
        e.duration *= repeats
        return e
    }

    /// Vendor-style jump delay (µs): interpolated between min and max up to `maxJumpDistance`.
    static func jumpDelay(_ pen: PenParameters, distance: Double) -> Double {
        guard distance > 0 else { return 0 }
        let ratio = pen.maxJumpDistance > 0 ? min(1, distance / pen.maxJumpDistance) : 1
        return pen.minJumpDelay + (pen.maxJumpDelay - pen.minJumpDelay) * ratio
    }
}

/// Result of `JobCompiler.estimate`.
public struct JobEstimate: Hashable, Sendable {
    /// Laser-on path length, mm (all loops and repeats).
    public var markLength: Double = 0
    /// Laser-off jump length, mm.
    public var travelLength: Double = 0
    /// Estimated duration, seconds.
    public var duration: TimeInterval = 0
    /// Number of polylines in one pass.
    public var polylineCount: Int = 0

    public init() {}
}

extension FillSettings {
    /// Maximum number of hatch layers (as in the vendor UI).
    public static let maxLayers = 4
}
