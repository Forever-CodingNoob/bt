# Design: live trading via Alpaca

Date: 2026-09-04
Status: implemented; order form superseded by [Design: share quantum and odd lots](./share-quantum-and-odd-lots.md#us-live-fractional-shares)

## Contents

- [Goal](#goal)
- [Decisions (settled during design)](#decisions-settled-during-design)
- [Verified Alpaca facts (primary sources, docs.alpaca.markets, 2026-09-04)](#verified-alpaca-facts-primary-sources-docsalpacamarkets-2026-09-04)
- [Architecture](#architecture)
- [Daily cycle](#daily-cycle)
- [Safety and failure](#safety-and-failure)
- [Testing and verification](#testing-and-verification)
- [Docs](#docs)
- [Non-goals](#non-goals)

## Goal

Run one bt strategy live against one Alpaca account as a long-running daemon. The daemon computes the same signals as the backtester, on the same compiled code path, and places near-close orders so live fills follow the `--fill close` assumption the strategies were validated under. The work stays in the bt repo and adds no new project or dependency.

## Decisions (settled during design)

- Run as a long-running daemon instead of a one-shot cron job.
- Fill discipline: provisional close plus a near-close order. The engine's close-fill model assumes the decision price equals the official close, which in practice means acting minutes before the close on a near-close price. The daemon is the live counterpart of that assumption. The fill-sensitivity experiment measured the remaining decision-to-fill drift as a slippage band. The order is a fractional `market` order with `time_in_force=day`. It replaced the original market-on-close order because Alpaca rejects fractional MOC orders.
- One strategy, one account. The account's positions are the strategy's book. Multi-strategy netting is a non-goal.
- Paper by default. `--live` is the only way to reach the real account.
- History comes from Tiingo through the existing `bt fetch` routine. Alpaca supplies only the current in-progress daily bar and account state.
- Signal evaluation reuses the DSL compiler and engine target evaluation unchanged. Reimplementing signal logic outside the engine is prohibited: once live recomputes signals with separate code, backtest and live can disagree, and you can trust neither.

## Verified Alpaca facts (primary sources, docs.alpaca.markets, 2026-09-04)

- Trading API base URLs: `https://paper-api.alpaca.markets` (paper) and `https://api.alpaca.markets` (live). Both share one API spec and differ only in endpoint and key pair.
- Market Data API base URL: `https://data.alpaca.markets`.
- Auth: headers `APCA-API-KEY-ID` and `APCA-API-SECRET-KEY` on both APIs. Keys come from the environment; separate pairs per mode.
- Order types: fractional quantities work only on `market` and `limit` orders with `time_in_force=day`. Alpaca rejects fractional market-on-close (`time_in_force=cls`) orders, and that rejection replaced the original MOC design. A day order submitted after the close queues for the next session, so bt stops submitting 2 minutes before the close. The cutoff was 10 minutes at first, carried over from the MOC 3:50 pm entry rule. That rule does not apply to market day orders, so the cutoff moved to 2 minutes, which still leaves room for the 60-second curl timeout on the order request.
- Snapshot: `GET /v2/stocks/{symbol}/snapshot` returns `dailyBar` (today's running o/h/l/c/v), `prevDailyBar`, `latestTrade`, `latestQuote`. Free tier uses `feed=iex`; the provisional price can deviate slightly from the consolidated tape, inside the measured slippage envelope.
- Clock: `GET /v2/clock` returns `timestamp`, `is_open`, `next_open`, `next_close` (RFC3339 with offset). The calendar includes early-close days, so bt anchors all scheduling to `next_close` instead of a hardcoded 16:00.
- Account: `GET /v2/account`; `equity` = cash + long market value + short market value. All numeric fields are JSON strings.
- Position: `GET /v2/positions/{symbol}`; `qty` is a string. With no position the endpoint returns 404, which bt treats as qty 0.
- Orders: `POST /v2/orders`; `client_order_id` is a client-supplied unique id (max 128 chars), and you can query an order by it. Alpaca does not document duplicate-id rejection, so idempotency must not rely on it.
- Paper accounts default to $100k, use IEX data, and do not simulate dividends. bt reads signed cash, the long and short market values, and the one held position. It sizes from the position valued at the provisional close and the mapped planner equity, not from Alpaca's `equity` field. Paper results understate dividend cash relative to a backtest.

## Architecture

New modules, each with an `.mli` interface file:

- `broker/alpaca.ml` + `broker/alpaca.mli`: REST client in the same curl+jq subprocess style as the existing fetch code. Mode (paper or live) selects the base URL. Surface: clock, account, position for one symbol, order submit, order lookup by client_order_id, and the data-API snapshot.
- `broker/live.ml` + `broker/live.mli`: the daily cycle and the one-shot evaluation that both subcommands share.

`bin/bt.ml` gains two subcommands:

- `bt live <strat> [--live] [--data-dir DIR]`: the daemon.
- `bt target <strat> [--live] [--data-dir DIR] [--provisional-close PRICE]`: one-shot. Runs one decision cycle up to, but not including, order submission. Prints the fetched-through date, provisional bar, computed target, equity, cash, debit, held position, and the exact order the daemon would place. Use it to debug and smoke-test.

Market handling follows the golden rule: `match` on the strategy's market. This design shipped a `| "us" -> ...` arm that proceeds, plus `| "tw"` and `| _` arms that failed with "live trading supports us only". [Design: TW live trading via Shioaji](./tw-live-trading.md) later filled the `"tw"` arm, and the `| _` arm now fails with "live trading supports us and tw only".

## Daily cycle

All times derive from the clock endpoint's `next_close`.

1. On wake, confirm a trading day via the clock. Otherwise sleep to `next_open`.
2. At `next_close - 15min`, fetch the snapshot. Run the existing Tiingo fetch through the snapshot's `prevDailyBar` date, the previous trading day, and verify that the cache's last date equals it. A stale cache fails the attempt, and the daemon retries the whole step every 60 seconds until the submit cutoff. A cache that stays stale means no trade today.
3. Build today's provisional bar from `dailyBar`, with the latest trade as the provisional close. Append it to cached history, compile the strat, evaluate targets over the whole series on the engine's standard path, and take the last bar's target exposure.
4. Read the signed account cash, the long and short market values, and the held position. Value the position at the provisional price. Map a negative cash balance to one margin debit, and split the position into cash and margin inventories. Pass that one-asset state to `Engine.plan_fills`. Net its ordinary buy and sell legs into one fractional order, truncated to 9 decimal places; refinancing pairs place no order. Skip a buy below USD 1. Cap a sell at the held position, and sell every held share when the planned final value is zero.
5. Before `next_close - 2min`, look up today's client_order_id (`bt-<symbol>-<YYYY-MM-DD>`). If that order exists, do not resubmit. Otherwise submit one fractional `market` order with `time_in_force=day`. Once the request goes out, the day ends there with no retry, because the request may have reached Alpaca and a retry could submit twice. A failed request logs `order submission uncertain ... order=skip`, a `rejected` status logs `Alpaca rejected the order order=skip`, and a failure while following the submitted order also logs `order=skip`.
6. After the close, poll the order by client_order_id until it reaches a terminal status or 5 minutes pass. Log the fill price and status, then sleep past `next_open`.

> [!NOTE]
> 2026-09-29: the strategy's `rebalance` statement now selects drift handling in both live paths; see [Design: rebalance statement](./rebalance-statement.md). Under `rebalance daily`, step 4 sizes an order every session. Under `rebalance on_change`, or without a declaration, step 4 first compares the last bar's effective target with the previous bar's and skips the session with `target unchanged` when they are equal. For an undeclared strategy, the daemon logs one warning right after the `startup` line. Under on_change, the position keeps its gap from target until the target next changes, whether the gap comes from ordinary price drift, a target that flips between the provisional decision price and the final close, a missed or rejected session, or a partial fill. `rebalance daily` re-plans toward the target every session but skips a buy under USD 1. Under daily, the backtest re-plans after a simulated next-open cure. Neither daemon detects a broker margin call; under daily, the next session buys back toward the target like any other shortfall.

> [!NOTE]
> 2026-09-30: US sizing now uses the backtest fill planner, with the account debit mapped into one margin lot; see [Design: US live planner](./us-live-planner.md). The decision fails when account cash is not finite, when the account holds a short or another symbol, or when mapped equity is not positive. Posted margin interest reaches the mapped state through cash. The state sets unposted interest to zero.

Margin: a target above 1.0 is a larger position. bt caps the US effective target at 2.0: `Engine.effective_targets` scales a target so that `target x (1 - ratio)` stays at or below 1, and the US Reg T initial-margin ratio is 0.5. Alpaca's account `multiplier` does not set that cap; the recorded account fixture reports 4. Alpaca enforces its own buying power and overnight maintenance: price-band requirements of 100%/50%/30%, plus 50%/75% house requirements for 2x/3x leveraged ETFs. Alpaca charges margin interest on the settlement-date debit at 6.50% per year for non-elite accounts or 5.00% for elite accounts, per [Alpaca: Margin and Short Selling](https://docs.alpaca.markets/us/docs/margin-and-short-selling) (updated 2026-09-17). The charge is `debit x rate / 360` per day, accrued daily and posted at month end. bt's US backtest financing default stays 6.25%; `bt run --financing-rate PERCENT` overrides it. bt reads no unposted interest from the account, so live sizing can overstate equity by up to about one month of interest before posting: at 6.50%, 31 days is about 0.56% of the debit. bt's default maintenance table omits the leveraged-ETF add-ons; `bt run --maintenance-ratio PERCENT` replaces the whole table with one flat rate for those ETFs. bt's maintenance and cure machinery stays backtest-only. bt logs a buying-power rejection and skips the day. Alpaca values buys at the far side of the NBBO, slightly tighter than the provisional price.

## Safety and failure

- Fail-safe posture: the daemon does not act on data it cannot verify. The original design ended the day on the first failure, so one transient network error could skip a session. Now a failure before the order request (stale cache, fetch error, snapshot error, evaluation error, clock or order-lookup error) logs `order=retry`, and the daemon retries every 60 seconds while the submit cutoff has not passed. Each retry looks up today's client_order_id first. At or after the cutoff, a failed order lookup logs `order=skip` and ends the day. Any failure after the order request, including a `rejected` status, still ends the day with no retry.
- Paper is the default. On startup the daemon logs mode, account number, and equity. It refuses to start if the account status is not ACTIVE or trading is blocked.
- No state file: the account is the state. Each cycle reads the live position before it decides. Under `rebalance daily`, the cycle sizes from that position every session, so the first session after a crash and restart re-plans toward the target. Under `rebalance on_change`, a session missed before a target change stays uncorrected until the target changes again. The deterministic client_order_id plus query-then-submit prevents double orders across restarts.
- Logging: append-only ASCII text. Each decision logs one line with date, fetched-through date, provisional close, target, equity, held, order or skip reason, and `fill=pending`. For a new submission, the daemon writes that line only after the order lookup and the pre-submit clock check succeed, so a failed attempt that retries writes none. When the lookup finds today's order already placed, the line follows the lookup alone. A separate line records the fill status, fill price, and filled quantity.

## Testing and verification

- Pure logic under TDD: share sizing and 9-decimal truncation, order diff and threshold, client_order_id construction, mode-to-URL selection, and the staleness check against the previous trading day.
- JSON parsing (snapshot, account, position, order) against recorded fixture responses, mirroring the Tiingo fetcher's fixture tests. Numeric strings parse with the same decimal handling.
- The engine is untouched: the TW 00685L byte-identity gate must hold at every commit.
- Live smoke: `bt target` against the paper account, output inspected by hand. Then `bt live` on paper across sessions before any `--live` promotion.

## Docs

- `docs/cli.md`: both subcommands, flags, environment variables, and the mode default.
- `docs/engine.md`: one line in the simulation-vs-market gap section noting that the live daemon implements the close-fill assumption with provisional evaluation at close minus 15 minutes plus a near-close market order.
- `CHANGELOG.md`: Added entry under `[Unreleased]`.

## Non-goals

- Multi-strategy netting, virtual books, or more than one account.
- TW live trading in this design. The market match leaves room for a new arm, which [Design: TW live trading via Shioaji](./tw-live-trading.md) later filled.
- Live replication of financing-interest accrual, broker maintenance, or margin-call cures. US order sizing itself uses the engine planner.
- Intraday trading, extended hours, and order types other than the fractional market day order.
- Dividend cash modeling in the live loop.
