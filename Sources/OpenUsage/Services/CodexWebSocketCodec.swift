import CryptoKit
import Foundation

/// Unix socket용 RFC 6455 framing — 확장·압축 없이 text JSON만 허용.
struct CodexWebSocketCodec {
    enum Event { case ready, message(Data), ping(Data), closed }
    static let maximumBytes = 1_048_576
    let key: String
    private(set) var ready = false
    private var bytes: [UInt8] = []
    private var fragments: [UInt8]?

    init(key: String = Data((0..<16).map { _ in UInt8.random(in: .min ... .max) }).base64EncodedString()) {
        self.key = key
    }

    var handshake: Data {
        Data("GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: \(key)\r\nSec-WebSocket-Version: 13\r\n\r\n".utf8)
    }

    mutating func receive(_ data: Data) throws -> [Event] {
        bytes.append(contentsOf: data)
        var events: [Event] = []
        if !ready {
            guard let end = bytes.indices.first(where: { index in
                index + 4 <= bytes.count && bytes[index..<index + 4].elementsEqual([13, 10, 13, 10])
            }) else {
                guard bytes.count < 16_384 else { throw SoftLimitControlError.invalidResponse }
                return []
            }
            guard end < 16_384, let header = String(bytes: bytes[..<end], encoding: .utf8) else {
                throw SoftLimitControlError.invalidResponse
            }
            let lines = header.components(separatedBy: "\r\n")
            let expected = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
            var fields: [String: String] = [:]
            for line in lines.dropFirst() {
                let pair = line.split(separator: ":", maxSplits: 1)
                guard pair.count == 2 else { throw SoftLimitControlError.invalidResponse }
                let name = pair[0].lowercased()
                guard fields[name] == nil else { throw SoftLimitControlError.invalidResponse }
                fields[name] = pair[1].trimmingCharacters(in: .whitespaces)
            }
            guard lines.first?.split(separator: " ").prefix(2).map(String.init) == ["HTTP/1.1", "101"],
                  fields["upgrade"]?.lowercased() == "websocket",
                  fields["connection"]?.lowercased().split(separator: ",").contains(where: { $0.trimmingCharacters(in: .whitespaces) == "upgrade" }) == true,
                  fields["sec-websocket-accept"] == expected,
                  fields["sec-websocket-extensions"] == nil
            else { throw SoftLimitControlError.invalidResponse }
            bytes.removeFirst(end + 4)
            ready = true
            events.append(.ready)
        }
        while bytes.count >= 2 {
            let final = bytes[0] & 0x80 != 0
            let opcode = bytes[0] & 0x0f
            guard bytes[0] & 0x70 == 0, bytes[1] & 0x80 == 0 else { throw SoftLimitControlError.invalidResponse }
            var size = UInt64(bytes[1] & 0x7f)
            let extra = size == 126 ? 2 : size == 127 ? 8 : 0
            let headerSize = 2 + extra
            guard bytes.count >= headerSize else { break }
            if extra > 0 { size = bytes[2..<headerSize].reduce(0) { ($0 << 8) | UInt64($1) } }
            guard size <= Self.maximumBytes, opcode < 8 || (final && size <= 125) else { throw SoftLimitControlError.invalidResponse }
            guard bytes.count >= headerSize + Int(size) else { break }
            let payload = Array(bytes[headerSize..<headerSize + Int(size)])
            bytes.removeFirst(headerSize + Int(size))
            switch opcode {
            case 1:
                guard fragments == nil else { throw SoftLimitControlError.invalidResponse }
                if final { events.append(.message(Data(payload))) } else { fragments = payload }
            case 0:
                guard fragments != nil, fragments!.count + payload.count <= Self.maximumBytes else { throw SoftLimitControlError.invalidResponse }
                fragments!.append(contentsOf: payload)
                if final { events.append(.message(Data(fragments!))); fragments = nil }
            case 8: events.append(.closed)
            case 9: events.append(.ping(Data(payload)))
            case 10: break
            default: throw SoftLimitControlError.invalidResponse
            }
        }
        guard bytes.count <= Self.maximumBytes + 10 else { throw SoftLimitControlError.invalidResponse }
        return events
    }

    static func frame(_ data: Data, opcode: UInt8 = 1) throws -> Data {
        guard data.count <= maximumBytes else { throw SoftLimitControlError.invalidResponse }
        var result = Data([0x80 | opcode])
        if data.count < 126 { result.append(0x80 | UInt8(data.count)) }
        else if data.count <= 65_535 {
            result.append(contentsOf: [0xfe, UInt8(data.count >> 8), UInt8(data.count & 0xff)])
        } else {
            result.append(0xff)
            for shift in stride(from: 56, through: 0, by: -8) { result.append(UInt8((UInt64(data.count) >> shift) & 0xff)) }
        }
        let mask = (0..<4).map { _ in UInt8.random(in: .min ... .max) }
        result.append(contentsOf: mask)
        result.append(contentsOf: data.enumerated().map { $0.element ^ mask[$0.offset % 4] })
        return result
    }
}
