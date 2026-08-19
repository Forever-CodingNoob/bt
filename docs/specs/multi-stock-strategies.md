# Design: multi-stock strategies with cross-asset signals

Date: 2026-08-19
Status: approved in discussion; pending spec review

## Context

A strategy file holds exactly one stock, and the engine accounts one
asset. Hedging needs hybrid strategies: one file that holds several
stocks at once, with one stock's indicators driving another stock's
exposure (for example, an inverse-ETF leg that enters when the primary
asset turns bearish).

This is sub-project B of the DSL-expressiveness update. Sub-project A
(exact corporate-action adjustment) landed first; sub-project C
(margin financing) builds on this portfolio accounting and has its own
spec.

## Goals

- One strat file can declare several stocks and trade them as one
  portfolio with one equity curve.
- Cross-asset signals: any expression can read any declared stock's
  series.
- All three DSL styles work per stock, with different stocks in one
  file free to use different styles.
- Existing single-stock files keep their exact meaning and their
  equity numbers.

## Non-goals

- Short exposure. Every per-stock target stays in the long/flat range.
- Margin financing, maintenance ratios, and margin calls
  (sub-project C).
- CLI changes. Multi-stock is invisible to `bt run` flags.
- Baseline changes: the baseline stays one symbol at target 1.0.
- Declaring the same symbol twice in one file (error).

## DSL

### Stock declarations and aliases

```
stock "tw/00685L" as bull
stock "tw/00632R" as bear
```

`as alias` is new. Aliases and qualification are all-or-nothing per
file:

- No alias: exactly one `stock` statement, bare statements and series,
  today's behavior unchanged.
- Aliased: every `stock` statement carries `as`, and every
  stock-scoped statement and bar series is qualified. This form allows
  one stock or several.

Errors: a mix of aliased and unaliased `stock` statements; two or more
unaliased stocks; duplicate alias; duplicate market/symbol; an alias
that collides with a param, let, builtin, or predefined series name.

### Qualified statements

The stock alias follows the keyword:

```
target bull <expr>
entry  bear when <cond> [size <expr>]
exit   bear when <cond> [size <expr>]
size   bull <expr>
cap    bear 1.0
```

Statements group by alias. Each group independently follows the
existing style rules: target style, partial orders, or legacy, never
mixed within one stock. Different stocks in one file may use different
styles. Each group compiles to that stock's target array with the
existing style compilers. A statement that names an undeclared alias
is an error; a declared stock with no statements is an error.

### Qualified series and builtins

- `alias.open`, `alias.high`, `alias.low`, `alias.close`,
  `alias.volume` read that stock's series.
- `alias.atr(n)` qualifies the one builtin that reads bars directly.
- In an aliased file, bare `open/high/low/close/volume` and bare
  `atr(n)` are compile errors.

`param` and `let` stay file-global. A `let` may mix aliases freely;
this is the cross-asset mechanism:

```
let bull_mid = sma(bull.close, 47)
let crash = bull.close / lag(bull_mid, 7) - 1 < -0.012
target bear 0.5 * num(crash)
```

### Grammar additions

```
statement  ::= "stock" string [ "as" ident ]
             | "entry" [ident] "when" expr [ "size" expr ]
             | "exit"  [ident] "when" expr [ "size" expr ]
             | "size"  [ident] expr
             | "target" [ident] expr
             | "cap"   [ident] number
expr       ::= ident "." ident
             | ident "." ident "(" [ expr { "," expr } ] ")"
```

`param` and `let` statements and all other expression forms keep the
grammar from docs/strategy.md unchanged.

`as` becomes a keyword. `.` becomes a token. The AST carries the
optional alias on statements and a qualifier on variable and call
nodes.

## Alignment

All stocks in a file load independently (with sub-project A's
adjustments), then intersect on common trading dates with the same
logic `bt run` uses across files. Every series shares indices before
evaluation. Fewer than 2 common dates is an error.

## Engine

### Canonical form

```ocaml
type strategy = { targets : float array array }  (* per asset, per bar *)
```

`Engine.run` takes per-asset bars (equal lengths), per-asset costs,
`~capital`, and `~fill`. Each asset resolves its own cost defaults by
market and symbol; CLI cost overrides apply to every asset uniformly.
A single-stock file is the one-asset case of the same loop.

### Accounting

One equity accumulator. Per-asset exposure `e_i` starts 0.0; a NaN or
negative target clamps to 0.0 per asset.

