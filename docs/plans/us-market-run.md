# US Market Run Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Execute docs/specs/us-market-run.md: single-market runs, one market profile, and the six Alpaca-verified US behaviors, with maximal reuse of the shared engine path.

## Global constraints

- The spec is binding, including the Simplicity and reuse section: forks only as variant matches inside shared functions; no parallel US copies.
- Strict TDD per behavior: failing test first with recorded red output in the report, then minimal code, then green with the full suite.
- lib/ style per CONTRIBUTING.md and AGENTS.md (match on market/profile, no if-else on markets). Update the relevant `.mli` files. Sentinel `test_engine_buyhold_costs` bit-for-bit.
- TW byte-identity gate after EVERY task: `_build/default/bin/bt.exe run /sandbox/research/strategies/channel_ladder/main.strat --baseline tw/00685L --data-dir data --out-dir <dir> --out-name fp --no-plot` byte-identical to the pre-plan capture (stdout and files; capture once before Task 1).
- After each task's commit, the coordinator dispatches a reviewer agent per the spec's Execution section; fix waves re-review before the next task starts.
- Git: commits only, NEVER push, NEVER touch git settings; trailer `Co-Authored-By: Claude <noreply@anthropic.com>`.
- Report per task: /sandbox/stock/.superpowers/sdd/us-market-run/task-<n>-report.md with red/green evidence.

## Task 1: market profile and single-market validation

**Files:** lib/engine.ml, lib/engine.mli, bin/bt.ml, test/test_bt.ml.

- [ ] RED: tests for `profile_of_market` values (tw: 365./2/Collateral_over_loan/6.35; us: 360./1/Equity_over_required/6.25; invalid market fails), and a CLI-level mixed-market rejection check (two strats tw+us, and tw strat with us baseline, both usage errors; levered or not).
- [ ] GREEN: `maintenance_model` and `market_profile` types plus `profile_of_market` (the only market match in the run path); `Engine.run` takes the profile; bt.ml validates one market across strats plus baseline, resolves optional `--financing-rate`/`--maintenance-ratio` against the profile, passes the profile through. TW arms carry today's constants; engine consumes `profile.interest_day_count` and `profile.settlement_lag` where 365./2 are hardcoded today.
- [ ] Gate: suite ok; TW byte-identity. Commit `feat: market profile and single-market runs`.

## Task 2: US interest, settlement, and Alpaca costs

**Files:** lib/engine.ml, lib/engine.mli, bin/bt.ml, test/test_bt.ml.

- [ ] RED: weekend-interest fixture asserting /360 for us and /365 for tw on the same bars; T+1 window arithmetic fixture (interest starts one bar after origination for us); SEC-fee sell test (tax_bps 0.206 default for us); TAF tests under `--capital`: per-share charge rounded up to the cent, $0.01 floor, $9.79 cap, inactive without capital, zero for tw.
- [ ] GREEN: day count and lag from the profile; `costs` record gains `per_share_sell_fee` and `per_share_sell_cap`; `default_costs` us arm: fee 0, tax_bps 0.206, TAF fields; charge path applies the per-share fee on sells when capital is present; CLI flags `--per-share-fee`/`--per-share-cap` override.
- [ ] Gate: suite ok; TW byte-identity. Commit `feat: Alpaca interest, settlement, and cost defaults`.

## Task 3: US maintenance, cure, docs, and smoke

**Files:** lib/engine.ml, lib/engine.mli, test/test_bt.ml, docs/engine.md, docs/cli.md, README.md, CHANGELOG.md (edit only).

- [ ] RED: tiered required-margin fixtures (one position in each band: <2.50 at 100%, 2.50-6.00 at 50%, >6.00 at 30%); breach detection at close; minimum-cure sizing fixture with hand-derived arithmetic (sell exactly enough that equity >= required after costs, positions survive); flat `--maintenance-ratio` override replacing the table; TW maintenance untouched (existing tests stay green unmodified).
- [ ] GREEN: `Equity_over_required` arm in the maintenance check and the call machinery (shared scheduling, variant-matched action: TW full margin liquidation vs US minimum cure), reusing the existing sell/repay primitives.
- [ ] Docs: engine.md US Margin financing and Gap sections rewritten to the modeled reality with dated rates; cli.md defaults table per-market resolution plus the two new flags; README touch only if it names US margin; CHANGELOG `[Unreleased]` entries; ToCs regenerated for touched files.
- [ ] Gate: suite ok; TW byte-identity; SPY margin smoke (temp strat `stock "us/SPY"` target 1.5, `--capital 10000`) before/after recorded with interpretation in the report.
- [ ] Commit `feat: US tiered maintenance with minimum cure` then `docs: US market run`.

## Reviews

Reviewer agent after each task (spec Execution section); final whole-branch review after Task 3; fix waves re-gate and re-review.
