import Foundation

extension ClaudeAuthError: UserPresentableError {
    var presentationMessage: LocalizedMessage {
        switch self {
        case .notLoggedIn:
            .init("Not logged in. Run `claude` to authenticate.")
        case .desktopPermissionRequired:
            .init("Claude Desktop login found. Refresh once and choose Always Allow to connect it.")
        case .desktopTokenExpired:
            .init("Claude Desktop login is stale. Open Claude Desktop, then refresh OpenUsage.")
        case .desktopCredentialsUnavailable:
            .init("Claude Desktop login couldn't be read. Open Claude Desktop, then try again.")
        case .sessionExpired:
            .init("Session expired. Run `claude` to log in again.")
        case .tokenExpired:
            .init("Token expired. Run `claude` to log in again.")
        case .credentialsChanged:
            .init("Claude login changed during refresh. Refresh again.")
        case .invalidOAuthURL(let value):
            .init("Invalid Claude OAuth URL: %@. Check CLAUDE_CODE_CUSTOM_OAUTH_URL / CLAUDE_LOCAL_OAUTH_API_BASE.", [String(value)])
        }
    }
}

extension ClaudeUsageError: UserPresentableError {
    var presentationMessage: LocalizedMessage {
        switch self {
        case .connectionFailed:
            .init("Usage request failed. Check your connection.")
        case .invalidResponse:
            .init("Usage response invalid. Try again later.")
        case .requestFailed(let statusCode):
            .init("Usage request failed (HTTP %@). Try again later.", [String(statusCode)])
        }
    }
}

extension CodexAuthError: UserPresentableError {
    var presentationMessage: LocalizedMessage {
        switch self {
        case .notLoggedIn:
            .init("Not logged in. Run `codex` to authenticate.")
        case .sessionExpired:
            .init("Session expired. Run `codex` to log in again.")
        case .tokenConflict:
            .init("Token conflict. Run `codex` to log in again.")
        case .tokenRevoked:
            .init("Token revoked. Run `codex` to log in again.")
        case .tokenExpired:
            .init("Token expired. Run `codex` to log in again.")
        case .usageAPIKey:
            .init("Usage not available for API key.")
        case .invalidAuthPayload:
            .init("Codex auth data is invalid.")
        case .credentialsChanged:
            .init("Codex sign-in changed during this operation. Reload the current account and try again.")
        }
    }
}

extension CodexUsageError: UserPresentableError {
    var presentationMessage: LocalizedMessage {
        switch self {
        case .requestFailed(let statusCode):
            .init("Usage request failed (HTTP %@). Try again later.", [String(statusCode)])
        case .invalidResponse:
            .init("Usage response invalid. Try again later.")
        case .connectionFailed:
            .init("Usage request failed. Check your connection.")
        }
    }
}

extension CursorAuthError: UserPresentableError {
    var presentationMessage: LocalizedMessage {
        switch self {
        case .notLoggedIn:
            .init("Not logged in. Sign in via Cursor app or run `agent login`.")
        case .sessionExpired:
            .init("Session expired. Sign in via Cursor app or run `agent login`.")
        case .tokenExpired:
            .init("Token expired. Sign in via Cursor app or run `agent login`.")
        case .credentialsChanged:
            .init("Cursor sign-in changed while refreshing. Refresh again to use the current account.")
        }
    }
}

extension CursorUsageError: UserPresentableError {
    var presentationMessage: LocalizedMessage {
        switch self {
        case .connectionFailed:
            .init("Usage request failed. Check your connection.")
        case .invalidResponse:
            .init("Usage response invalid. Try again later.")
        case .requestFailed(let statusCode):
            .init("Usage request failed (HTTP %@). Try again later.", [String(statusCode)])
        case .usageAfterRefreshFailed:
            .init("Usage request failed after refresh. Try again.")
        case .requestBasedUnavailable(let message):
            .init(message)
        case .totalUsageLimitMissing:
            .init("Total usage limit missing from API response.")
        case .noActiveSubscription:
            .init("No active Cursor subscription.")
        }
    }
}

