# Claude

Tracks your Claude subscription limits using the login you already have from Claude Code or Claude Desktop.

## What it tracks

| Metric | Meaning |
|---|---|
| Session | 5-hour rolling window usage |
| Weekly | 7-day window usage |
| Sonnet | Separate weekly Sonnet limit (plan-dependent) |
| Fable | Separate weekly Fable limit (model-scoped window from the `limits` array) |
| Extra Usage | Extra-usage credits spent against your monthly cap |
| Today / Yesterday / Last 30 Days | Local spend, as cost, tokens, or both (see below) |

When Claude reports your plan name, OpenUsage shows it beside the provider name.

## Where credentials come from

Sign in with Claude Code or Claude Desktop; OpenUsage reads the existing login.
It checks these sources, preferring one that can read your subscription usage:

1. The macOS keychain entry Claude Code maintains (its source of truth on macOS)
2. `~/.claude/.credentials.json` (or `$CLAUDE_CONFIG_DIR/.credentials.json`)
3. Claude Desktop's encrypted login cache, when no working Claude Code login is available
4. `CLAUDE_CODE_OAUTH_TOKEN` environment variable

While accounts are registered in [**Settings → Accounts**](/docs/settings.md) (or another Claude login sits in a custom config dir), the Desktop fallback is not used — that login could belong to a different account, so an authentication failure surfaces as re-login instead.

Claude Desktop support is read-only.
OpenUsage decrypts its currently valid access token using the `Claude Safe Storage` item in your macOS Keychain.
It never reads or uses Desktop's refresh token, and never changes Desktop's config, cookies, or Keychain entry.
This prevents OpenUsage from invalidating Claude Desktop's session.

macOS asks once before OpenUsage can access that Keychain item.
Background refreshes never open the password dialog: OpenUsage first asks you to refresh manually, and choosing **Always Allow** makes later refreshes silent.
If Desktop's short-lived token expires, open Claude Desktop so it can renew the login, then refresh OpenUsage.

A `CLAUDE_CODE_OAUTH_TOKEN` — usually a long-lived `claude setup-token` — can run the model but can't read your Session and Weekly limits, and it often lingers in your shell environment.
So when a real keychain or file login is present, OpenUsage uses that login for the live meters and keeps the environment token only as a fallback; the Session/Weekly meters no longer go blank just because that token is set.
If the environment token is your *only* credential (a headless setup), it's used on its own and the spend tiles still load from local logs.

If one source holds an expired or "locked out" token, OpenUsage falls back to the others — so signing in again with `claude` outside the app is picked up on the next refresh, without restarting OpenUsage.
For the selected managed Claude account, this is also a write-back boundary: after the shared-home login proves a usable provider identity, OpenUsage replaces that account's saved snapshot and stored identity and updates its readiness.
The account name and selection stay unchanged when the identity changes; incomplete or unverifiable authentication is never written.
Claude Code tokens are refreshed automatically; rotated tokens are written back only while the ordered login candidates still match the start of the refresh, so a newly added higher-priority login wins.
Claude Desktop tokens are never refreshed or written by OpenUsage.

## The spend tiles

