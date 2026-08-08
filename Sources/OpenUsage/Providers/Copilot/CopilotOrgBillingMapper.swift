import Foundation

/// GitHub organization billing 응답을 org 단위 Copilot meter로 normalize. billing usage summary(`/orgs/{org}/settings/billing/usage/summary`)의 Copilot AI-credit 항목이 **Org Credits**(이달 소비 credit, allotment 미노출이라 percentage 조작 없음)와 **Org Spend**(포함 credit 초과로 실제 청구된 달러)가 됨.
/// 둘 다 organization 전체 합계 — GitHub은 org 관리 Copilot의 per-seat 수치를 노출하지 않음.
enum CopilotOrgBillingMapper {
    /// `/user/orgs` 응답의 org slug, GitHub 순서 그대로. 깨진 body는 빈 배열.
    static func orgLogins(_ response: HTTPResponse) -> [String] {
        guard let array = try? JSONSerialization.jsonObject(with: response.body) as? [[String: Any]] else {
            return []
        }
        return array.compactMap { entry in
            (entry["login"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        }
    }

    /// billing usage summary → metric line, Copilot AI-credit 항목이 없으면 nil(그 org는 Copilot credit 미사용 — 호출자가 다른 org 계속 probe).
    /// `unitType`이 credit 계열(`ai-units`/`ai-credits`)인 항목만 집계 — 다른 단위의 seat-fee 항목이 합계를 오염시키지 못함.
    static func usageLines(_ response: HTTPResponse) -> [MetricLine]? {
        guard let body = ProviderParse.jsonObject(response.body) else { return nil }
        return usageLines(body: body)
    }

    static func usageLines(body: [String: Any]) -> [MetricLine]? {
        guard let items = body["usageItems"] as? [[String: Any]] else { return nil }

        let creditItems = items.filter { item in
            isCopilot(item["product"]) && isCreditUnit(item["unitType"])
        }
        guard !creditItems.isEmpty else { return nil }

        let credits = creditItems.reduce(0.0) { $0 + max(0, ProviderParse.number($1["grossQuantity"]) ?? 0) }
        let spend = creditItems.reduce(0.0) { $0 + max(0, ProviderParse.number($1["netAmount"]) ?? 0) }

        return [
            .values(label: "Org Credits", values: [MetricValue(number: credits, kind: .count, label: "credits")]),
            .values(label: "Org Spend", values: [MetricValue(number: spend, kind: .dollars)])
        ]
    }

    private static func isCopilot(_ value: Any?) -> Bool {
        guard let product = value as? String else { return false }
        return product.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "copilot"
    }

    private static func isCreditUnit(_ value: Any?) -> Bool {
        guard let unit = value as? String else { return false }
        let normalized = unit.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "ai-units" || normalized == "ai-credits"
    }
}
