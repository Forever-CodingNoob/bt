# Dividend Cash Accounting Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement docs/specs/dividend-cash-accounting.md: real-price money ledger, dividend receivables, TW pay-date forced loan paydown, US ex-date cash, re-fill on cash arrival, `--dividend-tax` (default 0).

## Global constraints

- The spec is binding. lib/ style: no for/while loops, `let () = e in` sequencing, tail-recursive helpers, no float reassociation in untouched arithmetic. One space around `=`. No hard-wrapped mid-sentence newlines in docs.
- Every new or changed test expectation carries a derivation comment. Sentinel `test_engine_buyhold_costs` stays bit-for-bit. CHANGELOG.md: edit text, never `git add`. Update lib/*.mli for signature changes.
- Binary convention: the sandbox gates FinMind egress by executable hash, so every rebuilt binary that must fetch or be smoke-tested is copied to a FRESH repo-root name `bt-test<n>.exe` (gitignored); if a copy's FinMind requests are blocked, copy again to `bt-test<n+1>.exe` and use that. Never run network operations from `_build/` paths directly.
- Regression gate after Tasks 2 and 3: 00685L smoke byte-identical against the pre-change reference `bt-test12.exe` (built at the plan commit; no cash dividends, so the money series equals today's series). Smoke: `./bt-test<n>.exe run /sandbox/research/strategies/channel_ladder/main.strat --baseline tw/00685L --data-dir data --out-dir <dir> --out-name fp --no-plot`.
- Commits carry `Co-authored-by: ChatGPT <noreply@openai.com>`. Reports under .superpowers/sdd/dividend-cash/ (untracked).
- If any subagent dispatch fails with usage_limit_reached, the coordinator pauses the task and waits for credit restoration (standing user rule); no inline fallback, no agent substitution.

## Task 1: data layer

**Files:** lib/data.ml, lib/data.mli, test/test_bt.ml.

- [ ] **Step 1: TW cash-dividend cache.** New fetch into `data/tw/<symbol>.cashdiv.csv`, header `ex_date,cash_per_share,pay_date`, from FinMind `TaiwanStockDividend`: ex_date from the cash ex-dividend trading date field, cash_per_share as the sum of the cash distribution components, pay_date from the cash payment date field; skip rows with zero cash; keep-cached-on-failure policy like the other fetches. Exercise the fetch through a fresh `bt-test<n>.exe` copy per the binary convention (start at `bt-test13.exe`). TIER FALLBACK: if the table returns HTTP 400/402/403 on the free tier, derive rows from the existing factor cache instead: cash_per_share = (1 - factor) * previous raw close at the ex-date, pay_date empty; print one warning naming the derivation. Loader fallback for a missing pay_date: ex_date plus one calendar month.
- [ ] **Step 2: two price planes.** `Data.load` returns money-series bars (event factors only) alongside signal-series bars (event plus dividend factors, exactly today's output) and dated dividend cash events per asset. TW events from the cashdiv cache; US events derived per day from `close`/`adj_close` ratio changes (cache already holds both columns), credited at ex_date; US pay_date = ex_date. Volume split adjustment applies to both planes unchanged.
- [ ] **Step 3: tests.** Fixture-based: TW cashdiv parse with and without pay_date (fallback + one-month arithmetic across year end); the tier-fallback derivation; US derivation from a synthetic close/adj_close fixture (one dividend: correct date and amount, no event on non-dividend days); signal series byte-identical to today's load for a dividend fixture; money series shows the ex-date drop.
- [ ] **Step 4: verification and commit.** Suite green. Commit `feat: dividend data layer with two price planes`.

## Task 2: engine and CLI

**Files:** lib/engine.ml, lib/engine.mli, bin/bt.ml, test/test_bt.ml.

- [ ] **Step 1: interface.** `Engine.run` takes per-asset dividend events (ex_date, cash_per_share, pay_date) with the money-series bars; margin record unchanged; new run parameter `dividend_tax : float` (fraction). bin/bt.ml: `--dividend-tax PCT` default 0, wires signal bars to the DSL and money bars plus events to the engine and baseline.
- [ ] **Step 2: receivables.** On a TW ex-date bar: shares = inventory value / money price per inventory; book cash-side and margin-side receivables net of tax; equity includes receivables; maintenance excludes them. US: credit the whole net dividend to cash on the ex-date bar (no receivable).
- [ ] **Step 3: pay date.** On the first bar with date >= pay_date: cash-side receivable to account cash; margin-side receivable repays that asset's lots pro-rata with matching accrued-interest settlement (existing proportional convention); excess above loan plus interest spills to cash. Frozen (bankrupt) accounts still convert receivables; the cash reduces residual debt.
- [ ] **Step 4: re-fill trigger.** Any bar where dividend cash lands (TW pay, US ex) marks the run for one normal fill pass toward current targets for all assets at that bar's fill price, normal costs, drift semantics otherwise untouched. Rollover/term machinery unaffected.
- [ ] **Step 5: tests with derivations.** (a) receivable in equity but not maintenance between ex and pay (maintenance dips); (b) TW pay-date paydown incl. matching interest settlement; (c) excess spill when dividend > remaining loan + interest; (d) US ex-date credit with re-fill paying costs; (e) tax fraction reduces the credit; (f) frozen-account receivable reduces debt; (g) no-dividend fixture byte-identical behavior (equity curve equal to a run without the events parameter).
- [ ] **Step 6: gates and commit.** Suite green; 00685L smoke byte-identical vs `bt-test12.exe`, run through a fresh `bt-test<n>.exe` copy. Commit `feat: dividend receivables, TW loan paydown, re-fill trigger`.

## Task 3: docs and comparison

**Files:** README.md, docs/cli.md, docs/strategy.md, CHANGELOG.md (edit only).

- [ ] **Step 1: docs.** Dividend lifecycle in the margin/strategy docs; `--dividend-tax` in the CLI table; disclosures: pay-date fallback, US zero-lag, ex-dividend trip statistics, tier fallback if active.
- [ ] **Step 2: 0050 comparison.** Run 0050 buy-and-hold before (`bt-test12.exe`) and after (fresh `bt-test<n>.exe`); record both tables and the delta in the report with a one-paragraph interpretation.
- [ ] **Step 3: gates and commit.** Suite green; 00685L smoke byte-identical. Commit `docs: dividend cash accounting`.

## Reviews

Scoped review after Task 2 (highest risk), final whole-branch review after Task 3; fix waves re-gate the same way.
