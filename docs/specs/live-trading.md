# Design: live trading via Alpaca

Date: 2026-09-04
Status: approved

## Goal

Run one bt strategy live against one Alpaca account as a long-running daemon. The daemon computes the same signals the backtester computes, on the same compiled code path, and places market-on-close orders so the live fill discipline matches the `--fill close` assumption the strategies were validated under. Everything lives in the bt repo; no new project and no new dependencies.

## Decisions (settled during design)

- Long-running daemon, not a one-shot cron job.
- Fill discipline: provisional close + MOC. The engine's close-fill model assumes the decision price equals the official close, which in reality means acting minutes before the close on a near-close price. The daemon is the live counterpart of that assumption; the residual decision-to-auction drift is the slippage band the fill-sensitivity experiment measured.
- One strategy, one account. The account's positions are the strategy's book. Multi-strategy netting is a non-goal.
- Paper by default. `--live` is the only way to reach the real account.
- History comes from Tiingo through the existing `bt fetch` routine. Alpaca supplies only the current in-progress daily bar and account state.
- Signal evaluation reuses the DSL compiler and engine target evaluation unchanged. Reimplementing signal logic outside the engine is prohibited: the moment live recomputes signals with separate code, backtest and live can disagree and neither can be trusted.

## Verified Alpaca facts (primary sources, docs.alpaca.markets, 2026-09-04)

