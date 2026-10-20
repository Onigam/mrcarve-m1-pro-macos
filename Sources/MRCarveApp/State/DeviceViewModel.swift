import Foundation
import Observation
import AppKit
import MRCarveKit

/// Connection state shown in the toolbar pill.
enum ConnectionState: Equatable {
    case disconnected
    case connecting
    case connected(DeviceInfo)
    case failed(String)

    var isConnected: Bool { if case .connected = self { true } else { false } }
}

/// What the laser is doing.
enum DeviceActivity: Equatable {
    case idle, framing, marking
}

/// How the last mark ended.
enum MarkOutcome: Equatable {
    case completed(TimeInterval)
    case stopped
    case failed(String)
}

/// Owns the `LaserController` (simulated or USB) and runs framing / marking without blocking the UI.
/// There is one device for the whole app; windows identify themselves with `ownerID` so that progress
/// sheets and errors appear in the window that started the operation.
@MainActor @Observable
final class DeviceViewModel {
    static let shared = DeviceViewModel()

    private(set) var mode: DeviceMode
    private(set) var connection: ConnectionState = .disconnected
    private(set) var activity: DeviceActivity = .idle
    private(set) var progress: Double = 0
    private(set) var markStartedAt: Date?
    private(set) var markEstimate: TimeInterval = 0
    /// Bounds traced by the red light while framing (for the canvas overlay).
    private(set) var framingBounds: Rect2?
    /// Window that started the current/last operation.
    private(set) var ownerID: UUID?
    /// Result of the last mark, until acknowledged.
    var outcome: MarkOutcome?
    /// Error to present in the owner window.
    var errorMessage: String?
    /// Set when the user ticks "don't show again for this session" on the safety sheet.
    var safetyAcknowledged = false

    @ObservationIgnored private var controller: any LaserController
    @ObservationIgnored private var framingTask: Task<Void, Never>?
    @ObservationIgnored private var markTask: Task<Void, Never>?
    @ObservationIgnored private var framingJob = MarkJob(items: [])
    @ObservationIgnored private var framingOutlineOnly = true
    @ObservationIgnored private var restartFraming = false
    @ObservationIgnored private var lastJob: MarkJob?

    private init() {
        let mode = AppSettings.shared.deviceMode
        self.mode = mode
        controller = DeviceViewModel.makeController(mode, machine: MachineStore.shared.library.defaultProfile)
    }

    private static func makeController(_ mode: DeviceMode, machine: MachineProfile) -> any LaserController {
        switch mode {
        case .simulator: SimulatedLaserController(machine: machine)
        case .usb: USBLaserController(machine: machine)
        }
    }

    var isBusy: Bool { activity != .idle }
    var isFraming: Bool { activity == .framing }
    var isMarking: Bool { activity == .marking }
    var canRepeatLastJob: Bool { lastJob != nil }

    /// Connects on launch when the user wants it (always for the simulator). Failures stay silent.
    func start() {
        if mode == .simulator || AppSettings.shared.autoConnect {
            Task { await connect(silently: true) }
        }
    }

    // MARK: Connection

    func setMode(_ newMode: DeviceMode) {
        guard newMode != mode else { return }
        let old = controller
        Task { await old.stop(); await old.disconnect() }
        framingTask?.cancel()
        markTask?.cancel()
        activity = .idle
        framingBounds = nil
        mode = newMode
        AppSettings.shared.deviceMode = newMode
        controller = DeviceViewModel.makeController(newMode, machine: MachineStore.shared.library.defaultProfile)
        connection = .disconnected
        start()
    }

    func connect(silently: Bool = false, owner: UUID? = nil) async {
        if case .connecting = connection { return }
        if let owner { ownerID = owner }
        connection = .connecting
        do {
            let info = try await controller.connect()
            connection = .connected(info)
        } catch {
            let message = DeviceViewModel.describe(error)
            connection = .failed(message)
            if !silently { errorMessage = message }
        }
    }

    func disconnect() async {
        await stopNow()
        await controller.disconnect()
        connection = .disconnected
    }

    func toggleConnection(owner: UUID? = nil) {
        Task {
            if connection.isConnected { await disconnect() } else { await connect(owner: owner) }
        }
    }

    private func ensureConnected() async throws {
        if connection.isConnected { return }
        connection = .connecting
        do {
            connection = .connected(try await controller.connect())
        } catch {
            connection = .failed(DeviceViewModel.describe(error))
            throw error
        }
    }

    // MARK: Framing

