# bt

`bt` is a command-line backtest tool written in OCaml. It downloads daily
prices from the FinMind API, and it tests a strategy script against a
buy-and-hold benchmark.

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

## Commands

```
bt fetch --market tw|us --symbol SYM [--from YYYY-MM-DD] [--to YYYY-MM-DD] [--data-dir DIR]
bt run STRAT_FILE --market tw|us --symbol SYM [--from D] [--to D]
       [--benchmark SYM] [--benchmark-market tw|us] [-p name=value ...]
       [--fee-bps F] [--tax-bps F] [--slip-bps F]
       [--data-dir DIR] [--out-dir DIR] [--no-plot]
```

- The default benchmark is `00685L` in market `tw`.
- `-p name=value` overrides a `param` in the strategy file.
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

### Grammar (BNF)

```
file       ::= { statement }
statement  ::= "param" ident "=" number
             | "let" ident "=" expr
             | "entry" "when" expr
             | "exit" "when" expr
             | "size" expr
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
- `entry when expr` sets the entry signal. The expression must give a
  boolean series. Exactly one `entry` statement is mandatory.
- `exit when expr` sets the exit signal. Exactly one `exit` statement is
  mandatory.
- `size expr` sets the exposure at entry. It is optional. The default
  is 1.0. A value above 1.0 applies daily-reset leverage. A value that
  is NaN or not positive falls back to 1.0.

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

- The engine reads signals at the close of a bar. It acts at the open of
  the next bar.
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
