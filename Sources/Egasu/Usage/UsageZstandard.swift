import Foundation
import libzstd

enum UsageZstandard {
    /// 연결된 프레임 전체를 복원. 잘린 프레임·크기 초과를 정상 빈 기록으로 취급하지 않음.
    static func decode(_ data: Data, maximumBytes: Int = 256 * 1024 * 1024) throws -> Data {
        try decompress(data, maximumBytes: maximumBytes, allowIncompleteFinalFrame: false).data
    }

    /// DSH의 작성 중 마지막 프레임만 허용. 완전한 프레임의 압축·checksum 오류는 유지.
    static func decodePrefix(_ data: Data, maximumBytes: Int = 256 * 1024 * 1024) throws -> (data: Data, incomplete: Bool) {
        try decompress(data, maximumBytes: maximumBytes, allowIncompleteFinalFrame: true)
    }

    private static func decompress(
        _ data: Data, maximumBytes: Int, allowIncompleteFinalFrame: Bool
    ) throws -> (data: Data, incomplete: Bool) {
        guard let stream = ZSTD_createDStream() else { throw CocoaError(.coderReadCorrupt) }
        defer { ZSTD_freeDStream(stream) }
        guard ZSTD_isError(ZSTD_initDStream(stream)) == 0 else { throw CocoaError(.coderReadCorrupt) }
        return try data.withUnsafeBytes { bytes in
            var input = ZSTD_inBuffer(src: bytes.baseAddress, size: bytes.count, pos: 0)
            var result = Data()
            var buffer = [UInt8](repeating: 0, count: Int(ZSTD_DStreamOutSize()))
            var remaining = 1
            while input.pos < input.size || remaining != 0 {
                try Task.checkCancellation()
                let previous = input.pos
                let produced = try buffer.withUnsafeMutableBytes { outputBytes in
                    var output = ZSTD_outBuffer(dst: outputBytes.baseAddress, size: outputBytes.count, pos: 0)
                    remaining = ZSTD_decompressStream(stream, &output, &input)
                    guard ZSTD_isError(remaining) == 0, output.pos <= maximumBytes - result.count else {
                        throw CocoaError(.coderReadCorrupt)
                    }
                    result.append(contentsOf: outputBytes.prefix(output.pos))
                    return output.pos
                }
                if produced == 0 && input.pos == previous {
                    guard allowIncompleteFinalFrame, input.pos == input.size, remaining != 0 else {
                        throw CocoaError(.coderReadCorrupt)
                    }
                    return (result, true)
                }
            }
            return (result, false)
        }
    }

    static func decodeIfNeeded(_ data: Data) throws -> Data {
        let magic = Array(data.prefix(4))
        let skippable = magic.count == 4 && (0x50...0x5F).contains(magic[0]) && Array(magic.dropFirst()) == [0x2A, 0x4D, 0x18]
        return magic == [0x28, 0xB5, 0x2F, 0xFD] || skippable ? try decode(data) : data
    }
}
