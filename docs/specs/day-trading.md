# Design: US day trading backtests

Date: 2026-09-05
Status: approved

## Goal

Add US intraday (day trading) backtesting to bt as a new, additive capability: a `bt daytrade` command driven by minute bars from Alpaca, a strategy-file timeframe declaration, and a small session-aware intraday engine. Every existing capability stays intact: `bt run`, `bt fetch` without the new flag, the daily engine, and all daily outputs are byte-identical before and after this work.

## Decisions (settled during design)

- Strict intraday: every position is forced flat at the session close. No overnight exposure ever, so the daily engine's financing, settlement, dividend, and maintenance machinery has no intraday counterpart.
- Long-only now, shorts designed-for: the strategy language accepts signed targets; the intraday engine rejects negative targets with `short targets are reserved`. Adding shorts later is an engine task, not a language migration.
- 1-minute bars are the stored resolution; a strategy declares its timeframe and the runner resamples locally with exact OHLCV arithmetic (first open, max high, min low, last close, summed volume).
- Leverage is a cap, not a broker model: position value may not exceed `leverage x previous-close equity` (default 1.0). No interest (same-day flat pays none), no day-trade calls, no intraday liquidation. For a strictly flat account Alpaca's day-trading buying power formula `(previous close equity - previous maintenance) x 4` collapses to `4 x previous close equity`, so this cap reproduces the normal case exactly; the $25k eligibility switch, call penalties, and mid-day liquidation are documented gaps.
- Fill discipline reuses `--fill`: `open` (default for this command) fills a bar's decision at the next bar's open; `close` fills at the same bar's close. The forced flat at session end always fills at the last bar's close, the backtest twin of the market-on-close order the live daemon places.
- US only. The data source is Alpaca's historical bars API (SIP feed, since 2016, free on the Basic plan for data older than 15 minutes, 200 requests per minute, 10,000 bars per page with `next_page_token`). Regular hours only, bounded per day by Alpaca's calendar endpoint.
- Additive architecture (Approach A): a separate intraday engine library. `Engine.run` is never called by the intraday path and never edited.

## Verified Alpaca facts (docs.alpaca.markets, 2026-09-05)

- Basic plan: historical data since 2016, SIP feed for any query whose `end` is at least 15 minutes old, 200 API calls per minute. Real-time is IEX-only, irrelevant to backtesting.
- Bars endpoint: `GET https://data.alpaca.markets/v2/stocks/{symbol}/bars?timeframe=1Min&feed=sip&start=...&end=...&limit=10000`, paginated via `next_page_token`. Minute bars are aggregated from trades with the timestamp truncated to the minute; the bar timestamp `t` is the left edge of the interval, in UTC.
- Calendar endpoint: `GET /v2/calendar?start=...&end=...` (trading API host) returns each trading day with its open and close times, including early closes.
- Symbol renames are transparent on historical queries (`asof` mapping on by default).
- Auth: `APCA-API-KEY-ID` and `APCA-API-SECRET-KEY` headers, the same key pair the live daemon uses.

## Libraries and modules

Per-concern layout following docs/specs/library-split.md; every new module ships its `.mli`.

- `intraday/intraday.ml` + `.mli`, library `intraday`, depends on `data engine`. Owns the session loop, fills, the leverage cap, the forced flat, and the per-session equity and fill outputs. Reuses `Engine.costs`, `Engine.default_costs "us"`, and the existing cost and per-share fee helpers. Never calls `Engine.run`.
- `market/data.ml` + `.mli` (additive): minute-bar cache read and write, exact OHLCV resampling, session-calendar cache read and write. No fetch code (the `data` library cannot depend on `broker`).
- `broker/alpaca.ml` + `.mli` (additive): `bars` (paginated 1-minute fetch) and `calendar`.
- `lang/` (additive): the `bars <n>m` statement (timeframe declaration; a file that contains it is an intraday strategy) and two injected session series, `since_open` and `to_close`, both in minutes of the session, available to expressions like `close` or `volume`. The runner computes them from the calendar; the compiler treats them as predefined series.
- `bin/bt.ml` (additive): the `bt daytrade` subcommand and the `--bars 1m` flag on `bt fetch`. `bt run` rejects a `bars` strategy with `day trading strategies run under bt daytrade`; `bt daytrade` rejects a strategy without `bars` with `bt daytrade requires a bars declaration`, and a tw strategy via a match arm with `day trading supports us only`.

## Data

Cache layout, additive to the existing per-symbol directory:

```
data/us/<SYMBOL>/1m/<YYYY>.csv    time,open,high,low,close,volume
data/us/calendar.csv              date,open,close
```

