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

## Development

```sh
forge install foundry-rs/forge-std --no-commit
git submodule update --init --recursive

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
