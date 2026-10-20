import Foundation

/// Converts field coordinates (mm, origin at field centre, +Y up) to 16-bit galvo DAC counts.
///
/// Mirrors the vendor `CDevUtil::LP2DPEX` (@0x13c634) → `LP2DPEX_SFT` → `CalibPoint` → `CCalibAlg::CalibManual`
/// (@0x121d04 in libBslCal) "box" calibration, which is the path taken when `LEN_ENABLECORFILE == 0`
/// (true for the M1 Pro's shipped `LmcPar_Fiber.cfg`/`LmcPar_Blue.cfg`). The 9-point / `.cor`-file least-
/// squares path (`CalibLSM`, `Calib9Pt`) is **not** implemented — see `docs/PROTOCOL.md`.
///
/// Confidence: the pipeline and the constants (galvo max 0xFFFF, centre 0x8000, counts/mm = 0xFFFF/workSize,
/// barrel normaliser 0xFFFF²) are confirmed from the decompiled code; treat the exact arithmetic as
/// **unverified** until checked against the machine.
public struct GalvoTransform: Sendable {
    public static let galvoMax = 65535.0
    public static let galvoCenter = 32768.0
    private static let normalizer = 65535.0 * 65535.0

    let lens: LensParameters

    public init(_ lens: LensParameters) { self.lens = lens }
    public init(_ machine: MachineProfile) { self.lens = machine.lens }

    /// mm → galvo counts (x, y each 0...65535). Point is clamped into range, as the device does.
    public func counts(_ p: Vec2) -> (x: Int, y: Int) {
        // 1. Field offset, then optional field rotation about (ROTATEOX, ROTATEOY) — defaults to origin.
        var x = p.x + lens.fieldOffsetX
        var y = p.y + lens.fieldOffsetY
        if abs(lens.rotateAngle) > 1e-4 {
            let a = lens.rotateAngle * .pi / 180
            let (s, c) = (sin(a), cos(a))
            let nx = c * x - s * y
            let ny = s * x + c * y
            x = nx; y = ny
        }

        // 2. Axis swap / inversion (CDevUtil::CalibPoint, box branch). For the M1 Pro these are all off.
        if lens.swapXY { swap(&x, &y) }
        if lens.invertX { x = -x }
        if lens.invertY { y = -y }

        // 3. Box correction (CalibManual). Vendor computes in single precision; we use Double.
        let g = Self.galvoMax / lens.workSize                 // counts per mm (full field = 0xFFFF)
        let a0 = lens.scaleX * x / 100.0                       // LEN_SCALEX fine-trim
        let b0 = lens.scaleY * y / 100.0
        let a1 = a0 - (1.0 - lens.parallelogramX) * b0         // LEN_PRRLX
        let b1 = b0 - (1.0 - lens.parallelogramY) * a0         // LEN_PRRLY
        let a2 = (a1 + ((1.0 - lens.trapezoidX) * b1 * a1 * -2.0) / lens.workSize) * g   // LEN_TRAPEX
        let b2 = (b1 + ((1.0 - lens.trapezoidY) * a1 * b1 * -2.0) / lens.workSize) * g   // LEN_TRAPEY
        let fx = a2 + (b2 * (lens.bucketX - 1.0) * a2 * b2) / Self.normalizer            // LEN_BUCKETX (barrel)
        let fy = b2 + ((lens.bucketY - 1.0) * b2 * a2 * a2) / Self.normalizer            // LEN_BUCKETY

        let gx = (fx + Self.galvoCenter).rounded()
        let gy = (fy + Self.galvoCenter).rounded()
        return (Int(max(0, min(Self.galvoMax, gx))), Int(max(0, min(Self.galvoMax, gy))))
    }

    /// Returns true if the point lands strictly inside the galvo range before clamping.
    public func inRange(_ p: Vec2) -> Bool {
        let g = Self.galvoMax / lens.workSize
        let a0 = lens.scaleX * p.x / 100.0, b0 = lens.scaleY * p.y / 100.0
        let fx = a0 * g + Self.galvoCenter, fy = b0 * g + Self.galvoCenter
        return fx >= 0 && fx <= Self.galvoMax && fy >= 0 && fy <= Self.galvoMax
    }
}
