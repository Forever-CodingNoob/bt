# CLI reference

`bt` downloads market data and runs backtests from the command line.

## Contents

- [Command syntax](#command-syntax)
- [`bt fetch`](#bt-fetch)
  - [Fetch options](#fetch-options)
  - [API tokens](#api-tokens)
  - [Cache files](#cache-files)
  - [Price adjustments](#price-adjustments)
- [`bt daytrade`](#bt-daytrade)
  - [Daytrade options](#daytrade-options)
  - [Data requirements](#data-requirements)
  - [Intraday output fields](#intraday-output-fields)
  - [Rejected flags](#rejected-flags)
- [`bt target`](#bt-target)
  - [US market](#us-market)
    - [Prerequisites](#prerequisites)
    - [Options](#options)
    - [Environment](#environment)
    - [Decision cycle](#decision-cycle)
    - [Output](#output)
    - [Failure handling](#failure-handling)
  - [Taiwan market](#taiwan-market)
    - [Prerequisites](#prerequisites-1)
    - [Options](#options-1)
    - [Environment](#environment-1)
    - [Decision cycle](#decision-cycle-1)
    - [Output](#output-1)
    - [Failure handling](#failure-handling-1)
- [`bt live`](#bt-live)
  - [US market](#us-market-1)
    - [Prerequisites](#prerequisites-2)
    - [Options](#options-2)
    - [Environment](#environment-2)
    - [Decision cycle](#decision-cycle-2)
    - [Output and logs](#output-and-logs)
    - [Failure handling](#failure-handling-2)
  - [Taiwan market](#taiwan-market-1)
    - [Prerequisites](#prerequisites-3)
    - [Options](#options-3)
    - [Environment](#environment-3)
    - [Decision cycle](#decision-cycle-3)
    - [Output and logs](#output-and-logs-1)
    - [Failure handling](#failure-handling-3)
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
bt fetch us/SYM --bars 1m [--data-dir DIR]
bt run STRAT... [--baseline M/SYM] [--from D] [--to D]
       [-p name=value ...] [--fill open|close]
       [--fee-bps F] [--tax-bps F] [--slip-bps F] [--min-fee F]
       [--financing-rate PERCENT] [--maintenance-ratio PERCENT]
       [--financing-ratio PERCENT] [--loan-term-months N] [--dividend-tax PERCENT]
       [--capital TWD] [--data-dir DIR] [--out-dir DIR] [--out-name NAME] [--no-plot]
bt daytrade STRAT... [--baseline us/SYM] [--fill open|close] [--leverage N] [--from YYYY-MM-DD] [--to YYYY-MM-DD] [-p name=value] [--capital USD] [--fee-bps F] [--tax-bps F] [--slip-bps F] [--per-share-fee F] [--per-share-cap F] [--data-dir DIR] [--out-dir DIR] [--out-name NAME] [--no-plot]
bt target STRAT [--live] [--equity TWD] [--data-dir DIR] [--provisional-close PRICE]
bt live STRAT [--live] [--equity TWD] [--data-dir DIR]
```

## `bt fetch`

Downloads price data and stores it in a local CSV cache. Taiwan data comes from [FinMind](https://finmind.github.io). US data comes from [Tiingo](https://www.tiingo.com). Use the positional form for new commands. The separate `--market` and `--symbol` options are an equivalent form.

### Fetch options

| Argument or option | Default | Description |
|---|---|---|
| `MARKET/SYMBOL` | - | Select one market and symbol, for example `tw/0050`. The market must be `tw` or `us`. Use this argument or use both options below. |
| `--market tw\|us` | - | Select the Taiwan or US market when you do not use the positional argument. |
| `--symbol SYM` | - | Select the symbol when you do not use the positional argument. |
| `--from YYYY-MM-DD` | `1994-10-01` | Set the first date to request. |
| `--to YYYY-MM-DD` | today | Set the last date to request. |
| `--data-dir DIR` | `data/` | Set the cache directory. |
| `--bars 1m` | daily | Fetch US regular-session SIP minute bars from Alpaca; other resolutions are rejected. |
| `-h`, `-help`, `--help` | - | Print the fetch options to standard output and exit with code 0. |

### API tokens

Set the environment variable for the market you use before running `bt fetch`.

```sh
export FINMIND_TOKEN="your_finmind_token"   # for tw
export TIINGO_TOKEN="your_tiingo_api_token" # for us
```

The command stops with code 1 if the required token is missing or empty.

### Cache files

| Market | File | Header |
|---|---|---|
| Taiwan | `data/tw/SYM/SYM.csv` | `date,open,high,low,close,volume` |
| Taiwan | `data/tw/SYM/SYM.div.csv` | `date,factor` |
| Taiwan | `data/tw/SYM/SYM.cashdiv.csv` | `ex_date,cash_per_share,pay_date` |
| Taiwan | `data/tw/SYM/SYM.events.csv` | `date,factor` |
| Taiwan | `data/tw/stockinfo.csv` | `stock_id,type,date` |
| US | `data/us/SYM/SYM.csv` | `date,open,high,low,close,volume` |
| US | `data/us/SYM/SYM.div.csv` | `date,factor` |
| US | `data/us/SYM/SYM.cashdiv.csv` | `ex_date,cash_per_share,pay_date` |
| US | `data/us/SYM/SYM.events.csv` | `date,factor` |
| US minute | `data/us/SYM/1m/YYYY.csv` | `time,open,high,low,close,volume` |
| US calendar | `data/us/calendar.csv` | `date,open,close` |

Replace `data/` with the value of `--data-dir` when you set that option.

> [!TIP]
> A plain fetch updates an existing TW cache forward only. Pass an explicit `--from` earlier than the cache start to backfill.

For both markets, `bt fetch` adds data at both ends of the cache. If `--from` is earlier than the first cached date, it fetches the missing earlier range and prepends it. It also fetches dates after the last cached date and appends them. Cached rows win at both boundaries. A repeated fetch is idempotent.

For Taiwan, the command fetches the full dividend-factor history and rewrites `SYM.div.csv` on each run, fetches cash dividends into `SYM.cashdiv.csv`, and fetches split, capital-reduction, and par-value-change events into `SYM.events.csv`. If the source omits a pay date, the loader uses one calendar month after the ex-date.

> [!WARNING]
> If the FinMind cash-dividend API returns status 400, 402, or 403, `bt fetch` derives cash from the legacy dividend factors and treats every factor as cash-only. This is exact for cash-only TW ETFs but can misprice stocks that also pay stock dividends.

Other fetch failures keep an existing cash-dividend file; without one, `bt run` warns and continues without cash credits.

For every Taiwan fetch, the command also downloads the `TaiwanStockInfo` table and rewrites `data/tw/stockinfo.csv`. It keeps only `twse` and `tpex` rows. If this fetch fails, the command keeps the existing stock-info cache. An unknown symbol or a missing cache makes `bt run` warn and use the TWSE financing ratio of 60%.

> [!WARNING]
> The stock-info table selects the standard exchange ratio only. The engine assumes every Taiwan symbol is marginable and does not check broker eligibility or reduced ratios. Leveraged ETFs such as 00685L have historically been excluded from margin financing or assigned reduced ratios.

For US, the command derives all four files from one Tiingo response: raw prices, signal-plane dividend factors, cash dividends (credited at the ex-date; Tiingo provides no pay date), and split events. Split factors are snapped to the nearest small rational to remove vendor floating-point noise.

### Price adjustments

The engine loads two price series for every asset. The signal series includes cash-dividend and corporate-event adjustments; the DSL evaluates indicators and rules on this series. The money series includes split, capital-reduction, par-value-change, and stock-dividend adjustments but leaves cash-dividend drops in place. The engine uses the money series for fills, inventory, loans, collateral, and equity.

For Taiwan, `<symbol>.div.csv` supplies the full dividend adjustment to the signal series and `<symbol>.cashdiv.csv` separates the cash component for the money series and ledger. `<symbol>.events.csv` supplies exact split, capital-reduction, and par-value-change factors to both price series. Share-count event factors also restate earlier volume to the post-event share basis. Cash-dividend factors do not change volume.

For US assets, `<symbol>.div.csv` supplies the dividend adjustment to the signal series and `<symbol>.cashdiv.csv` separates the cash component for the money series and ledger. `<symbol>.events.csv` supplies exact split factors to both price series and restates earlier volume to the post-split share basis.

## `bt daytrade`

Runs one or more single-stock US strategies on cached regular-session minute bars.

### Daytrade options

| Argument or option | Default | Description |
|---|---|---|
| `STRAT...` | required | Each file declares one unaliased US stock and `bars Nm`; basenames must be unique. |
| `--baseline us/SYM` | none | Daily Tiingo buy-and-hold on the common session dates. |
| `--fill open\|close` | `open` | Next-bar open or same-bar close decisions; session liquidation always uses the last close. |
| `--leverage N` | `1.0` | Positive finite previous-close buying-power multiplier. |
| `--from D`, `--to D` | all cached dates | Inclusive date bounds. |
| `-p name=value` | strategy defaults | Override a declared parameter. |
| `--capital USD` | none | Positive starting dollar value for dollar-based costs; sizing remains fractional exposure units. |
| `--fee-bps F` | `0` | Commission on each side. |
| `--tax-bps F` | `0.206` | Sell-side SEC fee in basis points. |
| `--slip-bps F` | `0` | Slippage on each side. |
| `--per-share-fee F` | `0.000195` | Dollar sell fee per share when capital is supplied. |
| `--per-share-cap F` | `9.79` | Dollar cap per sell order. |
| `--data-dir DIR` | `data/` | Minute, calendar, and optional daily baseline cache root. |
| `--out-dir DIR` | `out/` | Output directory. |
| `--out-name NAME` | joined strategy names | Equity and plot filename stem; trade logs retain each strategy basename. |
| `--no-plot` | off | Skip `scripts/plot.py`. |
| `-h`, `-help`, `--help` | - | Print usage and exit successfully. |

### Data requirements

```sh
bt fetch us/SPY --bars 1m --data-dir data
bt fetch us/SPY --data-dir data
bt daytrade examples/daytrade_orb.strat --baseline us/SPY --data-dir data --from 2026-01-01
```

Minute fetches require `APCA_API_KEY_ID` and `APCA_API_SECRET_KEY`; daily US fetches require `TIINGO_TOKEN`. Minute fetch refreshes the calendar from 2016 through today, requests SIP history through now minus 16 minutes, paginates in year ranges, and resumes from the last cached minute (2016 for an empty cache). Failed requests retain cached data. Timestamps are ET left edges with DST conversion; only calendar regular hours are retained.

> [!IMPORTANT]
> Strategies and the optional daily baseline are intersected by session date before evaluation. At least two common dates are required. Calendar sessions with no bars are omitted. Minute bars are not replaced by daily bars.

### Intraday output fields

| Output | Fields |
|---|---|
| `<stem>.csv` | Same per-date equity columns as `bt run`, one observation per session close, including optional baseline. |
| `<strategy>.trades.csv` | `time,stock,price,from_exposure,to_exposure`; execution timestamps identify the bar's left edge, including forced-close fills. |
| `<stem>.png` | Session-equity plot unless disabled. |
| Metric table | Total return, CAGR, Sharpe, MaxDD, Calmar, with daily annualization. |
| Strategy line | `sessions`, flat-to-flat `trades`, net-cost `win rate`, and `flat-forced` session count. |

### Rejected flags

| Flag | Reason |
|---|---|
| `--financing-rate` | No overnight financing. |
| `--maintenance-ratio` | No intraday maintenance model. |
| `--loan-term-months` | No term loans. |
| `--dividend-tax` | No overnight dividend holdings. |

These flags are usage errors (exit 2). `bt run`, `bt target`, and `bt live` reject `bars` strategies with `day trading strategies run under bt daytrade`; this command does not place live trades.

## `bt target`

Runs one US Alpaca or TW Shioaji decision, simulation or production, and prints the proposed action without submitting an order.

The following options are shared by both market arms.

| Argument or option | Default | Description |
|---|---|---|
| `STRAT` | - | Read one strategy containing exactly one US or TW stock declaration. |
| `--data-dir DIR` | `data/` | Set the Tiingo or FinMind cache directory selected by the strategy market. |
| `--provisional-close PRICE` | - | Use a positive PRICE for a local provisional bar instead of the broker snapshot. The output is marked `provisional: override PRICE`. |
| `-h`, `-help`, `--help` | - | Print the target options and exit with code 0. |

> [!TIP]
> Use `--provisional-close PRICE` for a dry run when a current broker snapshot is unavailable or unsuitable.

Both market arms write these fields, one per line.

| Field | Meaning |
|---|---|
| `provisional` | Report `override PRICE` when `--provisional-close` supplies the provisional bar. |
| `fetched-through` | Show the last historical date fetched from Tiingo or FinMind. |
| `provisional-date` | Show the provisional bar's date. |
| `provisional-open` | Show the provisional bar's open. |
| `provisional-high` | Show the provisional bar's high. |
| `provisional-low` | Show the provisional bar's low. |
| `provisional-close` | Show the provisional bar's close. |
| `provisional-volume` | Show the provisional bar's volume. |
| `target` | Show the exposure selected by the strategy. |
| `equity` | Show the account equity used to size the decision. |
| `held` | Show the current share position. |

> [!IMPORTANT]
> `bt target` prints the proposed action but never submits an order, even with `--live`.

### US market

#### Prerequisites

The strategy must declare exactly one US stock. The command needs Tiingo history and access to the selected Alpaca paper or live account.

#### Options

| Option | Default | Description |
|---|---|---|
| `--live` | paper | Select the live Alpaca endpoint. |

`--equity` is rejected for US strategies.

#### Environment

| Variable | Default | Purpose |
|---|---|---|
| `TIINGO_TOKEN` | - | Authenticate the Tiingo history request. |
| `APCA_API_KEY_ID` | - | Identify the selected paper or live Alpaca account. |
| `APCA_API_SECRET_KEY` | - | Authenticate the selected paper or live Alpaca account. |

The Alpaca key variables must contain credentials for the selected account.

#### Decision cycle

The command fetches Tiingo history through Alpaca's previous daily bar, appends Alpaca's current snapshot as a provisional bar, and evaluates the strategy through the same DSL compiler used by `bt run`.

#### Output

The US arm adds these fields to the shared output.

| Field | Meaning |
|---|---|
| `action` | Report `order` or `skip`. |
| `side` | Report `buy` or `sell` for an order. |
| `quantity` | Report the whole-share quantity for an order. |
| `client-order-id` | Report the deterministic order identifier. |
| `reason` | Explain a skipped action. |

#### Failure handling

An unavailable account, stale cache or snapshot, failed history fetch, or strategy evaluation error fails the decision without submitting an order.

> [!WARNING]
> The free Alpaca IEX feed can produce a provisional price that differs from the consolidated tape. Alpaca paper accounts also do not simulate dividends, so paper cash and equity can diverge from a live account.

### Taiwan market

#### Prerequisites

The strategy must declare exactly one TW stock. Install the official `shioaji` command, create the server `.env`, and start `shioaji server start`.

The official server reads this `.env` from the directory where it starts:

```dotenv
SJ_API_KEY=YOUR_API_KEY
SJ_SEC_KEY=YOUR_SECRET_KEY
SJ_CA_PATH=your/ca/path/Sinopac.pfx
SJ_CA_PASSWD=YOUR_CA_PASSWORD
SJ_PRODUCTION=false
```

`SJ_API_KEY` and `SJ_SEC_KEY` let the server log in to Shioaji. Copies in the `bt` environment are optional: `bt` sends a Bearer header only when both are set and nonempty, for servers that enforce Bearer authentication. `SJ_CA_PATH` and `SJ_CA_PASSWD` activate the certificate required for production order placement, and `SJ_PRODUCTION=false` or an unset value selects simulation while `true` selects production. The CA path, CA password, and production setting remain server-only.

#### Options

TW production sizes from broker balance, signed T+1 and T+2 settlements, and Common-lot positions. T+0 is required for settlement-window validation and startup audit but is already reflected in the balance.

| Option | Default | Description |
|---|---|---|
| `--live` | simulation | Request TW production mode and broker-derived sizing. |
| `--equity TWD` | - | Set total account equity for simulation. It is required in simulation and rejected in production. |

| Command mode | Required server mode | Equity source | Current availability |
|---|---|---|---|
| `bt target --equity TWD` | `simulation: true` | User-supplied total equity | Implemented |
| `bt target --live` | `simulation: false` | Broker balance, settlements, and positions | Implemented |

#### Environment

| Variable | Default | Purpose |
|---|---|---|
| `FINMIND_TOKEN` | - | Authenticate history and the independent `TaiwanStockTradingDate` calendar request. |
| `SHIOAJI_URL` | `http://localhost:8080` | Select the official Shioaji HTTP server used for account, snapshot, and order APIs. |
| `SJ_API_KEY` | - | Optional; sent only with `SJ_SEC_KEY` when the server enforces Bearer authentication. |
| `SJ_SEC_KEY` | - | Optional; sent only with `SJ_API_KEY` when the server enforces Bearer authentication. |

The Shioaji server may still need its own keys to log in. `bt` never fails because these optional client credentials are absent or incomplete.

#### Decision cycle

The TW target reads account and snapshot data from Shioaji and historical data from FinMind. It queries `TaiwanStockTradingDate` for the previous session and never treats cached prices as a calendar. It refreshes adjustments through today and rejects stale snapshots or a cache that does not end on the previous session.

On TW, `--provisional-close PRICE` replaces only the snapshot price: the command still checks Shioaji server mode, queries the independent FinMind trading calendar, fetches history, and requires the cache to end on the verified previous session.

The resulting plan preserves cash and margin inventories. It can contain cash sells, margin sells, cash buys, margin buys, and paired sell/rebuy refinancing legs. Dated `MarginTrading` position details that reach the engine's 18-calendar-month, month-end-clamped maturity produce sell/rebuy pairs before ordinary target legs. Every share quantity is floored to a `Common` lot of 1000 shares; the remainder is retained rather than rounded up or sent as an odd-lot order.

Production requires exactly one settlement row for each of T+0, T+1, and T+2 and rejects missing, duplicate, or other T-day rows. Spendable cash is `acc_balance + T+1 + T+2` using each signed amount; T+0 is already reflected in `acc_balance`, so it is validated and logged but not added again. Equity adds all Common-lot positions at broker `last_price`, then subtracts margin loan principal and interest. A real-account probe tracked a TWD -107 purchase payable at T+2 on 2026-09-16 and T+1 on 2026-09-17 while `acc_balance` remained TWD 100,000, then at T+0 on 2026-09-18 when `acc_balance` fell to TWD 99,893. Pending T+1 and T+2 settlements change the daily cash budget without skipping the session.

#### Output

The TW arm adds these fields to the shared output.

| Field | Meaning |
|---|---|
| `action` | Report `orders`. |
| `leg` | Report each leg as `ACTION CONDITION COMMON_LOTS`. |

#### Failure handling

The mode mismatch guard refuses simulation commands against a production server and refuses `--live` against a simulation server.

> [!WARNING]
> `--equity` is user-supplied simulation total equity, not broker cash or an `account_balance` result. With the supported one-stock account shape, `bt` infers simulation cash from equity, the selected symbol's cash and margin inventory values, loan principal, and interest. It rejects a nonzero holding in another symbol.

Production startup logs `acc_balance`, each T-day amount, derived spendable cash, and derived equity. T+0 remains visible for audit even though the verified cash formula excludes it.

## `bt live`

Runs the close-scheduled trading daemon for one US or TW strategy.

The following options are shared by both market arms.

| Argument or option | Default | Description |
|---|---|---|
| `STRAT` | - | Read one strategy containing exactly one US or TW stock declaration. |
| `--data-dir DIR` | `data/` | Set the Tiingo or FinMind cache directory selected by the strategy market. |
| `-h`, `-help`, `--help` | - | Print the live options and exit with code 0. |

Logs are append-only ASCII text. Both daemons record the session date, fetched-through date, provisional close, target, equity, held position, action or skip reason, and fill state and price.

### US market

#### Prerequisites

The strategy must declare exactly one US stock. The selected Alpaca account must be active and not trading-blocked.

#### Options

| Option | Default | Description |
|---|---|---|
| `--live` | paper | Select the live Alpaca endpoint and permit real-money market-on-close orders. |

`--equity` is rejected for US strategies.

#### Environment

| Variable | Default | Purpose |
|---|---|---|
| `TIINGO_TOKEN` | - | Authenticate Tiingo history requests. |
| `APCA_API_KEY_ID` | - | Identify the selected paper or live Alpaca account. |
| `APCA_API_SECRET_KEY` | - | Authenticate the selected paper or live Alpaca account. |

Startup prints the mode, account number, and equity.

#### Decision cycle

The daemon derives every phase from Alpaca's `next_close`.

| Phase | Timing | Action |
|---|---|---|
| Evaluate | 15 minutes before the close | Refresh Tiingo history and evaluate the provisional daily bar. |
| Submit | By 10 minutes before the close | Query today's deterministic client order ID, then submit a whole-share market-on-close order when needed. |
| Reconcile | After the close | Log the fill. |
| Sleep | After reconciliation | Sleep until the next open. |

#### Output and logs

The US log records held shares, the deterministic order or skip reason, and the reconciled fill. Startup also records the selected mode, account number, and equity.

#### Failure handling

An inactive or trading-blocked account is refused at startup. A stale cache, fetch or snapshot error, evaluation error, or order failure logs one error line and stops the US action for the day.

> [!CAUTION]
> `bt live --live` submits real-money market-on-close orders. Confirm the credentials, account, and strategy before starting it.

> [!WARNING]
> The free Alpaca IEX feed can produce a provisional price that differs from the consolidated tape. Alpaca paper accounts also do not simulate dividends, so paper cash and equity can diverge from a live account.

> [!IMPORTANT]
> The US path recomputes desired shares from the account and stops after a failed prerequisite or order.

> [!NOTE]
> The US path queries the deterministic client order ID before submission. This reduces duplicate risk but is not an exactly-once guarantee for concurrent processes.

### Taiwan market

#### Prerequisites

Install the official `shioaji` command, create the server `.env` shown in the TW target section, and start `shioaji server start`. The strategy must declare exactly one TW stock.

#### Options

Production uses broker-derived cash and equity; see [Safety and failure in the TW live-trading design](./specs/tw-live-trading.md#safety-and-failure).

| Option | Default | Description |
|---|---|---|
| `--live` | simulation | Request TW production mode and broker-derived sizing. |
| `--equity TWD` | - | Set finite positive total account equity for simulation. It is required in simulation and rejected in production. |

#### Environment

| Variable | Default | Purpose |
|---|---|---|
| `FINMIND_TOKEN` | - | Authenticate history and independent trading-calendar requests. |
| `SHIOAJI_URL` | `http://localhost:8080` | Select the official Shioaji HTTP server. |
| `SJ_API_KEY` | - | Optional; sent only with `SJ_SEC_KEY` when the server enforces Bearer authentication. |
| `SJ_SEC_KEY` | - | Optional; sent only with `SJ_API_KEY` when the server enforces Bearer authentication. |

The Shioaji server may still need its own keys to log in. `bt` never fails because these optional client credentials are absent or incomplete. `SJ_CA_PATH`, `SJ_CA_PASSWD`, and `SJ_PRODUCTION` remain server-only.

#### Decision cycle

| Phase | Taipei timing | Implemented TW action |
|---|---|---|
| Prepare | 13:05 | Check that a snapshot is dated today, query FinMind's independent trading calendar for the previous session, fetch prices through that session, refresh adjustment datasets through today, and require an exact price-cache end date. |
| Decide | 13:20 | Request a fresh snapshot, validate its session and OHLCV values, append the provisional bar, evaluate the final and previous effective targets, read Common-lot aggregate positions and dated margin details, derive simulation or production cash and equity, prepend due 18-month rollover pairs, and plan ordinary cash, margin, and refinancing legs in absolute TWD. An unchanged effective target preserves drift; a changed target trades from current inventory. |
| Execute | Before 13:25 | Floor shares to 1000-share Common lots and submit `MKT` + `IOC` legs sequentially. Recheck the date and cutoff immediately before every order and during every status poll. |
| Reconcile | After 13:30 | Query and log today's resulting trades, including fill status, deal lots, and weighted deal price. |

Every successor leg requires the previous order to be uniquely identified and completely filled at a finite positive weighted price. A refinance sell and rebuy are sequential dependent orders, not an atomic broker operation. The rebuy runs only after the full sell is confirmed and only when its complete original lot count is funded. An ordinary buy may be floored to the confirmed cash budget; if capped, its remainder and every later leg stay unsubmitted.

#### Output and logs

The TW log records held Common lots, planned cash, margin, and refinance legs, retained board-lot remainders, every observed fill, and resulting exposure. Production startup also records `acc_balance`, T+0, T+1, T+2, spendable cash, and equity. Reconciliation includes fill status, deal lots, and weighted deal price.

#### Failure handling

The mode mismatch guard requires simulation commands to see `info.simulation = true` and `--live` to see `info.simulation = false`. The daemon re-reads server info at the start of each unsubmitted daily Decide phase; if the server mode changed after startup, it logs the mismatch and skips the day's action before any order can be submitted. Partial, missing, ambiguous, mismatched, failed, inactive, rejected, cancelled, timed-out, cutoff, or uncertain POST results stop all later legs.

No execution path guarantees exactly once across concurrent daemon processes or every crash timing; the pre-submit query only reduces duplicate risk.

> [!WARNING]
> Simulation equity is a user-supplied sizing input. Board-lot flooring, real MKT fills, the spread, partial or cancelled IOC quantities, broker margin rules, settlements, and concurrent processes can make TW daemon execution differ from a daily close-fill backtest.

> [!IMPORTANT]
> A stale cache, fetch or snapshot error, evaluation error, or order failure logs one error line and stops the TW action for the day. TW never submits a successor after an unconfirmed predecessor.

> [!NOTE]
> The TW path queries today's orders before planning and carries only confirmed fills between legs. This reduces duplicate risk but is not an exactly-once guarantee for concurrent processes.

Pending T+1 and T+2 settlements never suppress a production session; their signed amounts alter the available cash passed to the unchanged planner and executor. T+0 remains required and logged but is already reflected in `acc_balance`.

## `bt run`

Loads one or more strategy files and their cached prices. Each strategy file selects its data with exactly one `stock "market/symbol"` statement.

> [!IMPORTANT]
> `--benchmark` was renamed to `--baseline`. Do not pass `--market`, `--symbol`, or `--benchmark-market` to `bt run`. Put the market and symbol in each strategy file.

### Run arguments and options

| Argument or option | Default | Description |
|---|---|---|
| `STRAT...` | - | Read one or more strategies from these files. At least one file is required. The file basename without its extension becomes the strategy name. |
| `--baseline M/SYM` | - | Add a buy-and-hold baseline for this market and symbol. |
| `--from YYYY-MM-DD` | first cached common date | Set the first date to load. |
| `--to YYYY-MM-DD` | last cached common date | Set the last date to load. |
| `-p name=value` | - | Override each matching strategy `param` with a float value. Repeat for more parameters. The command rejects a name that no strategy declares. |
| `--fill open\|close` | `close` | Select the fill mode. |
| `--capital TWD` | - | Set the portfolio starting value in TWD. Enables the per-order minimum fee. |
| `--fee-bps F` | per market | Override the fee in basis points for all strategies and the baseline. |
| `--tax-bps F` | per symbol class | Override the sell tax in basis points for all strategies and the baseline. |
| `--slip-bps F` | `0` | Override slippage in basis points for all strategies and the baseline. |
| `--min-fee F` | `20` (with `--capital`) | Override the minimum commission per order in TWD. Applies only with `--capital`. |
| `--dividend-tax PERCENT` | `0` | Reduce every TW receivable and US cash dividend at creation. Represents dividend income tax and the NHI supplementary premium. |
| `--financing-rate PERCENT` | TW 6.35, US 6.25 | Set the annual financing rate. |
| `--maintenance-ratio PERCENT` | TW 130 (collateral/loan), US tiered | Set a flat maintenance threshold for either market. When unset, TW uses 130% collateral over loan and US uses the tiered table (100% below $2.50, 50% $2.50-$6, 30% above $6). |
| `--per-share-fee F` | US 0.000195, TW 0 | Override the per-share sell fee in dollars. Applies only with `--capital`. |
| `--per-share-cap F` | US 9.79, TW 0 | Override the per-share sell fee cap in dollars per order. Use 0 for uncapped. Applies only with `--capital`. |
| `--financing-ratio PERCENT` | TW 60, US 50 | Set the fresh-loan financing ratio for every asset. TW defaults from cached stockinfo (TWSE/TPEX 60%). US defaults to the Reg T initial-margin ratio of 50%. |
| `--loan-term-months N` | `18` | Set the TW margin-loan term in calendar months. Use 0 for open-ended TW loans. US loans are always open-ended. |
| `--data-dir DIR` | `data/` | Set the cache directory. |
| `--out-dir DIR` | `out/` | Set the output directory. |
| `--out-name NAME` | strategy names joined with `_vs_` | Set the equity CSV and PNG stem. |
| `--no-plot` | - | Do not run the plot script or update the equity PNG. |
| `-h`, `-help`, `--help` | - | Print the run options to standard output and exit with code 0. |

> [!NOTE]
> The four margin options and `--dividend-tax` apply to every strategy and the baseline. US assets ignore `--loan-term-months`.

For the full margin and dividend engine guide, see [engine.md](./engine.md).

The command applies `--from` and `--to` to every input. It then uses the exact intersection of trading dates across all strategies and the optional baseline. This rule gives every report column the same dates. The command stops if fewer than two common dates remain.

> [!IMPORTANT]
> Strategy names must be unique. `one/a.strat` and `two/a.strat` both have the name `a` and produce a duplicate-basename error. A strategy with the basename `baseline` conflicts with `--baseline`.

`--baseline` is shorthand for an always-long target exposure of 1.0. It adds a report and equity column named `baseline`. Strategy metrics get a `W` marker when they are equal to or better than the baseline and an `L` marker when they are worse. Higher is better for Total return, CAGR, Sharpe, and Calmar. Lower is better for MaxDD.

### Cost defaults

One basis point is 0.01%. One hundred basis points are 1%.

| Market and symbol | Fee | Minimum fee | Sell tax | Per-share sell fee | Slippage |
|---|---|---|---|---|---|
| US | 0 bps (0%) | - | 0.206 bps (SEC fee, effective 2026-04-04) | $0.000195/share, $0.01 floor, $9.79 cap (TAF, effective 2026-01-01) | 0 bps (0%) |
| Taiwan ordinary bond ETF (`00...B`) | 3.99 bps (0.0399%) | 20 TWD per order | 0 bps (0%) through 2026-12-31 | - | 0 bps (0%) |
| Other Taiwan `00` or `02` ETN | 3.99 bps (0.0399%) | 20 TWD per order | 10 bps (0.10%) | - | 0 bps (0%) |
| Other Taiwan symbol | 3.99 bps (0.0399%) | 20 TWD per order | 30 bps (0.30%) | - | 0 bps (0%) |

Leveraged and inverse bond ETFs end in `L` or `R`, not `B`, so they use the 10 bps ETF rate.

An exposure increase pays the commission and slippage. An exposure decrease pays the commission, sell tax, and slippage. Commission is proportional to the absolute exposure change. When `--capital` is given, each order pays the greater of that proportional commission and the minimum fee. Without `--capital`, the minimum is ignored. Sell tax and slippage remain proportional. The four cost options override the applicable defaults for every strategy and the baseline; `--min-fee 0` disables the minimum.

### Fill modes

With `--fill close`, the target for a bar fills at the close of that bar. The old exposure earns the close-to-close return before the fill. The command applies fill costs at that close.

With `--fill open`, the target for a bar fills at the next bar's open. The old exposure earns the return from the previous close to that open. The new exposure then earns the return from the open to the close. If the target does not change, the current exposure earns the full close-to-close return.

The engine closes a final open exposure at the last close in both modes. It applies the fee, sell tax, and slippage to this close.

## Run outputs

`bt run` prints a report table to standard output. The table has one column for each strategy and, when requested, one baseline column. It shows Total return, CAGR, Sharpe, MaxDD, and Calmar. The lines below the table show each strategy's trade count and win rate, the common date range, and the fill mode. The `name:` line after the table joins each strategy's stock labels with `+`. When the same symbol appears under multiple aliases, the label carries a `#alias` suffix (for example `tw/00685L#core+tw/00685L#trade`).

If a strategy had a loan on at least one bar, `bt run` also prints a margin line:

```text
channel_ladder: margin - financing 6.35%/yr, min maintenance 145.20%, margin calls 1, refinances 3, clamps 0
```

A strategy that never had a loan has no margin line.

The default stem joins strategy names in argument order with `_vs_`. A single strategy uses its name as the stem. The optional baseline does not change the stem. `--out-name NAME` replaces this default stem.

| File | Content |
|---|---|
| `<stem>.csv` | All equity curves. Header: `date`, each strategy name in argument order, and `baseline` when requested. |
| `<name>.trades.csv` | One fill log per strategy. Header: `date,stock,price,from_exposure,to_exposure`. One row per fill per stock. When the same symbol appears under multiple aliases, the `stock` column carries `market/symbol#alias`. No baseline fill log. |
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
