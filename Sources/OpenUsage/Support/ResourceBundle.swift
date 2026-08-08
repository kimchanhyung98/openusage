import Foundation

extension Bundle {
    /// OpenUsage의 복사된 리소스(provider SVG, pricing supplement + snapshot)를 담은 bundle.
    /// `Bundle.module`은 packaged `.app`의 `Contents/Resources`를 못 찾아 launch crash — 실제 배포 위치를 먼저 탐색하고
    /// `swift run`/`swift test`에서만 `Bundle.module`로 fallback.
    static let openUsageResources: Bundle = {
        let bundleName = "OpenUsage_OpenUsage.bundle"
        let containingAppResources = Bundle.main.executableURL
            .flatMap(ContainingAppBundle.url(for:))?
            .appendingPathComponent("Contents/Resources", isDirectory: true)
        let searchBases: [URL?] = [
            Bundle.main.resourceURL,                          // packaged .app의 Contents/Resources
            Bundle.main.bundleURL,                            // 앱 루트 옆 bundle
            containingAppResources,                          // 번들된 CLI: helper → 앱 Resources
            Bundle(for: ResourceBundleToken.self).resourceURL,
            Bundle(for: ResourceBundleToken.self).bundleURL
        ]
        for case let base? in searchBases {
            guard let bundle = Bundle(url: base.appendingPathComponent(bundleName)) else { continue }
            if isValidOpenUsageResourceBundle(bundle) {
                return bundle
            }
            // `Bundle(url:)`은 경로의 아무 디렉터리에서나 성공 — 이전 빌드가 남긴 stale/빈 동명 디렉터리가 실제 bundle을 가리지 않도록 크게 알리고 계속 탐색.
            AppLog.warn(.config, "ignoring resource bundle at \(base.lastPathComponent): missing expected resources")
        }
        return .module
    }()
}

/// sentinel 검사 — 유효한 OpenUsage 리소스 bundle은 루트에 pricing supplement 보유.
/// pricing store와 같은 lookup을 사용해 실제 배포 bundle을 거부할 수 없음.
private func isValidOpenUsageResourceBundle(_ bundle: Bundle) -> Bool {
    bundle.url(forResource: "pricing_supplement", withExtension: "json") != nil
}

private final class ResourceBundleToken {}
