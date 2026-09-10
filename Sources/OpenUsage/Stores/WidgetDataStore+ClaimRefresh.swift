import Foundation

extension WidgetDataStore {
    enum ClaimRefreshBinding: Equatable {
        case account(String)
        case unresolvedCatalog(Int)
    }

    /// claim 완료 시점의 binding을 유지하며 pre-claim fetch가 끝나기를 대기.
    func refreshAfterClaim(
        providerID: String,
        maxAttempts: Int = 45,
        retryDelay: Duration = .seconds(1)
    ) async {
        let boundBinding = claimRefreshBinding(providerID: providerID)
        var failures = 0
        for _ in 0..<maxAttempts {
            guard !Task.isCancelled else { return }
            guard let boundBinding, claimRefreshBinding(providerID: providerID) == boundBinding else {
                AppLog.info(LogTag.plugin(ProviderAccountID.family(of: providerID)), "post-claim refresh stopped: account binding changed")
                AppDiagnostics.record(.postClaimRefresh, result: .bindingChanged, providerID: providerID)
                return
            }
            switch await refresh(providerID: providerID, force: true, trigger: .resetClaim) {
            case .refreshed, .cacheHit, .backedOff:
                AppDiagnostics.record(.postClaimRefresh, result: .success, providerID: providerID)
                return
            case .failed:
                failures += 1
                guard failures < 3 else {
                    AppDiagnostics.record(.postClaimRefresh, result: .failure, category: .other, providerID: providerID,
                                          localContext: "Post-claim refresh failed repeatedly; meters may lag until the next cycle")
                    return
                }
            case .skipped:
                break
            }
            do { try await Task.sleep(for: retryDelay) }
            catch { return }
        }
        AppDiagnostics.record(.postClaimRefresh, result: .failure, category: .other, providerID: providerID,
                              localContext: "Post-claim refresh kept being skipped; meters may lag until the next cycle")
    }
}
