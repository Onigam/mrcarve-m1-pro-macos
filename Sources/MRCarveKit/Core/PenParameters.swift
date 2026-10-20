import Foundation

/// Laser parameters attached to a pen (layer). Mirrors the vendor `tagPenPar` structure.
/// Units are the ones shown in the original software's UI.
/// NOTE: field list is provisional until the protocol reverse-engineering pass confirms `tagPenPar`;
/// the protocol layer may add fields, but must not rename existing ones.
public struct PenParameters: Codable, Hashable, Sendable, Identifiable {
    public var id: Int                     // pen index, 0...255
    public var name: String
    public var colorRGB: UInt32            // 0xRRGGBB, display only
    public var isEnabled: Bool = true

    // Marking
    public var loopCount: Int = 1          // passes
    public var markSpeed: Double = 500     // mm/s
    public var power: Double = 50          // % of max power
    public var frequency: Double = 30      // kHz
    public var pulseWidth: Double = 200    // Q pulse width (ns for MOPA, µs-scale for Q-switched; as in vendor UI)

    // Jumps (laser off)
    public var jumpSpeed: Double = 4000    // mm/s
    public var jumpPositionDelay: Double = 300   // µs
    public var jumpDistanceDelay: Double = 100   // µs per jump (distance-dependent part)
    public var minJumpDelay: Double = 100        // µs
    public var maxJumpDelay: Double = 300        // µs
    public var maxJumpDistance: Double = 10      // mm

    // Timing
    public var laserOnDelay: Double = 100   // µs, "Start Delay"
    public var laserOffDelay: Double = 100  // µs, "End Delay"
    public var endMarkDelay: Double = 100   // µs
    public var cornerDelay: Double = 50     // µs, "Polygon/Corner Delay"

    // Misc
    public var endCompensate: Double = 0    // mm
    public var accelerationDistance: Double = 0 // mm
    public var pointDwell: Double = 1       // ms, dot / pixel dwell time

    public init(id: Int, name: String? = nil, colorRGB: UInt32? = nil) {
        self.id = id
        self.name = name ?? "Pen \(id)"
        self.colorRGB = colorRGB ?? PenParameters.defaultColors[id % PenParameters.defaultColors.count]
    }

    /// Palette used by the original software for pens 0...15.
    public static let defaultColors: [UInt32] = [
        0x000000, 0x0000FF, 0xFF0000, 0x00FF00, 0xFF00FF, 0x00FFFF, 0xFFFF00, 0x808000,
        0x800080, 0x008080, 0x800000, 0x000080, 0x008000, 0x808080, 0xFF8000, 0x8000FF,
    ]
}
