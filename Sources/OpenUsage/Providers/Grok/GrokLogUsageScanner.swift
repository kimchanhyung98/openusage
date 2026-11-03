import Foundation

/// Grok CLI의 로컬 로그에서 일별 token/cost 추정치 생성.
/// token 행(`shell.turn.inference_done`)에 model id가 없어 process·session별 모델 추적으로 귀속.
/// 출력은 Claude/Codex spend tile과 동일한 `DailyUsageSeries` 형태로 `SpendTileMapper`에 그대로 연결.
struct GrokLogUsageScanner: Sendable {
    var files: TextFileAccessing
    var environment: EnvironmentReading
    var homeDirectory: @Sendable () -> URL
    private let readFailureReporter: UsageLogReadFailureReporter
    private let numericFailureReporter = NumericFailureReporter()

    init(
        files: TextFileAccessing = LocalTextFileAccessor(),
        environment: EnvironmentReading = ProcessEnvironmentReader(),
        homeDirectory: @escaping @Sendable () -> URL = { FileManager.default.homeDirectoryForCurrentUser },
        readFailureWarning: UsageLogReadFailureReporter.Warning? = nil
    ) {
        self.files = files
        self.environment = environment
        self.homeDirectory = homeDirectory
        self.readFailureReporter = UsageLogReadFailureReporter(
            logTag: LogTag.plugin("grok"),
            warning: readFailureWarning
        )
    }

