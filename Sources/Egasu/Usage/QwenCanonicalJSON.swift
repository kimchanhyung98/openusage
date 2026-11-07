import Foundation
import JavaScriptCore

/// 원장 해시의 UTF-16 키 순서와 JavaScript 숫자 표현 보존. 입력은 JSON 값으로만 전달.
struct QwenCanonicalJSON {
    private let function: JSValue

    init() throws {
        guard let context = JSContext(), let function = context.evaluateScript("""
        (function(source) {
            function encode(value) {
                if (Array.isArray(value)) return '[' + value.map(encode).join(',') + ']';
                if (value !== null && typeof value === 'object') {
                    return '{' + Object.keys(value).sort().map(function(key) {
                        return JSON.stringify(key) + ':' + encode(value[key]);
                    }).join(',') + '}';
                }
                return JSON.stringify(value);
            }
            return encode(JSON.parse(source));
        })
        """), !function.isUndefined else { throw CocoaError(.coderReadCorrupt) }
        self.function = function
    }

    func encode(_ object: Any) throws -> Data {
        let input = try JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed, .withoutEscapingSlashes])
        guard let result = function.call(withArguments: [String(decoding: input, as: UTF8.self)]), result.isString,
              let text = result.toString() else { throw CocoaError(.coderReadCorrupt) }
        return Data(text.utf8)
    }
}
