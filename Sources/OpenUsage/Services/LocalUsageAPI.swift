import Foundation

/// 읽기 전용 로컬 usage API의 라우팅과 JSON 변환 — pure 함수로 유지하고 `LocalUsageServer`는 transport만 담당.
/// `/v1/usage/:token`은 배열 반환, 단일 token 라우트는 plain string 매칭(정확한 카드 id 또는 family id) — 상태 해석 금지.
enum LocalUsageAPI {
    /// 요청 1건에 필요한 전부 — MainActor store에서 Sendable 값으로 캡처.
    struct State: Sendable {
        /// collection endpoint가 서빙하는 provider ID — enablement 필터 적용, 사용자 순서.
        var enabledOrderedIDs: [String]
        /// registry가 아는 모든 provider — 비활성 provider도 단일 조회 가능.
        var knownIDs: Set<String>
        /// 두 라우트가 공유하는 렌더링된 snapshot 집합 — `/v1/usage`와 `/v1/limits`는 wire format projection만 상이.
        var snapshots: [String: ProviderSnapshot]
        /// 안정적 limits 계약에 명시적으로 opt-in한 descriptor만 포함.
        var limitDescriptors: [String: [WidgetDescriptor]] = [:]
        var errors: [String: String] = [:]
        var generatedAt = Date()

        /// 요청 token이 지칭하는 모든 known 카드 — 정확한 카드 id, 또는 family 전체를 지칭하는 family id.
        /// 의도된 pure string 매칭 — 로그인 계정·enablement 등 runtime 상태 비의존. 정렬 출력, 빈 결과는 404.
        func matchingCardIDs(for token: String) -> [String] {
            knownIDs.filter { $0 == token || ProviderAccountID.family(of: $0) == token }.sorted()
        }

        /// 신뢰된 로컬 CLI용 snapshot에 live 계정 label을 입힌 복사본.
        /// snapshot 자체는 항상 파생 이름 저장 — label의 cache·iCloud 영속 금지. 항목 없는 카드는 기존 이름 유지.
        func resolvingDisplayNames(_ titles: [String: String]) -> State {
            guard !titles.isEmpty else { return self }
            var state = self
            state.snapshots = snapshots.mapValues { snapshot in
                guard let title = titles[snapshot.providerID] else { return snapshot }
                var snapshot = snapshot
                snapshot.displayName = title
                return snapshot
            }
            return state
        }

        /// wildcard CORS 응답용 복사본 — 계정 label은 고정 provider 카드 제목으로 교체.
        func redactingAccountNamesForBrowserWire() -> State {
            var state = self
            state.snapshots = snapshots.mapValues { snapshot in
                var snapshot = snapshot
                snapshot.displayName = ProviderAccountID.cardTitle(
                    providerID: snapshot.providerID,
                    fallback: snapshot.displayName
                )
                return snapshot
            }
            return state
        }
    }

    struct Response: Equatable, Sendable {
        var status: Int
        var body: Data?
    }

    static func respond(method: String, path: String, state: State) -> Response {
        // preflight 지원 — 모든 경로의 OPTIONS는 204 + 서버 상시 CORS 헤더.
        if method == "OPTIONS" {
            return Response(status: 204, body: nil)
        }

        let segments = path.split(separator: "?", maxSplits: 1)[0]
            .split(separator: "/")
            .map(String.init)

        switch (segments.count, segments.first, segments.dropFirst().first) {
        case (2, "v1", "limits"):
            guard method == "GET" else { return error(405, "method_not_allowed") }
            return Response(
                status: 200,
                body: LocalLimitsAPI.encode(providerIDs: state.enabledOrderedIDs, state: state)
            )

        case (3, "v1", "limits"):
            guard method == "GET" else { return error(405, "method_not_allowed") }
            // token은 plain string 매칭으로 카드 지칭(`matchingCardIDs`) — envelope이 카드 id 키라 단일 카드와 family가 동일 직렬화.
            // 데이터 없는 매칭 카드는 항목 없음 — token이 아무것도 지칭 못 할 때만 404.
            let providerIDs = state.matchingCardIDs(for: segments[2])
            guard !providerIDs.isEmpty else { return error(404, "provider_not_found") }
            return Response(
                status: 200,
                body: LocalLimitsAPI.encode(providerIDs: providerIDs, state: state)
            )

        case (2, "v1", "usage"):
            guard method == "GET" else { return error(405, "method_not_allowed") }
            let snapshots = state.enabledOrderedIDs.compactMap { state.snapshots[$0] }
            return Response(status: 200, body: encode(snapshots.map(WireSnapshot.init)))

        case (3, "v1", "usage"):
            guard method == "GET" else { return error(405, "method_not_allowed") }
            // `/v1/limits/:token`과 동일 매칭, collection 라우트와 동일한 항상-배열 shape — 매칭에 데이터 없으면 `[]`.
            let providerIDs = state.matchingCardIDs(for: segments[2])
            guard !providerIDs.isEmpty else { return error(404, "provider_not_found") }
            let snapshots = providerIDs.compactMap { state.snapshots[$0] }
            return Response(status: 200, body: encode(snapshots.map(WireSnapshot.init)))

        default:
            return error(404, "not_found")
        }
    }

