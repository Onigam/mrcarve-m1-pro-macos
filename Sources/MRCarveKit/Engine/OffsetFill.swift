import Foundation

/// Concentric ("offset") fill: closed rings at inset distances `first`, `first + spacing`, … from the outline.
///
/// The signed distance to the outline (positive inside, even-odd) is sampled on a grid whose nodes hold the
/// *exact* distance to their nearest edge: edges seed the nodes around them, then two raster passes propagate
/// the closest-edge candidates (vector distance transform), each candidate evaluated exactly. Rings are the
/// iso-lines of that field, extracted for all levels in one sweep with oriented marching squares (saddles
/// resolved by the cell centre) and chained into closed loops, then simplified.
/// The grid step is `spacing / 4` (≤ 0.05 mm, coarser only when the grid would exceed ~4 M nodes), so ring
/// positions are accurate to a small fraction of the step; sharp convex corners of inner rings are slightly
/// rounded at that scale.
enum OffsetFill {
    static let maxNodes = 4_000_000

    static func rings(_ contours: [Polyline], spacing: Double, first: Double) -> [Polyline] {
        guard spacing.isFinite, spacing >= 1e-3, first.isFinite else { return [] }
        let polys = contours.filter { $0.isClosed && $0.points.count >= 3 }.map(\.points)
        guard let bounds = Rect2(enclosing: polys.flatMap { $0 }), bounds.width > 0, bounds.height > 0 else { return [] }

        // Grid.
        var h = min(spacing / 4, 0.05)
        let pad = max(0, -first) + 2 * spacing
        let bw = bounds.width + 2 * pad, bh = bounds.height + 2 * pad
        if (bw / h + 3) * (bh / h + 3) > Double(maxNodes) { h = (bw * bh / Double(maxNodes)).squareRoot() * 1.01 }
        let w = Int((bw / h).rounded(.up)) + 3, hgt = Int((bh / h).rounded(.up)) + 3
        let ox = bounds.minX - pad - h, oy = bounds.minY - pad - h
        let count = w * hgt

        // Edges.
        var ax: [Double] = [], ay: [Double] = [], bx: [Double] = [], by: [Double] = []
        for p in polys {
            for i in 0..<p.count {
                let a = p[i], b = p[(i + 1) % p.count]
                ax.append(a.x); ay.append(a.y); bx.append(b.x); by.append(b.y)
            }
        }
        func edgeDistance(_ e: Int, _ px: Double, _ py: Double) -> Double {
            let dx = bx[e] - ax[e], dy = by[e] - ay[e]
            let l2 = dx * dx + dy * dy
            var t = l2 > 0 ? ((px - ax[e]) * dx + (py - ay[e]) * dy) / l2 : 0
            t = max(0, min(1, t))
            let qx = ax[e] + dx * t - px, qy = ay[e] + dy * t - py
            return (qx * qx + qy * qy).squareRoot()
        }

        var nearest = [Int32](repeating: -1, count: count)
        var dist = [Double](repeating: .infinity, count: count)
        func consider(_ node: Int, _ e: Int32) {
            let i = node % w, j = node / w
            let d = edgeDistance(Int(e), ox + Double(i) * h, oy + Double(j) * h)
            if d < dist[node] { dist[node] = d; nearest[node] = e }
        }
        // Seed nodes within 2 cells of every edge.
        for e in 0..<ax.count {
            let length = ((bx[e] - ax[e]) * (bx[e] - ax[e]) + (by[e] - ay[e]) * (by[e] - ay[e])).squareRoot()
            let steps = max(1, Int((length / h).rounded(.up)))
            for s in 0...steps {
                let t = Double(s) / Double(steps)
                let ci = Int(((ax[e] + (bx[e] - ax[e]) * t - ox) / h).rounded())
                let cj = Int(((ay[e] + (by[e] - ay[e]) * t - oy) / h).rounded())
                for j in max(0, cj - 2)...min(hgt - 1, cj + 2) {
                    for i in max(0, ci - 2)...min(w - 1, ci + 2) { consider(j * w + i, Int32(e)) }
                }
            }
        }
        // Propagate closest-edge candidates (8SSEDT pass structure).
        func pull(_ node: Int, _ other: Int) {
            let e = nearest[other]
            if e >= 0, e != nearest[node] { consider(node, e) }
        }
        for j in 0..<hgt {
            for i in 0..<w {
                let n = j * w + i
                if i > 0 { pull(n, n - 1) }
                if j > 0 {
                    pull(n, n - w)
                    if i > 0 { pull(n, n - w - 1) }
                    if i < w - 1 { pull(n, n - w + 1) }
                }
            }
            for i in stride(from: w - 2, through: 0, by: -1) { pull(j * w + i, j * w + i + 1) }
        }
        for j in stride(from: hgt - 1, through: 0, by: -1) {
            for i in stride(from: w - 1, through: 0, by: -1) {
                let n = j * w + i
                if i < w - 1 { pull(n, n + 1) }
                if j < hgt - 1 {
                    pull(n, n + w)
                    if i < w - 1 { pull(n, n + w + 1) }
                    if i > 0 { pull(n, n + w - 1) }
                }
            }
            for i in 1..<w { pull(j * w + i, j * w + i - 1) }
        }

        // Sign from the even-odd scanline intervals of each grid row.
        let rowYs = (0..<hgt).map { oy + Double($0) * h }
        var field = dist.map { -$0 }
        for seg in Hatcher.scan(polys, ys: rowYs, borderOffset: 0) {
            let j = Int(seg.line)
            let i0 = max(0, Int(((seg.x0 - ox) / h).rounded(.up))), i1 = min(w - 1, Int(((seg.x1 - ox) / h).rounded(.down)))
            if i0 <= i1 { for i in i0...i1 { field[j * w + i] = dist[j * w + i] } }
        }

        // Levels straddled by each cell.
        guard let maxValue = field.max(), maxValue >= first else { return [] }
        let levelCount = Int(((maxValue - first) / spacing).rounded(.down)) + 1
        guard levelCount > 0, levelCount < 1_000_000 else { return [] }
        var cellsByLevel = [[Int32]](repeating: [], count: levelCount)
        for j in 0..<(hgt - 1) {
            for i in 0..<(w - 1) {
                let n = j * w + i
                let v = (field[n], field[n + 1], field[n + w + 1], field[n + w])
                let lo = min(v.0, v.1, v.2, v.3), hi = max(v.0, v.1, v.2, v.3)
                guard hi >= first else { continue }
                let kLo = max(0, Int(((lo - first) / spacing).rounded(.down)) + 1)
                let kHi = min(levelCount - 1, Int(((hi - first) / spacing).rounded(.down)))
                if kLo <= kHi { for k in kLo...kHi { cellsByLevel[k].append(Int32(n)) } }
            }
        }

        // Crossing point on a grid edge: id = 2·node (+1 for the vertical edge above the node).
        func crossing(_ id: Int, _ level: Double) -> Vec2 {
            let node = id >> 1, i = node % w, j = node / w
            let other = id & 1 == 0 ? node + 1 : node + w
            let fa = field[node], fb = field[other]
            let t = fb != fa ? max(0, min(1, (level - fa) / (fb - fa))) : 0.5
            let x = ox + Double(i) * h, y = oy + Double(j) * h
            return id & 1 == 0 ? Vec2(x + t * h, y) : Vec2(x, y + t * h)
        }

        var result: [Polyline] = []
        let simplifyTolerance = min(0.002, h / 8)
        for k in 0..<levelCount where !cellsByLevel[k].isEmpty {
            let level = first + Double(k) * spacing
            var next: [Int: Int] = [:]
            var starts: [Int] = []
            next.reserveCapacity(cellsByLevel[k].count * 2)
            starts.reserveCapacity(cellsByLevel[k].count)
            for c in cellsByLevel[k] {
                let n = Int(c)
                // Corners counter-clockwise from bottom-left; edges e0 bottom, e1 right, e2 top, e3 left
                // (edge e runs from corner e to corner e + 1).
                let f0 = field[n], f1 = field[n + 1], f2 = field[n + w + 1], f3 = field[n + w]
                let mask = (f0 >= level ? 1 : 0) | (f1 >= level ? 2 : 0) | (f2 >= level ? 4 : 0) | (f3 >= level ? 8 : 0)
                func edge(_ e: Int) -> Int {
                    switch e & 3 {
                    case 0: return 2 * n
                    case 1: return 2 * (n + 1) + 1
                    case 2: return 2 * (n + w)
                    default: return 2 * n + 1
                    }
                }
                var exit0 = -1, exit1 = -1, entry0 = -1
                for e in 0..<4 {
                    let a = mask >> e & 1 == 1, b = mask >> ((e + 1) & 3) & 1 == 1
                    if a && !b { if exit0 < 0 { exit0 = e } else { exit1 = e } } else if !a && b { entry0 = e }
                }
                guard exit0 >= 0 else { continue }
                if exit1 < 0 {
                    next[edge(exit0)] = edge(entry0)
                    starts.append(edge(exit0))
                } else {
                    // Saddle: connect through the centre when it is above the level.
                    let step = (f0 + f1 + f2 + f3) / 4 >= level ? 1 : 3
                    for e in [exit0, exit1] {
                        next[edge(e)] = edge(e + step)
                        starts.append(edge(e))
                    }
                }
            }
            // Walk the loops (the region above the level is on the left).
            for startEdge in starts where next[startEdge] != nil {
                var loop: [Vec2] = []
                var e = startEdge
                while let n = next.removeValue(forKey: e) {
                    let p = crossing(e, level)
                    if loop.last.map({ $0.distance(to: p) > 1e-9 }) ?? true { loop.append(p) }
                    e = n
                    if e == startEdge { break }
                }
                if loop.count > 1, loop[0].distance(to: loop[loop.count - 1]) <= 1e-9 { loop.removeLast() }
                guard loop.count >= 3 else { continue }
                let ring = GeometryOps.simplified(Polyline(loop, closed: true), tolerance: simplifyTolerance)
                if ring.points.count >= 3 { result.append(ring) }
            }
        }
        return PathOptimizer.order(result, start: Vec2(bounds.minX, bounds.minY))
    }
}
