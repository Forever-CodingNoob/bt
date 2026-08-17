# CLI reference

`bt` downloads market data and runs backtests from the command line.

## Command syntax

```text
bt fetch --market tw|us --symbol SYM [--from YYYY-MM-DD] [--to YYYY-MM-DD] [--data-dir DIR]
bt run STRAT_FILE --market tw|us --symbol SYM [--from D] [--to D]
       [--benchmark SYM] [--benchmark-market tw|us] [-p name=value ...]
       [--fill open|close] [--fee-bps F] [--tax-bps F] [--slip-bps F]
       [--data-dir DIR] [--out-dir DIR] [--no-plot]
```

## `bt fetch`

This command downloads price data from FinMind. It stores the data in a local CSV cache.

### Fetch options

| Option | Description |
| --- | --- |
| `--market tw\|us` | Select the Taiwan or US market. This option is required. |
| `--symbol SYM` | Select the FinMind symbol. This option is required. |
| `--from YYYY-MM-DD` | Set the first date to request. The default is `2010-01-01`. |
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
| US | `data/us/SYM.csv` | `date,open,high,low,close,adj_close,volume` |

Replace `data/` with the value of `--data-dir` when you set that option.

For Taiwan prices, `bt fetch` appends rows after the last cached date. It does not add an existing date again. It fetches the full Taiwan dividend history and rewrites `SYM.div.csv` on each run. If this fetch fails, the command keeps the existing dividend file. If no file exists, the command warns that prices will be unadjusted for dividends.

For US prices, `bt fetch` rewrites `SYM.csv` on each run. If a cache exists, the request starts at the earlier of its first date and `--from`. This full rewrite keeps revised `Adj_Close` values consistent after dividends and splits.

### Price adjustments

The Taiwan price cache contains raw prices. The dividend file stores `after_price / before_price` for each event. During a run, `bt` applies all later event factors to each earlier open, high, low, and close value. It does not adjust volume.

`bt` also checks Taiwan prices for splits and capital reductions. It treats a close-to-close change above 25% in absolute value as an event. It uses the event open divided by the previous close as the factor. It applies this factor during the same load step.

The US cache contains both close and adjusted close values. During a run, `bt` multiplies each open, high, low, and close value by `adj_close / close`. It does not adjust volume.

## `bt run`

This command loads a strategy and cached prices. It compares the strategy with a benchmark.

### Run argument and options

| Argument or option | Description |
| --- | --- |
| `STRAT_FILE` | Read the strategy from this file. Supply one file. This argument is required. |
| `--market tw\|us` | Select the market for the strategy symbol. This option is required. |
| `--symbol SYM` | Select the strategy symbol. This option is required. |
| `--from YYYY-MM-DD` | Set the first date to load. The default has no lower limit, so `bt` uses the first cached date. |
| `--to YYYY-MM-DD` | Set the last date to load. The default has no upper limit, so `bt` uses the last cached date. |
| `--benchmark SYM` | Select the benchmark symbol. The default is `00685L`. |
| `--benchmark-market tw\|us` | Select the benchmark market. The default is `tw`. |
| `-p name=value` | Override a strategy `param` with a float value. Repeat this option for more parameters. The command rejects an unknown parameter. |
| `--fee-bps F` | Override the fee in basis points. |
| `--tax-bps F` | Override the sell tax in basis points. |
| `--slip-bps F` | Override slippage in basis points. |
| `--fill open\|close` | Select the fill mode. The default is `close`. |
| `--data-dir DIR` | Set the cache directory. The default is `data/`. |
| `--out-dir DIR` | Set the output directory. The default is `out/`. |
| `--no-plot` | Do not create or update `plot.py` and `equity.png`. The command still writes both CSV files. |
| `-h`, `-help`, `--help` | Print the run options to standard output and exit with code 0. |

The command limits benchmark data to the strategy date range. It then uses only dates that exist for both symbols.

### Cost defaults

One basis point is 0.01%. One hundred basis points are 1%.

| Market and symbol | Fee | Sell tax | Slippage |
| --- | --- | --- | --- |
| US | 0 bps (0%) | 0 bps (0%) | 0 bps (0%) |
| Taiwan symbol that starts with `00` | 14.25 bps (0.1425%) | 10 bps (0.10%) | 0 bps (0%) |
| Other Taiwan symbol | 14.25 bps (0.1425%) | 30 bps (0.30%) | 0 bps (0%) |

An exposure increase pays the fee and slippage. An exposure decrease pays the fee, sell tax, and slippage. The cost is proportional to the absolute exposure change. The three cost options override the applicable defaults for both the strategy and the benchmark.

### Fill modes

With `--fill close`, the target for a bar fills at the close of that bar. The old exposure earns the close-to-close return before the fill. The command applies fill costs at that close. This mode is the default.

With `--fill open`, the target for a bar fills at the next bar's open. The old exposure earns the return from the previous close to that open. The new exposure then earns the return from the open to the close. If the target does not change, the current exposure earns the full close-to-close return.

The engine closes a final open exposure at the last close in both modes. It applies the fee, sell tax, and slippage to this close.

## Run outputs

`bt run` prints a report table to standard output. The table shows Total return, CAGR, Sharpe, MaxDD, and Calmar for the strategy and benchmark. It also shows a WIN or LOSS verdict. The lines below the table show the trade count, win rate, date range, and fill mode.

The command writes these files under `--out-dir`:

With the default directory, the paths are `out/equity.csv`, `out/trades.csv`, `out/plot.py`, and `out/equity.png`.

| File | Content |
| --- | --- |
| `equity.csv` | The strategy and benchmark equity curves. The header is `date,strategy,benchmark`. |
| `trades.csv` | The strategy fill log. The header is `date,price,from_exposure,to_exposure`. Each row records one exposure change. |
| `plot.py` | The Python script that reads `equity.csv` and makes the graph. The command does not write this file with `--no-plot`. |
| `equity.png` | The equity graph. The command does not write this file with `--no-plot`. |

A plot failure does not fail the backtest. The command prints `warning: plot failed; skipping equity.png` to standard error and exits with code 0 after it saves the CSV files.

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
