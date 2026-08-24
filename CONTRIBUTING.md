# Contributing

## Layout

```
bin/bt.ml        CLI dispatch: fetch | run
lib/data.ml      FinMind fetch, CSV cache, dividend and corporate-action adjustment
lib/series.ml    Indicators on float arrays
lib/ast.ml       Strategy AST types
lib/lexer.mll    Lexer (ocamllex)
lib/parser.mly   Grammar (ocamlyacc)
lib/dsl.ml       Evaluator; compiles a script to Engine.strategy
lib/engine.ml    Portfolio engine (per-asset targets, costs, and two-inventory margin accounting)
lib/metrics.ml   CAGR, Sharpe, MaxDD, Calmar, trade statistics
lib/report.ml    Terminal table, CSV output, PNG plot
test/test_bt.ml  Assert-based tests (dune test)
test/fixtures/   Synthetic CSV data for tests
examples/        Strategy examples
scripts/plot.py  Equity graph renderer (run directly by bt)
docs/cli.md      Complete CLI reference
docs/strategy.md Strategy language reference (styles, grammar, builtins)
docs/specs/      Design specs; docs/plans/ implementation plans
```

## Build and test

First create the project-local opam switch; see "Build and test" in
README.md. All commands below assume `eval $(opam env)` ran in this
directory.

```sh
dune build     # must be clean; warnings are errors
dune test      # all asserts must pass
```

## Rules

- Use the OCaml standard library and `unix` only. Do not add opam
  package dependencies.
- Network and JSON work goes through `curl` and `jq` as subprocesses.
  Do not parse JSON in OCaml.
- Make list recursion tail-recursive. Use an accumulator and
  `List.rev`. Use `Array` index loops for series math.
- A numeric series is a `float array`. Warmup values are `Float.nan`.
  A comparison with NaN gives `false`.
- Put one space on each side of `=`. Do not align code with extra
  spaces.
- Do not embed Python (or other foreign code) in `.ml` files. Python
  scripts are standalone files in `scripts/`.

## Fixed contracts

Do not change these types or formats:

- `Data.bar` = `{ date; o; h; l; c; v }`
- `Engine.strategy` = `{ targets : float array array }` (per-asset target
  arrays in stock declaration order)
- Engine fill modes: `Close_same` fills at the decision close. `Open_next`
  fills at the next open.
- Margin accounting keeps separate cash and margin inventories for each asset. Equity subtracts loans, accrued interest, and residual debt.
- Buys use cash first. A fresh margin buy takes a standard exchange-ratio loan. Refinancing uses a sell and buy pair with full costs on both legs. Interest is a liability that settles with repayment.
- Maintenance is total margin inventory value divided by total loans. A margin call sells only margin inventories. Bankruptcy sells everything, keeps residual debt, and freezes the account.
- The engine assumes every Taiwan symbol is marginable at the standard TWSE or TPEX ratio. Broker eligibility and reduced ratios, including possible limits on leveraged ETFs such as 00685L, are outside the model.
- TW cache header: `date,open,high,low,close,volume`
- Dividend cache header: `date,factor`
- US cache header: `date,open,high,low,close,adj_close,volume`
- Fill log header: `date,stock,price,from_exposure,to_exposure`

## How to add an indicator

1. Add the function to `lib/series.ml`. Give NaN for the warmup indexes.
2. Add the name and arity to `builtin_arity` in `lib/dsl.ml`.
3. Add the call case to `eval_call` in `lib/dsl.ml`.
4. Add an exact-value assert to `test/test_bt.ml`.

## Tests

- Tests are plain asserts. Do not add a test framework.
- Test exact values against hand-computed or independently simulated
  numbers.
- Each non-trivial branch needs one check that fails when the logic
  breaks.
