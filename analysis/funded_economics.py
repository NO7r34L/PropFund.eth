#!/usr/bin/env python3
"""
PropFund funded-leg unit economics — Monte Carlo.

Question: with a $1 eval fee and bidirectional performance scaling, when is the
LP pool expected-value >= 0? The pool keeps (1-split) of winning trades but eats
100% of losers, so this is driven by (a) trader edge from eval selection and
(b) scaling winners up / losers down. We simulate funded-account lifecycles and
report pool EV, ruin rate, and the break-even edge.
"""
import numpy as np

rng = np.random.default_rng(42)

# ---- economic parameters (base case) ----
EVAL_FEE      = 1.0      # $ per eval attempt
PASS_RATE     = 0.08     # fraction of attempts that get funded (hard eval)
BASE_ALLOC    = 250.0    # $ starting funded capital at tier 2
DD_STOP       = 0.10     # terminate account at -10% drawdown from high-water (of current alloc)
SPLIT_TRADER  = 0.80     # trader keeps 80% of profit; pool keeps 20%
FEE_DRAG_BPS  = 8.0      # Avantis round-trip + funding, bps of notional, per trade
REBATE_BPS    = 1.0      # integrator rebate to pool, bps of notional, per trade
LEVERAGE      = 3.0      # avg leverage on funded notional
SIGMA_PX      = 0.008    # per-trade price move std (0.8%)
HORIZON       = 150      # max trades per funded account (else "graduates"/cashes out)
N_ACCTS       = 40_000

# ladder: cumulative realized PnL ($) -> (allocation multiplier, TRADER split)
# pool keeps MORE of unproven traders' profit (low tier), less as they prove out.
LADDER = [(1000,8.0,0.85),(400,4.0,0.80),(150,2.5,0.70),(50,1.5,0.60),(0,1.0,0.50)]
def tier_mult(cum_pnl):
    for thr, m, _ in LADDER:
        if cum_pnl >= thr: return m
    return 1.0
def split_for(cum_pnl):
    for thr, _, s in LADDER:
        if cum_pnl >= thr: return s
    return 0.50

def sim_cohort(edge_px, n=N_ACCTS, leverage=LEVERAGE, split=SPLIT_TRADER,
               dd=DD_STOP, fee_bps=FEE_DRAG_BPS, base=BASE_ALLOC, horizon=HORIZON):
    """Return (pool_net_per_acct, trader_payout, ruin_rate, avg_life)."""
    pool_net = np.zeros(n); payout = np.zeros(n); ruined = np.zeros(n); life = np.zeros(n)
    for a in range(n):
        cum = 0.0          # cumulative net trading PnL (on pool capital)
        hwm = 0.0          # high-water of cum (drives payout AND drawdown)
        paid = 0.0         # cumulative trader payout, only on NET new highs
        rebate = 0.0
        for t in range(horizon):
            alloc = base * tier_mult(cum)
            notional = alloc * leverage
            px = rng.normal(edge_px, SIGMA_PX)
            tpnl = notional * px - notional * fee_bps / 1e4   # net $ PnL this trade
            rebate += notional * REBATE_BPS / 1e4
            cum += tpnl
            life[a] = t + 1
            if cum > hwm:                              # NET new high -> pay tiered split of increment
                paid += split_for(cum) * (cum - hwm)
                hwm = cum
            if cum <= hwm - dd * alloc:                # drawdown breach -> terminate
                ruined[a] = 1.0
                break
        # pool keeps all trading PnL minus trader payouts, plus integrator rebates
        pool_net[a] = cum - paid + rebate
        payout[a]   = paid
    return pool_net.mean(), payout.mean(), ruined.mean(), life.mean()

def pool_ev_per_funded(pool_net):
    # each funded trader is "backed" by EVAL_FEE/PASS_RATE of eval-fee revenue
    return pool_net + EVAL_FEE / PASS_RATE

print(f"{'edge/trade':>11} | {'pool$/acct':>10} | {'+evalfee':>9} | {'trader$':>8} | {'ruin%':>6} | {'avg life':>8}")
print("-"*72)
edges = [-0.0010, -0.0005, 0.0, 0.0005, 0.0010, 0.0015, 0.0020, 0.0030]
for e in edges:
    pn, pay, ruin, life = sim_cohort(e)
    ev = pool_ev_per_funded(pn)
    print(f"{e*100:>9.2f}% | {pn:>10.2f} | {ev:>9.2f} | {pay:>8.2f} | {ruin*100:>5.1f}% | {life:>8.1f}")

# break-even edge (pool EV incl eval fee == 0)
print("\nbreak-even search (pool EV incl $1 eval fee == 0):")
lo, hi = -0.001, 0.003
for _ in range(22):
    mid = (lo+hi)/2
    pn,_,_,_ = sim_cohort(mid, n=15000)
    if pool_ev_per_funded(pn) < 0: lo = mid
    else: hi = mid
print(f"  break-even trader edge = {mid*100:.3f}% per trade  ({mid*1e4:.1f} bps)")

