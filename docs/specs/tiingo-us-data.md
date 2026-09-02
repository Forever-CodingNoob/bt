# Design: Tiingo US data source with a canonical cache format

Date: 2026-09-02
Status: approved

## Goal

Replace the FinMind US price path with Tiingo end-of-day data, and make `data/us/` structurally identical to `data/tw/`: raw prices plus explicit dated event files. One loader serves both markets; the US close/adjClose derivation heuristics are deleted.

## Canonical cache format (both markets)

- `<SYM>.csv`: raw as-traded bars, header `date,open,high,low,close,volume`.
- `<SYM>.events.csv`: unit changes, header `date,factor`, factor = post/pre price ratio (a 4:1 split is 0.25).
- `<SYM>.cashdiv.csv`: cash dividends, header `ex_date,cash_per_share,pay_date` (pay_date may be empty).
- `<SYM>.div.csv`: signal-plane dividend factors, header `date,factor`.

The TW side already matches; it does not change.

## Tiingo fetcher

- Endpoint: `GET https://api.tiingo.com/tiingo/daily/<SYM>/prices?startDate=...&endDate=...&format=csv`, authenticated with the `Authorization: Token` header read from `TIINGO_TOKEN` (0600 temp header file, token never in argv or URLs; a missing variable is a hard error). Verified live: the CSV columns are `date,close,high,low,open,volume,adjClose,adjHigh,adjLow,adjOpen,adjVolume,divCash,splitFactor` with plain `YYYY-MM-DD` dates, explicit per-row `divCash` (SPY 2024-03-15: 1.594937) and `splitFactor` (AAPL 2020-08-31: 4.0).
- Price basis, verified live: `open/high/low/close/volume` are raw as-traded values. Proof one: AAPL's close shows the actual 7:1 split discontinuity (2014-06-06 close 645.57, 2014-06-09 close 93.70) while adjClose is smooth across it. Proof two: SPY's latest row has adjClose equal to close exactly, so adjustment anchors at the present and scales only backward.
- Emission: raw OHLCV to `<SYM>.csv`; every `splitFactor <> 1` row to `events.csv` as `1 / splitFactor`; every `divCash > 0` row to `cashdiv.csv` with empty pay_date; `div.csv` factor computed as `(prev_close - divCash) / prev_close` from the prior raw close.
- splitFactor noise: Tiingo emits values like 7.000007000007001 for a 7:1 split. Before conversion, snap splitFactor to the nearest small rational p/q with p and q at most 50 when the relative difference is below 1e-4; otherwise use the value verbatim. Real splits are simple ratios; the snap keeps price, volume, and cash restatement exact.
- Incremental: raw rows and declared events never change retroactively, so the US fetch adopts the TW append and head-gap backfill machinery; full refetch on every run is retired. Keep-cached-on-failure applies to all four files.
- The adjusted columns are not cached; they may be used only for a fetch-time sanity log, never for adjustment.
- Free-tier limits (50 requests/hour, 1000/day, 500 unique symbols/month) far exceed this tool's usage; one request covers a symbol's full history.

## Removals (clean cutover)

The FinMind `USStockPrice` fetch, the `adj_close` cache column, `read_us_planes`, and all ratio-derivation heuristics (dividend inference, split classification, cent-rounding tolerances) are deleted, with their `.mli` exports and tests. Existing US caches are refetched once in the new format.

## Unified loader

One two-plane construction for both markets: signal bars = raw prices times dividend and event factors; money bars = raw prices times event factors only; volume restated by the inverse cumulative event factor in both planes; dividend cash events from `cashdiv.csv`. Market selects only the cache directory and the pay-date rule: TW uses the real pay date or ex-date plus one calendar month; US uses the ex-date (the engine credits US dividends at the ex-date, unchanged). The engine interface does not change.

## Verification

- Fetcher transform fixtures: splitFactor to event factor, divCash to cashdiv and div factor arithmetic, an AAPL-2020-shaped split fixture, a dividend-and-split-same-file fixture.
- Loader parity fixture: US planes built by hand equal the unified loader's output.
- TW regression: full suite green; 00685L smoke byte-identical pre/post (TW paths must not move).
- US comparison: SPY buy-and-hold before and after, both tables recorded with an interpretation paragraph; small shifts are expected because authoritative events replace inferred ones.
- Live check: one real `bt fetch us/SPY` through a fresh `bt-test<n>.exe`, confirming all four files and a clean incremental re-fetch.

## Docs and changelog

CHANGELOG `[Unreleased]`: Added (Tiingo US source), Changed (US cache format, incremental US fetch), Removed (FinMind US path). Docs: engine.md US section, cli.md fetch page and defaults, README data notes; ToCs regenerated for touched files.

## Execution

One task agent, compact brief, sequential steps; commits only (the user pushes); no git-settings changes; Claude co-author trailer.
