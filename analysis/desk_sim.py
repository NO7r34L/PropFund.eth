#!/usr/bin/env python3
"""
AgentDesk economics over 1000 agents — HONEST to the deployed AgentDesk.sol mechanics.

Question: is a firm-funded, 1x long-only ETH timing desk a profitable business across a
population of agents, and does the allocation ladder (with the buy-and-hold hurdle) fix the
"flat $500 book = lottery" result?

Modelled EXACTLY as the contract does it:
  - book = allocation in USDC; enterEth = all-in, exitEth = all-out; friction per round trip
  - profit above allocation -> split AGENT_SPLIT / firm, book swept back to allocation
  - loss stays in the book; book <= allocation x (1 - MAX_DD) -> revoked, deposit forfeited
  - LADDER: after every exit, target mult from realized cumPnl (T2/T4/T8 of BASE), gated on
    cumPnl >= hurdle, hurdle = BASE x max(0, ETH/bench - 1). Scale-up capped by firm idle and
    by (deposit + earned) / MAX_DD (earned reinvested as collateral); scale-down releases.
  - HOLD-OUT: the firm's alternative is holding ETH with the same capital (reported).

Agents: population skill is heavy-tailed around zero. An agent's timing skill rho_i is the
correlation between its entry signal and the sign of the next ETH move. Most agents have
|rho| ~ 0 (they are noise + friction); a few percent have real edge; a few percent are anti-skilled.
This is the adversary's real shape: mostly random, some good, some bad, all paying friction.

Regimes: bull / bear / chop / mixed price paths so the result isn't a beta artifact.
"""
import numpy as np

rng = np.random.default_rng(11)

# ---- deployed constants (DeployDesk.s.sol defaults) ----
BASE      = 500.0
DEPOSIT   = 50.0
MAX_DD    = 0.10
SPLIT     = 0.40          # agent share of realized profit (DeployDesk default 4000 bps)
T2, T4, T8 = 0.20, 0.50, 1.20   # of BASE: $100 / $250 / $600 realized (SCALE_T*_BPS)
MIN_TRADES = (40, 80, 120)      # SCALE_MIN_TRADES x 1/2/3 closed desk trades
MAX_MULT  = 8
FRICTION  = 0.0017        # measured $0.86 on a $500 round trip on the devnet venue (0.1%/side)
FIRM_CAPITAL = 5_000.0 * 100   # $500k idle for 1000 agents (5000 per 10 agents)

DAYS = 365
N_AGENTS = 1000


def eth_path(regime, days=DAYS):
    """Daily log-returns for a year. Vol ~ 65%/yr (realistic for ETH)."""
    vol = 0.65 / np.sqrt(365)
    drift = {"bull": 0.80, "bear": -0.50, "chop": 0.0, "mixed": 0.15}[regime] / 365
    r = rng.normal(drift - 0.5 * vol**2, vol, days)
    if regime == "mixed":   # bull H1, crash Q3, chop Q4
        r[:180]     += 0.60 / 365
        r[180:270]  -= 1.60 / 365
    return np.exp(np.cumsum(r)) * 2500.0


def population_skill(n):
    """rho_i: timing correlation. 85% noise, 10% mild edge, 5% anti-skill (heavy tails)."""
    rho = rng.normal(0.0, 0.03, n)
    k = rng.random(n)
    rho[k < 0.10] = np.abs(rng.normal(0.15, 0.06, (k < 0.10).sum()))
    rho[(k >= 0.10) & (k < 0.15)] = -np.abs(rng.normal(0.12, 0.05, ((k >= 0.10) & (k < 0.15)).sum()))
    return np.clip(rho, -0.6, 0.6)


def window_return(px, d, hold_days, sl, tp, trail_arm=None, trail_give=None):
    """Return of an all-in long entered at close d, managed by the agent's exit manager:
    stop at -sl, take-profit at +tp, trailing stop (arms at +trail_arm, gives back trail_give from
    the peak), else exit at close d+hold_days. Same for every entrant."""
    e = px[d]; peak = 0.0
    for k in range(1, hold_days + 1):
        r = px[d + k] / e - 1.0
        if r <= -sl: return -sl * 1.15          # gap through the stop (fills worse than the level)
        if r >= tp:  return tp
        peak = max(peak, r)
        if trail_arm and peak >= trail_arm and peak - r >= trail_give: return r
    return px[d + hold_days] / e - 1.0


