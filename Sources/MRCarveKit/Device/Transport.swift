import Foundation

/// USB bulk endpoints used by the BSL board. confirmed from `LibUsbControl` (@0x1688d8..):
/// command OUT 0x06, data OUT 0x02, command IN 0x88, data IN 0x84.
public enum SeaEndpoint {
    public static let commandOut: UInt8 = 0x06
    public static let dataOut: UInt8 = 0x02
    public static let commandIn: UInt8 = 0x88
    public static let dataIn: UInt8 = 0x84
    /// Reply read length used by `LibUsbControl::ReadPort`. confirmed (0x50).
    public static let readLength = 0x50
    /// Bulk transfer timeout in ms. confirmed (100).
    public static let timeoutMs: UInt32 = 100
}

/// Raw bulk transport (one implementation talks to libusb, one records for tests). This is the
/// `LibUsbControl` layer: it moves bytes on an endpoint and knows nothing about framing.
public protocol Transport: AnyObject, Sendable {
    func bulkWrite(endpoint: UInt8, _ bytes: [UInt8]) throws
    func bulkRead(endpoint: UInt8, maxLength: Int) throws -> [UInt8]
    func close()
}

/// The framing + retry layer (`TransferCtrl::SendCmd`/`SendData`). Applies the FE FF frame, a per-channel
/// 4-bit sequence number, reads the reply, verifies its checksum and net-error bits, and retries.
public final class SeaLink: @unchecked Sendable {
    private let transport: Transport
    private let lock = NSLock()
    private var cmdSeq: UInt8 = 0
    private var dataSeq: UInt8 = 0
    /// Retry counts match the vendor: 2 for commands, 8 for data. confirmed.
    public var commandRetries = 2
    public var dataRetries = 8

    public init(_ transport: Transport) { self.transport = transport }

    public func close() { transport.close() }

    /// Sends a command on its channel and returns the validated reply payload (header/trailer stripped).
    @discardableResult
    public func send(_ cmd: SeaCommand, channel: SeaChannel) throws -> [UInt8] {
        try send(payload: cmd.payload(), channel: channel)
    }

    /// Sends a pre-built payload (e.g. a batched command list) on a channel.
    @discardableResult
    public func send(payload: [UInt8], channel: SeaChannel) throws -> [UInt8] {
        lock.lock(); defer { lock.unlock() }
        let (outEP, inEP, retries) = channel == .command
            ? (SeaEndpoint.commandOut, SeaEndpoint.commandIn, commandRetries)
            : (SeaEndpoint.dataOut, SeaEndpoint.dataIn, dataRetries)
        var lastError = "no reply"
        for attempt in 0...retries {
            let seq = nextSeq(channel)
            let frame = SeaFrame.encode(payload: payload, isCommand: channel == .command, seq: seq)
            try transport.bulkWrite(endpoint: outEP, frame)
            let raw = try transport.bulkRead(endpoint: inEP, maxLength: SeaEndpoint.readLength)
            if let reply = SeaFrame.decode(raw) {
                if reply.flags & 0x0E00 != 0 { lastError = "board net error \((reply.flags >> 9) & 7)"; continue }
                if !checksumOK(raw) { lastError = "checksum error"; continue }
                return reply.payload
            }
            lastError = "malformed reply (attempt \(attempt))"
        }
        throw LaserControllerError.protocolError(lastError)
    }

    private func nextSeq(_ channel: SeaChannel) -> UInt8 {
        if channel == .command { cmdSeq = (cmdSeq + 1) & 0x0F; return cmdSeq }
        dataSeq = (dataSeq + 1) & 0x0F; return dataSeq
    }

    private func checksumOK(_ frame: [UInt8]) -> Bool {
        guard frame.count >= 10 else { return false }
        let total = (Int(frame[2]) << 8) | Int(frame[3])
        guard total <= frame.count, total >= 10 else { return false }
        // payload at [6 ..< total-2]; checksum byte at total-1; vendor sums payload[0,1,last,last-1].
        let p = Array(frame[6..<(total - 2)])
        guard p.count >= 2 else { return false }
        let cs = (Int(p[0]) &+ Int(p[1]) &+ Int(p[p.count - 1]) &+ Int(p[p.count - 2])) & 0xFF
        return UInt8(cs) == frame[total - 1]
    }
}

