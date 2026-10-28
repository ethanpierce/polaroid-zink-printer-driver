import Foundation
import IOBluetooth

public enum ZipPrinterError: LocalizedError {
    case bluetooth(String, IOReturn)
    case timeout(String)
    case disconnected
    case rejected(String)
    case unreadableFile(URL)

    public var errorDescription: String? {
        switch self {
        case let .bluetooth(what, code):
            return "Bluetooth error while trying to \(what) (\(String(format: "0x%08X", UInt32(bitPattern: code))))."
        case let .timeout(what):
            return "The printer didn't respond while \(what). Make sure it's switched on and nearby."
        case .disconnected:
            return "The printer disconnected."
        case let .rejected(reason):
            return "The printer rejected the photo: \(reason). Check that it has paper, the cover is closed and the battery isn't low."
        case let .unreadableFile(url):
            return "Couldn't read \(url.lastPathComponent) as an image or PDF."
        }
    }
}

/// An async wrapper around an IOBluetooth RFCOMM channel. All IOBluetooth
/// callbacks arrive on the main run loop, so this lives on the main actor.
@MainActor
final class RFCOMMConnection: NSObject, IOBluetoothRFCOMMChannelDelegate {
    let device: IOBluetoothDevice
    private var channel: IOBluetoothRFCOMMChannel?
    private var isOpen = false
    private var inbox = Data()

    private var openContinuation: CheckedContinuation<Void, Error>?
    private var writeContinuation: CheckedContinuation<Void, Error>?
    private var writeBuffer: UnsafeMutableRawPointer?
    private var dataWaiter: CheckedContinuation<Void, Never>?

    init(device: IOBluetoothDevice) {
        self.device = device
    }

    func open(channelID: BluetoothRFCOMMChannelID, timeout: TimeInterval = 20) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            openContinuation = c
            var ch: IOBluetoothRFCOMMChannel?
            let result = device.openRFCOMMChannelAsync(&ch, withChannelID: channelID, delegate: self)
            ZipLog.log("open RFCOMM channel \(channelID): \(result)")
            if result != kIOReturnSuccess {
                openContinuation = nil
                c.resume(throwing: ZipPrinterError.bluetooth("connect", result))
                return
            }
            channel = ch
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard let self, let c = self.openContinuation else { return }
                self.openContinuation = nil
                self.channel?.close()
                c.resume(throwing: ZipPrinterError.timeout("connecting"))
            }
        }
    }

    /// Writes `data`, split into chunks no larger than the channel MTU.
    func write(_ data: Data) async throws {
        guard let channel, isOpen else { throw ZipPrinterError.disconnected }
        let mtu = max(Int(channel.getMTU()), 64)
        var offset = data.startIndex
        while offset < data.endIndex {
            let end = min(offset + mtu, data.endIndex)
            try await writeChunk(data[offset..<end], on: channel)
            offset = end
        }
    }

    private func writeChunk(_ chunk: Data, on channel: IOBluetoothRFCOMMChannel) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            // writeAsync doesn't copy the bytes, so keep them alive until the
            // write-complete callback.
            let buffer = UnsafeMutableRawPointer.allocate(byteCount: chunk.count, alignment: 1)
            chunk.copyBytes(to: buffer.assumingMemoryBound(to: UInt8.self), count: chunk.count)
            writeBuffer = buffer
            writeContinuation = c
            let result = channel.writeAsync(buffer, length: UInt16(chunk.count), refcon: nil)
            if result != kIOReturnSuccess {
                finishWrite(error: ZipPrinterError.bluetooth("send data", result))
            }
        }
    }

    private func finishWrite(error: Error?) {
        writeBuffer?.deallocate()
        writeBuffer = nil
        guard let c = writeContinuation else { return }
        writeContinuation = nil
        if let error { c.resume(throwing: error) } else { c.resume() }
    }

    /// Waits until `parse` can extract a value from the received bytes.
    func receive<T>(timeout: TimeInterval, while activity: String, _ parse: (inout Data) -> T?) async throws -> T {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let value = parse(&inbox) { return value }
            guard isOpen else { throw ZipPrinterError.disconnected }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw ZipPrinterError.timeout(activity) }
            await waitForData(upTo: remaining)
        }
    }

    private func waitForData(upTo seconds: TimeInterval) async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            dataWaiter = c
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                self?.wakeReader()
            }
        }
    }

    private func wakeReader() {
        let c = dataWaiter
        dataWaiter = nil
        c?.resume()
    }

    func close() {
        channel?.close()
        channel = nil
        isOpen = false
        wakeReader()
    }

    // MARK: IOBluetoothRFCOMMChannelDelegate

    nonisolated func rfcommChannelOpenComplete(_ rfcommChannel: IOBluetoothRFCOMMChannel!, status error: IOReturn) {
        MainActor.assumeIsolated {
            ZipLog.log("RFCOMM open complete: \(error), MTU \(rfcommChannel.getMTU())")
            guard let c = openContinuation else { return }
            openContinuation = nil
            if error == kIOReturnSuccess {
                isOpen = true
                c.resume()
            } else {
                c.resume(throwing: ZipPrinterError.bluetooth("connect", error))
            }
        }
    }

    nonisolated func rfcommChannelData(_ rfcommChannel: IOBluetoothRFCOMMChannel!, data dataPointer: UnsafeMutableRawPointer!, length dataLength: Int) {
        let bytes = Data(bytes: dataPointer, count: dataLength)
        MainActor.assumeIsolated {
            ZipLog.log("← " + bytes.prefix(16).map { String(format: "%02X", $0) }.joined(separator: " ") + (bytes.count > 16 ? " … (\(bytes.count) bytes)" : ""))
            inbox.append(bytes)
            wakeReader()
        }
    }

    nonisolated func rfcommChannelWriteComplete(_ rfcommChannel: IOBluetoothRFCOMMChannel!, refcon: UnsafeMutableRawPointer!, status error: IOReturn) {
        MainActor.assumeIsolated {
            if error != kIOReturnSuccess { ZipLog.log("write failed: \(error)") }
            finishWrite(error: error == kIOReturnSuccess ? nil : ZipPrinterError.bluetooth("send data", error))
        }
    }

    nonisolated func rfcommChannelClosed(_ rfcommChannel: IOBluetoothRFCOMMChannel!) {
        MainActor.assumeIsolated {
            ZipLog.log("RFCOMM channel closed")
            isOpen = false
            if let c = openContinuation {
                openContinuation = nil
                c.resume(throwing: ZipPrinterError.disconnected)
            }
            finishWrite(error: ZipPrinterError.disconnected)
            wakeReader()
        }
    }
}

/// Optional diagnostic log of the Bluetooth conversation.
public enum ZipLog {
    @MainActor public static var handler: ((String) -> Void)?

    @MainActor static func log(_ message: @autoclosure () -> String) {
        handler?(message())
    }
}
