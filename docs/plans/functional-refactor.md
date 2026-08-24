# Functional-Style Refactor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rewrite the six hand-written `lib/` modules with no `for`/`while` loops per the spec (docs/specs/functional-refactor.md), add seven `.mli` files, and prove semantics are unchanged with a byte-identical golden-artifact gate after every module.

## Global constraints

- The spec's six rewrite rules are binding. Rule 2 (floating-point operation order unchanged) and rule 6 (`let () = e1 in e2` sequencing) apply to every touched line.
- `bin/`, `test/`, `lexer.mll`, `parser.mly`, and all behavior are out of scope. CHANGELOG.md stays untracked and unstaged.
- After every module: full gate (below) before the commit. On any gate failure: stop, fix within the module, re-gate; never proceed with a red gate.
- Commit messages: `refactor: functional style for lib/<module>` with trailer `Co-authored-by: ChatGPT <noreply@openai.com>`. One commit per module; the module's `.mli` is in the same commit. `ast.mli` rides with the first task's commit.
- If a rewrite cannot preserve exact float order at some site, STOP and ask; do not approximate.

## Gate (run after every module, before its commit)

```bash
opam exec -- dune build 2>/dev/null && opam exec -- dune runtest --force 2>/dev/null; echo "exit=$?"
cp _build/default/bin/bt.exe /tmp/fp-current.exe
/tmp/fp-current.exe run /sandbox/research/strategies/channel_ladder.strat --baseline tw/00685L --data-dir data --out-dir /tmp/fp-check --out-name fp --no-plot > /tmp/fp-check-stdout.txt 2>&1; echo "smoke=$?"
diff -r /tmp/fp-golden /tmp/fp-check && diff /tmp/fp-golden-stdout.txt /tmp/fp-check-stdout.txt && echo IDENTICAL
rm -rf /tmp/fp-check /tmp/fp-check-stdout.txt
```

`IDENTICAL` is required. Also compare smoke wall time (`time` the run) against the golden run; more than 2x slower fails the gate as a complexity regression.

## Task 0: Golden capture (no commit)

- [ ] **Step 1:** Verify clean base: `git status --short` shows only `?? CHANGELOG.md`; `opam exec -- dune build && opam exec -- dune runtest --force` exits 0.
- [ ] **Step 2:** Build and capture golden artifacts:

```bash
cp _build/default/bin/bt.exe /tmp/fp-golden.exe
/tmp/fp-golden.exe run /sandbox/research/strategies/channel_ladder.strat --baseline tw/00685L --data-dir data --out-dir /tmp/fp-golden --out-name fp --no-plot > /tmp/fp-golden-stdout.txt 2>&1
```

- [ ] **Step 3:** Record in the report which files the run produced (`ls /tmp/fp-golden`) and the wall time.

## Task 1: series.ml (+ series.mli, ast.mli)

- [ ] **Step 1:** Rewrite every loop site per the spec's series treatment: tail-recursive scans for rolling sum/missing-count, EMA seeding, RSI, ATR; deque keeps its buffer with tail-recursive shrink/walk; `lag`/`cross_above`/`cross_below`/`zip` via `Array.init`. Apply rule 6 sequencing throughout the file.
- [ ] **Step 2:** Write `series.mli` (exports = usage scan of test/, bin/, lib/ cross-references) and `ast.mli` (restate AST types).
- [ ] **Step 3:** Gate. **Step 4:** Commit `refactor: functional style for lib/series`.

## Task 2: metrics.ml (+ metrics.mli)

- [ ] **Step 1:** Returns via `Array.init`; mean/variance via `fold_left` in original order; rule 6 throughout.
- [ ] **Step 2:** `metrics.mli`. **Step 3:** Gate. **Step 4:** Commit.

## Task 3: dsl.ml (+ dsl.mli)

- [ ] **Step 1:** Elementwise sites via `Array.init`/`Array.map2`; `hold` and exposure scans via tail recursion or `fold_left_map`; bars-to-columns via per-column `Array.map`; rule 6 throughout.
- [ ] **Step 2:** `dsl.mli`. **Step 3:** Gate. **Step 4:** Commit.

## Task 4: data.ml (+ data.mli)

- [ ] **Step 1:** `String.exists` validation; tail-recursive line readers replacing `while true`/`End_of_file`; tail-recursive backward dividend-factor descent; filters via `Array.to_list |> List.filter |> Array.of_list`; rule 6 throughout.
- [ ] **Step 2:** `data.mli`. **Step 3:** Gate (also rerun a fetch-free path only; no network). **Step 4:** Commit.

## Task 5: report.ml (+ report.mli)

- [ ] **Step 1:** Alignment assertion via `Array.iter`/`Array.iteri`; CSV emission via `Array.iter` in row order; rule 6 throughout.
- [ ] **Step 2:** `report.mli`. **Step 3:** Gate. **Step 4:** Commit.

## Task 6: engine.ml (+ engine.mli)

- [ ] **Step 1:** Add private tail-recursive `iter_assets`/`fold_assets`; replace every per-asset loop preserving statement order; waterfall rounds as tail recursion with explicit remaining-rounds; E1 iteration and bar walk unchanged; rule 6 throughout.
- [ ] **Step 2:** `engine.mli` (concrete record/variant types per the spec). **Step 3:** Gate. **Step 4:** Commit.

## Reviews

- Scoped code review after Task 6 (engine diff), then the final whole-branch review of all commits. Fix waves re-gate with the same golden artifacts.
