import Foundation

/// Board run states written by `SetBoardStatus` (0xAA10). confirmed values from `SetReset`/`SetReady`/
/// `SetRunReady`/`SetRun`.
public enum BoardStatus: UInt8, Sendable {
    case reset = 0, ready = 1, runReady = 2, run = 3
}

/// Parsed `GetDevBaseState` (0xAA05) reply. Field meanings are inferred from `updateDevBaseState`
/// (@0x12acf8) and the Windows status parser (`FUN_10069580`); offsets are relative to the reply payload
/// after the 4-byte header the vendor skips (`updateDevBaseState(payload+4)`).
public struct DeviceBaseState: Hashable, Sendable {
    public var boardStatus: UInt8          // base[0]: 0 reset … 3 run
    public var laserState: UInt16          // base[4..5] BE; must be 0 before a job may start
    public var idle: Bool                  // base[8] bit0: cache drained / mark finished
    public var freeCacheBytes: Int         // base[9..11] BE24, in KiB per the vendor (×1024 here)

    /// Returns nil if the buffer is too short to contain a base-state reply. inferred length ≥ 16.
    public init?(payload: [UInt8]) {
        guard payload.count >= 16 else { return nil }
        let b = Array(payload[4...])
        boardStatus = b[0]
        laserState = (UInt16(b[4]) << 8) | UInt16(b[5])
        idle = (b[8] & 1) != 0
        freeCacheBytes = ((Int(b[9]) << 16) | (Int(b[10]) << 8) | Int(b[11])) * 1024
    }
}

/// Compiles a `MarkJob` (or its outline) into an ordered command stream. Mirrors the vendor flow:
/// `SendMarkPara` → `SendPenPara` → `SetMoStatus(true)` → per-polyline `GotoPosition`+`LinetoPosition`
/// → `SetMoStatus(false)` (`CController::MarkPaths` @0x486eb8, `CCmdExecutor::MarkLines` @0x133384).
///
/// The marking laser is enabled **only** by `compileMark`; `compileFrame` traces with the red pointer and
/// the master oscillator gated off.
public struct MarkCompiler: Sendable {
    public let machine: MachineProfile
    let transform: GalvoTransform

    public init(machine: MachineProfile) {
        self.machine = machine
        self.transform = GalvoTransform(machine)
    }

    /// True if every point of the job maps inside the galvo field.
    public func fitsField(_ job: MarkJob) -> Bool {
        for item in job.items {
            for pl in item.polylines {
                for p in pl.traversal where !transform.inRange(p) { return false }
            }
        }
        return true
    }

    // MARK: Marking (laser ON)

    public func compileMark(_ job: MarkJob) -> [CompiledCommand] {
        var out: [CompiledCommand] = []
        for (passIndex) in 0..<max(1, job.repeatCount) {
            for item in job.items where item.pen.isEnabled && !item.polylines.isEmpty {
                out += penSetup(item.pen, red: false)
                out.append(CompiledCommand(SeaCommandBuilder.masterOscillator(true, delayMicros: UInt16(machine.laser.moDelay)),
                                           .data, "MO gate on"))
                let conv = PenConversion(pen: item.pen, machine: machine)
                for _ in 0..<max(1, item.pen.loopCount) {
                    out += geometry(item, conv: conv, laserOn: true)
                }
                out.append(CompiledCommand(SeaCommandBuilder.masterOscillator(false), .data, "MO gate off"))
            }
            _ = passIndex
        }
        return out
    }

    // MARK: Framing (red pointer, laser OFF)

    public func compileFrame(_ job: MarkJob, outlineOnly: Bool) -> [CompiledCommand] {
        var out: [CompiledCommand] = []
        out.append(CompiledCommand(SeaCommandBuilder.masterOscillator(false), .data, "MO gate off (framing)"))
        out.append(CompiledCommand(SeaCommandBuilder.redPointer(true), .data, "red pointer on"))

        // Red framing uses the red-light speed, laser parameters are not uploaded.
        var redPen = PenParameters(id: 0)
        redPen.markSpeed = machine.redLight.speed
        redPen.jumpSpeed = machine.redLight.speed
        let conv = PenConversion(pen: redPen, machine: machine)

        let polylines: [Polyline]
        if outlineOnly, let b = job.bounds {
            polylines = [b.outline]
        } else {
            polylines = job.items.flatMap { $0.polylines }
        }
        for pl in polylines {
            out += trace(pl.traversal, conv: conv, laserOn: false, note: "red")
        }
        return out
    }

