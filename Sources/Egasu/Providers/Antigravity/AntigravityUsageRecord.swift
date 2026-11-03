import Foundation

struct AntigravityUsageRecord: Sendable {
    struct Identity: Hashable, Sendable {
        var cascade: String
        var trajectory: String
        var step: UInt32
    }

    var identity: Identity
    var date: Date
    var model: String
    var tokens: TokenBreakdown

    struct Step {
        var date: Date?
        var tokens: TokenBreakdown?
        var source: Source?
    }

    struct Source {
        var cascade = ""
        var trajectory = ""
        var step: UInt32 = 0
        var metadataIndex: UInt32 = 0
    }

    static func parseStep(_ bytes: UnsafeRawBufferPointer) throws -> Step {
        var step = Step()
        try AntigravityProtobuf.fields(bytes) { field in
            switch field.number {
            case 1: step.date = try timestamp(field.bytes())
            case 9: step.tokens = try usage(field.bytes())
            case 20: step.source = try source(field.bytes())
            default: break
            }
        }
        return step
    }

    /// 대화 본문·프롬프트는 디코딩하지 않고 보고된 모델 문자열만 추출.
    static func parseModel(_ bytes: UnsafeRawBufferPointer) throws -> String {
        var response: String?
        var full: String?
        var display: String?
        try AntigravityProtobuf.fields(bytes) { field in
            guard field.number == 1 else { return }
            try AntigravityProtobuf.fields(field.bytes()) { chat in
                switch chat.number {
                case 19: response = try chat.string()
                case 21: display = try chat.string()
                case 22: full = try chat.string()
                default: break
                }
            }
        }
        guard let model = [response, full, display].compactMap({ $0 })
            .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }).first(where: { !$0.isEmpty })
        else { throw AntigravityUsageScanError.unreadable }
        return model == "gemini-3.8-flash-n" ? "gemini-3.8-flash" : model
    }

    private static func usage(_ bytes: UnsafeRawBufferPointer) throws -> TokenBreakdown {
        var input = 0
        var output = 0
        var write = 0
        var read = 0
        try AntigravityProtobuf.fields(bytes) { field in
            guard (2...5).contains(field.number) else { return }
            guard let count = Int(exactly: try field.integer()) else {
                throw AntigravityUsageScanError.unreadable
            }
            switch field.number {
            case 2: input = count
            case 3: output = count
            case 4: write = count
            default: read = count
            }
        }
        guard UsageLogNumbers.sum(input, output, write, read) != nil else {
            throw AntigravityUsageScanError.unreadable
        }
        // input은 비캐시 입력. output은 thinking·response를 이미 포함한 합계.
        return TokenBreakdown(input: input, cacheWrite5m: write, cacheRead: read, output: output)
    }

    private static func timestamp(_ bytes: UnsafeRawBufferPointer) throws -> Date {
        var seconds: Int64 = 0
        var nanos: UInt64 = 0
        try AntigravityProtobuf.fields(bytes) { field in
            switch field.number {
            case 1: seconds = Int64(bitPattern: try field.integer())
            case 2: nanos = try field.integer()
            default: break
            }
        }
        guard (-62_135_596_800...253_402_300_799).contains(seconds), nanos < 1_000_000_000 else {
            throw AntigravityUsageScanError.unreadable
        }
        return Date(timeIntervalSince1970: Double(seconds) + Double(nanos) / 1_000_000_000)
    }

    private static func source(_ bytes: UnsafeRawBufferPointer) throws -> Source {
        var result = Source()
        try AntigravityProtobuf.fields(bytes) { field in
            switch field.number {
            case 1: result.trajectory = try field.string()
            case 4: result.cascade = try field.string()
            case 2, 3:
                guard let index = UInt32(exactly: try field.integer()) else {
                    throw AntigravityUsageScanError.unreadable
                }
                if field.number == 2 { result.step = index } else { result.metadataIndex = index }
            default: break
            }
        }
        return result
    }
}

/// SQLite 소유 blob의 범위를 빌려 읽으며 미사용 필드는 길이만큼 건너뜀.
private enum AntigravityProtobuf {
    struct Field {
        var number: Int
        var value: Value

        enum Value {
            case integer(UInt64)
            case bytes(UnsafeRawBufferPointer)
            case fixed
        }

        func integer() throws -> UInt64 {
            guard case let .integer(value) = value else { throw AntigravityUsageScanError.unreadable }
            return value
        }

        func bytes() throws -> UnsafeRawBufferPointer {
            guard case let .bytes(value) = value else { throw AntigravityUsageScanError.unreadable }
            return value
        }

        func string() throws -> String {
            guard let value = String(bytes: try bytes(), encoding: .utf8) else {
                throw AntigravityUsageScanError.unreadable
            }
            return value
        }
    }

    static func fields(_ data: UnsafeRawBufferPointer, consume: (Field) throws -> Void) throws {
        var offset = 0
        while offset < data.count {
            let tag = try varint(data, offset: &offset)
            let number = tag >> 3
            guard number > 0, number <= 536_870_911 else { throw AntigravityUsageScanError.unreadable }
            let value: Field.Value
            switch tag & 7 {
            case 0: value = .integer(try varint(data, offset: &offset))
            case 2:
                guard let size = Int(exactly: try varint(data, offset: &offset)), size <= data.count - offset else {
                    throw AntigravityUsageScanError.unreadable
                }
                value = .bytes(UnsafeRawBufferPointer(rebasing: data[offset..<(offset + size)]))
                offset += size
            case 1, 5:
                let size = (tag & 7) == 1 ? 8 : 4
                guard size <= data.count - offset else { throw AntigravityUsageScanError.unreadable }
                offset += size
                value = .fixed
            default: throw AntigravityUsageScanError.unreadable
            }
            try consume(Field(number: Int(number), value: value))
        }
    }

    private static func varint(_ data: UnsafeRawBufferPointer, offset: inout Int) throws -> UInt64 {
        var result: UInt64 = 0
        for index in 0..<10 {
            guard offset < data.count else { throw AntigravityUsageScanError.unreadable }
            let byte = data[offset]
            offset += 1
            guard index < 9 || byte <= 1 else { throw AntigravityUsageScanError.unreadable }
            result |= UInt64(byte & 0x7F) << (index * 7)
            if byte & 0x80 == 0 { return result }
        }
        throw AntigravityUsageScanError.unreadable
    }
}
