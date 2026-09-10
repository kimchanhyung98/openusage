/// cache 우회와 독립적인 작업 원인 — 명시적인 새로 고침만 manual 집계.
enum RefreshTrigger: String, Codable, CaseIterable, Sendable {
    case scheduled
    case manual
    case accountChange = "account_change"
    case credentialChange = "credential_change"
    case resetClaim = "reset_claim"
    case cli
}
