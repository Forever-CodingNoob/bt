# Design: directory-per-concern library split

Date: 2026-09-05
Status: approved

## Goal

Replace the flat `lib/` + single `btlib` library with cryptoline-style per-concern directories, each its own dune library with explicit dependencies (reference: github.com/fmlab-iis/cryptoline, one directory per concern, executables linking the libraries). Zero behavior change, provable by the existing gates.

## Layout

```
lang/      ast.ml ast.mli lexer.mll parser.mly dsl.ml dsl.mli   strategy language
series/    series.ml series.mli                                 indicators
data/      data.ml data.mli                                     fetch, cache, adjustment
engine/    engine.ml engine.mli                                 portfolio simulation
metrics/   metrics.ml metrics.mli                               performance statistics
report/    report.ml report.mli                                 tables, CSV, plots
broker/    alpaca.ml alpaca.mli live.ml live.mli                Alpaca client and live daemon
bin/       bt.ml                                                unchanged location
test/      test_bt.ml, fixtures/                                unchanged location
```

## Dune rules

- Each directory is `(library (name <dir>) (wrapped false))` so module names stay `Ast`, `Dsl`, `Data`, `Series`, `Engine`, `Metrics`, `Report`, `Alpaca`, `Live` - intra-library references in moved files stay byte-identical.
- The `(ocamllex lexer)` and `(ocamlyacc parser)` stanzas move into `lang/dune`.
- Each library declares the minimal `(libraries ...)` it needs; the compiler is the authority on the edges. Indicative DAG from current references: `series` and `metrics` and `data` depend only on `unix`/stdlib; `engine` on `data`; `lang` on `series` plus whatever the compiler demands; `report` on `data engine metrics`; `broker` on `data engine lang`; `bin` and `test` link all seven.
- `bin/dune` and `test/dune` replace `(libraries btlib)` with the seven library names; test `deps` (fixtures, example strats, plot script) stay as they are, paths adjusted only if dune requires.

## Source-edit budget

The ONLY source edits are mechanical `Btlib.` prefix deletions in `bin/bt.ml` and `test/test_bt.ml` (the flat library was wrapped; the new libraries are not). No other `.ml`/`.mli` line changes anywhere. Moves use `git mv` so history follows renames.

## Verification

- `dune build --root .` clean (warnings are errors).
- Full suite green; sentinel `test_engine_buyhold_costs` bit-for-bit.
- TW byte-identity: channel_ladder vs the standing reference capture, stdout and files.
- `git show --stat` of the move commit shows renames plus dune files plus the two prefix-edit files, nothing else.
- A fresh `cp _build/default/bin/bt.exe bt-test<n+1>.exe` still runs `fetch`/`target` (binary layout is unaffected by library structure, confirm by running `--help`).

## Non-goals

- No module renames, no wrapped namespacing, no `public_name`/opam packaging, no code refactoring inside any module, no CHANGELOG entry (build structure is not user-visible behavior; CONTRIBUTING.md module layout section IS updated to the new paths in the same commit).
