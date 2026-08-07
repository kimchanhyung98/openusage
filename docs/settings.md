# Settings

Settings lives inside the popover — there is no separate window. Open it from the footer's **Options** menu, with ⌘, while the popover is showing, or by right-clicking the menu bar icon and choosing Settings. The dashboard slides over to the Settings screen, which carries a back button in its top-left corner. Go back with that button, the ⌘, shortcut, or Esc (Esc always backs out to the dashboard first — pressing it again closes the popover).

## General

| Setting | Options | What it does |
|---|---|---|
| Show Total Spend | on/off | Whether the cross-provider [Total Spend](dashboard.md#total-spend) card shows at the top of the dashboard. On by default; the card appears whenever at least one enabled provider tracks spend (Claude, Codex, Cursor, Grok, OpenCode). |
| Launch at Login | on/off | Registers the app as a login item (the system's login-item registry is the source of truth). |
| Global Shortcut | record a shortcut | Global shortcut that toggles the popover from anywhere. Click the field and press a combo; the ⓧ clears it and disables the shortcut. |

**Upgrading from the legacy (pre-0.7) edition:** the old edition managed start-on-login with its own launcher file, which an in-place update left behind. That leftover could start the app a second time at every login and showed up in System Settings → Login Items under the signing company's name ("SUNSTORY LLC") instead of OpenUsage. The app now removes it automatically on launch — only when the file verifiably points at OpenUsage itself — so login starts exactly one copy, controlled by the Launch at Login toggle above.

## Accounts

The Accounts section manages Claude and Codex accounts.
An account is a named record of one provider sign-in — there are no folders to pick and no paths to edit.
Your existing `~/.claude` and `~/.codex` configuration (MCP settings, memory, plugins, skills, and session history) always stays in place.
Switching accounts replaces only the sign-in that new terminal sessions use.

- The add (+) button opens the Add Account flow.
  If you are already signed in and no account is registered yet, the current sign-in is imported directly — no new browser login.
  Otherwise, the official Claude or Codex sign-in opens.
  An additional account signs in inside a private workspace owned by OpenUsage, so your current account and open terminals keep working while you sign in.
  A cancelled or failed sign-in registers nothing.
- Each account's authentication is kept as a private snapshot in the macOS Keychain.
  The row badge reads **Ready** while that saved sign-in still proves its account, and **Sign-In Needed** otherwise.
- With two or more accounts for one provider, each row gains a toggle that picks the account new terminal sessions use.
  Switching asks for confirmation.
  Approval keeps the one shared Claude or Codex configuration home and replaces only its authentication with the selected account.
  The result is verified, and the previous sign-in is restored if anything fails.
  Approval also installs or updates a small `claude`/`codex` function in your login shell's startup file (zsh or fish), so new terminal sessions follow the switch.
  Switching requires a zsh or fish login shell; with another login shell the switch stops with an error and nothing is changed.
  See the [CLI](/docs/cli.md) page for details; the `openusage` command-line tool is not required.
  A toggle is enabled only while its row is **Ready**.
  While any registered accounts remain, one account stays selected even if it later needs sign-in.
  Readiness controls only whether that row can be switched to.
  Already-running sessions are never changed.
- Customize lists Claude or Codex once, and its on/off setting applies to every account card in that provider family.
  The dashboard's account selector lists only Settings-registered accounts and picks which account's usage the managed provider card shows.
  Existing Claude accounts discovered from separate configuration directories remain separate cards unless they prove the same identity as a registered account.
  A confirmed Settings switch moves the dashboard selector and the provider's menu-bar pins to that same account once.
  Changing the dashboard selector later is view-only and never runs another terminal switch.
  An inactive account's usage is read from its private Keychain snapshot.
  When that snapshot's token expires, the refreshed token is saved back into the same snapshot — never into the shared home or the active account.
- **Manage…** renames an account, re-runs the official sign-in when the account's session expires, and removes the account.
  The account name is the only editable field.
  **Sign In Again** replaces the saved snapshot only when the fresh sign-in proves the same account.
  A different account is refused with a hint to add it separately.
  Removing deletes the account's OpenUsage sign-in workspace first, then its Keychain snapshot, and finally unregisters the record.
  Your `~/.claude` and `~/.codex` data is never touched.
  If either deletion fails, the account stays registered so you can retry.
  A workspace failure also leaves the snapshot ready for switching.
  The selected account can't be removed while another account exists; switch first.
- Adding, renaming, re-signing, or removing an account updates the dashboard selector and card titles immediately.
  Restarting OpenUsage is not required.
- If the saved account registry cannot be decoded or validated, OpenUsage leaves the original data untouched.
  It shows an error in Accounts and blocks account changes instead of replacing the registry with an empty list.

## iCloud Sync

**Sync Across Macs** is off by default. Turning it on shares normalized OpenUsage history through the
app's private iCloud container and combines machine-local tokens and spend across Macs signed into the
same iCloud account. Settings shows the five-minute write cadence and each Mac's relative **Updated**
time; it also reports unavailable iCloud, loading, write, and malformed-file states. See
[iCloud Sync](icloud-sync.md) for what is included and which surfaces use the combined values.

## Appearance

| Setting | Options | What it does |
|---|---|---|
| Icon Style | Text / Bars | How starred metrics render in the menu bar. Bars is the default. See [Menu bar](menu-bar.md). |
| Theme | System / Light / Dark | App-wide appearance override for the popover. |
| Density | Default / Compact | Compact is the default for new installs. Default breathes; Compact is a real information-dense mode — text steps down one size, rows and provider sections pull together, and Customize / Settings rows tighten with them. In both, consecutive one-line metrics (Today / Yesterday / …) pull together; Compact pulls harder. |
| Time Format | Auto / 12-hour / 24-hour | How exact times read (e.g. "Resets today at 6:38 PM" vs "18:38"). 24-hour is the default; Auto follows the system. |
| Increase Transparency | Off / On | Off (default) keeps the popover a solid panel. On makes it translucent so your desktop shows through, while keeping the numbers and Options control legible with adaptive frosted surfaces. It pauses automatically when you have the macOS **Reduce Transparency** or **Increase Contrast** accessibility setting turned on (a note explains why), so it never works against those preferences. |

## Usage Display

| Setting | Options | What it does |
|---|---|---|
| Show Usage As | Used / Left | Whether bounded metrics read "48% used" or "52% left" — Used is the default; this is the same toggle as clicking a headline. |
| Reset Times | Countdown / Exact time | "Resets in 3h 25m" vs "Resets today at 6:38 PM" — Exact Time is the default; this is the same toggle as clicking a reset label. |
| Always Show Pacing | Off / On | On (default) surfaces pacing on every metric with a reset window: on-track rows gain their projection ("~33% left at reset") and an even-pace tick marking where steady use would put you right now. Off limits pacing to metrics close to or over their limit. Metrics without a reset window have no pace to show. |

## Notifications

OpenUsage can alert you with a macOS notification when a metric runs low or its pace gets worse, so you don't have to keep the popover open to catch a quota creeping toward its limit. Alerts work while the app runs in the menu bar, even with the popover closed.

| Setting | Options | What it does |
|---|---|---|
| Almost Out | On / Off | Alerts when a metric crosses under 10% remaining, including balances without a reset window. |
| Cutting It Close | On / Off | Alerts when a metric is projected to finish the period with little left — close to its limit. |
| Will Run Out | On / Off | Alerts when a metric is projected to run out before it resets. |

Alerts fire on a new crossing or pace worsening, then stay deduplicated while that condition is unchanged, so you do not get repeats on every refresh. A quota already in a bad state when OpenUsage launches establishes the baseline without alerting. If it recovers and later worsens again, the alert re-arms; a new reset period also clears the reset-based history. **Almost Out** is based only on the remaining share, so it also works for bounded balances without a reset window. **Cutting It Close** and **Will Run Out** require reset-window pace context. Metrics whose data cannot be read never alert. Turn all three triggers off to silence everything. When several alerts fire at once, they stack into a single grouped banner.

All three alerts default off. The first time you turn one on, OpenUsage asks for notification permission; if you decline (or turn notifications off for OpenUsage in System Settings later), a warning mark appears on the Notifications header and an "Open System Settings" button shows under the toggles so you can re-enable them. A notification's title is the alert name, its subtitle names the provider and metric, and its body is the plain-language verdict. Tapping an alert opens the popover on the dashboard.

## Privacy

| Setting | Options | What it does |
|---|---|---|
| Hide From Screen Share | On / Off | On (default) replaces the menu bar strip with the OpenUsage icon and wordmark while your screen is being shared or recorded, and restores your starred metrics the moment the capture ends. See [Menu bar](menu-bar.md#hiding-usage-while-screen-sharing). |
| Share Anonymous Usage | On / Off | Off by default. Turning it on shares anonymous, daily usage summaries — no account details, credentials, or usage values. See [Privacy & Usage Data](privacy.md) for exactly what is and isn't sent. |

## Advanced

| Setting | Options | What it does |
|---|---|---|
| Log Level | Error / Warning / Info / Debug | How much detail the app writes to its log file. Defaults to Info and persists across launches; raise to Debug while reproducing a problem. Applies immediately. |
| Copy Log Path | button | Copies the log file path (`~/Library/Logs/OpenUsage/OpenUsage.log`) to the clipboard. |
| Reveal in Finder | button | Opens a Finder window with the log file selected. |

See [Logging](logging.md) for the full behavior: subsystem tags, the file size cap, and the guarantee that secrets are never written.

## Updates

The Updates section appears in official packaged builds that include the signed update feed. Local
developer builds do not show it.

| Setting | Options | What it does |
|---|---|---|
| Update Automatically | On / Off | Whether Sparkle checks for updates in the background. You can still check manually when this is off. |
| Beta Updates | On / Off | Adds pre-release builds to the updates you can receive. Stable releases remain available either way. |
| Check for Updates… | button | Starts a manual update check and opens Sparkle's update window. |

See [Updates](updates.md) for the dashboard banner, channels, and signature verification.

## Version

The app version shows in the popover footer.

Your settings carry across updates — layout, stars, preferences, and the menu-bar shortcut all stay put. When an update changes how a setting is stored, the app upgrades it in place on launch, stepping through any in-between versions if you skipped a few. Nothing is reset. (Earlier betas wiped all settings on every update; that no longer happens.)

Which providers you have on also carries across updates — your choices are never overridden. A brand-new install picks its starting set by detecting the AI tools on your Mac (see [Dashboard § First launch](dashboard.md#first-launch)). When an update ships a provider you've never seen, the same local detection runs once for just that provider and turns it on only if you actually have the tool; everything you've already decided about stays exactly as you set it. See [Which Providers Are On](provider-enablement.md).
