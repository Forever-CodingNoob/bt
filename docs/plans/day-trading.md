# Day Trading Implementation Plan

> **For agentic workers:** Implementers use superpowers:executing-plans ONLY, one task per dispatch. Implementers never dispatch subagents of any kind; the coordinator owns every review. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Execute docs/specs/day-trading.md: US day trading backtests as an additive capability (`bt daytrade`, `bt fetch --bars 1m`, the `bars` declaration, a separate intraday engine), with every daily path byte-identical.

**Architecture:** New `intraday/` library owning the session loop; additive functions in `market/data.ml` (minute cache, calendar, resampling), `broker/alpaca.ml` (bars, calendar), `lang/` (`bars` statement, injected session series), `bin/bt.ml` (subcommand and flag). `Engine.run` and the daily fetch path are never edited.

**Tech stack:** OCaml stdlib + unix, curl and jq subprocesses, dune per-concern libraries (docs/specs/library-split.md), assert tests in test/test_bt.ml with fixtures.

## Global constraints

- Work ONLY in the worktree `/sandbox/stock-daytrading` on branch `day-trading`. Never build, test, or edit in `/sandbox/stock` (a concurrent study runs from its `_build`). Daily caches are read from `/sandbox/stock/data` (read-only, pass `--data-dir /sandbox/stock/data`); minute-bar smokes write to `/sandbox/stock-daytrading/data` (gitignored path).
- The spec docs/specs/day-trading.md is binding: copy endpoint paths, headers, cache headers, error messages, and flag names from it verbatim.
- Additive only: no edits to `Engine.run` or its helpers, no edits to existing `Data.fetch*` functions, no changes to existing CLI dispatch arms, no changes to any existing `.mli` export. New behavior is new functions, new statements, new arms.
- Strict TDD per behavior: failing test first with recorded red output in the report, then minimal code, then green with the full suite. Hand-derived fixtures with derivation comments (CONTRIBUTING.md Tests section).
- Style per CONTRIBUTING.md Style rules in full: stdlib + unix only; no `for`/`while`; `let () = e in` sequencing; tail recursion with accumulators, `Array` index loops for series math; preserve floating-point operation order; one space around `=`, no alignment; `match` arms on markets, never `if market =`; curl and jq as subprocesses; ASCII only. Every new module ships its `.mli` in the same commit; every new library gets its `dune` with minimal `(libraries ...)`.
- Docs per CONTRIBUTING.md Documentation style in full: one h1, disciplined h2-h4, alerts with fixed semantics (NOTE context, TIP usage, IMPORTANT load-bearing, WARNING fidelity gaps, CAUTION destructive), tables for enumerable content with a Default column in cli.md, full-depth ToCs regenerated, no mid-sentence hard wraps.
- Gates after EVERY task, all from the worktree: `dune build` clean; `dune runtest --force` exit 0; daily byte-identity: `_build/default/bin/bt.exe run /sandbox/research/strategies/tw/channel_ladder/main.strat --baseline tw/00685L --data-dir /sandbox/stock/data --out-dir <dir> --out-name fp --no-plot` byte-identical to `/tmp/dt-ref` (files) and `/tmp/dt-ref.txt` (stdout), captured at a9ee698.
- Network only through a fresh blessed binary: `cp _build/default/bin/bt.exe /sandbox/stock/bt-test<n+1>.exe && chmod +x` with a new n after every rebuild; never from `_build/` paths. Keys from the environment (`TIINGO_TOKEN`, `APCA_API_KEY_ID`, `APCA_API_SECRET_KEY`).
- Codex exhaustion (`usage_limit_reached`): pause the task and wait for restoration; never substitute a backend or do the work inline.
- Git: commits only, NEVER push, NEVER touch git settings or the author field; trailer `Co-authored-by: ChatGPT <noreply@openai.com>`.
- Report per task: `/sandbox/stock-daytrading/.superpowers/sdd/day-trading/task-<n>-report.md` with red/green evidence.

## Task 1: minute-bar data layer

**Files:** modify market/data.ml, market/data.mli, broker/alpaca.ml, broker/alpaca.mli, bin/bt.ml, test/test_bt.ml, test/dune (fixture deps); create test/fixtures/alpaca/bars.json, test/fixtures/alpaca/calendar.json, test/fixtures/minute/spy-2024-01-02.csv (one hand-written session of 1m bars, at least 12 rows, plus 3 rows of a 13:00 early-close session).