def run(regime, ladder, hurdle, n=N_AGENTS, trade_every=3, hold_days=2, seed=0,
        tiers=(T2, T4, T8), min_trades=(0, 0, 0), sl=None, tp=None, trail=(None, None), years=1, split=SPLIT):
    """Simulate `years`. Returns firm P&L decomposition + per-agent outcomes."""
    global rng, DAYS, SPLIT
    rng = np.random.default_rng(seed)
    DAYS = 365 * years; SPLIT = split
    px = eth_path(regime, DAYS)
    rho = population_skill(n)
    t2, t4, t8 = tiers

    firm_idle = FIRM_CAPITAL
    firm_profit = 0.0
    firm_book_losses = 0.0     # capital lost inside books (revoked below allocation, or shrunk)
    agent_earned = np.zeros(n)
    alloc = np.full(n, BASE); usdc = np.full(n, BASE); dep = np.full(n, DEPOSIT)
    cum = np.zeros(n); active = np.ones(n, bool)
    bench = np.full(n, px[0])
    firm_idle -= n * BASE
    trades = np.zeros(n, int); revoked = np.zeros(n, bool)
    peak_mult = np.ones(n)

    for d in range(0, DAYS - hold_days, trade_every):
        raw = px[d + hold_days] / px[d] - 1.0
        move = window_return(px, d, hold_days, sl, tp, *trail) if sl else raw
        # timing signal: rho-correlated with the sign of the coming move
        sig = rho * np.sign(raw) + rng.normal(0, 1, n) * np.sqrt(np.maximum(1 - rho**2, 1e-9))
        enter = active & (sig > 0.6)          # enters ~27% of opportunities at rho=0
        idx = np.nonzero(enter)[0]
        if idx.size == 0:
            continue
        trades[idx] += 1
        entry = usdc[idx]
        out = entry * (1.0 + move) * (1.0 - FRICTION)
        pnl = out - entry
        cum[idx] += pnl
        # settle
        profit = np.maximum(out - alloc[idx], 0.0)
        agent_cut = profit * SPLIT
        agent_earned[idx] += agent_cut
        firm_profit += (profit - agent_cut).sum()
        usdc[idx] = np.where(out > alloc[idx], alloc[idx], out)
        # drawdown breach -> revoke, forfeit deposit
        floor = alloc[idx] * (1 - MAX_DD)
        breach = usdc[idx] <= floor
        b = idx[breach]
        if b.size:
            firm_idle += usdc[b].sum()
            firm_book_losses += (alloc[b] - usdc[b]).sum()
            firm_profit += dep[b].sum()
            active[b] = False; revoked[b] = True
            usdc[b] = 0; dep[b] = 0
        # ladder
        if ladder:
            ok = idx[~breach]
            spot = px[d + hold_days]
            h = np.where(hurdle, BASE * np.maximum(spot / bench[ok] - 1.0, 0.0), 0.0)
            beats = cum[ok] >= h
            mult = np.ones(ok.size)
            nt = trades[ok]
            mult[beats & (cum[ok] >= BASE * t2) & (nt >= min_trades[0])] = 2
            mult[beats & (cum[ok] >= BASE * t4) & (nt >= min_trades[1])] = 4
            mult[beats & (cum[ok] >= BASE * t8) & (nt >= min_trades[2])] = 8
            mult = np.minimum(mult, MAX_MULT)
            target = BASE * mult
            for j, a in enumerate(ok):          # sequential: firm_idle is shared
                t = target[j]
                if t > alloc[a]:
                    add = min(t - alloc[a], firm_idle); t = alloc[a] + add
                    coverable = (dep[a] + agent_earned[a]) / MAX_DD
                    if coverable < t:
                        t = coverable; add = max(t - alloc[a], 0.0)
                    req = t * MAX_DD
                    if dep[a] < req:
                        short = req - dep[a]; agent_earned[a] -= short; dep[a] += short
                    if add <= 0:
                        continue
                    firm_idle -= add; usdc[a] += add; alloc[a] = t
                    peak_mult[a] = max(peak_mult[a], t / BASE)
                elif t < alloc[a]:
                    # scale-down: excess book back to firm, book value below target is a firm loss
                    alloc[a] = t
                    if usdc[a] > t:
                        firm_idle += usdc[a] - t; usdc[a] = t
                    req = t * MAX_DD
                    if dep[a] > req:
                        agent_earned[a] += dep[a] - req; dep[a] = req

    # year end: mark everything. Firm capital = idle + books (at usdc value) + profit.
    firm_end = firm_idle + usdc[active].sum() + firm_profit
    firm_pnl = (firm_end - FIRM_CAPITAL) / years
    hold_pnl = FIRM_CAPITAL * (px[-1] / px[0] - 1.0)   # the firm's alternative: hold ETH
    deployed_peak = FIRM_CAPITAL - firm_idle if firm_idle < FIRM_CAPITAL else 0
    return dict(
        regime=regime, ladder=ladder, hurdle=hurdle,
        eth=px[-1] / px[0] - 1.0,
        firm_pnl=firm_pnl, firm_ret=firm_pnl / FIRM_CAPITAL,
        firm_profit=firm_profit, book_losses=firm_book_losses + (BASE * active.sum() - usdc[active].sum()),
        hold_pnl=hold_pnl,
        agents_revoked=int(revoked.sum()),
        agents_scaled=int((peak_mult > 1).sum()), agents_8x=int((peak_mult >= 8).sum()),
        cap_deployed=FIRM_CAPITAL - firm_idle,
        agent_mean=float((agent_earned + np.where(revoked, -DEPOSIT, 0)).mean()),
        top_decile_share=float(np.sort(agent_earned)[-n // 10:].sum() / max(agent_earned.sum(), 1e-9)),
        skilled_scaled=float((peak_mult[rho > 0.08] > 1).mean()) if (rho > 0.08).any() else 0.0,
        precision=float((rho[peak_mult > 1] > 0.08).mean()) if (peak_mult > 1).any() else 0.0,
        skilled_cum=float(cum[rho > 0.08].mean()), noise_cum=float(cum[np.abs(rho) < 0.05].mean()),
        skilled_revoked=float(revoked[rho > 0.08].mean()),
        mean_trades=float(trades.mean()),
        noise_scaled=float((peak_mult[np.abs(rho) < 0.05] > 1).mean()),
    )


def fmt(r):
    return (f"{r['regime']:<6} ETH {r['eth']*100:+6.1f}% | "
            f"firm {r['firm_ret']*100:+6.2f}%/yr (${r['firm_pnl']:>9,.0f}; profit ${r['firm_profit']:>8,.0f}, book losses ${r['book_losses']:>8,.0f}) "
            f"| hold-ETH ${r['hold_pnl']:>10,.0f} | revoked {r['agents_revoked']:>3} scaled {r['agents_scaled']:>3} (8x {r['agents_8x']:>2}) "
            f"| scaled: skilled {r['skilled_scaled']*100:4.0f}% noise {r['noise_scaled']*100:4.0f}% precision {r['precision']*100:3.0f}% | trades/agent {r['mean_trades']:4.1f}")


def avg_runs(**kw):
    rs = [run(seed=s, **kw) for s in range(4)]
    return {k: (np.mean([r[k] for r in rs]) if isinstance(rs[0][k], (int, float, np.floating)) else rs[0][k]) for k in rs[0]}


if __name__ == "__main__":
    import sys
    print(f"AgentDesk, {N_AGENTS} agents, ${FIRM_CAPITAL:,.0f} firm capital, base ${BASE:.0f}, dd {MAX_DD:.0%}, friction {FRICTION:.2%}/round-trip")
    print("skill: 85% noise / 10% edge (rho~0.15) / 5% anti-skill; enters ~27% of windows. firm %/yr is ANNUALIZED")
    print("Rows: what shipped before this change (flat $500 book, 50/50, SL3/TP2) vs what is deployed now.\n")
    OLD_EXIT = dict(sl=0.03, tp=0.02, trail=(0.01, 0.005), hold_days=3)
    NEW_EXIT = dict(sl=0.015, tp=0.06, trail=(0.03, 0.015), hold_days=7)
    LADDER = dict(ladder=True, hurdle=True, tiers=(T2, T4, T8), min_trades=MIN_TRADES, split=SPLIT)
    ROWS = [("OLD: flat, 50/50, SL3/TP2",              dict(ladder=False, hurdle=False, split=0.50, **OLD_EXIT)),
            ("    + exit manager only (SL1.5/TP6)",   dict(ladder=False, hurdle=False, split=0.50, **NEW_EXIT)),
            ("    + ladder, no track-record gate",    dict(ladder=True, hurdle=True, tiers=(T2, T4, T8), min_trades=(0, 0, 0), split=0.50, **NEW_EXIT)),
            ("NEW: ladder + hurdle + 40/80/120 + 60/40", dict(**LADDER, **NEW_EXIT))]
    years = int(sys.argv[1]) if sys.argv[1:] else 2
    regimes = sys.argv[2:] or ["chop", "mixed", "bull", "bear"]
    for regime in regimes:
        print(f"--- {regime}, {years}y ---")
        for label, kw in ROWS:
            r = avg_runs(regime=regime, years=years, **kw)
            dep = 50 * r['agents_revoked']
            print(f"  {label:<42} ETH {r['eth']*100:+6.1f}% | firm {r['firm_ret']*100:+6.2f}%/yr | split ${r['firm_profit']-dep:>7,.0f} deposits ${dep:>7,.0f} "
                  f"| revoked {r['agents_revoked']:4.0f} (skilled {r['skilled_revoked']*100:3.0f}%) scaled {r['agents_scaled']:4.0f} prec {r['precision']*100:3.0f}% "
                  f"| cum skilled ${r['skilled_cum']:>6,.0f} noise ${r['noise_cum']:>6,.0f} | trades {r['mean_trades']:4.1f}")
        print()
