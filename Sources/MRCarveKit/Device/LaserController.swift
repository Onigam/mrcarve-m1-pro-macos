import Foundation

public struct DeviceInfo: Hashable, Sendable {
    public var fpgaVersion: String
    public var serial: String?
    public var usbSpeed: String?
    public var details: [String: String]

    public init(fpgaVersion: String, serial: String? = nil, usbSpeed: String? = nil, details: [String: String] = [:]) {
        self.fpgaVersion = fpgaVersion
        self.serial = serial
        self.usbSpeed = usbSpeed
        self.details = details
    }
}

public enum DeviceState: Hashable, Sendable {
    case disconnected
    case connecting
    case ready(DeviceInfo)
    case framing          // red-light preview running
    case marking(progress: Double)
    case error(String)
}

public enum LaserControllerError: Error, LocalizedError, Sendable {
    case deviceNotFound
    case notConnected
    case busy
    case outOfField(Rect2)
    case transport(String)
    case protocolError(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .deviceNotFound: "No MR Carve device found on USB (expected 04B4:1004)."
        case .notConnected: "The laser is not connected."
        case .busy: "The laser is busy."
        case .outOfField(let r): String(format: "Job exceeds the marking field (%.1f×%.1f mm).", r.width, r.height)
        case .transport(let m): "USB error: \(m)"
        case .protocolError(let m): "Protocol error: \(m)"
        case .cancelled: "Cancelled."
        }
    }
}

/// High-level device API used by the app. Implemented by the real USB controller and by
/// `SimulatedLaserController` (no hardware). Implementations must be safe to call from the main actor;
/// long operations are async and must honour `stop()`.
public protocol LaserController: AnyObject, Sendable {
    /// Connects and runs the full initialisation handshake. Returns device information.
    func connect() async throws -> DeviceInfo
    func disconnect() async

    /// Red-light framing: traces `job` (or its bounding box if `outlineOnly`) with the red pointer,
    /// looping until `stop()` is called. The marking laser stays off.
    func startFraming(_ job: MarkJob, outlineOnly: Bool) async throws

    /// Marks `job`. `progress` is called with 0...1. Returns when marking has finished on the device.
    func mark(_ job: MarkJob, progress: @escaping @Sendable (Double) -> Void) async throws

    /// Stops framing or marking as soon as possible (laser off).
    func stop() async

    /// Machine calibration / lens parameters used to convert mm to galvo units.
    var machine: MachineProfile { get set }
}
