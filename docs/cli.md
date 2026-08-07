# Command-Line Interface

OpenUsage ships a one-shot `openusage` command for agents and scripts. It prints the documented
[`/v1/limits`](local-http-api.md#get-v1limits) JSON and exits; it never launches or leaves the menu-bar
app running. The output contains stable scalar limits and balances, not UI rows, colors, subtitles,
charts, or spend-history tiles.

```sh
openusage                 # every enabled provider, refreshing stale cache entries
openusage codex           # one provider, refreshing when its cache is stale
openusage codex --force   # refresh through the shared provider engine, cache, print, exit
```

The command and app import the same providers, authentication stores, pricing, refresh coordinator, and
snapshot cache. A normal read reuses snapshots less than five minutes old and refreshes missing or stale
ones. `--force` is the CLI equivalent of the app's manual refresh: it bypasses that freshness gate and
writes successful results to the same cache. Credentials are used locally and never appear in the output.

A provider argument names providers by plain string matching, exactly like the
[local HTTP API](local-http-api.md): an exact provider ID names that provider, and a family ID
(`claude`, `codex`) names every account card of that family — with one account that's exactly the one
card, so existing usage keeps working unchanged as multi-account support arrives. One exception:
inactive managed accounts' read-only snapshot cards are app-only — their credentials live in
app-created Keychain items the one-shot CLI must not touch — so the CLI's family match covers only
cards backed by on-disk logins, while the app's local API also serves those cards. The output envelope
contains every matched provider; an ID that names nothing exits with an error. There is no aliasing
or account-picking logic.

## Install on `PATH`

In OpenUsage, open **Settings → Command Line** and click **Install…**. After the standard macOS
administrator prompt, `openusage` is available globally in new terminal sessions. The installed symlink
points to the signed helper inside OpenUsage, so in-place app updates also update the command.

Exit codes are `0` for success, `2` for invalid arguments or an unknown provider, and `4` when a
refresh or local read fails.

## Accounts

Account management lives in [**Settings → Accounts**](/docs/settings.md) in the app.
The CLI only reads the same registry, so scripts can see exactly what the GUI shows:

```sh
openusage account list [claude|codex] [--json]   # registered accounts; * marks the selected one
openusage account current [claude|codex]         # the selected account's name (scriptable)
```

`current` without a tool prints both tools.
With a tool, it prints the bare account name or nothing when no account is selected.
Exit codes are `0` for success, `2` for usage errors, and `4` when the saved account registry cannot be read or validated.
In that case, the CLI prints an error instead of an empty account list.

Accounts have no user-visible folders and no launch commands.
Switching replaces the shared configuration home's authentication, so a plain `claude` or `codex` in a new terminal runs as the selected account with or without the `openusage` command installed.

When Settings switches an account, it first asks for confirmation.
On approval, OpenUsage replaces the shared configuration home's authentication and installs or updates a small `claude`/`codex` function in the detected login shell's startup file.
Supported startup files are `~/.zshrc` and `~/.config/fish/config.fish`.
Other login shells are not supported, and the switch stops with an error.
The function pins the shared configuration home to `~/.claude` or `~/.codex` and launches the real `claude` or `codex` directly.
For Claude, it strips `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`, `CLAUDE_CODE_OAUTH_TOKEN`, `CLAUDE_CODE_OAUTH_REFRESH_TOKEN`, and `CLAUDE_CODE_OAUTH_SCOPES`.
For Codex, it strips `OPENAI_API_KEY`, `CODEX_API_KEY`, and `CODEX_ACCESS_TOKEN` and keeps the file credential store.
The function never reads the selected account itself because switching is implemented by replacing authentication in the shared home.
Open a new terminal after the first setup, or reload the shell's startup file in an already-open terminal.
