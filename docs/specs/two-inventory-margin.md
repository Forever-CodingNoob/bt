# Design: two-inventory margin engine

Date: 2026-08-22
Status: approved

Supersedes the accounting, fills, initial-margin, and margin-call
sections of docs/specs/margin-financing.md and
docs/specs/e1-fill-planning.md. The E1 solve, the drift fill trigger,
the calendar-day interest rate convention, VWAP trips, and the
bankruptcy freeze carry forward.

## Context

Real TW margin (TWSE Article 50) tracks cash-bought shares (現股) and
margin-bought shares (融資部位) as separate inventories. Each margin
purchase creates a loan of exactly purchase value times the financing
ratio; the buyer pays the remainder in actual cash. The maintenance
ratio counts only the margin inventory as collateral:
維持率 = 融資擔保品市值 / 融資金額. Interest accrues on the loan and
settles at repayment, not from daily cash.

The current engine aggregates each asset into one value and one loan.
Four realism gaps follow: the maintenance numerator wrongly includes
cash-funded shares (reads 200% at 2x where reality reads 166.7%);
cash can go negative beyond what loans explain (impossible in
reality); interest drains cash daily (real interest is a liability
settled at repayment); and cash-constrained scale-ins either fail or
borrow beyond the regulatory financing ratio.

Shioaji (the target live-trading API) confirms the two-inventory
reality: StockPosition carries per-position cond (Cash or
MarginTrading), margin_purchase_amount, and interest. A live bot can
compute the account maintenance ratio locally and can sell margin
positions itself, but has no API operation for 現金償還 (repaying a
loan from cash without selling). The engine must model only what the
bot can execute.

## Goals

- Maintenance = margin collateral / loan, exactly 1/ratio at purchase
  for any leverage level.
- Cash never negative. Every purchase settles with real cash.
- Interest as a liability settled at repayment.
- Targets inside the regulatory cap are reached through refinancing when the post-sell inventories have enough capacity; a deep-capacity shortfall scales buys and increments `clamps` rather than silently overspending.
- Margin calls liquidate the margin inventory only; cash shares
  survive.
- Cash-only strategies (gross target <= 1 always) are bit-identical
  to the E1 model.

## Non-goals

