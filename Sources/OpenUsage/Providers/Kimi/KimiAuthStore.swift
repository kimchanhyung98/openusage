import Foundation

enum KimiCredentialSource: Sendable, Equatable {
    case current(home: URL, credential: URL, lockTarget: URL)
    case legacy(credential: URL)
}

struct KimiCredentials: Sendable, Equatable {
    var source: KimiCredentialSource
    var accessToken: String?
    var refreshToken: String?
    var expiresAt: Date?
    var expiresIn: TimeInterval?
}

struct KimiCredentialDocument: Sendable, Equatable {
    var credentials: KimiCredentials
    var rawJSON: String
}

struct KimiTokenRefresh: Sendable, Equatable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
    var expiresIn: TimeInterval
    var scope: String? = nil
    var tokenType: String? = nil
}

struct KimiAuthStore: Sendable {
    static let defaultBaseURL = "https://api.kimi.com/coding/v1"
    static let defaultOAuthHost = "https://auth.kimi.com"

    var files: TextFileAccessing
    var environment: EnvironmentReading
    var homeDirectory: @Sendable () -> URL

    init(
        files: TextFileAccessing = LocalTextFileAccessor(),
        environment: EnvironmentReading = ProcessEnvironmentReader(),
        homeDirectory: @escaping @Sendable () -> URL = { FileManager.default.homeDirectoryForCurrentUser }
    ) {
        self.files = files
        self.environment = environment
        self.homeDirectory = homeDirectory
    }

    func loadCredentialDocument() throws -> KimiCredentialDocument? {
        try validateConfiguration()

        let current = currentSource()
        if let document = try readDocument(source: current) {
            return document
        }
        return try readDocument(source: legacySource())
    }

    func isUsable(_ document: KimiCredentialDocument, now: Date) -> Bool {
        guard document.credentials.accessToken?.nilIfEmpty != nil else {
            return false
        }
        if hasUsableAccess(document, now: now) { return true }

        switch document.credentials.source {
        case .legacy:
            return false
        case .current:
            return oauthLockEnabled && document.credentials.refreshToken?.nilIfEmpty != nil
        }
    }

    func hasUsableAccess(_ document: KimiCredentialDocument, now: Date) -> Bool {
        guard document.credentials.accessToken?.nilIfEmpty != nil else {
            return false
        }
        guard let expiresAt = document.credentials.expiresAt else {
            return true
        }
        return expiresAt.timeIntervalSince1970 == 0 || expiresAt > now
    }

    func needsRefresh(_ document: KimiCredentialDocument, now: Date) -> Bool {
        guard case .current = document.credentials.source,
              oauthLockEnabled,
              document.credentials.accessToken?.nilIfEmpty != nil,
              document.credentials.refreshToken?.nilIfEmpty != nil
        else {
            return false
        }
        guard let expiresAt = document.credentials.expiresAt,
              expiresAt.timeIntervalSince1970 != 0
        else {
            return false
        }
        let threshold = max(300, (document.credentials.expiresIn ?? 0) / 2)
        return expiresAt.timeIntervalSince(now) <= threshold
    }

    func reloadCurrentDocument(_ source: KimiCredentialSource) throws -> KimiCredentialDocument {
        guard case .current = source,
              let document = try readDocument(source: source)
        else {
            throw KimiAuthError.credentialsInvalid
        }
        return document
    }

    func persistRotatedCredentials(
        replacing liveDocument: KimiCredentialDocument,
        with token: KimiTokenRefresh
    ) throws {
        guard case .current(_, let credential, _) = liveDocument.credentials.source,
              var object = Self.jsonObject(liveDocument.rawJSON)
        else {
            throw KimiAuthError.credentialsInvalid
        }

        do {
            guard try files.readTextIfPresent(credential.path) == liveDocument.rawJSON else {
                throw KimiAuthError.credentialLockCompromised
            }
        } catch let error as KimiAuthError {
            throw error
        } catch {
            throw KimiAuthError.credentialSaveFailed
        }

        object["access_token"] = token.accessToken
        object["refresh_token"] = token.refreshToken
        object["expires_at"] = token.expiresAt.timeIntervalSince1970
        object["expires_in"] = token.expiresIn
        if let scope = token.scope { object["scope"] = scope }
        if let tokenType = token.tokenType { object["token_type"] = tokenType }

        guard JSONSerialization.isValidJSONObject(object) else {
            throw KimiAuthError.credentialsInvalid
        }
        let text: String
        do {
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            guard let encoded = String(data: data, encoding: .utf8) else {
                throw KimiAuthError.credentialSaveFailed
            }
            text = encoded
            try files.writeText(credential.path, text)
        } catch let error as KimiAuthError {
            throw error
        } catch {
            throw KimiAuthError.credentialSaveFailed
        }
    }

