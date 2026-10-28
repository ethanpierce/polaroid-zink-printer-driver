import CoreGraphics
import XCTest
@testable import ZipPrinterKit

final class OBEXTests: XCTestCase {
    func testConnectPacket() {
        XCTAssertEqual([UInt8](OBEX.connect(maxPacketLength: 0x1800)), [0x80, 0x00, 0x07, 0x10, 0x00, 0x18, 0x00])
    }

    func testDisconnectPacket() {
        XCTAssertEqual([UInt8](OBEX.disconnect()), [0x81, 0x00, 0x03])
    }

    func testParsesConnectResponseCapturedFromAPolaroidZip() {
        var buffer = Data([0xA0, 0x00, 0x07, 0x10, 0x00, 0xFF, 0x00, 0xA0])
        let response = OBEX.takeResponse(from: &buffer)
        XCTAssertEqual(response?.isSuccess, true)
        XCTAssertEqual(response?.maxPacketLength, 0xFF00)
        XCTAssertEqual([UInt8](buffer), [0xA0], "leftover bytes stay in the buffer")
    }

    func testWaitsForCompletePacket() {
        var buffer = Data([0xA0, 0x00, 0x07, 0x10])
        XCTAssertNil(OBEX.takeResponse(from: &buffer))
        XCTAssertEqual(buffer.count, 4)
    }

    func testNameHeaderIsNullTerminatedUTF16() {
        XCTAssertEqual([UInt8](OBEX.unicodeHeader(.name, "a.jpg")),
                       [0x01, 0x00, 0x0F, 0, 0x61, 0, 0x2E, 0, 0x6A, 0, 0x70, 0, 0x67, 0, 0])
    }

    func testPutPacketsReassembleBody() {
        let body = Data((0..<10_000).map { UInt8($0 & 0xFF) })
        let packets = OBEX.putPackets(name: "photo.jpg", type: "image/jpeg", body: body, maxPacketLength: 1024)

        XCTAssertGreaterThan(packets.count, 1)
        XCTAssertTrue(packets.allSatisfy { $0.count <= 1024 })
        XCTAssertTrue(packets.dropLast().allSatisfy { $0.first == OBEX.Opcode.put.rawValue })
        XCTAssertEqual(packets.last?.first, OBEX.Opcode.putFinal.rawValue)

        var reassembled = Data()
        var sawLength: UInt32?
        for packet in packets {
            XCTAssertEqual(Int(packet[1]) << 8 | Int(packet[2]), packet.count)
            var i = 3
            while i < packet.count {
                let id = packet[i]
                if id == OBEX.HeaderID.length.rawValue {
                    sawLength = UInt32(packet[i + 1]) << 24 | UInt32(packet[i + 2]) << 16 | UInt32(packet[i + 3]) << 8 | UInt32(packet[i + 4])
                    i += 5
                    continue
                }
                let length = Int(packet[i + 1]) << 8 | Int(packet[i + 2])
                if id == OBEX.HeaderID.body.rawValue || id == OBEX.HeaderID.endOfBody.rawValue {
                    reassembled.append(packet[(i + 3)..<(i + length)])
                }
                i += length
            }
        }
        XCTAssertEqual(reassembled, body)
        XCTAssertEqual(sawLength, 10_000)
    }

    func testSmallBodyIsOnePutFinal() {
        let packets = OBEX.putPackets(name: "x.jpg", type: "image/jpeg", body: Data([1, 2, 3]), maxPacketLength: 4096)
        XCTAssertEqual(packets.count, 1)
        XCTAssertEqual(packets[0].first, OBEX.Opcode.putFinal.rawValue)
    }
}

final class PrintImageTests: XCTestCase {
    private func solidImage(width: Int, height: Int) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }

    func testRenderMatchesPrinterSize() {
        let out = PrintImage.render(solidImage(width: 4000, height: 3000))!
        XCTAssertEqual(out.width, Int(PrintImage.size.width))
        XCTAssertEqual(out.height, Int(PrintImage.size.height))
    }

    func testRotateSwapsDimensions() {
        let out = PrintImage.rotate(solidImage(width: 30, height: 20), quarterTurns: 1)!
        XCTAssertEqual(out.width, 20)
        XCTAssertEqual(out.height, 30)
    }

    func testJPEGEncodes() {
        let data = PrintImage.jpegData(PrintImage.render(solidImage(width: 100, height: 150))!)!
        XCTAssertLessThanOrEqual(data.count, PrintImage.maxFileSize)
        XCTAssertEqual([UInt8](data.prefix(2)), [0xFF, 0xD8])
    }
}
