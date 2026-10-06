# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.12.0] - 2026-10-06

Live trading in this release ships on test evidence only: the US paper acceptance run (five sessions from 2026-10-06) and the TW production acceptance are pending, and fixes from them follow as patch releases.

### Added

- `bt target` prints `cash` and `debit` after `equity` for US and TW decisions: the free cash and margin loan the fill planner sizes from.
- Multi-stock US live trading in one market, with one joint decision and fill plan for all strategy symbols.
- Multi-stock TW live execution in one market and one account, with per-code snapshots, inventory, exchange, financing ratio, and costs. `bt live` now executes every declared TW code; the stage 1 startup check `TW live trading needs one stock in this release` is gone.
- TW production decisions pre-check all buy holds against `trading_available` and `margin_available`, rollover and refinance rebuys included, and fail the session with `TW symbol CODE is suspended`, `TW buy budget short: planned X, available Y`, or `TW margin budget short: planned X, available Y` before any order. They log the seven contract fields per code and the planned and available budgets; a code without a usable `limit_up` is priced at `reference x 1.10` and logged. `bt target --live` runs the same check and prints these lines to standard error. Simulation skips these reads.
- `Shioaji.contract_info` reads `GET /api/v1/data/contracts/CODE/info` and `Shioaji.trading_limits` reads `POST /api/v1/portfolio/trading_limits`, with `parse_contract_info`, `parse_trading_limits`, their records, and recorded fixtures. `Live.check_tw_budget` runs the pre-check, and `Live.decide` takes `?tw_contract_infos`, `?tw_trading_limits`, and `?tw_log` for injected inputs and audit lines.
- `Shioaji.trades_today` reads today's trades on every code in one request. `Live.tw_session_step` skips the whole session when it returns any order, including one on a code outside the strategy.
- Shared live decisions reject mixed markets, duplicate symbols, multi-stock provisional-price overrides, and history gaps in the last five union sessions.

### Changed

- US `bt live` and `bt target` size orders through the backtest fill planner, as `bt run` does. They map Alpaca's signed cash and every held strategy stock, valued at its provisional close, into the planner state, splitting the account debit into per-symbol margin lots in proportion to position value, so leveraged targets trade the planner's quantities. Alpaca's `equity` field no longer sizes orders; the `startup` line still logs it. `Live.us_plan_action` replaces `Live.decide_action` and `Live.us_rebalance_action`.
- US decisions fail with `US account cash is not finite`, `US account holds a short position`, `US account holds other symbols`, or `US account equity is not positive` before planning. `bt target` places no order, and `bt live` retries until its submit cutoff. The on_change skip text `target unchanged` does not change.
- `bt target` prints account fields once followed by declaration-ordered symbol blocks. US and TW daemon logs separate account and symbol lines; US existing-order, fill, and per-order error lines carry `symbol=SYMBOL`, and TW trade lines carry `code=CODE`.
- US live executes sells before buys in mixed sessions and stops the buy phase unless every sell fills before the cutoff. A rejected, canceled, expired, stopped, uncertain, or still-open sell stops the session with `sell SYMBOL STATE`, `sell SYMBOL uncertain`, or `sell SYMBOL open at cutoff`. A rejected or uncertain order does not block the other orders of its phase whose clock check passes: after a rejected or uncertain sell, the other sells go out and the session then stops before any buy; after a rejected or uncertain buy, the other buys go out. A cutoff reached between submissions logs `symbol=SYMBOL error=submit cutoff passed order=skip` for each affected symbol; an affected sell stops the session before any buy, and known orders still enter the finish pass. Restart deduplication routes existing sells to the sell barrier and existing buys to the finish pass. Restarts retry transient lookup or preflight errors before any new POST; a deterministic sell-barrier stop, a submission cutoff, or an uncertain POST ends the day without retry and reconciles known orders even if cutoff logging fails.
- US decisions check the account positions list before the existing market-value tolerance, rejecting every symbol outside the strategy with `US account holds unsupported symbol SYMBOL`, including for one-stock strategies.
- `Alpaca.positions` lists the account's open position symbols, and `Alpaca.order_t` carries the order `side`.
- `Shioaji.snapshot` fetches every requested contract in one request and matches the responses by code, rejecting missing, duplicate, or extra codes.
- `Live.decision` holds the account fields plus one `asset_decision` per symbol, and TW legs carry their `code` and `exchange`. `Data.common_dates` gives `bt run` and live decisions one date intersection.
- TW execution batches ordinary sells and ordinary buys by phase, with rollover and refinance pairs still run one leg at a time. A rejected or uncertain sell, or a `Common` sell that FOK kills with no fill, stops the session before the refinance pairs and buys, including at N = 1. Pending `IntradayOdd` `ROD` sells are exempt from the `Common` confirmation barrier and provide no same-session proceeds. A failed buy is logged and its siblings continue.
- TW `Common` lot legs use `MKT` + `FOK` instead of `MKT` + `IOC`; `IntradayOdd` legs remain `LMT` + `ROD`.
- The `Shioaji.snapshot` record carries its response `code`, and the `Shioaji.contract_info` record carries the requested `code`. `Live.execute_tw_legs` takes one `tw_execution_asset` per code, with its code, exchange, bid, ask, price, financing ratio, and costs, in place of the scalar per-code arguments, and its result carries the remaining `cash`.

