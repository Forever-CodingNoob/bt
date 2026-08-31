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
- [Help](#help)
- [Exit codes](#exit-codes)

## Command syntax

```text
bt fetch MARKET/SYMBOL [--from YYYY-MM-DD] [--to YYYY-MM-DD] [--data-dir DIR]
bt fetch --market tw|us --symbol SYM [--from YYYY-MM-DD] [--to YYYY-MM-DD] [--data-dir DIR]
bt run STRAT... [--baseline M/SYM] [--from D] [--to D]
       [-p name=value ...] [--fill open|close]
       [--fee-bps F] [--tax-bps F] [--slip-bps F] [--min-fee F]
       [--financing-rate PERCENT] [--maintenance-ratio PERCENT]
       [--financing-ratio PERCENT]
       [--capital TWD] [--data-dir DIR] [--out-dir DIR] [--out-name NAME] [--no-plot]
```

## `bt fetch`

This command downloads price data from FinMind. It stores the data in a
local CSV cache. Use the positional form for new commands. The separate
`--market` and `--symbol` options are an equivalent form.

### Fetch options

| Argument or option | Description |
| --- | --- |
| `MARKET/SYMBOL` | Select one market and symbol, for example `tw/0050`. The market must be `tw` or `us`. Use this argument or use both options below. |
| `--market tw\|us` | Select the Taiwan or US market when you do not use the positional argument. |
| `--symbol SYM` | Select the FinMind symbol when you do not use the positional argument. |
| `--from YYYY-MM-DD` | Set the first date to request. The default is `1994-10-01`. |
| `--to YYYY-MM-DD` | Set the last date to request. The default is today. |
| `--data-dir DIR` | Set the cache directory. The default is `data/`. |
| `-h`, `-help`, `--help` | Print the fetch options to standard output and exit with code 0. |

### FinMind token

Set `FINMIND_TOKEN` before you use `bt fetch`.

```sh
export FINMIND_TOKEN="your_token_here"
```

The command stops with code 1 if the variable is missing or empty.

### Cache files

The default cache has these files:

| Market | File | Header |
| --- | --- | --- |
| Taiwan | `data/tw/SYM.csv` | `date,open,high,low,close,volume` |
| Taiwan | `data/tw/SYM.div.csv` | `date,factor` |
| Taiwan | `data/tw/stockinfo.csv` | `stock_id,type,date` |
| US | `data/us/SYM.csv` | `date,open,high,low,close,adj_close,volume` |

Replace `data/` with the value of `--data-dir` when you set that option.

For Taiwan prices, `bt fetch` adds data at both ends of the cache. If
`--from` is earlier than the first cached date, it fetches the missing
earlier range and prepends it. It also fetches dates after the last cached
date and appends them. Cached rows win at both boundaries.
A plain fetch updates an existing cache forward only; pass an explicit
`--from` earlier than the cache start to backfill.
Therefore, the command does not add a date twice, and a repeated fetch is
idempotent. The command fetches the full Taiwan dividend history and
rewrites `SYM.div.csv` on each run. If this fetch fails, the command keeps the
existing dividend file. If no file exists, the command warns that prices
will be unadjusted for dividends.

For every Taiwan fetch, the command also downloads the `TaiwanStockInfo` table and rewrites `data/tw/stockinfo.csv`. It keeps only `twse` and `tpex` rows. If this fetch fails, the command keeps the existing stock-info cache. An unknown symbol or a missing cache makes `bt run` warn and use the TWSE financing ratio of 60%.

The stock-info table selects the standard exchange ratio only. The engine assumes every Taiwan symbol is marginable and does not check broker eligibility or reduced ratios. Leveraged ETFs such as 00685L have historically been excluded from margin financing or assigned reduced ratios, so live margin trading can be unavailable.

For US prices, `bt fetch` rewrites `SYM.csv` on each run. If a cache exists,
the request starts at the earlier of its first date and `--from`. This full
rewrite keeps revised `Adj_Close` values consistent after dividends and
splits.

### Price adjustments

The Taiwan price cache contains raw prices. The dividend file stores `after_price / before_price` for each event. During a run, `bt` applies all later event factors to each earlier open, high, low, and close value. It does not adjust volume.

`bt fetch` also downloads split, capital-reduction, and par-value-change
reference prices for Taiwan symbols into `<symbol>.events.csv`. Each row
holds the event date and the exact price factor. `bt` applies these
factors together with the dividend factors during the same load step. If
the file is missing, `bt` prints a warning and loads unadjusted prices.

The US cache contains both close and adjusted close values. During a run, `bt` multiplies each open, high, low, and close value by `adj_close / close`. It does not adjust volume.

## `bt run`

This command loads one or more strategy files and their cached prices. Each
strategy file selects its data with exactly one
`stock "market/symbol"` statement.

### Run arguments and options

| Argument or option | Description |
| --- | --- |
| `STRAT...` | Read one or more strategies from these files. At least one file is required. The file basename without its extension becomes the strategy name. |
| `--baseline M/SYM` | Add an optional buy-and-hold baseline for this market and symbol. The market must be `tw` or `us`. There is no default baseline. |
| `--from YYYY-MM-DD` | Set the first date to load. The default has no lower limit, so `bt` uses the first cached common date. |
| `--to YYYY-MM-DD` | Set the last date to load. The default has no upper limit, so `bt` uses the last cached common date. |
| `-p name=value` | Override each matching strategy `param` with a float value. Repeat this option for more parameters. The command rejects a name that no strategy declares. |
| `--fill open\|close` | Select the fill mode. The default is `close`. |
| `--capital TWD` | Set the portfolio starting value in TWD. Supplying it enables the per-order minimum fee; the default does not apply a minimum. |
| `--fee-bps F` | Override the fee in basis points for all strategies and the baseline. |
| `--tax-bps F` | Override the sell tax in basis points for all strategies and the baseline. |
| `--slip-bps F` | Override slippage in basis points for all strategies and the baseline. |
| `--min-fee F` | Override the minimum commission per order in TWD for all strategies and the baseline. The minimum applies only with `--capital`. |
| `--financing-rate PERCENT` | Set the annual financing rate. The default is 6.35%. Interest accrues by calendar day as a liability and settles with loan repayment. It does not reduce cash each day. |
| `--maintenance-ratio PERCENT` | Set the maintenance threshold. The default is 130%. Maintenance is total margin inventory value divided by total loans. The engine sells all margin inventories at the next open when maintenance falls below the threshold. Cash inventories remain. |
| `--financing-ratio PERCENT` | Set the fresh-loan financing ratio for every asset and skip stock-info classification. By default, the cache selects 60% for both TWSE and TPEX. Use 50 for TPEX backtests before 2014-11-10. |
| `--data-dir DIR` | Set the cache directory. The default is `data/`. |
| `--out-dir DIR` | Set the output directory. The default is `out/`. |
| `--out-name NAME` | Set the equity CSV and PNG stem. The default joins the strategy names with `_vs_`. |
| `--no-plot` | Do not run `scripts/plot.py` or create or update the equity PNG. The command still writes the equity CSV and all strategy fill logs. |
| `-h`, `-help`, `--help` | Print the run options to standard output and exit with code 0. |

The three margin options apply to every strategy and the baseline.

The engine keeps separate cash and margin inventories for each asset. Buys use available cash first and take fresh loans only for margin-funded shares. If required down payments exceed available cash, the engine can refinance existing inventories with sell and buy legs. Both legs charge full trading costs. A cash inventory frees the financing ratio per refinanced unit. A margin inventory frees only a positive amount after its loan and interest are repaid.

At a standard margin entry, collateral-only maintenance is 166.7% for both TWSE and TPEX, independent of total exposure. If equity is zero or less at a close, the engine sells all inventories, keeps any unpaid debt, and freezes the account.

Do not pass `--market`, `--symbol`, or `--benchmark-market` to `bt run`.
`--benchmark` was renamed to `--baseline`.
Put the market and symbol in each strategy file. Use `--baseline` only when
you want a separate buy-and-hold comparison.

`--baseline` is shorthand for an always-long target exposure of 1.0. It
adds a report and equity column named `baseline`. Strategy metrics get a
`W` marker when they are equal to or better than the baseline. They get an
`L` marker when they are worse. Higher is better for Total return, CAGR,
Sharpe, and Calmar. Lower is better for MaxDD. The baseline column has no
marker. A run without `--baseline` has no baseline column or markers.

The command applies `--from` and `--to` to every input. It then uses the
exact intersection of trading dates across all strategies and the optional
baseline. This rule gives every report column the same dates. The command
stops if fewer than two common dates remain.

Strategy names must be unique. For example, `one/a.strat` and
`two/a.strat` both have the name `a`, so the command reports
`run: duplicate strat basename "a"`. If you use `--baseline`, a strategy
file with the basename `baseline` reports
`run: strat basename "baseline" conflicts with --baseline`.

### Cost defaults

One basis point is 0.01%. One hundred basis points are 1%.

| Market and symbol | Fee | Minimum fee | Sell tax | Slippage |
| --- | --- | --- | --- | --- |
| US | 0 bps (0%) | 0 TWD | 0 bps (0%) | 0 bps (0%) |
| Taiwan ordinary bond ETF (symbol starts with `00` and ends with `B`) | 3.99 bps (0.0399%) | 20 TWD per order | 0 bps (0%) through 2026-12-31 | 0 bps (0%) |
| Other Taiwan symbol that starts with `00`, or an ETN that starts with `02` | 3.99 bps (0.0399%) | 20 TWD per order | 10 bps (0.10%) | 0 bps (0%) |
| Other Taiwan symbol | 3.99 bps (0.0399%) | 20 TWD per order | 30 bps (0.30%) | 0 bps (0%) |

Leveraged and inverse bond ETFs end in `L` or `R`, not `B`, so they use the 10 bps ETF rate.

An exposure increase pays the commission and slippage. An exposure decrease
pays the commission, sell tax, and slippage. Commission is proportional to
the absolute exposure change. When `--capital` is given, each order instead
pays the greater of that proportional commission and the minimum fee. Without
`--capital`, the minimum is ignored. Sell tax and slippage remain proportional.
The four cost options override the applicable defaults for every strategy and
the baseline; `--min-fee 0` disables the minimum.

### Fill modes

With `--fill close`, the target for a bar fills at the close of that bar.
The old exposure earns the close-to-close return before the fill. The
command applies fill costs at that close. This mode is the default.

With `--fill open`, the target for a bar fills at the next bar's open. The
old exposure earns the return from the previous close to that open. The new
exposure then earns the return from the open to the close. If the target
does not change, the current exposure earns the full close-to-close return.

The engine closes a final open exposure at the last close in both modes. It
applies the fee, sell tax, and slippage to this close.

## Run outputs

`bt run` prints a report table to standard output. The table has one column
for each strategy and, when requested, one baseline column. It shows Total
return, CAGR, Sharpe, MaxDD, and Calmar. The lines below the table show each
strategy's trade count and win rate, the common date range, and the fill
mode.

If a strategy had a loan on at least one bar, `bt run` also prints a margin line with the financing rate, minimum maintenance, margin-call count, refinance count, and clamp count:

```text
channel_ladder: margin — financing 6.35%/yr, min maintenance 145.20%, margin calls 1, refinances 3, clamps 0
```

A strategy that never had a loan has no margin line.

The default stem joins strategy names in argument order with `_vs_`. For
example, `bt run a.strat b.strat` uses the stem `a_vs_b`. A single strategy
uses its name as the stem. The optional baseline does not change the stem.
`--out-name NAME` replaces this default stem.

The command writes these files under `--out-dir`:

| File | Content |
| --- | --- |
| `<stem>.csv` | All equity curves. The header is `date`, each strategy name in argument order, and `baseline` when requested. |
| `<name>.trades.csv` | One fill log for each strategy. The header is `date,stock,price,from_exposure,to_exposure`. It has one row per fill per stock. The command does not write a baseline fill log. |
| `<stem>.png` | The equity graph. The command does not create or update this file with `--no-plot`. |

`--out-name` changes only `<stem>.csv` and `<stem>.png`. It does not change
`<name>.trades.csv`.

To create the equity graph, `bt` runs `scripts/plot.py` directly; it does not
copy the script into the output directory. `python3` and matplotlib are
optional. If either is unavailable or plotting otherwise fails, the command
prints `warning: plot failed; skipping <stem>.png` to standard error and exits
with code 0 after it saves the CSV files.

## Help

Use any of these top-level forms:

```text
bt --help
bt -h
bt help
```

Each form prints the command summary to standard output and exits with code 0. Run `bt` with no arguments to print the same summary to standard error and exit with code 2.

Use `-h`, `-help`, or `--help` after `bt fetch` or `bt run`. Each form lists all options for that subcommand and exits with code 0.

## Exit codes

| Code | Meaning |
| --- | --- |
| 0 | The command succeeded, or it printed requested help. |
| 1 | A runtime operation failed. Examples include a missing token, a missing cache file, invalid cached data, or a failed required download. A plot failure is not a runtime failure. |
| 2 | The command line has a usage error. Examples include an unknown subcommand, a missing required argument, or an invalid option. |
