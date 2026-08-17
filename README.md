# bt

`bt` is a command-line backtest tool written in OCaml. It downloads daily
prices from the FinMind API, and it tests a strategy script against a
buy-and-hold benchmark.

## Contents

- [Requirements](#requirements)
- [Build and test](#build-and-test)
- [Quick start](#quick-start)
- [Commands](#commands)
- [Strategy language (DSL)](#strategy-language-dsl)
  - [Strategy styles](#strategy-styles)
  - [Grammar (BNF)](#grammar-bnf)
  - [Statements](#statements)
  - [Values and types](#values-and-types)
  - [Builtin functions](#builtin-functions)
- [How the engine trades](#how-the-engine-trades)
- [Data notes](#data-notes)
- [Contributing](#contributing)
- [Acknowledgements](#acknowledgements)

## Requirements

- OCaml and dune (install with opam)
- `curl` and `jq` in `/usr/bin`
- `python3` with matplotlib (only for the equity graph; optional)
- A FinMind API token

## Build and test

```sh
dune build
dune test
```

The binary is `_build/default/bin/bt.exe`.

## Quick start

1. Set your token:
   ```sh
   export FINMIND_TOKEN="your_token_here"
   ```
2. Download data:
   ```sh
   bt fetch --market tw --symbol 0050 --from 2016-01-01
   bt fetch --market tw --symbol 00685L --from 2016-01-01
   ```
3. Run a backtest:
   ```sh
   bt run examples/sma_cross.strat --market tw --symbol 0050 --benchmark 00685L
   ```

The report shows each metric for the strategy and the benchmark, with a
WIN or LOSS verdict. The run also writes `out/equity.csv`,
`out/trades.csv`, and `out/equity.png`.

The report prints the fill mode on the date-range line.
The `out/trades.csv` file uses the header
`date,price,from_exposure,to_exposure`.

## Commands

```
bt fetch --market tw|us --symbol SYM [--from YYYY-MM-DD] [--to YYYY-MM-DD] [--data-dir DIR]
bt run STRAT_FILE --market tw|us --symbol SYM [--from D] [--to D]
       [--benchmark SYM] [--benchmark-market tw|us] [-p name=value ...]
       [--fill open|close] [--fee-bps F] [--tax-bps F] [--slip-bps F]
       [--data-dir DIR] [--out-dir DIR] [--no-plot]
```

See [docs/cli.md](./docs/cli.md) for the complete reference for each command, flag, and option.

- The default benchmark is `00685L` in market `tw`.
- `-p name=value` overrides a `param` in the strategy file.
- `--fill` selects the fill point: `close` fills at the decision close
  (default), `open` fills at the next open.
- `--no-plot` prevents the PNG output.
- The cost flags take basis points. 100 basis points = 1%.

## Strategy language (DSL)

A strategy file is a small script. Example (`examples/bb_macd.strat`):

```
param n = 20
param k = 2.0
let hist = macd_hist(close, 12, 26, 9)
entry when cross_above(close, bb_lower(close, n, k)) and hist > 0
exit  when cross_below(close, bb_mid(close, n)) or hist < 0
size 1.0
```

Statements are one per line.
A strategy file uses exactly one of these three styles. Do not mix styles.

### Strategy styles

#### Target exposure

```
target 0.5 * num(base) + 0.5 * num(base and boost)
```

`target` sets the desired exposure for each bar. The expression must give
a scalar or a numeric series. A scalar applies to all bars. A value above
1.0 applies daily-reset leverage.

#### Partial orders

```
cap 1.0
entry when cross_above(close, bb_lower(close, n, k))  size 0.5
entry when cross_above(hist, 0.0)                     size 0.5
exit  when cross_below(close, bb_mid(close, n))       size 0.5
exit  when cross_below(hist, 0.0)                     size 1.0
```

Use any number of `entry` and `exit` statements. An inline `size` changes
exposure by that many points. It does not state a fraction of the current
position. The engine sums the changes on each bar. It clamps exposure from
0 to `cap`. The default cap is 1.0.

#### Legacy entry and exit

```
entry when <cond>
exit  when <cond>
size 1.0
```

Use exactly one `entry` statement and one `exit` statement. The standalone
`size` is optional. This style keeps the original entry and exit behavior.

### Grammar (BNF)

```
file       ::= { statement }
statement  ::= "param" ident "=" number
             | "let" ident "=" expr
             | "entry" "when" expr [ "size" expr ]
             | "exit" "when" expr [ "size" expr ]
             | "size" expr
             | "target" expr
             | "cap" number
expr       ::= number
             | ident
             | ident "(" [ expr { "," expr } ] ")"
             | "(" expr ")"
             | "-" expr
             | "not" expr
             | expr binop expr
binop      ::= "+" | "-" | "*" | "/"
             | "<" | "<=" | ">" | ">=" | "==" | "!="
             | "and" | "or"
ident      ::= ( letter | "_" ) { letter | digit | "_" }
number     ::= decimal literal, with an optional exponent
```

Braces `{ }` mean repetition of zero or more times. Brackets `[ ]`
mean an optional part.

A `#` starts a comment. The comment stops at the end of the line.

Operator precedence, from low to high: `or`, `and`, `not`, comparisons,
`+ -`, `* /`, unary `-`.

### Statements

- `param name = number` declares a parameter. The CLI flag
  `-p name=value` can override it.
- `let name = expr` binds an expression result to a name.
- `entry when expr` and `exit when expr` set boolean conditions. The
  expression must give a boolean series. Partial orders can repeat these
  statements and add an inline `size expr`.
- `size expr` sets the exposure in legacy style. It is optional. The
  default is 1.0. A value above 1.0 applies daily-reset leverage. A value
  that is NaN or not positive falls back to 1.0.
- `target expr` sets the target exposure. Use it once in target style.
- `cap number` sets the maximum exposure for partial orders. It is
  optional. The default is 1.0.

### Values and types

- A value is a scalar, a numeric series, or a boolean series.
- The predefined series are `open`, `high`, `low`, `close`, and
  `volume`.
- Arithmetic and comparisons accept scalar and series operands in any
  mix. A scalar broadcasts across a series.
- A comparison gives a boolean series. If an operand is NaN at an
  index, the result at that index is `false`.
- `and`, `or`, and `not` operate on boolean series only.
- A window or period argument must be a scalar of 1 or more.
- Indicator outputs contain NaN in the warmup range.

### Builtin functions

Signal helpers:

- `cross_above(a, b)` is true on a bar where `a` was at or below `b` on
  the previous bar and is above `b` now. The result is `false` when an
  operand is NaN.
- `cross_below(a, b)` is the mirror of `cross_above`.
- Both cross helpers accept a scalar for either argument. The scalar
  broadcasts across the series.
- `hold(set, reset)` gives a boolean flip-flop series. It starts false.
  A true `set` value turns it on. A true `reset` value turns it off.
  Reset wins if both values are true on one bar.
- `num(b)` converts a boolean series to a numeric series of 0.0 and 1.0.

Moving averages and statistics:

- `sma(s, n)` gives the arithmetic mean of the last `n` values.
- `ema(s, n)` gives the exponential moving average with
  `alpha = 2 / (n + 1)`. The seed is the `sma` of the first `n` valid
  values, so `ema` also works on series with a NaN warmup, for example
  `macd` output.
- `stddev(s, n)` gives the population standard deviation of the last
  `n` values.
- `highest(s, n)` and `lowest(s, n)` give the maximum and the minimum
  of the last `n` values.
- `lag(s, n)` gives the value from `n` bars before.

Oscillators and ranges:

- `rsi(s, n)` gives the Wilder relative strength index, from 0 to 100.
- `atr(n)` gives the Wilder-smoothed average true range of the loaded
  bars. It reads high, low, and close directly, so it takes no series
  argument.

Bollinger Bands:

- `bb_mid(s, n)` equals `sma(s, n)`.
- `bb_upper(s, n, k)` equals `sma(s, n) + k * stddev(s, n)`.
- `bb_lower(s, n, k)` equals `sma(s, n) - k * stddev(s, n)`.

MACD:

- `macd(s, fast, slow)` equals `ema(s, fast) - ema(s, slow)`.
- `macd_signal(s, fast, slow, g)` is the `ema` of the MACD line with
  period `g`.
- `macd_hist(s, fast, slow, g)` equals the MACD line minus the signal
  line.

Arithmetic helpers:

- `abs(s)` gives the absolute value.
- `max(a, b)` and `min(a, b)` compare two values element by element.
  The result is NaN where an operand is NaN.

## How the engine trades

- In `close` mode, the engine reads a decision at the bar close and fills
  it at that close. This mode is the default.
- In `open` mode, the engine reads a decision at the bar close and fills
  it at the next bar open.
- A strategy states a target exposure per bar. The engine trades the
  difference and charges costs on the traded fraction.
- Default costs: a TW trade pays a 0.1425% fee on each side. A TW sale
  also pays a tax: 0.1% for ETFs (symbols that start with `00`) and
  0.3% for stocks. US costs are zero. Slippage is zero. Override these
  with the cost flags (0.1425% = 14.25 basis points).
- An open position at the end of the data is closed at the last close.

## Data notes

- TW prices are cached raw. The loader adjusts them for dividends with
  factors from `TaiwanStockDividendResult`.
- The loader detects TW splits and capital reductions. A close-to-close
  change of more than 25% in one step is not possible under the TW price
  bands, so the loader treats it as a corporate action.
- US prices are adjusted with the `Adj_Close` column. The US cache is
  downloaded again in full on each fetch, because `Adj_Close` changes
  for old rows after each dividend.
- A repeated fetch adds only new TW rows. It does not create duplicates.

## Contributing

See [CONTRIBUTING.md](./CONTRIBUTING.md).

## Acknowledgements

As you may have noticed, this project is vibe-coded in its entirety. A huge thanks to omp, Claude Fable 5, and OpenAI GPT-5.6 Sol.
