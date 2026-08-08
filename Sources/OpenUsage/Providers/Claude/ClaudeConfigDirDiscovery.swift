import Foundation

/// 커스텀 config dir(기본 home 외 `CLAUDE_CONFIG_DIR` 대상)의 추가 Claude 로그인 launch-time 스캔.
/// keychain secret 미조회(파일 존재 + attributes-only probe) — 권한 dialog·launch 블로킹 금지.
/// 후보는 `~`의 dot-dir와 `~/.config` 하위로 한정; identity 추출 성공이 곧 검증(이름 매칭 아님).
struct ClaudeConfigDirDiscovery {
    /// 승인된 커스텀 config-dir 로그인 1건 — 카드화/기존 계정 귀속 판단은 assembly 소관.
    struct Finding: Equatable, Sendable {
        var identityKey: String
        var label: String?
        /// 확장된 config-dir 경로 — 카드의 credential home이자 spend 로그 root.
        var anchorPath: String
        /// keychain 항목 이름을 만드는 해시 원문 문자열(`ClaudeCredentialScope` 참고).
        var keychainLiteral: String
    }

    struct Result: Sendable {
        var findings: [Finding] = []
        /// 결정별 support trail(로그 출력) — 토큰·이메일 없이 identity 해시·종류·경로만 포함.
        var notes: [String] = []
    }

    var environment: EnvironmentReading
    var files: TextFileAccessing
    var keychain: KeychainAccessing
    var homeDirectory: @Sendable () -> URL
    var listSubdirectories: @Sendable (URL) -> [URL]
    /// wall-clock 예산 — 초과 시 부분 결과 반환, 다음 launch에서 재개.
    var timeBudget: TimeInterval
    var now: @Sendable () -> Date

    init(
        environment: EnvironmentReading = ProcessEnvironmentReader(),
        files: TextFileAccessing = LocalTextFileAccessor(),
        keychain: KeychainAccessing = SecurityKeychainAccessor(),
        homeDirectory: @escaping @Sendable () -> URL = { FileManager.default.homeDirectoryForCurrentUser },
        listSubdirectories: @escaping @Sendable (URL) -> [URL] = Self.filesystemSubdirectories,
        timeBudget: TimeInterval = 0.4,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.environment = environment
        self.files = files
        self.keychain = keychain
        self.homeDirectory = homeDirectory
        self.listSubdirectories = listSubdirectories
        self.timeBudget = timeBudget
        self.now = now
    }

    func run(additionalDirectories: [URL] = []) -> Result {
        let started = now()
        var result = Result()
        let excluded = Set(defaultClaudeConfigDirs().map(canonical))
        var visited: Set<String> = []

        // 등록된 home은 정확한 계정 handle — bounded ambient 스캔보다 우선, launch 예산 안에서 카드 바인딩 필수.
        for candidate in additionalDirectories + candidateDirectories() {
            if now().timeIntervalSince(started) > timeBudget {
                result.notes.append("claude config-dir scan hit its \(Int(timeBudget * 1000))ms budget; finishing with partial results")
                break
            }
            let canonicalPath = canonical(candidate.path)
            guard visited.insert(canonicalPath).inserted,
                  !excluded.contains(canonicalPath) else { continue }
            if let finding = claudeCandidate(at: candidate, notes: &result.notes) {
                result.findings.append(finding)
            }
        }
        return result
    }

    /// 지정된 config dir 1개의 identity + credential 조회 — 관리 profile sign-in probe.
    /// launch 스캔과 동일한 엄격 검증(후보 gating·시간 예산만 제외); 기본 home 경로는
    /// `DefaultAccountObserver`로 라우팅 — 여기서는 항상 dir 내부의 state 파일 조회.
    func inspect(configDir url: URL) -> Finding? {
        var notes: [String] = []
        let finding = claudeCandidate(at: url, notes: &notes)
        for note in notes {
            AppLog.debug(.config, note)
        }
        return finding
    }

    // MARK: - Candidates

    /// `~`의 dot-dir + `~/.config` 하위 dir, 안정적 경로 순서.
    private func candidateDirectories() -> [URL] {
        let home = homeDirectory()
        var candidates = listSubdirectories(home).filter { $0.lastPathComponent.hasPrefix(".") }
        candidates += listSubdirectories(home.appendingPathComponent(".config"))
        return candidates.sorted { $0.path < $1.path }
    }

