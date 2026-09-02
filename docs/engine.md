# Engine guide

This document describes how the bt engine simulates trades, computes equity, and handles market-specific rules. For CLI flags see [cli.md](./cli.md). For the strategy DSL see [strategy.md](./strategy.md).

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

## Taiwan market (tw)

### Costs and taxes

A TW trade pays the online commission of 0.0399% on each side, with a 20 TWD minimum per order when `--capital` is given.

Sell-tax classes:

| Symbol class | Sell tax |
|---|---|
| Ordinary bond ETF (`00...B`) | 0% through 2026-12-31 (temporary exemption) |
| Other `00` ETFs and `02` ETNs | 0.1% |
| All other Taiwan symbols | 0.3% |

Override these with `--fee-bps`, `--tax-bps`, and `--slip-bps`. US costs and slippage default to zero.

### Margin financing

A new margin lot borrows 60% of its purchase value for both TWSE and TPEX stocks. The TPEX maximum became 60% on 2014-11-10; use `--financing-ratio 50` for earlier TPEX backtests. Financing ratios resolve from the cached `TaiwanStockInfo` table. `--financing-ratio` overrides all ratios.

Financing interest is a liability at 6.35% per year by default (`--financing-rate`). Interest starts on the second trading bar (T+2) after a loan lot originates. Repayment settles interest through T+2 after the repayment bar. The engine caps this tail at the last bar instead of extrapolating beyond the data. Interest does not reduce cash each day.

TW loan lots mature after 18 calendar months by default (`--loan-term-months`). The maturity keeps the origination day of the month and clamps to the month end when needed. On the first bar at or after maturity, the engine sells the lot's margin inventory and buys back the fundable part on margin. Both legs pay normal costs. Appreciation can free cash. An underwater lot draws its deficit from available cash; any unfundable part stays sold and records the exposure drop. Each rollover increments `refinances`. Use `--loan-term-months 0` to disable the TW term.

Maintenance is total margin inventory value divided by total loan principal. It starts at 166.7% for both TWSE and TPEX margin entries. Below 130% by default (`--maintenance-ratio`), the engine sells all margin inventories at the next open and repays loans and accrued interest from the proceeds. Cash inventories remain.

If equity is zero or less at any close, the solvency guard sells all inventories, keeps any unpaid debt as residual liability, and freezes the account.

### Dividends

The engine uses two price series for each asset. The signal series adjusts for dividends and all corporate events, so strategy rules keep their adjusted-price meaning. The money series adjusts splits, capital reductions, par-value changes, and stock dividends but keeps cash-dividend price drops. Fills, inventory, loans, collateral, and equity use the money series.

On a TW ex-date, the engine books net cash dividends as receivables for the shares in the cash and margin inventories. Receivables count in equity but not in maintenance or fill-planner liquidity. On the first bar on or after the pay date:

- The cash-inventory receivable becomes cash.
- The margin-inventory receivable repays that asset's loan lots pro rata with matching accrued interest. Any excess becomes cash.
- A frozen account still applies paid receivables to residual debt.

If TW data omits a pay date, the loader uses one calendar month after the ex-date. Cash-side dividends and only the margin-side excess after loan paydown trigger one normal cost-bearing fill pass toward current targets. A margin dividend fully consumed by loan paydown preserves drift and does not trigger a fill. `--dividend-tax` defaults to 0%.

Stock-dividend and share-count factors restate per-share cash amounts and volume. `bt fetch` writes TW cash events to `<symbol>.cashdiv.csv`. If the FinMind cash-dividend table returns errors, the fetcher derives missing cash from legacy dividend factors; existing direct rows win on overlapping ex-dates.

### Gap between simulation and the real market

- Fills execute at the recorded close or open price. A real trade pays the bid-ask spread.
- Limit-down locks on forced sales (margin calls, solvency guard) can make a sale unexecutable on that day. The engine fills at the recorded price regardless.
- A real TW margin call gives two business days to restore the ratio to its initial value. The engine liquidates at the next open without a grace period.
- The engine assumes every Taiwan symbol is marginable at the standard TWSE or TPEX ratio. Leveraged ETFs such as 00685L have historically been excluded from margin financing or assigned reduced ratios.
- Board lots (1000 shares for ordinary stocks, 1 share for ETFs) and tick sizes are not modeled. The engine trades fractional shares.
- Dividend cash timing uses a one-month fallback when the pay date is missing. Real pay dates vary.
- T+2 cash settlement is not modeled. Proceeds from a sale are immediately available.
- Day-trade tax reduction (half sell tax for same-day round trips) is not modeled.
- Odd-lot trades (below the board-lot size) are not modeled.

## United States market (us)

### Costs

US costs and slippage default to zero. Override with `--fee-bps`, `--tax-bps`, and `--slip-bps`.

### Dividends

US dividends use the adjusted-close ratio. A ratio change that matches the inverse raw-price jump is a share-count event (split), not cash. It restates money prices and both volume planes.

US dividends become cash on their ex-date with no receivable period. This zero-lag treatment is a simplification. When dividend cash arrives, the engine runs one normal cost-bearing fill pass toward the current targets.

### Open-ended margin

US loan lots are always open-ended. The engine does not model Reg T initial margin requirements, pattern-day-trader rules, or FINRA maintenance requirements.

### Gap between simulation and the real market

- The split-detection heuristic uses the adjusted-close ratio. Rounding noise in adjusted prices can misidentify small dividends as splits or vice versa.
- No short selling is modeled.
- No borrow costs are modeled.
- No US regulatory margin rules (Reg T, FINRA maintenance) are modeled.
