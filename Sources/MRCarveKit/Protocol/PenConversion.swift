import Foundation

/// Converts `PenParameters` (UI units) into the register values the board expects, and computes the
/// per-move timing the vendor uses. Derived from `CCmdExecutor::SendFiberPower` (@0x12d548),
/// `SendPWMSignal` (@0x12d75c), `SendPRRSignal` (@0x12d46c), `GetJumpTime` (@0x130580) and
/// `GotoPosition`/`LinetoPosition`. Values are clamped to the machine's declared limits.
///
/// Confidence: the formulas (power·0xFFFF/100, 48000/freq_kHz period, distance·1e6/speed timing) are
/// confirmed from the decompiled builders; apply on hardware at low power first.
public struct PenConversion: Sendable {
    /// 48 MHz board timebase used for PWM frequency and PRR period registers. confirmed (constant 48000).
    public static let timebaseKHz = 48_000.0

    public let pen: PenParameters
    public let laser: LaserSourceParameters

    public init(pen: PenParameters, machine: MachineProfile) {
        self.laser = machine.laser
        // Clamp UI values to profile limits so an out-of-range pen cannot drive the laser past spec.
        var p = pen
        p.power = min(max(p.power, 0), 100)
        p.frequency = min(max(p.frequency, machine.laser.minFrequency), machine.laser.maxFrequency)
        p.pulseWidth = min(max(p.pulseWidth, machine.laser.minPulseWidth), machine.laser.maxPulseWidth)
        p.markSpeed = min(max(p.markSpeed, machine.lens.minSpeed), machine.lens.maxSpeed)
        p.jumpSpeed = min(max(p.jumpSpeed, machine.lens.minSpeed), machine.lens.maxSpeed)
        self.pen = p
    }

    /// 16-bit fiber power DAC: `round(power% · 65535 / 100)`. confirmed (`SendFiberPower`).
    public var powerDAC16: UInt16 {
        UInt16(max(0, min(65535, (pen.power * 65535.0 / 100.0).rounded())))
    }

    /// 12-bit analog power DAC: `round(power% · 4095 / 100)` (before the optional POWERANALOGMAP curve).
    /// confirmed shape (`SendDASignal`); the power map is not applied here.
    public var powerDAC12: UInt16 {
        UInt16(max(0, min(4095, (pen.power * 4095.0 / 100.0).rounded())))
    }

    /// PWM frequency period register = `round(48000 / freq_kHz)` (ticks of the 48 MHz clock).
    /// confirmed (`SendPWMSignal`: `48000.0 / freq`).
    public var frequencyRegister: UInt16 {
        let f = max(pen.frequency, 0.001)
        return UInt16(max(0, min(65535, (Self.timebaseKHz / f).rounded())))
    }

    /// Pulse-repetition-rate register, same formula as the frequency register. confirmed (`SendPRRSignal`).
    public var prrRegister: UInt16 { frequencyRegister }

    /// Laser-on ("open") delay in µs — the register is sent verbatim. confirmed key (OPENDEPLAY @pen+0x50).
    public var laserOnDelay: UInt16 { UInt16(max(0, min(65535, pen.laserOnDelay.rounded()))) }
    /// Laser-off ("shut") delay in µs. confirmed key (SHUTDEPLAY @pen+0x54).
    public var laserOffDelay: UInt16 { UInt16(max(0, min(65535, pen.laserOffDelay.rounded()))) }
    /// Corner/polygon delay in µs. confirmed key (CORNERDEPLAY @pen+0x5c).
    public var cornerDelay: UInt16 { UInt16(max(0, min(65535, pen.cornerDelay.rounded()))) }

    /// Galvo move time for a segment of `distanceMM` at the mark speed, clamped to 16 bits.
    /// `time = distance · 1e6 / markSpeed` (µs). confirmed (`LinetoPosition`, `MarkLines`).
    public func markTime(distanceMM: Double) -> UInt16 {
        timeUnits(distanceMM: distanceMM, speed: pen.markSpeed)
    }
    /// Galvo jump time at the jump speed. confirmed (`GetJumpTime`, `GotoPosition`).
    public func jumpTime(distanceMM: Double) -> UInt16 {
        timeUnits(distanceMM: distanceMM, speed: pen.jumpSpeed)
    }

    private func timeUnits(distanceMM: Double, speed: Double) -> UInt16 {
        let t = (distanceMM * 1_000_000.0) / max(speed, 0.001)
        return UInt16(max(0, min(65535, t.rounded())))
    }

    /// Jump settle delay: interpolate `minJumpDelay…maxJumpDelay` over `0…maxJumpDistance`, clamped.
    /// confirmed (`GetJumpTime`: `delay = minDelay + dist·(maxDelay-minDelay)/maxDist` for dist ≤ maxDist,
    /// else `maxDelay`). Delays are the `ADV_JUMP*DELAY` registers in µs.
    public func jumpDelay(distanceMM: Double) -> UInt16 {
        let maxDist = max(pen.maxJumpDistance, 1e-6)
        let d: Double
        if distanceMM <= maxDist {
            d = pen.minJumpDelay + distanceMM * (pen.maxJumpDelay - pen.minJumpDelay) / maxDist
        } else {
            d = pen.maxJumpDelay
        }
        return UInt16(max(0, min(65535, d.rounded())))
    }
}
