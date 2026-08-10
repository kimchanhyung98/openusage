# Account-First Multi-Account Plan

The execution plan for multi-account Claude/Codex support, replacing the closed PR #1014 (branch `claude/provider-management-ux-780d96`, continued on `agent/multi-account-cli-pr1014`).
Those branches stay alive as **cherry-pick material** — most of their auth-store scoping, discovery internals, swap timeline, iCloud remapping, and ~4k test lines port into the phases below.

> Managed account switching in **Settings → Accounts** was implemented on top of this plan's record model; [Settings](/docs/settings.md) and [CLI](/docs/cli.md) document the current behavior.
> Managed accounts have a Remove action that deletes only OpenUsage's snapshot and workspace, while unmanaged discovered cards still follow the no-Remove rule below.
> This plan's identity-stable records describe discovered provider-account cards.
> A managed account is instead a user-named authentication record: re-sign-in may replace its provider identity, and multiple managed names may temporarily carry the same identity.
> Since then the card model changed: a provider gets one card whose layout is stored once, a config-dir login is shown only after it is registered in Settings, and card rename was removed — see [Dashboard](/docs/dashboard.md).

## Why the restart

PR #1014 keyed the default card by *location* (the default home) and every extra account by *identity*.
Review traced nearly every high-priority bug to that split: the default card's identity is mutable, so the branch accreted ~1.5–2k lines of guard machinery (same-account folds, duplicate suppression, launch gating, history withholding) defending a structural flaw — guards its own follow-up plan would then delete.
Since none of it ever shipped, no user has state that needs the staged migrate-shadow-flip choreography.
This plan flips to the account-first model **before** any multi-account discovery ships, so the guards never get written.

## Target model

Every card is an **account**: an opaque identity key with a stable record id minted at creation.
Places an account is signed in are **sources** (default home, config dir, cswap vault slot, Desktop/Cowork, Codex home) attached to its record.
"Default" is a badge on a source (`holdsDefaultSource`) used for the bare-id alias, CLI resolution, and attribution — never a key, never live sort order.
A swap re-points source edges; cards, history, layout, and pins never move.
An unresolved source claims no account.
A card renders only while at least one of its sources is found on this computer; when every source is gone the card stops rendering, and its record, layout, and history are retained so the card reattaches if the login reappears (owner decision 4 — no Remove affordance yet).

### The migration-killing decision

The account occupying the default home at conversion time **keeps the bare id (`claude`, `codex`) as its permanent record id**.
Ids are opaque, so nothing is special about the shape.
Every existing install migrates by doing nothing: layout keys, pins, history bindings, snapshot cache entries, and third-party API consumers keep working untouched.
If the user later swaps accounts at the default home, the new account mints `claude@<hash8>` and takes the default badge; the old card stays under its old id.
The bare id doubles as the family id in CLI/API requests, but there is **no alias resolution**: an id names providers by plain string matching (exact card id, or family id → every card of that family), and every match is returned.
The answer never depends on runtime state — which login holds the badge, what's enabled — and both surfaces always return the multi-provider shape (the limits envelope; a JSON array on `/v1/usage/:id`).

## Phases

Each phase is one PR, shipped to the **beta channel** and soaked before the next starts.
Docs and tests land in-slice (repo policy).
Estimated source LOC excludes tests.

### Phase 0 — Standalone reliability (no model change, ~300 LOC)

- Shell-environment snapshot: discovery-grade env facts survive a slow login shell (cherry-pick `22c8e97`).
- File splits along provider seams where they help review (`c96fc75`, as needed).
- Exit: beta with zero behavior change beyond launch reliability.

### Phase 1 — Account-first core, single account per family (~800 LOC)

- `ProviderAccountsStore` (`openusage.providerAccounts.v1`): account records with id, family, identityKey, label, sources (+ badge), tombstone.
  Port from `e052ef9`, dropping the shadow-comparison half — the registry is authoritative from day one.
- Default-home identity reading for Claude and Codex (the proven slice of discovery — **no candidate scanning yet**).
  Resolved identity attaches the default source; unresolved leaves the family rendering its current state.
- Cards render from account records.
  With exactly one account per family this is pixel-identical to today, so the structural flip ships invisibly.
- CLI + local HTTP API answer ids by plain string matching (family id → all its cards, always the multi-provider shape; unknown id → 404).
  One deliberate `/v1` break — `/v1/usage/:id` returns an array — made now, before multi-account ships, instead of aliasing forever.
- Snapshot-cache identity stamp (v9): cached values remember the producing account; a swap between launches discards the stale entry instead of painting it under the new account (port `fef9ad0`).
- Exit: beta soak; logs confirm identity-resolution rates in the wild; existing users see nothing.
- *Shipped as #1026 + #1027 (v0.7.7-beta.1).
  Signed-out rendering and "Remove Account…" were cut entirely per owner decision 4.*

### Phase 2 — Claude multi-account: config-dir discovery (~1,200 LOC)

> Superseded: a config-dir login is no longer a card and cannot be renamed; a provider has one card whose layout is stored once, and only registered accounts appear in its selector.

