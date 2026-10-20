import Foundation
import MRCarveKit

/// Old (legacy) protocol: raw 12-byte blocks. Golden bytes from the old branches of SeaMark.dll, plus the
/// hardware reply captured by the lead on 2026-10-20 (`mrcarve-cli info --live --trace`).
enum ProtocolLegacyTests {
    /// Exact bytes observed on the owner's unit in reply to our framed F0F0 request (seq 0x81).
    static let observedRequest: [UInt8] = [0xFE, 0xFF, 0x00, 0x14, 0x81, 0x00, 0xF0, 0xF0, 0, 0, 0, 0,
                                           0, 0, 0, 0, 0, 0, 0x00, 0xE0]
    static let observedReply: [UInt8] = [0x00, 0x00, 0xFF, 0xFF, 0x81, 0x00, 0xF0, 0xF0, 0x00, 0x00, 0x00, 0x00]

    static func register() {
        test("legacy: read-only query blocks golden bytes") {
            expectEqual(LegacyCommand.version().bytes, [0x01, 0x10, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
            expectEqual(LegacyCommand.status().bytes, [0x01, 0x01, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
            expectEqual(LegacyCommand.boardMode().bytes, [0x01, 0x40, 0, 0, 0, 0, 0, 0, 0, 0, 0x00, 0x01])
            for c in [LegacyCommand.version(), .status(), .boardMode(), .setReady(), .setRun()] {
                expectEqual(c.bytes.count, 12)
            }
        }

        test("legacy: motion block layout (time, X, Y, 0, delay; 16-bit BE)") {
            let m = LegacyCommand.moveToAbs(x: 0x8000, y: 0x1234, time: 0x0102, delay: 0x0304)
            expectEqual(m.bytes, [0x02, 0x41, 0x01, 0x02, 0x80, 0x00, 0x12, 0x34, 0x00, 0x00, 0x03, 0x04])
            let l = LegacyCommand.lineToAbs(x: 1, y: 2, time: 3, delay: 4)
            expectEqual([l.bytes[0], l.bytes[1]], [0x02, 0x43])   // old LineToAbs = 0x0243 (new 0x0245)
        }

        test("legacy: decode the exact hardware reply to a framed request") {
            let r = LegacyReply(observedReply)
            expect(r != nil, "12-byte reply must parse")
            expect(r!.isUnknownCommand, "00 00 FF FF must read as unknown command")
            expect(!r!.matches(observedRequest), "must not be accepted as an echo of FE FF")
            // bytes 4..11 are the request's bytes 4..11, untouched
            expectEqual(Array(r!.bytes[4..<12]), Array(observedRequest[4..<12]))
        }

        test("legacy: version and status replies parse") {
            let v = LegacyReply([0x01, 0x10, 1, 6, 0, 8, 0, 0, 0, 0, 0, 0])!
            expect(v.matches(LegacyCommand.version().bytes), "echo")
            expectEqual(v.fpgaVersion, "1.6.0.8")
            let s = LegacyStatus(LegacyReply([0x01, 0x01, 0x22, 0, 0x12, 0x34, 0x02, 7, 0, 0x00, 0x05, 0])!)
            expect(s != nil, "status parse")
            expect(s!.ready && s!.finished && !s!.running, "flag bits")
            expectEqual(Int(s!.word45), 0x1234)
            expectEqual(s!.freeCacheBytes, 2 << 12)
            expectEqual(Int(s!.markCounter), 5)
        }

        test("legacy: emulator reproduces the hardware trace for framed requests") {
            let rec = RecordingTransport.legacyUnit()
            let controller = USBLaserController(machine: MachineProfile(), variant: .framed, transport: { rec })
            let ok = runAsync { try await controller.connect() } != nil
            expect(!ok, "framed connect must fail against this unit")
            expectEqual(rec.writes.first?.bytes ?? [], observedRequest)
        }

        test("legacy: connect is read-only and reads version 1.6.0.8") {
            let rec = RecordingTransport.legacyUnit()
            let controller = USBLaserController(machine: MachineProfile(), transport: { rec })   // default = legacy
            let info = runAsync { try await controller.connect() }
            expectEqual(info?.fpgaVersion, "1.6.0.8")
            expectEqual(rec.writes.map(\.endpoint), [0x06, 0x06])
            expectEqual(rec.writes.map(\.bytes), [LegacyCommand.version().bytes, LegacyCommand.status().bytes])
            expectEqual(info?.details["protocol"], "legacy")
        }

        test("legacy: mark and framing are refused before anything is sent") {
            let rec = RecordingTransport.legacyUnit()
            let controller = USBLaserController(machine: MachineProfile(), transport: { rec })
            _ = runAsync { try await controller.connect() }
            let before = rec.writes.count
            let job = MarkJob(items: [MarkItem(pen: PenParameters(id: 0),
                                               polylines: [Rect2(minX: -5, minY: -5, maxX: 5, maxY: 5).outline])])
            expect(runAsync { try await controller.mark(job) { _ in } } == nil, "mark must throw in legacy mode")
            expect(runAsync { try await controller.startFraming(job, outlineOnly: true) } == nil, "framing must throw")
            expectEqual(rec.writes.count, before)
        }
    }

    private static func runAsync<T>(_ body: @escaping () async throws -> T) -> T? {
        let group = DispatchGroup(); group.enter()
        var result: T?
        Task { result = try? await body(); group.leave() }
        _ = group.wait(timeout: .now() + 5)
        return result
    }
}
