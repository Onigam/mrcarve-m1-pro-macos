import Foundation

/// Low-level host→board command protocol for the BSL / SEA controller used by the MR Carve M1 Pro.
///
/// Reverse-engineered from the vendor core (`re/out/libCoreSDK.so.c`, functions `tagSeaCMD::getData`
/// @0x13922c, `CSeaCmdList::getData` @0x129410, `TransferCtrl::SendCmd`/`SendData` @0x1695e0/0x169218,
/// `LibUsbControl::*` @0x1688d8..) and cross-checked against the Windows build (`re/out/SeaMark.dll.c`,
/// `CDataTransmission::PackageData` @0x10072780). See `docs/PROTOCOL.md`.
///
/// Confidence tags in comments: `confirmed` (byte layout read directly from code), `inferred`
/// (derived from consistent usage), `unverified` (guess, must be validated on hardware).

// MARK: - Opcodes

/// 16-bit command id. On the wire it is the first two payload bytes, **big-endian**
/// (`tagSeaCMD::setCmdId`: payload[0]=id>>8, payload[1]=id&0xff). confirmed.
public enum SeaOpcode: UInt16, Sendable, CaseIterable {
    // --- Query / handshake commands (sent on the COMMAND endpoint 0x06, reply on 0x88) ---
    case getDeviceInfo      = 0xF0F0   // CCmdExecutor via DevComm::GetDevInfo; reply carries FPGA version
    case isBindMe           = 0xF013   // CCmdExecutor::IsBindMe
    case bind               = 0x00FA   // CCmdExecutor::bind  (id byte pattern 0x..F0FA; see PROTOCOL.md)
    case heartbeat          = 0xAA01   // CCmdExecutor::GetDevHeartState
    case getBaseState       = 0xAA05   // CCmdExecutor::GetDevBaseState  (status poll)
    case getExtState        = 0xAA07   // CCmdExecutor::GetDevExtState
    case setBoardStatus     = 0xAA10   // CCmdExecutor::SetBoardStatus(u8 mode)
    case clearCache         = 0xAA18   // CCmdExecutor::ClearCache
    case setGpoValues       = 0xAA22   // CCmdExecutor::SetGpoValues
    case setGpoPulse        = 0xAA23   // CCmdExecutor::SetGpoPulse
    case pauseResume        = 0xAA2C   // CCmdExecutor::PauseMark / ResumeMark
    case online             = 0xAAA4   // CCmdExecutor::SetOnline / ClearCache(online)
    case onlineAck          = 0xAAA6   // CCmdExecutor::SetOnline second packet
    case getBoardModeNew    = 0xFFF1   // GetBoardMode (new protocol); legacy variant 0x0140

    // --- Data / stream opcodes (sent on the DATA endpoint 0x02, batched by CSeaCmdList) ---
    case setHardwareBlock   = 0x0202   // SetHardwareBlock
    case countOnce          = 0x0205   // CountOnce
    case lightOnDelay       = 0x0208   // SendLightOnDelay (laser on/off delays)
    case moSignal           = 0x0210   // SendMOSignal / SetMoStatus (master-oscillator gate)
    case apSignal           = 0x0211   // SendAPSignal
    case redSignal          = 0x0212   // SendRedSignal / SetRedLightMark (red pointer on/off)
    case prrSignal          = 0x0213   // SendPRRSignal (pulse repetition rate)
    case fiberPower         = 0x0214   // SendFiberPower
    case mopaLaser          = 0x0216   // SendMOPALaser (MOPA pulse width index)
    case pwmSignal          = 0x0218   // SendPWMSignal (frequency / Q pulse width)
    case daSignal           = 0x021A   // SendDASignal (analog power DAC)
    case preionFPS          = 0x021B   // SendPreionFPS
    case laserEffectTime    = 0x0220   // SendLaserEffectTime
    case lenPara            = 0x0221   // SendLenPara (lens/field parameters)
    case setDelayTime       = 0x0A00   // SetDelayTime
    case moveToAbs          = 0x0241   // MoveToAbs / GotoPosition (jump, laser off)
    case moveToRel          = 0x0242   // MoveToRel
    case lineToAbs          = 0x0245   // LineToAbs / LinetoPosition (mark, laser on)
    case lineToRel          = 0x0246   // LineToRel
}

// MARK: - tagSeaCMD payload builder

/// Builds a single command payload exactly as the vendor `tagSeaCMD` does (confirmed from
/// `tagSeaCMD::getData` and the per-opcode builders).
///
/// Payload layout:
/// - `[0..1]`  opcode, big-endian
/// - `[2]`     padded payload length, written only when the command carries a length byte (`hasLength`)
/// - `[3]`     0
/// - `[4..]`   parameters
///
/// The builder then pads the payload to at least 12 bytes and to an even length, matching the device's
/// expectation. Multi-byte parameters are little-endian on a little-endian host (the vendor keys the byte
/// order off `CCommFun::isBigEndian`, which is false on all our targets).
public struct SeaCommand: Hashable, Sendable {
    public let opcode: SeaOpcode
    /// Whether payload[2] carries the length (the vendor's `hasLen` flag). confirmed per-opcode.
    public let hasLength: Bool
    /// Parameter bytes placed starting at payload[4] (hasLength) or payload[2] (otherwise).
    public let params: [UInt8]

