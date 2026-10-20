import Foundation
import CLibUSB

/// libusb-backed bulk transport to the real BSL board. Opens VID:PID 04B4:1004, claims interface 0 and
/// moves bytes on the bulk endpoints. Mirrors `LibUsbControl` (@0x1688d8) but uses a normal
/// `libusb_open` rather than `libusb_wrap_sys_device` (that path is Android-specific).
///
/// SAFETY: creating this opens and claims the device. Nothing writes to the laser until the controller's
/// mark/frame paths run. Never instantiate against hardware from a diagnostics-only command.
public final class LibUSBTransport: Transport, @unchecked Sendable {
    private var ctx: OpaquePointer?
    private var handle: OpaquePointer?
    private let lock = NSLock()

    public init() throws {
        var c: OpaquePointer?
        guard libusb_init(&c) == 0, let c else { throw LaserControllerError.transport("libusb_init failed") }
        ctx = c
        let h = libusb_open_device_with_vid_pid(c, USBDiscovery.vendorID, USBDiscovery.productID)
        guard let h else {
            libusb_exit(c); ctx = nil
            throw LaserControllerError.deviceNotFound
        }
        handle = h
        libusb_set_auto_detach_kernel_driver(h, 1)
        let rc = libusb_claim_interface(h, 0)
        if rc != 0 {
            libusb_close(h); libusb_exit(c); handle = nil; ctx = nil
            throw LaserControllerError.transport("claim interface 0 failed: \(String(cString: libusb_error_name(rc)))")
        }
    }

    public func bulkWrite(endpoint: UInt8, _ bytes: [UInt8]) throws {
        lock.lock(); defer { lock.unlock() }
        guard let handle else { throw LaserControllerError.notConnected }
        var transferred: Int32 = 0
        var buf = bytes
        let rc = buf.withUnsafeMutableBufferPointer { ptr in
            libusb_bulk_transfer(handle, endpoint, ptr.baseAddress, Int32(ptr.count), &transferred, SeaEndpoint.timeoutMs)
        }
        guard rc == 0 else { throw LaserControllerError.transport("bulk OUT 0x\(String(endpoint, radix: 16)): \(String(cString: libusb_error_name(rc)))") }
    }

    public func bulkRead(endpoint: UInt8, maxLength: Int) throws -> [UInt8] {
        lock.lock(); defer { lock.unlock() }
        guard let handle else { throw LaserControllerError.notConnected }
        var transferred: Int32 = 0
        var buf = [UInt8](repeating: 0, count: maxLength)
        let rc = buf.withUnsafeMutableBufferPointer { ptr in
            libusb_bulk_transfer(handle, endpoint, ptr.baseAddress, Int32(ptr.count), &transferred, SeaEndpoint.timeoutMs)
        }
        guard rc == 0 else { throw LaserControllerError.transport("bulk IN 0x\(String(endpoint, radix: 16)): \(String(cString: libusb_error_name(rc)))") }
        return Array(buf.prefix(Int(max(0, transferred))))
    }

    public func close() {
        lock.lock(); defer { lock.unlock() }
        if let handle { libusb_release_interface(handle, 0); libusb_close(handle) }
        if let ctx { libusb_exit(ctx) }
        handle = nil; ctx = nil
    }

    deinit { close() }
}
