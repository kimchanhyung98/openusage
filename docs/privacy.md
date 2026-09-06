# Privacy & Usage Data

OpenUsage can share **anonymous** usage data to help understand how the app is used and catch problems.
It is off by default; opt in any time in **Settings → Privacy → Share Anonymous Usage**.

## Anonymous analytics: what is shared

When sharing is on, OpenUsage sends two kinds of small daily summaries: one app-use event per day and, for each provider refreshed that day, at most one provider-refresh event:

- **App use** — that the app was active today, the app and macOS version, which providers and metrics you have enabled, and which metrics you've pinned to the menu bar or tucked behind the "show more" caret.
  A random ID (not tied to you or any account) lets us count daily active users without identifying anyone.
- **Provider refreshes** — per provider, how many refreshes succeeded or failed that day, the **kinds** of errors that happened (for example "not logged in", "network", or an HTTP status group), and how many manual refreshes you triggered.

It also reports **crashes**, so we can find and fix the bugs that make the app quit unexpectedly:

- **Crash reports** — if OpenUsage crashes, it saves a report and sends it the next time you open the app: the technical stack trace (which parts of *OpenUsage's own code* were running when it crashed) plus the app and macOS version.
  This contains no account details, credentials, or usage values — just where in the app the crash happened.

## Anonymous analytics: what is never shared

- No account details, names, emails, or credentials.
- No actual usage **values** (no spend amounts, token counts, or limits).
- No error **messages** or file paths — only coarse error categories as counts.
- Nothing while the toggle is off.

## Credentials stored on this Mac

OpenUsage primarily reads credentials that provider tools already keep on your Mac.
When it writes a user-supplied API key or saves a refreshed credential, the file is replaced atomically and restricted to your macOS account (owner read and write only).
Antigravity's short-lived refreshed-token cache is tied to the current Keychain login using a one-way fingerprint; the refresh credential itself is not copied.
The cache is never used after logout, an account change, or while Keychain access is unavailable.

Claude Desktop access is strictly read-only.
OpenUsage may ask macOS for permission to use the `Claude Safe Storage` Keychain item so it can decrypt Desktop's current access token.
It never uses Desktop's rotating refresh token and never modifies Desktop's config, cookies, or Keychain data.

Managed account switching ([**Settings → Accounts**](/docs/settings.md)) keeps one authentication snapshot per account in your macOS Keychain under a service name that starts with `OpenUsage Account Authentication`.
This snapshot lets OpenUsage restore the previous sign-in when you switch back.
Each snapshot holds the credential file contents currently saved under that account name, stays private to your macOS login Keychain, and is never sent anywhere.
When the selected managed Claude account signs in through the official CLI in an ordinary terminal, OpenUsage verifies the new shared-home credential and replaces that account's snapshot and stored provider identity.
The account name and selection remain unchanged even if the verified provider identity changes; an incomplete or unverifiable credential is not copied.
Official sign-ins for additional accounts run in an app-owned workspace under `~/Library/Application Support/OpenUsage/AccountSignIn/<provider>/<account-id>/`.
Workspace directories use `0700`, and credential files use `0600`.
Removing an account deletes that workspace first and then its Keychain snapshot.
If either deletion fails, the account remains registered so you can retry.
Your `~/.claude` and `~/.codex` data is never moved or deleted.
A confirmed switch also updates a small `claude`/`codex` function in `~/.zshrc` or `~/.config/fish/config.fish`.
The function is wrapped in `>>> OpenUsage` comment markers, and deleting that marked block removes it.

Managed account names, current provider-identity bindings, selected-account state, sign-in readiness, and authentication snapshots are local to this Mac and are not included in iCloud Sync.
Only normalized usage history is eligible for iCloud.
Shared managed-home history is synced as a provider-family total, not under the currently selected account.

## Other network requests

Besides the provider API calls the vendor's own tools would make, OpenUsage fetches public [model price lists](pricing.md) about once an hour (from `raw.githubusercontent.com`, `models.dev`, and this project's GitHub Pages).
These are plain downloads of public data — they carry no usage, log, or account information, and they run regardless of the Share Anonymous Usage setting.
OpenUsage computes spend tiles from local CLI logs on your Mac and does not send those logs during normal refreshes or through anonymous analytics.

To avoid re-reading unchanged Claude, Codex, and pi logs after every relaunch, OpenUsage keeps their parsed usage events in `~/Library/Application Support/OpenUsage/log-scan-cache/`.
These records contain the usage metadata needed for local totals, including any per-event cost already recorded by a provider, but not raw JSONL lines or conversation text.
They are private to your macOS account and are never sent to PostHog, a provider, or iCloud.
Old source-file records are dropped as the scan window advances, and identity caches that have not been used for 35 days are removed.
OpenUsage's pricing engine runs after the cache is read, so its computed aggregates and totals are not persisted in this cache.