- `Close_same`, bar t:
  `equity *= 1 + sum_i e_i * (c_i,t / c_i,t-1 - 1)`, then each asset
  whose target changed fills at its own close.
- `Open_next`, bar t: on a bar where no asset fills, one joint leg:
  `equity *= 1 + sum_i e_i * (c_i,t / c_i,t-1 - 1)`. On a bar where at
  least one asset fills, two joint legs for every asset:
  `equity *= 1 + sum_i e_i * (o_i,t / c_i,t-1 - 1)`, fill the changed
  assets at their opens, then
  `equity *= 1 + sum_i e_i' * (c_i,t / o_i,t - 1)` with the new
  exposures. With one asset this reduces exactly to today's behavior.
- A fill from `e_i` to `s_i` charges the equity fraction
  `|s_i - e_i| * rate_i / 10000` with the existing buy/sell rate split
  and the per-order minimum fee floor when `--capital` is set.
- The last bar force-closes every nonzero exposure at that asset's
  last close, with sell costs.
- Gross exposure `sum_i e_i` is uncapped. Above 1.0 it behaves as
  cost-free daily-reset leverage until sub-project C adds financing;
  the report footer notes it.

### Fills and round trips

`fill_event` gains the stock: `date, stock, price, from_e, to_e`.

Round trips are per asset: a trip runs from the bar where `e_i`
leaves 0.0 to the bar where it returns to 0.0 (or the forced final
close). Trip return is the leg price return, costs excluded:

- entry price = the exposure-weighted average of fill prices over the
  trip's exposure increases (weights = the exposure added at each
  fill);
- exit price = the same over decreases;
- `net_ret = exit_price / entry_price - 1`.

This replaces the portfolio-equity-ratio definition everywhere,
including single-stock files: a hedge leg that made money counts as a
win even when the portfolio fell while it was held. Single-stock
equity curves and metrics other than trip statistics are unchanged;
`n_trades` counts trips across all assets of the file, and `win_rate`
uses the new `net_ret`.

## Report and CLI

- The report table is unchanged: one column per strat file, metrics on
  the portfolio equity curve.
- `out/<stem>.trades.csv` header becomes
  `date,stock,price,from_exposure,to_exposure` for every file,
  single-stock included.
- The leverage footer triggers on max gross exposure above 1.0.
- Equity CSV, plot, baseline handling, and every CLI flag are
  unchanged.

## Result changes

- Single-stock equity curves, Total return, CAGR, Sharpe, MaxDD:
  identical to today.
- Trip statistics change definition: costs drop out of `net_ret`, so
  `win_rate` can shift on marginal trips. `trades.csv` gains the
  `stock` column.

## Tests

- Parser: alias grammar, qualified statements, dotted series,
  `alias.atr(n)`, and every error rule (mixed aliased/unaliased,
  bare series in aliased files, unknown alias, duplicate
  alias/symbol, name collisions, stock without statements).
- Compile: a cross-asset `let` driving another stock's target; one
  file mixing target style and partial orders across two stocks.
- Engine: hand-computed two-asset equity in both fill modes, zero-cost
  and with distinct per-asset costs; force-close; min-fee with
  `--capital`; VWAP trip returns under scale-in/scale-out.
- Regression: the existing suite passes with single-stock files
  producing identical equity; golden trip stats updated to the new
  `net_ret` definition where they change.
- Integration: a two-fixture multi-stock strat through `bt run` with
  hand-computed expectations.

## Migration

- `lib/ast.ml`: optional alias on statements, qualifier on
  `Var`/`Call`, alias on `Stock`.
- `lib/lexer.mll`, `lib/parser.mly`: `as` keyword, `.` token,
  qualified statement forms.
- `lib/dsl.ml`: alias table, qualified environment, per-group style
  detection and compilation, error rules.
- `lib/engine.ml`: portfolio `strategy`, per-asset bars and costs,
  accounting above, `fill_event` stock field, VWAP trips.
- `bin/bt.ml`: load and intersect per-file stocks, per-asset costs,
  baseline as one-asset portfolio, footer input.
- `lib/report.ml`: `stock` column in the fills log, gross-exposure
  footer.
- `docs/strategy.md`: aliased style, qualified statements and series,
  grammar update. `docs/cli.md`: trades.csv header. `CONTRIBUTING.md`:
  `Engine.strategy` contract line. Respect user edits; edit
  surgically.