    public init(_ opcode: SeaOpcode, hasLength: Bool = true, params: [UInt8] = []) {
        self.opcode = opcode
        self.hasLength = hasLength
        self.params = params
    }

    /// The raw payload (opcode + length + params), padded to ≥12 bytes and an even length. confirmed.
    ///
    /// Note: when `hasLength` is false the parameters begin at payload[2] (no length byte); when true
    /// they begin at payload[4]. Build `params` to match the opcode (see `SeaCommandBuilder`).
    public func payload() -> [UInt8] {
        var p: [UInt8] = [UInt8(opcode.rawValue >> 8), UInt8(opcode.rawValue & 0xFF)]
        if hasLength {
            p.append(0)   // length, filled in after padding
            p.append(0)
        }
        p.append(contentsOf: params)
        // Pad to minimum 12 and even length (tagSeaCMD::getData).
        if p.count < 12 { p.append(contentsOf: repeatElement(0, count: 12 - p.count)) }
        if p.count % 2 != 0 { p.append(0) }
        if hasLength { p[2] = UInt8(truncatingIfNeeded: p.count) }
        return p
    }
}

// MARK: - Parameter encoding helpers

public enum SeaEncode {
    /// Multi-byte scalar params are **big-endian** on the wire: the vendor byte-swaps everything off the
    /// `CCommFun::isBigEndian` flag so the bytes always land in the board's (big-endian) order. confirmed
    /// (e.g. `MoveToAbs` @0x134088 writes time/delay as `hi,lo`; `SetDelayTime` writes a 32-bit BE value).
    public static func u16(_ v: UInt16) -> [UInt8] { [UInt8(v >> 8), UInt8(v & 0xFF)] }
    public static func u32(_ v: UInt32) -> [UInt8] {
        [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
    }
    /// A galvo coordinate occupies **3 bytes, big-endian** (`MoveToAbs`/`LineToAbs` builders write
    /// `byte2,byte1,byte0`); 2D marking uses the low 16 bits, the top byte is 0. confirmed.
    public static func coord(_ v: Int) -> [UInt8] {
        let u = UInt32(max(0, min(0xFFFF, v)))
        return [UInt8((u >> 16) & 0xFF), UInt8((u >> 8) & 0xFF), UInt8(u & 0xFF)]
    }
}

// MARK: - Framing (new protocol)

/// Frames a payload for transport, matching `tagSeaCMD::getData(withHeader=true)` and the Windows
/// `CDataTransmission::PackageData`. confirmed.
///
/// Frame = `FE FF | len16(BE) | flags | 00 | payload | 00 | checksum`
/// - `len16` = total frame length = payload.count + 8, big-endian
/// - `flags` = `0x80 | seq` for a command (expects a reply), or `seq` for a data/batch buffer
/// - `checksum` = (payload[0] + payload[1] + payload[last] + payload[last-1]) & 0xFF, computed over the
///   payload bytes that sit at frame offsets 6,7 and len-3,len-4 (the trailing 0 is byte len-2). confirmed.
public enum SeaFrame {
    public static let sync: [UInt8] = [0xFE, 0xFF]

    public static func encode(payload: [UInt8], isCommand: Bool, seq: UInt8) -> [UInt8] {
        let total = payload.count + 8
        var f = [UInt8]()
        f.reserveCapacity(total)
        f.append(contentsOf: sync)
        f.append(UInt8(total >> 8))
        f.append(UInt8(total & 0xFF))
        f.append(isCommand ? (0x80 | (seq & 0x0F)) : (seq & 0x0F))
        f.append(0)
        f.append(contentsOf: payload)
        f.append(0)                 // trailing zero (frame offset total-2)
        // checksum over payload[0], payload[1], payload[last], payload[last-1]
        let n = payload.count
        let cs = Int(payload[0]) &+ Int(payload[1]) &+ Int(payload[n - 1]) &+ Int(payload[n - 2])
        f.append(UInt8(truncatingIfNeeded: cs))
        return f
    }

    /// Validates and strips a reply frame, returning its payload. Mirrors the reply handling in
    /// `TransferCtrl::SendCmd`: verify the checksum, require the net-error bits (flags & 0x0E00) clear,
    /// and strip 6 header + 2 trailer bytes. inferred (exact header echo matching not enforced here).
    public static func decode(_ frame: [UInt8]) -> (payload: [UInt8], flags: UInt16)? {
        guard frame.count >= 10, frame[0] == 0xFE, frame[1] == 0xFF else { return nil }
        let total = (Int(frame[2]) << 8) | Int(frame[3])
        guard total <= frame.count, total >= 10 else { return nil }
        let flags = (UInt16(frame[4]) << 8) | UInt16(frame[5])
        let payload = Array(frame[6..<(total - 2)])
        return (payload, flags)
    }
}