    static let busy = error(503, "server_busy")

    private static func error(_ status: Int, _ code: String) -> Response {
        Response(status: status, body: Data(#"{"error":"\#(code)"}"#.utf8))
    }

    private static func encode(_ value: some Encodable) -> Data {
        (try? JSONEncoder().encode(value)) ?? Data("[]".utf8)
    }

    // MARK: - Wire types (the documented public shape, distinct from the internal cache Codable)

    private struct WireSnapshot: Encodable {
        let snapshot: ProviderSnapshot

        init(_ snapshot: ProviderSnapshot) { self.snapshot = snapshot }

        enum CodingKeys: String, CodingKey {
            case providerId, displayName, plan, lines, fetchedAt
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(snapshot.providerID, forKey: .providerId)
            try container.encode(snapshot.displayName, forKey: .displayName)
            try container.encode(snapshot.plan, forKey: .plan)
            try container.encode(snapshot.lines.map(WireLine.init), forKey: .lines)
            try container.encode(OpenUsageISO8601.string(from: snapshot.refreshedAt), forKey: .fetchedAt)
        }
    }

    private struct WireLine: Encodable {
        let line: MetricLine

        init(_ line: MetricLine) { self.line = line }

        enum CodingKeys: String, CodingKey {
            case type, label, value, used, limit, format, resetsAt, periodDurationMs, color, subtitle, text, points, note
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch line {
            case .text(let label, let value, let color, let subtitle):
                try container.encode("text", forKey: .type)
                try container.encode(label, forKey: .label)
                try container.encode(value, forKey: .value)
                try container.encode(color, forKey: .color)        // 원본과 동일한 explicit null.
                try container.encode(subtitle, forKey: .subtitle)
            case .values(let label, let values, let color, let expiriesAt, _, _):
                // 기존 local-API 통합 호환용 원본 `text` shape(결합 `value` 문자열)로 직렬화 — dollars는 full, counts는 compact.
                // per-model hover 상세는 UI 전용 — 공개 wire shape에서 의도적 생략.
                try container.encode("text", forKey: .type)
                try container.encode(label, forKey: .label)
                try container.encode(Self.legacyValueString(values), forKey: .value)
                try container.encode(color, forKey: .color)
                try container.encodeNil(forKey: .subtitle)
                // 가장 이른 expiry(Codex reset credits)를 ISO-8601로 노출 — progress row와 동일한 `resetsAt` 필드.
                try container.encodeIfPresent(expiriesAt.min().map(OpenUsageISO8601.string(from:)), forKey: .resetsAt)
            case .progress(let label, let used, let limit, let format, let resetsAt, let periodDurationMs, let color):
                try container.encode("progress", forKey: .type)
                try container.encode(label, forKey: .label)
                try container.encode(used, forKey: .used)
                try container.encode(limit, forKey: .limit)
                try container.encode(format, forKey: .format)      // {"kind": ...} (+ counts는 "suffix")
                try container.encodeIfPresent(resetsAt.map(OpenUsageISO8601.string(from:)), forKey: .resetsAt)
                try container.encodeIfPresent(periodDurationMs, forKey: .periodDurationMs)
                try container.encode(color, forKey: .color)
            case .badge(let label, let text, let color, let subtitle):
                try container.encode("badge", forKey: .type)
                try container.encode(label, forKey: .label)
                try container.encode(text, forKey: .text)
                try container.encode(color, forKey: .color)
                try container.encode(subtitle, forKey: .subtitle)
            case .chart(let label, let points, let note):
                // 원본 앱의 `barChart` line shape — 일자별 {label, value, valueLabel} point + 선택적 source note, 기존 통합의 trend 읽기 유지.
                try container.encode("barChart", forKey: .type)
                try container.encode(label, forKey: .label)
                try container.encode(points, forKey: .points)
                try container.encodeIfPresent(note, forKey: .note)
                try container.encodeNil(forKey: .color)
            }
        }

        /// `.values` row의 legacy 결합 문자열 — dollars는 full(cents 보존), counts는 compact, " · "로 join.
        private static func legacyValueString(_ values: [MetricValue]) -> String {
            values
                .map { MetricFormatter.string(for: $0, style: $0.kind == .count ? .tray : .full) }
                .joined(separator: " · ")
        }
    }
}
