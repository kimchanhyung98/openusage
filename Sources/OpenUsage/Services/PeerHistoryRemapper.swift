import Foundation

/// 동기화된 peer history를 카드 id가 아닌 계정 identity로 이 Mac의 카드에 매칭.
/// 같은 계정이 Mac마다 default/추가 카드로 달라 카드 id는 이동 불가 — v2 문서는 카드별 identity map으로 정확 매칭, v1 문서는 bare id에 legacy same-card-id merge 유지.
/// 이 Mac에 카드 없는 peer 계정은 `remoteOnly` — Total Spend에만 표시, ghost 카드 금지.
enum PeerHistoryRemapper {
    struct Remapped {
        /// 로컬 카드 id로 주소 지정된 peer history — same-id day merge 대상.
        var histories: [(cardID: String, history: ProviderUsageHistory)] = []
        /// 로컬 카드 없는 peer 계정 — identity 기준 그룹.
        var remoteOnly: [RemoteOnlyHistory] = []
    }

    struct RemoteOnlyHistory {
        var identityKey: String
        var family: String
        /// 계정의 identity 파생 카드 id (`claude@ab12cd34`) — 어느 Mac에서든 동일.
        /// Total Spend slice 이름 — 출처 Mac은 의도적 미포함(합계에 무관).
        var cardID: String
        var histories: [ProviderUsageHistory]
    }

    /// `localIdentityByCardID`: 이 Mac의 카드 → identity map (launch 계정 pass의 `identityKeysByCard`).
    static func remap(
        documents: [UsageHistoryDocument],
        localIdentityByCardID: [String: String]
    ) -> Remapped {
        // identity → 카드로 역전 — 한 identity가 로컬 카드 2개에 동시 등장 시(swap 전후 일시 가능) bare(default) 카드 우선.
        var localCardByIdentity: [String: String] = [:]
        for (cardID, identity) in localIdentityByCardID.sorted(by: { $0.key < $1.key }) {
            if let existing = localCardByIdentity[identity], !ProviderAccountID.isAccountCard(existing) {
                continue
            }
            if ProviderAccountID.isAccountCard(cardID), localCardByIdentity[identity] != nil {
                continue
            }
            localCardByIdentity[identity] = cardID
        }

        var result = Remapped()
        var remoteByIdentity: [String: RemoteOnlyHistory] = [:]
        func collectRemoteOnly(identity: String, family: String, cardID: String, history: ProviderUsageHistory) {
            var entry = remoteByIdentity[identity] ?? RemoteOnlyHistory(
                identityKey: identity, family: family, cardID: cardID, histories: []
            )
            entry.histories.append(history)
            remoteByIdentity[identity] = entry
        }

        for document in UsageHistoryDocument.newestByDevice(documents) {
            for (peerCardID, history) in document.providers.sorted(by: { $0.key < $1.key }) {
                let family = ProviderAccountID.family(of: peerCardID)
                if let identity = document.identities?[peerCardID] {
                    if let localCard = localCardByIdentity[identity] {
                        result.histories.append((localCard, history))
                    } else if !ProviderAccountID.isAccountCard(peerCardID), localIdentityByCardID[peerCardID] == nil {
                        // peer는 bare 카드 계정을 특정했으나 이 Mac의 bare 카드 identity는 이번 launch 미해석 — mismatch 증명 불가.
                        // legacy same-card-id merge 유지 — 같은 계정일 공산이 큰 history의 Total Spend 분리 방지; 실제 다른 계정은 identity 해석되는 다음 launch에 분리.
                        result.histories.append((peerCardID, history))
                    } else {
                        collectRemoteOnly(
                            identity: identity,
                            family: family,
                            cardID: ProviderAccountID.make(family: family, identityKey: identity),
                            history: history
                        )
                    }
                    continue
                }
                // identity 미기록(v1 문서, 또는 peer가 미식별한 카드): bare id는 legacy same-card-id merge, account-card id는 이 Mac에 같은 id 있으면 매칭, 없으면 remote-only.
                // peer의 카드 id가 grouping 키 겸 표시 id — peer에서 발급된 identity 파생 id.
                if !ProviderAccountID.isAccountCard(peerCardID) || localIdentityByCardID[peerCardID] != nil {
                    result.histories.append((peerCardID, history))
                } else {
                    collectRemoteOnly(identity: peerCardID, family: family, cardID: peerCardID, history: history)
                }
            }
        }

        result.remoteOnly = remoteByIdentity.values.sorted { $0.identityKey < $1.identityKey }
        return result
    }
}
