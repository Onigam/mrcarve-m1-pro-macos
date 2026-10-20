import Foundation
import Observation
import CoreGraphics
import MRCarveKit

/// Caches geometry for drawing so the canvas stays fast:
/// - local outlines (synchronous; text outlining is the expensive part),
/// - hatch previews and dithered raster previews (computed in the background, published via `revision`).
///
/// Everything is cached in the object's local frame, so moving or rotating an object only re-applies its transform.
/// While a background result is being recomputed, the previous one is returned (drawn with the current transform).
@MainActor @Observable
final class PreviewCache {
    /// Bumped whenever a background result arrives; the canvas reads it to redraw.
    private(set) var revision = 0

    private struct OutlineKey: Hashable {
        var kind: ObjectKind
        var width: Double
        var height: Double
    }

    private struct HatchKey: Hashable {
        var kind: ObjectKind
        var width: Double
        var height: Double
        var layer: HatchLayer
    }

    private struct RasterKey: Hashable {
        var dataCount: Int
        var settings: RasterSettings
        var width: Double
        var height: Double
    }

    /// Background computation state for one hatch layer or one image.
    private struct Slot<Key: Hashable, Value> {
        var result: (key: Key, value: Value)?
        var running = false
        var pending: (key: Key, object: DesignObject)?
    }

    @ObservationIgnored private var outlines: [UUID: (key: OutlineKey, value: [Polyline])] = [:]
    @ObservationIgnored private var hatchSlots: [String: Slot<HatchKey, [Polyline]>] = [:]
    @ObservationIgnored private var rasterSlots: [UUID: Slot<RasterKey, CGImage?>] = [:]

    // MARK: Outlines

    /// Outline in the object's local frame (see `DesignObject.localOutlines`).
    func localOutlines(_ object: DesignObject) -> [Polyline] {
        if case .image = object.kind { return [object.placement.localBox.outline] }
        let key = OutlineKey(kind: object.kind, width: object.placement.width, height: object.placement.height)
        if let hit = outlines[object.id], hit.key == key { return hit.value }
        let value = object.localOutlines(tolerance: 0.02)
        outlines[object.id] = (key, value)
        return value
    }

    /// Outline in field coordinates.
    func fieldOutlines(_ object: DesignObject) -> [Polyline] {
        let t = object.placement.transform
        return localOutlines(object).map { $0.applying(t) }
    }

    /// Field-coordinate bounds of the outline.
    func fieldBounds(_ object: DesignObject) -> Rect2 {
        fieldOutlines(object).compactMap(\.bounds).reduce(nil) { $0?.union($1) ?? $1 } ?? object.placement.boundingBox
    }

    // MARK: Hatch

    /// Hatch lines of fill layer `index` in the object's local frame, or nil if none are available yet.
    /// The layer angle is converted so that the preview matches the absolute angle used for marking.
    func localHatch(_ object: DesignObject, layerIndex index: Int, layer: HatchLayer) -> [Polyline]? {
        let p = object.placement
        var local = layer
        let sign: Double = p.mirrorX != p.mirrorY ? -1 : 1
        let angle = sign * (layer.angle - p.rotation)
        local.angle = (angle.truncatingRemainder(dividingBy: 180) + 180).truncatingRemainder(dividingBy: 180)
        let key = HatchKey(kind: object.kind, width: p.width, height: p.height, layer: local)
        let slotID = "\(object.id)#\(index)"
        var slot = hatchSlots[slotID] ?? Slot()
        if let r = slot.result, r.key == key { return r.value }
        if slot.running {
            slot.pending = (key, object)
        } else {
            slot.running = true
            startHatch(key, object: object, slotID: slotID)
        }
        hatchSlots[slotID] = slot
        return slot.result?.value
    }

    private func startHatch(_ key: HatchKey, object: DesignObject, slotID: String) {
        var local = object
        local.kind = key.kind
        local.placement = Placement(width: key.width, height: key.height)
        let layer = key.layer
        Task {
            let lines = await Task.detached(priority: .utility) { local.hatchLines(layer: layer, tolerance: 0.02) }.value
            var slot = self.hatchSlots[slotID] ?? Slot()
            slot.result = (key, lines)
            slot.running = false
            if let next = slot.pending {
                slot.pending = nil
                if next.key != key {
                    slot.running = true
                    self.startHatch(next.key, object: next.object, slotID: slotID)
                }
            }
            self.hatchSlots[slotID] = slot
            self.revision += 1
        }
    }

    // MARK: Raster

    /// Dithered preview of an image object. `image` is nil when nothing is available (yet, or the engine returns none);
    /// `isPending` tells whether a computation is still running.
    func rasterPreview(_ object: DesignObject) -> (image: CGImage?, isPending: Bool) {
        guard case .image(let content) = object.kind else { return (nil, false) }
        let key = RasterKey(dataCount: content.pngData.count, settings: content.raster,
                            width: object.placement.width, height: object.placement.height)
        var slot = rasterSlots[object.id] ?? Slot()
        if let r = slot.result, r.key == key { return (r.value, false) }
        if slot.running {
            slot.pending = (key, object)
        } else {
            slot.running = true
            startRaster(key, object: object)
        }
        rasterSlots[object.id] = slot
        return (slot.result?.value ?? nil, true)
    }

    private func startRaster(_ key: RasterKey, object: DesignObject) {
        let id = object.id
        Task {
            let image = await Task.detached(priority: .utility) { () -> CGImage? in
                guard let bitmap = object.rasterBitmap() else { return nil }
                return RasterEngraver.previewImage(bitmap)
            }.value
            var slot = self.rasterSlots[id] ?? Slot()
            slot.result = (key, image)
            slot.running = false
            if let next = slot.pending {
                slot.pending = nil
                if next.key != key {
                    slot.running = true
                    self.startRaster(next.key, object: next.object)
                }
            }
            self.rasterSlots[id] = slot
            self.revision += 1
        }
    }

    /// Forgets caches of objects that no longer exist.
    func prune(keeping ids: Set<UUID>) {
        outlines = outlines.filter { ids.contains($0.key) }
        rasterSlots = rasterSlots.filter { ids.contains($0.key) }
        hatchSlots = hatchSlots.filter { entry in
            guard let idPart = entry.key.split(separator: "#").first, let id = UUID(uuidString: String(idPart)) else { return false }
            return ids.contains(id)
        }
    }
}
