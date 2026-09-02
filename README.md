# bt

`bt` is a command-line backtest tool written in OCaml. It downloads daily
prices from the FinMind API and runs one or more strategy scripts. A run can
compare all strategies with an optional buy-and-hold baseline.

## Contents

- [Requirements](#requirements)
- [Build and test](#build-and-test)
- [Quick start](#quick-start)
- [Commands](#commands)
- [Strategy language (DSL)](#strategy-language-dsl)
- [Engine overview](#engine-overview)
- [Data notes](#data-notes)
- [Contributing](#contributing)
- [License](#license)
- [Acknowledgements](#acknowledgements)

## Requirements

- opam 2.x (the toolchain installs into a project-local switch)
- `curl` and `jq` in `/usr/bin`
- `python3` with matplotlib (optional; used by `scripts/plot.py` for the equity graph)
- A FinMind API token

For plotting, `bt` runs `scripts/plot.py` directly. If `python3` or matplotlib
is unavailable, it prints `warning: plot failed; skipping <stem>.png` and
skips the graph without failing the backtest.

## Build and test

One-time preparation: create the project-local opam switch. This pins
the compiler to OCaml 5.5.0 and installs dune into `_opam/` inside the
project, so the build does not depend on a global toolchain.

```sh
opam switch create . ocaml-base-compiler.5.5.0 --no-install -y
eval $(opam env)
opam install -y dune.3.24.2
```

Then, in each new shell:

```sh
eval $(opam env)   # selects the project switch when run in this directory
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
   bt fetch tw/0050 --from 2016-01-01
   bt fetch tw/00685L --from 2016-01-01
   ```
3. Run two strategies and add a buy-and-hold baseline:
   ```sh
   bt run examples/sma_cross.strat examples/00685L_bh.strat \
     --baseline tw/00685L
   ```

The report has one column for each strategy and one baseline column. Each
strategy metric has a `W` or `L` marker when you use `--baseline`.

The default output stem joins the strategy basenames with `_vs_`. This
example writes `out/sma_cross_vs_00685L_bh.csv` and
`out/sma_cross_vs_00685L_bh.png`. It also writes the fill logs
`out/sma_cross.trades.csv` and `out/00685L_bh.trades.csv`. A fill log has
the header `date,stock,price,from_exposure,to_exposure`.

## Commands

```
bt fetch MARKET/SYMBOL [--from YYYY-MM-DD] [--to YYYY-MM-DD] [--data-dir DIR]
bt run STRAT... [--baseline M/SYM] [--from D] [--to D]
       [-p name=value ...] [--fill open|close]
       [--fee-bps F] [--tax-bps F] [--slip-bps F] [--min-fee F]
       [--financing-rate PCT] [--maintenance-ratio PCT] [--financing-ratio PCT]
       [--loan-term-months N] [--dividend-tax PCT]
       [--capital TWD] [--data-dir DIR] [--out-dir DIR] [--out-name NAME] [--no-plot]
```

See [docs/cli.md](./docs/cli.md) for the complete reference.

- Use a value such as `tw/0050` for `MARKET/SYMBOL`. For `bt fetch` you
  can use `--market tw|us --symbol SYM` instead.
- The default fetch range starts on `1994-10-01` and ends today.
- A strategy file holds one stock, or several stocks declared with `as`
  aliases and dotted statements; see [docs/strategy.md](./docs/strategy.md).
- `--baseline M/SYM` adds an optional buy-and-hold baseline.
- `-p name=value` overrides a matching `param` in the strategy files.
- `--fill` selects the fill point. `close` fills at the decision close
  and is the default. `open` fills at the next open.
- The default curve stem joins strategy basenames with `_vs_`.
  `--out-name NAME` replaces this stem. The curve files are
  `<stem>.csv` and `<stem>.png`.
- Each strategy gets a separate `<name>.trades.csv` fill log.
  `--out-name` does not change these log names.
- `--no-plot` skips `scripts/plot.py` and prevents updates to `<stem>.png`.
- `--fee-bps`, `--tax-bps`, and `--slip-bps` take basis points. 100 basis
  points are 1%. `--capital` and `--min-fee` take TWD.
- `--dividend-tax` takes a percentage. It defaults to 0 and reduces each dividend before the engine books it.

## Strategy language (DSL)

A strategy file is a small script with one statement per line. Example
(`examples/bb_macd.strat`):

```
stock "tw/0050"
param n = 20
param k = 2.0
let hist = macd_hist(close, 12, 26, 9)
entry when cross_above(close, bb_mid(close, n)) and hist > 0
exit  when cross_below(close, bb_lower(close, n, k)) or hist < 0
size 1.0
```

Line by line:

- `stock "tw/0050"` selects the market and the symbol to trade.
- `param` declares a tunable number. `-p n=30` overrides it from the CLI.
- `let` names an intermediate series. Here `hist` is the MACD histogram.
- `entry when` gives the buy condition: the close crosses above the
  middle Bollinger band while the histogram is positive.
- `exit when` gives the sell condition: the close crosses below the
  lower band, or the histogram turns negative.
- `size 1.0` invests the full equity while in a position.

The DSL also supports fractional and staged exposure through two more
styles (`target` expressions and partial orders), about 20 builtin
indicator functions, and scalar/series arithmetic. See
[docs/strategy.md](./docs/strategy.md) for the complete reference:
styles, grammar, statements, types, and every builtin.

## Engine overview

The engine reads each bar's target exposure and trades only the difference.
Positions drift between fills. Each asset has separate cash and margin
inventories with lot-level loan tracking. See
[docs/engine.md](./docs/engine.md) for the complete engine guide, including
per-market costs, margin financing, dividend accounting, and simulation gaps.

## Data notes

- TW prices are cached raw. `data/tw/<symbol>.cashdiv.csv` stores cash ex-dates, cash per share, and pay dates. If a pay date is absent, the loader uses one calendar month after the ex-date.
- The loader builds a dividend-adjusted signal series and a money series that keeps cash-dividend price drops. Both series keep exact split, capital-reduction, par-value-change, and stock-dividend adjustments. Volume changes only for share-count events.
- If FinMind denies the cash-dividend table with HTTP or API status 400, 402, or 403, `bt fetch` derives cash from the legacy `<symbol>.div.csv` factors and treats every factor as cash-only. This is exact for cash-only TW ETFs. It can misprice stocks that also pay stock dividends.
- US caches keep raw close and adjusted close. The loader uses their daily ratio to derive ex-date cash dividends, builds the signal series from adjusted prices, and keeps cash-dividend drops in the money series.
- A Taiwan fetch prepends rows when `--from` is earlier than the first
  cached date. It also appends rows after the last cached date. Cached
  dates are not added again, so repeated fetches are idempotent.

## Contributing

See [CONTRIBUTING.md](./CONTRIBUTING.md).

## License
The project is licensed under GPU LGPL v2.1. See [LICENSE](./LICENSE).

## Acknowledgements

As you may have noticed, this project is vibe-coded in its entirety. A huge thanks to omp, Claude Fable 5, and OpenAI GPT-5.6 Sol.

