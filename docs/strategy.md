# Strategy language reference

A strategy file is a small script. `bt run` compiles it to a target
exposure series and backtests it. See the README for basic usage and
docs/cli.md for the CLI flags.

## Contents

- [Strategy styles](#strategy-styles)
- [Multi-stock strategies](#multi-stock-strategies)
- [Grammar (BNF)](#grammar-bnf)
- [Statements](#statements)
- [Values and types](#values-and-types)
- [Builtin functions](#builtin-functions)

Statements are one per line. Each stock uses exactly one of the three
styles below. Do not mix styles for one stock.

## Strategy styles

### Target exposure

```
target 0.5 * num(base) + 0.5 * num(base and boost)
```

`target` sets the desired exposure for each bar. The expression must give
a scalar or a numeric series. A scalar applies to all bars. A value above
1.0 applies daily-reset leverage.

### Partial orders

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

### Legacy entry and exit

```
entry when <cond>
exit  when <cond>
size 1.0
```

Use exactly one `entry` statement and one `exit` statement. The standalone
`size` is optional. This style keeps the original entry and exit behavior.

## Multi-stock strategies

Add `as alias` to every stock declaration to use the qualified form:

```
stock "tw/00685L" as bull
stock "tw/0050" as bear
```

Aliases are all-or-nothing within a file. Without aliases, declare exactly
one stock and use bare stock-scoped statements and bar series. With aliases,
every stock declaration needs an alias, and every stock-scoped statement and
bar series needs that alias.

Qualified statement forms are:

```
bull.target 0.8 * num(x)
bear.entry when <cond> size <expr>
bear.exit when <cond>
bull.size <expr>
bear.cap 1.0
```

Use `alias.open`, `alias.high`, `alias.low`, `alias.close`, and
`alias.volume` for bar series. Use `alias.atr(n)` for ATR. Do not qualify
other builtins; pass a qualified series instead, such as
`sma(bull.close, n)`.

Each alias groups its own statements and follows one strategy style
independently. Different stocks may use different styles. `param` and `let`
remain file-global. Expressions may combine series from any aliases, which
supports cross-asset signals.

Before evaluation, `bt` intersects all stock calendars. Every series uses
the common dates. Fewer than two common dates is an error.

Compilation fails for:

- a mix of aliased and unaliased stock declarations, or more than one
  unaliased stock;
- a duplicate alias or duplicate market/symbol;
- an alias that collides with a `param`, `let`, builtin, or predefined
  series name;
- an undeclared alias, or a declared stock with no statements;
- a bare stock-scoped statement, bare predefined series, or bare `atr(n)`
  in an aliased file; or
- a qualified builtin other than `atr`.

## Grammar (BNF)

```
file       ::= { statement }
statement  ::= "stock" string [ "as" ident ]
             | "param" ident "=" number
             | "let" ident "=" expr
             | [ident "."] "entry" "when" expr [ "size" expr ]
             | [ident "."] "exit" "when" expr [ "size" expr ]
             | [ident "."] "size" expr
             | [ident "."] "target" expr
             | [ident "."] "cap" number
expr       ::= number
             | ident
             | ident "." ident
             | ident "(" [ expr { "," expr } ] ")"
             | ident "." ident "(" [ expr { "," expr } ] ")"
             | "(" expr ")"
             | "-" expr
             | "not" expr
             | expr binop expr
binop      ::= "+" | "-" | "*" | "/"
             | "<" | "<=" | ">" | ">=" | "==" | "!="
             | "and" | "or"
ident      ::= ( letter | "_" ) { letter | digit | "_" }
number     ::= decimal literal, with an optional exponent
string     ::= '"' { character except '"' or newline } '"'
```

Braces `{ }` mean repetition of zero or more times. Brackets `[ ]`
mean an optional part.

A `#` starts a comment. The comment stops at the end of the line.

Operator precedence, from low to high: `or`, `and`, `not`, comparisons,
`+ -`, `* /`, unary `-`.

## Statements

- `stock "market/symbol" [as alias]` selects data for the strategy. Use
  market `tw` or `us`. An unaliased file must contain exactly one `stock`
  statement. An aliased file may contain one or more, all with aliases.
- `param name = number` declares a parameter. The CLI flag
  `-p name=value` can override it.
- `let name = expr` binds an expression result to a name.
- `entry when expr` and `exit when expr` set boolean conditions. Their
  dotted forms are `alias.entry when expr` and `alias.exit when expr`. The
  expression must give a boolean series. Partial orders can repeat these
  statements and add an inline `size expr`.
- `size expr`, or `alias.size expr`, sets the exposure in legacy style. It
  is optional. The default is 1.0. A value above 1.0 applies daily-reset
  leverage. A value that is NaN or not positive falls back to 1.0.
- `target expr`, or `alias.target expr`, sets the target exposure. Use it
  once in target style.
- `cap number`, or `alias.cap number`, sets the maximum exposure for
  partial orders. It is optional. The default is 1.0.

Trips are per stock. Entry and exit prices are the exposure-weighted fill
VWAPs, and `net_ret = exit VWAP / entry VWAP - 1`. Costs are excluded.

## Values and types

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

## Builtin functions

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
