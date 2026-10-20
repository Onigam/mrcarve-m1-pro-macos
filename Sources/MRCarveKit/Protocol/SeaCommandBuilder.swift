import Foundation

/// Which USB pipe a command is sent on (see `docs/PROTOCOL.md`). confirmed.
public enum SeaChannel: String, Sendable {
    /// Command endpoint 0x06, reply read on 0x88 (queries, state changes). `TransferCtrl::SendCmd`.
    case command
    /// Data endpoint 0x02, ack read on 0x84 (geometry / batched streams). `TransferCtrl::SendData`.
    case data
}

/// A command plus the channel it belongs on and a human-readable annotation (used by `dryrun`).
public struct CompiledCommand: Sendable {
    public let command: SeaCommand
    public let channel: SeaChannel
    public let note: String
    public init(_ command: SeaCommand, _ channel: SeaChannel, _ note: String) {
        self.command = command; self.channel = channel; self.note = note
    }
}

/// Constructs the specific `SeaCommand`s the init / framing / marking paths use. Only the primary data
/// fields (the ones that determine machine behaviour) are filled; reserved trailing bytes are left as the
/// device's zero padding. Field order and byte widths are confirmed from the vendor builders; treat the
/// exact reserved padding as `unverified`.
public enum SeaCommandBuilder {
    // MARK: Status / lifecycle (command channel)

    public static func getDeviceInfo() -> SeaCommand { SeaCommand(.getDeviceInfo, hasLength: false) }
    public static func getBaseState() -> SeaCommand { SeaCommand(.getBaseState, hasLength: false) }
    public static func heartbeat() -> SeaCommand { SeaCommand(.heartbeat, hasLength: false) }

    /// `SetBoardStatus(mode)`: 0 reset, 1 ready, 2 run-ready, 3 run. confirmed opcode; param at payload[2].
    public static func setBoardStatus(_ mode: UInt8) -> SeaCommand {
        SeaCommand(.setBoardStatus, hasLength: false, params: [mode])
    }
    public static func clearCache() -> SeaCommand { SeaCommand(.clearCache, hasLength: false) }
    public static func online(_ on: Bool) -> SeaCommand {
        SeaCommand(.online, hasLength: false, params: [on ? 0 : 1])  // SetOnline sends inverted flag
    }
    /// `PauseMark`/`ResumeMark` share opcode 0xAA2C. inferred: byte distinguishes pause vs resume.
    public static func pause() -> SeaCommand { SeaCommand(.pauseResume, hasLength: false, params: [1]) }
    public static func resume() -> SeaCommand { SeaCommand(.pauseResume, hasLength: false, params: [0]) }

    // MARK: Laser parameters (data channel, batched)

    /// Red pointer on/off (`SendRedSignal`/`SetRedLightMark`, op 0x0212). confirmed: payload[4] = on.
    public static func redPointer(_ on: Bool) -> SeaCommand {
        SeaCommand(.redSignal, params: [on ? 1 : 0, 0])
    }
    /// Master-oscillator gate (`SetMoStatus`/`SendMOSignal`, op 0x0210). confirmed: payload[4] = on,
    /// payload[6..7] = MO delay (µs, big-endian). inferred delay placement.
    public static func masterOscillator(_ on: Bool, delayMicros: UInt16 = 0) -> SeaCommand {
        SeaCommand(.moSignal, params: [on ? 1 : 0, 0] + SeaEncode.u16(delayMicros))
    }
    /// Fiber power (`SendFiberPower`, op 0x0214). confirmed: payload[4..5] = 16-bit power DAC, big-endian.
    public static func fiberPower(_ dac16: UInt16) -> SeaCommand {
        SeaCommand(.fiberPower, params: SeaEncode.u16(dac16))
    }
    /// PWM frequency period (`SendPWMSignal`, op 0x0218). confirmed: payload[6..9] carry the 32-bit period;
    /// we send the 16-bit period in the low half. unverified exact field width.
    public static func pwm(periodReg: UInt16) -> SeaCommand {
        SeaCommand(.pwmSignal, params: [1, 0] + SeaEncode.u32(UInt32(periodReg)))
    }
    /// Q pulse-width index for MOPA sources (`SendMOPALaser`, op 0x0216). confirmed opcode.
    public static func mopaPulse(_ index: UInt16) -> SeaCommand {
        SeaCommand(.mopaLaser, params: SeaEncode.u16(index) + [0xA5, 0x01])
    }
    /// Laser on/off delays (`SendLightOnDelay`, op 0x0208). confirmed: payload[4..5] laser-on offset,
    /// payload[6..7] open delay, both big-endian. inferred pairing.
    public static func lightDelays(onDelay: UInt16, offDelay: UInt16) -> SeaCommand {
        SeaCommand(.lightOnDelay, params: SeaEncode.u16(onDelay) + SeaEncode.u16(offDelay))
    }

    // MARK: Motion (data channel, batched)

    /// `MoveToAbs`/`GotoPosition` (op 0x0241): jump with the laser off.
    /// params = time(u16 BE) · delay(u16 BE) · X(24-bit BE) · Y(24-bit BE) · 3 reserved zero bytes. confirmed.
    public static func moveToAbs(x: Int, y: Int, time: UInt16, delay: UInt16) -> SeaCommand {
        SeaCommand(.moveToAbs, params: SeaEncode.u16(time) + SeaEncode.u16(delay)
                   + SeaEncode.coord(x) + SeaEncode.coord(y) + [0, 0, 0])
    }
    /// `LineToAbs`/`LinetoPosition` (op 0x0245): mark with the laser on. Same param layout as `moveToAbs`.
    /// confirmed.
    public static func lineToAbs(x: Int, y: Int, time: UInt16, delay: UInt16) -> SeaCommand {
        SeaCommand(.lineToAbs, params: SeaEncode.u16(time) + SeaEncode.u16(delay)
                   + SeaEncode.coord(x) + SeaEncode.coord(y) + [0, 0, 0])
    }
}
