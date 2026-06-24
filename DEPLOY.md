# PropFund — Deploy Runbook

Turnkey redeploy of the current contract (guardian/treasury split + `PropFundLens` + $1 eval fee).
Mirrors the Celo "tagged candidate → deploy → verify deployed state against the candidate" discipline.

## 0. Decisions to make first (🔑 you)
- **Target network** — `sepolia` (current beta), `baseSepolia`, or `base` (mainnet — only after the §7
  gates in `PRODUCTION.md`: audit, legal, real funds).
- **`TREASURY`** — fee recipient + admin (DAO/multisig in production). **Must differ from the keeper.**
- **`GUARDIAN`** — emergency pause key, separate from `TREASURY` (a fast ops multisig).
- **`EVAL_FEE`** — defaults to `1e6` ($1). Override only if you want a different challenge price.

## 1. Prereqs
- Foundry installed (`forge --version`).
- A funded **deployer** wallet on the target chain (testnet gas from a faucet).
- An RPC URL for the target chain.
- Deps present: `forge build` succeeds (CI clones forge-std v1.16.0 + solady v0.1.26 into `lib/`).

## 2. Set env
```sh
export PRIVATE_KEY=0x<deployer-key>
export TREASURY=0x<dao-or-multisig>      # fees + admin
export GUARDIAN=0x<separate-ops-key>     # pause only — NOT the keeper, NOT TREASURY
export EVAL_FEE=1000000                  # optional; 1e6 = $1 (default)
```

## 3. Deploy + auto-wire
Each script deploys `PropFund` + `PropFundLens` + (on testnet) a mock USDC + the renderer, and logs every
address. Pick the matching script:

```sh
# Ethereum Sepolia
forge script script/DeploySepolia.s.sol:DeploySepoliaScript \
  --rpc-url https://ethereum-sepolia-rpc.publicnode.com --broadcast -vv

# Base Sepolia
forge script script/DeployBaseSepolia.s.sol:DeployBaseSepoliaScript \
  --rpc-url https://sepolia.base.org --broadcast -vv
```

Record the logged `PropFund`, `Lens`, `MockUSDC`, `EvalCert`, `Renderer` addresses.

## 4. Verify on the explorer (🔨)
```sh
forge verify-contract <PropFund> src/PropFund.sol:PropFund \
  --chain <id> --watch --constructor-args $(cast abi-encode ...)   # see foundry verify docs
forge verify-contract <Lens> src/PropFundLens.sol:PropFundLens --chain <id> --watch
```
Confirm on Etherscan/Basescan that the verified source matches this branch's commit (the "deployed ==
candidate" check).

## 5. Post-deploy sanity (verify state == candidate)
```sh
cast call <PropFund> "TREASURY()(address)"  --rpc-url $RPC   # == your TREASURY
cast call <PropFund> "GUARDIAN()(address)"  --rpc-url $RPC   # == your GUARDIAN (≠ TREASURY)
cast call <PropFund> "EVAL_FEE()(uint256)"  --rpc-url $RPC   # == 1000000
cast call <Lens>     "FUND()(address)"      --rpc-url $RPC   # == <PropFund>
```

## 6. Wire the CLI / bot (🔨 + 🔑)
1. `cli/src/networks.js` — set `contractAddr`, `usdcAddr`, `lensAddr`, (router if deployed) for the network.
2. Regenerate ABIs:
   ```sh
   forge inspect PropFund abi --json > cli/src/propfund.abi.json
   forge inspect PropFundLens abi --json > cli/src/propfundlens.abi.json
   ```
3. Repoint `getTraderStats` / `getEvalStatus` reads at the lens (stats.js, trade.js, funded.js, eval.js,
   agent.js) — these now live on `PropFundLens`, not `PropFund`.
4. Point the running agent + keeper at the new `contractAddr` and restart the quadlets.
5. **Fund** the trader + keeper wallets (faucet).

## 7. Smoke test (the beta "working" definition)
- `propfund lp deposit` seeds the pool (or the script already seeded it on testnet).
- Run the agent for one full virtual lifecycle: eval ($1 fee) → pass → claim funding → scaled trades
  (leverage scales up on wins, down on losses) → settle. Confirm on the explorer.
- Keeper bot ticks without watchdog timeouts.

## ABI / compatibility deltas vs the prior deploy
- `getTraderStats` / `getEvalStatus` **moved** from `PropFund` → `PropFundLens` (same return shapes).
- New: `GUARDIAN()` immutable, `maxLevelMinted(address)` getter, `Config.guardian` field.
- `funded()/positions()/records()/evals()` getters **unchanged** (the NFT high-water uses a separate mapping).

## Rollback
Immutables can't be repointed — a bad config means redeploy. Keep the prior deployment's addresses until the
new one passes §7.
