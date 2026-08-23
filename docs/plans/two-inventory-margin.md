# Two-Inventory Margin Engine Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Split each asset into cash and margin inventories with per-inventory loans and interest liabilities, so maintenance, margin calls, funding, and refinancing match real TW margin mechanics and Shioaji's executable surface.

**Architecture:** Engine state per asset becomes `cash_value`, `margin_value`, `loan`, `interest`. Account cash is never negative; equity subtracts loan and interest liabilities. The E1 fill planner extends with inventory splits and pro-rata refinancing legs. Maintenance = margin collateral / loans. Margin calls liquidate margin inventories only. Interest accrues as a liability and settles at repayment.

**Tech Stack:** OCaml (stdlib + Unix), dune, single test binary `test/test_bt.ml`.

**Spec:** `docs/specs/two-inventory-margin.md`

## Global Constraints

- Verification: `opam exec -- dune build && opam exec -- dune runtest` from the repo root.
- Cash-only strategies (no bar ever creates a loan) are bit-identical to the current E1 engine. `test_engine_buyhold_costs` and every zero-cost non-margin test are sentinels: if any changes, STOP and report.
- Every margin test expectation must carry a step-by-step derivation comment. If an observed value differs from the plan's derivation, STOP and report both.
- The formulas below are exact requirements, not suggestions. The implementer writes the OCaml; the algebra is fixed.
- Style: two-space indent, one space on each side of `=`. Commit trailer after one blank line: `Co-authored-by: ChatGPT <noreply@openai.com>`.
- Smoke binary name: `bt-test10.exe` (fallback `bt-test11.exe` if blocked).

---

### Task 1: Engine rework with core tests

**Files:**
- Modify: `lib/engine.ml`, `lib/report.ml` (margin line), `test/test_bt.ml`

**Interfaces:**
- `margin_stats` gains `refinances : int`.
- `Engine.run` signature unchanged.

#### State (replaces the current single `values`/`loans` arrays)

```
cash : float ref                     (invariant: >= 0 outside bankruptcy)
cash_values, margin_values : float array   (per asset, >= 0)
loans, interests : float array             (per asset, >= 0)

total_value i = cash_values.(i) +. margin_values.(i)
equity = !cash +. sum(total_value) -. sum(loans) -. sum(interests)
```

Exposure `e_i = total_value i / equity`. Both inventories scale with price returns (same joint legs as today in both fill modes).

#### Interest

Per bar t > 0, per asset with `loans.(i) > 0.`:
`interests.(i) <- interests.(i) +. loans.(i) *. rate *. days /. 365.`
Never touches cash. When a repayment reduces `loans.(i)` by fraction f, the same fraction of `interests.(i)` is settled: deducted from sale proceeds and from the liability.

#### Fill planning (extends the E1 iteration; tolerance 1e-15 relative, max 20 rounds)

Only assets with `eff.(i) <> prev_eff.(i)` participate. Per iteration with current estimate E1:

1. `final_total_i = eff_i * E1`; `trade_i = final_total_i - total_value_i`. Sells: `trade < 0`; buys: `trade > 0`.
2. **Sells** (margin inventory first): `sell_margin_i = min(|trade_i|, margin_values_i)`; `sell_cash_i = |trade_i| - sell_margin_i`. Repayment `= loans_i * sell_margin_i / margin_values_i`; interest settled at the same fraction. Sell cost from the existing `charge` with the sell-side rates on the exposure delta. Proceeds to cash `= |trade_i| - repayment - interest_settled - sell_cost_value`.
3. **Buy funding**: `available = cash_after_sells`. If `available >= sum(B_i)`: all buys cash-funded. Else allocate `C_i = available * B_i / sum(B)` pro-rata; cash slice `x_i = max(0, (C_i - (1 - r_i) * B_i) / r_i)` (derivation: cash spent `x_i + (1-r_i)(B_i - x_i) <= C_i`); margin slice `m_i = B_i - x_i`; down payment `d_i = x_i + (1 - r_i) * m_i`.
4. **Refinancing**: shortage `S = max(0, sum(d_i) - available)`. When `S > 0`: refinance value per asset `F_j = S * w_j / r_j` with weights `w_j = cv_j * r_j / sum_k(cv_k * r_k)` over ALL assets' post-sell cash inventories (this frees exactly `sum(F_j * r_j) = S` and is declaration-order independent). Each refinance leg: sell `F_j` from the cash inventory (sell-side costs), rebuy `F_j` into the margin inventory (buy-side costs), `loans_j += F_j * r_j`. Feasibility `S <= sum(cv_k * r_k)` is guaranteed by the `effective` regulatory cap; if violated numerically, STOP and report.
5. Buy cost from `charge` with buy-side rates on the exposure delta. `E1_next = E0 - total_costs` (sells + buys + both refinance legs, with min-fee floors per order when `--capital` is set).

Freeze the plan after convergence, then execute: sells, refinance legs, buys. Nothing recomputes during execution.

**Fill events:** buys/sells record as today (from_e/to_e on total exposure). Refinance legs record as paired fill events with `from_e = to_e` (exposure unchanged; VWAP accumulators receive zero delta and are unaffected; the legs appear in trades.csv for transparency). Count each refinancing event (per bar, not per leg) in `refinances`.

#### Maintenance, margin call, bankruptcy