## [0.11.0] - 2026-09-29

### Added

- Daily strategies can declare `rebalance daily` or `rebalance on_change`. The backtest, `bt target`, and both live daemons follow the declared rule. `rebalance daily` re-plans to the effective target every bar, including the bar of a simulated maintenance cure. An undeclared daily strategy trades on_change: `bt run` and `bt target` print a warning on standard error, and `bt live` logs it after the `startup` line. Every command rejects `rebalance` in a `bars` strategy.

### Changed

- US `bt live` and `bt target` skip a session with `target unchanged` when the effective target equals the previous bar's and the strategy declares `rebalance on_change` or nothing. Before, US live resized to the target every session; declare `rebalance daily` to keep that behavior.
- TW decisions value production positions at the provisional close, the price the planner uses, instead of broker `last_price`, and fail the session when that equity is not positive.
- `rebalance`, `daily`, and `on_change` are reserved words, so a strategy can no longer use them as names.

## [0.10.1] - 2026-09-28

### Changed

- Each `bt live` log line starts with a UTC timestamp.
- The US `bt live` submit cutoff moves from 10 minutes to 2 minutes before the close; the decision still runs 15 minutes before the close. The 10 minutes came from the market-on-close 3:50 pm rule, which does not apply to market day orders, and 2 minutes leave room for the 60-second curl timeout before the close.
- TW `bt live` stops placing new orders at 13:24:30 Taipei instead of 13:25:00, and checks that cutoff as the last step before each order request. Continuous trading ends at 13:25, so the 30-second margin reduces the chance that a checked order reaches the broker in the closing call. Status polls still run until 13:25.

### Fixed

- When a US daemon step fails before the submit cutoff and before the order request, the daemon logs `order=retry` and retries every 60 seconds. This covers the Alpaca clock request, a stale cache, fetch, snapshot, and evaluation errors, and the order lookup. Each retry looks up today's client order ID first, so it follows an existing order instead of submitting another. Before, the first such failure skipped the day, so a transient network error could skip the day's decision. At or after the cutoff, a failed order lookup logs `order=skip` and ends the day. Once the daemon sends the order request, the day ends with no retry, because the request may have reached Alpaca and a retry could submit twice: a failed request logs `order submission uncertain ... order=skip`, a `rejected` status logs `error=Alpaca rejected the order order=skip`, and a failure while following the submitted order logs `order=skip`. A failed attempt writes no decision line. For a new submission, the daemon writes it after the order lookup and the pre-submit clock check succeed; for an order already placed today, it writes it after the lookup alone.
- `bt live` refuses to start while another daemon holds `$HOME/.bt/live-<market>-<mode>.lock`, so two daemons that share a `HOME`, market, and mode cannot both submit the day's order. The lock does not exclude daemons with different `HOME` values, even when they trade the same account.

## [0.10.0] - 2026-09-24

### Added

- `bt target` supports TW strategies on the Shioaji simulation server. It requires `--equity TWD`, checks cache freshness independently against the FinMind trading calendar, and plans cash, margin, and refinance legs.
- `bt live` adds a TW simulation daemon. It rolls margin lots over at 18 months and confirms each `MKT` + `IOC` fill before it submits the next order.
- TW `--live` production sizing requires exactly one T+0, T+1, and T+2 row. Spendable cash is `acc_balance + T+1 + T+2`, and the daemon logs T+0 for audit. A real-account observation from 2026-09-16 through 2026-09-18 verified the rule: the TWD -107 payable moved from T+2 to T+1 while `acc_balance` was TWD 100,000, then reached T+0 when `acc_balance` fell to TWD 99,893.

### Changed

