<!-- Branched off `main` (feat/… · fix/… · docs/… · chore/…) — not committing to main directly. -->

## What & why

<!-- One or two sentences: what this changes and why. Link any related issue. -->

## Type

- [ ] feat
- [ ] fix
- [ ] docs
- [ ] chore

## Checklist

- [ ] `forge build` clean, `forge test` passes (full suite, not just affected)
- [ ] Contract size under EIP-170 (`forge build --sizes`) — if `src/` changed
- [ ] Tests added for any state-mutating change
- [ ] `THREAT_MODEL.md` updated if trust assumptions changed
- [ ] No new external deps, privileged actions, or upgradeability
- [ ] New external functions have NatSpec; new reverts use named errors

## Agent-authored?

- [ ] This PR was produced by an autonomous agent on its own branch
<!-- If yes, note the model/agent for reviewer context. -->
