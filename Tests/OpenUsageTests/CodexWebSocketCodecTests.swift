import XCTest
@testable import OpenUsage

final class CodexWebSocketCodecTests: XCTestCase {
    private let handshake = Data("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n\r\n".utf8)

    func testSplitHandshakeAndFragmentedTextWithInterleavedPing() throws {
        var codec = CodexWebSocketCodec(key: "dGhlIHNhbXBsZSBub25jZQ==")
        XCTAssertTrue(try codec.receive(handshake.prefix(20)).isEmpty)
        let ready = try codec.receive(handshake.dropFirst(20))
        XCTAssertEqual(ready.count, 1)
        XCTAssertTrue(codec.ready)
        XCTAssertTrue(try codec.receive(Data([0x01, 2, 123, 34])).isEmpty)
        let events = try codec.receive(Data([0x89, 1, 65, 0x80, 4, 97, 34, 58, 49]))
        XCTAssertEqual(events.count, 2)
        if case .ping(let data) = events[0] { XCTAssertEqual(data, Data([65])) } else { XCTFail() }
        if case .message(let data) = events[1] { XCTAssertEqual(String(decoding: data, as: UTF8.self), "{\"a\":1") } else { XCTFail() }
    }

    func testRejectsWrongHandshakeMaskedServerFramesAndOversizedPayloads() throws {
        var wrong = CodexWebSocketCodec(key: "different")
        XCTAssertThrowsError(try wrong.receive(handshake))
        for payload in [Data([0x81, 0x80]), Data([0x81, 0x7f, 0, 0, 0, 0, 1, 0, 0, 0]), Data([0x09, 0]), Data([0xc1, 0])] {
            var codec = CodexWebSocketCodec(key: "dGhlIHNhbXBsZSBub25jZQ==")
            _ = try codec.receive(handshake)
            XCTAssertThrowsError(try codec.receive(payload))
        }
    }

    func testClientMasksEveryFrameAndEncodesAllLengthWidths() throws {
        for count in [0, 125, 126, 65_535, 65_536] {
            let input = Data(repeating: 42, count: count)
            let frame = try CodexWebSocketCodec.frame(input)
            XCTAssertEqual(frame[0], 0x81)
            XCTAssertNotEqual(frame[1] & 0x80, 0)
            let offset = count < 126 ? 2 : count <= 65_535 ? 4 : 10
            let mask = Array(frame[offset..<offset + 4])
            let unmasked = Data(frame.dropFirst(offset + 4).enumerated().map { $0.element ^ mask[$0.offset % 4] })
            XCTAssertEqual(unmasked, input)
        }
    }

    func testReceivesPartialAndCoalescedMessages() throws {
        var codec = CodexWebSocketCodec(key: "dGhlIHNhbXBsZSBub25jZQ==")
        _ = try codec.receive(handshake)
        XCTAssertTrue(try codec.receive(Data([0x81, 2, 123])).isEmpty)
        let events = try codec.receive(Data([125, 0x81, 2, 91, 93]))
        XCTAssertEqual(events.count, 2)
        if case .message(let data) = events[0] { XCTAssertEqual(data, Data("{}".utf8)) } else { XCTFail() }
        if case .message(let data) = events[1] { XCTAssertEqual(data, Data("[]".utf8)) } else { XCTFail() }
    }
}