- `bt run` and `bt daytrade` require `--capital`. A missing value is a usage error (`run: --capital is required`, `daytrade: --capital is required`). The minimum fee and per-share fees always apply.
- The backtest and live planning floor TW quantities to whole shares for cash inventory and to 1000-share lots for margin inventory. US quantities stay fractional.
- The TW default commission is 0.0285% (SinoPac electronic-trading promotion rate) with a TWD 1 minimum per order. It replaces 0.0399% with a TWD 20 minimum.
- TW live submits `Common` lots plus one `IntradayOdd` remainder per cash leg. It sends odd-lot orders as limit `ROD` orders at the snapshot ask or bid, does not poll them, and skips them on the simulation server. Live planning and execution both use the 14.25 bps settlement-debit list rate.
- If the broker rejects a `Common` order with no fill, TW live still runs the later independent legs. A rejected sell still blocks its dependent rebuy.
- TW live reads positions in shares, so any holding in another symbol, including an odd lot, now makes `bt target` fail and the daemon skip the day, as the one-stock account rule requires. Before, positions were read in whole lots, so the odd-lot part of every holding was not seen and was left out of equity.
- US live submits fractional `market` orders with `time_in_force: day` instead of whole-share market-on-close orders. It skips buys below USD 1 and submits sells of any positive quantity.

### Fixed

- TW live accepts Shioaji snapshot timestamps with 1 to 9 fractional-second digits and truncates them to whole seconds for session-time checks.
- TW live planning now keeps drift when the effective target is unchanged and trades only when the target changes. It applies the minimum commission without rescaling absolute broker values.
- US live and `bt target` reject an Alpaca snapshot whose open, high, low, or latest trade price is not positive and finite. Before, a negative price made the desired share count negative, so the daemon could sell the whole holding.

## [0.9.0] - 2026-09-06

### Added

- `bt daytrade` runs single-stock US `bars Nm` strategies with session-aware next-open or same-close fills, forced flat at session end, and execution-only previous-close buying-power caps.
- Alpaca SIP 1-minute cache and exchange calendar via `bt fetch --bars 1m`, local resampling, and `since_open`/`to_close` strategy series.
- Session-equity metrics, timestamped intraday fill logs, daily baseline comparison, and the opening-range-breakout example. Capital enables dollar costs without whole-share rounding; empty calendar sessions are omitted.

### Changed

- Source tree restructured into per-concern dune libraries (`lang/`, `series/`, `market/`, `engine/`, `metrics/`, `report/`, `broker/`) replacing the flat `lib/` and its wrapped `btlib`; module names, the CLI, and all behavior are unchanged.

## [0.8.0] - 2026-09-05

### Added

- Alpaca live trading, paper mode by default: `bt live STRAT` runs a close-scheduled daemon that fetches Tiingo history, evaluates the strategy on a provisional bar 15 minutes before the US close, and submits one whole-share market-on-close order; `--live` switches to the real-money endpoint and is the only way to reach it.
- `bt target STRAT` prints one complete decision (fetched-through date, provisional bar, target, account equity, held position, proposed order) without submitting anything.
- `bt target --provisional-close PRICE` dry-runs the full decision path outside market hours with an explicitly marked local provisional bar.
- Daemon fail-safe rules: every failure (stale cache, stale snapshot session, API or transport error, rejected order) logs one line and skips the day; submissions are refused after the market-on-close cutoff even if the decision ran late; a deterministic `bt-<symbol>-<date>` client order id is checked before submitting, so restarts never double-order; the daemon keeps no state file - the account is the state.
- Credentials come from `APCA_API_KEY_ID` and `APCA_API_SECRET_KEY`; live trading supports the us market only, enforced at strategy load.
- `Engine.effective_targets` exposes the backtester's target normalization (NaN and negative clamp plus the funding cap) so live decisions trade on exactly the values a backtest would fill.

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

[Unreleased]: https://github.com/Forever-CodingNoob/bt/compare/v0.12.0...HEAD
[0.12.0]: https://github.com/Forever-CodingNoob/bt/compare/v0.11.0...v0.12.0
[0.11.0]: https://github.com/Forever-CodingNoob/bt/compare/v0.10.1...v0.11.0
[0.10.1]: https://github.com/Forever-CodingNoob/bt/compare/v0.10.0...v0.10.1
[0.10.0]: https://github.com/Forever-CodingNoob/bt/compare/v0.9.0...v0.10.0
[0.9.0]: https://github.com/Forever-CodingNoob/bt/compare/v0.8.0...v0.9.0
[0.8.0]: https://github.com/Forever-CodingNoob/bt/compare/v0.7.5...v0.8.0
[0.7.5]: https://github.com/Forever-CodingNoob/bt/compare/v0.7.0...v0.7.5
[0.7.0]: https://github.com/Forever-CodingNoob/bt/compare/v0.6.0...v0.7.0
[0.6.0]: https://github.com/Forever-CodingNoob/bt/compare/v0.5.0...v0.6.0
[0.5.0]: https://github.com/Forever-CodingNoob/bt/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/Forever-CodingNoob/bt/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/Forever-CodingNoob/bt/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/Forever-CodingNoob/bt/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/Forever-CodingNoob/bt/releases/tag/v0.1.0
