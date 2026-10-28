import Foundation
import IOBluetooth

/// A Polaroid ZIP (or compatible ZINK) printer reachable over Bluetooth Classic.
///
/// The printer advertises three RFCOMM services over SDP:
///  - OBEX Object Push (UUID 0x1105), usually channel 4: accepts a JPEG and prints it
///  - Apple iAP2 (UUID 00000000-DECA-FADE-DECA-DEAFDECACAFF), usually channel 1, for the iOS app
///  - Serial Port (UUID 0x1101), usually channel 2
///
/// Printing only needs Object Push, and the printer doesn't require pairing.
@MainActor
public final class ZipPrinter {
    public let device: IOBluetoothDevice

    public var address: String { device.addressString ?? "" }
    public var name: String { device.name ?? "Polaroid ZIP" }

    static let objectPushUUID: UInt16 = 0x1105
    static let defaultObjectPushChannel: BluetoothRFCOMMChannelID = 4
    static let ourMaxPacketLength: UInt16 = 0xFFFF
    static let packetLength = 4096
    static let bytesPerSecond = 12_000.0

    public init(device: IOBluetoothDevice) {
        self.device = device
    }

    public convenience init?(address: String) {
        guard let device = IOBluetoothDevice(addressString: address) else { return nil }
        self.init(device: device)
    }

    /// Sends a JPEG to the printer. `progress` is called with 0...1 as the
    /// transfer proceeds; printing starts on its own once the transfer ends.
    public func send(jpeg: Data, fileName: String = "photo.jpg", progress: @escaping (Double) -> Void = { _ in }) async throws {
        let channelID = await objectPushChannel()
        ZipLog.log("Object Push is on RFCOMM channel \(channelID); sending \(jpeg.count) bytes")
        do {
            try await send(jpeg: jpeg, fileName: fileName, channelID: channelID, progress: progress)
        } catch let error as SendFailure where !error.finalPacketSent && error.isTransient {
            // The link sometimes drops on the first connection after the
            // printer wakes up. Nothing has printed yet, so try once more.
            ZipLog.log("retrying after: \(error.underlying.localizedDescription)")
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            do {
                try await send(jpeg: jpeg, fileName: fileName, channelID: channelID, progress: progress)
            } catch let error as SendFailure {
                throw error.underlying
            }
        } catch let error as SendFailure {
            throw error.underlying
        }
    }

    private struct SendFailure: Error {
        let underlying: Error
        let finalPacketSent: Bool

        var isTransient: Bool {
            switch underlying as? ZipPrinterError {
            case .disconnected, .timeout, .bluetooth: return true
            default: return false
            }
        }
    }

    private func send(jpeg: Data, fileName: String, channelID: BluetoothRFCOMMChannelID, progress: @escaping (Double) -> Void) async throws {
        var finalPacketSent = false
        do {
            try await transfer(jpeg: jpeg, fileName: fileName, channelID: channelID, progress: progress) {
                finalPacketSent = true
            }
        } catch {
            throw SendFailure(underlying: error, finalPacketSent: finalPacketSent)
        }
    }

