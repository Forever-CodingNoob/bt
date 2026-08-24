# Design: functional-style refactor of lib/

Date: 2026-08-23
Status: approved

## Goal

Rewrite the six hand-written modules in `lib/` (`series.ml`, `metrics.ml`, `dsl.ml`, `data.ml`, `report.ml`, `engine.ml`) in a functional style with no `for` or `while` loops, and add interface files for every hand-written module. Program semantics must not change: the full test suite stays green and the smoke artifacts stay byte-identical.

## Scope

- In scope: `lib/*.ml` rewrites, new `lib/*.mli` files (`ast.mli`, `data.mli`, `dsl.mli`, `engine.mli`, `metrics.mli`, `report.mli`, `series.mli`).
- Out of scope: `bin/`, `test/`, `lexer.mll`, `parser.mly` (the generators produce their own interfaces), any behavior change, any dependency change.

## Rewrite rules

1. No `for` and no `while`. Elementwise, order-pure array fills use `Array.init`, `Array.map`, or `Array.map2`. A fill whose function reads or writes shared state uses a tail-recursive helper or `Array.fold_left_map`, because OCaml does not specify the evaluation order of `Array.init`.
2. Accumulator refs become `Array.fold_left` or `List.fold_left` with the accumulator threaded in the same index order as the removed loop. Floating-point operation order must not change: no reassociation, no reordering.
3. Every recursive helper is tail-recursive. Every algorithm keeps its current complexity; the incremental rolling-window algorithms in `series.ml` stay O(n).
4. Use `|>` pipelines where a value flows through stages. Do not force a pipeline where a plain `let` is clearer.
5. Local mutation stays only where the algorithm needs it (for example the rolling-extremum deque buffer), wrapped so the enclosing function stays externally pure.
6. Imperative sequencing uses `let () = e1 in e2` instead of `e1; e2`, everywhere in the refactored modules, including inside lambda bodies. The final expression of a sequence stays bare. Retire `begin ... end` blocks that existed only for `;` sequencing.

## Per-module treatment

- `series.ml`: rolling sum and missing-count machinery, EMA seeding, RSI, and ATR become tail-recursive scans that carry state as parameters. The monotonic deque for rolling extrema keeps its int-array buffer; its inner `while` shrink and outer walk become tail-recursive functions. `lag`, `cross_above`, `cross_below`, and `zip` become `Array.init` (order-pure).
- `metrics.ml`: returns via `Array.init`; mean and variance via `fold_left` in the original order.
- `dsl.ml`: the elementwise map and compare sites become `Array.init` or `Array.map2`. The `hold` and exposure scans become tail-recursive or `fold_left_map`. The bars-to-columns splitter builds each column with its own `Array.map` over bars.
- `data.ml`: symbol validation via `String.exists`. The `while true` plus `End_of_file` line readers become tail-recursive readers that return accumulated lists. The backward dividend-factor walk becomes a tail-recursive descent carrying the factor. The two backward filter loops become `Array.to_list |> List.filter |> Array.of_list`, which preserves element order and predicate calls.
- `report.ml`: the alignment assertion uses `Array.iter` and `Array.iteri`. CSV emission uses `Array.iter` in row order so the output byte sequence is unchanged.
- `engine.ml`: private tail-recursive `iter_assets : (int -> unit) -> unit` and `fold_assets` helpers replace the per-asset loops. The waterfall's bounded round loop with early exit becomes a tail-recursive function with an explicit remaining-rounds parameter. The E1 iteration and the bar walk stay as they are. The order of side effects inside every former loop body is preserved statement for statement.

## Interface files

Exports are derived from observed usage in `bin/bt.ml`, `test/test_bt.ml`, and cross-module references inside `lib/`. Nothing is exported speculatively. Every record or variant type read across a module boundary stays concrete in the `.mli` (`Data.bar`, `Engine.result`, `Engine.margin_stats`, `Engine.costs`, `Engine.fill`, `Engine.fill_event`, `Engine.trip`, `Engine.margin`, and any others the usage scan finds). `ast.mli` restates the AST type definitions. Each export carries a one-line doc comment. New helpers from the loop rewrite stay private by omission from the `.mli`. Each `.mli` lands in the same commit as its module's rewrite.

## Verification

Before any change: full suite green at the base commit, then golden artifacts captured once from the smoke run (`bt run` of `/sandbox/research/strategies/channel_ladder.strat` with `--baseline tw/00685L`): stdout table, equity CSV, trades CSV.

After each module commit: `dune build` (type-checks the new `.mli` against all callers), `dune runtest --force` green, smoke rerun, `cmp` byte-identical CSVs, identical stdout table. Any divergence stops work at that module. Wall time is compared against the golden run to catch complexity regressions.

## Execution

Six tasks in order: `series`, `metrics`, `dsl`, `data`, `report`, `engine`. One commit per module, message `refactor: functional style for lib/<module>`, with the implementing model's co-author trailer. One implementer executes the plan task by task with the gate after each. A scoped code review follows the `engine` task; the standard final whole-branch review follows the last task.