extension GrokAuthError: UserPresentableError {
    var presentationMessage: LocalizedMessage {
        switch self {
        case .notLoggedIn:
            .init("Grok not logged in. Run `grok login`.")
        case .invalidAuth:
            .init("Grok auth invalid. Run `grok login` again.")
        case .expired:
            .init("Grok auth expired. Run `grok login` again.")
        case .credentialsChanged:
            .init("Grok sign-in changed while refreshing. Refresh again to use the current account.")
        case .credentialReadFailed:
            .init("Grok sign-in could not be read. Check access to ~/.grok/auth.json and refresh again.")
        }
    }
}

extension GrokUsageError: UserPresentableError {
    var presentationMessage: LocalizedMessage {
        switch self {
        case .connectionFailed:
            .init("Grok billing request failed. Check your connection.")
        case .invalidResponse:
            .init("Grok billing response changed.")
        case .requestFailed(let statusCode):
            .init("Grok billing request failed (HTTP %@). Try again later.", [String(statusCode)])
        }
    }
}

extension KimiAuthError: UserPresentableError {
    var presentationMessage: LocalizedMessage {
        switch self {
        case .notLoggedIn:
            .init("Not logged in to Kimi. Run `kimi` to authenticate.")
        case .credentialsUnreadable:
            .init("Kimi credentials could not be read. Check the credential file permissions.")
        case .credentialsInvalid:
            .init("Kimi credentials are invalid. Run `kimi` to log in again.")
        case .unsupportedConfiguration:
            .init("Custom Kimi API or OAuth hosts are not supported.")
        case .authExpired, .refreshRejected:
            .init("Kimi session expired. Run `kimi` to log in again.")
        case .refreshResponseInvalid:
            .init("Kimi returned an invalid token refresh response.")
        case .credentialLockUnavailable:
            .init("Kimi credentials are busy. Try again shortly.")
        case .credentialLockCompromised:
            .init("Kimi credential lock changed during refresh. Try again.")
        case .credentialSaveFailed:
            .init("Refreshed Kimi credentials could not be saved.")
        }
    }
}

extension KimiUsageError: UserPresentableError {
    var presentationMessage: LocalizedMessage {
        switch self {
        case .connectionFailed:
            .init("Usage request failed. Check your connection.")
        case .requestFailed(let status):
            .init("Usage request failed (HTTP %@). Try again later.", [String(status)])
        case .invalidResponse:
            .init("Usage response invalid. Try again later.")
        case .quotaUnavailable:
            .init("Kimi quota data is unavailable for this account.")
        }
    }
}

extension KiroAuthError: UserPresentableError {
    var presentationMessage: LocalizedMessage {
        switch self {
        case .notLoggedIn:
            .init("Not logged in to Kiro. Run `kiro-cli login` and try again.")
        case .credentialsUnreadable:
            .init("Kiro credentials could not be read. Check the CLI database permissions.")
        case .credentialsInvalid:
            .init("Kiro credentials are invalid. Run `kiro-cli login` and try again.")
        case .missingProfile:
            .init("Kiro profile is unavailable. Run `kiro-cli login` and try again.")
        case .authExpired:
            .init("Kiro session expired. Run `kiro-cli login` and try again.")
        }
    }
}

extension KiroUsageError: UserPresentableError {
    var presentationMessage: LocalizedMessage {
        switch self {
        case .connectionFailed:
            .init("Usage request failed. Check your connection.")
        case .requestFailed(let status):
            .init("Usage request failed (HTTP %@). Try again later.", [String(status)])
        case .invalidResponse:
            .init("Usage response invalid. Try again later.")
        case .quotaUnavailable:
            .init("Kiro credit usage is unavailable for this account.")
        }
    }
}

extension AntigravityError: UserPresentableError {
    var presentationMessage: LocalizedMessage {
        switch self {
        case .notSignedIn:
            .init("Start Antigravity or run `agy` and try again.")
        case .credentialStoreUnreadable:
            .init("Couldn't read Antigravity credentials from Keychain. Unlock Keychain or sign in to Antigravity again.")
        case .invalidCredentialData:
            .init("Antigravity credentials are invalid. Open Antigravity or run `agy` to sign in again.")
        case .authExpired:
            .init("Antigravity sign-in expired. Open Antigravity or run `agy` to refresh.")
        case .unavailable:
            .init("Antigravity usage is temporarily unavailable. Try again shortly.")
        }
    }
}

extension DevinAuthError: UserPresentableError {
    var presentationMessage: LocalizedMessage {
        switch self {
        case .notLoggedIn:
            .init("Run devin auth login or sign in to Devin and try again.")
        }
    }
}

