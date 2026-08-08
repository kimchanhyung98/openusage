# Kiro

Tracks the coding credits reported for the account already signed in through Kiro CLI.

## What it tracks

| Metric | Meaning |
|---|---|
| Credits | Credits used against the current billing-period limit, with its reset time |

OpenUsage also shows the subscription name returned by Kiro.
Bonus credits and overage details are not shown because their active response shapes have not been verified.

## Where credentials come from

OpenUsage reads the Kiro CLI database at `~/Library/Application Support/kiro-cli/data.sqlite3`.
The access token and profile are read-only: OpenUsage never refreshes or writes Kiro credentials.

Only Kiro CLI social sign-in is supported.
Kiro IDE state, Builder ID or Identity Center credentials, and the machine-local session files under `~/.kiro` are not used as account quota sources.

## Troubleshooting

- **"Not logged in to Kiro"** — run `kiro-cli login`, then refresh OpenUsage.
- **"Kiro session expired"** — run `kiro-cli login` again, then refresh.
- **"Kiro credentials could not be read"** — check that the Kiro CLI database exists and is readable.

## Under the hood

OpenUsage sends the stored access token and profile ARN to the unofficial CodeWhisperer `GetUsageLimits` endpoint.
After a 401 or 403 response, it re-reads the database once and retries only when Kiro CLI has already replaced the token.
