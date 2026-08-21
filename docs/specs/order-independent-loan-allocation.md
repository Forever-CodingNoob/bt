# Design: order-independent loan allocation

Date: 2026-08-21
Status: approved

## Context

`apply_fills` calls `trade` per asset in declaration order. Each
`trade` updates cash and checks `cash < 0` to decide whether the fill
is margin-financed. The first asset can absorb all available cash,
changing the loan decision for later assets. The same portfolio gets
different loan amounts depending on stock declaration order.

Example: equity 100, buy A = 90, buy B = 30, ratio 60%, zero fees.

- Order A then B: A uses 90 cash, B needs margin.
  loan = 30 * 60% = 18, maintenance = 120 / 18 = 666.7%.
- Order B then A: B uses 30 cash, A needs margin.
  loan = 90 * 60% = 54, maintenance = 120 / 54 = 222.2%.

The engine must decide all loan amounts before it processes the
individual trades.

## Fix

Replace the per-trade loan decision in `apply_fills` with a two-pass
fill:

### Pass 1: sells

Process every asset whose effective target decreased (including full
exits). Each sell repays its proportional loan and returns proceeds to
cash, exactly as today. This nets sell proceeds into the cash pool
before any buy.

### Pass 2: buys with joint loan allocation

Collect every asset whose effective target increased. Compute the
total purchase value and the available cash after sells.

If `total_buy <= cash`: every buy is cash-funded, no loans created.

Otherwise:

```
shortfall = total_buy - cash
capacity_i = buy_i * ratio_i
total_capacity = sum(capacity_j)
loan_i += shortfall * capacity_i / total_capacity
```

The initial-margin cap in `effective` guarantees
`shortfall <= total_capacity`. Each asset's position is sized and cash
is updated as before; only the loan assignment changes.

### Buy value

`buy_i` is the value increase for asset i: the new position value
minus the old position value after the fill. In the current engine
this is `desired * equity_after - old_value` where `equity_after`
accounts for costs.

### Sell loan repayment

Unchanged from the current engine: on a partial sell,
`loan_i *= new_value / old_value`. On a full exit, `loan_i = 0`.

## Invariants

- `sum(loan_i) = shortfall` on every buy bar.
- Declaration order does not affect loan amounts.
- Single-asset fills reduce to `loan = min(shortfall, capacity)`,
  which equals `shortfall` when the initial-margin cap holds.
- Buy-and-hold at target 1.0: shortfall = 0 (cash covers the
  purchase exactly), so loan stays 0.

## Scope

Only the loan-assignment logic in `trade` and `apply_fills` changes.
The initial-margin cap, interest accrual, maintenance formula,
solvency guard, forced liquidation, sell_out, and cost charging are
unchanged.

## Tests

- Two-asset buy at sub-max leverage, both orders: assert identical
  loan amounts, identical maintenance, identical equity.
- Two-asset with one sell and one buy on the same bar: verify sell
  proceeds fund the buy before the loan check.
- Single-asset regression: verify loan amounts match the current
  engine exactly.
- All-in (target 1.0) regression: loan stays 0, equity unchanged.