extension DevinUsageError: UserPresentableError {
    var presentationMessage: LocalizedMessage {
        switch self {
        case .invalidResponse, .quotaUnavailable:
            .init("Devin quota data unavailable. Try again later.")
        }
    }
}

extension CopilotAuthError: UserPresentableError {
    var presentationMessage: LocalizedMessage {
        switch self {
        case .notLoggedIn:
            .init("Sign in to GitHub Copilot in your editor, or run gh auth login, and try again.")
        case .tokenInvalid:
            .init("GitHub token invalid or expired. Re-authenticate (gh auth login) and try again.")
        }
    }
}

extension CopilotUsageError: UserPresentableError {
    var presentationMessage: LocalizedMessage {
        switch self {
        case .invalidResponse:
            .init("Copilot usage response invalid. Try again later.")
        case .connectionFailed:
            .init("Couldn't reach GitHub. Check your connection.")
        case .requestFailed(let status):
            .init("Copilot usage request failed (HTTP %@). Try again later.", [String(status)])
        case .quotaUnavailable:
            .init("Copilot usage data is unavailable for this account.")
        }
    }
}

extension OpenRouterAuthError: UserPresentableError {
    var presentationMessage: LocalizedMessage {
        switch self {
        case .missingKey:
            .init("No OpenRouter API key. Set OPENROUTER_API_KEY or add it to ~/.config/openusage/openrouter.json.")
        case .invalidKey:
            .init("OpenRouter API key invalid. Check your key at openrouter.ai/keys.")
        case .saveFailed:
            .init("Couldn't save the OpenRouter API key.")
        case .deleteFailed:
            .init("Couldn't remove the saved OpenRouter API key.")
        }
    }
}

extension OpenRouterUsageError: UserPresentableError {
    var presentationMessage: LocalizedMessage {
        switch self {
        case .connectionFailed:
            .init("Couldn't reach OpenRouter. Check your connection.")
        case .invalidResponse:
            .init("OpenRouter usage data unavailable. Try again later.")
        case .requestFailed(let status):
            .init("OpenRouter request failed (HTTP %@).", [String(status)])
        }
    }
}

extension ZAIAuthError: UserPresentableError {
    var presentationMessage: LocalizedMessage {
        switch self {
        case .missingKey:
            .init("No Z.ai API key. Set ZAI_API_KEY or add it to ~/.config/openusage/zai.json.")
        case .invalidKey:
            .init("Z.ai API key invalid. Check your key at z.ai/manage-apikey/apikey-list.")
        case .saveFailed:
            .init("Couldn't save the Z.ai API key.")
        case .deleteFailed:
            .init("Couldn't remove the saved Z.ai API key.")
        }
    }
}

extension ZAIUsageError: UserPresentableError {
    var presentationMessage: LocalizedMessage {
        switch self {
        case .connectionFailed:
            .init("Usage request failed. Check your connection.")
        case .invalidResponse:
            .init("Usage response invalid. Try again later.")
        case .requestFailed(let status):
            .init("Usage request failed (HTTP %@). Try again later.", [String(status)])
        case .noCodingPlan:
            .init("No active GLM Coding Plan. Subscribe at z.ai/subscribe to see usage.")
        }
    }
}

extension OpenCodeUsageError: UserPresentableError {
    var presentationMessage: LocalizedMessage {
        switch self {
        case .notLoggedIn:
            .init("OpenCode not detected. Log in with OpenCode Go or use OpenCode locally first.")
        case .credentialsUnreadable:
            .init("Couldn't read OpenCode's auth.json. Check its file permissions or log into OpenCode Go again.")
        case .databaseUnreadable:
            .init("Couldn't read OpenCode's local database. Quit OpenCode and refresh, or check the data directory's permissions.")
        }
    }
}

extension CodexWeeklyTimerProviderError: UserPresentableError {
    var presentationMessage: LocalizedMessage {
        switch self {
        case .accountChanged:
            .init("Weekly timer account changed. Refresh this account and try again.")
        case .weeklyQuotaUnavailable:
            .init("Weekly timer could not verify this account's weekly usage.")
        case .credentialsChanged:
            .init("Weekly timer credentials changed. Refresh this account and try again.")
        }
    }
}
