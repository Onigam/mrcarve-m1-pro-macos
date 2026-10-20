import Foundation

/// A `LaserController` that needs no hardware: it validates jobs against the field and
/// simulates timing so the UI can be developed and demoed without the machine.
public final class SimulatedLaserController: LaserController, @unchecked Sendable {
    private let lock = NSLock()
    private var connected = false
    private var cancelled = false
    private var _machine: MachineProfile

    public init(machine: MachineProfile = MachineProfile()) {
        _machine = machine
    }

    public var machine: MachineProfile {
        get { lock.withLock { _machine } }
        set { lock.withLock { _machine = newValue } }
    }

    public func connect() async throws -> DeviceInfo {
        try await Task.sleep(nanoseconds: 300_000_000)
        lock.withLock { connected = true }
        return DeviceInfo(fpgaVersion: "simulated", serial: "SIM-0001", usbSpeed: "n/a")
    }

    public func disconnect() async {
        lock.withLock { connected = false; cancelled = true }
    }

    public func startFraming(_ job: MarkJob, outlineOnly: Bool) async throws {
        try checkReady(job)
        lock.withLock { cancelled = false }
        while !lock.withLock({ cancelled }) {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    public func mark(_ job: MarkJob, progress: @escaping @Sendable (Double) -> Void) async throws {
        try checkReady(job)
        lock.withLock { cancelled = false }
        // Rough duration: mark length at pen speed, capped so demos stay short.
        let seconds = min(8.0, max(1.0, job.items.reduce(0.0) { acc, item in
            let len = item.polylines.reduce(0) { $0 + $1.length } * Double(max(1, item.pen.loopCount))
            return acc + len / max(1, item.pen.markSpeed)
        }))
        let steps = 50
        for i in 1...steps {
            if lock.withLock({ cancelled }) { throw LaserControllerError.cancelled }
            try await Task.sleep(nanoseconds: UInt64(seconds / Double(steps) * 1e9))
            progress(Double(i) / Double(steps))
        }
    }

    public func stop() async {
        lock.withLock { cancelled = true }
    }

    private func checkReady(_ job: MarkJob) throws {
        guard lock.withLock({ connected }) else { throw LaserControllerError.notConnected }
        if let b = job.bounds {
            let f = machine.field
            if b.minX < f.minX - 1e-6 || b.minY < f.minY - 1e-6 || b.maxX > f.maxX + 1e-6 || b.maxY > f.maxY + 1e-6 {
                throw LaserControllerError.outOfField(b)
            }
        }
    }
}
