# Design: margin financing with drift accounting

Date: 2026-08-19
Status: approved in discussion; pending spec review

## Context

The engine resets exposure to the target fraction every bar and charges
nothing for leverage. Under that daily reset, the loan stays
proportional to equity and the maintenance ratio is the constant
`e / (e - 1)`, so a margin call can never fire below 4.33x. Real TW
margin trading (融資) holds shares against a fixed loan: exposure
drifts, interest accrues, and the maintenance ratio decays in
drawdowns until the broker force-sells.

This is sub-project C of the DSL-expressiveness update, built on
sub-project B's portfolio engine. Approved decisions: drift
accounting; full liquidation at the next open on a margin call;
financing ratios from a cached `TaiwanStockInfo` table with a CLI
override.

## Goals

- Positions drift between fills; a fill happens only when the target
  series changes value.
- Financing interest on borrowed cash, default 6.35% per year.
- Initial margin bound by TW financing ratios: TWSE 60%, TPEX 50%.
- Account-level maintenance ratio, default 130%; below it after a
  close, full forced liquidation at the next open.
- Cash-only all-in/all-out strategies and the baseline reproduce
  today's numbers exactly.

## Non-goals

- Short selling (融券) and securities lending.
- Modeling the two-day top-up grace period: a backtest has no fresh
  capital, so the call resolves by liquidation at the next open.
- US margin rules. The flags apply as given; no US classification.
- Broker-specific rate tiers or per-position (non-account) maintenance.

## Accounting

### State

Per run: cash `c` and per-asset position values `v_i >= 0`, all in
equity units. Start: `c = 1.0`, every `v_i = 0`. Equity
`= c + sum_i v_i`. Negative cash is the loan. Exposure
`e_i = v_i / equity` is derived and drifts.

### Accrual, every bar

- Each `v_i` scales by its asset's price return: close-to-close on a
  bar without fills; in `Open_next` on a fill bar, the two joint legs
  (close-to-open, fills, open-to-close) exactly as sub-project B
  defined them, applied to `v_i` values.
- Interest before fills: if `c < 0`, then
  `c -= (-c) * rate * days / 365`, where `days` is the calendar-day
  difference between the previous bar's date and this bar's date.
  Weekends and holidays accrue. No interest on bar 0.

### Fills

A fill for asset i happens only when the clamped target value changes:
`clamp(target_i(t)) <> clamp(target_i(t-1))`, plus a nonzero clamped
target on bar 0. Forced liquidation (below) is the only other trade.

Fill mechanics per asset, in declaration order, mirroring the current
engine's sequence:

1. `from_e = v_i / equity` (drifted exposure).
2. Cost fraction = `|target_i - from_e| * rate_i / 10000` with the
   existing buy/sell rate split and the per-order minimum-fee floor
   when `--capital` is set. Charge it: `c -= cost_fraction * equity`.
3. Size to the post-cost equity: `v_i' = target_i * equity'`, and the
   value difference moves through cash:
   `c -= (v_i' - v_i)`.

With this sequence a buy-and-hold strategy keeps `c = 0` exactly and
`e = 1` forever, so all-in/all-out results are unchanged to the last
bit.

### Initial margin cap

At fill time the TW self-funding rule binds:
`sum_i v_i * (1 - ratio_i) <= equity`, with `ratio_i` the financing
ratio (0.6 TWSE, 0.5 TPEX). Single-stock corollary: max exposure
2.5x TWSE, 2.0x TPEX. When the requested targets violate the bound,
all requested targets scale down uniformly by the largest feasible
factor, and the run counts the clamp. The engine also treats the
scaled targets as the effective targets for the change-detection of
later bars.

### Trips and fills log

Unchanged mechanics from sub-project B: `from_e` is the drifted
exposure at fill time; VWAP weights use the exposure change per fill;
trip boundaries are exposure leaving and returning to zero, which
happens only through fills or forced liquidation.

## Margin call

