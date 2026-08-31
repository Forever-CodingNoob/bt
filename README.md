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
- [How the engine trades](#how-the-engine-trades)
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

## How the engine trades

- In `close` mode, the engine reads a decision at the bar close and fills
  it at that close. This mode is the default.
- In `open` mode, the engine reads a decision at the bar close and fills
  it at the next bar open.
- A strategy states a target exposure per bar. The engine trades the
  difference and charges costs on the traded fraction.
- Default costs: a TW trade pays the online commission of 0.0399% on each side, with a 20 TWD minimum per order.
  The minimum applies only when `--capital` is given.
  Through 2026-12-31, an ordinary bond ETF (a symbol that starts with `00` and ends with `B`) pays no sell tax.
  Other `00` ETFs and `02` ETNs pay 0.1%; other Taiwan symbols pay 0.3%.
  US costs and slippage are zero.
  Override these with the cost flags (0.0399% = 3.99 basis points).
- An open position at the end of the data is closed at the last close.

Targets fill only when they change, so positions drift between fills. Each asset has separate cash and margin inventories. A buy uses available cash first. A new margin purchase borrows 60% of its value for both TWSE and TPEX stocks. The TPEX maximum became 60% on 2014-11-10; use `--financing-ratio 50` for earlier TPEX backtests.

If required down payments exceed available cash, the engine can refinance existing inventory with a sell and buy pair. Both legs charge full trading costs. Financing interest accrues by calendar day as a liability at 6.35% per year by default and settles with repayment. It does not reduce cash each day. Equity is cash plus both inventories, less loans, accrued interest, and residual debt.

Maintenance is total margin inventory value divided by total loans. It starts at 166.7% for both TWSE and TPEX margin entries, independent of total exposure. The default threshold is 130%. A call sells all margin inventories at the next open, but cash inventories remain. If equity is zero or less at a close, the engine sells everything, keeps any unpaid debt, and freezes the account.

The engine assumes every Taiwan symbol is marginable at the standard exchange ratio. It does not check broker eligibility or reduced financing ratios. Leveraged ETFs such as 00685L have historically been excluded from margin financing or assigned reduced ratios, so live margin trading can be unavailable.

## Data notes

- TW prices are cached raw. The loader adjusts them for dividends with
  factors from `TaiwanStockDividendResult`.
- The loader adjusts TW prices for splits, capital reductions, and par
  value changes with factors from `TaiwanStockSplitPrice`,
  `TaiwanStockCapitalReductionReferencePrice`, and
  `TaiwanStockParValueChange`, cached per symbol in
  `data/tw/<symbol>.events.csv`.
- US prices are adjusted with the `Adj_Close` column. The US cache is
  downloaded again in full on each fetch, because `Adj_Close` changes
  for old rows after each dividend.
- A Taiwan fetch prepends rows when `--from` is earlier than the first
  cached date. It also appends rows after the last cached date. Cached
  dates are not added again, so repeated fetches are idempotent.

## Contributing

See [CONTRIBUTING.md](./CONTRIBUTING.md).


## License
The project is licensed under GPU LGPL v2.1. See [LICENSE](./LICENSE).

## Acknowledgements

As you may have noticed, this project is vibe-coded in its entirety. A huge thanks to omp, Claude Fable 5, and OpenAI GPT-5.6 Sol.