- After each close with `sum(loans) > 0`: `maintenance = sum(margin_values) / sum(loans)`; track the minimum; below the threshold, record the call date and schedule liquidation.
- Liquidation at next open: for every asset, sell the ENTIRE margin inventory, repay `loans` and `interests` from proceeds, remainder to cash. Cash inventories untouched. `prev_eff` untouched (fills resume only on target change).
- Solvency guard (equity <= 0 with any inventory open): sell everything; repay what proceeds allow; any residual loan/interest stays on the books so equity stays negative; freeze (`bankrupt`). Cash never goes negative — the residual liability carries the deficit.
- Final force-close: sell everything at last close (margin inventory first), settle loans and interest.

#### Report

`lib/report.ml` margin line becomes:
`<name>: margin — financing %.2f%%/yr, min maintenance <pct>, margin calls %d, refinances %d, clamps %d`.

#### Hand-derived test expectations (zero cost, ratio 0.6, flat prices unless stated)

Write each as a registered test with the derivation comment:

1. `test_inventory_split`: target 2.0 from equity 1.0. `x = (1 - 0.4*2)/0.6 = 1/3`, `m = 5/3`, `loan = 1.0`, cash 0. Maintenance `= (5/3)/1 = 5/3`. Final force-close returns equity 1.0.
2. `test_maintenance_at_entry`: targets 1.2x, 2.0x, 2.5x in separate runs all give min maintenance exactly `5. /. 3.` (1.2x: m = 1/3, loan = 0.2; 2.5x: x = 0, loan = 1.5).
3. `test_refinance_scale_in`: targets `[1.5; 2.0; 2.0]`. Bar 0: cv = 2/3, mv = 5/6, loan = 0.5, cash 0. Bar 1: buy 0.5 with no cash; shortage S = 0.2; same-asset refinance F = 0.2/0.6 = 1/3; after: cv = 1/3, mv = 5/6 + 1/3 + 0.5 = 5/3, loan = 1.0, cash 0. State EQUALS the direct 2x entry (path independence at zero cost). `refinances = 1`, maintenance 5/3, final equity 1.0.
4. `test_call_liquidates_margin_only`: 2x entry at 100, maintenance threshold 1.3, closes 100 then 75 then 75. At 75: mv = 1.25, maintenance = 1.25 < 1.3 -> call. Next open 75: sell mv, repay 1.0, cash = 0.25, cv = 0.25 survives, equity = 0.5. Assert one call date, final equity 0.5 (force-close of the surviving cv at 75 is free).
5. `test_interest_liability`: 2x held over Fri/Mon/Tue at 6.35%: equity at bar 1 = 1 - 1.0*0.0635*3/365; final = 1 - 1.0*0.0635*4/365 (loan is 1.0 either way; the liability timing is inside equity daily).
6. `test_cap_reachable`: target 2.5 from 1.0: all-margin, down payment exactly 1.0, loan 1.5, clamps 0, maintenance 5/3.
7. `test_refinance_order_independence`: two assets A and B, both holding 1.0 of cash inventory (targets 1.0 constant on bar 0). On bar 1, bump A's target to 1.5: gross = 2.5, need = 1.5*0.4 + 1.0*0.4 = 1.0, exactly the cap boundary, no clamp. The 0.5 buy has no cash, so shortage S = 0.2 refinances pro-rata over both cash inventories (equal weights: F = 0.1/0.6 each). Swap declaration order; assert identical equity, identical total loan, identical maintenance.
8. `test_insolvent_gap` (re-derived): 2x entry, close halves. cv = 1/6, mv = 5/6, loan = 1, equity 0 -> guard sells all, proceeds 1.0 repay the loan exactly, everything 0, final equity 0, min maintenance = 5/6 / 1 = `5. /. 6.` (was 1.0 under the old numerator).
9. Costed sentinel: `test_engine_buyhold_costs` unchanged bit-for-bit.
10. Re-derive every other existing margin test under the new formulas with derivation comments; list all changes at once if several shift; STOP on any zero-cost non-margin change.

- [ ] **Step 1: Write the tests above (failing)**
- [ ] **Step 2: Verify the new tests fail and sentinels pass**
- [ ] **Step 3: Implement the engine rework per the formulas**
- [ ] **Step 4: Full verification; list all margin-test re-derivations in the report**
- [ ] **Step 5: Commit** — message `feat: two-inventory margin engine` with the ChatGPT trailer.

---

### Task 2: Docs, changelog, and smoke

**Files:**
- Modify: `docs/strategy.md`, `docs/cli.md`, `README.md`, `CONTRIBUTING.md`, `CHANGELOG.md` (untracked working file — edit, do not add to git)

- [ ] **Step 1: Update docs** — margin semantics per the spec: two inventories, collateral-only maintenance (166.7% at entry for TWSE), refinancing with costs, calls liquidate margin inventory only, interest at repayment, marginability assumption disclosed. Surgical edits; read each section first.
- [ ] **Step 2: Smoke**

```bash
cp _build/default/bin/bt.exe bt-test10.exe
./bt-test10.exe run /sandbox/research/strategies/channel_ladder.strat \
  --baseline tw/00685L --data-dir data --out-dir /tmp/two-inv-smoke \
  --out-name two_inv --no-plot 2>&1 | tail -8
```

Record the full table and margin line in the report; calls may now appear — that is expected, not a defect.

- [ ] **Step 3: Commit docs** (not CHANGELOG.md) — message `docs: two-inventory margin semantics` with the ChatGPT trailer.