- Trading API base URLs: `https://paper-api.alpaca.markets` (paper) and `https://api.alpaca.markets` (live). Same API spec; only endpoint and key pair differ.
- Market Data API base URL: `https://data.alpaca.markets`.
- Auth: headers `APCA-API-KEY-ID` and `APCA-API-SECRET-KEY` on both APIs. Keys come from the environment; separate pairs per mode.
- MOC: `type=market` with `time_in_force=cls`, eligible only in the closing auction. Submitted after 3:50pm ET and before 7:00pm ET: rejected. After 7:00pm ET: queued for the next day's auction. This design submits whole shares only, which sidesteps any fractional-order TIF restriction.
- Snapshot: `GET /v2/stocks/{symbol}/snapshot` returns `dailyBar` (today's running o/h/l/c/v), `prevDailyBar`, `latestTrade`, `latestQuote`. Free tier uses `feed=iex`; the provisional price can deviate slightly from the consolidated tape, inside the measured slippage envelope.
- Clock: `GET /v2/clock` returns `timestamp`, `is_open`, `next_open`, `next_close` (RFC3339 with offset). The calendar includes early-close days, so all scheduling anchors to `next_close`, never to a hardcoded 16:00.
- Account: `GET /v2/account`; `equity` = cash + long market value + short market value. All numeric fields are JSON strings.
- Position: `GET /v2/positions/{symbol}`; `qty` is a string; no position returns 404 (treated as qty 0).
- Orders: `POST /v2/orders`; `client_order_id` is a client-supplied unique id (max 128 chars); an order is queryable by it. Duplicate-id rejection is not documented, so idempotency must not rely on it.
- Paper accounts default to $100k, use IEX data, and do not simulate dividends. Equity is read from the account endpoint either way, so sizing stays correct; paper results understate dividend cash relative to a backtest.

## Architecture

New modules, each with an `.mli` interface file:

- `lib/alpaca.ml` + `lib/alpaca.mli`: REST client in the same curl+jq subprocess style as the existing fetch code. Mode (paper or live) selects the base URL. Surface: clock, account, position for one symbol, order submit, order lookup by client_order_id, and the data-API snapshot.
- `lib/live.ml` + `lib/live.mli`: the daily cycle and the one-shot evaluation shared by both subcommands.

`bin/bt.ml` gains two subcommands:

- `bt live <strat> [--live] [--data-dir DIR]`: the daemon.
- `bt target <strat> [--live] [--data-dir DIR]`: one-shot. Runs one decision cycle up to but excluding order submission; prints fetched-through date, provisional bar, computed target, equity, held position, and the exact order the daemon would place. This is the debugging and smoke-test entry point.

Market handling follows the golden rule: `match` on the strategy's market with `| "us" -> ...` proceeding and `| "tw"` and `| _` arms erroring with "live trading supports us only".

## Daily cycle

All times derive from the clock endpoint's `next_close`.

1. On wake, confirm a trading day via the clock; otherwise sleep to `next_open`.
2. At `next_close - 15min`: run the existing Tiingo fetch. Verify the cache's last date equals the previous trading day. Stale cache means no trade today.
3. Fetch the snapshot. Build the provisional bar for today from `dailyBar`, with the latest trade as provisional close. Append it to cached history, compile the strat, evaluate targets over the whole series on the engine's standard path, and take the last bar's target exposure.
4. Read account equity and held position. Desired shares = floor(target x equity / provisional price). Delta = desired - held. If |delta x price| is below the minimum order threshold (default $1), skip.
5. By `next_close - 10min`: check for an existing order with today's client_order_id (`bt-<symbol>-<YYYY-MM-DD>`); if present, do not resubmit. Otherwise submit one market order, `time_in_force=cls`, whole shares.
6. After the close, poll the order by client_order_id, log the fill price and status, and sleep past `next_open`.

Margin: targets above 1.0 are just larger sizes. Alpaca's margin engine enforces its own limits: Reg T 50% initial margin (account `multiplier` 2, so position value <= 2x equity, which caps the reachable target at 2.0), the tiered overnight maintenance table bt already models (100%/50%/30% by price band, 50%/75% house add-ons for leveraged ETFs), and financing at 6.25%/yr standard tier charged as debit x rate / 360. These match bt's US backtest defaults by construction. bt's maintenance and cure machinery stays backtest-only. A buying-power rejection (Alpaca values buys at the far side of the NBBO, slightly tighter than the provisional price) is logged and the day is skipped.

## Safety and failure

- Fail-safe posture: every failure (stale cache, fetch error, snapshot error, evaluation error, order rejection) ends today's cycle with a loud log line and no order. The daemon never acts on data it cannot verify.
- Paper is the default. On startup the daemon logs mode, account number, and equity, and refuses to start if the account status is not ACTIVE or trading is blocked.
- No state file. The account is the state. Every cycle recomputes desired shares from scratch and diffs against the live position, so a crash and restart self-corrects. The deterministic client_order_id plus query-then-submit prevents double orders across restarts.
- Logging: append-only ASCII text, one line per decision with date, fetched-through date, provisional close, target, equity, held, order or skip reason, and fill result.

## Testing and verification

- Pure logic under TDD: share sizing and flooring, order diff and threshold, client_order_id construction, mode-to-URL selection, staleness check against the calendar.
- JSON parsing (snapshot, account, position, order) against recorded fixture responses, mirroring the Tiingo fetcher's fixture tests. Numeric strings parse with the same decimal handling.
- The engine is untouched: the TW 00685L byte-identity gate must hold at every commit.
- Live smoke: `bt target` against the paper account, output inspected by hand. Then `bt live` on paper across sessions before any `--live` promotion.

## Docs

- `docs/cli.md`: both subcommands, flags, environment variables, and the mode default.
- `docs/engine.md`: one line in the simulation-vs-market gap section noting the live daemon implements the close-fill assumption via provisional evaluation at close minus 15 minutes plus MOC submission.
- `CHANGELOG.md`: Added entry under `[Unreleased]`.

## Non-goals

- Multi-strategy netting, virtual books, or more than one account.
- TW live trading (no MOC-equivalent path is designed; the market match keeps the door open as a new arm).
- Live replication of the engine's margin financing, maintenance, or cure logic.
- Intraday trading, extended hours, order types other than MOC, and fractional shares.
- Dividend cash modeling in the live loop.