- 現金償還 as a rescue (not executable via Shioaji).
- Preemptive deleveraging guards (the strategy's job).
- Short selling, securities lending, broker-specific rate tiers,
  disposition-stock ratio adjustments, marginability eligibility
  lists (every tw symbol is assumed marginable at its classified
  ratio; the report discloses the assumption).

## State

Per asset i:

- `cash_value_i >= 0` — market value of the cash inventory.
- `margin_value_i >= 0` — market value of the margin inventory.
- `loan_i >= 0` — 融資金額, set at purchase, reduced only by
  repayment.
- `interest_i >= 0` — accrued financing interest liability.

Account:

- `cash >= 0` — settled cash, floored at zero after each complete funding sequence.
- `debt >= 0` — residual account-level liability that cannot be assigned to a surviving inventory.

```
equity = cash + sum(cash_value_i + margin_value_i)
       - sum(loan_i) - sum(interest_i) - debt
```

Exposure `e_i = (cash_value_i + margin_value_i) / equity` is derived
and drifts. Both inventories scale with the asset's price return each
bar (the same joint legs as before in Open_next).

## Interest

Each bar t > 0, per asset with `loan_i > 0`:

```
interest_i += loan_i * rate * days / 365
```

with `days` the calendar-day gap between bar dates. Interest never
changes cash or loan_i directly. When a repayment reduces `loan_i` by
fraction f, the proceeds pay `f * interest_i` (removed from the
proceeds and from the liability). Full repayment settles the full
accrued interest.

## Fills

The fill trigger is unchanged: an asset fills only when its clamped
effective target changes value (plus a nonzero target on bar 0).
Forced liquidation is the only other trade.

### Fill planning (E1 solve, extended)

E1 = E0 - total costs, where costs cover the sell legs, the buy legs,
and any refinancing legs. The iteration from the E1 spec carries over
(tolerance 1e-15 relative, max 20 rounds); refinancing amounts are
functions of E1, so they join the iteration. The frozen plan contains
per asset: final total value, inventory split, trades per inventory,
loan delta, interest settlement, refinancing legs, and all costs.

The frozen plan executes atomically in sell, refinancing, then buy order, so a temporary sell-pass deficit remains in the funding accumulator until all planned legs have run.
Only a final aggregate shortfall restores unpaid planned loan and interest settlements proportionally; any remainder becomes account debt and settled cash is floored at zero.

### Sells

Assets whose planned total value decreases sell margin inventory
first (stops interest soonest, repays the loan), then cash inventory.
A margin sell of value X: proceeds = X - repayment - settled interest
- sell costs, where repayment = loan_i * X / margin_value_i
(proportional). Cash receives the proceeds. Trip and VWAP bookkeeping
are unchanged, computed on the asset's total exposure.

### Buys

For every planned purchase `B_i`, first reserve its minimum down payment `d_i = (1 - ratio_i) * B_i`; an asset with `ratio_i = 0` instead has `d_i = B_i`.

Let `D = sum(d_i)` and let `S = min(max(0, C - D), sum(ratio_i * B_i))` be cash available beyond all minimum down payments after sells and planned refinancing.
Allocate `S` through a capped waterfall: distribute the remaining surplus in proportion to `B_i` among uncapped buys, cap each allocation `a_i` at `ratio_i * B_i`, and redistribute any residue until no surplus remains.
For `ratio_i > 0`, the cash inventory slice is `x_i = a_i / ratio_i`, the margin inventory slice is `m_i = B_i - x_i`, settled cash is `d_i + a_i`, and `loan_i` increases by `ratio_i * m_i`; a zero-ratio purchase is entirely cash inventory.
This minimum-down-payment-first waterfall is order-independent and prevents a large buy from consuming cash needed to make another simultaneous buy legal.

### Refinancing

Refinancing is planned only when one or more positive buys exist and their aggregate minimum down payments exceed cash from the account and planned sells.
After planned sells, cash inventory `cash_value_i` contributes funding capacity `K_cash_i = ratio_i * cash_value_i`.
Margin inventory contributes freed-cash rate `q_i = max(0, ratio_i - (loan_i + interest_i) / margin_value_i)` and capacity `K_margin_i = margin_value_i * q_i`, with both values zero when `margin_value_i = 0`.
The shortage is allocated pro-rata across every positive cash and margin capacity, independent of asset declaration order.
A cash-inventory allocation sells value `allocation / ratio_i` and rebuys it as margin inventory; a margin-inventory allocation sells value `allocation / q_i`, settles its proportional loan and interest, and rebuys the same value at `ratio_i`.
The refinance sell leg charges commission, tax, and slippage; its buy leg charges commission and slippage, so both legs are fully costed and leave target exposure unchanged.
A sell-only fee deficit never creates refinancing legs; it follows the final aggregate-shortfall path instead.

The regulatory cap `sum(t_i * (1 - ratio_i)) <= 1` remains the target envelope, and refinancing makes a target within it reachable only when available cash plus `sum(K_cash_i + K_margin_i)` covers the requested minimum down payments and iterative leg costs.
If this deep-capacity condition fails, the planner uniformly scales positive buys to the fundable fraction and increments `clamps`; it never assumes unconditional reachability under the cap.
The report counts bars with planned refinancing and reports the separate clamp counter.

## Maintenance and margin call

After the close of any bar with `sum(loan_i) > 0`:

```
maintenance = sum(margin_value_i) / sum(loan_i)
```

At purchase this equals `1 / ratio` (166.7% TWSE, 200% TPEX)
regardless of leverage; it moves only with prices afterward. Below
the maintenance threshold (default 130%): at the next bar's opens the
engine sells the entire margin inventory of every asset (self-directed
liquidation, better than the broker's T+3 disposal and executable via
Shioaji), repays all loans and accrued interest from the proceeds,
records the call date. Cash inventories are untouched; the account
continues at its remaining exposure and fills again only when a
target changes value.

Bankruptcy occurs when equity is non-positive: the engine sells every remaining inventory, settles as much loan, interest, and account debt as proceeds allow, floors cash at zero, leaves any residual debt on the books, and freezes all later interest, fills, and checks.

## Report

The margin line becomes:

```
<name>: margin — financing 6.35%/yr, min maintenance 145.20%, margin calls 1, refinances 3, clamps 0
```

`min maintenance` now reflects the collateral-only formula.

## Result changes

- Cash-only strategies: bit-identical to the E1 model.
- Every leveraged number changes again. Maintenance at entry drops to
  1/ratio (166.7% TWSE) from the previous funding-gap formula, so
  margin calls fire more readily; a 22% collateral drawdown from any
  entry hits 130%. channel_ladder results must be re-derived and may
  now show calls.
- Interest totals change slightly (liability timing vs daily cash
  deduction).

## Tests

- Inventory split: 2x entry gives cash inventory E/3, margin inventory 5E/3, loan E, and maintenance exactly 5/3.
- Maintenance is 1/ratio at entry for 1.2x, 2x, and 2.5x.
- Minimum-down-payment-first allocation and its capped surplus waterfall are declaration-order independent.
- Cash invariant: settled account cash is non-negative after every bar.
- Refinancing: a walled scale-in uses cash- and margin-inventory capacities, allocates the shortage pro-rata by capacity, costs both legs, reaches the target, and increments the refinancing count.
- A temporary underwater-sale deficit remains in the frozen funding sequence until planned refinancing and buys complete.
- A sell-only minimum-fee deficit creates account debt without refinance legs.
- Residual debt is added back when reconstructing available cash, preventing a later funded buy from spuriously refinancing or clamping.
- Interest accrues as a liability, settles proportionally on partial repayment, settles fully on exit, leaves cash untouched during accrual, and reduces equity daily.
- Margin calls liquidate margin inventories only; cash shares survive, loans and interest settle, the call date is recorded, and remaining exposure persists until a target change.
- Regulatory-cap reachability: target 2.5x TWSE from cash 1.0 succeeds through full-margin funding, while a deep-capacity corner scales buys and increments `clamps`.
- Cash-only identity: an all-in/all-out costed strategy matches the E1 model bit for bit.
- Bankruptcy liquidation retains unpaid account debt and the frozen equity curve cannot be resurrected by later prices.

## Migration

- `lib/engine.ml`: state arrays split; account debt added; interest made a liability; the fill planner extended with minimum-first allocation, cash-plus-margin refinancing, and deep-capacity clamps; sells remain margin-first; maintenance uses margin collateral; calls liquidate only margin inventory; `margin_stats` gains `refinances : int`.
- `lib/report.ml`: margin line gains refinances.
- `test/test_bt.ml`: per the Tests section; existing margin tests
  re-derived.
- `docs/strategy.md`, `docs/cli.md`, `README.md`, `CHANGELOG.md`
  (uncommitted working file), `CONTRIBUTING.md`: margin semantics
  updated; disclose the marginability assumption.
