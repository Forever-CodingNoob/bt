# Contributing

## Contents

- [Module layout](#module-layout)
- [Documentation map](#documentation-map)
- [Build and test](#build-and-test)
- [Style rules](#style-rules)
- [Tests](#tests)
- [Fetching test data](#fetching-test-data)
- [Data cache layout](#data-cache-layout)
- [Fixed contracts](#fixed-contracts)
- [How to add an indicator](#how-to-add-an-indicator)

## Module layout

```
bin/bt.ml          CLI dispatch: fetch | run
lib/ast.ml         Strategy AST types
lib/ast.mli        AST interface
lib/lexer.mll      Lexer (ocamllex)
lib/parser.mly     Grammar (ocamlyacc)
lib/dsl.ml         Evaluator; compiles a script to Engine.strategy
lib/dsl.mli        DSL interface
lib/data.ml        FinMind fetch, CSV cache, dividend and corporate-action adjustment
lib/data.mli       Data interface
lib/series.ml      Indicators on float arrays
lib/series.mli     Series interface
lib/engine.ml      Portfolio engine (per-asset targets, two-inventory margin accounting)
lib/engine.mli     Engine interface
lib/metrics.ml     CAGR, Sharpe, MaxDD, Calmar, trade statistics
lib/metrics.mli    Metrics interface
lib/report.ml      Terminal table, CSV output, PNG plot
lib/report.mli     Report interface
test/test_bt.ml    Assert-based tests (dune test)
test/fixtures/     Synthetic CSV data for tests
examples/          Strategy examples
scripts/plot.py    Equity graph renderer (run directly by bt)
```

## Documentation map

```
README.md             Overview, build, quick start, command summary
CONTRIBUTING.md       This file
CHANGELOG.md          Versioned changes (keepachangelog 1.1.0)
docs/cli.md           Complete CLI reference (flags, defaults, examples)
docs/strategy.md      Strategy language reference (styles, grammar, builtins)
docs/engine.md        Engine internals and per-market simulation notes
docs/specs/           Design specs
docs/plans/           Implementation plans
```

## Build and test

Create the project-local opam switch first; see "Build and test" in README.md.
All commands below assume `eval $(opam env)` ran in this directory.

```sh
dune build --root .          # must be clean; warnings are errors
dune test --root . --force   # all asserts must pass
```

## Style rules

- Use the OCaml standard library and `unix` only. Do not add opam package dependencies.
- No `for` or `while` loops. Sequence side effects with `let () = e in`.
- Branch on the market with `match` arms (`| "tw" -> ... | "us" -> ...`), never `if market = ...`. New markets must slot in as new arms.
- Make list recursion tail-recursive. Use an accumulator and `List.rev`. Use `Array` index loops for series math.
- Preserve floating-point operation order. Do not rewrite arithmetic that would change rounding.
- A numeric series is a `float array`. Warmup values are `Float.nan`. A comparison with NaN gives `false`.
- Put one space on each side of `=`. Do not align code with extra spaces.
- Network and JSON work goes through `curl` and `jq` as subprocesses. Do not parse JSON in OCaml.
- Do not embed Python (or other foreign code) in `.ml` files. Python scripts are standalone files in `scripts/`.

## Tests

- Tests are plain asserts in `test/test_bt.ml`. Do not add a test framework.
- Test exact values against hand-computed or independently simulated numbers.
- Each non-trivial branch needs one check that fails when the logic breaks.
- Write a derivation comment above each expected value explaining how it was computed. These comments are part of the test contract.
- `test_engine_buyhold_costs` is the sentinel test: it pins the E1 cost-sizing sequence for a single buy-and-hold bar pair. A change that breaks this value has changed the engine's cost identity.
- Byte-identity gates (e.g. `Marshal.to_bytes ... = Marshal.to_bytes ...`) verify that a code path produces structurally identical output. Do not weaken them to tolerance checks.

## Fetching test data

Each `bt-test<N>.exe` in the repo root is a firewall-approved binary snapshot. To fetch fresh market data for a test environment, copy the latest `bt-test<N>.exe` and run:

```sh
./bt-test<N>.exe fetch tw/0050
```

These binaries are gitignored.

## Data cache layout

```
data/tw/<SYMBOL>/<SYMBOL>.csv            Price bars (date,open,high,low,close,volume)
data/tw/<SYMBOL>/<SYMBOL>.div.csv        Dividend factors (date,factor)
data/tw/<SYMBOL>/<SYMBOL>.events.csv     Corporate-action factors (date,factor)
data/tw/<SYMBOL>/<SYMBOL>.cashdiv.csv    Cash dividends (ex_date,cash_per_share,pay_date)
data/tw/stockinfo.csv                    Financing ratio classification
data/us/<SYMBOL>/<SYMBOL>.csv            Price bars (date,open,high,low,close,volume)
data/us/<SYMBOL>/<SYMBOL>.events.csv     Corporate-action factors (date,factor)
data/us/<SYMBOL>/<SYMBOL>.cashdiv.csv    Cash dividends (ex_date,cash_per_share,pay_date)
data/us/<SYMBOL>/<SYMBOL>.div.csv        Dividend factors (date,factor)
```

## Fixed contracts

Do not change these types or formats:

- `Data.bar` = `{ date; o; h; l; c; v }`
- `Engine.strategy` = `{ targets : float array array }` (per-asset target arrays in stock declaration order)
- Engine fill modes: `Close_same` fills at the decision close. `Open_next` fills at the next open.
- Margin accounting keeps separate cash and margin inventories for each asset. Equity subtracts loans, accrued interest, and residual debt.
- Buys use cash first. A fresh margin buy takes a standard exchange-ratio loan. Refinancing uses a sell and buy pair with full costs on both legs. Interest is a liability that settles with repayment.
- Maintenance is total margin inventory value divided by total loans. A margin call sells only margin inventories. Bankruptcy sells everything, keeps residual debt, and freezes the account.
- The engine assumes every Taiwan symbol is marginable at the standard TWSE or TPEX ratio. Broker eligibility and reduced ratios, including possible limits on leveraged ETFs such as 00685L, are outside the model.
- TW cache header: `date,open,high,low,close,volume`
- Dividend cache header: `date,factor`
- US cache header: `date,open,high,low,close,adj_close,volume`
- Fill log header: `date,stock,price,from_exposure,to_exposure`

## How to add an indicator

1. Add the function to `lib/series.ml`. Give NaN for the warmup indexes. Export it in `lib/series.mli`.
2. Add the name and arity to `builtin_arity` in `lib/dsl.ml`.
3. Add the call case to `eval_call` in `lib/dsl.ml`.
4. Add an exact-value assert to `test/test_bt.ml` with a derivation comment.
