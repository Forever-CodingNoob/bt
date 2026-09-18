# Engine guide

This document describes how the bt engine simulates trades, computes equity, and handles market-specific rules. For CLI flags see [cli.md](./cli.md). For the strategy DSL see [strategy.md](./strategy.md).

## Contents

- [Core engine](#core-engine)
  - [Targets and drift](#targets-and-drift)
  - [Fill planner](#fill-planner)
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

A strategy states a target exposure per bar. The engine trades only when the clamped target changes from the previous bar. Between fills, positions drift with the market price. There is no free daily-reset rebalancing.

### Fill planner

The fill planner sizes each trade and funds it from the account.

A buy uses available cash first. When required down payments exceed available cash, the engine executes an E1-based iterative planner:

1. Reserve every minimum down payment across all simultaneous buys.
2. Allocate remaining cash through a capped waterfall proportional to purchase size. Each asset's surplus is capped at the amount that makes its purchase entirely cash inventory.
3. When cash cannot cover a required margin down payment, refinance existing inventory. A cash inventory contributes capacity `r * cash_value`. A margin inventory contributes `max(0, r - (loans + interest) / margin_value) * margin_value`. Shortage is allocated pro rata by capacity.
4. Each refinancing sell leg charges commission, tax, and slippage. Each buy leg charges commission and slippage.
5. If cash plus capacity cannot fund the minimum payments and iterative leg costs, buys scale down and the report increments `clamps`.

Sells execute margin inventory before cash inventory.

### Equity accounting

The engine tracks account cash and separate cash and margin inventories for every asset.

Each margin purchase creates a separate loan lot with its origination bar, principal, and accrued interest. Partial repayments reduce all lots for that asset pro rata. A full margin exit clears the lots and carries any unpaid amount as residual debt.

Equity is computed as:

```
equity = cash + cash_inventories + margin_inventories - loan_principal - accrued_interest - residual_debt
```

Cash never goes below zero after a complete frozen sell-refinance-buy sequence.

### End-of-data close

At the end of the data, every open inventory is sold at its last close with normal sell costs. Margin-sale proceeds settle loan principal and accrued interest. The settlement tail is capped at that same last bar. Trip statistics use per-leg VWAP returns.

## Daily market behavior

The core accounting above is shared by both daily markets. Data, costs, financing, dividends, live-decision fidelity, and known simulation gaps are market-specific.

### US market (us)

#### Data source

US market data comes from [Tiingo](https://www.tiingo.com) end-of-day prices. The Tiingo response provides raw OHLCV bars, per-row cash dividends (`divCash`), and per-row split factors (`splitFactor`). The fetcher stores raw prices in `<symbol>.csv`, signal-plane dividend factors in `<symbol>.div.csv`, cash dividends in `<symbol>.cashdiv.csv`, and split events in `<symbol>.events.csv` (factor = 1/splitFactor). The adjusted columns from Tiingo are not cached.

Split factors are snapped to the nearest small rational p/q (p and q at most 50) when the relative difference is below 1e-4. This removes Tiingo's floating-point noise (e.g., 7.000007 becomes 7) and keeps price, volume, and cash restatement exact.

#### Costs and taxes

A US trade pays no commission by default. Alpaca charges zero commission for equities.

Sell-side regulatory fees:

| Fee | Rate | Effective | Source |
|---|---|---|---|
| SEC fee | 0.206 bps ($20.60 per $1,000,000) | 2026-04-04 | SEC fiscal-year schedule |
| FINRA TAF | $0.000195 per share, $0.01 floor, $9.79 cap | 2026-01-01 | FINRA fee schedule |

The SEC fee applies as the default `tax_bps` for US sells. The TAF applies only when `--capital` supplies a dollar scale. Without `--capital`, per-share dollar amounts are inactive.

Override with `--fee-bps`, `--tax-bps`, `--slip-bps`, `--per-share-fee`, and `--per-share-cap`.

#### Margin financing

US margin defaults to the Reg T initial-margin ratio of 50%. US loan lots are always open-ended: there is no term maturity, and `--loan-term-months` does not apply. `--financing-ratio` overrides the default.

Financing interest is a liability at 6.25% per year by default (`--financing-rate`). The Alpaca formula is `daily_charge = debit_balance * rate / 360`. Interest starts on the next trading bar (T+1) after a loan lot originates. Repayment settles interest through T+1 after the repayment bar. The engine caps this tail at the last bar instead of extrapolating beyond the data.

Maintenance uses a tiered required-margin table evaluated at each close on the money series:

| Close price | Required margin |
|---|---|
| Below $2.50 | 100% of position value |
| $2.50 to $5.99 | 50% of position value |
| $6.00 and above | 30% of position value |

The required margin is the sum of each long position's tier rate times its position value. The account passes while equity is at least the required margin.

`--maintenance-ratio PCT` overrides the entire table with one flat rate. Use this for leveraged ETFs that carry house requirements (2x ETFs at 50%, 3x ETFs at 75%).

A breach at close schedules a next-open minimum cure. The engine sells the smallest proportional fraction of margin inventory whose proceeds (after repaying the associated loan share and paying costs) restore equity to at least the required margin. Positions survive partially. This matches the Alpaca policy of liquidating only enough to reduce the margin requirement sufficiently.

If equity is zero or less at any close, the solvency guard sells all inventories, keeps any unpaid debt as residual liability, and freezes the account. Bankruptcy and the solvency guard are shared with TW.

#### Dividends

US dividends use the same two-plane architecture as TW. The signal plane adjusts for both dividends and splits. The money plane adjusts for splits only.

US dividends become cash on their ex-date with no receivable period. When dividend cash arrives, the engine runs one normal cost-bearing fill pass toward the current targets.

#### Live trading fidelity

The live daemon implements the close-fill assumption by evaluating a provisional bar 15 minutes before the close and submitting a market-on-close order.

#### Gaps between simulation and the real market

- Leveraged-ETF house requirements (2x 50%, 3x 75%) and short tiers are not auto-classified. Use `--maintenance-ratio` to set the correct rate.
- The concentration rule (single position at 70% of equities value with a margin balance of $100,000 or more raises that position to 50%) is not modeled.
- Intraday buying power (4x) and the intraday margin framework are out of scope. The engine is end-of-day.
- Elite-tier margin pricing (4.75%) is a `--financing-rate` override, not a default.
- CAT fee pass-throughs are not modeled.
- No short selling or borrow costs are modeled.
- Pattern-day-trader rules are not modeled.

### Taiwan market (tw)

#### Data source

TW market data comes from [FinMind](https://finmind.github.io). `bt fetch` stores raw prices in `<symbol>.csv`, signal-plane dividend factors in `<symbol>.div.csv`, cash dividends with ex and pay dates in `<symbol>.cashdiv.csv`, and split, capital-reduction, and par-value-change events in `<symbol>.events.csv`. The shared `TaiwanStockInfo` classification lands in `data/tw/stockinfo.csv`.

If the FinMind cash-dividend table returns errors, the fetcher derives missing cash amounts from the legacy dividend factors; existing direct rows win on overlapping ex-dates.

#### Costs and taxes

A TW trade pays the online commission of 0.0399% on each side, with a 20 TWD minimum per order when `--capital` is given.

Sell-tax classes:

| Symbol class | Sell tax |
|---|---|
| Ordinary bond ETF (`00...B`) | 0% through 2026-12-31 (temporary exemption) |
| Other `00` ETFs and `02` ETNs | 0.1% |
| All other Taiwan symbols | 0.3% |

Override these with `--fee-bps`, `--tax-bps`, and `--slip-bps`.

#### Margin financing

A new margin lot borrows 60% of its purchase value for both TWSE and TPEX stocks. The TPEX maximum became 60% on 2014-11-10; use `--financing-ratio 50` for earlier TPEX backtests. Financing ratios resolve from the cached `TaiwanStockInfo` table. `--financing-ratio` overrides all ratios.

Financing interest is a liability at 6.35% per year by default (`--financing-rate`). Interest starts on the second trading bar (T+2) after a loan lot originates. Repayment settles interest through T+2 after the repayment bar. The engine caps this tail at the last bar instead of extrapolating beyond the data. Interest does not reduce cash each day.

TW loan lots mature after 18 calendar months by default (`--loan-term-months`). The maturity keeps the origination day of the month and clamps to the month end when needed. On the first bar at or after maturity, the engine sells the lot's margin inventory and buys back the fundable part on margin. Both legs pay normal costs. Appreciation can free cash. An underwater lot draws its deficit from available cash; any unfundable part stays sold and records the exposure drop. Each rollover increments `refinances`. Use `--loan-term-months 0` to disable the TW term.

Maintenance is total margin inventory value divided by total loan principal. It starts at 166.7% for both TWSE and TPEX margin entries. Below 130% by default (`--maintenance-ratio`), the engine sells all margin inventories at the next open and repays loans and accrued interest from the proceeds. Cash inventories remain.

If equity is zero or less at any close, the solvency guard sells all inventories, keeps any unpaid debt as residual liability, and freezes the account.

#### Dividends

The engine uses two price series for each asset. The signal series adjusts for dividends and all corporate events, so strategy rules keep their adjusted-price meaning. The money series adjusts splits, capital reductions, par-value changes, and stock dividends but keeps cash-dividend price drops. Fills, inventory, loans, collateral, and equity use the money series.

On a TW ex-date, the engine books net cash dividends as receivables for the shares in the cash and margin inventories. Receivables count in equity but not in maintenance or fill-planner liquidity. On the first bar on or after the pay date:

- The cash-inventory receivable becomes cash.
- The margin-inventory receivable repays that asset's loan lots pro rata with matching accrued interest. Any excess becomes cash.
- A frozen account still applies paid receivables to residual debt.

If TW data omits a pay date, the loader uses one calendar month after the ex-date. Cash-side dividends and only the margin-side excess after loan paydown trigger one normal cost-bearing fill pass toward current targets. A margin dividend fully consumed by loan paydown preserves drift and does not trigger a fill. `--dividend-tax` defaults to 0%.

Stock-dividend and share-count factors restate per-share cash amounts and volume.

#### Live trading fidelity

The TW daemon is a Shioaji simulation and production execution path around the unchanged daily engine planner.

- At 13:05 Taipei it validates a same-session Shioaji snapshot, queries FinMind's independent `TaiwanStockTradingDate` calendar for the previous session, refreshes prices only through that date, refreshes dividend and corporate-action data through the current session, and rejects any price cache that does not end exactly at the previous session.
- At 13:20 it validates a fresh per-decision snapshot, builds today's provisional OHLCV bar, and runs the same strategy compiler, target normalization, costs, financing ratio, and fill planner used by the daily backtest.
- Simulation requires `--equity TWD` as total account equity. With the supported one-stock account shape, cash is inferred as equity minus cash and margin inventory value plus loan principal and interest. A nonzero holding in another symbol is rejected.
- Production requires exactly one broker settlement row for each of T+0, T+1, and T+2 and rejects missing, duplicate, or other T-day rows. Spendable cash is `acc_balance + T+1 + T+2`; T+0 is already reflected in `acc_balance`, so it is validated and logged but excluded from the sum. Equity adds Common-lot positions at broker `last_price` and subtracts loans and interest. Pending T+1 and T+2 settlements alter the cash budget but do not skip the session.
- The client reads each margin position's dated Shioaji `position_detail`. A lot due under the engine's 18-calendar-month, month-end-clamped TW rule adds a margin sell/rebuy pair before ordinary planner legs. The executor floors every leg to `Common` lots of 1000 shares and retains the remainder.
- Orders use `MKT` + `IOC` during continuous trading. The executor rechecks the Taipei session and the fresh per-order cutoff before every submission and every status poll; nothing is submitted at or after 13:25.
- Every successor waits for a unique, matching, completely filled predecessor with a finite positive weighted fill price. A partial, ambiguous, missing, mismatched, rejected, failed, inactive, cancelled, timed-out, cutoff, or uncertain submission stops the remaining legs and logs the observed exposure.
- Refinance sells and rebuys are sequential. A rebuy requires a full sell fill and enough cash for the original lot count. An unfunded rebuy or capped ordinary buy stops later legs.
- Querying today's orders before planning reduces duplicate submissions, but does not guarantee exactly-once execution across concurrent daemons or every crash timing.

> [!WARNING]
> Daily backtests fill fractional shares at recorded closes and make proceeds immediately available. TW daemon simulation floors to 1000-share Common lots, uses a 13:20 snapshot and actual IOC fill reports, may stop after a partial plan, and applies a confirmed-cash budget between orders. Results can therefore diverge even though both paths use the same planner.

Production startup logs every cash-formula input and the derived cash and equity. The 2026-09-16 through 2026-09-18 real-account observation verified that `acc_balance` is debited when the payable reaches T+0, so the logged T+0 amount is audit-only.

#### Gaps between simulation and the real market

- Fills execute at the recorded close or open price. A real trade pays the bid-ask spread.
- Limit-down locks on forced sales (margin calls, solvency guard) can make a sale unexecutable on that day. The engine fills at the recorded price regardless.
- A real TW margin call gives two business days to restore the ratio to its initial value. The engine liquidates at the next open without a grace period.
- The engine assumes every Taiwan symbol is marginable at the standard TWSE or TPEX ratio. Leveraged ETFs such as 00685L have historically been excluded from margin financing or assigned reduced ratios.
- Board lots (1000 shares for ordinary stocks, 1 share for ETFs) and tick sizes are not modeled. The engine trades fractional shares.
- Dividend cash timing uses a one-month fallback when the pay date is missing. Real pay dates vary.
- T+2 cash settlement is not modeled by the daily backtest. The production daemon includes signed broker T+1 and T+2 amounts in spendable cash and requires the T+0 row for validation and audit.
- Day-trade tax reduction (half sell tax for same-day round trips) is not modeled.
- Odd-lot trades (below the board-lot size) are not modeled.

## Intraday engine

`bt daytrade` uses a separate session engine, not the daily margin engine; the optional baseline remains daily buy-and-hold.

### Sessions and fills

| Rule | Behavior |
|---|---|
| Sessions | Calendar regular hours only, including early closes; sessions with no bars are omitted. |
| Open fills | A decision executes at the next available bar's open within the same session. |
| Close fills | A decision executes at the same bar's close. |
| Last bar | Its decision is ignored; any position closes at that bar's close under either fill mode. |
| Overnight | Cash carries forward, with no positions, financing, dividends, settlement, or maintenance. |
| Costs | Shared US commission, tax, slippage, and per-share sell costs apply to every fill, including forced liquidation. |
| Sizing | Fractional exposure units in both modes; capital enables dollar-based costs, not whole-share rounding. |
| Statistics | One closing equity point per session; trades are flat-to-flat round trips, wins require positive net cash profit after costs, and flat-forced counts liquidated sessions. |

### Leverage cap

NaN decisions become zero and targets above leverage are capped. On execution, desired position value is `min(target * post-cost equity, leverage * previous-close equity)`; the first session uses initial equity as previous close.

> [!IMPORTANT]
> Buying power is checked only at executions. Unchanged targets drift without rebalancing, cap trimming, or liquidation; a price gain can carry position value above the previous-close cap. This is not a continuous collateral guarantee.

### Gap between simulation and the real market

> [!WARNING]
> This model omits broker eligibility and enforcement, and minute OHLCV cannot establish executable prices or queue priority.

| Gap | Consequence |
|---|---|
| Shorts | Negative decisions fail with `short targets are reserved`; an ignored last-bar decision is not executed. |
| Broker enforcement | No day-trade calls, penalties, or broker liquidation. |
| Eligibility | The $25,000 pattern-day-trader switch is not modeled. |
| Hours | No extended-hours or overnight positions. |
| Fill realism | No bid/ask spread, depth, queue, or sub-minute path; missing intervals are not fabricated. |
| Timing sensitivity | Same-close decisions can be optimistic; compare `--fill open` with `--fill close`. Forced flat uses the last available bar's close, which can precede the scheduled close when data is missing. |