After the close of any bar where `c < 0`:
`maintenance = sum_i v_i / (-c)`. If it is below the maintenance
ratio (default 130%), the account is force-liquidated at the next
bar's opens: every position sells with sell costs, cash absorbs the
proceeds, and the run records one margin call with its date. After
liquidation the strategy stays flat until an asset's target series
next changes value; it does not re-lever on an unchanged target. A target
change that lands on the breach bar itself re-enters at the same fill slot
as the liquidation; staying flat applies only while the effective target
series remains unchanged after the call. A breach on the last bar coincides
with the existing final force-close.

The engine tracks the minimum maintenance ratio observed while a loan
exists.

## Data: TWSE/TPEX classification

`bt fetch` (tw market) downloads the free `TaiwanStockInfo` dataset
once per fetch into the shared cache `data/tw/stockinfo.csv` with
header `stock_id,type,date`, keeping only rows whose `type` is `twse`
or `tpex`. The fetch is tolerant like dividends: on failure, keep the
cached file and warn. At load, a symbol resolves to the row with the
latest date; `twse` maps to 60%, `tpex` to 50%. An unknown symbol or
a missing cache defaults to 60% with
`warning: financing ratio unknown for <symbol>; assuming TWSE 60%`.

## CLI

- `--financing-rate PERCENT` — annual financing rate, default 6.35.
- `--maintenance-ratio PERCENT` — default 130.
- `--financing-ratio PERCENT` — forces one uniform financing ratio for
  every asset and skips classification.

Flags apply to strategies and baseline alike; the baseline at target
1.0 never borrows, so it is unaffected in practice.

## Report

Remove the footer `Exposure above 1.0 uses daily-reset leverage.`
(now false). When a loan existed at any bar of any strategy column,
print one line per affected strategy:
`<name>: margin — financing 6.35%/yr, min maintenance 145.20%, margin calls 1, clamps 0`
with the run's actual values. No table changes.

## Result changes

- All-in/all-out strategies (targets only 0 or 1) and the baseline:
  identical output.
- Fractional and leveraged strategies change on three axes: drift
  between fills, financing interest, and possible margin calls or
  initial-margin clamps. The `channel_ladder` family is affected; its
  published numbers must be re-derived after this lands.

## Tests

- Drift: constant fractional target across moving prices produces no
  fill and the drifted equity path, hand-computed.
- Interest: a leveraged position held across a weekend gap accrues
  `rate * 3 / 365` on the loan, hand-computed via dates.
- Fill sizing: buy-and-hold with costs keeps cash at exactly 0.
- Initial margin: requested 3x on a TWSE asset scales to 2.5x and
  counts one clamp; a mixed TWSE/TPEX pair scales by the account
  formula.
- Margin call: a leveraged position with falling closes crosses the
  maintenance ratio, force-liquidates at the next open, stays flat
  under an unchanged target, and re-enters on the next target change;
  min-maintenance and call-count statistics assert exact values.
- Classification: stockinfo cache resolution (twse, tpex, latest date
  wins), unknown-symbol warning and 60% default, `--financing-ratio`
  override.
- Regression: every all-in/all-out test passes unchanged; tests with
  fractional or leveraged targets update with derivations in comments.
- End-to-end: the existing multi-stock CLI test gains a leveraged
  variant asserting the margin report line.

## Migration

- `lib/engine.ml`: cash/position state, drift, interest, fill
  sizing, initial-margin clamp, maintenance check, forced
  liquidation, margin statistics in `result`.
- `lib/data.ml`: `fetch_stockinfo`, `stockinfo.csv` cache, ratio
  lookup helper.
- `bin/bt.ml`: three flags, per-asset ratio resolution, margin
  statistics plumbed to the report.
- `lib/report.ml`: footer replacement, margin line.
- `test/test_bt.ml`, `docs/strategy.md` (target semantics note),
  `docs/cli.md` (flags, margin line), `CONTRIBUTING.md` (engine
  contract line), `README.md` (margin summary). Respect user edits;
  edit surgically.
