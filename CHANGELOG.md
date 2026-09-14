# Changelog

This changelog starts with v0.8.0, the first release of this fork.

## v0.11.3

### New Features

- feat(codex): show scheduled resets as 99% forecasts ([#35](https://github.com/kimchanhyung98/openusage/pull/35)) by @kimchanhyung98.
- feat(site): add an interactive Korean landing page ([#34](https://github.com/kimchanhyung98/openusage/pull/34)) by @kimchanhyung98.

---

### Changelog

**Full Changelog**: [v0.11.2...v0.11.3](https://github.com/kimchanhyung98/openusage/compare/v0.11.2...v0.11.3)

## v0.11.2

### Bug Fixes

- fix(codex): show zero reset chance when no active signal exists ([#25](https://github.com/kimchanhyung98/openusage/pull/25)) by @kimchanhyung98.
- fix(telemetry): harden diagnostics, consent, and account isolation ([#24](https://github.com/kimchanhyung98/openusage/pull/24)) by @kimchanhyung98.
- fix(git-hooks): isolate repository environment in pre-commit ([#26](https://github.com/kimchanhyung98/openusage/pull/26)) by @kimchanhyung98.
- fix(local-api): handle empty paths and peer disconnects ([#27](https://github.com/kimchanhyung98/openusage/pull/27)) by @kimchanhyung98.
- fix(accounts): guard cache and refreshes across credential changes ([#28](https://github.com/kimchanhyung98/openusage/pull/28)) by @kimchanhyung98.
- fix(usage-logs): preserve failure state until confirmed recovery ([#29](https://github.com/kimchanhyung98/openusage/pull/29)) by @kimchanhyung98.
- fix(telemetry): retain crash locations and Swift exception types ([#30](https://github.com/kimchanhyung98/openusage/pull/30)) by @kimchanhyung98.
- fix(diagnostics): classify installer, updater, and pricing failures ([#31](https://github.com/kimchanhyung98/openusage/pull/31)) by @kimchanhyung98.
- fix(accounts): show actual session status in settings ([#32](https://github.com/kimchanhyung98/openusage/pull/32)) by @kimchanhyung98.
- fix(tokscale): add result dismissal and sync cooldown ([#33](https://github.com/kimchanhyung98/openusage/pull/33)) by @kimchanhyung98.

---

### Changelog

**Full Changelog**: [v0.11.1...v0.11.2](https://github.com/kimchanhyung98/openusage/compare/v0.11.1...v0.11.2)

## v0.11.1

### Bug Fixes

- fix(accounts): hide unregistered shared-home account cards ([#23](https://github.com/kimchanhyung98/openusage/pull/23)) by @kimchanhyung98.

---

### Changelog

**Full Changelog**: [v0.11.0...v0.11.1](https://github.com/kimchanhyung98/openusage/compare/v0.11.0...v0.11.1)

## v0.11.0

### New Features

- feat(release): derive bundle versions from git tags ([#16](https://github.com/kimchanhyung98/openusage/pull/16)) by @kimchanhyung98.
- feat(codex): add Reset Watch forecast ([#17](https://github.com/kimchanhyung98/openusage/pull/17)) by @kimchanhyung98.
- feat(tokscale): add CLI sync settings ([#19](https://github.com/kimchanhyung98/openusage/pull/19)) by @kimchanhyung98.
- feat(status): add provider server status indicators ([#20](https://github.com/kimchanhyung98/openusage/pull/20)) by @kimchanhyung98.
- feat(accounts): add shared card modes and account ordering ([#21](https://github.com/kimchanhyung98/openusage/pull/21)) by @kimchanhyung98.
### Bug Fixes

- fix(codex): show Reset Watch only on the main account card ([#22](https://github.com/kimchanhyung98/openusage/pull/22)) by @kimchanhyung98.

---

### Changelog

**Full Changelog**: [v0.9.5...v0.11.0](https://github.com/kimchanhyung98/openusage/compare/v0.9.5...v0.11.0)

## v0.9.5

### Bug Fixes

- Retry durable iCloud usage-history deletions after a transient failure ([#15](https://github.com/kimchanhyung98/openusage/pull/15)) by @kimchanhyung98.
- Conceal menu-bar usage while the screen is being captured ([#14](https://github.com/kimchanhyung98/openusage/pull/14)) by @kimchanhyung98.
- Reject symlinked account sign-in workspaces ([#11](https://github.com/kimchanhyung98/openusage/pull/11)) by @kimchanhyung98.
- Bind Cursor SQLite values instead of interpolating authentication tokens ([#12](https://github.com/kimchanhyung98/openusage/pull/12)) by @kimchanhyung98.
- Redact account names at the local HTTP API boundary ([#13](https://github.com/kimchanhyung98/openusage/pull/13)) by @kimchanhyung98.

---

### Changelog

**Full Changelog**: [v0.9.4...v0.9.5](https://github.com/kimchanhyung98/openusage/compare/cf33dbd890b9b9b3e2d78e1cfd0774616e29cb3c...ade70bb8e24955cd50de4572337311b63d73450d)

## v0.9.4

### Bug Fixes

- Update GPT-5.6 pricing and aliases ([#10](https://github.com/kimchanhyung98/openusage/pull/10)) by @kimchanhyung98.
- Map Daybreak Blue usage to GPT-5.6 Sol ([219e88c](https://github.com/kimchanhyung98/openusage/commit/219e88cab0a3d12a4b9840383d9621718499f269)) by @kimchanhyung98.

### Chores

- Optimize bundled images ([#2](https://github.com/kimchanhyung98/openusage/pull/2)) by @imgbot[bot].

---

### Changelog

**Full Changelog**: [v0.9.3...v0.9.4](https://github.com/kimchanhyung98/openusage/compare/a5ee0028817e617db1dd501912c5e2a5b3b413fe...cf33dbd890b9b9b3e2d78e1cfd0774616e29cb3c)

## v0.9.3

### Bug Fixes

- Keep one shared customizable card for each provider across managed accounts ([#9](https://github.com/kimchanhyung98/openusage/pull/9)) by @kimchanhyung98.

---

### Changelog

**Full Changelog**: [v0.9.2...v0.9.3](https://github.com/kimchanhyung98/openusage/compare/edfee95e71fa1c5b835386266595cb11fa2da868...a5ee0028817e617db1dd501912c5e2a5b3b413fe)

## v0.9.2

### Bug Fixes

- Keep account-card layout, notifications, and menu-bar pins scoped to their provider ([d25f6dc](https://github.com/kimchanhyung98/openusage/commit/d25f6dcf344988a0fb716d3506bd78f00fb66b43)) by @kimchanhyung98.
- Store layout per provider and hide unregistered logins ([076871f](https://github.com/kimchanhyung98/openusage/commit/076871f55be91c6dc2dd7d78658afb2a56239629)) by @kimchanhyung98.
- Harden Claude reauthentication reconciliation ([e8403f3](https://github.com/kimchanhyung98/openusage/commit/e8403f3abdb4b61a265cae9eb1a52dfdda5544eb)) by @kimchanhyung98.

---

### Changelog

**Full Changelog**: [v0.9.1...v0.9.2](https://github.com/kimchanhyung98/openusage/compare/21427211078a7a31ab8e2d4bd160115647e12c3c...edfee95e71fa1c5b835386266595cb11fa2da868)

## v0.9.1

### Bug Fixes

- Reconcile Claude terminal reauthentication without mixing account identities ([#8](https://github.com/kimchanhyung98/openusage/pull/8)) by @kimchanhyung98.

### Documentation

- Standardize documentation and code-comment style ([#7](https://github.com/kimchanhyung98/openusage/pull/7)) by @kimchanhyung98.

---

### Changelog

**Full Changelog**: [v0.9.0...v0.9.1](https://github.com/kimchanhyung98/openusage/compare/5ed3693ced27839379f1eb35659be3a02613718f...21427211078a7a31ab8e2d4bd160115647e12c3c)

## v0.9.0

### New Features

- Add managed Claude and Codex account switching, per-account dashboard cards, and read-only account CLI commands ([#6](https://github.com/kimchanhyung98/openusage/pull/6)) by @kimchanhyung98.

---

### Changelog

**Full Changelog**: [v0.8.2...v0.9.0](https://github.com/kimchanhyung98/openusage/compare/e6ec605d77d12243ebfb16f947c72bfff139968b...5ed3693ced27839379f1eb35659be3a02613718f)

## v0.8.2

### Bug Fixes

- Unblock the release pipeline and retarget telemetry ([#5](https://github.com/kimchanhyung98/openusage/pull/5)) by @kimchanhyung98.

---

### Changelog

**Full Changelog**: [v0.8.1...v0.8.2](https://github.com/kimchanhyung98/openusage/compare/aee49294353255825585fc88cb1548ec2ea74c03...e6ec605d77d12243ebfb16f947c72bfff139968b)

## v0.8.1

### Chores

- Retarget app identifiers, signing, iCloud containers, and the update feed ([#4](https://github.com/kimchanhyung98/openusage/pull/4)) by @kimchanhyung98.
- Make compact density the default dashboard layout ([0865c1f](https://github.com/kimchanhyung98/openusage/commit/0865c1f0159778d23538d9b6822f8d3a282ca702)) by @kimchanhyung98.

---

### Changelog

**Full Changelog**: [v0.8.0...v0.8.1](https://github.com/kimchanhyung98/openusage/compare/3fdbef4e0076e8493a4be634dcf51d0917166ead...aee49294353255825585fc88cb1548ec2ea74c03)

## v0.8.0

### New Features

- Add Kimi and Kiro usage tracking ([#1](https://github.com/kimchanhyung98/openusage/pull/1)) by @kimchanhyung98.

### Bug Fixes

- Add Claude Opus 5 pricing and native fast-mode pricing ([#3](https://github.com/kimchanhyung98/openusage/pull/3)) by @kimchanhyung98.

---

### Changelog

**Release Commit**: [3fdbef4e](https://github.com/kimchanhyung98/openusage/commit/3fdbef4e0076e8493a4be634dcf51d0917166ead)
