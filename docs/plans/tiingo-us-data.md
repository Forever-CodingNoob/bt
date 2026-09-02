# Tiingo US Data Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Execute docs/specs/tiingo-us-data.md: Tiingo replaces FinMind for US data, `data/us/` adopts the canonical TW cache layout, one two-plane loader serves both markets, and all US derivation heuristics are deleted.

## Global constraints

- The spec is binding, including the splitFactor snap rule and the raw-price basis it records.
- lib/ style: no for/while loops, `let () = e in` sequencing, tail-recursive helpers, no float reassociation in untouched arithmetic. Update lib/data.mli. Derivation comments on every new test expectation. Sentinel `test_engine_buyhold_costs` bit-for-bit.
- Git: commits only, NEVER push; NEVER touch git settings (`remote`, `config`); Claude co-author trailer `Co-Authored-By: Claude <noreply@anthropic.com>`.
- Binary convention: after building, bless a fresh gated binary with `touch bt-test<n>.exe` (cp is denied; touch materializes a frozen snapshot of the current build). Reference binary `bt-test22.exe` is already blessed at the spec commit (pre-change behavior). Next free n is 23. Never fetch from `_build/` paths.
- `TIINGO_TOKEN` comes from the environment (`~/.bashrc`); never print it; pass it to curl via a 0600 header file like the FinMind token.
- CHANGELOG.md is tracked: add the `[Unreleased]` entries in the docs step.
- Report: /sandbox/stock/.superpowers/sdd/tiingo-us/report.md (create the directory).

## Task steps

- [ ] **Step 0: preserve the before state.** Copy the current `data/us/` to `/tmp/us-old-cache/`. Run the SPY before table with the reference binary and the old cache: `./bt-test22.exe run <temp SPY buy-and-hold strat> --baseline us/SPY --data-dir data --out-dir /tmp/spy-before --out-name spy --no-plot`, saving stdout. The temp strat is `stock "us/SPY"` with `target 1.0` written under /tmp.
- [ ] **Step 1: fetcher.** Implement the Tiingo fetch in lib/data.ml per the spec: endpoint with `format=csv`, `Authorization: Token` header from `TIINGO_TOKEN`, hard error when unset; parse the verified column set; emit the four canonical files (raw OHLCV without adj_close; events.csv `1/splitFactor` with the p/q<=50, 1e-4 snap; cashdiv.csv with empty pay_date; div.csv `(prev_close - divCash)/prev_close`); adopt the TW incremental append and head-gap machinery for the prices file; keep-cached-on-failure for all four. Delete the FinMind USStockPrice path. Commit `feat: Tiingo US fetcher with canonical cache format`.
- [ ] **Step 2: unified loader.** Delete `read_us_planes` and every close/adjClose heuristic; route both markets through one two-plane construction (signal = raw x div x event factors; money = raw x event factors; volume restated by inverse event factors in both planes; dividend events from cashdiv.csv; pay-date rule: TW real-or-plus-one-month, US ex-date). Update lib/data.mli and delete obsolete exports. Commit `feat: unified two-plane loader for both markets`.
- [ ] **Step 3: tests.** Transform fixtures: splitFactor snap (7.000007000007001 to 1/7), divCash to cashdiv and div factor arithmetic, AAPL-2020-shaped split, dividend-and-split combined. Loader parity fixture: hand-built US planes equal loader output. Delete or re-derive the old US heuristic tests with comments. Gate: `opam exec -- dune build && opam exec -- dune runtest --force` prints ok. Commit `test: Tiingo transform and loader parity fixtures`.
- [ ] **Step 4: live cutover.** Build; bless `bt-test23.exe` via touch. Delete the old `data/us/*.csv`. Run `./bt-test23.exe fetch us/SPY` live: all four files appear; re-run the same fetch: incremental no-op (idempotent). Run the SPY after table with the new binary and cache into /tmp/spy-after. Record both tables and the delta with one interpretation paragraph in the report.
- [ ] **Step 5: TW regression gate.** 00685L smoke byte-identical between `bt-test22.exe` and `bt-test23.exe` on the same data (`run /sandbox/research/strategies/channel_ladder/main.strat --baseline tw/00685L --data-dir data --out-dir <dir> --out-name fp --no-plot`); STOP if any byte differs.
- [ ] **Step 6: docs and changelog.** engine.md US section (Tiingo source, authoritative events, raw basis), cli.md fetch page and defaults table, README data notes; regenerate ToCs for touched files (full depth); CHANGELOG `[Unreleased]`: Added (Tiingo US source), Changed (US cache format, incremental US fetch), Removed (FinMind US path and derivation heuristics). Commit `docs: Tiingo US data source`.

## Verification (coordinator repeats independently)

Suite green from clean; TW byte-identity; four-file SPY cache present with sane spot values; idempotent refetch; SPY before/after tables in the report.