    private func transfer(jpeg: Data, fileName: String, channelID: BluetoothRFCOMMChannelID,
                          progress: @escaping (Double) -> Void, willSendFinalPacket: () -> Void) async throws {
        let connection = RFCOMMConnection(device: device)
        try await connection.open(channelID: channelID, timeout: 12)
        defer { connection.close() }

        try await connection.write(OBEX.connect(maxPacketLength: Self.ourMaxPacketLength))
        let hello = try await connection.receive(timeout: 10, while: "connecting", OBEX.takeResponse)
        guard hello.isSuccess else { throw ZipPrinterError.rejected(OBEX.describe(hello.code)) }
        let maxPacket = min(hello.maxPacketLength ?? 0x1000, Int(Self.ourMaxPacketLength))

        let packets = OBEX.putPackets(name: fileName, type: "image/jpeg", body: jpeg,
                                      maxPacketLength: min(maxPacket, Self.packetLength))
        progress(0)
        ZipLog.log("CONNECT ok, printer max packet \(maxPacket); \(packets.count) PUT packets")
        let started = Date()
        var sent = 0
        for (index, packet) in packets.enumerated() {
            // The printer acknowledges packets as soon as they land in its
            // receive buffer, then decodes from that buffer as it goes. Sent
            // too fast, newer data overwrites bytes it hasn't decoded yet and
            // a band of the photo goes missing, so hold to a steady pace.
            let due = Double(sent) / Self.bytesPerSecond - Date().timeIntervalSince(started)
            if due > 0 { try? await Task.sleep(nanoseconds: UInt64(due * 1_000_000_000)) }

            ZipLog.log(String(format: "%6.2fs → PUT %d/%d (%d bytes)", Date().timeIntervalSince(started), index + 1, packets.count, packet.count))
            let isLast = index == packets.count - 1
            if isLast { willSendFinalPacket() }
            try await connection.write(packet)
            sent += packet.count
            // The final response can lag while the printer decodes the JPEG.
            let reply = try await connection.receive(timeout: isLast ? 60 : 20, while: "sending the photo", OBEX.takeResponse)
            if isLast ? !reply.isSuccess : !reply.isContinue {
                throw ZipPrinterError.rejected(OBEX.describePrinterError(reply.code))
            }
            progress(Double(index + 1) / Double(packets.count))
        }
        ZipLog.log(String(format: "%6.2fs  transfer complete", Date().timeIntervalSince(started)))

        try? await connection.write(OBEX.disconnect())
        _ = try? await connection.receive(timeout: 3, while: "disconnecting", OBEX.takeResponse)
    }

    /// Opens and closes an OBEX session without sending anything. Throws if
    /// the printer is asleep or out of range. (This doesn't reset the
    /// printer's idle power-off timer.)
    public func ping() async throws {
        let channelID = await objectPushChannel()
        let connection = RFCOMMConnection(device: device)
        try await connection.open(channelID: channelID, timeout: 10)
        defer { connection.close() }
        try await connection.write(OBEX.connect(maxPacketLength: Self.ourMaxPacketLength))
        let hello = try await connection.receive(timeout: 5, while: "connecting", OBEX.takeResponse)
        guard hello.isSuccess else { throw ZipPrinterError.rejected(OBEX.describe(hello.code)) }
        try await connection.write(OBEX.disconnect())
        _ = try? await connection.receive(timeout: 3, while: "disconnecting", OBEX.takeResponse)
        ZipLog.log("ping ok")
    }

    /// Looks up the Object Push RFCOMM channel over SDP, falling back to the
    /// channel the ZIP normally uses.
    func objectPushChannel() async -> BluetoothRFCOMMChannelID {
        if let channel = Self.objectPushChannel(in: device.services) { return channel }
        let query = SDPQuery()
        await query.run(on: device, timeout: 10)
        return Self.objectPushChannel(in: device.services) ?? Self.defaultObjectPushChannel
    }

    static func objectPushChannel(in services: [Any]?) -> BluetoothRFCOMMChannelID? {
        guard let opp = IOBluetoothSDPUUID(uuid16: objectPushUUID) else { return nil }
        for case let record as IOBluetoothSDPServiceRecord in services ?? [] where record.hasService(from: [opp]) {
            var channel: BluetoothRFCOMMChannelID = 0
            if record.getRFCOMMChannelID(&channel) == kIOReturnSuccess { return channel }
        }
        return nil
    }
}

/// Runs one SDP query and waits for it to finish.
@MainActor
private final class SDPQuery: NSObject {
    private var continuation: CheckedContinuation<Void, Never>?

    func run(on device: IOBluetoothDevice, timeout: TimeInterval) async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            continuation = c
            if device.performSDPQuery(self) != kIOReturnSuccess {
                finish()
                return
            }
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self?.finish()
            }
        }
    }

    private func finish() {
        let c = continuation
        continuation = nil
        c?.resume()
    }

    @objc nonisolated func sdpQueryComplete(_ device: IOBluetoothDevice!, status: IOReturn) {
        MainActor.assumeIsolated { finish() }
    }
}