    var oauthLockEnabled: Bool {
        environment.value(for: "KIMI_DISABLE_OAUTH_LOCK")?
            .trimmingCharacters(in: .whitespacesAndNewlines) != "1"
    }

    private func currentSource() -> KimiCredentialSource {
        let rawHome = environment.value(for: "KIMI_CODE_HOME")?
            .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let home = rawHome.map(resolvePath) ?? homeDirectory().appendingPathComponent(".kimi-code")
        return .current(
            home: home,
            credential: home.appendingPathComponent("credentials/kimi-code.json"),
            lockTarget: home.appendingPathComponent("oauth/kimi-code")
        )
    }

    private func legacySource() -> KimiCredentialSource {
        .legacy(credential: homeDirectory().appendingPathComponent(".kimi/credentials/kimi-code.json"))
    }

    private func readDocument(source: KimiCredentialSource) throws -> KimiCredentialDocument? {
        let path: String
        switch source {
        case .current(_, let credential, _), .legacy(let credential):
            path = credential.path
        }

        let text: String?
        do {
            text = try files.readTextIfPresent(path)
        } catch {
            throw KimiAuthError.credentialsUnreadable
        }
        guard let text else { return nil }
        guard let object = Self.jsonObject(text) else {
            throw KimiAuthError.credentialsInvalid
        }

        let accessToken = Self.string(object["access_token"])
        let refreshToken = Self.string(object["refresh_token"])
        guard accessToken != nil || refreshToken != nil else {
            throw KimiAuthError.credentialsInvalid
        }

        let expiresAt = ProviderParse.number(object["expires_at"])
            .map(Date.init(timeIntervalSince1970:))
        let expiresIn = ProviderParse.number(object["expires_in"])
        if object["expires_at"] != nil && expiresAt == nil {
            throw KimiAuthError.credentialsInvalid
        }
        if object["expires_in"] != nil && expiresIn == nil {
            throw KimiAuthError.credentialsInvalid
        }

        return KimiCredentialDocument(
            credentials: KimiCredentials(
                source: source,
                accessToken: accessToken,
                refreshToken: refreshToken,
                expiresAt: expiresAt,
                expiresIn: expiresIn
            ),
            rawJSON: text
        )
    }

    private func validateConfiguration() throws {
        let overrides = [
            ("KIMI_CODE_BASE_URL", Self.defaultBaseURL),
            ("KIMI_CODE_OAUTH_HOST", Self.defaultOAuthHost),
            ("KIMI_OAUTH_HOST", Self.defaultOAuthHost)
        ]
        for (key, expected) in overrides {
            guard let raw = environment.value(for: key)?
                .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            else {
                continue
            }
            guard Self.matchesDefaultEndpoint(raw, expected: expected) else {
                throw KimiAuthError.unsupportedConfiguration
            }
        }
    }

    private func resolvePath(_ path: String) -> URL {
        if path == "~" { return homeDirectory() }
        if path.hasPrefix("~/") {
            return homeDirectory().appendingPathComponent(String(path.dropFirst(2)))
        }
        return URL(fileURLWithPath: path)
    }

    private static func jsonObject(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func string(_ value: Any?) -> String? {
        (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    private static func matchesDefaultEndpoint(_ value: String, expected: String) -> Bool {
        guard let actual = URLComponents(
            string: value.trimmingCharacters(in: .whitespacesAndNewlines)
        ), let standard = URLComponents(string: expected),
              actual.user == nil,
              actual.password == nil,
              actual.query == nil,
              actual.fragment == nil,
              actual.scheme?.lowercased() == standard.scheme?.lowercased(),
              actual.host?.lowercased() == standard.host?.lowercased(),
              actual.port == standard.port
        else {
            return false
        }
        return actual.percentEncodedPath.trimmingTrailingSlashes
            == standard.percentEncodedPath.trimmingTrailingSlashes
    }
}
