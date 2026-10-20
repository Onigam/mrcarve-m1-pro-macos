import Foundation

/// Real hardware controller for the MR Carve M1 Pro (BSL board, Cypress FX2LP 04B4:1004).
///
/// Implemented from `docs/PROTOCOL.md`. Talks to a `Transport` through the `SeaLink` framing layer, so it
/// can be exercised against a `RecordingTransport` with no hardware. The marking laser is enabled only in
/// `mark(_:progress:)`; `startFraming` uses the red pointer with the master oscillator gated off; `stop`
/// is fast and always leaves the laser off.
///
/// IMPORTANT (open question for bring-up): the board may require a mode / bind handshake before it accepts
/// data commands — the vendor logs "board still in factory mode uMode=0" and runs a `GetBoardMode`/`bind`
/// exchange during init. This controller does NOT perform that handshake; `connect()` only reads version
/// and status. See the final report / PROTOCOL.md "Open questions".
public final class USBLaserController: LaserController, @unchecked Sendable {
    public var machine: MachineProfile {
        get { lock.withLock { _machine } }
        set { lock.withLock { _machine = newValue } }
    }

    private let lock = NSLock()
    private var _machine: MachineProfile
    private var link: SeaLink?
    private var legacy: LegacyLink?
    private var cancelled = false
    private let makeTransport: @Sendable () throws -> Transport

    /// Wire protocol. Defaults to `.legacy`: the owner's unit rejects `FE FF` frames (hardware trace in
    /// PROTOCOL.md §1a). `.framed` keeps the new-protocol path available for newer boards.
    public let variant: SeaProtocolVariant

    /// Production initializer: opens the libusb device lazily on `connect()`.
    public init(machine: MachineProfile, variant: SeaProtocolVariant = .legacy) {
        self._machine = machine
        self.variant = variant
        self.makeTransport = { try LibUSBTransport() }
    }

    /// Test / injection initializer: supply a transport factory (e.g. returning a `RecordingTransport`).
    public init(machine: MachineProfile, variant: SeaProtocolVariant = .legacy,
                transport: @escaping @Sendable () throws -> Transport) {
        self._machine = machine
        self.variant = variant
        self.makeTransport = transport
    }

    // MARK: Connect

    public func connect() async throws -> DeviceInfo {
        let transport = try makeTransport()
        switch variant {
        case .legacy:
            // Read-only: GetSSVersion (0x0110) then status poll (0x0101), raw 12-byte blocks on EP 0x06/0x88.
            let legacy = LegacyLink(transport)
            lock.withLock { self.legacy = legacy; self.link = nil; self.cancelled = false }
            let version = try legacy.query(.version())
            let statusReply = try legacy.query(.status())
            var details = ["protocol": "legacy", "note": "connect() is read-only; board mode handshake not performed"]
            if let s = LegacyStatus(statusReply) {
                details["statusFlags"] = String(format: "0x%02X", s.flags)
                details["freeCacheBytes"] = String(s.freeCacheBytes)
                details["markCounter"] = String(s.markCounter)
            }
            return DeviceInfo(fpgaVersion: version.fpgaVersion, serial: nil, usbSpeed: "high", details: details)
        case .framed:
            let link = SeaLink(transport)
            lock.withLock { self.link = link; self.legacy = nil; self.cancelled = false }
            // Passive identification only — no state changes on the board. (command channel)
            let infoReply = try link.send(SeaCommandBuilder.getDeviceInfo(), channel: .command)
            let version = Self.fpgaVersion(infoReply)
            _ = try link.send(SeaCommandBuilder.getBaseState(), channel: .command)
            return DeviceInfo(fpgaVersion: version, serial: nil, usbSpeed: "high",
                              details: ["protocol": "framed",
                                        "note": "connect() is read-only; board mode/bind handshake not performed"])
        }
    }

    public func disconnect() async {
        let (l, g) = lock.withLock { () -> (SeaLink?, LegacyLink?) in
            let x = (link, legacy); link = nil; legacy = nil; return x
        }
        l?.close(); g?.close()
    }

    /// Legacy mode refuses laser/red-pointer work until the old-protocol parameter encodings are mapped.
    private func refuseIfLegacy(_ what: String) throws {
        if variant == .legacy {
            throw LaserControllerError.protocolError(
                "\(what) is disabled in legacy-protocol mode: old-protocol red-pointer/laser parameter encodings are not mapped yet")
        }
    }

    // MARK: Framing (red pointer, laser off)

    public func startFraming(_ job: MarkJob, outlineOnly: Bool) async throws {
        try refuseIfLegacy("Framing")
        let (link, machine) = try ready()
        let compiler = MarkCompiler(machine: machine)
        guard compiler.fitsField(job), let bounds = job.bounds else {
            throw LaserControllerError.outOfField(job.bounds ?? Rect2(minX: 0, minY: 0, maxX: 0, maxY: 0))
        }
        _ = bounds
        lock.withLock { cancelled = false }
        let frame = compiler.compileFrame(job, outlineOnly: outlineOnly)
        do {
            while !lock.withLock({ cancelled }) {
                try sendBatched(frame, link: link)
                try await Task.sleep(nanoseconds: 20_000_000)
            }
        } catch {
            try? stopNow(link)
            throw error
        }
        _ = try? sendBatched(compiler.framingOff(), link: link)
    }

