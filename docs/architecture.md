# Architecture

A high-level map of how OpenUsage is put together, for people working on the code.
For what the app *does*, start with the [behavior docs](README.md).

## The shape of the app

OpenUsage is a SwiftPM package with a shared module and two thin executables — there is no Xcode project.
The main executable is a menu-bar app: a SwiftUI interface hosted inside an AppKit status item and panel.
The code is grouped by role:

- `App/` — startup and the AppKit bridge (status item, panel, the app entry point).
- `Models/` — the small value types the rest of the app speaks in (`MetricLine`, `WidgetData`, descriptors).
- `Providers/` — one folder per provider (Claude, Codex, Cursor, Devin, Grok, OpenCode, …).
- `Stores/` — the mutable state the UI observes.
- `Services/` — shared infrastructure (HTTP, the local API, process running).
- `Support/` — small shared helpers (formatting, parsing, animations).
- `Views/` — the SwiftUI screens (dashboard, customize, settings, menu-bar strip).

## Composition root

`AppContainer` is the one place that wires everything together.
At launch it builds the list of providers, turns it into a `WidgetRegistry`, creates the stores, starts the periodic refresh loop, and starts the local HTTP API.
Everything else receives what it needs from here rather than reaching for globals, which keeps the pieces testable in isolation.

The `openusage` executable imports the same module.
Every invocation constructs the canonical `ProviderCatalog` (including the launch account pass) and refreshes missing or stale entries through `WidgetDataStore` before reading `ProviderSnapshotCache`; `--force` only bypasses the five-minute freshness gate.
Providers annotate the scalar resources they export through the stable limits contract; the CLI and `/v1/limits` share one serializer over those same normalized snapshots.
It never launches the GUI or duplicates provider, auth, pricing, or mapping logic.

## The provider pipeline

Each provider is a small module that conforms to `ProviderRuntime`.
A refresh flows through three parts:

1. **Auth store** — reads credentials that already exist on the machine (config files, keychain).
   OpenUsage never asks the user to paste tokens.
2. **Usage client** — makes the HTTP calls to the provider's API.
3. **Mapper** — turns the provider's response into the app's own vocabulary: a `ProviderSnapshot` containing typed widget values (`.progress`, `.values`, `.badge`, `.chart`) plus `.text` notices that remain available through the local API but do not render as widgets.

Because every provider produces the same normalized `MetricLine` shapes, the UI renders them all the same way and doesn't need to know provider-specific details.
To add one, see [Adding a provider](adding-a-provider.md).

Claude, Codex, and pi share `IncrementalJSONLScanner` for local JSONL history.
Its per-file parsed events are cached by path, size, and modification time in a versioned Application Support store partitioned by provider/home identity.
Provider instances reading the same home share one scanner actor, which avoids duplicate parsing across cards.
The disk store provides reuse across process launches.
Scans drop source-file records as their modification dates leave the requested history window.
Aggregation and pricing still run on every refresh from the cached events.
The launch account pass assembles log roots for the shared home and read-only snapshot cards for inactive registered accounts.
Settings account actions repeat that pass, so cards follow account changes without a relaunch.
A Claude login found in a config directory that is not registered produces no card and no registry record; it only records that another login exists on this Mac.
The dashboard selector collapses every card of a provider into one, so each provider renders a single card.
Shared pi logs cannot identify which Claude login produced them, so they are omitted while another Claude login exists rather than assigned to the wrong account.
When a config dir is re-authenticated as a different account, reconciliation moves that source edge to the new identity while retaining the old record and its history.
For the selected managed Claude account, shared-home reconciliation is verification-guarded and bidirectional.
Any complete, verifiable login produced by the official Claude CLI replaces the selected record's saved authentication and current provider identity while preserving its stable id, account name, and selection.
Provider identity isolates credentials and cached usage during that replacement; it is not the immutable key or uniqueness constraint of a managed account.