/// In-memory transport for tests: records everything written and serves scripted replies, so connect /
/// frame / mark can be exercised without hardware.
public final class RecordingTransport: Transport, @unchecked Sendable {
    public struct Write: Sendable { public let endpoint: UInt8; public let bytes: [UInt8] }

    private let lock = NSLock()
    private var _writes: [Write] = []
    private let responder: @Sendable (UInt8, [UInt8]) -> [UInt8]
    public private(set) var closed = false

    /// `responder` receives the OUT endpoint and the frame just written, and returns the reply frame to
    /// hand back on the next read. The default responder echoes a minimal valid reply for any request.
    public init(responder: (@Sendable (UInt8, [UInt8]) -> [UInt8])? = nil) {
        self.responder = responder ?? RecordingTransport.defaultResponder
    }

    public var writes: [Write] { lock.withLock { _writes } }
    /// All OUT frames that were sent, in order.
    public var sentFrames: [[UInt8]] { lock.withLock { _writes.map(\.bytes) } }

    private var pendingReply: [UInt8] = []

    public func bulkWrite(endpoint: UInt8, _ bytes: [UInt8]) throws {
        lock.withLock {
            _writes.append(Write(endpoint: endpoint, bytes: bytes))
            pendingReply = responder(endpoint, bytes)
        }
    }

    public func bulkRead(endpoint: UInt8, maxLength: Int) throws -> [UInt8] {
        lock.withLock { Array(pendingReply.prefix(maxLength)) }
    }

    public func close() { lock.withLock { closed = true } }

    /// Builds a valid reply frame for a request frame: echoes the opcode and appends `data`.
    public static func reply(toRequest requestFrame: [UInt8], data: [UInt8] = []) -> [UInt8] {
        // Request payload opcode is at frame[6..7]; echo it so the link's validation passes.
        let op: [UInt8] = requestFrame.count >= 8 ? [requestFrame[6], requestFrame[7]] : [0, 0]
        var payload = op + [0, 0] + data
        if payload.count < 12 { payload += Array(repeating: 0, count: 12 - payload.count) }
        if payload.count % 2 != 0 { payload.append(0) }
        return SeaFrame.encode(payload: payload, isCommand: true, seq: 0)
    }

    private static let defaultResponder: @Sendable (UInt8, [UInt8]) -> [UInt8] = { _, frame in
        guard frame.count >= 8 else { return [] }
        let op = (UInt16(frame[6]) << 8) | UInt16(frame[7])
        switch op {
        case SeaOpcode.getDeviceInfo.rawValue:
            // 52-byte payload; bytes [42..45] = FPGA version 1.6.0.8 (payload offset counts from op).
            var data = Array<UInt8>(repeating: 0, count: 50)
            data[38] = 1; data[39] = 6; data[40] = 0; data[41] = 8   // payload[42..45] after 4-byte prefix
            return reply(toRequest: frame, data: data)
        case SeaOpcode.getBaseState.rawValue:
            // reply payload = op(2) + 2 + data; the state base begins at payload[4] = data[0].
            // base[0]=ready, base[4..5]=laserState 0, base[8]=idle, base[9..11]=free cache 0xFFF KiB.
            var data = Array<UInt8>(repeating: 0, count: 24)
            data[0] = BoardStatus.ready.rawValue            // base[0] board status
            data[8] = 1                                     // base[8] idle bit
            data[9] = 0x0F; data[10] = 0xFF; data[11] = 0xFF  // base[9..11] free cache KiB
            return reply(toRequest: frame, data: data)
        default:
            return reply(toRequest: frame)
        }
    }
}

// MARK: - Legacy (old-protocol) link

