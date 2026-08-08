import Foundation

/// 자신이 공급할 widget을 등록하는 data source.
struct Provider: Identifiable, Hashable {
    let id: String
    let displayName: String
    let icon: IconSource
    /// 카드 확장 영역에 버튼으로 표시되는 provider별 quick link — 기본값 빈 배열.
    let links: [ProviderLink]

    init(id: String, displayName: String, icon: IconSource, links: [ProviderLink] = []) {
        self.id = id
        self.displayName = displayName
        self.icon = icon
        self.links = links
    }

    /// 렌더 가능한 link만 필터 — trim 후 비어 있지 않은 label·URL, `http(s)` scheme 한정.
    var visibleLinks: [ProviderLink] {
        links.compactMap { link in
            let label = link.label.trimmingCharacters(in: .whitespacesAndNewlines)
            let url = link.url.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty,
                  !url.isEmpty,
                  url.hasPrefix("https://") || url.hasPrefix("http://") else { return nil }
            return ProviderLink(label: label, url: url)
        }
    }
}

/// provider 카드의 외부 quick-link 버튼 하나 — label과 기본 브라우저로 여는 URL.
struct ProviderLink: Hashable {
    let label: String
    let url: String
}