    /// `~/.grok/logs/unified.jsonl` — `$GROK_HOME` 설정 시 `$GROK_HOME/logs/unified.jsonl`.
    var logPath: String {
        if let raw = environment.value(for: "GROK_HOME")?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            return expandHome(raw).trimmingTrailingSlashes + "/logs/unified.jsonl"
        }
        return homeDirectory().appendingPathComponent(".grok/logs/unified.jsonl").path
    }

    /// 로그의 최근 `daysBack`일 스캔.
    /// 로그 부재·읽기 실패 시 `nil`(spend tile은 "No data" 렌더링), 존재하나 window 내 유효 행이 없으면 빈 `daily`.
    /// nonisolated async — `@MainActor` provider가 `await`하면 파일 읽기+parse가 main actor 밖에서 수행.
    func scan(daysBack: Int = 30, now: Date = Date(), pricing: ModelPricing) async -> LogUsageScan? {
        let path = logPath
        guard files.exists(path) else { return nil }
        let text: String
        do {
            text = try files.readText(path)
            await readFailureReporter.update(checkedPaths: [path], failingPaths: [])
        } catch {
            await readFailureReporter.update(checkedPaths: [path], failingPaths: [path])
            return nil
        }
        let scan = Self.parse(text, since: JSONLScanning.sinceDate(daysBack: daysBack, now: now),
                              pricing: pricing, reportNumericFailures: false)
        await numericFailureReporter.update(path: path, rejectedRows: scan.rejectedNumericRows)
        return scan
    }

    /// append-only 로그에 대한 시간순 단일 pass.
    /// 날짜와 무관하게 process·session의 모델 갱신 — 기간 경계 전 기록도 모델 귀속에 사용.
    static func parse(
        _ text: String, since: Date, pricing: ModelPricing, reportNumericFailures: Bool = true
    ) -> LogUsageScan {
        var modelByPID: [Int: String] = [:]
        var modelBySession: [SessionKey: String] = [:]
        var inheritedSessions: Set<SessionKey> = []
        var ambiguousPIDs: Set<Int> = []
        var accumulator = DailyUsageAccumulator()
        var rejectedMetadataRows = 0

        text.enumerateLines { line, _ in
            guard line.contains("inference_done") || line.contains("model")
                    || line.contains("process resource limits") else { return }
            guard let data = line.data(using: .utf8),
                  let object = ProviderParse.jsonObject(data),
                  let msg = object["msg"] as? String
            else { return }

            let ctx = object["ctx"] as? [String: Any] ?? [:]
            let pid = UsageLogNumbers.count(object["pid"]).flatMap { $0 > 0 ? $0 : nil }
            let sid = (object["sid"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            let session = pid.flatMap { pid in sid.map { SessionKey(pid: pid, sid: $0) } }

            // 시작 이벤트는 프로세스당 한 번 기록. PID 재사용 시 이전 실행의 모델 상태만 제거.
            if msg == "process resource limits", let pid {
                modelByPID.removeValue(forKey: pid)
                modelBySession = modelBySession.filter { $0.key.pid != pid }
                inheritedSessions = inheritedSessions.filter { $0.pid != pid }
                ambiguousPIDs.remove(pid)
                return
            }

            // 공식 child_model 이벤트에는 sid가 없음. 이후 기본 모델 갱신과 미확인 세션의 기본값 사용 중단.
            if msg == "subagent model resolved", sid == nil {
                if let pid { ambiguousPIDs.insert(pid) }
                return
            }

            if let model = modelID(msg: msg, ctx: ctx) {
                if let session {
                    modelBySession[session] = model
                } else if let pid, !ambiguousPIDs.contains(pid) {
                    modelByPID[pid] = model
                }
                return
            }

            guard msg == "shell.turn.inference_done" else { return }
            let model: String?
            if let session {
                if let sessionModel = modelBySession[session] {
                    model = sessionModel
                } else if inheritedSessions.contains(session) || !ambiguousPIDs.contains(session.pid) {
                    model = modelByPID[session.pid]
                    if model != nil { inheritedSessions.insert(session) }
                } else {
                    model = nil
                }
            } else {
                model = pid.flatMap { ambiguousPIDs.contains($0) ? nil : modelByPID[$0] }
            }
            guard ctx["prompt_tokens"] != nil,
                  !["prompt_tokens", "cached_prompt_tokens", "completion_tokens", "reasoning_tokens"].allSatisfy({
                      ctx[$0] == nil || ctx[$0] is NSNull
                  }),
                  let timestamp = (object["ts"] as? String).flatMap(OpenUsageISO8601.date(from:)),
                  timestamp >= since
            else { return }

            guard object["pid"] == nil || pid != nil,
                  let promptTokens = UsageLogNumbers.count(ctx["prompt_tokens"]),
                  let completion = UsageLogNumbers.count(ctx["completion_tokens"], missing: 0),
                  let reasoning = UsageLogNumbers.count(ctx["reasoning_tokens"], missing: 0),
                  let cached = UsageLogNumbers.count(ctx["cached_prompt_tokens"], missing: 0),
                  let output = UsageLogNumbers.sum(completion, reasoning),
                  let totalTokens = UsageLogNumbers.sum(promptTokens, output)
            else {
                accumulator.rejectNumericRow()
                return
            }
            // `cached_prompt_tokens`는 `prompt_tokens`의 부분집합 — total에서 prompt는 1회만 집계
            let cacheRead = min(cached, promptTokens)
            let inputNoCache = promptTokens - cacheRead

            let day = DailyUsageAccumulator.dayKey(from: timestamp)

            // 가격 산정 불가 행(model 미귀속 또는 가격 없는 model)은 모든 표시 합계에서 제외 — 실측 token과 혼합 시 수치 비일관
            guard let model else {
                if totalTokens > 0, session != nil || pid.map({ ambiguousPIDs.contains($0) }) == true {
                    rejectedMetadataRows += 1
                }
                return
            }
            let tokenBreakdown = TokenBreakdown(input: inputNoCache, cacheRead: cacheRead, output: output)
            guard let cost = pricing.estimatedCostDollars(model: model, tokens: tokenBreakdown) else {
                if totalTokens > 0 {
                    accumulator.addUnknownModel(day: day, model: model)
                }
                return
            }
            accumulator.add(day: day, tokens: totalTokens, cost: cost, model: model)
        }

        if rejectedMetadataRows > 0 {
            AppDiagnostics.record(
                .historyScan, result: .degraded, category: .decoding, providerID: "grok",
                localContext: "source=grok; unattributed_session_rows=\(rejectedMetadataRows)"
            )
        }
        return accumulator.build(
            source: "grok", reportNumericFailures: reportNumericFailures, rejectedMetadataRows: rejectedMetadataRows
        )
    }

    private struct SessionKey: Hashable {
        let pid: Int
        let sid: String
    }

    /// 같은 파일의 손상 행 수 증가만 보고; 정상 window로 돌아오면 복구 기록.
    private actor NumericFailureReporter {
        private var rejectedRowsByPath: [String: Int] = [:]

        func update(path: String, rejectedRows: Int) {
            let previous = rejectedRowsByPath[path] ?? 0
            if rejectedRows == 0 {
                rejectedRowsByPath.removeValue(forKey: path)
                if previous > 0 { AppDiagnostics.record(.historyScan, result: .success, providerID: "grok") }
            } else {
                rejectedRowsByPath[path] = rejectedRows
                if rejectedRows > previous { UsageLogNumbers.reportRejectedRows(rejectedRows - previous, source: "grok") }
            }
        }
    }

    /// 실제 모델 적용 이벤트의 model id. 검증 전 요청인 `model changed`는 제외.
    /// 세션 정보는 호출부에서 판별; 여기서는 모델 필드만 해석.
    private static func modelID(msg: String, ctx: [String: Any]) -> String? {
        let raw: Any?
        switch msg {
        case "model catalog: notifying clients":
            raw = ctx["current_model_id"]
        case "backend_search: model switch":
            raw = ctx["new_model"] ?? ctx["model"] ?? ctx["current_model_id"] ?? ctx["model_id"]
        case "subagent model resolved":
            raw = ctx["child_model"] ?? ctx["model_id"] ?? ctx["model"]
        default:
            return nil
        }
        guard let model = (raw as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !model.isEmpty
        else { return nil }
        return model
    }

}