/// Old-protocol link: raw 12-byte blocks, no framing. Commands go out on EP 0x06 and the 12-byte reply is
/// read on EP 0x88. A reply is accepted only if it echoes the request opcode; otherwise read again (vendor
/// `FUN_100649c0`: up to 3 reads; `GetSSVersion` FUN_10063f60: "ReadPort again"). 5 ms between write and
/// read, 10 ms between write attempts (FUN_10063f60 `Sleep(5)` / `Sleep(10)`). confirmed.
public final class LegacyLink: @unchecked Sendable {
    private let transport: Transport
    private let lock = NSLock()
    public var writeAttempts = 3
    public var readsPerAttempt = 3

    public init(_ transport: Transport) { self.transport = transport }
    public func close() { transport.close() }

    /// Sends one command block on the command endpoint and returns the matching 12-byte reply.
    public func query(_ cmd: LegacyCommand) throws -> LegacyReply {
        lock.lock(); defer { lock.unlock() }
        let req = cmd.bytes
        let op = String(format: "0x%04X", cmd.opcode.rawValue)
        for attempt in 0..<writeAttempts {
            if attempt > 0 { Thread.sleep(forTimeInterval: 0.010) }
            try transport.bulkWrite(endpoint: SeaEndpoint.commandOut, req)
            Thread.sleep(forTimeInterval: 0.005)
            for _ in 0..<readsPerAttempt {
                guard let raw = try? transport.bulkRead(endpoint: SeaEndpoint.commandIn, maxLength: LegacyCommand.size),
                      let reply = LegacyReply(raw) else { break }   // timeout / short read → write again
                if reply.matches(req) { return reply }
                if reply.isUnknownCommand {
                    throw LaserControllerError.protocolError("board answered \(op) with 00 00 FF FF (unknown command)")
                }
            }
        }
        throw LaserControllerError.protocolError("no matching reply to \(op) after \(writeAttempts) attempts")
    }

    /// Sends a list of blocks on the data endpoint 0x02 (old `ExeCurCmd` FUN_100690c0: N×12 raw bytes via
    /// WriteData) and reads the 12-byte ack on 0x84. Not used by the controller yet (old-protocol laser
    /// parameters are unmapped), kept for bring-up of motion-only tests.
    @discardableResult
    public func sendData(_ blocks: [LegacyCommand]) throws -> LegacyReply? {
        lock.lock(); defer { lock.unlock() }
        let bytes = blocks.flatMap(\.bytes)
        guard bytes.count >= LegacyCommand.size else { return nil }   // WriteData refuses < 12 bytes
        try transport.bulkWrite(endpoint: SeaEndpoint.dataOut, bytes)
        return (try? transport.bulkRead(endpoint: SeaEndpoint.dataIn, maxLength: LegacyCommand.size)).flatMap(LegacyReply.init)
    }
}

extension RecordingTransport {
    /// Emulates the owner's unit as observed on hardware (2026-10-20 trace): legacy 12-byte blocks get an
    /// opcode-echo reply; any `FE FF`-framed request gets `00 00 FF FF` + request bytes 4…11.
    public static func legacyUnit(version: [UInt8] = [1, 6, 0, 8]) -> RecordingTransport {
        RecordingTransport { _, frame in
            if frame.count >= 2, frame[0] == 0xFE, frame[1] == 0xFF {
                return [0x00, 0x00, 0xFF, 0xFF] + Array(frame[4..<min(12, frame.count)])
                    + Array(repeating: 0, count: max(0, 12 - min(12, frame.count)))
            }
            guard frame.count >= LegacyCommand.size else { return [] }
            let op = (UInt16(frame[0]) << 8) | UInt16(frame[1])
            switch op {
            case LegacyOpcode.version.rawValue:
                return [frame[0], frame[1]] + version + [0, 0, 0, 0, 0, 0]
            case LegacyOpcode.status.rawValue:
                // flags = ready (bit1), free cache byte 0xFF (<<12), counter 0
                return [frame[0], frame[1], 0x02, 0x00, 0x00, 0x00, 0xFF, 0x00, 0x00, 0x00, 0x00, 0x00]
            default:
                if LegacyOpcode(rawValue: op) != nil { return [frame[0], frame[1]] + Array(repeating: 0, count: 10) }
                return [0x00, 0x00, 0xFF, 0xFF] + Array(frame[4..<12])
            }
        }
    }
}
