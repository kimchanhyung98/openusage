import Foundation

/// Grok CLI의 로컬 로그에서 일별 token/cost 추정치 생성.
/// token 행(`shell.turn.inference_done`)에 model id가 없어 CLI process(`pid`)별 current model 추적으로 귀속.
/// 출력은 Claude/Codex spend tile과 동일한 `DailyUsageSeries` 형태로 `SpendTileMapper`에 그대로 연결.
struct GrokLogUsageScanner: Sendable {
    var files: TextFileAccessing
    var environment: EnvironmentReading
    var homeDirectory: @Sendable () -> URL
    private let readFailureReporter: UsageLogReadFailureReporter

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
        guard files.exists(path) else {
            await readFailureReporter.update(checkedPaths: [path], failingPaths: [])
            return nil
        }
        let text: String
        do {
            text = try files.readText(path)
            await readFailureReporter.update(checkedPaths: [path], failingPaths: [])
        } catch {
            await readFailureReporter.update(checkedPaths: [path], failingPaths: [path])
            return nil
        }
        return Self.parse(text, since: JSONLScanning.sinceDate(daysBack: daysBack, now: now), pricing: pricing)
    }

    /// append-only 로그에 대한 시간순 단일 pass.
    /// model 이벤트는 날짜와 무관하게 `pid`별 current model 갱신 — `since` 경계에 걸친 session도 귀속 유지.
    /// window 내 `inference_done` 행은 해당 `pid`의 current model로 가격 산정 후 로컬 달력일로 bucket 분류.
    static func parse(_ text: String, since: Date, pricing: ModelPricing) -> LogUsageScan {
        var modelByPID: [Int: String] = [:]
        var accumulator = DailyUsageAccumulator()

        text.enumerateLines { line, _ in
            // JSON parse 전 저비용 pre-filter — token 행은 "inference_done", 모든 model 이벤트의 `msg`는 "model" 포함
            guard line.contains("inference_done") || line.contains("model") else { return }
            guard let data = line.data(using: .utf8),
                  let object = ProviderParse.jsonObject(data),
                  let msg = object["msg"] as? String
            else { return }

            let ctx = object["ctx"] as? [String: Any] ?? [:]
            let pid = ProviderParse.number(object["pid"]).map { Int($0) }

            if let model = modelID(msg: msg, ctx: ctx) {
                if let pid { modelByPID[pid] = model }
                return
            }

            guard msg == "shell.turn.inference_done",
                  let promptTokens = ProviderParse.number(ctx["prompt_tokens"]),
                  let timestamp = (object["ts"] as? String).flatMap(OpenUsageISO8601.date(from:)),
                  timestamp >= since
            else { return }

            let completion = Int(ProviderParse.number(ctx["completion_tokens"]) ?? 0)
            let reasoning = Int(ProviderParse.number(ctx["reasoning_tokens"]) ?? 0)
            // `cached_prompt_tokens`는 `prompt_tokens`의 부분집합 — total에서 prompt는 1회만 집계
            let cached = min(ProviderParse.number(ctx["cached_prompt_tokens"]) ?? 0, promptTokens)
            let cacheRead = Int(cached)
            let inputNoCache = Int(max(0, promptTokens - cached))
            let output = completion + reasoning

            let day = DailyUsageAccumulator.dayKey(from: timestamp)
            let totalTokens = Int(promptTokens) + output

            // 가격 산정 불가 행(model 미귀속 또는 가격 없는 model)은 모든 표시 합계에서 제외 — 실측 token과 혼합 시 수치 비일관
            // 가격 없는 model 이름만 `unknownModelsByDay`(warning triangle)로 노출, 미귀속 행은 알릴 이름 자체가 없음
            guard let model = pid.flatMap({ modelByPID[$0] }) else { return }
            let tokenBreakdown = TokenBreakdown(input: inputNoCache, cacheRead: cacheRead, output: output)
            guard let cost = pricing.estimatedCostDollars(model: model, tokens: tokenBreakdown) else {
                if totalTokens > 0 {
                    accumulator.addUnknownModel(day: day, model: model)
                }
                return
            }
            accumulator.add(day: day, tokens: totalTokens, cost: cost, model: model)
        }

        return accumulator.build()
    }

    /// model 변경 이벤트가 실어 나르는 model id, 그 외 라인은 `nil`.
    /// Grok CLI는 여러 이벤트 shape로 active model을 알림 — 모두 `pid` 기준.
    private static func modelID(msg: String, ctx: [String: Any]) -> String? {
        let raw: Any?
        switch msg {
        case "model changed":
            raw = ctx["model"]
        case "model catalog: notifying clients":
            raw = ctx["current_model_id"]
        case "backend_search: model switch":
            raw = ctx["model"] ?? ctx["current_model_id"] ?? ctx["model_id"]
        case "subagent model resolved":
            raw = ctx["model_id"] ?? ctx["model"]
        default:
            return nil
        }
        guard let model = (raw as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !model.isEmpty
        else { return nil }
        return model
    }

}