If you explicitly turn on [iCloud Sync](icloud-sync.md), OpenUsage writes normalized daily tokens, spend, and model totals to its private iCloud container so your own Macs can show one combined summary.
Credentials, account limits, provider responses, and raw logs are never written there.
This is separate from anonymous usage sharing: iCloud Sync defaults off and uses your iCloud account, while the analytics toggle controls PostHog events.

## Tokscale public sharing

The Tokscale action is a third, independent sharing flow.
Neither iCloud Sync nor Share Anonymous Usage enables it, and changing Tokscale state changes neither of those settings.
No app launch, refresh, background task, widget update, `openusage` CLI invocation, or local API request triggers Bun installation or Tokscale.

Only an explicit **Sync Now** in Settings runs:

```sh
bunx tokscale@latest submit
```

That command asks the Tokscale package resolved by `bunx` to discover its supported sources and update a public profile that may be indexed by search engines.
Verified against Tokscale v4.15.1 on 2026-09-04, the CLI may include token and cost breakdowns, dates, clients, models, message and timing statistics, device information, discovered MCP server names, and the Tokscale CLI version.
The CLI may read local session files to calculate those aggregates, but Tokscale's current policy excludes prompts, responses and conversation content, source code, file contents and names, and AI-provider API keys or credentials from submission.
OpenUsage does not derive the submission from its widgets, iCloud history, or anonymous analytics and does not apply its provider settings as a filter.
OpenUsage merges the app and captured login-shell environments so the current `@latest` CLI, rather than an OpenUsage provider list, remains responsible for source discovery.
The child can therefore access exported credentials and other secrets in that environment; OpenUsage does not inspect or log those values.
Known runtime-injection settings, Tokscale test hooks, custom Tokscale API endpoints, and a custom terminal `HOME` are not forwarded; the command uses the current macOS account's home as both `HOME` and its working directory.
Tokscale uses its own token to authenticate the request; its current policy excludes AI-provider API keys and credentials from the submitted usage data.

The device name saved through **Name…** is a public label and can identify the machine on the Tokscale profile.
OpenUsage stores it locally and supplies it only to the submit process as `TOKSCALE_DEVICE_NAME`; a value such as `m1-max` replaces the display label for the same stable device on its next successful submission.
Saving or changing the name alone makes no network request.
Removing the override does not clear Tokscale's existing public name; it lets later submissions use the name from Tokscale's environment or stored device record again.

If the submit command reports a verified missing-login result, OpenUsage offers a separate **Log In…** action that runs `bunx tokscale@latest login`.
Login alone does not submit usage, and completing it never starts submit automatically.
The current login flow lets Tokscale store the GitHub numeric ID, username, display name, avatar URL, and email.
During a new login, the command also sends `CLI on <hostname>` as the personal-token name; that token name is separate from the public submission-device label and is not changed by **Name…**.
A later submission creates or updates the public profile, which can show the GitHub username, avatar, and display name.

When an explicit **Sync Now** cannot find a usable Bun runtime, OpenUsage downloads and runs Bun's official installer before continuing.
The installer creates or updates files in a safe configured `BUN_INSTALL` directory below the current user's home or `~/.bun` by default and may append Bun's path setup to the login shell profile; it does not require administrator access.
Its child process receives exported proxy and certificate settings for the binary download, but not other login-shell values.
OpenUsage does not modify an incompatible `BUN_INSTALL` outside that boundary and instead offers the manual installation guide.
The mutable Bun installer and `@latest` are part of the disclosure boundary: they may download and execute Bun or Tokscale code that changed without an OpenUsage update.
The exact `bunx` command follows the user's Bun configuration and may prefer a matching package under the home directory.
See the official [Tokscale Privacy Policy](https://tokscale.ai/privacy), [Bun installation guide](https://bun.com/docs/installation), and [Bun `bunx` documentation](https://bun.com/docs/pm/bunx).

Installer and command output can contain usernames, browser URLs, authorization codes, local paths, model names, profile URLs, and usage values.
OpenUsage shows a bounded in-memory copy in the Settings card and login sheet, retains completion or failure output until the next command or app termination, and never writes it to the OpenUsage log, telemetry, UserDefaults, a file, or the clipboard automatically.
OpenUsage does not read or copy Tokscale's credential file and provides no Tokscale logout, disconnect, or remote-data deletion UI.

## How anonymous analytics works

- Anonymous analytics is fully anonymous: OpenUsage never identifies you to the analytics service and creates no user profile.
- Crash reports use the **same** Share Anonymous Usage switch — turn it off and crash reporting is off too, with no separate setting to find.
  While it's off, no crash report is recorded or sent.
- Counts are rolled up locally and sent as daily summaries, so the app's normal 5-minute refresh never turns into a flood of network calls.
- Your choice and the anonymous ID are stored separately from the rest of the app's settings, so settings migrations and updates do not re-enable sharing or change your ID.

## Controlling anonymous analytics

Open **Settings → Privacy** and switch **Share Anonymous Usage** on to opt in.
Switching it off stops sharing immediately.
