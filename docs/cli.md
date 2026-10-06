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
  - [Strategy validation](#strategy-validation)
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
       [--per-share-fee F] [--per-share-cap F]
       [--financing-rate PERCENT] [--maintenance-ratio PERCENT]
       [--financing-ratio PERCENT] [--loan-term-months N] [--dividend-tax PERCENT]
       --capital AMOUNT [--data-dir DIR] [--out-dir DIR] [--out-name NAME] [--no-plot]
bt daytrade STRAT... [--baseline us/SYM] [--fill open|close] [--leverage N] [--from YYYY-MM-DD] [--to YYYY-MM-DD] [-p name=value] --capital USD [--fee-bps F] [--tax-bps F] [--slip-bps F] [--per-share-fee F] [--per-share-cap F] [--data-dir DIR] [--out-dir DIR] [--out-name NAME] [--no-plot]
bt target STRAT [--live] [--equity TWD] [--data-dir DIR] [--provisional-close PRICE]
bt live STRAT [--live] [--equity TWD] [--data-dir DIR]
```

## `bt fetch`

`bt fetch` downloads price data into a local CSV cache. Taiwan data comes from [FinMind](https://finmind.github.io) and US data from [Tiingo](https://www.tiingo.com). Prefer the positional `MARKET/SYMBOL` form; the `--market` and `--symbol` options are equivalent.

### Fetch options

| Argument or option | Default | Description |
|---|---|---|
| `MARKET/SYMBOL` | - | Select one market and symbol, for example `tw/0050`. The market must be `tw` or `us`. Use this argument or both options below. |
| `--market tw\|us` | - | Select the Taiwan or US market when you do not use the positional argument. |
| `--symbol SYM` | - | Select the symbol when you do not use the positional argument. |
| `--from YYYY-MM-DD` | `1994-10-01` for a new cache | Set the first date to request. |
| `--to YYYY-MM-DD` | today | Set the last date to request. |
| `--data-dir DIR` | `data/` | Set the cache directory. |
| `--bars 1m` | daily | Fetch US regular-session SIP minute bars from Alpaca. Only `1m` is accepted. |
| `-h`, `-help`, `--help` | - | Print the fetch options to standard output and exit with code 0. |

### API tokens

Set the environment variable for the market you use before running `bt fetch`.

```sh
export FINMIND_TOKEN="your_finmind_token"   # for tw
export TIINGO_TOKEN="your_tiingo_api_token" # for us
```

`bt fetch` exits with code 1 when the required token is missing or empty.

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
> Without `--from`, `bt fetch` extends an existing cache forward only. To backfill, pass a `--from` date earlier than the cache start.

For both markets, `bt fetch` can extend the cache at both ends. When `--from` is earlier than the first cached date, it fetches the missing earlier range and prepends it. It then fetches dates after the last cached date and appends them. Cached rows win at both boundaries, so a repeated fetch is idempotent.

For Taiwan, each run also rewrites three adjustment files from their full history: dividend factors in `SYM.div.csv`, cash dividends in `SYM.cashdiv.csv`, and split, capital-reduction, and par-value-change events in `SYM.events.csv`. If the source omits a pay date, the loader uses one calendar month after the ex-date.

> [!WARNING]
> If the FinMind cash-dividend API returns status 400, 402, or 403, `bt fetch` derives cash from the legacy dividend factors and treats every factor as cash-only. The result is exact for cash-only TW ETFs but can misprice stocks that also pay stock dividends.

Other fetch failures keep an existing cash-dividend file; without one, `bt run` warns and continues without cash credits.

For every Taiwan fetch, the command also requests the symbol's rows from the `TaiwanStockInfo` table and merges them into `data/tw/stockinfo.csv`, replacing that symbol's earlier rows. It keeps only `twse` and `tpex` rows. If this request fails, the command keeps the existing stock-info cache. An unknown symbol or a missing cache makes `bt run` warn and use the TWSE financing ratio of 60%.

> [!WARNING]
> The stock-info table selects the standard exchange ratio only. The engine assumes every Taiwan symbol is marginable and does not check broker eligibility or reduced ratios. Leveraged ETFs such as 00685L have historically been excluded from margin financing or assigned reduced ratios.

For US, the command derives all four files from the same Tiingo response: raw prices, signal-plane dividend factors, cash dividends, and split events. Tiingo provides no pay date, so `bt run` credits US cash dividends at the ex-date. The command snaps split factors to the nearest small rational to remove vendor floating-point noise. If a Tiingo request fails, the command prints a warning, keeps any cached files, and exits with code 0.

### Price adjustments

The engine loads two price series for every asset. The signal series includes cash-dividend and corporate-event adjustments, and the DSL evaluates indicators and rules on it. The money series includes split, capital-reduction, par-value-change, and stock-dividend adjustments but leaves cash-dividend drops in place. The engine uses the money series for fills, inventory, loans, collateral, and equity.

For Taiwan, `<symbol>.div.csv` supplies the full dividend adjustment to the signal series and `<symbol>.cashdiv.csv` separates the cash component for the money series and ledger. `<symbol>.events.csv` supplies exact split, capital-reduction, and par-value-change factors to both price series. Share-count event factors also restate earlier volume to the post-event share basis. Cash-dividend factors do not change volume.

For US assets, `<symbol>.div.csv` supplies the dividend adjustment to the signal series and `<symbol>.cashdiv.csv` separates the cash component for the money series and ledger. `<symbol>.events.csv` supplies exact split factors to both price series and restates earlier volume to the post-split share basis.

## `bt daytrade`

`bt daytrade` runs one or more single-stock US strategies on cached regular-session minute bars.

### Daytrade options

| Argument or option | Default | Description |
|---|---|---|
| `STRAT...` | required | Each file declares one unaliased US stock and `bars Nm`; basenames must be unique. |
| `--baseline us/SYM` | none | Add a daily Tiingo buy-and-hold baseline on the common session dates. |
| `--fill open\|close` | `open` | Fill each decision at the next bar's open or at the same bar's close. Session liquidation uses the last close in both modes. |
| `--leverage N` | `1.0` | Set the buying-power multiplier on previous-close cash. It must be positive and finite. |
| `--from D`, `--to D` | all cached dates | Set inclusive date bounds. |
| `-p name=value` | strategy defaults | Override a declared parameter. |
| `--capital USD` | required | Set the positive finite starting dollar value. It scales the per-share sell fee and its cap; sizing stays in fractional exposure units. |
| `--fee-bps F` | `0` | Set the commission in basis points on each side. |
| `--tax-bps F` | `0.206` | Set the sell-side SEC fee in basis points. |
| `--slip-bps F` | `0` | Set slippage in basis points on each side. |
| `--per-share-fee F` | `0.000195` | Set the dollar sell fee per share. |
| `--per-share-cap F` | `9.79` | Set the dollar cap per sell order. |
| `--data-dir DIR` | `data/` | Set the cache root for minute bars, the calendar, and the optional daily baseline. |
| `--out-dir DIR` | `out/` | Set the output directory. |
| `--out-name NAME` | joined strategy names | Set the equity and plot filename stem. Trade logs keep each strategy basename. |
| `--no-plot` | off | Skip `scripts/plot.py`. |
| `-h`, `-help`, `--help` | - | Print usage and exit with code 0. |

### Data requirements

```sh
bt fetch us/SPY --bars 1m --data-dir data
bt fetch us/SPY --data-dir data
bt daytrade examples/daytrade_orb.strat --baseline us/SPY --capital 100000 --data-dir data --from 2026-01-01
```

Minute fetches require `APCA_API_KEY_ID` and `APCA_API_SECRET_KEY`. Daily US fetches require `TIINGO_TOKEN`. A minute fetch refreshes the calendar from 2016 through today and requests SIP history through 16 minutes before now. It paginates in year ranges and resumes from the last cached minute, or from 2016 for an empty cache. A failed request keeps the cached data. Timestamps are ET bar left edges with DST conversion, and the cache keeps only calendar regular hours.

> [!IMPORTANT]
> `bt daytrade` intersects the strategies and the optional daily baseline by session date before evaluation and requires at least two common dates. It omits calendar sessions with no bars and does not replace minute bars with daily bars.

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

`bt daytrade` treats these flags as usage errors (exit 2). It does not place live trades. `bt run`, `bt target`, and `bt live` reject `bars` strategies with `day trading strategies run under bt daytrade`. `bt run`, `bt target`, `bt live`, and `bt daytrade` reject a `bars` strategy that declares `rebalance` with `<file>: rebalance applies to daily strategies only`.

## `bt target`

`bt target` runs one decision against US Alpaca or TW Shioaji, in simulation or production mode, and prints the proposed action without submitting an order.

Both market arms share these options.

| Argument or option | Default | Description |
|---|---|---|
| `STRAT` | required | Read one daily strategy with N distinct US or TW symbols, all in one market. |
| `--data-dir DIR` | `data/` | Use that market's Tiingo or FinMind cache. |
| `--provisional-close PRICE` | - | Build the provisional bar from a positive PRICE instead of the broker snapshot. It requires a one-stock strategy, and the output then starts with `provisional: override PRICE`. |
| `-h`, `-help`, `--help` | - | Print the target options and exit with code 0. |

> [!TIP]
> Use `--provisional-close PRICE` for a dry run when a current broker snapshot is unavailable or unsuitable.

Both markets print the account fields once, then one symbol block per stock in declaration order, one field per line. Each block ends with its market-specific action fields.

| Scope | Field | Meaning |
|---|---|---|
| Account | `provisional` | Report `override PRICE` first when `--provisional-close` supplies the provisional bar. |
| Account | `fetched-through` | Show the last historical date that every symbol shares. |
| Account | `equity` | Show the equity the planner sizes from. US: Alpaca's signed cash plus every held symbol at its provisional close. TW: the simulation `--equity` or the broker-derived production equity. |
| Account | `cash` | Show the free cash passed to the planner. US: Alpaca's cash when positive, otherwise 0. TW: the inferred simulation cash or the production spendable cash. |
| Account | `debit` | Show the margin loan passed to the planner. US: the negative part of Alpaca's cash. TW: the summed loan principal of the held margin positions. |
| Symbol block | `symbol` | Start the block with the symbol or code. |
| Symbol block | `provisional-date` | Show the provisional bar's date. |
| Symbol block | `provisional-open` | Show the provisional bar's open. |
| Symbol block | `provisional-high` | Show the provisional bar's high. |
| Symbol block | `provisional-low` | Show the provisional bar's low. |
| Symbol block | `provisional-close` | Show the provisional bar's close, the decision price. |
| Symbol block | `provisional-volume` | Show the provisional bar's volume. |
| Symbol block | `target` | Show the effective target exposure after the engine clamps and jointly scales all targets. |
| Symbol block | `held` | Show the shares currently held. TW counts cash and margin shares together. |
| Symbol block | `action` | Report US `order` or `skip`, or TW `orders`, followed by that market's fields. |

> [!IMPORTANT]
> `bt target` prints the proposed action but never submits an order, even with `--live`.

A strategy without `rebalance daily` or `rebalance on_change` rebalances only when its effective target changes. TW maturity rollover pairs run either way. `bt target` prints `warning: <file> does not declare rebalance; trading only when the target changes` to standard error before the decision; standard output is unchanged.

> [!IMPORTANT]
> Under `rebalance on_change`, declared or by default, each decision compares today's effective target with the previous session's, which bt recomputes from that session's cached final close. When the two are equal, the decision places no rebalancing order, and the position keeps its gap from target until the target next changes. The gap can come from ordinary price drift, from a previous-session decision at a provisional price whose target the final close does not reproduce, from a missed session or rejected orders, or from a partial fill. `rebalance daily` re-plans toward the target from the held position every session. It can still leave a residual: US skips a buy under USD 1, and TW floors cash quantities to whole shares and margin quantities to 1000-share lots.

### Strategy validation

These checks apply to `bt target` and `bt live` in both markets.

| Message | Effect |
|---|---|
| `live trading needs one market` | A strategy that mixes US and TW stocks is a usage error, exit 2. |
| `live trading needs distinct symbols: SYMBOL` | A broker symbol declared twice fails the command, even under distinct aliases. |
| `--provisional-close needs a one-stock strategy` | `bt target` fails before any broker call. |
| `history gap in SYMBOL within the last 5 sessions` | The decision fails on the first symbol, in declaration order, that misses one of the last five dates in the union of cached dates. `bt target` exits 1, the US daemon retries until the cutoff, and the TW daemon skips the day. |

History is loaded and freshness-checked per symbol. A gap in any of the last five union dates fails the decision; older gaps pass. Every symbol is then filtered to the common dates, as `bt run` does, before its provisional bar is appended. The DSL compiler runs once with all assets, and `Engine.effective_targets` scales the final and previous target rows jointly. Under on_change, a symbol whose effective target is unchanged keeps its drift. When every symbol is unchanged, US skips before planning.

### US market

#### Prerequisites

The strategy must declare one or more distinct US stocks, and the account may hold only those symbols. The command needs Tiingo history and access to the selected Alpaca paper or live account.

#### Options

| Option | Default | Description |
|---|---|---|
| `--live` | paper | Select the live Alpaca endpoint. |

`bt target` rejects `--equity` for US strategies.

#### Environment

| Variable | Default | Purpose |
|---|---|---|
| `TIINGO_TOKEN` | - | Authenticate the Tiingo history request. |
| `APCA_API_KEY_ID` | - | Identify the selected paper or live Alpaca account. |
| `APCA_API_SECRET_KEY` | - | Authenticate the selected paper or live Alpaca account. |

The Alpaca key variables must contain credentials for the selected account.

#### Decision cycle

For each symbol, the command fetches Tiingo history through Alpaca's previous daily bar and reads Alpaca's current snapshot. It keeps the dates every symbol shares, appends each snapshot as a provisional bar, and evaluates the strategy with the same DSL compiler as `bt run`. With `--provisional-close PRICE`, the command skips the Alpaca snapshot and treats the last cached date as the previous daily bar.

Under `rebalance on_change`, or without a declaration, the command compares each symbol's effective target with its previous bar's effective target, or 0 on the first bar. A symbol whose target is unchanged skips with the reason `target unchanged`. Under `rebalance daily`, or for symbols whose targets changed, it plans orders from the account and the held positions.

The command maps the account into one engine state. A negative Alpaca cash balance becomes the account debit. bt splits it across symbols in proportion to their holdings at the provisional close, or equally when every holding is zero. Each symbol's holding becomes margin inventory up to `loan / 0.5`, the value its share of the loan finances at the US financing ratio; the rest is cash inventory. One `Engine.plan_fills` call then plans every symbol with the US default costs, as `bt run` does. Alpaca's `equity` field does not size the orders.

The command nets each symbol's planned ordinary buys and sells into one order for that symbol. Refinancing pairs need no Alpaca order, so the net ignores them. A net of 0 skips with the reason `no trade planned`. The command truncates the quantity to at most 9 decimal places, caps a sell at the held position, and sells every held share when the plan closes the position. A buy below USD 1 notional, or a quantity that truncates to 0, skips with the reason `below $1 minimum order value`. A sell of any positive quantity becomes an order, so you can always close a position worth less than USD 1.

#### Output

The US arm adds these fields to each symbol block.

| Field | Meaning |
|---|---|
| `action` | Report `order` or `skip`. |
| `side` | Report `buy` or `sell` for an order. |
| `quantity` | Report the fractional share quantity for an order, with at most 9 decimal places. |
| `client-order-id` | Report the deterministic order identifier. |
| `reason` | Explain a skipped action. |

#### Failure handling

The [strategy validation](#strategy-validation) checks apply first. An unavailable account, stale cache or snapshot, failed history fetch, or strategy evaluation error fails the decision without submitting an order. These account states also fail it, checked in this order before the `target unchanged` skip:

| Message | Condition |
|---|---|
| `US account cash is not finite` | Alpaca's `cash` is NaN or infinite. |
| `US account holds a short position` | `short_market_value` is not 0, or the held quantity is negative. |
| `US account holds unsupported symbol SYMBOL` | An open position in Alpaca's positions list has a symbol outside the strategy. The check applies to one-stock strategies too. |
| `US account holds other symbols` | `long_market_value` is not finite, or differs from the sum of every symbol's held quantity at its provisional close by more than 1% of `long_market_value`. |
| `US account equity is not positive` | The mapped equity is NaN, infinite, or at most 0. |

A `--provisional-close` price more than about 1% away from Alpaca's mark trips the other-symbols check on an account that holds the stock.

> [!WARNING]
> The free Alpaca IEX feed can produce a provisional price that differs from the consolidated tape. Alpaca paper accounts also do not simulate dividends, so paper cash and equity can diverge from a live account.

### Taiwan market

#### Prerequisites

The strategy must declare one or more distinct TW stocks, and the account may hold only those codes. Install the official `shioaji` command, create the server `.env`, and start `shioaji server start`.

The official server reads this `.env` from the directory where it starts:

```dotenv
SJ_API_KEY=YOUR_API_KEY
SJ_SEC_KEY=YOUR_SECRET_KEY
SJ_CA_PATH=your/ca/path/Sinopac.pfx
SJ_CA_PASSWD=YOUR_CA_PASSWORD
SJ_PRODUCTION=false
```

The server uses `SJ_API_KEY` and `SJ_SEC_KEY` to log in to Shioaji. Copies in the `bt` environment are optional: `bt` sends a Bearer header only when both are set and nonempty, for servers that enforce Bearer authentication. `SJ_CA_PATH` and `SJ_CA_PASSWD` activate the certificate that production order placement requires. `SJ_PRODUCTION=true` selects production; `false` or an unset value selects simulation. The CA path, CA password, and production setting stay server-only.

#### Options

In production, `bt` sizes from the broker balance, the signed T+1 and T+2 settlements, and positions read with `unit: Share`. The T+0 row must be present for settlement-window validation, but `bt` does not add it because the balance already reflects it.

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

The TW target reads account data and one snapshot request for all codes from Shioaji, and historical data from FinMind. It queries `TaiwanStockTradingDate` for the previous session and never treats cached prices as a calendar. It refreshes adjustments through today and rejects a stale snapshot or a cache that does not end on the previous session.

On TW, `--provisional-close PRICE` replaces only the snapshot. The command still checks the Shioaji server mode, queries the independent FinMind trading calendar, fetches history, and requires the cache to end on the verified previous session.

The resulting plan preserves the cash and margin inventories. It can contain cash sells, margin sells, cash buys, margin buys, and paired sell/rebuy refinancing legs. When a dated `MarginTrading` position detail reaches the engine's 18-calendar-month, month-end-clamped maturity, the plan puts a sell/rebuy pair before the ordinary target legs. As in `bt run`, the engine floors cash quantities to whole shares and margin and refinance quantities to 1000-share lots. The plan prices commission at SinoPac's settlement-debit list rate of 14.25 bps, the rate the `bt live` daemon funds with, so printed buy quantities can be slightly lower than a `bt run` backtest's at the 2.85 bps default. The design is in [Design: share quantum and odd lots](./specs/share-quantum-and-odd-lots.md).

With several codes, the plan lists every code's rollover pairs first, then all margin sells, cash sells, refinance pairs, cash buys, and margin buys, each group in declaration order. Each symbol block prints its own legs in that order.

Under `rebalance daily`, the planner plans back to the effective target every session, so it re-plans missed legs and partial fills. Under `rebalance on_change`, or without a declaration, it plans ordinary legs only when the effective target differs from the previous bar's, and otherwise preserves drift. Maturity rollover pairs do not depend on this choice.

| Leg | Orders |
|---|---|
| Cash buy or sell of N shares | One `Common` order for N / 1000 lots when that is positive, then one `IntradayOdd` order for the N mod 1000 remaining shares when that is positive. |
| Margin buy or sell | One `Common` order. N is already a multiple of 1000. |
| Refinance or rollover sell and rebuy | One `Common` order per side. |

Production requires exactly one settlement row for each of T+0, T+1, and T+2 and rejects missing, duplicate, or other T-day rows. Spendable cash is `acc_balance + T+1 + T+2`, using each signed amount. `bt` validates T+0 but does not add it again, because `acc_balance` already reflects it. Equity is spendable cash plus all positions, counted in shares, at the provisional close, minus margin loan principal and interest. The decision fails when that equity is not positive. A real-account probe tracked a TWD -107 purchase payable at T+2 on 2026-09-16 and T+1 on 2026-09-17 while `acc_balance` remained TWD 100,000, then at T+0 on 2026-09-18 when `acc_balance` fell to TWD 99,893. Pending T+1 and T+2 settlements change the daily cash budget without skipping the session.

#### Output

The TW arm adds these fields to each symbol block.

| Field | Meaning |
|---|---|
| `action` | Report `orders`. |
| `leg` | Report each leg as `ACTION CONDITION LOT QUANTITY`. `LOT` is `Common`, with QUANTITY in 1000-share lots, or `IntradayOdd`, with QUANTITY in shares. |

A cash buy of 86,580 shares prints two legs:

```text
leg: Buy Cash Common 86
leg: Buy Cash IntradayOdd 580
```

In production, `bt target` also prints the [budget pre-check](#failure-handling-1) audit lines to standard error before its standard output, without the `date=DATE` prefix the daemon adds: one contract line per code, one fallback line per code without a usable `limit_up`, and one budget line. Standard output keeps the account fields and symbol blocks above. Simulation prints neither.

```text
code=CODE reference=VALUE limit-up=VALUE limit-down=VALUE day-trade=VALUE unit=VALUE margin-loan-ratio=VALUE trading-suspended=BOOL
code=CODE budget-price-fallback=reference*1.10 price=VALUE
buy-hold=VALUE trading-available=VALUE margin-hold=VALUE margin-available=VALUE
```

#### Failure handling

The [strategy validation](#strategy-validation) checks apply first. The mode mismatch guard refuses simulation commands against a production server and refuses `--live` against a simulation server. The decision fails when the dated `position_detail` quantities of a margin position, counted in 1000-share lots, exceed its held margin shares.

`bt target --live` and the TW production daemon both run the decision through `Live.decide`, so both read contract info for each code and the trading limits once, then check the planned buys before any order. `bt target` places no order either way. Simulation makes neither read.

| Buy leg | Production budget hold |
|---|---|
| `Common`, `Cash` | `limit_up x lots x unit`, summed against `trading_available`. |
| `Common`, `MarginTrading` | `limit_up x lots x unit`, summed against `margin_available`, not discounted by the financing ratio. |
| `IntradayOdd`, `Cash` | The snapshot ask, which is the order's `LMT` price, times the shares, summed against `trading_available`. A zero or negative ask holds nothing, because the executor skips that buy. |
| Rollover or refinance rebuy | Counted once in the `MarginTrading` sum. |

A code with an absent, null, or non-positive `limit_up` uses `reference x 1.10` in its place and logs `code=CODE budget-price-fallback=reference*1.10 price=VALUE`. The check never offsets a buy hold with a sell and never relies on an FOK kill releasing a hold. It assumes the broker holds a market buy at `limit_up` and that a filled sell adds nothing to `trading_available`; the [stage 2 acceptance](./specs/multi-stock-live.md#stage-2-tw-production) measures both. On the production account with 0050, `trading_used` reset daily, a cancel released its hold at once, and an order rejected at placement held nothing ([Measured and unmeasured](./specs/multi-stock-live.md#measured-and-unmeasured)). `margin_limit` read 0 at every probe reading, so any margin buy fails while `margin_available` stays 0.

| Message | Effect |
|---|---|
| `TW symbol CODE is suspended` | A `trading_suspended` contract fails the whole decision; no symbol trades. |
| `TW buy budget short: planned X, available Y` | The cash buy holds exceed `trading_available`; no order is submitted. |
| `TW margin budget short: planned X, available Y` | The margin buy holds exceed `margin_available`; no order is submitted. |
| `TW budget inputs are not finite` | A `Common` hold price is not finite and positive, an odd-lot ask is not finite, or a hold sum or available figure is negative or not finite; no order is submitted. |

A failed pre-check makes `bt target` exit 1 without an order. The TW daemon logs `date=DATE error=MESSAGE order=skip` and skips the day; it does not retry the check within the session.

> [!WARNING]
> `--equity` is the total equity you supply for simulation; `bt` does not read it from broker cash or `account_balance`. Over the strategy's symbol set, `bt` infers simulation cash as equity minus the summed cash and margin inventory values of all strategy positions, plus their summed loan principal and interest. It rejects a nonzero holding in any code outside the strategy.

`bt target` does not print `acc_balance` or the T-day amounts. `bt live` logs them with derived spendable cash and equity at production startup; see [Output and logs](#output-and-logs-1). T+0 stays visible there for audit even though the verified cash formula excludes it.

## `bt live`

`bt live` runs the close-scheduled trading daemon for one US or TW strategy.

Both market arms share these options.

| Argument or option | Default | Description |
|---|---|---|
| `STRAT` | required | Read one daily strategy with N distinct US or TW symbols, all in one market. The account may hold only those strategy symbols. |
| `--data-dir DIR` | `data/` | Set the Tiingo or FinMind cache directory selected by the strategy market. |
| `-h`, `-help`, `--help` | - | Print the live options and exit with code 0. |

Both daemons print ASCII log lines to standard output: one account line per decision, then one line per symbol with its provisional close, target, holdings, and action. The [strategy validation](#strategy-validation) checks of `bt target` also apply.

Only one daemon can hold `$HOME/.bt/live-<market>-<mode>.lock` at a time (`paper` or `live` for US; `simulation` or `production` for TW), regardless of the data directory; another fails with `another bt live daemon holds <path>`. The lock excludes only daemons that share a `HOME`, market, and mode, so daemons with different `HOME` values can trade the same account at once.

A strategy without `rebalance daily` or `rebalance on_change` rebalances only when its effective target changes. TW maturity rollover pairs run either way. The daemon logs `warning: <file> does not declare rebalance; trading only when the target changes` once, right after the `startup` line.

> [!IMPORTANT]
> Under `rebalance on_change`, declared or by default, each session compares today's effective target with the previous session's, which the daemon recomputes from that session's cached final close. When the two are equal, the session places no rebalancing order, and the position keeps its gap from target until the target next changes. The gap can come from ordinary price drift, from a previous-session decision at a provisional price whose target the final close does not reproduce, from a missed session or rejected orders, or from a partial fill. `rebalance daily` re-plans toward the target from the held position every session. It can still leave a residual: US skips a buy under USD 1, and TW floors cash quantities to whole shares and margin quantities to 1000-share lots.

### US market

#### Prerequisites

The strategy must declare one or more distinct US stocks, and the account may hold only those symbols. The selected Alpaca account must be active and not trading-blocked.

#### Options

| Option | Default | Description |
|---|---|---|
| `--live` | paper | Select the live Alpaca endpoint and permit real-money orders. |

`bt live` rejects `--equity` for US strategies.

#### Environment

| Variable | Default | Purpose |
|---|---|---|
| `TIINGO_TOKEN` | - | Authenticate Tiingo history requests. |
| `APCA_API_KEY_ID` | - | Identify the selected paper or live Alpaca account. |
| `APCA_API_SECRET_KEY` | - | Authenticate the selected paper or live Alpaca account. |

At startup, the daemon logs the mode, account number, and equity.

#### Decision cycle

The daemon derives every phase from Alpaca's `next_close`.

| Phase | Timing | Action |
|---|---|---|
| Evaluate | 15 minutes before the close | Refresh Tiingo history and evaluate the provisional daily bar. |
| Submit | Until 2 minutes before the close | Query today's deterministic client order ID for every symbol, then submit fractional `market` orders with `time_in_force: day` where needed. A session with sells and buys submits every buy only after every sell fills. |
| Reconcile | After the close | Poll each open order every 15 seconds until it reaches a terminal status or 5 minutes pass after the close, then log its fill. |
| Sleep | After reconciliation | Sleep until the next open. |

The Submit phase ends 2 minutes before the close because Alpaca queues a day order sent after the close for the next session, and the order request can take up to its 60-second curl timeout. At or after that cutoff, the daemon logs `error=submit cutoff passed order=skip` and submits nothing. The account checks, the planner sizing, the `target unchanged` and `no trade planned` skips, the 9-decimal fractional quantity, and the USD 1 buy minimum match `bt target`.

A session with both sells and buys runs a sell phase. The daemon POSTs its sells, polls all of them every 15 seconds, and starts buys only after every sell reaches `filled`. It checks the clock before each POST. A session with no sell or no buy posts its orders before the finish pass, as a one-order session always did. On restart, existing sells join the sell barrier and existing buys enter only the finish pass. No request is retried after a POST.

#### Output and logs

Each daemon line starts with a UTC timestamp in `YYYY-MM-DDTHH:MM:SSZ` format. The `startup` line records the selected `mode`, `account` number, and `equity`. Each decision logs one account line, followed by one line per symbol:

```text
date=DATE fetched-through=DATE equity=VALUE cash=VALUE debit=VALUE
date=DATE symbol=SYMBOL provisional-close=VALUE target=VALUE held=VALUE order=ORDER fill=pending
```

ORDER holds the deterministic order as `SIDE:QUANTITY:CLIENT-ORDER-ID` or the skip reason as `skip:REASON`. An all-unchanged on_change session logs only the account line, ending in `order=skip:target unchanged`. Existing-order, fill, and per-order error lines include `symbol=SYMBOL`. Client order IDs remain `bt-SYMBOL-DATE`. Fill lines record `client-order-id`, `fill-status`, `fill-price`, and `filled-qty`.

When new orders are pending, the daemon writes the decision lines only after today's order lookups and the pre-submit clock check succeed, so an attempt that fails before then and retries writes none. When the lookups find every order already placed, the daemon reconciles those orders without deciding or logging account and symbol decision lines. A restart whose only new orders are buys behind an existing sell skips that early check; each buy POST still checks the clock.

#### Failure handling

The daemon refuses to start with an inactive or trading-blocked account. If the Alpaca clock request at the start of a daemon cycle fails, the daemon logs `order=retry`, retries every 60 seconds, and continues the same session once a request succeeds. Before the cutoff, a stale cache, a history gap, a fetch, snapshot, or evaluation error, a failed order lookup, or a failed clock check just before the first submission also logs `order=retry`, and the daemon retries every 60 seconds. Each retry looks up today's client order IDs first, so a symbol that already has an order gets no second one. At or after the cutoff, a failed order lookup logs `order=skip` and ends the US action for the day. Once the daemon sends any order request, nothing is retried that day, because the request may have reached Alpaca and a retry could submit the order twice. A failed buy request logs `symbol=SYMBOL error=order submission uncertain: REASON order=skip`, a `rejected` buy logs `symbol=SYMBOL error=Alpaca rejected the order order=skip`, and the other buys still go out. A failure while following a submitted order logs `symbol=SYMBOL error=REASON order=skip`.

A sell-phase stop sends no buy and logs a session-level `error=REASON order=skip` line. Known orders still enter the finish pass.

| US sell-phase stop | Result |
|---|---|
| `sell SYMBOL rejected` or `sell SYMBOL uncertain` at submission | The failed sell logs `symbol=SYMBOL error=REASON order=skip`, and each other sell still goes out if its pre-submit clock check passes. The first failed sell names the stop, and no buy is POSTed. |
| `submit cutoff passed` between submissions | Each sell whose pre-submit clock check finds the cutoff logs `symbol=SYMBOL error=submit cutoff passed order=skip` and is not POSTed. No buy POST. |
| `sell SYMBOL STATE` while polling | No buy POST when STATE is `rejected`, `canceled`, `expired`, or `stopped`. A failed status lookup reports `sell SYMBOL uncertain`. |
| `sell SYMBOL open at cutoff` | No buy POST. |

A failed [account check](#failure-handling) before the cutoff logs `error=Failure("MESSAGE") order=retry`, and the daemon retries every 60 seconds. If the account stays invalid until the cutoff, the daemon logs `error=submit cutoff passed order=skip` and places no order.

> [!CAUTION]
> `bt live --live` submits real-money fractional market orders. Confirm the credentials, account, and strategy before starting it.

> [!WARNING]
> The free Alpaca IEX feed can produce a provisional price that differs from the consolidated tape. The market order fills near the decision time, about 15 minutes before the official close; model that gap in `bt run` with `--slip-bps`. Alpaca paper accounts also do not simulate dividends, so paper cash and equity can diverge from a live account.

> [!IMPORTANT]
> The US path re-plans every order from the account on every attempt. It retries a failed prerequisite until the cutoff but never retries after it sends an order request.

> [!NOTE]
> The US path queries each symbol's deterministic client order ID before submission. This reduces duplicate risk but is not an exactly-once guarantee for concurrent processes.

> [!WARNING]
> A partial restart plans from holdings and cash, not open orders. An unfilled order of a done symbol is invisible to that re-plan, so remaining symbols can be sized from cash the open order will spend. Symbol deduplication prevents resubmission but does not close this buying-power gap.

### Taiwan market

#### Prerequisites

Install the official `shioaji` command, create the server `.env` shown in the TW target section, and start `shioaji server start`.

TW `bt target` and `bt live` both support every distinct code the strategy declares. The single-price `--provisional-close` override still requires one stock.

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
| Decide | 13:20 | Skip the session when today's trades, read once for the whole account, hold any order on any code. Otherwise request a fresh snapshot for every code, validate its session and OHLCV values, append the provisional bars, evaluate the final and previous effective targets, read aggregate positions in shares and dated margin details, derive simulation or production cash and equity, prepend due 18-month rollover pairs, and plan ordinary cash, margin, and refinancing legs in absolute TWD. In production, read contract info for each code and the trading limits, then run the [budget pre-check](#failure-handling-1). Under `rebalance daily`, the plan returns to the effective target every session. Under `rebalance on_change` or without a declaration, an unchanged effective target preserves drift, and a changed target trades from current inventory. |
| Execute | New orders before 13:24:30; status polls before 13:25 | Split legs into `Common` and `IntradayOdd` orders as in `bt target` and run them in four phases: rollover pairs, ordinary sells, refinance pairs, and ordinary buys. Recheck the date and the 13:24:30 order cutoff immediately before every order, and the date and 13:25 during every status poll. Continuous trading ends at 13:25, so the 30-second margin reduces the chance that a checked order reaches the broker in the closing call. |
| Reconcile | After 13:30 | Query and log today's trades for every strategy code, including fill status, deal quantity, and weighted deal price. A code without trades logs `date=DATE code=CODE fill-status=none`. |

> [!IMPORTANT]
> The existing-orders check filters today's trades by date only, not by code or origin. A manual order placed that day on any code, inside or outside the strategy, skips the bot's TW session once the server lists it.

| Order | Request | Confirmation |
|---|---|---|
| `Common` ordinary leg | `MKT` + `FOK`, price 0, quantity in lots. | FOK asks for a complete fill or none, and the partial-fill check stays as a guard. The placed orders of one phase are polled together: up to five rounds, one second apart, with at most one read of today's trades per code per round. Each needs one matching `Filled` record with the full quantity and a finite positive weighted price, or a no-fill `Failed`, `Inactive`, `Cancelled`, or `Rejected` record. |
| `Common` pair leg | `MKT` + `FOK`, price 0, quantity in lots. | Sell, then rebuy the full original lot count, one leg at a time. Each sell must be confirmed filled, and the rebuy must be fully funded. |
| `IntradayOdd` | Limit `ROD`, quantity 1 to 999 shares, priced at the snapshot ask for a buy and the snapshot bid for a sell. | None. The executor logs `submitted=intraday-odd-rod-pending quantity=N` and moves on. |

TWSE intraday odd-lot trading accepts only limit `ROD` orders of 1 to 999 shares and no margin or securities-lending sales ([TWSE intraday odd-lot rules](https://www.twse.com.tw/downloads/zh/trading/introduce/introduce4-1.pdf)). The Shioaji server exposes no odd-lot quote, so the limit comes from the regular-book snapshot. An accepted odd-lot buy reserves its full cost from the cash budget at once. An odd-lot sale never adds proceeds to the same session's cash.

| Odd-lot case | Behavior |
|---|---|
| Simulation server | Skip the order, log `submitted=skip:odd-lot-unsupported-in-simulation`, and continue with later legs. |
| Snapshot ask or bid missing | Skip the order, log `submitted=skip:odd-lot-quote-unavailable`, and continue. In production, the budget pre-check gives an odd-lot buy with a zero ask no hold, so that buy reaches this skip. |
| Broker rejects the placement | Log `code=CODE submitted=skip:odd-lot-rejected`. A rejected buy lets later legs continue; a rejected sell stops the session before the next phase. |
| Today's trades hold an opposite-direction `IntradayOdd` fill for the symbol | Stop with `opposite-direction odd-lot fill today`; nothing else is submitted. |
| Today's trades cannot be read | Stop with `odd-lot trade history unavailable: REASON`. |

The opposite-direction guard prevents a same-day odd-lot round trip. The daemon skips a session that already has orders, and a plan never holds an odd-lot sell and an odd-lot buy together, so the guard is a backstop.

Within a phase, the executor places every leg first and then polls the placed `Common` orders together. Every ordinary `Common` sell must be confirmed filled before the refinance pairs and ordinary buys start. A pending odd-lot `ROD` sell is exempt from that barrier. Each buy reserves its cost at its quote price from one running cash balance before the next buy is sized, and a confirmed fill replaces the reservation with the deal-price cost. A refinance or rollover sell and its rebuy are sequential dependent orders, not an atomic broker operation. An ordinary buy may be floored to the remaining cash; if capped, its remainder and every later leg stay unsubmitted.

Live planning and execution both use SinoPac's settlement-debit list rate of 14.25 bps with a TWD 1 minimum per order, because the broker debits the list rate at settlement and rebates the discount later. Execution funds each buy and carries cash after each fill at that rate. Backtests use the 2.85 bps default commission. A cash leg split into a `Common` order and an `IntradayOdd` order pays two minimums.

#### Output and logs

Each daemon line starts with a UTC timestamp in `YYYY-MM-DDTHH:MM:SSZ` format. The production `startup` line also records `acc-balance`, `t0`, `t1`, `t2`, spendable `cash`, and `equity`. Production decisions first log one contract line per code, a fallback line for each code without a usable `limit_up`, and one budget line, all before any placement. Each decision then logs one account line and one line per code in declaration order:

```text
date=DATE code=CODE reference=VALUE limit-up=VALUE limit-down=VALUE day-trade=VALUE unit=VALUE margin-loan-ratio=VALUE trading-suspended=BOOL
date=DATE code=CODE budget-price-fallback=reference*1.10 price=VALUE
date=DATE buy-hold=VALUE trading-available=VALUE margin-hold=VALUE margin-available=VALUE
date=DATE fetched-through=DATE equity=VALUE cash=VALUE debit=VALUE submitted=OUTCOME
date=DATE symbol=CODE provisional-close=VALUE target=VALUE cash-shares=VALUE margin-shares=VALUE loan=VALUE planned-legs=LEGS
```

A code without a usable `limit_up` prints `limit-up=-` on its contract line. Simulation logs neither contract nor budget lines. OUTCOME is `complete`, `skip:no-order-legs`, `skip:existing-orders`, or `stop:REASON remaining:LEGS`. LEGS lists `ACTION:CONDITION:LOT:QUANTITY` entries, or `none`. In an existing-orders skip, `cash`, `debit`, and every symbol value except `planned-legs=none` print `-` for every strategy code, and `equity` is the startup equity. Rejected placements and no-fill `Common` ends add `code=CODE submitted=skip:...` lines, and odd-lot orders add their own `submitted=` lines. Trade lines record `code`, `order-id`, `action`, `cond`, `lot`, `fill-status`, `deal-quantity` in the trade's lot unit, and `fill-price`. `custom_field` remains `btMMDD`. Lot orders use `MKT` + `FOK`, and odd lots stay `LMT` + `ROD`.

#### Failure handling

The [strategy validation](#strategy-validation) checks apply at startup and in each decision. The mode mismatch guard requires simulation commands to see `info.simulation = true` and `--live` to see `info.simulation = false`. The daemon re-reads server info at the start of each unsubmitted daily Decide phase; if the server mode changed after startup, it logs the mismatch and skips the day's action before any order can be submitted. The day also stops when the dated `position_detail` quantities of a margin position, counted in 1000-share lots, exceed its held margin shares.

A failed [budget pre-check](#failure-handling-1) skips the day before any order. A rejected or uncertain sell, or a `Common` sell that ends `Failed`, `Inactive`, `Cancelled`, or `Rejected` with no fill, stops the session before the refinance and buy phases. An FOK kill counts as such a no-fill end only when the broker reports one of those statuses; any other status is uncertain. The first uncertain result stops the remaining placements, but the orders already placed are still polled and logged. A failed buy is logged, and its sibling buys continue. Odd-lot `ROD` sells stay unpolled and may still be pending when buys start; their proceeds are never spent that session. A partial, missing, ambiguous, mismatched, timed-out, or cutoff result stops all later legs.

No execution path guarantees exactly once across concurrent daemon processes or every crash timing; the pre-submit query only reduces duplicate risk.

> [!WARNING]
> Simulation equity is a user-supplied sizing input, and simulation skips every odd-lot order. Real MKT fills, odd-lot limit fills in the separate odd-lot book, unfilled ROD orders, the spread, FOK kills, the retained partial-fill guard, broker margin rules, settlements, and concurrent processes can make TW daemon execution differ from a daily close-fill backtest.

> [!IMPORTANT]
> A stale cache, fetch or snapshot error, or evaluation error logs one error line and stops the TW action for the day. TW starts no later phase while a placed `Common` order's result is unconfirmed, and it records that stop as `submitted=stop:REASON remaining:LEGS`.

> [!NOTE]
> The TW path queries today's orders before planning and carries confirmed `Common` fills, quote-price reservations for placed buys, and pending odd-lot buy costs between legs. This reduces duplicate risk but is not an exactly-once guarantee for concurrent processes.

Pending T+1 and T+2 settlements never suppress a production session; their signed amounts change the available cash passed to the unchanged planner and executor. T+0 must still be present and appears in the startup log, but `acc_balance` already reflects it.

## `bt run`

`bt run` backtests one or more strategy files on cached prices. Each strategy file selects its data with `stock "market/symbol"` statements; a file that declares more than one stock gives each an `as` alias.

> [!IMPORTANT]
> `--benchmark` was renamed to `--baseline`. Do not pass `--market`, `--symbol`, or `--benchmark-market` to `bt run`. Put the market and symbol in each strategy file.

### Run arguments and options

| Argument or option | Default | Description |
|---|---|---|
| `STRAT...` | required | Read strategies from one or more files. The file basename without its extension becomes the strategy name. |
| `--baseline M/SYM` | - | Add a buy-and-hold baseline for this market and symbol. |
| `--from YYYY-MM-DD` | first cached common date | Set the first date to load. |
| `--to YYYY-MM-DD` | last cached common date | Set the last date to load. |
| `-p name=value` | - | Override each matching strategy `param` with a float value. Repeat for more parameters. The command rejects a name that no strategy declares. |
| `--fill open\|close` | `close` | Select the fill mode. |
| `--capital AMOUNT` | required | Set the positive finite portfolio starting value in the market's currency: TWD for Taiwan, USD for US. The engine converts exposure to share counts at this scale and charges the minimum fee and per-share fees in money terms. |
| `--fee-bps F` | per market | Override the fee in basis points for all strategies and the baseline. |
| `--tax-bps F` | per symbol class | Override the sell tax in basis points for all strategies and the baseline. |
| `--slip-bps F` | `0` | Override slippage in basis points for all strategies and the baseline. |
| `--min-fee F` | TW 1, US 0 | Override the minimum commission per order in the market's currency. |
| `--dividend-tax PERCENT` | `0` | Reduce every TW receivable and US cash dividend by this percent when the engine creates it, to model dividend income tax and the NHI supplementary premium. |
| `--financing-rate PERCENT` | TW 6.35, US 6.25 | Set the annual financing rate. |
| `--maintenance-ratio PERCENT` | TW 130 (collateral/loan), US tiered | Set a flat maintenance threshold for either market. When unset, TW uses 130% collateral over loan and US uses the tiered table (100% below $2.50, 50% from $2.50 to below $6, 30% at $6 and above). |
| `--per-share-fee F` | US 0.000195, TW 0 | Override the per-share sell fee in dollars. |
| `--per-share-cap F` | US 9.79, TW 0 | Override the per-share sell fee cap in dollars per order. Use 0 for uncapped. |
| `--financing-ratio PERCENT` | TW 60, US 50 | Set the fresh-loan financing ratio for every asset. TW defaults from cached stockinfo (TWSE/TPEX 60%). US defaults to the Reg T initial-margin ratio of 50%. |
| `--loan-term-months N` | `18` | Set the TW margin-loan term in calendar months. Use 0 for open-ended TW loans. US loans are always open-ended. |
| `--data-dir DIR` | `data/` | Set the cache directory. |
| `--out-dir DIR` | `out/` | Set the output directory. |
| `--out-name NAME` | strategy names joined with `_vs_` | Set the equity CSV and PNG stem. |
| `--no-plot` | off | Do not run the plot script or update the equity PNG. |
| `-h`, `-help`, `--help` | - | Print the run options to standard output and exit with code 0. |

> [!NOTE]
> The four margin options and `--dividend-tax` apply to every strategy and the baseline. US assets ignore `--loan-term-months`.

A strategy without `rebalance daily` or `rebalance on_change` rebalances only on a bar where its effective target changes or dividend cash lands. Margin-call sales and TW maturity rollovers trade under either choice. `bt run` prints `warning: <file> does not declare rebalance; trading only when the target changes` to standard error once for each undeclared file; the report on standard output is unchanged. The `--baseline` run always trades on_change. See [Targets and drift](./engine.md#targets-and-drift).

[engine.md](./engine.md) covers the margin and dividend engine in full.

The engine floors Taiwan cash quantities to whole shares and Taiwan margin quantities to 1000-share lots; the floored remainder stays in cash. US quantities stay fractional. See [Share quantum](./engine.md#share-quantum).

The command applies `--from` and `--to` to every input, then keeps only the trading dates common to all strategies and the optional baseline, so every report column covers the same dates. The command stops if fewer than two common dates remain.

> [!IMPORTANT]
> Strategy names must be unique. `one/a.strat` and `two/a.strat` both have the name `a` and produce a duplicate-basename error. A strategy with the basename `baseline` conflicts with `--baseline`.

`--baseline` is shorthand for an always-long target exposure of 1.0. It adds a report and equity column named `baseline`. Strategy metrics get a `W` marker when they are equal to or better than the baseline and an `L` marker when they are worse. Higher is better for Total return, CAGR, Sharpe, and Calmar. Lower is better for MaxDD.

### Cost defaults

One basis point is 0.01%. One hundred basis points are 1%.

| Market and symbol | Fee | Minimum fee | Sell tax | Per-share sell fee | Slippage |
|---|---|---|---|---|---|
| US | 0 bps (0%) | - | 0.206 bps (SEC fee, effective 2026-04-04) | $0.000195/share, $0.01 floor, $9.79 cap (TAF, effective 2026-01-01) | 0 bps (0%) |
| Taiwan ordinary bond ETF (`00...B`) | 2.85 bps (0.0285%) | 1 TWD per order | 0 bps (0%) through 2026-12-31; the engine has no end date, see [Costs and taxes](./engine.md#costs-and-taxes-1) | - | 0 bps (0%) |
| Other Taiwan `00` ETF or `02` ETN | 2.85 bps (0.0285%) | 1 TWD per order | 10 bps (0.10%) | - | 0 bps (0%) |
| Other Taiwan symbol | 2.85 bps (0.0285%) | 1 TWD per order | 30 bps (0.30%) | - | 0 bps (0%) |

Leveraged and inverse bond ETFs end in `L` or `R`, not `B`, so they use the 10 bps ETF rate. The Taiwan fee is SinoPac's electronic-trading promotion rate, 20% of the 0.1425% list rate.

An exposure increase pays the commission and slippage. An exposure decrease pays the commission, sell tax, and slippage. Commission is proportional to the absolute exposure change, and each asset trade pays the greater of that proportional commission and the minimum fee. Sell tax and slippage remain proportional. The cost options override the applicable defaults for every strategy and the baseline; `--min-fee 0` disables the minimum.

### Fill modes

With `--fill close`, the target for a bar fills at the close of that bar. The old exposure earns the close-to-close return before the fill. The command applies fill costs at that close.

With `--fill open`, the target for a bar fills at the next bar's open. The old exposure earns the return from the previous close to that open. The new exposure then earns the return from the open to the close. Under `rebalance on_change`, if the target does not change, the current exposure earns the full close-to-close return. Under `rebalance daily`, the engine re-plans at every open.

The engine closes a final open exposure at the last close in both modes. It applies the fee, sell tax, and slippage to this close.

## Run outputs

`bt run` prints a report table to standard output. The table has one column for each strategy and, when requested, one baseline column. It shows Total return, CAGR, Sharpe, MaxDD, and Calmar. Below the table, each strategy gets a `name:` line with its stock labels joined by `+`, its trade count, and its win rate. A final line shows the common date range and the fill mode. When the same symbol appears under multiple aliases, the label carries a `#alias` suffix (for example `tw/00685L#core+tw/00685L#trade`).

If a strategy had a loan on at least one bar, `bt run` also prints a margin line:

```text
channel_ladder: margin - financing 6.35%/yr, min maintenance 145.20%, margin calls 1, refinances 3, clamps 0
```

A strategy that never had a loan has no margin line.

The default stem joins strategy names in argument order with `_vs_`. A single strategy uses its name as the stem. The optional baseline does not change the stem. `--out-name NAME` replaces this default stem.

| File | Content |
|---|---|
| `<stem>.csv` | All equity curves. Header: `date`, each strategy name in argument order, and `baseline` when requested. |
| `<name>.trades.csv` | One fill log per strategy. Header: `date,stock,price,from_exposure,to_exposure`. One row per fill per stock. When the same symbol appears under multiple aliases, the `stock` column carries `market/symbol#alias`. The baseline has no fill log. |
| `<stem>.png` | Equity graph. Not created with `--no-plot`. |

`--out-name` changes only `<stem>.csv` and `<stem>.png`; `<name>.trades.csv` keeps the strategy name.

> [!NOTE]
> `bt` runs `scripts/plot.py` in place and does not copy it into the output directory. `python3` and matplotlib are optional. If either is unavailable or plotting fails, the command prints a warning and exits with code 0 after it saves the CSV files.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | The command succeeded, or it printed requested help. |
| 1 | A runtime operation failed: missing token, missing cache, invalid cached data, or a failed required download. A plot failure is not a runtime failure. |
| 2 | The command line has a usage error: unknown subcommand, missing required argument, or invalid option. |
