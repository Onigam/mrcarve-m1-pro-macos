import Foundation

/// Scanline hatching behind `HatchFill`.
///
/// The contours are rotated by −angle so hatch lines become horizontal, intersected with lines spaced
/// `spacing` apart using an active edge table (edges are half-open in y, so vertices on a scanline are
/// counted correctly), paired with the even-odd rule, then rotated back.
///
/// `borderOffset` is applied exactly, per scanline, as a morphological erosion (positive) or dilation
/// (negative) of the filled region by a disk: each scanline interval minus / plus the union of the
/// "capsules" (Minkowski sums of every edge with the disk). This yields the same result as offsetting the
/// outline with round joins, including holes growing and narrow parts disappearing, without building
/// offset polygons.
///
/// Segments are grouped into chains of overlapping segments on consecutive scanlines (one chain per
/// "band" of the shape, e.g. both sides of the hole of an "O"); chains are traversed zig-zag
/// (bidirectional) or in the +line direction (unidirectional) and ordered by a greedy nearest-neighbour tour.
enum Hatcher {
    /// Scanlines are never closer than this (mm), to bound work for nonsensical input.
    static let minimumSpacing = 1e-4
    /// Segments shorter than this are dropped (mm).
    static let minimumSegmentLength = 1e-6

    struct Parameters {
        var angle: Double          // degrees
        var spacing: Double
        var startOffset: Double = 0
        var endOffset: Double = 0
        var evenDistribution = false
        var borderOffset: Double = 0
        var bidirectional = true
    }

    /// Hatches `contours` (even-odd); returns the ordered lines and the final tool position.
    static func hatch(_ contours: [Polyline], _ params: Parameters, start: Vec2? = nil) -> (lines: [Polyline], end: Vec2?) {
        guard params.spacing.isFinite, params.spacing >= minimumSpacing, params.angle.isFinite else { return ([], nil) }
        // sinpi/cospi are exact for multiples of 90°, so axis-aligned hatching has no rotation noise.
        let turns = params.angle.truncatingRemainder(dividingBy: 360) / 180
        let c = __cospi(turns), s = __sinpi(turns)
        func rotate(_ p: Vec2) -> Vec2 { Vec2(p.x * c + p.y * s, -p.x * s + p.y * c) }
        func unrotate(_ q: Vec2) -> Vec2 { Vec2(q.x * c - q.y * s, q.x * s + q.y * c) }

        // Rotated closed contours.
        var rings: [[Vec2]] = []
        var minX = Double.infinity, minY = Double.infinity, maxY = -Double.infinity
        for contour in contours where contour.isClosed && contour.points.count >= 3 {
            let pts = contour.points.map(rotate)
            for p in pts { minX = min(minX, p.x); minY = min(minY, p.y); maxY = max(maxY, p.y) }
            rings.append(pts)
        }
        guard !rings.isEmpty, minY.isFinite, maxY.isFinite else { return ([], nil) }

        let ys = scanlinePositions(minY: minY, maxY: maxY, params)
        guard !ys.isEmpty else { return ([], nil) }

        let segments = scan(rings, ys: ys, borderOffset: params.borderOffset)
        guard !segments.isEmpty else { return ([], nil) }

        let chains = buildChains(segments)
        let startRotated = start.map(rotate) ?? Vec2(minX, ys[0])
        let (lines, endRotated) = orderChains(chains, segments: segments, ys: ys,
                                              bidirectional: params.bidirectional, start: startRotated,
                                              unrotate: unrotate)
        return (lines, endRotated.map(unrotate))
    }

    // MARK: Scanline placement

    static func scanlinePositions(minY: Double, maxY: Double, _ p: Parameters) -> [Double] {
        // Expected extent of the offset region (exact for dilation, a bound for erosion).
        let lo = minY + p.borderOffset + p.startOffset
        let hi = maxY - p.borderOffset - p.endOffset
        guard hi >= lo else { return [] }
        let maxLines = 2_000_000
        if p.evenDistribution {
            let range = hi - lo
            let n = max(1, Int((range / p.spacing).rounded()))
            guard n <= maxLines else { return [] }
            let step = range / Double(n)
            return (0..<n).map { lo + step * (Double($0) + 0.5) }
        }
        let n = Int(((hi - lo) / p.spacing + 1e-9).rounded(.down)) + 1
        guard n <= maxLines else { return [] }
        return (0..<n).map { lo + Double($0) * p.spacing }
    }

    // MARK: Scanning

    struct Segment {
        var line: Int32
        var x0: Double
        var x1: Double
    }

    private struct Edge {
        var yMin: Double, yMax: Double, x: Double, slope: Double
    }

    private struct Capsule {
        var a: Vec2, b: Vec2, yMin: Double, yMax: Double
    }

