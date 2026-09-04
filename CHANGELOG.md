# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.7.5] - 2026-09-04

### Changed

- A strategy may declare the same stock symbol multiple times under distinct aliases (needed for analog runs mapping several legs to one underlying); duplicate-alias and mixed-alias guards remain.
- When the same market/symbol appears under multiple aliases, the engine labels each leg `market/symbol#alias` so trades.csv rows and the `name:` line are attributable per leg.
- Terminal report lines use ASCII hyphens instead of em dashes.

## [0.7.0] - 2026-09-02

### Added

- Tiingo end-of-day US data source with canonical four-file cache layout (raw OHLCV, events, cash dividends, dividend factors).
- Split-factor snap to nearest small rational p/q (p,q at most 50) for exact price and volume restatement.
- Market profile (`profile_of_market`) carries interest day count, settlement lag, maintenance model, and default financing rate per market. One pure function replaces hardcoded constants.
- US tiered maintenance: 100% below $2.50, 50% $2.50-$6, 30% above $6 (Alpaca overnight table). Breach at close schedules a next-open minimum cure that sells the smallest fraction of margin inventory restoring equity to the required level.
- US default costs modeled on Alpaca: SEC fee 0.206 bps sells-only (effective 2026-04-04), FINRA TAF $0.000195/share with $0.01 floor and $9.79 cap (effective 2026-01-01), zero commission.
- `--per-share-fee` and `--per-share-cap` flags override the per-share sell fee and its cap.
- US interest uses /360 day count and T+1 settlement lag.

### Changed

- A run simulates exactly one market: mixing tw and us stocks (or a baseline from another market) in one `bt run` is now a usage error.
- US cache format uses raw prices without adj_close; one unified two-plane loader serves both TW and US markets.
- Incremental US fetch with append and head-gap backfill (same as TW).
- Cache files grouped into per-symbol subdirectories: `data/<market>/<SYMBOL>/<SYMBOL>.csv`. The shared `data/tw/stockinfo.csv` stays at the market level.
- `margin.maintenance_ratio : float` replaced by `margin.maintenance_override : float option`. Unset means the default model for each market (tiered for US, 130% collateral/loan for TW). An explicit value overrides with a flat rate.
- `--financing-rate` and `--maintenance-ratio` defaults resolve per market profile instead of hardcoded values.

### Removed

- FinMind USStockPrice fetch path and close/adjClose derivation heuristics.

### Fixed

- US symbols default to Reg T 50% financing ratio instead of the TW 60% fallback with a spurious warning.

## [0.6.0] - 2026-09-02

### Added

- Dividend data layer with signal and money two-price-plane architecture.
- TW cash dividends: ex-date receivables, pay-date margin-loan paydown, and cost-bearing re-fill trigger.
- `--dividend-tax` CLI flag (default 0%).
- `bt fetch` writes TW cash events to `<symbol>.cashdiv.csv`.
- Fallback cash derivation from legacy dividend factors when the FinMind cash-dividend API returns errors.
- Stock-dividend and share-count factor restatement of per-share cash amounts and volume.

### Fixed

- Receivable liquidity excluded from fill-planner collateral.
- Intersected ex-dates outside the bar range no longer create phantom events.
- Cash-clamp for unlevered funding gaps that would otherwise create a spurious micro-loan.
- Re-fill fires only on actual cash receipt, not on margin-consumed paydown.
- Dividend basis restated correctly across stock dividends and US splits.

## [0.5.0] - 2026-09-01

### Added

- Two-inventory margin engine with separate cash and margin inventories per asset.
- TW margin loan term (18 calendar months by default) with free rollover at maturity.
- T+2 settlement-window interest on origination and repayment.
- Collateral-only maintenance: margin calls liquidate only margin inventory.
- Bankruptcy guard freezes the account at zero-or-negative equity.
- `.mli` interface files for all six library modules.
- Volume restatement across share-count events (splits, reductions, par-value changes).

### Changed

