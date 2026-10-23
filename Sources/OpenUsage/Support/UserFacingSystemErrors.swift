import Foundation

extension AccountCredentialVaultError: UserPresentableError {
    var presentationMessage: LocalizedMessage {
        .init("The saved sign-in is missing or invalid. Sign in again and retry.")
    }
}

extension SoftLimitControlError: UserPresentableError {
    var presentationMessage: LocalizedMessage {
        switch self {
        case .unavailable:
            .init("No local cancellation connection. Connect your AI client first.")
        case .unsafeEndpoint:
            .init("The local control socket has unsafe ownership or permissions.")
        case .disconnected:
            .init("The cancellation connection closed. Some tasks may still be running.")
        case .invalidResponse:
            .init("The AI client returned an unsupported control response.")
        case .rejected:
            .init("The AI client rejected the cancellation control request.")
        case .timedOut:
            .init("Cancellation was not confirmed in time. Some tasks may still be running.")
        case .wrongProvider:
            .init("The task does not belong to this provider.")
        }
    }
}

extension BunInstallerError: UserPresentableError {
    var presentationMessage: LocalizedMessage {
        switch self {
        case .unsafeInstallDirectory:
            .init("BUN_INSTALL must be a shell-safe absolute directory inside your home folder.")
        case .existingBunWithoutBunx:
            .init("Bun is installed, but bunx is unavailable. Repair the existing Bun installation and try again.")
        case .installationInProgress:
            .init("Bun installation is already in progress.")
        case .downloadFailed:
            .init("Bun could not be downloaded. Check your connection and try again.")
        case .invalidHTTPResponse:
            .init("The Bun installer returned an invalid response.")
        case .unexpectedHTTPStatus(let status):
            .init("The Bun installer returned HTTP status %@.", [String(status)])
        case .disallowedRedirect:
            .init("The Bun installer redirected to an unsupported address.")
        case .emptyInstaller, .invalidInstaller:
            .init("The downloaded Bun installer is invalid.")
        case .installerTooLarge:
            .init("The downloaded Bun installer is unexpectedly large.")
        case .temporaryWorkspaceFailed:
            .init("A private workspace for the Bun installer could not be created.")
        case .installerFailed(let exitCode):
            .init("Bun installation exited with status %@.", [String(exitCode)])
        case .verificationFailed:
            .init("Bun installation finished, but Bun and bunx could not be verified.")
        }
    }
}

extension StreamingProcessRunnerError: UserPresentableError {
    var presentationMessage: LocalizedMessage {
        switch self {
        case .executableMustBeAbsolute:
            .init("The executable path must be absolute.")
        case .currentDirectoryMustBeAbsolute:
            .init("The working-directory path must be absolute.")
        case .invalidTimeout:
            .init("The command timeout must be finite and greater than zero.")
        case .invalidOutputLimit:
            .init("The command output limit cannot be negative.")
        case .standardInputTooLarge:
            .init("The command’s standard input exceeds the pipe buffer limit.")
        case .invalidArgument:
            .init("Command arguments cannot contain null bytes.")
        case .invalidEnvironment:
            .init("The command environment is malformed.")
        case .outputReadFailed:
            .init("The command output could not be read.")
        case .processWaitFailed:
            .init("The command exit could not be confirmed. Please try again.")
        case .timedOut(let timeout):
            .init("The command timed out after %@ seconds.", [String(timeout.formatted())])
        }
    }
}

extension TokscaleDeviceNameError: UserPresentableError {
    var presentationMessage: LocalizedMessage {
        switch self {
        case .empty:
            .init("Enter a device name.")
        case .containsControlCharacter:
            .init("Device names can’t contain control characters.")
        case .tooLong:
            .init("Device names must be 120 UTF-8 bytes or fewer.")
        }
    }
}

extension AccountIdentityReplacementError: UserPresentableError {
    var presentationMessage: LocalizedMessage {
        switch self {
        case .pendingTransaction:
            .init("Another account sign-in update is still being recovered. Try again after the next refresh.")
        case .invalidTransaction:
            .init("The saved account sign-in update could not be recovered. Check the app log and try again.")
        }
    }
}

extension ICloudUsageSyncError: UserPresentableError {
    var presentationMessage: LocalizedMessage {
        switch self {
        case .unavailable:
            .init("iCloud Drive isn’t available. Check that this Mac is signed into iCloud and iCloud Drive is on.")
        case .invalidDeviceID:
            .init("The saved iCloud sync device identifier is invalid.")
        }
    }
}

extension CodexSharedCredentialSynchronizationError: UserPresentableError {
    var presentationMessage: LocalizedMessage {
        .init("Codex sign-in was saved, but shared sign-in synchronization did not finish.")
    }
}

extension UsageHistoryDocumentError: UserPresentableError {
    var presentationMessage: LocalizedMessage {
        switch self {
        case .unsupportedSchema:
            .init("This Mac wrote a newer usage-history format. Update OpenUsage.")
        case .invalidDevice:
            .init("The synced Mac identity is invalid.")
        case .invalidProvider:
            .init("The synced provider identifier is invalid.")
        case .invalidDay:
            .init("The synced history contains an invalid date.")
        case .duplicateDay:
            .init("The synced history contains the same date more than once.")
        case .duplicateModel:
            .init("The synced history contains the same model more than once.")
        case .invalidValue:
            .init("The synced history contains an invalid usage value.")
        }
    }
}

