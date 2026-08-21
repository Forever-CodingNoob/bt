# Design: E1-based fill planning

Date: 2026-08-21
Status: approved

Supersedes: docs/specs/order-independent-loan-allocation.md (the
two-pass approach had four structural bugs under drift; see the GPT
5.6 Sol max review for the detailed findings).

## Context

The engine must compute all trade sizes, classify buys and sells,
and allocate margin loans before modifying the portfolio. The previous
two-pass approach classified by target direction (`eff > prev_eff`),
but under drift the actual trade direction can differ. Sequential
execution also made loan allocation order-dependent and double-counted
existing borrowing on scale-in.

## Goals

- All trade sizes, costs, and loan amounts are determined from one
  pre-fill snapshot before any portfolio state changes.
- Declaration order does not affect any computed value.
- `T = 1`: cash ends at exactly 0, no loan.
- `T < 1`: cash ends positive, no loan.
- `T > 1`: cash ends negative, loans assigned proportionally.
- The four reviewed bugs (double-counting, direction mis-classification,
  cost estimation mismatch, post-sell insolvency) are eliminated by
  construction.

## Non-goals

- Changes to interest accrual, maintenance formula, solvency guard,
  forced liquidation, sell_out, initial-margin cap, or the VWAP trip
  definition.

## Solving for E1

`E1` is the post-fill equity that accounts for all costs:

```
E1 = E0 - sum_i cost_i
```

Each trade and its cost depend on E1:

```
final_value_i = target_i * E1
trade_i = final_value_i - current_value_i
cost_i = |trade_i| * rate_i
```

`rate_i` is the combined bps rate for asset i: `(fee + slip) / 10000`
for buys, `(fee + tax + slip) / 10000` for sells. The buy/sell
classification is determined by the sign of `trade_i`.

### Iterative solve

1. Set `E1 = E0`.
2. For each asset, compute `trade_i = target_i * E1 - v_i`.
   Classify: positive = buy, negative = sell, zero = unchanged.
3. Compute `cost_i` for each asset using the appropriate rate and the
   per-order minimum fee floor (`min_fee / capital` in value terms)
   when `--capital` is set. `cost_i = max(|trade_i| * rate_i, floor)`
   where the floor applies only when `min_fee > 0` and capital is set.
4. Set `E1 = E0 - sum(cost_i)`.
5. If `|E1 - E1_prev| > 1e-15 * |E0|`, go to step 2.
6. Convergence is guaranteed: costs are a contraction
   (`sum(rate_i) < 1` for any realistic fee schedule). In practice,
   2-3 iterations reach machine precision.

If the classification of any asset flips between iterations, the
rates for that asset change (buy rate vs sell rate). The iteration
handles this correctly because each round recomputes from scratch.

### Properties of the solution

After convergence:

```
cash_after = E1 - sum(final_value_i) = E1 * (1 - T)
```

where `T = sum(target_i)`. This is exact by construction:
- `T = 1`: `cash = 0`, no borrowing.
- `T < 1`: `cash > 0`, surplus cash.
- `T > 1`: `cash < 0`, the deficit is the shortfall.

## Fill plan

After E1 converges, all values are frozen:

1. `final_value_i = target_i * E1` for every asset.
2. `trade_i = final_value_i - v_i` for every asset.
3. `cost_i` from the final iteration.
4. Buy/sell classification from the sign of `trade_i`.

## Execution

The plan executes in two passes. Nothing is recomputed during
execution; the passes only update the portfolio state and record
events.

### Sell pass

For each asset where `trade_i < 0`:
- Set `values.(i) = final_value_i`.
- Loan repayment: `loans.(i) *= final_value_i / v_i` (proportional).
  Full exit (`final_value_i = 0`): `loans.(i) = 0`.
- `cash += (v_i - final_value_i) - cost_i` (proceeds minus sell
  costs).
- Record the fill event and close the trip if exposure reaches 0.

### Solvency check

After all sells, if `equity <= 0` and any position remains, run the
existing solvency guard (liquidate via `sell_out`, set bankrupt).

### Buy pass with loan allocation

Total buy value = `sum(trade_i)` over buys. Cash available after
sells. Shortfall = `max(0, total_buy_value - cash_available)`.

When `shortfall > 0`:

```
capacity_i = trade_i * ratio_i          (for each buying asset)
total_capacity = sum(capacity_j)
loan_delta_i = shortfall * capacity_i / total_capacity
```

The initial-margin cap guarantees `shortfall <= total_capacity`.

For each buying asset:
- `loans.(i) += loan_delta_i`.
- `values.(i) = final_value_i`.
- `cash -= trade_i + cost_i`.
- Record the fill event and start a trip if entering from 0.

### Post-fill

- Update `prev_eff`.
- Maintenance check (existing logic, using `sum(loans)`).
- Bankruptcy check.

## What changes

- `apply_fills` is replaced with the E1 solve, plan, and two-pass
  execution described above.
- `trade` is removed. The fill recording, VWAP bookkeeping, and trip
  lifecycle are inlined into the sell and buy execution loops.
- The `loan_delta` argument is removed.
- The `charge` function is reused in the E1 solve (it already computes
  the cost fraction from a delta and equity).

## What stays

- `sell_out` (for forced liquidation and final close).
- `accrue_interest`, maintenance check, solvency guard, `effective`,
  `day_number`, and all types.
- VWAP trip bookkeeping logic (moved into the execution loops but
  unchanged).
- All existing tests that use zero costs: results are identical
  because `E1 = E0` when costs are zero.

## Tests

- Order independence: two-asset buy at sub-max leverage, both
  declaration orders, assert identical loans and equity.
- Sell-then-buy: sell one asset and buy another on the same bar,
  verify sell proceeds fund the buy before loan allocation.
- Scale-in: targets `[1.5; 2.0; 2.0]`, verify total loan does not
  double-count existing borrowing.
- Drift reversal: target drops from 2.0 to 1.8 after a price
  doubling, verify the fill is classified as a buy (actual exposure
  drifted to 1.33).
- Post-sell insolvency: a sell with min-fee pushes equity below zero
  while another asset remains; verify the solvency guard fires.
- Nonzero costs: two assets with 100 bps fees, both declaration
  orders, verify identical equity and maintenance.
- Buy-and-hold: target 1.0 with costs, verify cash = 0 and loan = 0.
- All existing margin tests pass (with re-derived expectations where
  the E1 sizing produces different values from the old sequential
  sizing; for zero-cost tests, results are identical).
