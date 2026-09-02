# CLI reference

`bt` downloads market data and runs backtests from the command line.

## Contents

- [Command syntax](#command-syntax)
- [`bt fetch`](#bt-fetch)
  - [Fetch options](#fetch-options)
  - [FinMind token](#finmind-token)
  - [Cache files](#cache-files)
  - [Price adjustments](#price-adjustments)
- [`bt run`](#bt-run)
  - [Run arguments and options](#run-arguments-and-options)
  - [Cost defaults](#cost-defaults)
  - [Fill modes](#fill-modes)
- [Run outputs](#run-outputs)
- [Exit codes](#exit-codes)

## Command syntax

```text
bt fetch MARKET/SYMBOL [--from YYYY-MM-DD] [--to YYYY-MM-DD] [--data-dir DIR]
bt fetch --market tw|us --symbol SYM [--from YYYY-MM-DD] [--to YYYY-MM-DD] [--data-dir DIR]
bt run STRAT... [--baseline M/SYM] [--from D] [--to D]
       [-p name=value ...] [--fill open|close]
       [--fee-bps F] [--tax-bps F] [--slip-bps F] [--min-fee F]
       [--financing-rate PERCENT] [--maintenance-ratio PERCENT]
       [--financing-ratio PERCENT] [--loan-term-months N] [--dividend-tax PERCENT]
       [--capital TWD] [--data-dir DIR] [--out-dir DIR] [--out-name NAME] [--no-plot]
```

## `bt fetch`

Downloads price data from FinMind and stores it in a local CSV cache. Use the positional form for new commands. The separate `--market` and `--symbol` options are an equivalent form.

### Fetch options

| Argument or option | Default | Description |
|---|---|---|
| `MARKET/SYMBOL` | — | Select one market and symbol, for example `tw/0050`. The market must be `tw` or `us`. Use this argument or use both options below. |
| `--market tw\|us` | — | Select the Taiwan or US market when you do not use the positional argument. |
| `--symbol SYM` | — | Select the FinMind symbol when you do not use the positional argument. |
| `--from YYYY-MM-DD` | `1994-10-01` | Set the first date to request. |
| `--to YYYY-MM-DD` | today | Set the last date to request. |
| `--data-dir DIR` | `data/` | Set the cache directory. |
| `-h`, `-help`, `--help` | — | Print the fetch options to standard output and exit with code 0. |

### FinMind token

Set `FINMIND_TOKEN` before you use `bt fetch`.

```sh
export FINMIND_TOKEN="your_token_here"
```

The command stops with code 1 if the variable is missing or empty.

### Cache files

| Market | File | Header |
|---|---|---|
| Taiwan | `data/tw/SYM.csv` | `date,open,high,low,close,volume` |
| Taiwan | `data/tw/SYM.div.csv` | `date,factor` |
| Taiwan | `data/tw/SYM.cashdiv.csv` | `ex_date,cash_per_share,pay_date` |
| Taiwan | `data/tw/stockinfo.csv` | `stock_id,type,date` |
| US | `data/us/SYM.csv` | `date,open,high,low,close,adj_close,volume` |

Replace `data/` with the value of `--data-dir` when you set that option.

> [!TIP]
> A plain fetch updates an existing TW cache forward only. Pass an explicit `--from` earlier than the cache start to backfill.

For Taiwan prices, `bt fetch` adds data at both ends of the cache. If `--from` is earlier than the first cached date, it fetches the missing earlier range and prepends it. It also fetches dates after the last cached date and appends them. Cached rows win at both boundaries. A repeated fetch is idempotent.

The command fetches the full Taiwan dividend-factor history and rewrites `SYM.div.csv` on each run. It also fetches cash dividends into `SYM.cashdiv.csv`. If the source omits a pay date, the loader uses one calendar month after the ex-date.

> [!WARNING]
> If the FinMind cash-dividend API returns status 400, 402, or 403, `bt fetch` derives cash from the legacy dividend factors and treats every factor as cash-only. This is exact for cash-only TW ETFs but can misprice stocks that also pay stock dividends.

Other fetch failures keep an existing cash-dividend file; without one, `bt run` warns and continues without cash credits.

For every Taiwan fetch, the command also downloads the `TaiwanStockInfo` table and rewrites `data/tw/stockinfo.csv`. It keeps only `twse` and `tpex` rows. If this fetch fails, the command keeps the existing stock-info cache. An unknown symbol or a missing cache makes `bt run` warn and use the TWSE financing ratio of 60%.

> [!WARNING]
> The stock-info table selects the standard exchange ratio only. The engine assumes every Taiwan symbol is marginable and does not check broker eligibility or reduced ratios. Leveraged ETFs such as 00685L have historically been excluded from margin financing or assigned reduced ratios.

For US prices, `bt fetch` rewrites `SYM.csv` on each run. If a cache exists, the request starts at the earlier of its first date and `--from`. This full rewrite keeps revised `Adj_Close` values consistent after dividends and splits.

### Price adjustments

The engine loads two price series for every asset. The signal series includes cash-dividend and corporate-event adjustments; the DSL evaluates indicators and rules on this series. The money series includes split, capital-reduction, par-value-change, and stock-dividend adjustments but leaves cash-dividend drops in place. The engine uses the money series for fills, inventory, loans, collateral, and equity.

For Taiwan, `<symbol>.div.csv` supplies the full dividend adjustment to the signal series and `<symbol>.cashdiv.csv` separates the cash component for the money series and ledger. `<symbol>.events.csv` supplies exact split, capital-reduction, and par-value-change factors to both price series. Share-count event factors also restate earlier volume to the post-event share basis. Cash-dividend factors do not change volume.

For US assets, the cache contains raw close and adjusted close. The signal series uses the adjusted-close scale. The money series uses raw prices, and the loader derives each cash dividend from the daily change in the close-to-adjusted-close ratio.

## `bt run`

Loads one or more strategy files and their cached prices. Each strategy file selects its data with exactly one `stock "market/symbol"` statement.

> [!IMPORTANT]
> `--benchmark` was renamed to `--baseline`. Do not pass `--market`, `--symbol`, or `--benchmark-market` to `bt run`. Put the market and symbol in each strategy file.

### Run arguments and options

| Argument or option | Default | Description |
|---|---|---|
| `STRAT...` | — | Read one or more strategies from these files. At least one file is required. The file basename without its extension becomes the strategy name. |
| `--baseline M/SYM` | — | Add a buy-and-hold baseline for this market and symbol. |
| `--from YYYY-MM-DD` | first cached common date | Set the first date to load. |
| `--to YYYY-MM-DD` | last cached common date | Set the last date to load. |
| `-p name=value` | — | Override each matching strategy `param` with a float value. Repeat for more parameters. The command rejects a name that no strategy declares. |
| `--fill open\|close` | `close` | Select the fill mode. |
| `--capital TWD` | — | Set the portfolio starting value in TWD. Enables the per-order minimum fee. |
| `--fee-bps F` | per market | Override the fee in basis points for all strategies and the baseline. |
| `--tax-bps F` | per symbol class | Override the sell tax in basis points for all strategies and the baseline. |
| `--slip-bps F` | `0` | Override slippage in basis points for all strategies and the baseline. |
| `--min-fee F` | `20` (with `--capital`) | Override the minimum commission per order in TWD. Applies only with `--capital`. |
| `--dividend-tax PERCENT` | `0` | Reduce every TW receivable and US cash dividend at creation. Represents dividend income tax and the NHI supplementary premium. |
| `--financing-rate PERCENT` | `6.35` | Set the annual financing rate. |
| `--maintenance-ratio PERCENT` | `130` | Set the maintenance threshold. |
| `--financing-ratio PERCENT` | per symbol | Set the fresh-loan financing ratio for every asset. Use 50 for TPEX backtests before 2014-11-10. |
| `--loan-term-months N` | `18` | Set the TW margin-loan term in calendar months. Use 0 for open-ended TW loans. US loans are always open-ended. |
| `--data-dir DIR` | `data/` | Set the cache directory. |
| `--out-dir DIR` | `out/` | Set the output directory. |
| `--out-name NAME` | strategy names joined with `_vs_` | Set the equity CSV and PNG stem. |
| `--no-plot` | — | Do not run the plot script or update the equity PNG. |
| `-h`, `-help`, `--help` | — | Print the run options to standard output and exit with code 0. |

> [!NOTE]
> The four margin options and `--dividend-tax` apply to every strategy and the baseline. US assets ignore `--loan-term-months`.

For the full margin and dividend engine guide, see [engine.md](./engine.md).

The command applies `--from` and `--to` to every input. It then uses the exact intersection of trading dates across all strategies and the optional baseline. This rule gives every report column the same dates. The command stops if fewer than two common dates remain.

> [!IMPORTANT]
> Strategy names must be unique. `one/a.strat` and `two/a.strat` both have the name `a` and produce a duplicate-basename error. A strategy with the basename `baseline` conflicts with `--baseline`.

`--baseline` is shorthand for an always-long target exposure of 1.0. It adds a report and equity column named `baseline`. Strategy metrics get a `W` marker when they are equal to or better than the baseline and an `L` marker when they are worse. Higher is better for Total return, CAGR, Sharpe, and Calmar. Lower is better for MaxDD.

### Cost defaults

One basis point is 0.01%. One hundred basis points are 1%.

| Market and symbol | Fee | Minimum fee | Sell tax | Slippage |
|---|---|---|---|---|
| US | 0 bps (0%) | 0 TWD | 0 bps (0%) | 0 bps (0%) |
| Taiwan ordinary bond ETF (`00...B`) | 3.99 bps (0.0399%) | 20 TWD per order | 0 bps (0%) through 2026-12-31 | 0 bps (0%) |
| Other Taiwan `00` or `02` ETN | 3.99 bps (0.0399%) | 20 TWD per order | 10 bps (0.10%) | 0 bps (0%) |
| Other Taiwan symbol | 3.99 bps (0.0399%) | 20 TWD per order | 30 bps (0.30%) | 0 bps (0%) |

Leveraged and inverse bond ETFs end in `L` or `R`, not `B`, so they use the 10 bps ETF rate.

An exposure increase pays the commission and slippage. An exposure decrease pays the commission, sell tax, and slippage. Commission is proportional to the absolute exposure change. When `--capital` is given, each order pays the greater of that proportional commission and the minimum fee. Without `--capital`, the minimum is ignored. Sell tax and slippage remain proportional. The four cost options override the applicable defaults for every strategy and the baseline; `--min-fee 0` disables the minimum.

### Fill modes

With `--fill close`, the target for a bar fills at the close of that bar. The old exposure earns the close-to-close return before the fill. The command applies fill costs at that close.

With `--fill open`, the target for a bar fills at the next bar's open. The old exposure earns the return from the previous close to that open. The new exposure then earns the return from the open to the close. If the target does not change, the current exposure earns the full close-to-close return.

The engine closes a final open exposure at the last close in both modes. It applies the fee, sell tax, and slippage to this close.

## Run outputs

`bt run` prints a report table to standard output. The table has one column for each strategy and, when requested, one baseline column. It shows Total return, CAGR, Sharpe, MaxDD, and Calmar. The lines below the table show each strategy's trade count and win rate, the common date range, and the fill mode.

If a strategy had a loan on at least one bar, `bt run` also prints a margin line:

```text
channel_ladder: margin — financing 6.35%/yr, min maintenance 145.20%, margin calls 1, refinances 3, clamps 0
```

A strategy that never had a loan has no margin line.

The default stem joins strategy names in argument order with `_vs_`. A single strategy uses its name as the stem. The optional baseline does not change the stem. `--out-name NAME` replaces this default stem.

| File | Content |
|---|---|
| `<stem>.csv` | All equity curves. Header: `date`, each strategy name in argument order, and `baseline` when requested. |
| `<name>.trades.csv` | One fill log per strategy. Header: `date,stock,price,from_exposure,to_exposure`. One row per fill per stock. No baseline fill log. |
| `<stem>.png` | Equity graph. Not created with `--no-plot`. |

`--out-name` changes only `<stem>.csv` and `<stem>.png`, not `<name>.trades.csv`.

> [!NOTE]
> `bt` runs `scripts/plot.py` directly; it does not copy the script into the output directory. `python3` and matplotlib are optional. If either is unavailable or plotting fails, the command prints a warning and exits with code 0 after it saves the CSV files.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | The command succeeded, or it printed requested help. |
| 1 | A runtime operation failed: missing token, missing cache, invalid cached data, or a failed required download. A plot failure is not a runtime failure. |
| 2 | The command line has a usage error: unknown subcommand, missing required argument, or invalid option. |