extension GenericPasswordWriteError: UserPresentableError {
    var presentationMessage: LocalizedMessage {
        switch self {
        case .ambiguousService:
            .init("Multiple Keychain items matched the service; no credential was changed.")
        case .securityStatus(let status):
            .init("Keychain write failed (status %@).", [String(status)])
        }
    }
}

extension ProcessRunnerError: UserPresentableError {
    var presentationMessage: LocalizedMessage {
        switch self {
        case .timedOut(let executable, let timeout):
            .init("%@ timed out after %@s.", [String(executable), String(Int(timeout))])
        case .standardInputUnsupported:
            .init("This process runner does not support standard input.")
        case .standardInputFailed:
            .init("Could not send input to the process.")
        case .standardInputTooLarge:
            .init("Process input exceeds 4096 bytes.")
        case .outputReadFailed:
            .init("Could not read output from the process.")
        }
    }
}

extension HTTPClientError: UserPresentableError {
    var presentationMessage: LocalizedMessage {
        .init("Invalid HTTP response.")
    }
}

extension ClaudeUsageStateStore.StoreError: UserPresentableError {
    var presentationMessage: LocalizedMessage {
        switch self {
        case .identityUnavailable:
            .init("Claude account identity could not be verified. Sign in again before refreshing usage.")
        case .invalidRecord:
            .init("Claude usage retry data could not be read. Check the app log before retrying.")
        case .storageUnavailable:
            .init("Claude usage retry data could not be saved or opened. Check the app log and try again.")
        case .busy:
            .init("Another Claude usage request is still running. Try again after it finishes.")
        }
    }
}

extension AccountSignInWorkspace.WorkspaceError: UserPresentableError {
    var presentationMessage: LocalizedMessage {
        switch self {
        case .invalidComponent(let component):
            .init("Invalid sign-in workspace component: %@", [String(component)])
        case .outsideOwnedRoot(let path):
            .init("The sign-in workspace resolved outside OpenUsage's owned directory: %@", [String(path)])
        case .symlinkedComponent(let path):
            .init("OpenUsage can't use a symbolic link in its sign-in workspace: %@", [String(path)])
        }
    }
}

extension AccountCredentialSwitcher.Error: UserPresentableError {
    var presentationMessage: LocalizedMessage {
        switch self {
        case .unsupportedFamily(let family):
            .init("Account switching is not supported for %@.", [String(family)])
        case .missingSnapshot(let label):
            .init("No saved sign-in was found for %@. Sign in again and retry.", [String(label)])
        case .snapshotIdentityMismatch(let label):
            .init("The saved sign-in for %@ no longer matches its account. Sign in again and retry.", [String(label)])
        case .invalidClaudeState(let url):
            .init("Claude account state is invalid: %@", [String(url.path)])
        case .incompleteClaudeAuthentication:
            .init("Claude sign-in has not finished updating its account state. Finish signing in and try again.")
        case .switchVerificationFailed(let label):
            .init("Switching to %@ could not be verified, so the previous account was restored.", [String(label)])
        }
    }
}

extension AccountProfileError: UserPresentableError {
    var presentationMessage: LocalizedMessage {
        switch self {
        case .unknownFamily(let family):
            .init("Unknown tool: %@ (expected claude or codex)", [String(family)])
        case .invalidLabel:
            .init("Invalid account name.")
        case .duplicateLabel(let label):
            .init("An account named '%@' already exists. Choose a different name.", [String(label)])
        case .accountLimitReached(let limit):
            .init("All %@ account slots are in use. Remove an account first.", [String(limit)])
        case .profileNotFound(let reference):
            .init("No account matches '%@'.", [String(reference)])
        case .ambiguousReference(let reference):
            .init("'%@' matches multiple accounts. Use its id from 'openusage account list --json'.", [String(reference)])
        case .removeSelectedProfile:
            .init("This account is currently selected. Select another account before removing it.")
        case .registryUnreadable:
            .init("OpenUsage couldn't read the saved account list. It was left unchanged. Restart OpenUsage and check the log before trying again.")
        }
    }
}

extension AccountCredentialImporter.ImportError: UserPresentableError {
    var presentationMessage: LocalizedMessage {
        switch self {
        case .noSignIn(let family):
            .init("No %@ sign-in was found to import.", [family])
        case .identityUnreadable(let family):
            .init("The current %@ sign-in doesn't name its account, so it can't be imported.", [family])
        case .verificationFailed(let family):
            .init("The imported %@ sign-in could not be verified, so nothing was registered.", [family])
        }
    }
}

extension AccountCredentialImporter.RemovalError: UserPresentableError {
    var presentationMessage: LocalizedMessage {
        switch self {
        case .workspace:
            .init("OpenUsage couldn't delete this account's sign-in workspace. The account and its saved authentication were not removed — try again.")
        case .snapshot:
            .init("OpenUsage couldn't delete the saved Keychain authentication. The account remains registered and ready, so you can try removing it again.")
        }
    }
}
