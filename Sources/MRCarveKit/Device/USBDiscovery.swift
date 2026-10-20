import Foundation
import CLibUSB

/// Read-only USB inspection (no data is ever sent to the device).
public enum USBDiscovery {
    public static let vendorID: UInt16 = 0x04B4   // Cypress
    public static let productID: UInt16 = 0x1004  // BSL / SEA-LASER board (FX2LP with firmware)
    public static let bareFX2ProductID: UInt16 = 0x8613 // FX2LP without firmware loaded

    public struct Endpoint: Hashable, Sendable {
        public var address: UInt8
        public var attributes: UInt8
        public var maxPacketSize: UInt16
        public var isIn: Bool { address & 0x80 != 0 }
        public var transferType: String {
            switch attributes & 0x03 { case 0: "control"; case 1: "iso"; case 2: "bulk"; default: "interrupt" }
        }
    }

    public struct Interface: Hashable, Sendable {
        public var number: UInt8
        public var alternateSetting: UInt8
        public var interfaceClass: UInt8
        public var endpoints: [Endpoint]
    }

    public struct Device: Hashable, Sendable {
        public var vendorID: UInt16
        public var productID: UInt16
        public var bus: UInt8
        public var address: UInt8
        public var speed: String
        public var bcdDevice: UInt16
        public var interfaces: [Interface]
        public var isMRCarve: Bool { vendorID == USBDiscovery.vendorID && productID == USBDiscovery.productID }
        public var isBareFX2: Bool { vendorID == USBDiscovery.vendorID && productID == USBDiscovery.bareFX2ProductID }
    }

    /// Lists all USB devices with their descriptors.
    public static func listDevices() throws -> [Device] {
        var ctx: OpaquePointer?
        let rc = libusb_init(&ctx)
        guard rc == 0 else { throw LaserControllerError.transport(String(cString: libusb_error_name(rc))) }
        defer { libusb_exit(ctx) }

        var list: UnsafeMutablePointer<OpaquePointer?>?
        let n = libusb_get_device_list(ctx, &list)
        guard n >= 0, let list else { throw LaserControllerError.transport(String(cString: libusb_error_name(Int32(n)))) }
        defer { libusb_free_device_list(list, 1) }

        var result: [Device] = []
        for i in 0..<Int(n) {
            guard let dev = list[i] else { continue }
            var desc = libusb_device_descriptor()
            guard libusb_get_device_descriptor(dev, &desc) == 0 else { continue }
            var interfaces: [Interface] = []
            var cfg: UnsafeMutablePointer<libusb_config_descriptor>?
            if libusb_get_active_config_descriptor(dev, &cfg) == 0 || libusb_get_config_descriptor(dev, 0, &cfg) == 0, let cfg {
                for ii in 0..<Int(cfg.pointee.bNumInterfaces) {
                    let itf = cfg.pointee.interface[ii]
                    for ai in 0..<Int(itf.num_altsetting) {
                        let alt = itf.altsetting[ai]
                        var eps: [Endpoint] = []
                        for ei in 0..<Int(alt.bNumEndpoints) {
                            let ep = alt.endpoint[ei]
                            eps.append(Endpoint(address: ep.bEndpointAddress, attributes: ep.bmAttributes, maxPacketSize: ep.wMaxPacketSize))
                        }
                        interfaces.append(Interface(number: alt.bInterfaceNumber, alternateSetting: alt.bAlternateSetting,
                                                    interfaceClass: alt.bInterfaceClass, endpoints: eps))
                    }
                }
                libusb_free_config_descriptor(cfg)
            }
            let speed: String
            switch libusb_get_device_speed(dev) {
            case Int32(LIBUSB_SPEED_LOW.rawValue): speed = "low"
            case Int32(LIBUSB_SPEED_FULL.rawValue): speed = "full"
            case Int32(LIBUSB_SPEED_HIGH.rawValue): speed = "high"
            case Int32(LIBUSB_SPEED_SUPER.rawValue): speed = "super"
            default: speed = "unknown"
            }
            result.append(Device(vendorID: desc.idVendor, productID: desc.idProduct,
                                 bus: libusb_get_bus_number(dev), address: libusb_get_device_address(dev),
                                 speed: speed, bcdDevice: desc.bcdDevice, interfaces: interfaces))
        }
        return result
    }
}