- TPEX sell-tax classes and financing ratios aligned with current TW rules.
- Engine state reworked from aggregate value tracking to per-asset two-inventory accounting.

### Fixed

- Solvency and cash invariants in two-inventory engine.
- Financing plan deficit, refinance gating, and debt identity after sell-then-buy sequences.

## [0.4.0] - 2026-08-21

### Added

- Margin financing with drift accounting: positions drift between fills instead of daily reset.
- Per-asset cash and margin inventory tracking with lot-level loan origination.
- Calendar-day interest with T+2 settlement start.
- Maintenance check with next-open margin-call liquidation below a configurable threshold.
- Solvency guard at every close: zero-or-negative equity sells all and freezes.
- `--financing-rate`, `--maintenance-ratio`, `--financing-ratio`, and `--loan-term-months` CLI flags.
- Cached `TaiwanStockInfo` for per-symbol financing ratio classification.
- Order-independent loan allocation with minimum-down-payment reservation and capped waterfall.
- E1-based fill planning for simultaneous margin allocation across assets.

### Fixed

- Solvency guard executes before fills.
- Margin loan tracked separately from cash.
- Margin loans allocated jointly across assets in a single pass.

## [0.3.0] - 2026-08-19

### Added

- Exact corporate-action adjustment via FinMind split, capital-reduction, and par-value-change tables.
- Multi-stock strategies with `stock "market/symbol" as alias` syntax and dotted qualification.
- Per-asset cost defaults and portfolio engine with exposure-weighted VWAP trip returns.
- `bt run` accepts multiple strategy files with `--baseline M/SYM` comparison sugar.
- TW cache backfill via atomic prepend with idempotent head-gap fetch.
- `bt fetch` positional `MARKET/SYMBOL` argument and `--from 1994-10-01` default.
- Stem-named output files (`<a_vs_b>.csv/.png`) and `--out-name` override.
- GNU LGPL v2.1 license.
- `--capital` flag for per-order minimum fee.

### Changed

- The 25% close-to-close gap split heuristic replaced by exact event factors.

### Removed

- `--market` and `--symbol` CLI flags (replaced by `stock` DSL statement).

## [0.2.0] - 2026-08-18

### Added

- Target-exposure engine model with `Close_same` and `Open_next` fill modes.
- `target` (style 1) and partial-order `entry`/`exit`/`size`/`cap` (style 2) DSL styles.
- `hold(set, reset)` and `num(bool)` builtins with scalar broadcast for `cross_above`/`cross_below`.
- Round-trip statistics with per-leg VWAP returns.
- `--fill` CLI flag (default `close`).
- Complete CLI reference in docs/cli.md.

### Changed

- Engine rewritten around a canonical target-exposure array.

## [0.1.0] - 2026-08-17

### Added

- `bt fetch` subcommand: FinMind API data fetch for TW and US markets with local CSV cache.
- `bt run` subcommand: backtest `.strat` files with equity curve, trades CSV, and matplotlib PNG output.
- Strategy DSL with ocamllex/ocamlyacc parser: `param`, `let`, `entry when`, `exit when`, `size`.
- Indicators: `sma`, `ema`, `rsi`, `bb_upper`, `bb_lower`, `atr`, `lag`, `cross_above`, `cross_below`.
- Return-based engine with daily close-to-close signal prices.
- TW dividend back-adjustment via FinMind factors.

[Unreleased]: https://github.com/Forever-CodingNoob/bt/compare/v0.7.5...HEAD
[0.7.5]: https://github.com/Forever-CodingNoob/bt/compare/v0.7.0...v0.7.5
[0.7.0]: https://github.com/Forever-CodingNoob/bt/compare/v0.6.0...v0.7.0
[0.6.0]: https://github.com/Forever-CodingNoob/bt/compare/v0.5.0...v0.6.0
[0.5.0]: https://github.com/Forever-CodingNoob/bt/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/Forever-CodingNoob/bt/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/Forever-CodingNoob/bt/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/Forever-CodingNoob/bt/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/Forever-CodingNoob/bt/releases/tag/v0.1.0
