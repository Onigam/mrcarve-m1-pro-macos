import Foundation
import MRCarveKit

// Bring-up / diagnostics tool. `list`, `dryrun` and `info` (without --live) send nothing to the device.
// `info --live`, `frame --live` and `mark-test --live` open and drive the real machine.

func hex(_ v: UInt16) -> String { String(format: "%04X", v) }
func hexBytes(_ b: [UInt8]) -> String { b.map { String(format: "%02X", $0) }.joined(separator: " ") }

let args = Array(CommandLine.arguments.dropFirst())
func hasFlag(_ f: String) -> Bool { args.contains(f) }
func positional(_ afterIndex: Int) -> String? {
    let ps = args.dropFirst().filter { !$0.hasPrefix("-") }
    return ps.count > afterIndex ? ps[ps.index(ps.startIndex, offsetBy: afterIndex)] : nil
}

func loadMachine() -> MachineProfile {
    // Use defaults unless an LmcPar_*.cfg path is given with --cfg <path>.
    if let i = args.firstIndex(of: "--cfg"), i + 1 < args.count {
        let url = URL(fileURLWithPath: args[i + 1])
        if let p = try? VendorConfig.machineProfile(fromLmcPar: url, source: .fiber) { return p }
        FileHandle.standardError.write("warning: could not read \(url.path); using defaults\n".data(using: .utf8)!)
    }
    return MachineProfile()
}

func loadJob(_ path: String) throws -> MarkJob {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    return try JSONDecoder().decode(MarkJob.self, from: data)
}

// MARK: - list

func cmdList() throws {
    let devices = try USBDiscovery.listDevices()
    if devices.isEmpty { print("No USB devices."); return }
    for d in devices {
        let tag = d.isMRCarve ? "  <-- MR Carve (BSL board)" : d.isBareFX2 ? "  <-- bare Cypress FX2 (no firmware!)" : ""
        print("\(hex(d.vendorID)):\(hex(d.productID))  bus \(d.bus) addr \(d.address)  speed=\(d.speed)  bcdDevice=\(hex(d.bcdDevice))\(tag)")
        guard d.isMRCarve || d.isBareFX2 || hasFlag("-v") else { continue }
        for itf in d.interfaces {
            print("    interface \(itf.number) alt \(itf.alternateSetting) class 0x\(String(format: "%02X", itf.interfaceClass))")
            for ep in itf.endpoints {
                print("      EP 0x\(String(format: "%02X", ep.address)) \(ep.isIn ? "IN " : "OUT") \(ep.transferType) maxPacket=\(ep.maxPacketSize)")
            }
        }
    }
}

// MARK: - info

func cmdInfo() async throws {
    // What connect() sends, in order (command endpoint 0x06, reply on 0x88):
    if hasFlag("--framed") {
        let info = SeaCommandBuilder.getDeviceInfo()
        let state = SeaCommandBuilder.getBaseState()
        print("info sends (framed/new protocol, read-only, command endpoint 0x06):")
        print("  GetDeviceInfo 0xF0F0  frame: \(hexBytes(SeaFrame.encode(payload: info.payload(), isCommand: true, seq: 1)))")
        print("  GetDevBaseState 0xAA05 frame: \(hexBytes(SeaFrame.encode(payload: state.payload(), isCommand: true, seq: 2)))")
    } else {
        print("info sends (legacy/old protocol, raw 12-byte blocks, read-only, EP 0x06 → reply 12 B on EP 0x88):")
        print("  GetSSVersion 0x0110  block: \(hexBytes(LegacyCommand.version().bytes))")
        print("  Status poll  0x0101  block: \(hexBytes(LegacyCommand.status().bytes))")
    }
    guard hasFlag("--live") else {
        print("\n(not opening the device; pass --live to actually query it)")
        return
    }
    let controller = makeLiveController(loadMachine())
    let dev = try await controller.connect()
    await controller.disconnect()
    print("\nFPGA version: \(dev.fpgaVersion)   speed: \(dev.usbSpeed ?? "?")")
}

/// Wraps a transport and prints every bulk transfer in hex (enabled with `--trace`).
final class TracingTransport: Transport, @unchecked Sendable {
    private let inner: Transport
    init(_ inner: Transport) { self.inner = inner }

    func bulkWrite(endpoint: UInt8, _ bytes: [UInt8]) throws {
        print(String(format: ">> EP 0x%02X (%3d B) ", endpoint, bytes.count) + hexBytes(bytes))
        try inner.bulkWrite(endpoint: endpoint, bytes)
    }

    func bulkRead(endpoint: UInt8, maxLength: Int) throws -> [UInt8] {
        do {
            let r = try inner.bulkRead(endpoint: endpoint, maxLength: maxLength)
            print(String(format: "<< EP 0x%02X (%3d B) ", endpoint, r.count) + hexBytes(r))
            return r
        } catch {
            print(String(format: "<< EP 0x%02X  error: ", endpoint) + error.localizedDescription)
            throw error
        }
    }

    func close() { inner.close() }
}

func makeLiveController(_ machine: MachineProfile) -> USBLaserController {
    // Legacy (old 12-byte) protocol by default — the owner's unit rejects FE FF frames. --framed opts in.
    let variant: SeaProtocolVariant = hasFlag("--framed") ? .framed : .legacy
    guard hasFlag("--trace") else { return USBLaserController(machine: machine, variant: variant) }
    return USBLaserController(machine: machine, variant: variant, transport: { TracingTransport(try LibUSBTransport()) })
}

// MARK: - dryrun

