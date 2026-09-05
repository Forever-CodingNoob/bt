# Library Split Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans to implement this plan. Implementers use executing-plans only and never run review loops themselves. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Execute docs/specs/library-split.md: replace flat `lib/` + wrapped `btlib` with seven unwrapped per-concern dune libraries, zero behavior change.

## Global constraints

- The spec is binding: layout table, `(wrapped false)` rule, source-edit budget (ONLY `Btlib.` prefix deletions in bin/bt.ml and test/test_bt.ml), `git mv` for all moves.
- No subagents: never dispatch a reviewer or any other agent; the coordinator owns reviews.
- `bt fetch` and `bt run` behavior stays frozen (concurrent backtest study); the byte-identity gate is the proof.
- Git: one commit `refactor: split lib into per-concern libraries`, NEVER push, no git settings, no author override; trailer `Co-authored-by: ChatGPT <noreply@openai.com>`.
- Report to /sandbox/stock/.superpowers/sdd/library-split/task-1-report.md with per-gate evidence.

## Task 1: the split

**Files:** every `lib/*` file moves per the spec layout table; create `lang/dune`, `series/dune`, `data/dune`, `engine/dune`, `metrics/dune`, `report/dune`, `broker/dune`; delete `lib/dune`; modify `bin/dune`, `test/dune`, `bin/bt.ml`, `test/test_bt.ml` (prefix deletions only), `CONTRIBUTING.md` (module layout section paths).

- [ ] Confirm the standing TW reference `/tmp/live-ref` + `/tmp/live-ref.txt` exists; if missing, capture it at HEAD before any change (command in CONTRIBUTING's test conventions; strat: /sandbox/research/strategies/tw/channel_ladder/main.strat --baseline tw/00685L --data-dir data).
- [ ] `git mv` each file to its spec directory (lang: ast.ml ast.mli lexer.mll parser.mly dsl.ml dsl.mli; series, data, engine, metrics, report pairs; broker: alpaca and live pairs).
- [ ] Write the seven dune files: `(library (name <dir>) (wrapped false) (libraries <minimal deps>))`; move `(ocamllex lexer)` and `(ocamlyacc parser)` stanzas into lang/dune; let the compiler dictate the `(libraries ...)` edges - start from the spec's indicative DAG, add only what unbound-module errors demand, remove any edge the build does not require (verify by removing and rebuilding).
- [ ] `bin/dune` and `test/dune`: replace `(libraries btlib)` with the needed library names; keep test deps list (adjust relative paths only if dune errors demand).
- [ ] Delete every `Btlib.` prefix occurrence in bin/bt.ml and test/test_bt.ml (mechanical; zero other source lines change - `git diff --stat` must show only the two files beyond moves and dune files).
- [ ] `opam exec -- dune build --root .` clean; `opam exec -- dune runtest --force` exit 0 with `ok` (sentinel included).
- [ ] TW byte-identity: run the reference command to a fresh out-dir; `diff -r` files and `diff` stdout vs /tmp/live-ref{,.txt}; both empty.
- [ ] Copy the rebuilt binary to the next fresh `bt-test<n+1>.exe` (`cp _build/default/bin/bt.exe bt-test<n+1>.exe && chmod +x`); run `./bt-test<n+1>.exe --help` (or bare usage) and confirm all four subcommands print.
- [ ] CONTRIBUTING.md: rewrite the Module layout block to the new directories (keep the one-line descriptions), and confirm no other CONTRIBUTING section references `lib/` paths (fix any that do).
- [ ] Commit with the exact message and trailer; confirm clean tree; write the report.
