# bt

`bt` is a command-line backtest tool written in OCaml. It downloads daily prices from FinMind (Taiwan) and Tiingo (US) and runs one or more strategy scripts. A run can compare all strategies against an optional buy-and-hold baseline.

## Contents

- [Requirements](#requirements)
- [Build and test](#build-and-test)
- [Quick start](#quick-start)
- [Commands](#commands)
- [Strategy language (DSL)](#strategy-language-dsl)
- [Engine overview](#engine-overview)
- [Data notes](#data-notes)
  - [US market (us)](#us-market-us)
  - [Taiwan market (tw)](#taiwan-market-tw)
- [Contributing](#contributing)
- [License](#license)
- [Acknowledgements](#acknowledgements)

## Requirements

- opam 2.x (the toolchain installs into a project-local switch)
- `curl` and `jq` in `/usr/bin`
- `python3` with matplotlib (optional; `scripts/plot.py` uses it to draw the equity graph)
- A FinMind API token (`FINMIND_TOKEN`) for TW data, a Tiingo API token (`TIINGO_TOKEN`) for US data, or both

`bt` runs `scripts/plot.py` directly to draw the graph. If `python3` or matplotlib is missing, `bt` prints `warning: plot failed; skipping <stem>.png`, skips the graph, and still completes the backtest.

## Build and test

Create the project-local opam switch once. This pins the compiler to OCaml 5.5.0 and installs dune into `_opam/` inside the project, so the build needs no global toolchain.

```sh
opam switch create . ocaml-base-compiler.5.5.0 --no-install -y
eval $(opam env)
opam install -y dune.3.24.2
```

Then run these in each new shell:

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
     --baseline tw/00685L --capital 1000000
   ```

The report has one column per strategy and one baseline column. With `--baseline`, each strategy metric gets a `W` or `L` marker unless the strategy value or the baseline value is `n/a`.

The default output stem joins the strategy basenames with `_vs_`, so this example writes `out/sma_cross_vs_00685L_bh.csv` and `out/sma_cross_vs_00685L_bh.png`. It also writes the fill logs `out/sma_cross.trades.csv` and `out/00685L_bh.trades.csv`. Each fill log has the header `date,stock,price,from_exposure,to_exposure`.

## Commands

```
bt fetch MARKET/SYMBOL [--from YYYY-MM-DD] [--to YYYY-MM-DD] [--data-dir DIR]
bt run STRAT... [--baseline M/SYM] [--from D] [--to D]
       [-p name=value ...] [--fill open|close]
       [--fee-bps F] [--tax-bps F] [--slip-bps F] [--min-fee F]
       [--per-share-fee F] [--per-share-cap F]
       [--financing-rate PCT] [--maintenance-ratio PCT] [--financing-ratio PCT]
       [--loan-term-months N] [--dividend-tax PCT]
       --capital AMOUNT [--data-dir DIR] [--out-dir DIR] [--out-name NAME] [--no-plot]
```

See [docs/cli.md](./docs/cli.md) for the complete reference.

- `MARKET/SYMBOL` takes a value such as `tw/0050`. For `bt fetch` you can pass `--market tw|us --symbol SYM` instead.
- Without `--from`, a new cache starts on `1994-10-01` and an existing cache resumes after its last cached date. `--to` defaults to today.
- A strategy file holds one stock, or several stocks declared with `as` aliases and dotted statements; see [docs/strategy.md](./docs/strategy.md).
- `--baseline M/SYM` adds an optional buy-and-hold baseline.
- `-p name=value` overrides a matching `param` in the strategy files.
- `--fill` selects the fill point. `close`, the default, fills at the decision close. `open` fills at the next open.
- The default curve stem joins strategy basenames with `_vs_`. `--out-name NAME` replaces this stem. The curve files are `<stem>.csv` and `<stem>.png`.
- Each strategy gets its own `<name>.trades.csv` fill log. `--out-name` does not change these log names.
- `--no-plot` skips `scripts/plot.py` and leaves `<stem>.png` untouched.
- `--fee-bps`, `--tax-bps`, and `--slip-bps` take basis points; 100 basis points are 1%. `--capital` is required. It and `--min-fee` take the market's currency: TWD for `tw` and USD for `us`.
- `--dividend-tax` takes a percentage. It defaults to 0 and reduces each dividend before the engine books it.

## Strategy language (DSL)

A strategy file is a small script with one statement per line. This example is `examples/bb_macd.strat`:

```
stock "tw/0050"
param n = 20
param k = 2.0
let hist = macd_hist(close, 12, 26, 9)
entry when cross_above(close, bb_mid(close, n)) and hist > 0
exit  when cross_below(close, bb_lower(close, n, k)) or hist < 0
size 1.0
```

Each line does one thing:

- `stock "tw/0050"` selects the market and the symbol to trade.
- `param` declares a tunable number. `-p n=30` overrides it from the CLI.
- `let` names an intermediate series. Here `hist` is the MACD histogram.
- `entry when` gives the buy condition: the close crosses above the middle Bollinger band while the histogram is positive.
- `exit when` gives the sell condition: the close crosses below the lower band, or the histogram turns negative.
- `size 1.0` invests the full equity while in a position.

Two more styles, `target` expressions and partial orders, support fractional and staged exposure. The DSL also has about 20 builtin indicator functions and scalar/series arithmetic. See [docs/strategy.md](./docs/strategy.md) for the complete reference: styles, grammar, statements, types, and every builtin.

## Engine overview

The engine reads each bar's target exposure and trades only the difference, so positions drift between fills. Each asset has separate cash and margin inventories with lot-level loan tracking. See [docs/engine.md](./docs/engine.md) for the complete engine guide, including per-market costs, margin financing, dividend accounting, and simulation gaps.

## Data notes

Both markets use one loader with two price planes. The signal plane adjusts for dividends and every corporate event. The money plane adjusts for splits and share-count events and keeps cash-dividend drops. `bt fetch` prepends rows when `--from` is earlier than the first cached date and appends rows after the last cached date. It never adds a cached date twice, so repeated fetches are idempotent.

### US market (us)

- US prices come from [Tiingo](https://www.tiingo.com). `bt fetch` stores raw OHLCV bars, signal-plane dividend factors, cash dividends, and split events in four files per symbol under `data/us/<symbol>/`.
- Tiingo gives no pay date for cash dividends, so the engine credits them on the ex-date.
- `bt fetch` snaps split factors to the nearest small rational to remove vendor floating-point noise.

### Taiwan market (tw)

- TW prices come from [FinMind](https://finmind.github.io). `bt fetch` stores raw OHLCV bars, signal-plane dividend factors, cash dividends, and unit events in four files per symbol under `data/tw/<symbol>/`.
- Cash dividends carry real pay dates when FinMind provides them. A missing pay date falls back to one calendar month after the ex-date.
- If FinMind denies the cash-dividend table with HTTP or API status 400, 402, or 403, `bt fetch` derives cash amounts from the legacy `<symbol>.div.csv` factors and treats every factor as cash-only. This is exact for cash-only TW ETFs but can misprice stocks that also pay stock dividends.

## Contributing

See [CONTRIBUTING.md](./CONTRIBUTING.md).

## License

The project is licensed under the GNU LGPL v2.1. See [LICENSE](./LICENSE).

## Acknowledgements

As you may have noticed, this project is vibe-coded in its entirety. Thanks to omp, Claude Fable 5, and OpenAI GPT-5.6 Sol.

