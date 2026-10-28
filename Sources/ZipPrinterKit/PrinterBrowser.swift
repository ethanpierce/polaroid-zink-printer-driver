import Foundation
import IOBluetooth

public struct DiscoveredPrinter: Identifiable, Hashable {
    public let address: String
    public let name: String
    public var rssi: Int?

    public var id: String { address }

    public init(address: String, name: String, rssi: Int? = nil) {
        self.address = address
        self.name = name
        self.rssi = rssi
    }
}

/// Scans for nearby Polaroid ZIP printers with a Bluetooth Classic inquiry.
@MainActor
public final class PrinterBrowser: NSObject, IOBluetoothDeviceInquiryDelegate {
    public private(set) var printers: [DiscoveredPrinter] = []
    public private(set) var isScanning = false
    public var onChange: () -> Void = {}

    private var inquiry: IOBluetoothDeviceInquiry?

    /// IOBluetooth's first call blocks until the system Bluetooth service
    /// (and the permission prompt) answers, so make it off the main thread
    /// before using anything else in this module.
    public static func prepareBluetooth() async {
        await Task.detached { _ = IOBluetoothDevice.pairedDevices() }.value
    }

    /// True for devices that look like a ZINK photo printer: an Imaging-class
    /// device with the Printer bit set, or anything named like a Polaroid ZIP.
    public static func isPrinter(name: String?, classOfDevice: BluetoothClassOfDevice) -> Bool {
        if let name, name.localizedCaseInsensitiveContains("polaroid") || name.localizedCaseInsensitiveContains("zip") {
            return true
        }
        let majorClass = (classOfDevice >> 8) & 0x1F
        let printerBit = (classOfDevice >> 2) & 0x20
        return majorClass == 0x06 && printerBit != 0
    }

    /// Printers this Mac has seen before; usable without a scan.
    public func knownPrinters() -> [DiscoveredPrinter] {
        let devices = (IOBluetoothDevice.pairedDevices() ?? []) + (IOBluetoothDevice.recentDevices(20) ?? [])
        var seen = Set<String>()
        return devices.compactMap { $0 as? IOBluetoothDevice }.compactMap { device in
            guard let address = device.addressString, seen.insert(address).inserted,
                  Self.isPrinter(name: device.name, classOfDevice: device.classOfDevice) else { return nil }
            return DiscoveredPrinter(address: address, name: device.name ?? "Polaroid ZIP")
        }
    }

    public func startScan(seconds: UInt8 = 10) {
        stopScan()
        printers = knownPrinters()
        guard let inquiry = IOBluetoothDeviceInquiry(delegate: self) else { return }
        inquiry.inquiryLength = seconds
        inquiry.updateNewDeviceNames = true
        self.inquiry = inquiry
        isScanning = inquiry.start() == kIOReturnSuccess
        onChange()
    }

    public func stopScan() {
        inquiry?.stop()
        inquiry = nil
        if isScanning {
            isScanning = false
            onChange()
        }
    }

    private func record(_ device: IOBluetoothDevice) {
        guard let address = device.addressString,
              Self.isPrinter(name: device.name, classOfDevice: device.classOfDevice) else { return }
        let printer = DiscoveredPrinter(address: address, name: device.name ?? "Polaroid ZIP", rssi: Int(device.rawRSSI()))
        if let index = printers.firstIndex(where: { $0.address == address }) {
            printers[index] = printer
        } else {
            printers.append(printer)
        }
        onChange()
    }

    // MARK: IOBluetoothDeviceInquiryDelegate

    nonisolated public func deviceInquiryDeviceFound(_ sender: IOBluetoothDeviceInquiry!, device: IOBluetoothDevice!) {
        MainActor.assumeIsolated { record(device) }
    }

    nonisolated public func deviceInquiryDeviceNameUpdated(_ sender: IOBluetoothDeviceInquiry!, device: IOBluetoothDevice!, devicesRemaining: UInt32) {
        MainActor.assumeIsolated { record(device) }
    }

    nonisolated public func deviceInquiryComplete(_ sender: IOBluetoothDeviceInquiry!, error: IOReturn, aborted: Bool) {
        MainActor.assumeIsolated {
            guard sender === inquiry else { return }
            inquiry = nil
            isScanning = false
            onChange()
        }
    }
}
