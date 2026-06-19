# Contributing to PropFund

Thanks for taking an interest. PropFund is a single-contract protocol with a strong
"no upgrades, no admin override" stance, so contributions land directly in immutable
code — please read this before opening a PR.

## Ground rules

- **Tests are required for every state-mutating change.** Add unit coverage in
  `test/PropFund.t.sol` (or the most-relevant suite). For new attack surface, add an
  invariant in `test/Invariants.t.sol` and a section in `THREAT_MODEL.md`.
- **No new external dependencies in `src/`.** Pyth and USDC are the only outside
  contracts the protocol calls into. Vendored solady utilities (`DynamicBufferLib`,
  `Base64`, `LibString`) are renderer-only.
- **Stay under EIP-170.** `forge build --sizes` must show PropFund ≤ 24,576 bytes.
  Hot paths in the contract have been tuned for size; new code may need to free up
  bytes elsewhere or move to a separate contract.
- **No upgradeability.** Don't add proxy patterns, delegatecall, or
  upgrade-via-redeploy paths. The contract is immutable by design.
- **No new privileged actions.** The `treasury` role is intentionally minimal
  (`addFeeds`, `setPaused`, `withdrawTreasury`). New treasury powers need a strong
  case in `THREAT_MODEL.md`.

## Branching & pull requests

`main` is the stable, deployable branch — **don't commit to it directly.** Every change
lands through a pull request so it's reviewable and CI-gated.

- **Branch off `main`** for each change, with a descriptive prefix:
  - `feat/<name>` — new functionality
  - `fix/<name>` — bug fixes
  - `docs/<name>` — docs only
  - `chore/<name>` — tooling, deps, CI
- **One logical change per branch/PR.** Smaller PRs review faster and are safer for
  immutable on-chain code.
- **Open a PR into `main`.** CI (`forge build` + `forge test`) must pass; fill in the PR
  template and the checklist below.
- **Rebase on `main`** before requesting review.

### Working with autonomous agents

PropFund is built to be extended by AI agents as well as humans. If you run an agent (or
several) against this repo:

- **Give each agent its own branch** (e.g. `feat/agent-<name>-<task>`). Never let
  multiple agents share a branch or touch `main` — isolated branches keep parallel work
  conflict-free and each diff independently reviewable.
- **One PR per agent task**, gated by the same CI + checklist as a human PR. Agent diffs
  get reviewed on their merits, not waved through.
- Same rules apply: tests required, `THREAT_MODEL.md` note for new attack surface, no new
  privileged actions or upgradeability.

## Development

```sh
# Vendored deps (lib/ is gitignored). Pinned to the versions CI builds against:
git clone --depth 1 --branch v1.16.0 https://github.com/foundry-rs/forge-std lib/forge-std
git clone --depth 1 --branch v0.1.26 https://github.com/Vectorized/solady   lib/solady

forge build
forge test
```

For the live-Pyth fork test:

```sh
BASE_SEPOLIA_RPC=https://sepolia.base.org forge test --match-contract PythFork
```

## PR checklist

Before opening a PR:

- [ ] `forge build` is clean
- [ ] `forge test` passes (full suite, not just affected suites)
- [ ] Contract size still under EIP-170 (`forge build --sizes`)
- [ ] New external function has NatSpec (`@notice`, `@param`, `@return`)
- [ ] New revert paths use named errors, not strings
- [ ] If touching settlement / accounting math: an invariant covers the new path
- [ ] If touching trust assumptions: `THREAT_MODEL.md` updated

## Reporting bugs

For non-security bugs, file a GitHub issue with:
- Foundry version (`forge --version`)
- Steps to reproduce
- Expected vs. actual behavior

For **security** issues see [`SECURITY.md`](./SECURITY.md). Please do not open public
issues for security findings.

## Code style

- Solidity: 4-space indent, 120-char line cap, lowercase `bracket_spacing = false`
  (see `foundry.toml`). Match the existing file's conventions — single-line
  `unchecked` blocks and inline enums are intentional. `forge fmt`'s default opinion
  is *not* enforced; aim for diffs that match the surrounding code.
- JS (`cli/`): plain ESM, no transpilation. Match existing structure under
  `cli/src/`.
- Comments: explain *why*, not *what*. Reserved exceptions: tricky math,
  audit-driven guards, and CEI ordering reasoning.

## License

By submitting a PR, you agree your contribution is licensed under the project's
Apache-2.0 license.
