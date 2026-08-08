import Foundation

/// 따옴표 필드(내장 콤마·개행·escaped 따옴표 `""` → `"`)를 지원하는 최소 CSV parser. header 행으로 key된 record를 streaming. `../cursorcat/Sources/CursorCat/API/CSVParser.swift`에서 개작.
enum CursorCSVParser {
    struct Summary: Equatable {
        var isStructurallyComplete: Bool
        var rejectedRecordCount: Int
    }

    /// record streaming + 구조적 실패와 header와 폭이 다른 행 보고.
    /// `header`는 normalize된 header를 1회 노출 — boundary mapper가 전체 export 재파싱 없이 필수 schema 검증 가능.
    @discardableResult
    static func forEachRecord(
        in text: String,
        header onHeader: (([String]) -> Void)? = nil,
        _ body: ([String: String]) -> Void
    ) -> Summary {
        var header: [String]?
        var rejectedRecordCount = 0
        let isStructurallyComplete = forEachRow(in: text) { row in
            guard let keys = header else {
                let normalized = row.map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}")))
                }
                header = normalized
                onHeader?(normalized)
                return
            }

            guard row.count == keys.count else {
                rejectedRecordCount += 1
                return
            }
            var dict: [String: String] = [:]
            for (i, key) in keys.enumerated() {
                dict[key] = row[i]
            }
            body(dict)
        }
        return Summary(
            isStructurallyComplete: isStructurallyComplete,
            rejectedRecordCount: rejectedRecordCount
        )
    }

    private static func forEachRow(in text: String, _ body: ([String]) -> Void) -> Bool {
        enum FieldState: Equatable {
            case start
            case unquoted
            case quoted
            case quoteClosed
        }

        var field = ""
        var row: [String] = []
        var state = FieldState.start
        var i = text.startIndex

        while i < text.endIndex {
            let c = text[i]

            if state == .quoted {
                if c == "\"" {
                    let next = text.index(after: i)
                    if next < text.endIndex && text[next] == "\"" {
                        field.append("\"")
                        i = text.index(after: next)
                        continue
                    } else {
                        state = .quoteClosed
                        i = next
                        continue
                    }
                } else {
                    field.append(c)
                    i = text.index(after: i)
                    continue
                }
            }

            switch state {
            case .start:
                switch c {
                case "\"":
                    state = .quoted
                case ",":
                    row.append(field)
                    field = ""
                case "\r", "\n", "\r\n":
                    row.append(field)
                    emit(row, body)
                    row = []
                    field = ""
                default:
                    field.append(c)
                    state = .unquoted
                }
            case .unquoted:
                switch c {
                case "\"":
                    return false
                case ",":
                    row.append(field)
                    field = ""
                    state = .start
                case "\r", "\n", "\r\n":
                    row.append(field)
                    emit(row, body)
                    row = []
                    field = ""
                    state = .start
                default:
                    field.append(c)
                }
            case .quoteClosed:
                switch c {
                case ",":
                    row.append(field)
                    field = ""
                    state = .start
                case "\r", "\n", "\r\n":
                    row.append(field)
                    emit(row, body)
                    row = []
                    field = ""
                    state = .start
                default:
                    return false
                }
            case .quoted:
                preconditionFailure("quoted fields are handled before the state switch")
            }
            i = text.index(after: i)
        }

        guard state != .quoted else { return false }
        // 끝의 부분 행 처리.
        if !field.isEmpty || !row.isEmpty || state == .quoteClosed {
            row.append(field)
            emit(row, body)
        }
        return true
    }

    private static func emit(_ row: [String], _ body: ([String]) -> Void) {
        if !row.allSatisfy(\.isEmpty) {
            body(row)
        }
    }
}
