# Design: TW live trading via Shioaji

Date: 2026-09-06
Status: approved

## Goal

Extend `bt live` and `bt target` to the Taiwan market through SinoPac's Shioaji API, so the same strategies validated by the daily backtester run live with the same sizing, including margin financing. The US path, the daily engine, `bt fetch`, and all backtest outputs stay byte-identical.

## Decisions (settled during design)

- Fill discipline: decide at 13:20 Taipei on the live near-close quote and submit immediately into continuous trading. The backtester's close-fill assumption is a stand-in for "the price minutes before the close" (FinMind has no intraday data), so this is its honest live realization. Orders are not held for the 13:25-13:30 closing call and the after-hours fixed-price session is not used.
- Margin from day one: exposure the engine funds with an exchange-ratio loan goes out as `order_cond: MarginTrading`; cash-inventory exposure as `order_cond: Cash`. The broker runs the actual loans, interest, and maintenance; bt's maintenance and call machinery stays backtest-only.
- Engine alignment: the daemon does not reinvent sizing. The engine's per-bar fill planner (cash-first buys, standard-ratio loans, sell allocation across the two inventories) is extracted into an exported pure function, `Engine.run` partially applies it, and the daemon calls it with live account state. Behavior preservation is proven by the TW byte-identity gate.
- Transport: the official Shioaji HTTP server (`shioaji server start`, a local Rust binary reading a `.env` with `SJ_API_KEY`, `SJ_SEC_KEY`, `SJ_CA_PATH`, `SJ_CA_PASSWD`, `SJ_PRODUCTION`) on `http://localhost:8080`. bt speaks curl+jq to it exactly as it does to Tiingo and Alpaca; no Python enters bt and no opam dependency is added. The server process is the one external prerequisite.
- Board lots only: quantities are floored to `Common` lots of 1000 shares; the remainder is logged. Odd lots are a non-goal.
- One strategy, one stock account; simulation by default, `--live` for production.

## Verified Shioaji facts (sinotrade.github.io, 2026-09-06)

- Server: `shioaji server start` reads `.env`, logs in, activates the CA, serves REST on port 8080. `GET /api/v1/info` returns `{"simulation": bool, ...}`. `SJ_PRODUCTION=false` (or unset) is simulation.
- Simulation APIs: `snapshots`, `kbars`, `place_order`, `update_order`, `cancel_order`, `update_status`, `list_trades`, `list_positions`, `list_profit_loss`. `account_balance` is NOT available in simulation. Simulation does not support odd lots.
- Snapshot: `POST /api/v1/data/snapshots` with `{"contracts":[{"security_type":"STK","exchange":"TSE"|"OTC","code":"..."}]}`; response array with `datetime` (ISO, Taipei local), `open`, `high`, `low`, `close` (last), `buy_price`, `sell_price`, `total_volume`. Documented as a request-type query, not a feed: the daemon calls it at most twice a day.
- Place order: `POST /api/v1/order/place_order` with `contract` (as above) and `stock_order` `{action: Buy|Sell, price, quantity (lots), price_type: LMT|MKT, order_type: ROD|IOC|FOK, order_lot: Common|Fixing|Odd|IntradayOdd, order_cond: Cash|MarginTrading|ShortSelling|..., custom_field (6 alphanumerics), account}`. Response is a Trade with `order.id`, `status.status` (`PendingSubmit` initially).
- Order status: `POST /api/v1/order/update_status` with `{"account": {broker_id, account_id}}` returns Trades with `status.status` in `{Cancelled, Filled, PartFilled, Inactive, Failed, PendingSubmit, PreSubmitted, Submitted}`, `order_quantity`, `deal_quantity`, `deals[].price`, and `order_datetime` (ISO +08:00). `custom_field` is not echoed in responses.
- Positions: `POST /api/v1/portfolio/position_unit` with `{"account_type":"S","unit":"Common"}` returns per position `code`, `direction`, `quantity` (lots under `Common`), `price`, `last_price`, `yd_quantity`, `cond` in `{Cash, Netting, MarginTrading, ShortSelling, Emerging}`, `margin_purchase_amount`, `collateral`, `interest`.
- Balance: `POST /api/v1/portfolio/account_balance` returns `acc_balance` (settlement account cash), `date`, `errmsg`. Production only.
- Accounts: login returns stock and futures accounts with `signed`; orders default to the server's default stock account when `account` is omitted.
- CA: required for production orders; absent CA means the server refuses orders, not bt.

## Modules

Per-concern layout; every new module ships its `.mli`.

- `broker/shioaji.ml` + `.mli` (new): REST client. Base URL from `SHIOAJI_URL` (default `http://localhost:8080`), no credentials in bt. Surface: `info`, `snapshot ~exchange ~code`, `positions` (parsed into cash and margin entries with lots, loan amount, interest), `balance`, `place_order` (typed record for the stock_order fields), `orders_today ~code` (via `update_status` then `list_trades`, filtered by `order_datetime` date and code), all with pure parse functions over recorded JSON.
- `engine/engine.ml` + `.mli` (extraction only): the per-bar fill planner lifted to a top-level exported pure function with explicit state arguments; `run` partially applies it at its existing call site. Exact shape pinned from the code at implementation time. No behavior change.
- `broker/live.ml` (additive arms): `decide` and the daemon gain `| "tw" ->` arms; the `"us"` arms are untouched. Market-neutral cycle pieces (logging, fail-safe wrapper, query-then-submit shape) are reused.
- `market/data.ml`: read-only reuse of the stockinfo classification to map a symbol to `TSE` or `OTC` (the same table that resolves the financing ratio).
- `bin/bt.ml`: no new subcommand. `bt live` and `bt target` stop rejecting `tw`; new flags `--equity TWD` (required in simulation, rejected in production) and the existing `--live`.

