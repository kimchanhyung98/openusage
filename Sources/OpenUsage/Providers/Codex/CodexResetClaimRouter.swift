import Foundation
import SwiftUI

/// One `CodexResetClaimService` per Codex card. A reset-credit claim is irreversible — the app's
/// only provider-API write — so the claim tapped on a card must run through THAT card's own
/// `authStore`/`usageClient`: after Task-1 scoping, each per-card provider reads exactly its own
/// login, and routing anywhere else could spend a different account's credential than the card
/// shows. The default card's service is built exactly as the historical app-wide one was (same
/// store, same client, same `refreshAfterClaim` retry loop — the closure is parameterized by card
/// id and refreshes the claiming card via `WidgetDataStore.refresh(providerID:force:)`).
@MainActor
final class CodexResetClaimRouter {
    private var servicesByCard: [String: CodexResetClaimService]
    private let refreshAfterClaim: (String) async -> Void

    /// `refreshAfterClaim` receives the claiming card's provider id; the container supplies the
    /// shared bounded-retry forced refresh (see `AppContainer`).
    init(
        providers: [CodexProvider],
        refreshAfterClaim: @escaping (String) async -> Void
    ) {
        self.servicesByCard = [:]
        self.refreshAfterClaim = refreshAfterClaim
        reconfigure(providers: providers)
    }

    /// The claim service for one card, or `nil` for a card with no Codex runtime (unknown id, or a
    /// card whose managed home wasn't found this launch) — the row then renders read-only.
    func service(for cardID: String) -> CodexResetClaimService? {
        servicesByCard[cardID]
    }

    /// Rebuilds the routing table for the current catalog. A managed switch can rescope the bare
    /// `codex` runtime without changing its card id, so every runtime gets a fresh service over its
    /// own store/client — replacing whatever an earlier runtime left under the same id — and a card
    /// that left the catalog loses its service instead of staying claimable with stale credentials.
    func reconfigure(providers: [CodexProvider]) {
        let refreshAfterClaim = refreshAfterClaim
        servicesByCard = Dictionary(uniqueKeysWithValues: providers.map { provider in
            let cardID = provider.provider.id
            return (cardID, CodexResetClaimService(
                authStore: provider.authStore,
                usageClient: provider.usageClient,
                refreshAfterClaim: { await refreshAfterClaim(cardID) }
            ))
        })
    }
}

/// Hands the claim router to the resets popover through the environment: `nil` (the default —
/// previews, share-card renders, reorder previews) renders the timeline read-only with no "Use"
/// affordance.
private struct CodexResetClaimRouterKey: EnvironmentKey {
    static let defaultValue: CodexResetClaimRouter? = nil
}

extension EnvironmentValues {
    var codexResetClaim: CodexResetClaimRouter? {
        get { self[CodexResetClaimRouterKey.self] }
        set { self[CodexResetClaimRouterKey.self] = newValue }
    }
}
