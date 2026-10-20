import Foundation
import CoreGraphics

/// Position, size and orientation of a design object in field coordinates (mm, +Y up).
///
/// Object geometry is generated in a *local* frame centred on the origin and already at its final
/// `width`×`height`; `transform` then mirrors, rotates (counter-clockwise, degrees) and moves it to `center`.
public struct Placement: Codable, Hashable, Sendable {
    public var center: Vec2
    public var width: Double
    public var height: Double
    /// Degrees, counter-clockwise (field +Y is up).
    public var rotation: Double
    /// Flip left ↔ right (about the object's vertical axis).
    public var mirrorX: Bool
    /// Flip top ↔ bottom (about the object's horizontal axis).
    public var mirrorY: Bool

    public init(center: Vec2 = .zero, width: Double, height: Double, rotation: Double = 0,
                mirrorX: Bool = false, mirrorY: Bool = false) {
        self.center = center
        self.width = width
        self.height = height
        self.rotation = rotation
        self.mirrorX = mirrorX
        self.mirrorY = mirrorY
    }

    /// Local frame → field transform (mirror, then rotate, then translate).
    public var transform: CGAffineTransform {
        CGAffineTransform(translationX: center.x, y: center.y)
            .rotated(by: rotation * .pi / 180)
            .scaledBy(x: mirrorX ? -1 : 1, y: mirrorY ? -1 : 1)
    }

    /// The local box, centred on the origin.
    public var localBox: Rect2 {
        Rect2(minX: -width / 2, minY: -height / 2, maxX: width / 2, maxY: height / 2)
    }

    /// Corners of the placed box in field coordinates, in local order bottom-left, bottom-right, top-right, top-left
    /// (before mirroring).
    public var corners: [Vec2] {
        let t = transform
        let b = localBox
        return [Vec2(b.minX, b.minY), Vec2(b.maxX, b.minY), Vec2(b.maxX, b.maxY), Vec2(b.minX, b.maxY)]
            .map { $0.applying(t) }
    }

    /// Axis-aligned bounds of the placed box.
    public var boundingBox: Rect2 {
        Rect2(enclosing: corners) ?? Rect2(minX: center.x, minY: center.y, maxX: center.x, maxY: center.y)
    }

    /// Rotation normalised to (-180, 180].
    public var normalizedRotation: Double {
        var r = rotation.truncatingRemainder(dividingBy: 360)
        if r <= -180 { r += 360 }
        if r > 180 { r -= 360 }
        return r
    }

    /// Converts a field point into the object's local frame.
    public func localPoint(_ p: Vec2) -> Vec2 {
        p.applying(transform.inverted())
    }
}