**Produces (consumed by Tasks 3-4):**
- `type Data.session = { date : string; open_ : string; close : string }` (ET times `HH:MM`).
- `val Data.et_offset_minutes : string -> int` (YYYY-MM-DD -> -240 during US DST, second Sunday of March to first Sunday of November, else -300; pure).
- `val Data.read_calendar : data_dir:string -> session array` / `val Data.write_calendar : data_dir:string -> session list -> unit` (`data/us/calendar.csv`, header `date,open,close`, sorted, deduplicated by date).
- `val Data.read_minute_bars : data_dir:string -> symbol:string -> from_:string option -> to_:string option -> bar array` (reads `data/us/<SYM>/1m/<YYYY>.csv`, header `time,open,high,low,close,volume`, `bar.date` carries `YYYY-MM-DDTHH:MM`).
- `val Data.write_minute_bars : data_dir:string -> symbol:string -> bar list -> unit` (merge into year files, deduplicate by time, sorted).
- `val Data.resample : minutes:int -> sessions:session array -> bar array -> bar array` (anchored at each session open, never crossing a session; partial final bucket kept; `minutes = 1` is the identity; OHLCV = first open, max high, min low, last close, summed volume).
- `val Alpaca.bars : symbol:string -> start:string -> end_:string -> bar list` (`GET https://data.alpaca.markets/v2/stocks/{symbol}/bars?timeframe=1Min&feed=sip&limit=10000&start=&end=`, follows `next_page_token`; converts UTC `t` to ET `YYYY-MM-DDTHH:MM` with `Data.et_offset_minutes`; drops rows outside the day's session per the calendar).
- `val Alpaca.calendar : mode -> start:string -> end_:string -> Data.session list` (`GET /v2/calendar?start=&end=` on the trading host).
- `bt fetch us/SYM --bars 1m [--data-dir DIR]`: refreshes `calendar.csv` from 2016-01-01 through today, then fetches minute bars from the last cached minute (or 2016-01-01) to now minus 16 minutes, writing year files. Keep-cached-on-failure as the daily fetcher. `bt fetch` without `--bars` must not change by a single byte of code path: add the flag as a new match arm and leave the existing arm untouched.

- [ ] RED: `et_offset_minutes` at DST boundaries (2024-03-09 -> -300, 2024-03-10 -> -240, 2024-11-02 -> -240, 2024-11-03 -> -300); calendar round trip; minute-bar write/read round trip across a year boundary; `resample ~minutes:5` on the fixture session with hand-derived OHLCV for the first two buckets and the partial final bucket of the early-close session; `resample ~minutes:1` identity; Alpaca bars and calendar fixture parsing (bars.json with two pages is not needed - parse one page, pagination is exercised by the smoke); UTC-to-ET conversion of a fixture `t` (`2024-01-02T14:30:00Z` -> `2024-01-02T09:30`).
- [ ] Run: `opam exec -- dune runtest --force`. Expected: FAIL on unbound functions. Record.
- [ ] GREEN: implement the functions; wire the `--bars` arm in bin/bt.ml.
- [ ] Gates. Commit `feat: minute-bar cache, calendar, resampling, and Alpaca bars fetch`.

## Task 2: strategy language

**Files:** modify lang/ast.ml, lang/ast.mli, lang/lexer.mll, lang/parser.mly, lang/dsl.ml, lang/dsl.mli, bin/bt.ml, test/test_bt.ml.

**Consumes:** nothing from Task 1 (independent).

**Produces (consumed by Tasks 3-4):**
- AST statement `Bars of int` from the source form `bars <n>m` (n a positive integer; `bars 0m` and `bars 5` are parse errors).
- `val Dsl.timeframe : Ast.program -> int option` (Some n when the program declares `bars`, None otherwise; a second `bars` is a compile error `duplicate bars declaration`).
- Predefined series `since_open` and `to_close` usable in expressions. Injection: the existing compile entry point gains an optional `?extra:(string * float array) list` argument; the daily path passes nothing and its byte-identity holds. When `extra` is absent and a program references `since_open` or `to_close`, compilation fails with `since_open and to_close are available only under bt daytrade`.
- Routing in bin/bt.ml: `bt run` rejects any strategy with `bars` using `day trading strategies run under bt daytrade` (new check before the existing run path, so the existing path is unchanged for programs without `bars`).

- [ ] RED: parse `bars 5m` into `Bars 5`; `bars 0m` and `bars 5` fail; duplicate `bars` fails; `timeframe` returns Some 5 / None; a program using `since_open` compiles with `extra` provided and fails with the exact message without it; `bt run` on a `bars` strategy exits with the routing error.
- [ ] Run: expected FAIL. Record.
- [ ] GREEN: minimal grammar, AST, compiler, and routing changes.
- [ ] Gates (byte-identity is the critical one here: the daily compile path must be untouched). Commit `feat: bars declaration and session series`.

## Task 3: intraday engine

**Files:** create intraday/dune (`(library (name intraday) (wrapped false) (libraries data engine))`), intraday/intraday.ml, intraday/intraday.mli; modify test/dune (add `intraday` to libraries), test/test_bt.ml.

**Consumes:** `Data.session`, `Data.bar`, `Data.resample` (Task 1); `Engine.costs`, `Engine.default_costs`, and the existing charge/per-share helpers exported by engine.mli (read the .mli; do not add exports).

**Produces (consumed by Task 4):**
- `type Intraday.config = { fill : Engine.fill_mode; leverage : float; costs : Engine.costs; capital : float option }`.
- `type Intraday.fill = { time : string; price : float; from_exposure : float; to_exposure : float }`.
- `type Intraday.result = { session_dates : string array; equity : float array; fills : fill list; trades : int; wins : int; flat_forced : int }` (equity has one entry per session close; `trades` counts round trips closed within a session; `wins` counts round trips with positive net P&L after costs; `flat_forced` counts sessions whose last bar liquidated a nonzero position).
- `val Intraday.run : config -> sessions:Data.session array -> bars:Data.bar array -> targets:float array -> initial_equity:float -> result`. Semantics exactly per the spec Engine semantics section: NaN -> 0; negative -> `failwith "short targets are reserved"`; cap at `leverage`; position value <= `leverage x previous-close equity` (first session: `initial_equity`); `Open_next` fills bar i's decision at bar i+1's open within the session, `Close_same` at bar i's close; the last bar's decision is ignored; the last bar forces the position to zero at its close; cash carries across sessions; costs on every fill including the forced flat; sizing in exposure units unless `capital` is Some, then whole shares and per-share fees as `bt run` does.

- [ ] RED, one assertion group per behavior with hand-derived numbers on a two-session synthetic series (session 1: five 5m bars, session 2: three bars with an early close): open-vs-close latency on a two-bar move (exact equity difference derived by hand); last-bar decision ignored (a target set on the final bar produces no fill); forced flat (a nonzero position at the last bar yields a fill at that bar's close with `to_exposure = 0` and `flat_forced = 1`); leverage cap anchored to previous-close equity (target 2.0 with leverage 2.0 and a mid-session gain: position value stays at 2 x previous close equity, not 2 x current); negative target raises the exact message; NaN target treated as 0; costs applied on the forced flat (equity reflects the fee); `trades` and `wins` counts on a known win and a known loss.
- [ ] Run: expected FAIL, `Intraday` unbound. Record.
- [ ] GREEN: implement the session loop functionally (fold over sessions, fold over bars, no refs).
- [ ] Gates. Commit `feat: intraday session engine`.

## Task 4: bt daytrade, outputs, docs, smoke

**Files:** modify bin/bt.ml, bin/dune (add `intraday`), report/report.ml, report/report.mli (additive: an intraday report line and the `time,...` fill-log writer), docs/cli.md, docs/strategy.md, docs/engine.md, CHANGELOG.md, test/test_bt.ml; create examples/daytrade_orb.strat (a minimal `bars 5m` opening-range-breakout example used by the smoke and the docs).

**Consumes:** everything above.

- [ ] RED: CLI tests - `bt daytrade` on a strategy without `bars` fails with `bt daytrade requires a bars declaration`; on a tw strategy with `day trading supports us only`; on an aliased multi-stock file with `day trading strategies declare exactly one stock`; `--financing-rate` (and the other three daily margin flags) rejected as usage errors; `--fill` default resolves to `open` (assert via a two-bar fixture run through the CLI that the fill lands at the next open). Report test: the intraday line contains `sessions`, `trades`, `win rate`, `flat-forced`; the trades CSV header is exactly `time,stock,price,from_exposure,to_exposure`.
- [ ] Run: expected FAIL. Record.
- [ ] GREEN: `bt daytrade` parses the flags listed in the spec Command surface, loads the strategy, reads the calendar and minute bars from `--data-dir`, resamples to the declared timeframe, computes `since_open`/`to_close` from the calendar, compiles with `extra`, runs `Intraday.run`, writes `<name>.csv` (per-session equity, same shape as `bt run`) and `<name>.trades.csv`, prints the table via `Metrics`/`Report` on the session equity plus the intraday line, supports `--baseline us/SYM` via the daily buy-and-hold over the same date span, and calls the plot script unless `--no-plot`.
- [ ] Docs: cli.md `bt daytrade` section (subsections: options table with Default column, data requirements, output fields, rejected flags) and the `--bars` row under `bt fetch` options; strategy.md `bars` declaration and the two session series; engine.md new `## Intraday engine` section with `### Sessions and fills`, `### Leverage cap`, `### Gap between simulation and the real market` (no shorts, no day-trade calls or broker liquidation, regular hours only, $25k rule, minute-bar fill realism and the open-vs-close sensitivity); CHANGELOG `[Unreleased]` Added entries; ToCs regenerated for all three docs.
- [ ] Gates. Commit `feat: bt daytrade` then `docs: day trading`.
- [ ] Smoke (network, blessed binary, keys from the environment): `bt fetch us/SPY --bars 1m --data-dir /sandbox/stock-daytrading/data` for at least the current year (record row counts and the calendar's last date); copy `/sandbox/stock/data/us/SPY` daily files into the worktree data dir for the baseline; run `bt daytrade examples/daytrade_orb.strat --baseline us/SPY --data-dir /sandbox/stock-daytrading/data --from <this year>`; hand-check one session's fills in the trades CSV against the minute cache (opening range, breakout bar, next-open fill, forced flat at the last bar). Record in the report. If keys or egress are unavailable, record the exact commands and mark deferred; never fake output.

## Reviews

Reviewer agent dispatched by the coordinator after each task (diff against the task's base; spec compliance plus code quality with file:line evidence); fix waves re-gate and re-review before the next task starts. Final whole-branch review after Task 4.