Today / Yesterday / Last 30 Days are computed **locally**: OpenUsage reads the Claude Code session logs under `~/.claude/projects/` (or `$CLAUDE_CONFIG_DIR`) itself — no external tools needed.
Symlinks are followed, so a projects folder linked into a synced location (say, a Dropbox folder) is read all the same.
Claude usage from the [pi](https://github.com/earendil-works/pi) coding agent counts too: OpenUsage reads pi's session logs under `~/.pi/agent/sessions/` (or `$PI_CODING_AGENT_SESSION_DIR`) and folds any Claude usage there into the same tiles and trend, so a Claude sub driven through pi still shows up here.
pi records its own per-message cost, so those dollars come straight from pi rather than being re-estimated.
Cowork (the Claude desktop app's agent mode) counts too: it writes the same logs into per-session folders under `~/Library/Application Support/Claude/local-agent-mode-sessions/`, and OpenUsage scans those as well, so desktop agent sessions show up in the tiles alongside terminal ones.
Persisted `claude -p` runs count as well.
Runs made with `--no-session-persistence` cannot appear because Claude deliberately writes no session log for OpenUsage to read.
Advisor work recorded inside a message is counted once under the advisor's own model; the parent's main-model totals are kept separate, and ordinary iteration details are not counted again.
A log's recorded fast or standard speed controls its price; OpenUsage does not infer speed from the event date.
Days are grouped in your Mac's local time zone, so they line up with your own calendar.
Each period is one tile showing cost and tokens together (`$4.08 · 1.2M tokens`); a day with no usage reads **No data** rather than a misleading `$0.00 · 0 tokens` — the same as every other spend-tracking provider.
The live Session and Weekly meters are unaffected.
The dollars are estimated from token counts at API rates (that's the ⓘ) using the shared [model pricing](../pricing.md); the token counts themselves are measured.
No log data leaves your Mac.

When another Claude login sits in a custom config directory, pi entries are omitted because pi logs cannot identify which Claude login produced them.
This avoids assigning shared logs to the wrong account.
Otherwise pi usage stays in the Claude card's tiles like the rest of the shared home's logs.

## Other config-directory logins

OpenUsage shows the account signed in to the shared home (`~/.claude`) plus the accounts you register in **Settings → Accounts** — nothing else.
A Claude login sitting in a custom config dir (a separate `CLAUDE_CONFIG_DIR` home) is not a card, not an entry in the account selector, and not in the [CLI](../cli.md) or [local API](../local-http-api.md).
Register that account in Settings to see it.

A custom dir signed into the same account as the shared home is different: its session logs count into that account's spend tiles, since they belong to the account already on screen.

## Managed account switching

**Settings → Accounts** manages named Claude accounts.
The first account imports your current sign-in without a new login.
An additional account signs in through the official flow inside an app-owned workspace, so the active login is never disturbed.
Switching keeps the shared Claude configuration directory (`~/.claude`) in place and replaces only authentication.
The credential and account identity in Claude's state files change, while MCP settings, memory, sessions, and onboarding remain available in new Claude Code sessions.
Each account's authentication snapshot is stored in the macOS Keychain.
An inactive account's usage card reads from that snapshot.
Inactive account cards appear in the [local API](/docs/local-http-api.md) under ids like `claude@profile-…`.

Claude follows the shared **Usage Cards** setting in **Settings → Accounts**.
The default **Single Card** keeps one **Claude** card with the existing account selector; **Separate Cards** shows one card per available account without a selector.
Separate Cards uses the fixed title format **{Provider}: {name}**, such as **Claude: company**.
See [Settings](/docs/settings.md) for account order and [Dashboard](/docs/dashboard.md) for card display and sharing behavior.

The dashboard account picker changes only which account's usage is shown and never changes the account a new Claude session uses.
Local spend and trend logs stay with the shared configuration home and are not attributed to managed accounts.
In **Single Card**, those rows can still show **No data** while viewing an inactive snapshot account.
In **Separate Cards**, **Usage Trend**, **Today**, and **Yesterday** follow the existing metric settings only on the active account card backed by the actual shared-home login; inactive cards omit these rows entirely.
Adding, renaming, re-signing, or removing an account updates the dashboard immediately.
The picker and separate cards show the shared home's account plus the accounts registered in Settings.
Registered account names stay separate selector entries and individual cards even when two of them currently prove the same provider identity.

The ordinary terminal is a supported reauthentication path for the selected managed account.
Start `claude` in a new terminal and use `/login`, or run `claude auth login`, then complete any valid Claude sign-in you want stored under the account name selected in Settings.
OpenUsage verifies the shared `~/.claude` login, replaces that named account's private Keychain snapshot and stored provider identity, and refreshes its status without requiring **Sign In Again** or an app restart.
Signing in as another provider identity does not rename the account or silently select another managed account.

## Troubleshooting

- **"Not logged in"** — for the selected managed account, start `claude` in a new terminal and use `/login`, or run `claude auth login`, complete the sign-in you want stored under that account name, and refresh OpenUsage.
  `claude auth status` must report `loggedIn: true`, and the shared Claude home must resolve to one coherent identity before OpenUsage updates the managed snapshot automatically.
  If its state files name different accounts, cannot be parsed, or are older than a new Keychain credential without belonging to the existing credential chain, OpenUsage preserves the existing snapshot.
  **Settings → Accounts → Manage… → Sign In Again** remains an alternative recovery path.
- **"Claude Desktop login found"** — refresh manually and choose **Always Allow** when macOS asks for access to `Claude Safe Storage`.
- **"Claude Desktop login is stale"** — open Claude Desktop so it can renew the login, then refresh OpenUsage.
- **"Re-login for live usage"** (an amber warning on the Claude header) — your saved login can authenticate for inference but can't read your subscription limits, because it lacks the `user:profile` access (this is what an inference-only token from `claude setup-token` carries).
  Run `claude` and sign in again with your Claude account, then refresh; the spend tiles keep working in the meantime.
- **"Updates blocked by Anthropic"** (an amber warning on the Claude header) — the usage API is throttling OpenUsage.
  It keeps the last values from the same login, shows when it will retry, and backs off in the meantime.
  A different login starts with a fresh cache and cooldown.
- **Spend tiles show "No data"** — OpenUsage found no Claude Code logs in the last 30 days.
  Outside managed account switching, set `CLAUDE_CONFIG_DIR` when your logs live somewhere custom so Claude Code and OpenUsage look in the same place.
  Managed terminal switching uses the shared `~/.claude` home.
  A login kept in another custom home is not shown at all until you register it in Settings.

## Under the hood

`GET https://api.anthropic.com/api/oauth/usage` with the selected OAuth token.
Claude Code tokens refresh via `platform.claude.com/v1/oauth/token`; Claude Desktop tokens are read-only and must be renewed by Desktop itself.
If a token is expired or revoked, OpenUsage retries with the next credential source before reporting an error.

When the five-hour session window has no usage yet, the Session row shows **Not started** on the trailing label; hover explains that the session begins after your first message.
