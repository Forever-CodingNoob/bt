# Engine guide

This guide explains how the bt engine simulates trades, computes equity, and applies market-specific rules. See [cli.md](./cli.md) for CLI flags and [strategy.md](./strategy.md) for the strategy DSL.

## Contents

- [Core engine](#core-engine)
  - [Targets and drift](#targets-and-drift)
  - [Fill planner](#fill-planner)
  - [Share quantum](#share-quantum)
  - [Equity accounting](#equity-accounting)
  - [End-of-data close](#end-of-data-close)
- [Daily market behavior](#daily-market-behavior)
  - [US market (us)](#us-market-us)
    - [Data source](#data-source)
    - [Costs and taxes](#costs-and-taxes)
    - [Margin financing](#margin-financing)
    - [Dividends](#dividends)
    - [Live trading fidelity](#live-trading-fidelity)
    - [Gaps between simulation and the real market](#gaps-between-simulation-and-the-real-market)
  - [Taiwan market (tw)](#taiwan-market-tw)
    - [Data source](#data-source-1)
    - [Costs and taxes](#costs-and-taxes-1)
    - [Margin financing](#margin-financing-1)
    - [Dividends](#dividends-1)
    - [Live trading fidelity](#live-trading-fidelity-1)
    - [Gaps between simulation and the real market](#gaps-between-simulation-and-the-real-market-1)
- [Intraday engine](#intraday-engine)
  - [Sessions and fills](#sessions-and-fills)
  - [Leverage cap](#leverage-cap)
  - [Gap between simulation and the real market](#gap-between-simulation-and-the-real-market)

## Core engine

### Targets and drift

A strategy states a target exposure for each bar. The engine trades only when the clamped target differs from the previous bar's. Between fills, positions drift with the market price, and the engine does not rebalance them back to target each day.

### Fill planner

The fill planner sizes each trade and funds it from the account.

A buy uses available cash first. When cash cannot pay for every buy in full, the planner iterates on post-cost equity (E1):

1. Reserve every minimum down payment across all simultaneous buys.
2. Allocate the remaining cash through a capped waterfall, in proportion to purchase size. The cap on each asset's share is the amount that turns its whole purchase into cash inventory.
3. When cash cannot cover a required margin down payment, refinance existing inventory. A cash inventory contributes capacity `r * cash_value`. A margin inventory contributes `max(0, r - (loans + interest) / margin_value) * margin_value`. The planner splits the shortage pro rata by capacity.
4. Each refinancing sell leg pays commission, tax, slippage, and any per-share sell fee. Each buy leg pays commission and slippage.
5. If cash plus capacity cannot fund the minimum payments and the iterated leg costs, the planner scales buys down and the report increments `clamps`.

Sells take margin inventory before cash inventory.

### Share quantum

Each market profile sets a share quantum for each inventory. The planner converts every planned value to shares at the fill price and the `--capital` scale, floors the count to a multiple of the quantum, and converts the count back to value. The floored remainder stays in cash.

| Market | Cash inventory | Margin inventory |
|---|---|---|
| US | Fractional (quantum 0) | Fractional (quantum 0) |
| Taiwan | Whole shares (quantum 1) | 1000-share lots (quantum 1000) |

Cash buys and cash sells use the cash quantum. Margin buys, margin sells, both sides of every refinance, maturity rollovers, and margin-call sales use the margin quantum. Other forced sales use the quantum of the inventory they sell. With a positive quantum, the engine also carries each inventory as a share count between bars. A quantum of 0 skips the floor.

### Equity accounting

The engine tracks account cash plus separate cash and margin inventories for each asset.

Each margin purchase opens its own loan lot, which records the origination bar, principal, and accrued interest. A partial repayment reduces all of that asset's lots pro rata. A full margin exit clears the lots and carries any unpaid amount as residual debt.

The engine computes equity as:

```
equity = cash + cash_inventories + margin_inventories + dividend_receivables - loan_principal - accrued_interest - residual_debt
```

After a complete frozen sell-refinance-buy sequence, cash is never below zero; any deficit becomes residual debt.

### End-of-data close

At the end of the data, the engine sells every open inventory at its last close with normal sell costs. Margin-sale proceeds settle loan principal and accrued interest, with the settlement tail capped at that same last bar. Trip statistics use per-leg VWAP returns.

## Daily market behavior

Both daily markets share the core accounting above. Each market sets its own data, costs, financing, dividends, live-decision fidelity, and known simulation gaps.

### US market (us)

#### Data source

US market data comes from [Tiingo](https://www.tiingo.com) end-of-day prices. Each Tiingo row carries raw OHLCV, a cash dividend (`divCash`), and a split factor (`splitFactor`). The fetcher stores raw prices in `<symbol>.csv`, signal-plane dividend factors in `<symbol>.div.csv`, cash dividends in `<symbol>.cashdiv.csv`, and split events in `<symbol>.events.csv` (factor = 1/splitFactor). It does not cache Tiingo's adjusted columns.

The fetcher snaps each split factor to the nearest small rational p/q (p and q at most 50) when the relative difference is below 1e-4. Snapping removes Tiingo's floating-point noise (for example, 7.000007 becomes 7) and keeps price, volume, and cash restatement exact.

#### Costs and taxes

A US trade pays no commission by default, since Alpaca charges zero commission for equities.

Sell-side regulatory fees:

| Fee | Rate | Effective | Source |
|---|---|---|---|
| SEC fee | 0.206 bps ($20.60 per $1,000,000) | 2026-04-04 | SEC fiscal-year schedule |
| FINRA TAF | $0.000195 per share, $0.01 floor, $9.79 cap | 2026-01-01 | FINRA fee schedule |

The SEC fee is the default `tax_bps` for US sells. The engine charges the TAF in dollars at the `--capital` scale.

Override these with `--fee-bps`, `--tax-bps`, `--slip-bps`, `--per-share-fee`, and `--per-share-cap`.

#### Margin financing

US margin defaults to the Reg T initial-margin ratio of 50%; `--financing-ratio` overrides it. US loan lots stay open-ended with no term maturity, so `--loan-term-months` does not apply.

Financing interest accrues as a liability at 6.25% per year by default (`--financing-rate`). The Alpaca formula is `daily_charge = debit_balance * rate / 360`. Interest starts on the next trading bar (T+1) after a loan lot originates. A repayment settles interest through T+1 after the repayment bar. The engine caps this tail at the last bar instead of extrapolating past the data.

Maintenance uses a tiered required-margin table, evaluated at each close on the money series:

| Close price | Required margin |
|---|---|
| Below $2.50 | 100% of position value |
| $2.50 to $5.99 | 50% of position value |
| $6.00 and above | 30% of position value |

The required margin is the sum, over long positions, of each position's tier rate times its value. The account passes while equity is at least the required margin.

`--maintenance-ratio PCT` replaces the whole table with one flat rate. Use it for leveraged ETFs with house requirements (2x ETFs at 50%, 3x ETFs at 75%).

A breach at the close schedules a minimum cure at the next open. The engine sells the smallest proportional fraction of margin inventory whose proceeds, after the matching loan repayment and costs, bring equity back to at least the required margin. Positions survive in part. This matches Alpaca's policy of liquidating only enough to meet the margin requirement.

If equity is zero or less at any close, the solvency guard sells all inventories, keeps any unpaid debt as a residual liability, and freezes the account. TW shares the same bankruptcy and solvency-guard logic.

#### Dividends

US dividends use the same two-plane design as TW. The signal plane adjusts for dividends and splits. The money plane adjusts for splits only.

A US dividend becomes cash on its ex-date, with no receivable period. When dividend cash arrives, the engine runs one normal cost-bearing fill pass toward the current targets.

#### Live trading fidelity

The live daemon evaluates a provisional bar 15 minutes before the close and submits a fractional `market` order with `time_in_force: day` before the 10-minute cutoff. The order fills near the decision price rather than at the official close, and `--slip-bps` models that gap in the backtest. Live and backtest quantities are both fractional.

#### Gaps between simulation and the real market

- The engine does not auto-classify leveraged-ETF house requirements (2x 50%, 3x 75%) or short tiers. Use `--maintenance-ratio` to set the correct rate.
- The engine does not model the concentration rule, under which a single position at 70% of equities value with a margin balance of $100,000 or more has its requirement raised to 50%.
- Intraday buying power (4x) and the intraday margin framework are out of scope because the engine works end-of-day.
- Elite-tier margin pricing (4.75%) is a `--financing-rate` override rather than a default.
- The engine does not model CAT fee pass-throughs.
- The engine models neither short selling nor borrow costs.
- The engine does not model pattern-day-trader rules.

### Taiwan market (tw)

#### Data source

TW market data comes from [FinMind](https://finmind.github.io). `bt fetch` stores raw prices in `<symbol>.csv`, signal-plane dividend factors in `<symbol>.div.csv`, cash dividends with ex and pay dates in `<symbol>.cashdiv.csv`, and split, capital-reduction, and par-value-change events in `<symbol>.events.csv`. It writes the shared `TaiwanStockInfo` classification to `data/tw/stockinfo.csv`.

If the FinMind `TaiwanStockDividend` request fails with HTTP or API status 400, 402, or 403, the fetcher derives missing cash amounts from the legacy dividend factors. Cached rows win on overlapping ex-dates.

#### Costs and taxes

A TW trade pays SinoPac's electronic-trading promotion commission of 0.0285% on each side, which is 20% of the 0.1425% list rate, with a TWD 1 minimum per asset trade.

Sell-tax classes:

| Symbol class | Sell tax |
|---|---|
| Ordinary bond ETF (`00...B`) | 0% (temporary exemption through 2026-12-31) |
| Other `00` ETFs and `02` ETNs | 0.1% |
| All other Taiwan symbols | 0.3% |

> [!WARNING]
> The bond ETF sell-tax exemption ends 2026-12-31, but `default_costs` in `engine/engine.ml` has no end date. From 2027-01-01, backtests and TW live still price `00...B` sells at 0% tax, so they understate the cost of those sells until someone updates `default_costs`.

Override these with `--fee-bps`, `--tax-bps`, and `--slip-bps`.

#### Margin financing

A new margin lot borrows 60% of its purchase value for both TWSE and TPEX stocks. The TPEX maximum became 60% on 2014-11-10, so use `--financing-ratio 50` for earlier TPEX backtests. The engine resolves financing ratios from the cached `TaiwanStockInfo` table, and `--financing-ratio` overrides all of them.

Financing interest accrues as a liability at 6.35% per year by default (`--financing-rate`). Interest starts on the second trading bar (T+2) after a loan lot originates. A repayment settles interest through T+2 after the repayment bar. The engine caps this tail at the last bar instead of extrapolating past the data. Interest does not reduce cash each day.

TW loan lots mature after 18 calendar months by default (`--loan-term-months`). The maturity date keeps the origination day of the month and clamps to the month end when needed. On the first bar at or after maturity, the engine sells the lot's margin inventory and buys back the fundable part on margin. Both legs pay normal costs. Appreciation can free cash. An underwater lot draws its deficit from available cash; any part the engine cannot fund stays sold, and the fills record the exposure drop. Each rollover increments `refinances`. Use `--loan-term-months 0` to disable the TW term.

Maintenance is total margin inventory value divided by total loan principal. A new margin entry starts at 166.7% on both TWSE and TPEX. When maintenance falls below 130% by default (`--maintenance-ratio`), the engine sells all margin inventories at the next open and repays loans and accrued interest from the proceeds. Cash inventories remain.

If equity is zero or less at any close, the solvency guard sells all inventories, keeps any unpaid debt as a residual liability, and freezes the account.

#### Dividends

The engine keeps two price series for each asset. The signal series adjusts for dividends and all corporate events, so strategy rules keep their adjusted-price meaning. The money series adjusts for splits, capital reductions, par-value changes, and stock dividends, but keeps cash-dividend price drops. Fills, inventory, loans, collateral, and equity use the money series.

On a TW ex-date, the engine books net cash dividends as receivables for the shares in the cash and margin inventories. Receivables count in equity, but not in maintenance or in the fill planner's liquidity. On the first bar on or after the pay date:

- The cash-inventory receivable becomes cash.
- The margin-inventory receivable repays that asset's loan lots pro rata with matching accrued interest. Any excess becomes cash.
- A frozen account still applies paid receivables to residual debt.

If TW data omits a pay date, the loader uses one calendar month after the ex-date. Cash-side dividends, plus any margin-side excess left after loan paydown, trigger one normal cost-bearing fill pass toward the current targets. A margin dividend that loan paydown consumes in full preserves drift and triggers no fill. `--dividend-tax` defaults to 0%.

Stock-dividend and share-count factors restate per-share cash amounts and volume.

#### Live trading fidelity

The TW daemon runs the unchanged daily engine planner inside a Shioaji execution path, in simulation or production.

- At 13:05 Taipei, the daemon validates a same-session Shioaji snapshot and asks FinMind's independent `TaiwanStockTradingDate` calendar for the previous session. It refreshes prices only through that date and refreshes dividend and corporate-action data through the current session. It rejects any price cache that does not end exactly at the previous session.
- At 13:20, it validates a fresh per-decision snapshot and builds today's provisional OHLCV bar. It then runs the same strategy compiler, target normalization, financing ratio, share quantum, and fill planner as the daily backtest, with the 14.25 bps settlement-debit commission in place of the backtest's 2.85 bps default. The planner compares the final effective target with the previous bar's effective target, so an unchanged target preserves drift instead of rebalancing. Live account values are already in absolute TWD, so planner capital is 1 and the TWD 1 minimum commission stays TWD 1.
- Simulation requires `--equity TWD` as total account equity. For the supported one-stock account, the daemon infers cash as equity minus cash and margin inventory value, plus loan principal and interest. It rejects a nonzero holding in any other symbol.
- Production requires exactly one broker settlement row for each of T+0, T+1, and T+2, and rejects missing, duplicate, or other T-day rows. Spendable cash is `acc_balance + T+1 + T+2`. `acc_balance` already reflects T+0, so the daemon validates and logs T+0 but leaves it out of the sum. Equity adds positions, read in shares with `unit: Share` and valued at broker `last_price`, then subtracts loans and interest. Pending T+1 and T+2 settlements change the cash budget but do not skip the session.
- The client reads the dated Shioaji `position_detail` of each margin position. A lot due under the engine's TW rule (18 calendar months, clamped to month end) adds a margin sell and rebuy pair ahead of the ordinary planner legs.
- The planner already floors cash quantities to whole shares and margin quantities to 1000-share lots. Each cash leg becomes one `Common` order for the whole lots plus one `IntradayOdd` order for the remaining 1 to 999 shares. Margin, refinance, and rollover legs use `Common` orders only.
- `Common` orders use `MKT` + `IOC` during continuous trading. `IntradayOdd` orders are limit `ROD` orders at the snapshot ask for a buy and the snapshot bid for a sell, the only order form TWSE accepts for intraday odd lots. The simulation server does not support odd lots, so simulation skips them. Before every submission and every status poll, the executor rechecks the Taipei session and the per-order cutoff. It submits nothing at or after 13:25.
- A `Common` successor waits for a unique, matching, completely filled predecessor with a finite positive weighted fill price. The executor does not poll `IntradayOdd` orders: a buy reserves its full cost at once, and a sale adds no cash in the same session. A `Common` order rejected with no fill lets later independent legs run but blocks its dependent rebuy. A partial, ambiguous, missing, mismatched, timed-out, cutoff, or uncertain result stops the remaining legs and logs the observed exposure.
- Refinance sells and rebuys run in sequence. A rebuy requires a full sell fill and enough cash for the original lot count. An unfunded rebuy or a capped ordinary buy stops the later legs.
- Live planning and execution both use the 14.25 bps settlement-debit list rate with a TWD 1 minimum per order, because SinoPac debits the list rate at settlement and rebates the discount later. Execution funds buys and tracks cash at that rate. Backtests use the 2.85 bps default.
- The daemon queries today's orders before planning to reduce duplicate submissions. This check cannot guarantee exactly-once execution across concurrent daemons or every crash timing.

> [!WARNING]
> Daily backtests fill at recorded closes and make proceeds available at once. The TW daemon uses a 13:20 snapshot and actual IOC fill reports for lot orders. Its odd-lot ROD orders fill in the separate odd-lot book at that book's prices, or not at all. The daemon may stop after a partial plan and applies a confirmed-cash budget between orders. Simulation skips odd-lot orders. Results can diverge even though both paths use the same planner.

Production startup logs every cash-formula input plus the derived cash and equity. A real-account observation from 2026-09-16 through 2026-09-18 confirmed that the broker debits `acc_balance` when the payable reaches T+0, so the logged T+0 amount serves only as an audit record.

#### Gaps between simulation and the real market

- Fills execute at the recorded close or open price, while a real trade pays the bid-ask spread.
- Limit-down locks on forced sales (margin calls, solvency guard) can make a sale unexecutable that day. The engine fills at the recorded price regardless.
- A real TW margin call gives two business days to restore the ratio to its initial value. The engine liquidates at the next open with no grace period.
- The engine assumes every Taiwan symbol is marginable at the standard TWSE or TPEX ratio. Leveraged ETFs such as 00685L have historically been excluded from margin financing or assigned reduced ratios.
- The engine does not model tick sizes.
- Dividend cash timing falls back to one month when the pay date is missing, while real pay dates vary.
- The daily backtest does not model T+2 cash settlement. The production daemon includes signed broker T+1 and T+2 amounts in spendable cash and requires the T+0 row for validation and audit.
- The engine does not model the day-trade tax reduction (half sell tax for same-day round trips).
- Backtest fills of 1 to 999 shares use the same recorded price as lot fills. Live odd-lot orders trade in a separate book whose prices can differ from the regular book, and a limit order can stay unfilled.
- The backtest charges one minimum commission per asset trade. Live execution charges one per order, so a cash leg split into a `Common` order and an `IntradayOdd` order pays two.
- The engine models neither the promotion's monthly TWD 1,000,000 ceiling nor its delayed rebate.

## Intraday engine

`bt daytrade` runs a separate session engine instead of the daily margin engine. The optional baseline stays a daily buy-and-hold run.

### Sessions and fills

| Rule | Behavior |
|---|---|
| Sessions | Regular calendar hours only, including early closes. The engine omits sessions with no bars. |
| Open fills | A decision executes at the next available bar's open within the same session. |
| Close fills | A decision executes at the same bar's close. |
| Last bar | The engine ignores its decision and closes any position at that bar's close under either fill mode. |
| Overnight | Only cash carries into the next session. The engine skips overnight financing, dividends, settlement, and maintenance. |
| Costs | The shared US commission, tax, slippage, and per-share sell costs apply to every fill, including forced liquidation. |
| Sizing | Both modes use fractional exposure units, and capital scales dollar-based costs. |
| Statistics | The engine records one closing equity point per session. Trades are flat-to-flat round trips, a win requires positive net cash profit after costs, and flat-forced counts liquidated sessions. |

### Leverage cap

The engine turns NaN decisions into zero and caps targets at the leverage. On execution, the desired position value is `min(target * post-cost equity, leverage * previous-close equity)`; the first session uses initial equity as the previous close.

> [!IMPORTANT]
> The engine checks buying power only at executions. Unchanged targets drift without rebalancing, cap trimming, or liquidation, so a price gain can carry position value above the previous-close cap. The cap is not a continuous collateral guarantee.

### Gap between simulation and the real market

> [!WARNING]
> This model omits broker eligibility and enforcement, and minute OHLCV cannot establish executable prices or queue priority.

| Gap | Consequence |
|---|---|
| Shorts | Negative decisions fail with `short targets are reserved`. A negative decision on the ignored last bar never executes, so it does not fail. |
| Broker enforcement | The model omits day-trade calls, penalties, and broker liquidation. |
| Eligibility | The model ignores the $25,000 pattern-day-trader switch. |
| Hours | The model trades regular hours only and holds nothing in extended hours or overnight. |
| Fill realism | The model ignores bid/ask spread, depth, queue, and the sub-minute price path, and it does not fabricate missing intervals. |
| Timing sensitivity | Same-close decisions can be optimistic; compare `--fill open` with `--fill close`. Forced flat uses the last available bar's close, which can precede the scheduled close when data is missing. |