Credential/cache identity and iCloud history attribution are separate.
A managed bare Claude/Codex runtime can have one current authentication identity while its shared-home logs contain sessions from several switched accounts.
That history is exported as a family total without the selected profile's identity.
Snapshot cards for registered accounts read one proven account's authentication, so their history stays identity-keyed.

## Stores

The UI reads from a few observable stores:

- `WidgetDataStore` — the latest snapshot per provider, plus refresh and caching.
  It keeps machine-local cached snapshots separate from rendered snapshots so peer history can never be written back out and counted again.
- `LayoutStore` — which metrics are shown, the provider/metric order, and which metrics are starred for the menu bar.
  It stores all of that once per provider, so every account card of a provider renders the same layout from that single set.
- `ProviderEnablementStore` — which providers the user has turned on or off.
- `ProviderAccountsStore` — the account-first registry for stable card ids and per-account sources for Claude/Codex sign-ins.
  `AccountProfilesStore` stores the managed account records and the selected account for each family.
  Each record contains a stable id, an editable account name, and the provider identity derived from its current saved authentication.
  Account names distinguish managed records; reauthentication may replace the stored identity, and more than one managed record may temporarily carry the same identity.
  The `openusage account` CLI reads the same records through the shared defaults domain.
  Account credentials live in per-account Keychain snapshots.
  Re-logins started by OpenUsage run in an app-owned sign-in workspace under Application Support.
  A selected Claude account may also reauthenticate through the official CLI in the shared configuration home; verification-checked reconciliation replaces the existing snapshot and stored provider identity with that result.
  The managed-account model — registry, Keychain snapshots, sign-in workspaces, and the switch transaction — is family-neutral, so account switching for additional providers extends the same mechanism instead of adding a parallel one.
- `ICloudUsageSyncStore` — one coordinated, atomic history file per Mac, iCloud metadata notifications, and the visible device/error state.
  File access is injected for lifecycle and failure tests.

Refresh runs on a timer in `AppContainer`; each pass respects the cache, so the network is only hit once a snapshot has actually expired.

Providers with spend tiles carry an explicit history scope beside their export descriptors.
Machine-local sources can be summed across device files; account-wide sources such as Cursor cannot.
`WidgetDataStore` re-renders only the spend rows from the union, leaving quota and error state local.

## Tokscale CLI boundary

The integration is a narrow external-process boundary, not another provider pipeline or sync engine.
The boundary has four responsibilities:

- `BunInstaller` runs only when an explicit **Sync Now** cannot find a usable Bun runtime; a present runtime with a missing `bunx` alias fails without reinstalling or overwriting Bun.
  It downloads the script from the fixed official URL `https://bun.com/install` to a private temporary file, runs that file with `/bin/bash`, verifies `bunx` under the installer's selected `${BUN_INSTALL:-$HOME/.bun}` directory, and resolves the installed executable directly without waiting for the app environment to refresh.
  The installer child receives only the fixed installation values plus exported proxy and certificate settings needed for its download.
  Automatic installation accepts only a safe directory below the current user's home; an incompatible `BUN_INSTALL` fails before download and leaves manual installation as the recovery path.
  Existing parent directories are resolved before appending missing folders, so symbolic links cannot redirect installation outside the home directory; broken links are rejected before download.
- `TokscaleCommandRunner` accepts only `submit` or `login` and launches the resolved `bunx` directly with fixed argument arrays for `tokscale@latest submit` and `tokscale@latest login`.
  It never uses `shell -c`, AppleScript, or user-supplied command text.
  It merges the app and captured login-shell environments so `@latest` remains responsible for current and future source discovery rather than freezing a provider-specific allowlist in OpenUsage.
  Known runtime-injection settings, Tokscale test hooks, and `TOKSCALE_API_URL` are removed; `HOME` and the working directory are anchored to the current macOS account, and package resolution otherwise keeps the user's Bun configuration.
  The only value accepted from this UI and passed to a child is a validated submit-only `TOKSCALE_DEVICE_NAME` environment entry.