    /// Starts red-light framing, or stops it if already framing.
    func toggleFraming(_ job: MarkJob, machine: MachineProfile, outlineOnly: Bool, owner: UUID) {
        if isFraming { stop(); return }
        guard !isBusy else { return }
        startFraming(job, machine: machine, outlineOnly: outlineOnly, owner: owner)
    }

    private func startFraming(_ job: MarkJob, machine: MachineProfile, outlineOnly: Bool, owner: UUID) {
        ownerID = owner
        framingJob = job
        framingOutlineOnly = outlineOnly
        framingBounds = job.bounds
        activity = .framing
        controller.machine = machine
        let controller = self.controller
        framingTask = Task { [weak self] in
            do {
                try await self?.ensureConnected()
                while let self, !Task.isCancelled {
                    self.restartFraming = false
                    do {
                        try await controller.startFraming(self.framingJob, outlineOnly: self.framingOutlineOnly)
                    } catch LaserControllerError.cancelled {}
                    if !self.restartFraming { break }
                }
            } catch {
                self?.report(error, owner: owner)
            }
            self?.finishFraming()
        }
    }

    /// Re-traces with an updated job while framing (e.g. after the design changed).
    func updateFraming(_ job: MarkJob, outlineOnly: Bool) {
        guard isFraming, job != framingJob || outlineOnly != framingOutlineOnly else { return }
        framingJob = job
        framingOutlineOnly = outlineOnly
        framingBounds = job.bounds
        restartFraming = true
        let controller = self.controller
        Task { await controller.stop() }
    }

    private func finishFraming() {
        if activity == .framing { activity = .idle }
        framingBounds = nil
        framingTask = nil
    }

    // MARK: Marking

    /// Marks `job`; progress and the outcome are published for the owner window's sheet.
    func mark(_ job: MarkJob, machine: MachineProfile, estimate: TimeInterval, owner: UUID) {
        guard activity != .marking else { return }
        let wasFraming = isFraming
        ownerID = owner
        outcome = nil
        progress = 0
        markEstimate = estimate
        markStartedAt = Date()
        lastJob = job
        let previousFraming = framingTask
        activity = .marking
        controller.machine = machine
        let controller = self.controller
        markTask = Task {
            if wasFraming {
                await controller.stop()
                await previousFraming?.value
            }
            let started = Date()
            do {
                try await ensureConnected()
                activity = .marking
                markStartedAt = Date()
                try await controller.mark(job) { p in
                    Task { @MainActor in
                        let model = DeviceViewModel.shared
                        if model.activity == .marking { model.progress = p }
                    }
                }
                outcome = .completed(Date().timeIntervalSince(started))
                NSSound(named: "Glass")?.play()
            } catch LaserControllerError.cancelled {
                outcome = .stopped
            } catch {
                outcome = .failed(DeviceViewModel.describe(error))
            }
            activity = .idle
            markTask = nil
        }
    }

    /// Re-marks the last job (from the "Mark Again" button).
    func markAgain(machine: MachineProfile, owner: UUID) {
        guard let job = lastJob else { return }
        mark(job, machine: machine, estimate: markEstimate, owner: owner)
    }

    // MARK: Stop

    /// Stops framing or marking immediately (laser off).
    func stop() {
        restartFraming = false
        let controller = self.controller
        Task { await controller.stop() }
    }

    private func stopNow() async {
        restartFraming = false
        await controller.stop()
        await framingTask?.value
        await markTask?.value
    }

    // MARK: Errors

    private func report(_ error: Error, owner: UUID) {
        if case LaserControllerError.cancelled = error { return }
        ownerID = owner
        errorMessage = DeviceViewModel.describe(error)
    }

    static func describe(_ error: Error) -> String {
        if let e = error as? LocalizedError, let d = e.errorDescription { return d }
        return error.localizedDescription
    }

    // MARK: Presentation

    /// Short status for the toolbar pill.
    var statusTitle: String {
        switch activity {
        case .framing: return L("Framing")
        case .marking: return L("Marking %@", Format.percent(progress))
        case .idle: break
        }
        switch connection {
        case .connecting: return L("Connecting…")
        case .connected(let info):
            return mode == .simulator ? L("Simulator") : L("Connected · FPGA %@", info.fpgaVersion)
        case .disconnected, .failed: return mode == .simulator ? L("Simulator (offline)") : L("Disconnected")
        }
    }

    var deviceInfo: DeviceInfo? {
        if case .connected(let info) = connection { info } else { nil }
    }

    var lastConnectionError: String? {
        if case .failed(let m) = connection { m } else { nil }
    }
}