    // MARK: Marking (laser on)

    public func mark(_ job: MarkJob, progress: @escaping @Sendable (Double) -> Void) async throws {
        try refuseIfLegacy("Marking")
        let (link, machine) = try ready()
        let compiler = MarkCompiler(machine: machine)
        guard compiler.fitsField(job) else {
            throw LaserControllerError.outOfField(job.bounds ?? Rect2(minX: 0, minY: 0, maxX: 0, maxY: 0))
        }
        lock.withLock { cancelled = false }
        let commands = compiler.compileMark(job)
        do {
            // Prepare the board: online, clear cache, ready.
            try link.send(SeaCommandBuilder.online(true), channel: .command)
            try link.send(SeaCommandBuilder.clearCache(), channel: .command)
            try link.send(SeaCommandBuilder.setBoardStatus(BoardStatus.ready.rawValue), channel: .command)

            // Stream the geometry in ≤0x200-byte batches with free-cache flow control.
            let batches = Self.batch(commands.map(\.command))
            try link.send(SeaCommandBuilder.setBoardStatus(BoardStatus.runReady.rawValue), channel: .command)
            for (i, payload) in batches.enumerated() {
                if lock.withLock({ cancelled }) { throw LaserControllerError.cancelled }
                try waitForEnoughCache(link: link, need: payload.count)
                try link.send(payload: payload, channel: .data)
                progress(Double(i + 1) / Double(batches.count + 1))
            }
            try link.send(SeaCommandBuilder.setBoardStatus(BoardStatus.run.rawValue), channel: .command)
            try waitForFinish(link: link)
            // Marking done: drop back to ready and make sure the laser gate is closed.
            _ = try? link.send(SeaCommandBuilder.setBoardStatus(BoardStatus.ready.rawValue), channel: .command)
            progress(1.0)
        } catch {
            try? stopNow(link)   // leave the laser off on any error
            throw error
        }
    }

    // MARK: Stop

    public func stop() async {
        // Legacy mode never starts framing/marking, so there is nothing to undo: only set the flag.
        let l = lock.withLock { () -> SeaLink? in cancelled = true; return link }
        guard let l else { return }
        try? stopNow(l)
    }

    /// Best-effort, fast stop: gate MO off, red pointer off, board back to reset. Leaves the laser off.
    private func stopNow(_ link: SeaLink) throws {
        _ = try? link.send(SeaCommandBuilder.masterOscillator(false), channel: .data)
        _ = try? link.send(SeaCommandBuilder.redPointer(false), channel: .data)
        _ = try? link.send(SeaCommandBuilder.setBoardStatus(BoardStatus.reset.rawValue), channel: .command)
    }

    // MARK: Helpers

    private func ready() throws -> (SeaLink, MachineProfile) {
        try lock.withLock {
            guard let link else { throw LaserControllerError.notConnected }
            return (link, _machine)
        }
    }

    /// Concatenates command payloads into ≤0x200-byte batches (CSeaCmdList, USB comm limit). confirmed.
    public static func batch(_ commands: [SeaCommand], limit: Int = 0x200) -> [[UInt8]] {
        var batches: [[UInt8]] = []
        var current: [UInt8] = []
        for cmd in commands {
            let p = cmd.payload()
            if !current.isEmpty && current.count + p.count > limit {
                batches.append(current); current = []
            }
            current += p
        }
        if !current.isEmpty { batches.append(current) }
        return batches
    }

    private func sendBatched(_ commands: [CompiledCommand], link: SeaLink) throws {
        for payload in Self.batch(commands.map(\.command)) {
            if lock.withLock({ cancelled }) { throw LaserControllerError.cancelled }
            try link.send(payload: payload, channel: .data)
        }
    }

    /// Polls `GetDevBaseState` until the board reports enough free cache for the next batch (or gives up).
    /// Mirrors `WaitForEnoughCache` (@0x12e400). inferred thresholds.
    private func waitForEnoughCache(link: SeaLink, need: Int) throws {
        for _ in 0..<400 {
            if lock.withLock({ cancelled }) { throw LaserControllerError.cancelled }
            let reply = try link.send(SeaCommandBuilder.getBaseState(), channel: .command)
            if let s = DeviceBaseState(payload: reply), s.freeCacheBytes >= need + 10_000 { return }
            Thread.sleep(forTimeInterval: 0.025)
        }
    }

    /// Polls until the board reports idle (cache drained). Mirrors `WaitForFinish` (@0x12e6c0).
    private func waitForFinish(link: SeaLink) throws {
        for _ in 0..<100_000 {
            if lock.withLock({ cancelled }) { throw LaserControllerError.cancelled }
            let reply = try link.send(SeaCommandBuilder.getBaseState(), channel: .command)
            if let s = DeviceBaseState(payload: reply), s.idle || s.boardStatus < 2 { return }
            Thread.sleep(forTimeInterval: 0.02)
        }
    }

    /// FPGA version from a `GetDeviceInfo` reply: payload bytes [42..45] = a.b.c.d. confirmed location
    /// (Windows `GetSSVersion` reads these four bytes; e.g. "1.6.0.8").
    static func fpgaVersion(_ payload: [UInt8]) -> String {
        guard payload.count >= 46 else { return "unknown" }
        return "\(payload[42]).\(payload[43]).\(payload[44]).\(payload[45])"
    }
}