## Daily cycle (Asia/Taipei, fixed +8, no DST)

1. Wake. Weekend: sleep to Monday 13:00. Weekday: at 13:05 probe the snapshot; a `datetime` not dated today means a holiday: sleep to tomorrow.
2. 13:05: run the existing FinMind fetch for the symbol; verify the cache's last date equals the previous trading session (the snapshot's `datetime` date minus one session, derived from the cache calendar). Stale means no trade today.
3. 13:20: snapshot gives the near-close quote and today's running OHLC. Build the provisional bar (close = `close`, or the bid/ask midpoint when `close` is stale), append it, evaluate through the unchanged DSL and engine path, and take the final-bar target through `Engine.effective_targets` with the TW profile.
4. Read live state: positions (cash lots, margin lots, loan amount, interest) and equity (production: `acc_balance` plus position values minus loans and interest; simulation: `--equity`). Convert lots to shares. Call the extracted engine planner with that state and the target; receive planned buys and sells per inventory in shares.
5. Translate to orders: floor each leg to lots; drop legs below one lot with a log line; submit each remaining leg immediately as `price_type: MKT`, `order_type: ROD`, `order_lot: Common`, `order_cond` per inventory (`Cash` or `MarginTrading`), `custom_field` = `bt` + `MMDD`. Sells of margin inventory go out as `MarginTrading` sells (the broker repays the loan), cash-inventory sells as `Cash`.
6. After 13:30: `update_status`; log each leg's status, `deal_quantity`, and deal price; sleep to the next session.

Dedup: before step 5, `orders_today ~code` non-empty means today's plan was already submitted (possibly partially); log and skip. A crash between legs therefore never double-submits; the next session's plan starts from read-back positions and self-corrects.

## Safety and failure

- Fail-safe: any failure (server unreachable, stale cache, stale snapshot, evaluation error, rejected leg) ends the day's cycle with one ASCII log line and no further action. No retries into the closing call window. A partially filled multi-leg plan is logged and left for the next session.
- Mode: simulation by default. `--live` refuses to start unless `info.simulation` is false. In simulation, `--equity TWD` is required and its value is logged on every decision so simulated sizing is never mistaken for account truth; in production, `--equity` is a usage error and equity comes from the broker.
- Startup banner: mode, broker and account id, equity source and value.
- No state file: the account is the state.
- Logging: append-only ASCII, one line per decision with date, fetched-through date, provisional close, target, equity, cash lots, margin lots, loan, planned legs, submitted or skip reason, and fill results.

## Command surface

```
bt live STRAT [--live] [--equity TWD] [--data-dir DIR]
bt target STRAT [--live] [--equity TWD] [--data-dir DIR] [--provisional-close PRICE]
```

The market arm is chosen from the strategy's `stock "tw/..."` declaration. `--provisional-close` works for tw as it does for us (fabricated snapshot, session date from the local Taipei clock). `SHIOAJI_URL` overrides the server address.

## Testing and verification

- Fixture tests for every Shioaji JSON shape (info, snapshot, positions with mixed Cash and MarginTrading entries, balance, place_order response, update_status trades) through the production parse functions; no network in tests.
- Engine planner extraction: red test that the extracted function reproduces the planner's decisions on a hand-derived two-inventory case; TW byte-identity gate proves `run` unchanged.
- Pure tests: Taipei schedule arithmetic (weekend, 13:05, 13:20, post-13:30 phases), lot flooring with remainder, TSE/OTC mapping, equity derivation from balance and positions, dedup predicate on `order_datetime` dates.
- Plan translation: hand-derived cases for target 0 -> 1.0 (cash leg only), 1.0 -> 2.0 (margin leg), 2.0 -> 0 (two sells), and a sub-lot remainder.
- Gates at every commit, all in the `/sandbox/stock-tw-live` worktree: build clean, suite green, TW byte-identity against the standing reference; `/sandbox/stock` is never built.
- Smoke: requires the user's SinoPac API key and a running `shioaji server` in simulation; `bt target` on the TW strategy first, then supervised `bt live` sessions. Recorded as exact commands and deferred when absent.

## Docs

- docs/cli.md: TW subsections under `bt live` and `bt target` (server prerequisite, `.env` fields, `SHIOAJI_URL`, `--equity`, mode mapping), in the CONTRIBUTING.md documentation style.
- docs/engine.md: TW gap section gains the live counterpart (13:20 decision, near-close continuous fill, lot flooring, unfilled-leg handling, simulation equity caveat).
- CHANGELOG.md: Added entry under [Unreleased].

## Non-goals

- Futures, options, odd lots, short selling (`ShortSelling`, SBL), the fixed-price after-hours session, any closing-auction fallback.
- TW intraday trading; the daemon stays daily.
- Automated response to margin calls; the daemon only logs what it reads back.
- Multiple accounts or strategies.
- Any change to daily backtest behavior, the US live path, or `bt fetch`.