- `time` is an ET session-local timestamp `YYYY-MM-DDTHH:MM` (DST-correct, sortable). Conversion from Alpaca's UTC `t` uses the calendar's per-day open and close, which carry the ET offset.
- Fetches are incremental by year file: existing years are kept, the current year is appended from its last cached minute, and rows outside the day's regular session are dropped. Keep-cached-on-failure applies as in the daily fetcher.
- `bt fetch us/SYM --bars 1m` writes both files. `bt fetch` without `--bars` is byte-for-byte today's daily Tiingo path.
- `Data.bar` is reused for minute bars (`date` carries the timestamp), so every indicator in `series/` runs on minute bars unmodified. Indicators are continuous across sessions (a 20-bar SMA at 9:30 looks back into the previous session); strategies gate warmup with `since_open` when they want it.
- Resampling: `bars <n>m` accepts any positive integer n. Buckets are anchored at each session's open and never cross a session boundary; a partial final bucket (for example the last 30 minutes of a 13:00 early close under `bars 60m`) is kept as its own bar. `bars 1m` is the identity.

## Command surface

```
bt daytrade STRAT... [--baseline us/SYM] [--fill open|close] [--leverage N] [--from YYYY-MM-DD] [--to YYYY-MM-DD] [-p name=value] [--capital USD] [--fee-bps F] [--tax-bps F] [--slip-bps F] [--per-share-fee F] [--per-share-cap F] [--data-dir DIR] [--out-dir DIR] [--out-name NAME] [--no-plot]
bt fetch us/SYM --bars 1m [--data-dir DIR]
```

- New flags: `--bars 1m` on `fetch`; `--leverage N` (default 1.0) on `daytrade`. All other `daytrade` flags are the existing `bt run` flags with the same semantics; `--fill` defaults to `open` for this command.
- Rejected on `daytrade` as usage errors: `--financing-rate`, `--maintenance-ratio`, `--loan-term-months`, `--dividend-tax`. Nothing intraday consumes them.
- The timeframe is not a flag. `bars 5m` lives in the strategy file next to the `stock` declaration.

## Engine semantics

- Sessions: bars are grouped by session date from the calendar. State is cash, long shares, and the previous session's closing equity.
- Targets: the DSL evaluates over the whole resampled series exactly as `bt run` receives them. Intraday normalization: NaN becomes 0; a negative target is a run error `short targets are reserved`; values above `leverage` are capped.
- Sizing mirrors `bt run`: exposure units by default; whole shares with per-share fees when `--capital` is given. The position value may never exceed `leverage x previous-close equity` (first session: initial equity).
- Fills: `open` fills bar i's decision at bar i+1's open; `close` fills at bar i's close. A decision on the session's last bar is ignored. At the last bar the position is forced to zero at that bar's close regardless of fill mode.
- Overnight: cash carries; nothing else does. No interest, dividends, settlement lags, or maintenance code exists in the intraday engine.
- Costs: `Engine.default_costs "us"` and the existing fee, tax, slippage, and per-share flags apply to every fill including the forced flat.

## Outputs

- Equity series: one point per session close, so `Metrics` (CAGR, Sharpe, MaxDD, Calmar) and the report table work unchanged with correct daily annualization.
- Report line per strategy adds `sessions`, `trades`, `win rate`, and `flat-forced` (sessions where the close forced a liquidation).
- `--baseline us/SYM` reuses the daily buy-and-hold from the Tiingo cache over the same span.
- Files: `<name>.csv` per-session equity (same shape as `bt run`); `<name>.trades.csv` with header `time,stock,price,from_exposure,to_exposure`. The daily fill-log contract is untouched.
- Plot reuses scripts/plot.py on the session equity.

## Verification

- TDD per behavior with hand-derived fixtures: resampling exactness (5m from 1m, including a partial final bucket), session grouping with a 13:00 early close, last-bar decision ignored, forced flat at the last bar's close under both fill modes, open-vs-close latency on a two-bar move, leverage cap anchored to previous-close equity (a mid-day gain does not expand it), negative-target rejection, NaN to 0, and the `bars` routing errors in both directions.
- Alpaca `bars` and `calendar` parsing against recorded fixture JSON, no network in tests.
- Gates at every commit: daily TW byte-identity (channel_ladder vs the standing reference); daily `bt fetch` path unchanged (a daily fetch produces byte-identical cache files); all builds and tests in the `/sandbox/stock-daytrading` worktree only, never in `/sandbox/stock`.
- Smoke: fetch one year of SPY 1-minute bars through a fresh blessed `bt-test<n+1>.exe`, run a trivial `bars 5m` strategy, hand-check one session's fills against the cache.

## Docs

- docs/cli.md: `bt daytrade` section and the `--bars` flag under `bt fetch`, in the style codified in CONTRIBUTING.md (subsections, alert semantics, option tables with defaults).
- docs/strategy.md: the `bars` declaration and the `since_open` and `to_close` series.
- docs/engine.md: a new "Intraday engine" section with its own gap subsection (no shorts, no day-trade calls or broker liquidation, regular hours only, $25k eligibility not modeled, minute-bar fill realism and the open-vs-close sensitivity).
- CHANGELOG.md: Added entries under [Unreleased].

## Non-goals

- Short selling (reserved in the language, refused by the engine).
- Overnight holding on intraday bars, extended-hours sessions, sub-minute data.
- TW intraday data or trading.
- Day-trade calls, broker liquidation, the $25k eligibility rule.
- Live intraday trading; the live daemon stays daily.
- Any change to the daily engine, the daily fetch path, or daily outputs.
