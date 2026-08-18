# Design: multi-strat runs, backfill, earliest-date default

Status: design approved in discussion; pending spec review.

## Context

`bt run` compares one strategy against one hardcoded benchmark, with the
stock given by CLI flags. Research needs side-by-side backtests of
several strategies, each owning its stock. The TW cache cannot extend
backward, and the fetch default starts at 2010.

## 1. Strat files name their stock

New DSL statement:

```
stock "tw/00685L"
```

- Form: `stock "<market>/<symbol>"` with market `tw` or `us`. The
  argument is a string literal: the lexer gains one rule for
  double-quoted strings (no escapes, no newlines). A bare
  `stock tw/00685L` cannot lex: `00685L` splits into NUMBER and IDENT
  tokens, and a slash-joined token pattern would break unspaced
  division such as `mid/lag(mid, k)` in expressions. The string form
  is unambiguous and reusable for future portfolio syntax.
- The compiler splits the string on `/` and validates the market;
  malformed forms get a clear error naming the expected shape.
- Exactly one `stock` statement per file in v1. A second one is an
  error: `multiple stocks per strat are not supported yet`. This is the
  reserved extension point for future portfolios.
- A strat without `stock` is an error naming the statement to add.
- `bt run` no longer accepts `--market`/`--symbol` (clean cutover).
  `bt fetch` keeps its flags and also accepts one positional
  `tw/00685L` form (proposal a).

## 2. Multi-strat CLI

```
bt run STRAT... [--benchmark M/SYM] [--from D] [--to D] [--fill open|close]
       [-p name=value ...] [--fee-bps F] [--tax-bps F] [--slip-bps F]
       [--data-dir DIR] [--out-dir DIR] [--out-name NAME] [--no-plot]
```

- One or more strat files. Each runs through the existing single-asset
  engine unchanged.
- Shared flags apply to every strat. Cost defaults are per-strat from
  its own market/symbol; explicit cost flags override for all.
- `-p name=value` applies to every strat that declares that param.
  If no strat declares it, error.
- Date range: all strats (and the benchmark) intersect to their common
  trading dates, per the current benchmark rule. `--from`/`--to`
  narrow further. Fewer than 2 common bars is an error.
- Duplicate strat file basenames are an error (column and output name
  collisions). The basename `benchmark` is rejected when `--benchmark`
  is given, for the same reason.

## 3. Benchmark sugar

- `--benchmark tw/00685L` injects an implicit buy-and-hold column
  (target 1.0, that market's cost defaults, same fill mode).
  `--benchmark-market` is removed. There is no default benchmark.
- With a benchmark, each strat metric cell carries a compact W/L
  marker against the benchmark (lower wins for MaxDD). Without it,
  plain side-by-side metrics.

## 4. Data layer

- TW backfill: when the requested `--from` precedes the first cached
  date, fetch the head gap `[from, day-before-first-cached]` and
  prepend the rows to the cache. Tail append is unchanged. Dividends
  already refetch full history; adjustment happens at load, so
  prepended raw rows are correct by construction.
- US backfill already works through the full-rewrite path (start date
  is the earlier of the requested date and the cached start).
- `bt fetch` default `--from` becomes `1994-10-01` (earliest FinMind
  TW daily data). `bt run` keeps defaulting to the full cached range.

## 5. Report and outputs

- Terminal table: one column per strat (header = file basename), plus
  `benchmark` when present. Below the table, one line per strat:
  basename, stock, trip count, win rate. Date range and fill mode
  lines stay.
- `out/<stem>.csv` and `out/<stem>.png` where `<stem>` is the strat
  basenames joined with `_vs_` (benchmark excluded from the name), or
  the value of `--out-name` when given. CSV columns: `date`, one
  column per strat basename, `benchmark` last when present. The plot
  script is already header-driven and needs no change.
- Fill logs: `out/<basename>.trades.csv` per strat, current fill-log
  format. The benchmark writes no fill log.
- `out/plot.py` name unchanged.

## 6. Examples and migration

- `examples/00685L_bh.strat`: `stock tw/00685L` + `target 1.0`
  (proposal b, named by its stock).
- Existing example strats gain a `stock` statement (sma_cross and
  bb_macd get `stock tw/0050`).
- No auto-fetch during run (proposal c): a missing cache stays an
  error with the exact `bt fetch` hint.
- README, docs/cli.md, and CONTRIBUTING update to the new grammar.

## Non-goals

- Multiple stocks in one strat (portfolio engine).
- Parameter optimization.
- Limit fills.
- Cross-strat capital allocation; each strat's equity starts at 1.0
  independently.

## Testing

- Parser: `stock` statement forms, missing/duplicate stock errors,
  malformed token error.
- Backfill: factor the prepend into a pure cache-file operation (rows
  file + cache path in, seamless cache out) and unit-test it against a
  synthetic cache: prepend produces no duplicate dates and keeps
  ordering; a subsequent load adjusts across the seam. The curl+jq
  path is covered by live verification.
- Multi-strat run on the fixture: two strats on the same synthetic
  stock produce two columns; frozen final equities for both.
- Output naming: default stem `a_vs_b`, `--out-name` override,
  duplicate-basename error.
- Live verification: backfill 0050 to 1994, run channel-ladder vs
  00685L_bh with benchmark sugar, check PNG has N labeled curves.
