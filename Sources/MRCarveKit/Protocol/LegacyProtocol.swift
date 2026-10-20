import Foundation

/// Which wire protocol a board speaks.
///
/// - `legacy`: the "old" protocol — raw, fixed **12-byte** command blocks, no `FE FF` framing, 12-byte replies.
///   Present in the Windows build as the `IsNewProtocol() == false` branches of every command builder
///   (`SeaMark.dll`, transmission vtable `+0x48`). **Hardware evidence:** the owner's unit (FPGA 1.6.0.8
///   family, Windows-era USB board) answered a framed `F0F0` request with the 12-byte block
///   `00 00 FF FF 81 00 F0 F0 00 00 00 00` — i.e. it parsed our `FE FF` as an (unknown) opcode.
/// - `framed`: the "new" protocol (`FE FF` frames, see `SeaFrame`) used by the Android core and by the
///   Windows build when its new-protocol flag is set (`FUN_1006fa90` sets it to 1 by default).
public enum SeaProtocolVariant: String, Sendable, CaseIterable {
    case legacy, framed
}

/// Old-protocol opcodes, each read directly from an old-branch `htons(…)` literal in `SeaMark.dll`
/// (confirmed), with the new-protocol equivalent where the same function has one. **Numbering differs
/// between protocols** (e.g. old `0x0212` is the lens block while new `0x0212` is the red pointer), so never
/// reuse a new opcode in legacy mode.
public enum LegacyOpcode: UInt16, Sendable, CaseIterable {
    case status          = 0x0101   // FUN_10069580 / FUN_100698d0   (new 0xAA05)
    case modeQuery0102   = 0x0102   // FUN_10066ea0, reply[7] bit1 checked (meaning unknown)
    case extState        = 0x0103   // FUN_10066f40 / FUN_100670b0   (new 0xAA07)
    case setRun          = 0x0104   // FUN_10069400                  (new 0xAA10 03)
    case setReady        = 0x0105   // FUN_100692b0                  (new 0xAA10 01)
    case clearCache      = 0x0106   // FUN_10064770                  (new 0xAA18)
    case query010D       = 0x010D   // FUN_10068fd0                  (new 0xAA34)
    case version         = 0x0110   // FUN_10063f60 GetSSVersion     (new 0xF0F0)
    case gpo             = 0x0111   // FUN_10069cb0                  (new 0xAA22)
    case query0112       = 0x0112   // FUN_1006ae10
    case pauseResume     = 0x0125   // FUN_1006c4e0 / FUN_1006c5a0   (new 0xAA2C)
    case boardMode       = 0x0140   // FUN_10063d20 GetBoardMode     (new 0xFFF1)
    case hardwareBlock   = 0x0202   // FUN_10068de0                  (same)
    case countOnce       = 0x0205   // FUN_10068f00                  (same)
    case lensPara        = 0x0212   // FUN_10067210                  (new 0x0221!)
    case moveToAbs       = 0x0241   // FUN_1006a030                  (same)
    case moveToRel       = 0x0242   // FUN_1006a630                  (same)
    case lineToAbs       = 0x0243   // FUN_1006a330                  (new 0x0245!)
    case lineToRel       = 0x0244   // FUN_1006a930                  (new 0x0246!)
}

/// A raw old-protocol command block: exactly 12 bytes = opcode word + five 16-bit words, all big-endian
/// (`htons`, `Ordinal_9` in the decompile). Sent unframed. confirmed.
public struct LegacyCommand: Hashable, Sendable {
    public static let size = 12
    public let opcode: LegacyOpcode
    /// Words 1…5 (byte offsets 2,4,6,8,10). Missing words are zero.
    public let words: [UInt16]

    public init(_ opcode: LegacyOpcode, words: [UInt16] = []) {
        precondition(words.count <= 5, "a legacy block has 5 parameter words")
        self.opcode = opcode
        self.words = words
    }

    public var bytes: [UInt8] {
        var b = SeaEncode.u16(opcode.rawValue)
        for i in 0..<5 { b += SeaEncode.u16(i < words.count ? words[i] : 0) }
        return b
    }

    // MARK: confirmed builders (read-only queries)

    /// `GetSSVersion` (FUN_10063f60, old branch): `01 10` + 10 zero bytes. Read-only.
    public static func version() -> LegacyCommand { LegacyCommand(.version) }
    /// Status poll (FUN_10069580, old branch): `01 01` + zeros. Read-only (polled every 50 ms by the vendor).
    public static func status() -> LegacyCommand { LegacyCommand(.status) }
    /// `GetBoardMode` (FUN_10063d20, old branch): `01 40`, word5 = 1. Query by usage, but word5's meaning is
    /// unknown — not sent by `connect()`.
    public static func boardMode() -> LegacyCommand { LegacyCommand(.boardMode, words: [0, 0, 0, 0, 1]) }

    // MARK: confirmed builders (state / motion — not used by connect)

    public static func setReady() -> LegacyCommand { LegacyCommand(.setReady) }
    public static func setRun() -> LegacyCommand { LegacyCommand(.setRun) }
    public static func clearCache() -> LegacyCommand { LegacyCommand(.clearCache) }

