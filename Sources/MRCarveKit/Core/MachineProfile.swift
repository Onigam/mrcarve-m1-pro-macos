import Foundation

/// Which laser source a profile is for. The M1 Pro ships two parameter sets:
/// `LmcPar_Fiber.cfg` (1064 nm) and `LmcPar_Blue.cfg` (blue diode).
public enum LaserSource: String, Codable, Hashable, Sendable, CaseIterable {
    case fiber
    case blue
}

/// Galvo / field-lens calibration. Mirrors the `LEN_*` keys of the vendor `LmcPar_*.cfg` files.
public struct LensParameters: Codable, Hashable, Sendable {
    public var workSize: Double = 70          // LEN_WORKSIZE, mm (square field)
    public var scaleX: Double = 64.407        // LEN_SCALEX
    public var scaleY: Double = 64.424        // LEN_SCALEY
    public var bucketX: Double = 1.038        // LEN_BUCKETX (barrel/pincushion)
    public var bucketY: Double = 0.958        // LEN_BUCKETY
    public var trapezoidX: Double = 0.997     // LEN_TRAPEX
    public var trapezoidY: Double = 0.999     // LEN_TRAPEY
    public var parallelogramX: Double = 1     // LEN_PRRLX
    public var parallelogramY: Double = 1     // LEN_PRRLY
    public var fieldOffsetX: Double = 0       // LEN_FIELDOFFSETX, mm
    public var fieldOffsetY: Double = 0       // LEN_FIELDOFFSETY, mm
    public var rotateAngle: Double = 0        // LEN_ROTATEANGLE, degrees
    public var invertX: Bool = false          // LEN_XINVERT
    public var invertY: Bool = false          // LEN_YINVERT
    public var swapXY: Bool = false           // LEN_XYFLIP
    public var maxSpeed: Double = 10000       // LEN_MAXSPEED, mm/s
    public var minSpeed: Double = 1           // LEN_MINSPEED, mm/s
    public var useCorrectionFile: Bool = false // LEN_ENABLECORFILE
    public var correctionFilePath: String?    // COR_FILENAME

    public init() {}
}

/// Red pointer (framing) calibration. Mirrors `REDLIGHT*` keys.
public struct RedLightParameters: Codable, Hashable, Sendable {
    public var speed: Double = 7000           // REDLIGHTSPEED, mm/s
    public var offsetX: Double = 0.21         // REDLIGHTOFFSETX, mm
    public var offsetY: Double = 0.1          // REDLIGHTOFFSETY, mm
    public var scaleX: Double = 1.01          // REDLIGHTSCALEX
    public var scaleY: Double = 1.01          // REDLIGHTSCALEY
    public var outputPort: Int = 0            // REDLIGHTOUTPORT

    public init() {}
}

/// Laser source configuration. Mirrors the `OPC_*` / `LASERTYPE` keys.
public struct LaserSourceParameters: Codable, Hashable, Sendable {
    public var laserType: Int = 0             // LASERTYPE
    public var fiberType: Int = 0             // FIBERTYPE
    public var firstPulseKiller: Bool = true  // OPC_FPK
    public var firstPulseKillerTime: Double = 20 // OPC_FPKTIME, µs
    public var pwmOutput: Bool = true         // OPC_ENPWMOUT
    public var analogPowerOutput: Bool = true // OPC_ENPOWERANALOGOUT
    public var minFrequency: Double = 20      // OPC_MINPWMFREQ, kHz
    public var maxFrequency: Double = 200     // OPC_MAXPWMFREQ, kHz
    public var minPulseWidth: Double = 0      // OPC_MINQPW
    public var maxPulseWidth: Double = 200    // OPC_MAXQPW
    public var moDelay: Double = 8            // OPC_MoDelay
    /// 11-point power mapping table (OPC_POWERMAP0...10), % in → % out.
    public var powerMap: [Double] = [10, 15, 20, 30, 40, 50, 60, 70, 80, 90, 97]

    public init() {}
}

/// Everything the device layer needs to know about the machine.
/// `raw` keeps every key of the imported `.cfg` so the protocol layer can read values
/// that are not modelled explicitly yet.
public struct MachineProfile: Codable, Hashable, Sendable {
    public var name: String
    public var source: LaserSource
    public var lens: LensParameters
    public var redLight: RedLightParameters
    public var laser: LaserSourceParameters
    public var raw: [String: String]

    public init(name: String = "M1 Pro", source: LaserSource = .fiber,
                lens: LensParameters = .init(), redLight: RedLightParameters = .init(),
                laser: LaserSourceParameters = .init(), raw: [String: String] = [:]) {
        self.name = name
        self.source = source
        self.lens = lens
        self.redLight = redLight
        self.laser = laser
        self.raw = raw
    }

    /// Marking field centred on the origin, in mm.
    public var field: Rect2 {
        let h = lens.workSize / 2
        return Rect2(minX: -h, minY: -h, maxX: h, maxY: h)
    }
}
