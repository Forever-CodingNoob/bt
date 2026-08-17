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

## Strategy files

A strategy file is a small script. Example (`examples/bb_macd.strat`):

```
param n = 20
param k = 2.0
let hist = macd_hist(close, 12, 26, 9)
entry when cross_above(close, bb_lower(close, n, k)) and hist > 0
exit  when cross_below(close, bb_mid(close, n)) or hist < 0
size 1.0
```

Rules:

- One `entry when` and one `exit  when` statement are mandatory.
- `size` is optional. The default is 1.0. A value above 1.0 applies
  daily-reset leverage.
- `#` starts a comment.
- The price series are `open`, `high`, `low`, `close`, and `volume`.

Builtin functions:

```
sma(s,n)  ema(s,n)  rsi(s,n)  stddev(s,n)  highest(s,n)  lowest(s,n)
lag(s,n)  atr(n)  abs(s)  max(a,b)  min(a,b)
cross_above(a,b)  cross_below(a,b)
bb_upper(s,n,k)  bb_mid(s,n)  bb_lower(s,n,k)
macd(s,fast,slow)  macd_signal(s,fast,slow,g)  macd_hist(s,fast,slow,g)
```

## How the engine trades

- The engine reads signals at the close of a bar. It acts at the open of
  the next bar.
- Cost defaults: TW fee 14.25 bps for each side, TW sell tax 10 bps for
  ETFs (symbols that start with `00`) and 30 bps for stocks. US costs
  are zero. Override them with the CLI flags.
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