func cmdDryrun(_ path: String) throws {
    let job = try loadJob(path)
    let machine = loadMachine()
    let compiler = MarkCompiler(machine: machine)
    print("# dryrun \(path) — field \(Int(machine.lens.workSize)) mm, \(job.items.count) item(s)")
    print("# fits field: \(compiler.fitsField(job))   bounds: \(job.bounds.map { "\($0.width)×\($0.height) mm" } ?? "empty")")
    let commands = compiler.compileMark(job)
    print("\n## mark stream (laser ON): \(commands.count) commands")
    for c in commands {
        print(String(format: "  %@ op=%04X  %@", c.channel == .data ? "DATA" : "CMD ", c.command.opcode.rawValue, c.note))
    }
    // Show how the controller batches these onto the data endpoint.
    let batches = USBLaserController.batch(commands.map(\.command))
    print("\n## batched into \(batches.count) data frame(s) (≤0x200 payload each):")
    for (i, b) in batches.enumerated() {
        print("  frame[\(i)] payload \(b.count) bytes")
    }
    // And the first few framed bytes, captured through a RecordingTransport, to show the real wire form.
    let rec = RecordingTransport()
    let link = SeaLink(rec)
    if let first = batches.first { _ = try? link.send(payload: first, channel: .data) }
    if let wire = rec.sentFrames.first {
        print("\n## first data frame on the wire (\(wire.count) bytes):\n  \(hexBytes(Array(wire.prefix(48))))\(wire.count > 48 ? " …" : "")")
    }
}

// MARK: - frame / mark-test

func safetyWarning(_ what: String) {
    FileHandle.standardError.write("""
    ====================================================================
     SAFETY: '\(what)' drives the real laser galvos.
     - Make sure the work area is clear and you are wearing eye protection.
     - framing uses the RED POINTER only; mark-test FIRES THE LASER.
     - Keep a hand on the power switch. Ctrl-C stops the host; it does not
       guarantee the board stops instantly.
    ====================================================================

    """.data(using: .utf8)!)
}

func demoJob(_ machine: MachineProfile) -> MarkJob {
    // A small centred 10×10 mm square.
    var pen = PenParameters(id: 0)
    pen.power = 10; pen.markSpeed = 500; pen.frequency = 30
    let sq = Rect2(minX: -5, minY: -5, maxX: 5, maxY: 5).outline
    return MarkJob(items: [MarkItem(pen: pen, polylines: [sq])])
}

func cmdFrame(_ path: String?) async throws {
    let machine = loadMachine()
    let job = try path.map(loadJob) ?? demoJob(machine)
    let outlineOnly = !hasFlag("--full")
    let compiler = MarkCompiler(machine: machine)
    print("frame: tracing \(outlineOnly ? "bounding box" : "all geometry") with the red pointer; fits field: \(compiler.fitsField(job))")
    guard hasFlag("--live") else {
        let cmds = compiler.compileFrame(job, outlineOnly: outlineOnly)
        print("(dry) \(cmds.count) red-pointer commands; pass --live to run. First few:")
        for c in cmds.prefix(6) { print("  op=\(hex(c.command.opcode.rawValue))  \(c.note)") }
        return
    }
    safetyWarning("frame")
    let controller = makeLiveController(machine)
    _ = try await controller.connect()
    print("Framing. Press Ctrl-C to stop.")
    try await controller.startFraming(job, outlineOnly: outlineOnly)
}

func cmdMarkTest(_ path: String?) async throws {
    let machine = loadMachine()
    let job = try path.map(loadJob) ?? demoJob(machine)
    guard hasFlag("--live") else {
        let compiler = MarkCompiler(machine: machine)
        let cmds = compiler.compileMark(job)
        print("(dry) mark-test would send \(cmds.count) commands (laser ON). Pass --live to run.")
        return
    }
    safetyWarning("mark-test")
    let controller = makeLiveController(machine)
    _ = try await controller.connect()
    try await controller.mark(job) { p in
        FileHandle.standardError.write("progress \(Int(p * 100))%\r".data(using: .utf8)!)
    }
    await controller.disconnect()
    print("\nmark-test complete.")
}

// MARK: - dispatch

func usage() {
    print("""
    mrcarve-cli — MR Carve M1 Pro diagnostics
      list [-v]                 List USB devices (descriptors only, nothing is sent)
      info [--live] [--trace] [--framed]   Show what identification sends; --live queries the device read-only (legacy protocol unless --framed)
      dryrun <job.json> [--cfg F]   Compile a job and print the annotated command stream (no device)
      frame [job.json] --live [--full] [--cfg F]   Red-pointer framing (SAFE: no laser). Omit --live to dry-run
      mark-test [job.json] --live [--cfg F]         Mark a small test (LASER FIRES). Omit --live to dry-run
    A job.json is a JSON-encoded MarkJob (see docs/PROTOCOL.md). --cfg loads an LmcPar_*.cfg profile.
    """)
}

let sema = DispatchSemaphore(value: 0)
Task {
    do {
        switch args.first ?? "help" {
        case "list": try cmdList()
        case "info": try await cmdInfo()
        case "dryrun":
            guard let p = positional(0) else { print("usage: dryrun <job.json>"); break }
            try cmdDryrun(p)
        case "frame": try await cmdFrame(positional(0))
        case "mark-test": try await cmdMarkTest(positional(0))
        default: usage()
        }
    } catch {
        FileHandle.standardError.write("error: \(error.localizedDescription)\n".data(using: .utf8)!)
        sema.signal()
        exit(1)
    }
    sema.signal()
}
sema.wait()