    /// Even-odd intervals of `rings` on each scanline (ascending `ys`), with the border offset applied.
    static func scan(_ rings: [[Vec2]], ys: [Double], borderOffset: Double) -> [Segment] {
        var edges: [Edge] = []
        var capsules: [Capsule] = []
        let r = abs(borderOffset)
        let useCapsules = r > 1e-9
        for ring in rings {
            let n = ring.count
            for i in 0..<n {
                let a = ring[i], b = ring[i + 1 == n ? 0 : i + 1]
                if useCapsules {
                    capsules.append(Capsule(a: a, b: b, yMin: min(a.y, b.y) - r, yMax: max(a.y, b.y) + r))
                }
                guard a.y != b.y else { continue }
                let (lo, hi) = a.y < b.y ? (a, b) : (b, a)
                edges.append(Edge(yMin: lo.y, yMax: hi.y, x: lo.x, slope: (hi.x - lo.x) / (hi.y - lo.y)))
            }
        }
        edges.sort { $0.yMin < $1.yMin }
        capsules.sort { $0.yMin < $1.yMin }

        var segments: [Segment] = []
        var active: [Int] = [], activeCapsules: [Int] = []
        var nextEdge = 0, nextCapsule = 0
        var xs: [Double] = [], region: [(Double, Double)] = [], forbidden: [(Double, Double)] = []
        var result: [(Double, Double)] = []

        for (lineIndex, y) in ys.enumerated() {
            // Edge table: half-open [yMin, yMax).
            while nextEdge < edges.count, edges[nextEdge].yMin <= y {
                if edges[nextEdge].yMax > y { active.append(nextEdge) }
                nextEdge += 1
            }
            active.removeAll { edges[$0].yMax <= y }
            xs.removeAll(keepingCapacity: true)
            for e in active { xs.append(edges[e].x + (y - edges[e].yMin) * edges[e].slope) }
            xs.sort()
            region.removeAll(keepingCapacity: true)
            var k = 0
            while k + 1 < xs.count { region.append((xs[k], xs[k + 1])); k += 2 }

            if useCapsules {
                while nextCapsule < capsules.count, capsules[nextCapsule].yMin <= y {
                    if capsules[nextCapsule].yMax >= y { activeCapsules.append(nextCapsule) }
                    nextCapsule += 1
                }
                activeCapsules.removeAll { capsules[$0].yMax < y }
                forbidden.removeAll(keepingCapacity: true)
                // Erosion keeps points at exactly `r` (open capsules); dilation adds them (closed capsules).
                let open = borderOffset > 0
                for ci in activeCapsules {
                    if let iv = capsuleInterval(capsules[ci].a, capsules[ci].b, r, y, open: open) { forbidden.append(iv) }
                }
                mergeIntervals(&forbidden)
                result.removeAll(keepingCapacity: true)
                if borderOffset > 0 {
                    subtract(region, forbidden, into: &result)
                } else {
                    result = region + forbidden
                    mergeIntervals(&result)
                }
                swap(&region, &result)
            }
            for (x0, x1) in region where x1 - x0 > minimumSegmentLength {
                segments.append(Segment(line: Int32(lineIndex), x0: x0, x1: x1))
            }
        }
        return segments
    }

    /// Intersection of the horizontal line at `y` with the capsule {p : dist(p, segment ab) < r}
    /// (`open`) or ≤ r (closed): the hull of the intersections with both end disks and the swept rectangle.
    static func capsuleInterval(_ a: Vec2, _ b: Vec2, _ r: Double, _ y: Double, open: Bool) -> (Double, Double)? {
        var lo = Double.infinity, hi = -Double.infinity
        for p in [a, b] {
            let dy = abs(y - p.y)
            if open ? dy < r : dy <= r {
                let h = max(0, r * r - dy * dy).squareRoot()
                lo = min(lo, p.x - h); hi = max(hi, p.x + h)
            }
        }
        let d = b - a
        let len = d.length
        if len > 0 {
            let n = Vec2(-d.y / len * r, d.x / len * r)
            let quad = [a + n, b + n, b - n, a - n]
            let qMin = quad.map(\.y).min()!, qMax = quad.map(\.y).max()!
            let inside = open ? (y > qMin && y < qMax) : (y >= qMin && y <= qMax)
            if inside {
                for i in 0..<4 {
                    let p = quad[i], q = quad[(i + 1) & 3]
                    guard (p.y - y) * (q.y - y) <= 0 else { continue }
                    if p.y == q.y {
                        lo = min(lo, p.x, q.x); hi = max(hi, p.x, q.x)
                    } else {
                        let x = p.x + (y - p.y) * (q.x - p.x) / (q.y - p.y)
                        lo = min(lo, x); hi = max(hi, x)
                    }
                }
            }
        }
        if open { return lo < hi ? (lo, hi) : nil }
        return lo <= hi ? (lo, hi) : nil
    }