    private static func filesystemSubdirectories(of url: URL) -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        )) ?? []
        return contents.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        }
    }

    private func claudeCandidate(at url: URL, notes: inout [String]) -> Finding? {
        // pre-gate: identity 파일 보유 dir만 trail 진입 — 나머지는 무관한 dot-dir로 로그 제외.
        // 커스텀 dir은 state를 내부에 보관; 기본 home(`~/.claude.json` 방식)은 사전 제외됨.
        guard let identityText = try? files.readTextIfPresent(url.path + "/.claude.json") else {
            return nil
        }
        guard let parsed = try? JSONDecoder().decode(
                  DefaultAccountObserver.ClaudeStateFile.self, from: Data(identityText.utf8)
              ),
              let account = parsed.oauthAccount,
              let key = DefaultAccountObserver.claudeIdentityKey(account)
        else {
            notes.append("claude candidate \(logPath(url.path)): identity file present but names no account → skipped")
            return nil
        }

        // credential 형태: dir의 `.credentials.json` 또는 계산된 keychain 항목 —
        // 가능한 경로 표기 전부를 attributes-only로 probe(secret·prompt 없음).
        let fileBacked = (try? files.readTextIfPresent(url.path + "/.credentials.json"))
            .flatMap { $0 }
            .flatMap { ClaudeAuthStore.parseCredentials($0) }?
            .claudeAiOauth?.accessToken?.nilIfEmpty != nil

        var matchedLiteral: String?
        let literals = keychainLiterals(for: url)
        for literal in literals {
            let service = ClaudeAuthStore.scopedKeychainServiceName(
                forConfigDirLiteral: literal,
                environment: environment
            )
            if keychain.genericPasswordExists(service: service) == true {
                matchedLiteral = literal
                break
            }
        }
        guard fileBacked || matchedLiteral != nil else {
            notes.append("claude candidate \(logPath(url.path)): identity \(hash8(key)) but no credential (no .credentials.json, no keychain item for \(literals.count) path spellings) → skipped")
            return nil
        }

        notes.append("claude candidate \(logPath(url.path)): accepted (\(hash8(key)), \(fileBacked ? "file" : "keychain") credential)")
        return Finding(
            identityKey: key,
            label: DefaultAccountObserver.claudeIdentityLabel(account),
            anchorPath: url.path,
            keychainLiteral: matchedLiteral ?? url.path
        )
    }

    /// Claude Code가 해시했을 수 있는 이 dir의 경로 표기 전부 — 원본·symlink 해소·`~` 축약 조합.
    private func keychainLiterals(for url: URL) -> [String] {
        let home = homeDirectory()
        let homePaths = Array(Set([home.path, home.resolvingSymlinksInPath().path]))
        var candidates = [url.path, url.resolvingSymlinksInPath().path]
        for candidate in candidates {
            for homePath in homePaths where candidate.hasPrefix(homePath + "/") {
                let suffix = candidate.dropFirst(homePath.count)
                candidates += homePaths.map { $0 + suffix }
            }
        }
        var literals: [String] = []
        for candidate in candidates {
            literals.append(candidate)
            for homePath in homePaths where candidate.hasPrefix(homePath + "/") {
                literals.append("~" + candidate.dropFirst(homePath.count))
            }
        }
        var seen = Set<String>()
        return literals.filter { seen.insert($0).inserted }
    }

    // MARK: - Default homes (the exclusion set)

    /// 기본 카드의 config dir 목록 — `CLAUDE_CONFIG_DIR` 우선, 없으면 표준 해석(`$XDG_CONFIG_HOME/claude`, `~/.claude`).
    private func defaultClaudeConfigDirs() -> [String] {
        if let raw = environment.value(for: "CLAUDE_CONFIG_DIR")?
            .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
            let dirs = raw.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            if !dirs.isEmpty { return dirs.map(expandTilde) }
        }
        let home = homeDirectory()
        let xdg = environment.value(for: "XDG_CONFIG_HOME")?.nilIfEmpty.map(expandTilde)
            ?? home.appendingPathComponent(".config").path
        return [xdg + "/claude", home.appendingPathComponent(".claude").path]
    }

    // MARK: - Path helpers

    private func expandTilde(_ path: String) -> String {
        guard path == "~" || path.hasPrefix("~/") else { return path }
        return homeDirectory().path + String(path.dropFirst(1))
    }

    private func canonical(_ path: String) -> String {
        URL(fileURLWithPath: expandTilde(path)).resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// 로그 안전 경로 — home prefix를 `~`로 접어 username 노출 방지.
    private func logPath(_ path: String) -> String {
        let home = homeDirectory().path
        guard path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }

    private func hash8(_ identityKey: String) -> String {
        String(ProviderAccountID.make(family: "claude", identityKey: identityKey).dropFirst("claude@".count))
    }
}