    public func framingOff() -> [CompiledCommand] {
        [CompiledCommand(SeaCommandBuilder.redPointer(false), .data, "red pointer off")]
    }

    // MARK: Helpers

    private func penSetup(_ pen: PenParameters, red: Bool) -> [CompiledCommand] {
        let conv = PenConversion(pen: pen, machine: machine)
        var cmds: [CompiledCommand] = []
        cmds.append(CompiledCommand(SeaCommandBuilder.redPointer(false), .data, "red pointer off"))
        cmds.append(CompiledCommand(SeaCommandBuilder.lightDelays(onDelay: conv.laserOnDelay, offDelay: conv.laserOffDelay),
                                    .data, "laser on/off delays \(conv.laserOnDelay)/\(conv.laserOffDelay) µs"))
        cmds.append(CompiledCommand(SeaCommandBuilder.pwm(periodReg: conv.frequencyRegister),
                                    .data, "PWM period \(conv.frequencyRegister) (= \(Int(pen.frequency)) kHz)"))
        cmds.append(CompiledCommand(SeaCommandBuilder.fiberPower(conv.powerDAC16),
                                    .data, "power \(Int(pen.power))% → DAC \(conv.powerDAC16)"))
        return cmds
    }

    private func geometry(_ item: MarkItem, conv: PenConversion, laserOn: Bool) -> [CompiledCommand] {
        var out: [CompiledCommand] = []
        switch item.kind {
        case .vector:
            for pl in item.polylines { out += trace(pl.traversal, conv: conv, laserOn: laserOn, note: "mark") }
        case .dots(let dwell):
            let dwellMs = dwell ?? item.pen.pointDwell
            let dwellTime = UInt16(max(0, min(65535, dwellMs * 1000)))  // ms → µs
            for pl in item.polylines {
                for p in pl.points {
                    let g = transform.counts(p)
                    out.append(CompiledCommand(SeaCommandBuilder.moveToAbs(x: g.x, y: g.y, time: conv.jumpTime(distanceMM: 0), delay: conv.jumpDelay(distanceMM: 0)),
                                               .data, "dot jump → (\(g.x),\(g.y))"))
                    out.append(CompiledCommand(SeaCommandBuilder.lineToAbs(x: g.x, y: g.y, time: dwellTime, delay: conv.laserOffDelay),
                                               .data, "dot dwell \(Int(dwellMs)) ms"))
                }
            }
        }
        return out
    }

    /// Jump to the first point (laser off), then trace the rest with LineTo.
    private func trace(_ pts: [Vec2], conv: PenConversion, laserOn: Bool, note: String) -> [CompiledCommand] {
        guard let first = pts.first else { return [] }
        var out: [CompiledCommand] = []
        var prev = first
        let g0 = transform.counts(first)
        out.append(CompiledCommand(SeaCommandBuilder.moveToAbs(x: g0.x, y: g0.y,
                                                               time: conv.jumpTime(distanceMM: 0),
                                                               delay: conv.jumpDelay(distanceMM: 0)),
                                   .data, "\(note) jump → (\(g0.x),\(g0.y))"))
        for p in pts.dropFirst() {
            let dist = prev.distance(to: p)
            let g = transform.counts(p)
            out.append(CompiledCommand(SeaCommandBuilder.lineToAbs(x: g.x, y: g.y,
                                                                   time: conv.markTime(distanceMM: dist),
                                                                   delay: conv.laserOffDelay),
                                       .data, "\(note) line → (\(g.x),\(g.y))"))
            prev = p
        }
        return out
    }
}