    /// Sorts and merges overlapping intervals in place.
    static func mergeIntervals(_ v: inout [(Double, Double)]) {
        guard v.count > 1 else { return }
        v.sort { $0.0 < $1.0 }
        var w = 0
        for i in 1..<v.count {
            if v[i].0 <= v[w].1 {
                v[w].1 = max(v[w].1, v[i].1)
            } else {
                w += 1
                v[w] = v[i]
            }
        }
        v.removeSubrange((w + 1)...)
    }

    /// `region` minus `forbidden`; both sorted and disjoint.
    static func subtract(_ region: [(Double, Double)], _ forbidden: [(Double, Double)], into out: inout [(Double, Double)]) {
        var j = 0
        for (a, b) in region {
            var start = a
            while j < forbidden.count, forbidden[j].1 <= start { j += 1 }
            var k = j
            while k < forbidden.count, forbidden[k].0 < b {
                if forbidden[k].0 > start { out.append((start, forbidden[k].0)) }
                start = max(start, forbidden[k].1)
                if start >= b { break }
                k += 1
            }
            if start < b { out.append((start, b)) }
        }
    }

    // MARK: Chains & ordering

    /// Groups segments (sorted by line, then x) into chains of x-overlapping segments on consecutive lines.
    static func buildChains(_ segments: [Segment]) -> [[Int]] {
        var chains: [[Int]] = []
        var previous: [(chain: Int, x0: Double, x1: Double)] = []  // chains ending on the previous line, by x
        var current: [(chain: Int, x0: Double, x1: Double)] = []
        var claimed: [Bool] = []
        var previousLine: Int32 = -2
        var i = 0
        while i < segments.count {
            let line = segments[i].line
            if line != previousLine + 1 { previous.removeAll() }
            claimed = [Bool](repeating: false, count: previous.count)
            current.removeAll(keepingCapacity: true)
            var j = 0
            while i < segments.count, segments[i].line == line {
                let s = segments[i]
                while j < previous.count, previous[j].x1 < s.x0 { j += 1 }
                var chosen = -1
                var k = j
                while k < previous.count, previous[k].x0 <= s.x1 {
                    if !claimed[k] { chosen = k; break }
                    k += 1
                }
                let chain: Int
                if chosen >= 0 {
                    claimed[chosen] = true
                    chain = previous[chosen].chain
                    chains[chain].append(i)
                } else {
                    chain = chains.count
                    chains.append([i])
                }
                current.append((chain, s.x0, s.x1))
                i += 1
            }
            swap(&previous, &current)
            previousLine = line
        }
        return chains
    }

    /// Orders chains with a greedy tour and emits 2-point polylines (unrotated).
    static func orderChains(_ chains: [[Int]], segments: [Segment], ys: [Double], bidirectional: Bool,
                            start: Vec2, unrotate: (Vec2) -> Vec2) -> ([Polyline], Vec2?) {
        func y(_ seg: Int) -> Double { ys[Int(segments[seg].line)] }
        func left(_ seg: Int) -> Vec2 { Vec2(segments[seg].x0, y(seg)) }
        func right(_ seg: Int) -> Vec2 { Vec2(segments[seg].x1, y(seg)) }

        // Variant bits: 1 = traverse chain from its last segment, 2 = first traversed segment runs −x
        // (bidirectional only; unidirectional lines always run +x).
        func firstGoesRight(_ variant: Int) -> Bool { variant & 2 == 0 }
        func direction(_ variant: Int, position: Int) -> Bool {  // true = +x
            bidirectional ? (firstGoesRight(variant) == position.isMultiple(of: 2)) : true
        }
        func sequence(_ chain: [Int], _ variant: Int) -> [Int] { variant & 1 == 0 ? chain : chain.reversed() }

        var entries: [GreedyRouter.Entry] = []
        entries.reserveCapacity(chains.count * 4)
        let variants = bidirectional ? [0, 1, 2, 3] : [0, 1]
        for (ci, chain) in chains.enumerated() {
            for v in variants {
                let firstSeg = v & 1 == 0 ? chain[0] : chain[chain.count - 1]
                let p = direction(v, position: 0) ? left(firstSeg) : right(firstSeg)
                entries.append(GreedyRouter.Entry(point: p, item: Int32(ci), variant: Int32(v)))
            }
        }
        let order = GreedyRouter.route(entries: entries, itemCount: chains.count, start: start) { ci, v in
            let chain = chains[ci]
            let lastSeg = v & 1 == 0 ? chain[chain.count - 1] : chain[0]
            return direction(v, position: chain.count - 1) ? right(lastSeg) : left(lastSeg)
        }

        var lines: [Polyline] = []
        lines.reserveCapacity(segments.count)
        var end: Vec2?
        for (ci, v) in order {
            for (pos, seg) in sequence(chains[ci], v).enumerated() {
                let (a, b) = direction(v, position: pos) ? (left(seg), right(seg)) : (right(seg), left(seg))
                lines.append(Polyline([unrotate(a), unrotate(b)]))
                end = b
            }
        }
        return (lines, end)
    }
}
