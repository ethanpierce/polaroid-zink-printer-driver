import Foundation

/// Minimal OBEX (IrDA Object Exchange) encoder/decoder: just enough of the
/// Object Push Profile to send one file to a printer.
public enum OBEX {
    public enum Opcode: UInt8 {
        case connect = 0x80
        case disconnect = 0x81
        case put = 0x02
        case putFinal = 0x82
        case abort = 0xFF
    }

    public enum HeaderID: UInt8 {
        case name = 0x01        // null-terminated UTF-16BE
        case type = 0x42        // null-terminated ASCII
        case length = 0xC3      // 4-byte big-endian
        case body = 0x48
        case endOfBody = 0x49
    }

    public enum ResponseCode: UInt8 {
        case `continue` = 0x90
        case success = 0xA0
    }

    public static let version: UInt8 = 0x10

    public struct Response: Equatable {
        public let code: UInt8
        public let payload: Data

        public var isSuccess: Bool { code == ResponseCode.success.rawValue }
        public var isContinue: Bool { code == ResponseCode.continue.rawValue }

        /// For a CONNECT response: the largest packet the peer will accept.
        public var maxPacketLength: Int? {
            guard payload.count >= 4 else { return nil }
            let i = payload.startIndex
            return Int(payload[i + 2]) << 8 | Int(payload[i + 3])
        }
    }

    // MARK: Packets

    public static func connect(maxPacketLength: UInt16) -> Data {
        var d = Data([Opcode.connect.rawValue, 0, 7, version, 0x00])
        d.append(UInt8(maxPacketLength >> 8))
        d.append(UInt8(maxPacketLength & 0xFF))
        return d
    }

    public static func disconnect() -> Data {
        packet(.disconnect, headers: Data())
    }

    public static func packet(_ opcode: Opcode, headers: Data) -> Data {
        let length = 3 + headers.count
        precondition(length <= 0xFFFF, "OBEX packet too large")
        var d = Data([opcode.rawValue, UInt8(length >> 8), UInt8(length & 0xFF)])
        d.append(headers)
        return d
    }

    /// Splits `body` into a sequence of PUT packets that each fit in
    /// `maxPacketLength`. The first packet carries Name/Type/Length; the last
    /// is a PUT-final with an End-of-Body header.
    public static func putPackets(name: String, type: String, body: Data, maxPacketLength: Int) -> [Data] {
        let meta = unicodeHeader(.name, name) + asciiHeader(.type, type) + uint32Header(.length, UInt32(body.count))
        var packets: [Data] = []
        var offset = body.startIndex
        var first = true
        repeat {
            let prefix = first ? meta : Data()
            let room = maxPacketLength - 3 - prefix.count - 3
            precondition(room > 0, "maxPacketLength too small")
            let end = min(offset + room, body.endIndex)
            let chunk = body[offset..<end]
            let last = end == body.endIndex
            let headers = prefix + bytesHeader(last ? .endOfBody : .body, Data(chunk))
            packets.append(packet(last ? .putFinal : .put, headers: headers))
            offset = end
            first = false
        } while offset < body.endIndex
        return packets
    }

    // MARK: Headers

    public static func unicodeHeader(_ id: HeaderID, _ text: String) -> Data {
        var value = Data()
        for unit in text.utf16 {
            value.append(UInt8(unit >> 8))
            value.append(UInt8(unit & 0xFF))
        }
        value.append(contentsOf: [0, 0])
        return bytesHeader(id, value)
    }

    public static func asciiHeader(_ id: HeaderID, _ text: String) -> Data {
        bytesHeader(id, Data(text.utf8) + Data([0]))
    }

    public static func bytesHeader(_ id: HeaderID, _ value: Data) -> Data {
        let length = 3 + value.count
        var d = Data([id.rawValue, UInt8(length >> 8), UInt8(length & 0xFF)])
        d.append(value)
        return d
    }

    public static func uint32Header(_ id: HeaderID, _ value: UInt32) -> Data {
        Data([id.rawValue, UInt8(value >> 24), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)])
    }

    // MARK: Parsing

    /// Removes and returns one complete response from the front of `buffer`,
    /// or returns nil if a full packet hasn't arrived yet.
    public static func takeResponse(from buffer: inout Data) -> Response? {
        guard buffer.count >= 3 else { return nil }
        let i = buffer.startIndex
        let length = Int(buffer[i + 1]) << 8 | Int(buffer[i + 2])
        guard length >= 3, buffer.count >= length else { return nil }
        let response = Response(code: buffer[i], payload: Data(buffer[(i + 3)..<(i + length)]))
        buffer = Data(buffer[(i + length)...])
        return response
    }

    /// ZINK printers in the LG Pocket Photo / Polaroid ZIP family answer a
    /// rejected PUT with a vendor-specific response code describing why.
    public static func describePrinterError(_ code: UInt8) -> String {
        switch code {
        case 0xC0: return "printer is busy"
        case 0xC1: return "the photo data couldn't be read"
        case 0xC2: return "paper jam"
        case 0xC5: return "out of paper"
        case 0xC7: return "battery is low"
        case 0xC8: return "printer system error"
        case 0xC9: return "paper cover is open"
        case 0xCB: return "printer is too hot"
        case 0xCC: return "printer is too cold"
        case 0xCD: return "wrong paper loaded"
        case 0xCF: return "printer is cooling down"
        default: return describe(code)
        }
    }

    public static func describe(_ code: UInt8) -> String {
        switch code & 0x7F {
        case 0x10: return "Continue"
        case 0x20: return "OK"
        case 0x40: return "Bad Request"
        case 0x41: return "Unauthorized"
        case 0x43: return "Forbidden"
        case 0x44: return "Not Found"
        case 0x46: return "Not Acceptable"
        case 0x4D: return "Request Entity Too Large"
        case 0x4F: return "Unsupported Media Type"
        case 0x50: return "Internal Server Error"
        case 0x53: return "Service Unavailable"
        case 0x60: return "Database Full"
        case 0x61: return "Database Locked"
        default: return String(format: "Response 0x%02X", code)
        }
    }
}
