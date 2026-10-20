import Foundation
import MRCarveKit

enum ProtocolTests {
    static func register() {
        // MARK: Framing & checksum (golden bytes derived from tagSeaCMD::getData / PackageData)

        test("frame: GetDeviceInfo golden bytes") {
            let payload = SeaCommandBuilder.getDeviceInfo().payload()
            // op F0F0, no length byte, padded to 12 zero bytes.
            expectEqual(payload, [0xF0, 0xF0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
            let frame = SeaFrame.encode(payload: payload, isCommand: true, seq: 1)
            // FE FF | len=0x0014 | flags=0x81 | 00 | payload | 00 | checksum(F0+F0+00+00=0xE0)
            expectEqual(frame, [0xFE, 0xFF, 0x00, 0x14, 0x81, 0x00,
                                0xF0, 0xF0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                                0x00, 0xE0])
        }

        test("frame: data channel flags carry seq without 0x80") {
            let f = SeaFrame.encode(payload: [0x02, 0x12, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0], isCommand: false, seq: 3)
            expectEqual(f[4], 0x03)       // data flag = seq, no 0x80
            expectEqual(Int(f[2]) << 8 | Int(f[3]), f.count)   // length field == frame length
        }

        test("frame: decode round-trips payload and validates length") {
            let payload: [UInt8] = [0xAA, 0x05, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8]
            let frame = SeaFrame.encode(payload: payload, isCommand: true, seq: 0)
            let decoded = SeaFrame.decode(frame)
            expect(decoded != nil, "decode failed")
            expectEqual(decoded?.payload ?? [], payload)
        }

        test("command: payload padded to >=12 and even, length byte set") {
            let c = SeaCommand(.setDelayTime, hasLength: true, params: SeaEncode.u32(1234))
            let p = c.payload()
            expect(p.count >= 12, "too short")
            expect(p.count % 2 == 0, "odd length")
            expectEqual(p[2], UInt8(p.count))   // length byte
            expectEqual([p[0], p[1]], [0x0A, 0x00])  // op 0x0A00 big-endian
        }

        // MARK: Parameter byte order (big-endian scalars, 24-bit coords)

        test("encode: scalars big-endian, coords 24-bit big-endian") {
            expectEqual(SeaEncode.u16(0x1234), [0x12, 0x34])
            expectEqual(SeaEncode.u32(0x01020304), [0x01, 0x02, 0x03, 0x04])
            expectEqual(SeaEncode.coord(0xBEEF), [0x00, 0xBE, 0xEF])
            expectEqual(SeaEncode.coord(70000), [0x00, 0xFF, 0xFF])   // clamped to 0xFFFF
        }

        test("moveToAbs: time, delay, X, Y layout") {
            let c = SeaCommandBuilder.moveToAbs(x: 0x8000, y: 0x4000, time: 0x0102, delay: 0x0304)
            let p = c.payload()
            // payload: op(2) len(1) 00(1) time(2 BE) delay(2 BE) X(3 BE) Y(3 BE) reserved(3)
            expectEqual([p[0], p[1]], [0x02, 0x41])
            expectEqual([p[4], p[5]], [0x01, 0x02])          // time BE
            expectEqual([p[6], p[7]], [0x03, 0x04])          // delay BE
            expectEqual([p[8], p[9], p[10]], [0x00, 0x80, 0x00])  // X = 0x8000
            expectEqual([p[11], p[12], p[13]], [0x00, 0x40, 0x00]) // Y = 0x4000
        }

        // MARK: Galvo transform

        test("galvo: field centre maps to 0x8000/0x8000") {
            let t = GalvoTransform(MachineProfile())
            let c = t.counts(.zero)
            expectEqual(c.x, 32768)
            expectEqual(c.y, 32768)
        }

        test("galvo: symmetric about centre and clamps") {
            let t = GalvoTransform(MachineProfile())
            let pos = t.counts(Vec2(5, 0)), neg = t.counts(Vec2(-5, 0))
            expect(pos.x > 32768 && neg.x < 32768, "not symmetric")
            expect(abs((pos.x - 32768) - (32768 - neg.x)) <= 1, "asymmetric offsets")
            let far = t.counts(Vec2(1000, 1000))
            expect(far.x <= 65535 && far.y <= 65535 && far.x >= 0, "not clamped")
        }

        // MARK: Pen conversion

        test("pen: power / frequency / timing registers") {
            var pen = PenParameters(id: 0)
            pen.power = 50; pen.frequency = 30; pen.markSpeed = 500
            let conv = PenConversion(pen: pen, machine: MachineProfile())
            expectEqual(Int(conv.powerDAC16), 32768)           // round(50*65535/100)
            expectEqual(Int(conv.frequencyRegister), 1600)     // 48000/30
            expectEqual(Int(conv.markTime(distanceMM: 10)), 20000)  // 10mm * 1e6 / 500
        }

        test("pen: values clamped to profile limits") {
            var pen = PenParameters(id: 0)
            pen.power = 500; pen.frequency = 10_000   // way over limits
            let m = MachineProfile()
            let conv = PenConversion(pen: pen, machine: m)
            expect(conv.powerDAC16 == 65535, "power not clamped to 100%")
            expectEqual(Int(conv.frequencyRegister), Int((PenConversion.timebaseKHz / m.laser.maxFrequency).rounded()))
        }

        // MARK: Device state parsing

        test("state: parse default base-state reply") {
            let req = SeaFrame.encode(payload: SeaCommandBuilder.getBaseState().payload(), isCommand: true, seq: 1)
            let replyFrame = RecordingTransport.reply(toRequest: req, data: {
                var d = [UInt8](repeating: 0, count: 24); d[0] = 1; d[8] = 1; d[9] = 0x0F; d[10] = 0xFF; d[11] = 0xFF; return d
            }())
            let payload = SeaFrame.decode(replyFrame)!.payload
            let s = DeviceBaseState(payload: payload)
            expect(s != nil, "parse failed")
            expectEqual(Int(s?.boardStatus ?? 99), 1)
            expect(s?.idle == true, "idle not set")
            expectEqual(s?.freeCacheBytes ?? 0, 0x0FFFFF * 1024)
        }

        // MARK: Full flow against RecordingTransport

        test("flow: connect reads FPGA version from device-info reply") {
            let rec = RecordingTransport()
            let controller = USBLaserController(machine: MachineProfile(), variant: .framed, transport: { rec })
            let info = runAsync { try await controller.connect() }
            expectEqual(info?.fpgaVersion, "1.6.0.8")
            expect(rec.sentFrames.count >= 2, "connect should send >= 2 queries")
        }

        test("flow: mark fires laser (power sent), completes, ends laser off") {
            let rec = RecordingTransport()
            let controller = USBLaserController(machine: MachineProfile(), variant: .framed, transport: { rec })
            _ = runAsync { try await controller.connect() }
            var pen = PenParameters(id: 0); pen.power = 10; pen.markSpeed = 500
            let job = MarkJob(items: [MarkItem(pen: pen, polylines: [Rect2(minX: -5, minY: -5, maxX: 5, maxY: 5).outline])])
            let done = runAsync { try await controller.mark(job) { _ in } } != nil
            expect(done, "mark threw")
            expect(containsOpcode(rec, .fiberPower), "mark must upload laser power")
            expect(containsOpcode(rec, .setBoardStatus), "mark must set board status")
        }

        test("flow: framing uses red pointer and never uploads power") {
            let rec = RecordingTransport()
            let controller = USBLaserController(machine: MachineProfile(), variant: .framed, transport: { rec })
            _ = runAsync { try await controller.connect() }
            let pen = PenParameters(id: 0)
            let job = MarkJob(items: [MarkItem(pen: pen, polylines: [Rect2(minX: -5, minY: -5, maxX: 5, maxY: 5).outline])])
            // startFraming loops until stop(); kick it off then stop quickly.
            let group = DispatchGroup(); group.enter()
            Task { try? await controller.startFraming(job, outlineOnly: true); group.leave() }
            Thread.sleep(forTimeInterval: 0.05)
            runAsyncVoid { await controller.stop() }
            _ = group.wait(timeout: .now() + 2)
            expect(containsOpcode(rec, .redSignal), "framing must drive the red pointer")
            expect(!containsOpcode(rec, .fiberPower), "framing must NOT upload laser power")
        }

        test("transport: endpoint map matches device descriptors") {
            // Confirmed on hardware: OUT 0x02/0x06, IN 0x84/0x88 (interface 0, class 0xFF).
            expectEqual(SeaEndpoint.commandOut, 0x06)
            expectEqual(SeaEndpoint.commandIn, 0x88)
            expectEqual(SeaEndpoint.dataOut, 0x02)
            expectEqual(SeaEndpoint.dataIn, 0x84)
            let rec = RecordingTransport()
            let link = SeaLink(rec)
            _ = try? link.send(SeaCommandBuilder.getBaseState(), channel: .command)
            _ = try? link.send(SeaCommandBuilder.redPointer(false), channel: .data)
            expectEqual(rec.writes.map(\.endpoint), [0x06, 0x02])
        }

        test("batch: command list splits at 0x200 bytes") {
            let many = Array(repeating: SeaCommandBuilder.lineToAbs(x: 1, y: 2, time: 3, delay: 4), count: 60)
            let batches = USBLaserController.batch(many)
            expect(batches.count >= 2, "should split into multiple frames")
            for b in batches { expect(b.count <= 0x200, "batch exceeds 0x200") }
        }
    }

    // MARK: helpers

    private static func containsOpcode(_ rec: RecordingTransport, _ op: SeaOpcode) -> Bool {
        let needle: [UInt8] = [UInt8(op.rawValue >> 8), UInt8(op.rawValue & 0xFF)]
        for frame in rec.sentFrames {
            // scan payload region (skip 6-byte header) for the opcode as a command start
            guard frame.count > 8 else { continue }
            let payload = Array(frame[6..<max(6, frame.count - 2)])
            var i = 0
            while i + 1 < payload.count {
                if payload[i] == needle[0] && payload[i + 1] == needle[1] { return true }
                i += 1
            }
        }
        return false
    }

    private static func runAsync<T>(_ body: @escaping () async throws -> T) -> T? {
        let group = DispatchGroup(); group.enter()
        var result: T?
        Task { result = try? await body(); group.leave() }
        _ = group.wait(timeout: .now() + 5)
        return result
    }

    private static func runAsyncVoid(_ body: @escaping () async -> Void) {
        let group = DispatchGroup(); group.enter()
        Task { await body(); group.leave() }
        _ = group.wait(timeout: .now() + 5)
    }
}
