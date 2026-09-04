import Foundation

struct TerminalOutputSanitizer: Sendable {
    private enum State: Sendable {
        case text
        case escape
        case escapeIntermediate
        case controlSequence
        case operatingSystemCommand
        case operatingSystemCommandEscape
        case stringControl
        case stringControlEscape
    }

    private var state = State.text

    static func sanitize(_ input: String) -> String {
        var sanitizer = Self()
        return sanitizer.append(input) + sanitizer.finish()
    }

    mutating func append(_ input: String) -> String {
        var result = ""
        result.reserveCapacity(input.utf8.count)

        for scalar in input.unicodeScalars {
            let value = scalar.value
            switch state {
            case .text:
                switch value {
                case 0x1B:
                    state = .escape
                case 0x9B:
                    state = .controlSequence
                case 0x9D:
                    state = .operatingSystemCommand
                case 0x90, 0x98, 0x9E, 0x9F:
                    state = .stringControl
                case 0x09, 0x0A:
                    result.unicodeScalars.append(scalar)
                case 0x00 ... 0x1F, 0x7F ... 0x9F:
                    break
                default:
                    result.unicodeScalars.append(scalar)
                }
            case .escape:
                switch value {
                case 0x1B:
                    break
                case 0x5B:
                    state = .controlSequence
                case 0x5D:
                    state = .operatingSystemCommand
                case 0x50, 0x58, 0x5E, 0x5F:
                    state = .stringControl
                case 0x20 ... 0x2F:
                    state = .escapeIntermediate
                default:
                    state = .text
                }
            case .escapeIntermediate:
                if value == 0x1B {
                    state = .escape
                } else if (0x30 ... 0x7E).contains(value) {
                    state = .text
                }
            case .controlSequence:
                if value == 0x1B {
                    state = .escape
                } else if value == 0x18 || value == 0x1A || (0x40 ... 0x7E).contains(value) {
                    state = .text
                }
            case .operatingSystemCommand:
                if value == 0x07 || value == 0x9C {
                    state = .text
                } else if value == 0x1B {
                    state = .operatingSystemCommandEscape
                }
            case .operatingSystemCommandEscape:
                if value == 0x5C || value == 0x9C {
                    state = .text
                } else if value != 0x1B {
                    state = .operatingSystemCommand
                }
            case .stringControl:
                if value == 0x9C {
                    state = .text
                } else if value == 0x1B {
                    state = .stringControlEscape
                }
            case .stringControlEscape:
                if value == 0x5C || value == 0x9C {
                    state = .text
                } else if value != 0x1B {
                    state = .stringControl
                }
            }
        }
        return result
    }

    mutating func finish() -> String {
        state = .text
        return ""
    }
}

enum ProcessOutputChannel: Sendable {
    case stdout
    case stderr
}

/// 두 pipe의 decode·sanitize·callback 순서를 직렬화하고 보존 output을 UTF-8 byte 상한 내 유지.
final class StreamingProcessOutput: @unchecked Sendable {
    private let lock = NSLock()
    private let deliveryLock = NSLock()
    private let headLimit: Int
    private let tailLimit: Int
    private let onOutput: @Sendable (String) -> Void
    private var headData = Data()
    private var tailData = Data()
    private var headClosed = false
    private var stdoutDecoder = IncrementalUTF8Decoder()
    private var stderrDecoder = IncrementalUTF8Decoder()
    private var stdoutSanitizer = TerminalOutputSanitizer()
    private var stderrSanitizer = TerminalOutputSanitizer()

    init(limit: Int, onOutput: @escaping @Sendable (String) -> Void) {
        self.headLimit = limit / 2 + limit % 2
        self.tailLimit = limit / 2
        self.onOutput = onOutput
    }

    func append(_ data: Data, channel: ProcessOutputChannel) {
        lock.lock()
        let sanitized: String
        switch channel {
        case .stdout:
            sanitized = stdoutSanitizer.append(stdoutDecoder.append(data))
        case .stderr:
            sanitized = stderrSanitizer.append(stderrDecoder.append(data))
        }
        appendBounded(sanitized)
        deliver(sanitized)
    }