- `TokscaleSyncStore` owns one active install or command for the app lifetime and persists the optional device name locally, so hiding or rebuilding Settings does not orphan the process or lose its result.
- `TokscaleSettingsSection` renders the compact card, the **Name…** header action and sheet, the missing-login action, and the login sheet.

Only the corresponding Settings buttons may start installation or a Tokscale command.
App launch, Settings appearance, periodic or manual refresh, provider changes, iCloud callbacks, widget updates, the `openusage` executable, and local API requests never trigger either one.
The submit action runs exactly `bunx tokscale@latest submit`; if the optional device name is set, it is supplied only through `TOKSCALE_DEVICE_NAME`.
Saving **Name…** does not start a process or network request, and the next successful submit updates the display label associated with Tokscale's stable device ID.
**Remove OpenUsage Override** removes only the local override and does not clear Tokscale's existing public name; later submissions let Tokscale's environment or stored device record supply the label.
Only a verified missing-login submit result enables the separate login action, and login never receives the public device-name override.
Login completion never starts submit, and there is no automatic retry or background submission.
App termination waits for the runner-owned installer or Tokscale process group to settle after cancellation, so OpenUsage does not abandon its active operation while closing.
The runner keeps the exited leader's process ID reserved until group cleanup finishes, then reaps it so late cancellation cannot target a reused process group.
Any detached follow-up work that Tokscale CLI starts outside that process group remains owned by Tokscale.

The boundary does not read `MetricLine`, `WidgetDataStore`, OpenUsage history, iCloud history, provider accounts, or provider enablement to build or filter a submission.
The boundary contains no provider collector, parser, contribution model, payload schema, direct Tokscale API client, token vault, or credential migration.
Tokscale's CLI owns its source discovery, credentials, stable device ID and `device.json`, aggregation, and network request; OpenUsage never edits that file.

Installer and Tokscale standard output and error are drained concurrently, stripped of ANSI and control sequences, and kept in a bounded in-memory command buffer.
Cleanup still reads buffered output, with a final 64 KiB allowance per pipe so detached writers cannot hold the runner open indefinitely.
The retained beginning and end share unused space at UTF-8 boundaries, preserving complete characters that fit in the byte limit; raw C1 controls are sanitized too.
The Settings card shows that buffer while it is available, including completion or failure output until the next operation or app termination, and the login sheet also shows login output while it remains open.
Raw output, inherited environment values, credentials, and authorization codes never enter OpenUsage logs, telemetry, files, or preferences.

## The AppKit bridge

macOS menu-bar apps live in an `NSStatusItem`.
OpenUsage shows its content in a custom, key-capable `NSPanel` rather than an `NSPopover`: a popover's window is only key while the whole app is active, and activating a menu-bar (accessory) app is asynchronous and unreliable on recent macOS, so a popover ends up unable to receive keystrokes until a second click.
A non-activating `NSPanel` whose `canBecomeKey` is `true` takes key focus the instant it opens, so keyboard navigation and the Settings shortcut recorder just work.
`App/` owns that AppKit layer and hosts the SwiftUI views inside it, so the bulk of the UI can stay plain SwiftUI.

## Platform support

OpenUsage runs on macOS 15 (Sequoia) and later.
It is built against the latest SDK and back-deploys: on macOS 26 (Tahoe) it uses the system's Liquid Glass controls, and on macOS 15 it falls back to the standard controls with the same behavior (the footer still pins, the buttons keep their states).
Every one of those version checks lives in a single file — `Support/LiquidGlassFallbacks.swift` — so the views stay free of `#available` checks.

The release build (`script/release.sh`) ships a universal binary (arm64 + x86_64), so a single DMG runs natively on both Apple Silicon and Intel Macs.
The dev build (`script/build_and_run.sh`) stays host-arch only — a universal dev build just doubles compile time on the maintainer's own machine for no benefit.

## Local HTTP API

A small loopback server exposes the current usage as JSON on `127.0.0.1:6736` for other local tools.
See [Local HTTP API](local-http-api.md) for the endpoints and the privacy tradeoff.
