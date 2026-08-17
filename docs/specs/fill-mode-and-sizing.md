# Design: fill modes and fractional position sizing

Date: 2026-08-17
Status: approved in discussion; pending spec review

## Context

The engine only supports all-in/all-out trades. It decides at the close
of bar t and always fills at the open of bar t+1. Two changes are
approved:

1. A fill mode that models "decide near the close, fill at the close".
2. Fractional position sizing: strategies can scale in and scale out.

Both changes share one engine rewrite, so this is one spec.

## Goals

- Fill at the same-day close (new default) or at the next open (old
  behavior, still available).
- Strategies state how much exposure to hold, add, or remove.
- Two DSL styles: declarative target exposure, and imperative partial
  orders. Legacy strategies keep their exact meaning.
- No lookahead: a decision at close t uses data up to close t only.

## Non-goals

- Short positions. Exposure stays in the long/flat range.
- Intraday data, stop orders, and limit orders.
- Changes to fetch, cache, metrics formulas, or the plot.

## Engine

### Canonical strategy form

```ocaml
type strategy = { target : float array }  (* desired exposure per bar *)
```

`target.(t)` is the exposure the strategy wants after the decision at
close t. The DSL compiles every style to this array. The old record
`{ entry; exit_; size }` is deleted. A NaN target means 0.0 (flat). A
negative target clamps to 0.0.

### Fill modes

```ocaml
type fill = Open_next | Close_same
```

- `Close_same` (CLI default): the trade to `target.(t)` fills at the
  close of bar t. The new exposure applies to the bar t+1 return.
- `Open_next`: the trade to `target.(t)` fills at the open of bar t+1.
  The old exposure applies from close t to open t+1. The new exposure
  applies from open t+1 to close t+1.

### Per-bar algorithm

State: current exposure `e` (starts 0.0), equity (starts 1.0).
For a fill from `e` to `s` with delta `d = s - e`:

- Buy (`d > 0`): cost fraction = `d * (fee_bps + slip_bps) / 10000`.
- Sell (`d < 0`): cost fraction = `-d * (fee_bps + tax_bps + slip_bps) / 10000`.

`Close_same`, bar t: `equity *= 1 + e * (c_t / c_(t-1) - 1)`, then fill
at `c_t` (charge cost, set `e = s`).

`Open_next`, bar t (fill decided at close t-1):
`equity *= 1 + e_old * (o_t / c_(t-1) - 1)`, fill at `o_t`, then
`equity *= 1 + e_new * (c_t / o_t - 1)`.

A position open after the last bar is closed at the last close with
sell costs, so the strategy and the benchmark stay comparable.

The all-in/all-out entry and exit formulas of the current engine are
the special cases `e = 0 -> s` and `e -> 0` of this algorithm.

Bar 0 has no previous close, so no return accrues on bar 0. In
`Close_same` a fill at the close of bar 0 is possible. In `Open_next`
the first possible fill is at the open of bar 1.

### Benchmark

The benchmark is `target = 1.0` on every bar, run through the same
fill mode and cost machinery as the strategy.

## DSL

A strategy file uses exactly one of three styles. A mix is an error.

### Style 1: target exposure

```
target 0.5 * num(base) + 0.5 * num(base and boost)
```

- `target <expr>` is allowed once. The expression must give a scalar
  or a numeric series. A scalar broadcasts to all bars.
- Values above 1.0 apply daily-reset leverage. The report footer notes
  this when max target > 1.
- New builtins:
  - `hold(set, reset)`: boolean flip-flop series. It becomes true on a
    bar where `set` is true, and false on a bar where `reset` is true.
    The initial state is false. If both are true on one bar, reset
    wins.
  - `num(b)`: converts a boolean series to a 0.0/1.0 numeric series.
- `cross_above(a, b)` and `cross_below(a, b)` accept a scalar for
  either argument (broadcast).

### Style 2: partial orders

```
cap 1.0
entry when cross_above(close, bb_lower(close, n, k))  size 0.5
entry when cross_above(hist, 0.0)                     size 0.5
exit  when cross_below(close, bb_mid(close, n))       size 0.5
exit  when cross_below(hist, 0.0)                     size 1.0
```

- Any number of `entry when <cond> [size <expr>]` and
  `exit when <cond> [size <expr>]` statements. The default size is 1.0.
- All sizes are exposure points. They are not fractions of the current
  position.
- A statement fires on a bar where its condition is true.
- Per bar: sum the sizes of all fired entries, subtract the sizes of
  all fired exits, apply the net delta, then clamp exposure to
  [0, cap]. `cap <number>` is optional and defaults to 1.0.
- An inline size must give a scalar or a numeric series. A series is
  read at the firing bar. A NaN size value contributes 0.0.
- Clamping makes repeated fires of level conditions harmless: the
  exposure saturates instead of growing.
- The compiler walks the bars with this rule and emits the target
  array.

### Style 3: legacy (unchanged meaning)

```
entry when <cond>
exit  when <cond>
size 1.0
```

- Exactly one `entry when` and one `exit when`, no inline sizes, plus
  an optional standalone `size` statement.
- Compiles to: target = size value while in position, else 0.0. The
  in-position walk matches the current engine: entry only while flat,
  exit only while in position. A NaN or non-positive size value falls
  back to 1.0, as today.

### Style detection and errors

- A `target` statement selects style 1. Inline sizes or `cap` or
  multiple entry/exit statements select style 2. Otherwise style 3.
- Errors: `target` mixed with `entry`/`exit`; more than one `target`;
  standalone `size` in style 1 or 2; `cap` in style 1 or 3; zero
  entry statements in style 2 or 3.

## Trades and metrics

- `out/trades.csv` becomes a fill log with the header
  `date,price,from_exposure,to_exposure`.
- `n_trades` and `win_rate` are computed over round trips. A round
  trip runs from a bar where exposure leaves 0.0 to the bar where it
  returns to 0.0 (or to the forced final close). Its `net_ret` is the
  equity ratio across the round trip minus 1.
- The report table is unchanged. The benchmark column still shows `-`
  for trade statistics.

## CLI and report

- `bt run` gains `--fill open|close`. The default is `close`. Other
  values are usage errors.
- The report prints the fill mode next to the date range line.
- Published numbers from the current version change under the new
  default; `--fill open` reproduces them.

## Tests

- Engine: hand-computed equities for a partial scale-in/scale-out
  sequence, zero-cost and with fees, in both fill modes.
- Equivalence: the legacy golden strategy (sma_cross, fast=5, slow=20,
  fixture data) under `Open_next` must reproduce the frozen golden
  equity exactly. This proves the migration keeps old semantics.
- Parser: style detection for all three styles; each mixing error;
  `hold`, `num`, and cross broadcast cases.
- Round trips: one partial-exit sequence with a known win/loss split.

## Migration

- `lib/engine.ml`: new `strategy` record, `fill` type, unified loop.
- `lib/dsl.ml`: style detection, state walks for styles 2 and 3, new
  builtins.
- `lib/parser.mly`, `lib/lexer.mll`: `target`, `cap`, inline `size`.
- `lib/report.ml`: fill-mode line, fill log, round-trip statistics
  (moves from `lib/metrics.ml` trade stats where needed).
- `bin/bt.ml`: `--fill` flag, benchmark target array.
- `README.md`: engine section and DSL reference update. Respect user
  edits; edit surgically.
- `CONTRIBUTING.md`: update the fixed contract for `Engine.strategy`.
