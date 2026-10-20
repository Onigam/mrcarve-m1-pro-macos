import Foundation

/// Greedy nearest-neighbour tour over items that can each be entered in one of several ways
/// ("variants": open polyline forwards/backwards, closed polyline starting at vertex k, hatch chain phases...).
///
/// Entry points live in a uniform grid; queries expand rings of cells until no unvisited cell can beat the
/// best candidate. Used entries are removed lazily (swap-remove when their cell is visited) and the grid is
/// rebuilt coarser when it becomes sparse, so a tour over n entries costs roughly O(n log n).
enum GreedyRouter {
    struct Entry {
        var point: Vec2
        var item: Int32
        var variant: Int32
    }

    /// Visits every item that has at least one entry, starting at `start`.
    /// `exit(item, variant)` is where the tool ends up after traversing that item in that variant.
    static func route(entries: [Entry], itemCount: Int, start: Vec2,
                      exit: (_ item: Int, _ variant: Int) -> Vec2) -> [(item: Int, variant: Int)] {
        guard !entries.isEmpty, itemCount > 0 else { return [] }
        var used = [Bool](repeating: false, count: itemCount)
        var entriesPerItem = [Int32](repeating: 0, count: itemCount)
        for e in entries { entriesPerItem[Int(e.item)] += 1 }
        var remaining = entriesPerItem.reduce(0) { $0 + ($1 > 0 ? 1 : 0) }
        var aliveEntries = entries.count

        var grid = Grid(entries: entries, alive: Array(0..<Int32(entries.count)))
        var order: [(item: Int, variant: Int)] = []
        order.reserveCapacity(remaining)
        var p = start
        while remaining > 0 {
            guard let e = grid.nearest(to: p, entries: entries, used: used) else {
                // Defensive: should not happen; rebuild from scratch and retry once.
                let alive = (0..<Int32(entries.count)).filter { !used[Int(entries[Int($0)].item)] }
                if alive.isEmpty { break }
                grid = Grid(entries: entries, alive: alive)
                continue
            }
            let item = Int(entries[e].item), variant = Int(entries[e].variant)
            used[item] = true
            remaining -= 1
            aliveEntries -= Int(entriesPerItem[item])
            order.append((item, variant))
            p = exit(item, variant)
            if aliveEntries > 0, grid.cellCount.count > 64, aliveEntries * 4 < grid.cellCount.count {
                let alive = (0..<Int32(entries.count)).filter { !used[Int(entries[Int($0)].item)] }
                grid = Grid(entries: entries, alive: alive)
            }
        }
        return order
    }

    /// Uniform grid in CSR layout: entries of cell c are `slots[cellStart[c] ..< cellStart[c] + cellCount[c]]`.
    struct Grid {
        var minX = 0.0, minY = 0.0, cell = 1.0
        var width = 1, height = 1
        var cellStart: [Int32] = [0]
        var cellCount: [Int32] = [0]
        var slots: [Int32] = []

        init(entries: [Entry], alive: [Int32]) {
            guard let first = alive.first else { return }
            var lo = entries[Int(first)].point, hi = lo
            for i in alive {
                let p = entries[Int(i)].point
                lo.x = min(lo.x, p.x); lo.y = min(lo.y, p.y)
                hi.x = max(hi.x, p.x); hi.y = max(hi.y, p.y)
            }
            let w = hi.x - lo.x, h = hi.y - lo.y
            let span = max(w, h, 1e-9)
            let targetCells = Double(max(1, alive.count / 2))
            cell = max((w * h / targetCells).squareRoot(), span / 2048, 1e-9)
            width = min(2048, Int(w / cell) + 1)
            height = min(2048, Int(h / cell) + 1)
            minX = lo.x; minY = lo.y

            let cells = width * height
            var counts = [Int32](repeating: 0, count: cells)
            var cellOf = [Int32](repeating: 0, count: alive.count)
            for (k, i) in alive.enumerated() {
                let c = cellIndex(entries[Int(i)].point)
                cellOf[k] = Int32(c)
                counts[c] += 1
            }
            var starts = [Int32](repeating: 0, count: cells)
            var running: Int32 = 0
            for c in 0..<cells { starts[c] = running; running += counts[c] }
            var fill = starts
            slots = [Int32](repeating: 0, count: alive.count)
            for (k, i) in alive.enumerated() {
                let c = Int(cellOf[k])
                slots[Int(fill[c])] = i
                fill[c] += 1
            }
            cellStart = starts
            cellCount = counts
        }

        func cellCoords(_ p: Vec2) -> (Int, Int) {
            let fx = ((p.x - minX) / cell).rounded(.down), fy = ((p.y - minY) / cell).rounded(.down)
            let cx = fx.isFinite ? Int(max(0, min(Double(width - 1), fx))) : 0
            let cy = fy.isFinite ? Int(max(0, min(Double(height - 1), fy))) : 0
            return (cx, cy)
        }

        func cellIndex(_ p: Vec2) -> Int {
            let (cx, cy) = cellCoords(p)
            return cy * width + cx
        }

        /// Index of the nearest entry whose item is unused, or nil when none is left.
        mutating func nearest(to p: Vec2, entries: [Entry], used: [Bool]) -> Int? {
            let (cx, cy) = cellCoords(p)
            var best = -1
            var bestD = Double.infinity
            var r = 0
            while true {
                let j0 = max(0, cy - r), j1 = min(height - 1, cy + r)
                for j in j0...j1 {
                    if j == cy - r || j == cy + r {
                        let i0 = max(0, cx - r), i1 = min(width - 1, cx + r)
                        for i in i0...i1 { scan(j * width + i, p, entries, used, &best, &bestD) }
                    } else {
                        if cx - r >= 0 { scan(j * width + cx - r, p, entries, used, &best, &bestD) }
                        if r > 0, cx + r <= width - 1 { scan(j * width + cx + r, p, entries, used, &best, &bestD) }
                    }
                }
                // Lower bound on the distance to any cell outside the visited square.
                var bound = Double.infinity
                if cx - r > 0 { bound = min(bound, p.x - (minX + Double(cx - r) * cell)) }
                if cx + r < width - 1 { bound = min(bound, minX + Double(cx + r + 1) * cell - p.x) }
                if cy - r > 0 { bound = min(bound, p.y - (minY + Double(cy - r) * cell)) }
                if cy + r < height - 1 { bound = min(bound, minY + Double(cy + r + 1) * cell - p.y) }
                if bound == .infinity { break }  // whole grid visited
                if best >= 0, bound >= 0, bestD <= bound * bound { break }
                r += 1
            }
            return best >= 0 ? best : nil
        }

        private mutating func scan(_ c: Int, _ p: Vec2, _ entries: [Entry], _ used: [Bool],
                                   _ best: inout Int, _ bestD: inout Double) {
            let start = Int(cellStart[c])
            var count = Int(cellCount[c])
            var k = 0
            while k < count {
                let e = Int(slots[start + k])
                let entry = entries[e]
                if used[Int(entry.item)] {
                    count -= 1
                    slots[start + k] = slots[start + count]
                    continue
                }
                let dx = entry.point.x - p.x, dy = entry.point.y - p.y
                let d = dx * dx + dy * dy
                if d < bestD || (d == bestD && e < best) { bestD = d; best = e }
                k += 1
            }
            cellCount[c] = Int32(count)
        }
    }
}
