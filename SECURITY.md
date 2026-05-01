# Security policy

PropFund is an oracle-settled trading contract that holds user funds. We take
vulnerability reports seriously and want to make it easy for researchers to
disclose responsibly.

## Reporting a vulnerability

**Do not open a public GitHub issue for a security finding.** Email the disclosure
contact below with:

- A clear description of the issue
- A minimum reproducer (Foundry test, transaction trace, or step-by-step write-up)
- The commit hash and deployment address (if applicable) you tested against
- Your assessment of severity and possible mitigations

Disclosure contact: see the project's GitHub repository "Security" tab for the
current PGP key and email address.

We aim to acknowledge new reports within 72 hours.

## Scope

In scope:
- `src/PropFund.sol`, `src/EvalCert.sol`, `src/EvalCertRenderer.sol`
- The vendored solady utilities under `lib/solady` *only* in how PropFund uses them
- Deploy scripts under `script/` — for misconfiguration that would brick or
  mis-parameterize a real deploy

Out of scope:
- The CLI (`cli/`) — keys, RPC handling, and gas-strategy logic. Bugs are welcome
  as ordinary issues.
- Pyth Network's own contracts and publisher set
- Circle's USDC contract (depeg, blacklist, etc.)
- Documentation typos, formatting issues

## Severity → response

| Severity | Definition | Action |
|---|---|---|
| Critical | Direct loss of user funds, pool insolvency, or oracle bypass | Immediate triage; contract pause if the deployment is live; coordinated patch + redeploy |
| High | Significant accounting drift, settlement bias, or denial-of-service for exits | Patch + redeploy on next regular cadence |
| Medium | Side-channel info leaks, gas griefing, NFT mint failures with no fund impact | Patch in next release |
| Low / Informational | Code quality, unused code, doc drift | Patch as time allows; PRs welcome |

## Pause behavior

The treasury wallet can call `setPaused(true)` as an emergency lever. Under pause:

- New deposits, evals, and trade-opens are blocked
- **All exit paths remain callable** — `closeTrade`, `liquidate`, `executeExit`,
  `forceClose`, `withdraw`, `withdrawProfit`, `resignFunding`, `emergencyClose`,
  `cancelEval`, `leaveFundingQueue`, and `processFundingQueue` continue to work

This is a deliberate design choice: users are never trapped, even during incident
response.

## Hall of fame

Confirmed researchers will be credited (with permission) in the project release
notes after the fix lands.