    func finish(channel: ProcessOutputChannel) {
        lock.lock()
        let sanitized: String
        switch channel {
        case .stdout:
            sanitized = stdoutSanitizer.append(stdoutDecoder.finish()) + stdoutSanitizer.finish()
        case .stderr:
            sanitized = stderrSanitizer.append(stderrDecoder.finish()) + stderrSanitizer.finish()
        }
        appendBounded(sanitized)
        deliver(sanitized)
    }

    var value: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: headData + tailData, as: UTF8.self)
    }

    private func appendBounded(_ text: String) {
        guard !text.isEmpty else { return }
        var incoming = Data(text.utf8)

        if !headClosed, headData.count < headLimit {
            let remaining = headLimit - headData.count
            let prefixLength = Self.validUTF8PrefixLength(of: incoming, maximumBytes: remaining)
            headData.append(incoming.prefix(prefixLength))
            incoming.removeFirst(prefixLength)
            headClosed = !incoming.isEmpty
        }

        guard tailLimit > 0, !incoming.isEmpty else { return }
        if incoming.count >= tailLimit {
            tailData = Self.validUTF8Suffix(of: incoming, maximumBytes: tailLimit)
            return
        }

        let previousLimit = tailLimit - incoming.count
        if tailData.count > previousLimit {
            tailData = Self.validUTF8Suffix(of: tailData, maximumBytes: previousLimit)
        }
        tailData.append(incoming)
    }

    /// output 순서를 예약한 뒤 accumulator lock 밖에서 외부 callback 실행.
    private func deliver(_ text: String) {
        guard !text.isEmpty else {
            lock.unlock()
            return
        }
        deliveryLock.lock()
        lock.unlock()
        onOutput(text)
        deliveryLock.unlock()
    }

    private static func validUTF8PrefixLength(of data: Data, maximumBytes: Int) -> Int {
        guard maximumBytes > 0, !data.isEmpty else { return 0 }
        guard data.count > maximumBytes else { return data.count }

        var end = data.index(data.startIndex, offsetBy: maximumBytes)
        while end > data.startIndex, data[end] & 0xC0 == 0x80 {
            end = data.index(before: end)
        }
        return data.distance(from: data.startIndex, to: end)
    }

    private static func validUTF8Suffix(of data: Data, maximumBytes: Int) -> Data {
        guard maximumBytes > 0, !data.isEmpty else { return Data() }
        guard data.count > maximumBytes else { return data }

        var start = data.index(data.endIndex, offsetBy: -maximumBytes)
        while start < data.endIndex, data[start] & 0xC0 == 0x80 {
            start = data.index(after: start)
        }
        return Data(data[start...])
    }
}

private struct IncrementalUTF8Decoder: Sendable {
    private var pending = Data()

    mutating func append(_ data: Data) -> String {
        var combined = Data()
        combined.reserveCapacity(pending.count + data.count)
        combined.append(pending)
        combined.append(data)

        let suffixLength = Self.incompleteSuffixLength(combined)
        let completeCount = combined.count - suffixLength
        pending = suffixLength == 0 ? Data() : Data(combined.suffix(suffixLength))
        return String(decoding: combined.prefix(completeCount), as: UTF8.self)
    }

    mutating func finish() -> String {
        defer { pending.removeAll(keepingCapacity: false) }
        return String(decoding: pending, as: UTF8.self)
    }

    private static func incompleteSuffixLength(_ data: Data) -> Int {
        guard let last = data.last else { return 0 }
        if last < 0x80 { return 0 }

        var continuationCount = 0
        var index = data.index(before: data.endIndex)
        while data[index] & 0xC0 == 0x80 {
            continuationCount += 1
            guard index > data.startIndex, continuationCount < 4 else { return 0 }
            index = data.index(before: index)
        }

        let expectedLength: Int
        switch data[index] {
        case 0xC2 ... 0xDF:
            expectedLength = 2
        case 0xE0 ... 0xEF:
            expectedLength = 3
        case 0xF0 ... 0xF4:
            expectedLength = 4
        default:
            return 0
        }

        let availableLength = continuationCount + 1
        return availableLength < expectedLength ? availableLength : 0
    }
}