    /// Old `MoveToAbs` (FUN_1006a030): word1 time, word2 X, word3 Y, word4 0, word5 delay. confirmed.
    /// Coordinates are 16-bit here (`ROUND(x) & 0xFFFF`), unlike the 24-bit new-protocol fields.
    public static func moveToAbs(x: Int, y: Int, time: UInt16, delay: UInt16) -> LegacyCommand {
        LegacyCommand(.moveToAbs, words: [time, clamp16(x), clamp16(y), 0, delay])
    }
    /// Old `LineToAbs` (FUN_1006a330, opcode 0x0243): same layout as `moveToAbs`. confirmed.
    public static func lineToAbs(x: Int, y: Int, time: UInt16, delay: UInt16) -> LegacyCommand {
        LegacyCommand(.lineToAbs, words: [time, clamp16(x), clamp16(y), 0, delay])
    }

    static func clamp16(_ v: Int) -> UInt16 { UInt16(max(0, min(0xFFFF, v))) }
}

/// A 12-byte old-protocol reply. The vendor accepts a reply only when its first word equals the request's
/// first word (`FUN_100649c0`, `FUN_10063f60`: "ReadPort again" on mismatch). confirmed.
public struct LegacyReply: Hashable, Sendable {
    public let bytes: [UInt8]

    public init?(_ bytes: [UInt8]) {
        guard bytes.count >= LegacyCommand.size else { return nil }
        self.bytes = Array(bytes.prefix(LegacyCommand.size))
    }

    public var word0: UInt16 { (UInt16(bytes[0]) << 8) | UInt16(bytes[1]) }
    public var word1: UInt16 { (UInt16(bytes[2]) << 8) | UInt16(bytes[3]) }

    /// True when the reply echoes the request opcode (the vendor's acceptance test).
    public func matches(_ request: [UInt8]) -> Bool {
        request.count >= 2 && bytes[0] == request[0] && bytes[1] == request[1]
    }

    /// The board's answer to an opcode it does not recognise, as observed on hardware: word0 `0000`,
    /// word1 `FFFF`, bytes 4…11 left as the request's bytes 4…11. inferred meaning (observed bytes confirmed).
    public var isUnknownCommand: Bool { word0 == 0x0000 && word1 == 0xFFFF }

    /// FPGA version from a `0x0110` reply: bytes [2],[3],[4],[5] = a.b.c.d (the order `GetSSVersion`
    /// prints with "FPGA:%d.%d.%d.%d"). confirmed.
    public var fpgaVersion: String { "\(bytes[2]).\(bytes[3]).\(bytes[4]).\(bytes[5])" }
}

/// Parsed old-protocol status reply (`0x0101`), from the old branch of FUN_10069580. Byte positions are
/// confirmed; meanings are inferred by matching each field to the same executor member the new-protocol
/// branch fills.
public struct LegacyStatus: Hashable, Sendable {
    public let flags: UInt8         // [2]: bit0 running, bit1 ready, bit2 reset, bit5 finished/idle, bit6, bit7
    public let word45: UInt16       // [4..5] BE (same member as new reply byte 19; meaning unknown)
    public let freeCacheBytes: Int  // [6] << 12
    public let byte7: UInt8         // [7]
    public let markCounter: UInt16  // [9..10] BE

    public init?(_ reply: LegacyReply) {
        let b = reply.bytes
        guard reply.word0 == LegacyOpcode.status.rawValue else { return nil }
        flags = b[2]
        word45 = (UInt16(b[4]) << 8) | UInt16(b[5])
        freeCacheBytes = Int(b[6]) << 12
        byte7 = b[7]
        markCounter = (UInt16(b[9]) << 8) | UInt16(b[10])
    }

    public var running: Bool { flags & 0x01 != 0 }
    public var ready: Bool { flags & 0x02 != 0 }
    public var inReset: Bool { flags & 0x04 != 0 }
    public var finished: Bool { flags & 0x20 != 0 }
}

extension MarkCompiler {
    /// Old-protocol **motion-only** preview of a job: a jump to each polyline start, then lines. No laser,
    /// red-pointer or pen parameters are emitted — their old-protocol encodings (`0x0206/0x0207/0x0208/0x0217/
    /// 0x0218` in FUN_10067b90's old branch) are not mapped yet. For `dryrun`/tests only.
    public func legacyMotionPreview(_ job: MarkJob) -> [LegacyCommand] {
        var out: [LegacyCommand] = []
        let t = GalvoTransform(machine)
        for item in job.items where item.pen.isEnabled {
            let conv = PenConversion(pen: item.pen, machine: machine)
            for pl in item.polylines {
                let pts = pl.traversal
                guard let first = pts.first else { continue }
                let g0 = t.counts(first)
                out.append(.moveToAbs(x: g0.x, y: g0.y, time: conv.jumpTime(distanceMM: 0), delay: conv.jumpDelay(distanceMM: 0)))
                var prev = first
                for p in pts.dropFirst() {
                    let g = t.counts(p)
                    out.append(.lineToAbs(x: g.x, y: g.y, time: conv.markTime(distanceMM: prev.distance(to: p)), delay: conv.laserOffDelay))
                    prev = p
                }
            }
        }
        return out
    }
}
