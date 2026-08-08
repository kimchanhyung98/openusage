# Kimi

Tracks the coding quota reported for the Kimi account already signed in through Kimi Code.

## What it tracks

| Metric | Meaning |
|---|---|
| Session | Usage in the rolling 5-hour window, with its reset time |
| Weekly | Usage in the 7-day window, with its reset time |

The plan label maps Kimi's internal membership level to its official international plan names: Adagio, Moderato, Allegretto, Allegro, and Vivace.
Unknown levels stay readable.
OpenUsage does not track spend or show the optional booster wallet.

## Where credentials come from

OpenUsage checks the current Kimi Code home first:

- `$KIMI_CODE_HOME/credentials/kimi-code.json` when `KIMI_CODE_HOME` is set
- `~/.kimi-code/credentials/kimi-code.json` otherwise

It then falls back to the legacy `~/.kimi/credentials/kimi-code.json` path.
Current credentials for the default Kimi hosts can be refreshed using the same lock protocol as the CLI.
Legacy credentials are read-only and work only while their access token remains valid.

Custom API or OAuth hosts and scoped `kimi-code-env-*.json` credentials are not supported.
OpenUsage will not send a custom-host token to Kimi's default service.

## Troubleshooting

- **"Not logged in to Kimi"** — run `kimi`, complete sign-in, then refresh OpenUsage.
- **"Kimi session expired"** — sign in through `kimi` again, then refresh.
- **"Custom Kimi API or OAuth hosts are not supported"** — use the default Kimi Code hosts for this provider.

## Under the hood

OpenUsage calls Kimi Code's unofficial `GET https://api.kimi.com/coding/v1/usages` endpoint.
When a current credential needs rotation, it uses Kimi Code's OAuth endpoint and updates that credential file without discarding fields owned by the CLI.