# how much does the $1 eval fee actually move it?
pn0,_,_,_ = sim_cohort(0.0010, n=15000)
print(f"\nat +0.10%/trade edge: pool$/acct = {pn0:.2f}; eval-fee buffer adds "
      f"{EVAL_FEE/PASS_RATE:.2f}/acct ({100*(EVAL_FEE/PASS_RATE)/abs(pn0) if pn0 else 0:.1f}% of |pool net|)")

# ============================================================================
# CAPACITY / WAITLIST MODEL  — capital is the bottleneck, not eval throughput.
# Pool has finite K. Funded allocations must sum <= K. Passed traders queue FIFO
# until capital frees (ruin / graduation / scale-down). Scaling a winner UP
# competes for the same scarce capital as funding the next queued passer.
# ============================================================================
def sim_capacity(K=50_000.0, ticks=2000, arrivals_per_tick=0.5, blended_edge_fn=None,
                 base=BASE_ALLOC, lev=LEVERAGE, dd=DD_STOP, fee_bps=FEE_DRAG_BPS):
    if blended_edge_fn is None:
        # eval-selected cohort: mostly skilled, some lucky passers
        def blended_edge_fn():
            return rng.normal(0.0022, 0.0010) if rng.random() < 0.6 else rng.normal(0.0, 0.0006)
    free = K; pool_cash = 0.0; queue = 0; active = []
    waits = []; pending_wait = []   # ticks each queued trader has waited
    util_samples = []; bank = 0.0
    for tk in range(ticks):
        # eval-fee revenue accrues every tick whether or not capital is free
        attempts = arrivals_per_tick / max(PASS_RATE, 1e-9)
        bank += attempts * EVAL_FEE
        # new passers arrive -> queue
        new = rng.poisson(arrivals_per_tick)
        queue += new; pending_wait += [0]*new
        # admit from queue while capital for a base allocation is free
        while queue > 0 and free >= base:
            free -= base
            active.append(dict(cum=0.0,hwm=0.0,paid=0.0,alloc=base,edge=blended_edge_fn()))
            queue -= 1; waits.append(pending_wait.pop(0))
        pending_wait = [w+1 for w in pending_wait]
        # step every active account one trade
        still = []
        for ac in active:
            notional = ac['alloc']*lev
            tpnl = notional*rng.normal(ac['edge'],SIGMA_PX) - notional*fee_bps/1e4
            pool_cash += notional*REBATE_BPS/1e4
            ac['cum'] += tpnl
            if ac['cum'] > ac['hwm']:
                pay = split_for(ac['cum'])*(ac['cum']-ac['hwm'])
                ac['paid'] += pay; ac['hwm']=ac['cum']
            # drawdown breach -> close, return capital + pool's net to pool
            if ac['cum'] <= ac['hwm'] - dd*ac['alloc']:
                pool_cash += ac['cum'] - ac['paid']
                free += ac['alloc']
                continue
            # scale allocation toward tier target IF free capital allows (else stay)
            target = base*tier_mult(ac['cum'])
            if target > ac['alloc'] and free >= (target-ac['alloc']):
                free -= (target-ac['alloc']); ac['alloc']=target
            elif target < ac['alloc']:
                free += (ac['alloc']-target); ac['alloc']=target
            still.append(ac)
        active = still
        util_samples.append((K-free)/K)
    # close out survivors at horizon
    for ac in active:
        pool_cash += ac['cum'] - ac['paid']
    total_pool = pool_cash + bank
    return dict(pool_trading=pool_cash, eval_fees=bank, total=total_pool,
                roi_pct=100*total_pool/K, util=np.mean(util_samples)*100,
                avg_wait=np.mean(waits) if waits else 0, funded=len(waits), final_queue=queue)

print("\n" + "="*72)
print("CAPACITY / WAITLIST (K=$50k pool, blended eval-selected cohort, 2000 ticks)")
print("="*72)
for arr in [0.2, 0.5, 1.0]:
    r = sim_capacity(arrivals_per_tick=arr)
    print(f"arrivals/tick={arr:>4}: ROI {r['roi_pct']:>6.1f}% | util {r['util']:>5.1f}% | "
          f"funded {r['funded']:>4} | avg wait {r['avg_wait']:>5.1f} ticks | "
          f"queue@end {r['final_queue']:>3} | trading ${r['pool_trading']:>8.0f} + fees ${r['eval_fees']:>7.0f}")

print("\nWAITLIST BINDS when capital is scarce vs demand (arrivals/tick=1.0, vary pool K):")
for K in [3000, 8000, 20000, 50000]:
    r = sim_capacity(K=K, arrivals_per_tick=1.0)
    print(f"  K=${K:>6}: util {r['util']:>5.1f}% | avg wait {r['avg_wait']:>6.1f} ticks | "
          f"funded {r['funded']:>4} | queue@end {r['final_queue']:>4} | ROI {r['roi_pct']:>6.1f}%")
