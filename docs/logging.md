# Logging

OpenUsage keeps a file log so you can capture what the app was doing and share it with support when something misbehaves.
Lines at or above your chosen level also go to the macOS unified log, so raising the level to Debug surfaces the extra detail in both places (see [Debugging](debugging.md) for `log stream`).

## Where the log file lives

```
~/Library/Logs/OpenUsage/OpenUsage.log
```

The easiest way to grab it: open Settings -> Advanced and use **Copy Log Path** (puts the path on the clipboard) or **Reveal in Finder** (selects the file in a Finder window).
No Terminal needed.

## Changing the log level (Settings -> Advanced)

The **Log Level** picker controls how much detail is written.
Your choice persists across launches and takes effect immediately — no restart.

| Level | What it captures |
|---|---|
| Error | Only failures. |
| Warning | Failures plus things that look wrong but recovered. |
| Info | The normal story: refresh start/end, per-provider results, cache and auth milestones. |
| Debug | Everything, including per-request and per-cache-check detail. |

The release default is **Info** — quiet but useful.
**Debug** is opt-in; turn it on only while reproducing a problem, since it is much noisier.

If a local usage log exists but cannot be read, OpenUsage writes one warning and skips it for that refresh.
It does not repeat the warning every five minutes; it warns again only after a confirmed successful read followed by another read failure.
A missing file does not count as recovery.
The shared diagnostic module writes one local record for each reported failure: Error for a failed operation, Warning when an optional step fails and the main result remains usable.
The record includes a fixed operation, error category, and available local context or error domain and code; raw error descriptions are excluded.
Terminal helper shell failures use the subprocess category; authorization denials use permission, and unrecognized failures remain other.
Update-download network failures retain the network category through Sparkle download errors, and pricing feeds with unusable JSON structures use decoding.
Cancelled downloads remain cancelled when the cancellation is wrapped in a Sparkle download error.
Normal missing-login, unavailable-plan, and empty Reset Watch vote results stay at Info, and user cancellation is not treated as a failure.
HTTP transport details stay at Debug; the operation handling the failure records its final error or partial-failure warning.

Any provider refresh that takes 10 seconds or longer writes a Warning-level `[refresh]` line with the provider ID, elapsed milliseconds, and threshold.
This is visible at the default Info setting, so a slow local-log scan or network call can be identified from a normal support log without reproducing it with Debug enabled.
The warning is diagnostic only: other provider cards still update independently, and the slow provider is allowed to finish.

## Subsystem tags

Every line is prefixed with a bracketed tag so the log is easy to grep:

`[refresh]` `[cache]` `[http]` `[auth]` `[keychain]` `[menubar]` `[updates]` `[config]` `[subprocess]` `[localapi]`, plus per-provider tags like `[plugin:claude]` and `[auth:claude]`.

For example, to follow just the refresh cycle:

```sh
grep '\[refresh\]' ~/Library/Logs/OpenUsage/OpenUsage.log
```

## What is never logged

Secrets never reach the log.
Access/refresh tokens, cookies, session tokens, and API keys are redacted before any line is written (a sensitive value becomes `first4...last4`, or `[REDACTED]` when too short to mask safely), and filesystem paths under your home directory are replaced with `[PATH]`.
Response bodies are never logged in full; on an HTTP error the app may record a redacted, truncated (≤500 byte) preview at Debug to aid diagnosis — run through the same redaction first.
Local API request logs keep only a fixed method and route category; query strings, account-specific path segments, and unknown request text are excluded.
Local logs can still contain diagnostic account-card identifiers; they are separate from the more restrictive anonymous analytics payload.

## Anonymous Diagnostic Events

With **Share Anonymous Usage** enabled, provider results and selected feature operations also feed structured PostHog events.
Changing the local log level does not change this consent setting or the event payload.
These events allow only fixed operation names, result and error categories, provider families, dates, versions, build channels, and counts.
Raw log lines, local context, error domains and codes, account IDs, command output, and usage values are excluded.
When sharing is already enabled at launch, diagnostic collection starts before iCloud device identity initialization, so its failures are counted too.

Provider summaries separate explicit manual refreshes from account changes, credential changes, reset claims, and scheduled work.
Successful limit refreshes with an unavailable history scan or optional endpoint are recorded as partial failures when that condition is reported by the provider.
Invalid Codex reset-credit responses keep the usage-response fallback and record a decoding partial failure.
Cursor request-based fallback failures preserve their HTTP, network, or decoding category, and successful fallbacks are counted too.
iCloud records each distinct peer-file error category once per completed read and ignores results from a sync that was stopped or restarted.
The first unexpected failure, partial failure, or recovery for a category can be sent immediately, capped at 30 events per local day; all recorded results remain in daily counts.
Recovery events are limited to operations independent of account identity; one account's successful refresh does not declare another account's failure resolved.
Claude, Codex, and Cursor record each token refresh request and response validation separately from saving the refreshed credentials.
If Claude credentials change before the guarded save, the save records an account-binding change while preserving the existing re-read behavior.
A replaced Claude login starts a fresh result while keeping the earlier failure diagnostic; a fallback within the same login retains any unresolved credential-save partial failure.
Token refresh and credential saving do not generate recovery alerts across accounts.
The daily check runs before refresh work and on an independent one-minute timer.
Cancelling the refresh loop stops that timer even while account reconciliation is still waiting.

PostHog transport logs report a fixed endpoint category and HTTP status or transport error code, without request bodies, tokens, or URLs.
An HTTP success confirms a response from ingestion, not that an event is visible in a dashboard or that a crash has resolved symbols.
See [Privacy & Usage Data](/docs/privacy.md) for consent, queue deletion, and crash-handler limits.

## File size cap

The log is capped at ~10 MB.
When it fills up, the current file is rotated to `OpenUsage.1.log` and a fresh `OpenUsage.log` starts, so a long-running session can never fill your disk (at most ~20 MB across the live file and one archive).
An oversize file left over from a previous session is rotated once at launch.
Independent writers coordinate appends and rotation with a shared file lock, so the app and CLI do not overwrite one another's lines.

> Note: the dev build and a released build both write to the same `OpenUsage.log`.
> Running them at the same time interleaves their lines — fine for normal use, worth knowing if you debug both at once.