- Candidate scan (dot-dirs at `~`, dirs under `~/.config`), identity-extraction-is-validation, support-trail log lines.
  Port the discovery internals; **omit** fold/suppression plumbing — a candidate naming a known account just attaches as another source/log root on that record, so duplicate cards are structurally impossible.
- New account → new record → new card named by account label ("Claude — Sunstory"), falling back to the short-hash id; user rename in the card's context menu and in Customize.
  Cards seed enabled; layout seeded from `DefaultLayout.translatedForAccountCards` (pins never seeded).
  A card renders only while one of its sources is still found on this computer.
- Scoped `ClaudeAuthStore` (per-config-dir keychain names), per-account spend from each home's logs.
- iCloud identity routing: `PeerHistoryRemapper`, account-identity matching, v1-peer histories to a family bucket rendered as remote-only Total Spend slices named by account code (`claude@ab12cd34`).
  Required the moment two accounts can exist.
- Exit: beta soak with real multi-config-dir users; lifecycle test suite re-targeted green.
- *Shipped as #1030.*

### Phase 2b — One name resolver (~150 LOC)

- Follow-up to Phase 2's rename feature: name resolution had no single seam — some surfaces read the rename live from the registry, others (Total Spend legend, share export, menu bar accessibility, notifications, CLI/API) showed the name baked into the `Provider` at launch, so a mid-session rename drifted between surfaces.
- The rule: `Provider.displayName` only ever carries the *derived* default; a rename lives solely in the account registry (`ProviderAccountRecord.resolvedDisplayName`) and is resolved at render time.
  Renames are never baked at launch and never persist into the snapshot cache or iCloud.
- Total Spend slices carry a caller-resolved title (so the live legend and the outside-the-environment share render agree); menu bar VoiceOver text, quota notifications, and the CLI/HTTP API resolve through the same registry at their boundaries.

### Phase 3 — Claude: Cowork / Desktop accounts (~500 LOC)

- Cowork sandbox walk with per-sandbox identity; sandboxes matching an existing account attach as its log roots; a distinct account becomes one Desktop-backed card (org-pinned identity, Safe Storage credentials).
- Purely a new source kind on the existing model.

### Phase 4 — Claude: cswap (~500 LOC)

- Vault slot discovery: each parked slot is a source of its account; the active slot is whoever holds the default badge.
- Switch-log timeline partitions the shared home's spend logs per account.
- A swap is the badge moving between records — no suppression, no restart requirement.
  A mid-process swap marks the source stale; reconcile next launch.

### Phase 5 — Codex multi-account + per-card resets (~700 LOC)

- **5a:** `CODEX_HOME` candidate scan with the strict identity rule — `tokens.account_id` or the id_token's ChatGPT account claim; a credential file that can't name its account never becomes a card (port `93e741e`).
  Scoped auth stores and per-identity log-root grouping.
  The per-card `CodexResetClaimRouter` already landed with the managed-account layer, so every account's row claims its own reset credits from day one.
- **5b (separate if needed):** keyring-mode homes — an unverified keyring source claims no account until the one-time post-launch account-scoped read binds it (`CodexHomeIdentityCache`).
  The nichest slice; keeping it out of 5a keeps 5a simple.

### Phase 6 — Attribution polish (small)

- Pi spend attribution routed through the resolver to the badge holder.
- Family-keyed telemetry rollups (`accounts_per_family` gauge).
- Total Spend family grouping/tinting if still wanted (see `c6a63eb` on the old branch for why plain size order won before).

## Owner decisions (locked 2026-07-19)

1. **Bare id as the first account's record id** — yes (kills all migration).
2. Label fallback when an account has no email/org name: the short-hash record id (`claude@ab12cd34`).
   Superseded: rename was removed, so the fallback stands on its own.
3. Newly discovered accounts seed **enabled** (PR #1014 behavior).
4. **No "Remove Account…" yet.**
   Only accounts found on this computer render as cards; a card whose account is no longer found anywhere simply stops rendering (its record, layout, and history are retained and reattach if the login reappears).
   Unwanted cards are handled by the existing per-provider disable.
   Tombstones stay schema-only until a later phase needs true removal.

## Release verification for the managed-account layer

- Run `swift build` and the full `swift test` suite.
  Include the account registry, credential transaction, workspace, shell installer, dashboard-selection, and per-card claim regressions.
- Verify that unmanaged config-dir cards still render independently with zero or one managed profile.
  Verify that two or more managed profiles collapse only their own cards into the selector.
- Run `script/build_and_run.sh`, then inspect `~/Library/Logs/OpenUsage/OpenUsage.log` for account registry, identity, switch, rollback, and refresh failures.
- Exercise both Claude and Codex live: import the first account, add a second account, switch, start a fresh terminal session, view an inactive account, re-sign in, and remove it.
  Verify that an expired credential either refreshes or becomes **Sign-In Needed**, and that a completed re-sign-in replaces the selected managed account's authentication and provider identity without changing its name or selection.
- Verify the read-only account CLI plus the existing card CLI/API ids and response shapes.
- Repeat the two-Mac iCloud compatibility check before release.
  Managed account metadata and credentials remain local, while synced usage history must keep working with older readers.
