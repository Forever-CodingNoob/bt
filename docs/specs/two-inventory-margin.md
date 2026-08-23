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
- Every target within the regulatory cap is reachable
  (refinance-on-demand); no silent undershoot.
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

Account: `cash >= 0` (invariant).

```
equity = cash + sum(cash_value_i + margin_value_i)
       - sum(loan_i) - sum(interest_i)
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

### Sells

Assets whose planned total value decreases sell margin inventory
first (stops interest soonest, repays the loan), then cash inventory.
A margin sell of value X: proceeds = X - repayment - settled interest
- sell costs, where repayment = loan_i * X / margin_value_i
(proportional). Cash receives the proceeds. Trip and VWAP bookkeeping
are unchanged, computed on the asset's total exposure.

### Buys

For each buying asset, purchase B_i at total available cash C (after
sells and refinancing):

- Cash-funded slice: `x_i = B_i` when cash suffices, else
  `x_i = max(0, (C_i - (1 - ratio_i) * B_i) / ratio_i)` with C_i the
  cash allocated to this buy. Derivation: cash spent is
  `x_i + (1 - ratio_i) * (B_i - x_i) <= C_i`.
- Margin slice `m_i = B_i - x_i`: cash pays `m_i * (1 - ratio_i)`,
  `loan_i += m_i * ratio_i`.

Multi-asset allocation of scarce cash across simultaneous buys is
pro-rata by purchase size (order-independent).

### Refinancing

When the plan's buys need more cash than sells and existing cash
provide (the down payments cannot be covered), the plan inserts
refinancing legs: sell cash-inventory shares and rebuy the same value
into the margin inventory. Each refinanced unit of value frees
`ratio_i` of cash and leaves the asset's exposure unchanged. Both
legs charge full costs (sell commission + tax + slip, buy commission
+ slip). Selection is same-asset first, then pro-rata across other
assets' cash inventories (order-independent). With refinancing, any
target satisfying the regulatory cap `sum(t_i * (1 - ratio_i)) <= 1`
is reachable, so the existing `effective` clamp remains exact and
sufficient.

The report counts refinancing events.

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

Bankruptcy: when equity <= 0, sell everything, freeze the account
(no interest, fills, or checks afterward) — carried forward
unchanged.

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

- Inventory split: 2x entry gives cash inventory E/3, margin
  inventory 5E/3, loan E, maintenance exactly 5/3.
- Maintenance is 1/ratio at entry for 1.2x, 2x, and 2.5x.
- Cash invariant: cash >= 0 after every bar of every test.
- Refinancing: a walled scale-in (cash 0) refinances same-asset,
  frees exactly ratio per unit, charges both legs, reaches the
  target; refinancing count asserted.
- Pro-rata refinancing across two assets is declaration-order
  independent.
- Interest: accrues as liability, settles proportionally on partial
  repayment, fully on exit; cash untouched by accrual; equity
  reflects the liability daily.
- Margin call: liquidates margin inventories only; cash shares
  survive; loans and interest settle; call date recorded; remaining
  exposure persists until a target change.
- Regulatory cap reachable: target 2.5x TWSE from cash 1.0 succeeds
  via full-margin funding without a clamp.
- Cash-only identity: an all-in/all-out costed strategy matches the
  E1 model bit for bit.
- Bankruptcy freeze carried forward.

## Migration

- `lib/engine.ml`: state arrays split; interest liability; fill
  planner extended with inventory split and refinancing; sells
  margin-first; maintenance formula; call liquidation scope;
  `margin_stats` gains `refinances : int`.
- `lib/report.ml`: margin line gains refinances.
- `test/test_bt.ml`: per the Tests section; existing margin tests
  re-derived.
- `docs/strategy.md`, `docs/cli.md`, `README.md`, `CHANGELOG.md`
  (uncommitted working file), `CONTRIBUTING.md`: margin semantics
  updated; disclose the marginability assumption.
