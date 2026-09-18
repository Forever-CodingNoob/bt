# Design: TW live trading via Shioaji

Date: 2026-09-06
Status: implemented for TW simulation and production

> [!IMPORTANT]
> Verified across 2026-09-16 through 2026-09-18: spendable cash is `acc_balance + T+1 + T+2` using signed settlement amounts, and equity is spendable cash plus Common-lot position value minus loans and interest. The TWD -107 purchase payable moved from T+2 to T+1 while `acc_balance` stayed TWD 100,000, then appeared at T+0 when `acc_balance` fell to TWD 99,893. The bank balance therefore already reflects T+0 on settlement morning. Production still requires and logs exactly one T+0 row for window validation and audit, but excludes it from the sum.

## Contents

- [Goal](#goal)
- [Decisions](#decisions)
- [Verified Shioaji facts](#verified-shioaji-facts)
- [Modules](#modules)
- [Daily cycle](#daily-cycle)
- [Safety and failure](#safety-and-failure)
- [Command surface](#command-surface)
- [Testing and verification](#testing-and-verification)
- [Docs](#docs)
- [Authoritative sources](#authoritative-sources)
- [Non-goals](#non-goals)

## Goal

Extend `bt live` and `bt target` to the Taiwan market through SinoPac's Shioaji API, so the same strategies validated by the daily backtester use the same planner for DAILY simulation or production execution, including margin financing. The US path, the daily engine, `bt fetch`, and all backtest outputs stay byte-identical.

## Decisions

- Fill discipline: decide at 13:20 Taipei on the live near-close quote and submit immediately into continuous trading. The backtester's close-fill assumption is a stand-in for "the price minutes before the close" because FinMind daily data has no intraday bar. Orders are not held for the 13:25-13:30 closing call and the after-hours fixed-price session is not used.
- Order discipline: every Common-lot leg is `price_type: MKT`, `order_type: IOC`, and `price: 0`, matching the official Shioaji stock-order fields. The executor rechecks the session and the `< 13:25` cutoff before every order and while polling it.
- Margin from day one: exposure the engine funds with an exchange-ratio loan goes out as `order_cond: MarginTrading`; cash-inventory exposure as `order_cond: Cash`. The broker runs the actual loans, interest, and maintenance; bt's maintenance and call machinery stays backtest-only.
- Engine alignment: the daemon does not reinvent sizing. The engine's per-bar fill planner is an exported pure function used by both `Engine.run` and TW decision planning. TW execution additionally floors lots and applies confirmed-fill cash and inventory constraints between orders.
- Transport: the official Shioaji HTTP server (`shioaji server start`) reads its local `.env` with `SJ_API_KEY`, `SJ_SEC_KEY`, `SJ_CA_PATH`, `SJ_CA_PASSWD`, and `SJ_PRODUCTION`. `bt` reaches it through `SHIOAJI_URL`, default `http://localhost:8080`, using curl and jq. Client-side `SJ_API_KEY` and `SJ_SEC_KEY` are optional; `bt` sends `Authorization: Bearer <key>:<secret>` only when both are set and nonempty, for servers that enforce Bearer authentication. The CA path, CA password, and production setting remain server-only.
- Board lots only: quantities are floored to `Common` lots of 1000 shares; the remainder is logged and retained. Odd lots are a non-goal.
- One strategy, one stock account; simulation by default, `--live` requests production. Production derives broker cash and equity before sizing.

## Verified Shioaji facts

- The official HTTP-server setup documents `shioaji server start`, the local `.env`, port 8080, and `GET /api/v1/info` with a `simulation` field. `SJ_PRODUCTION=false` or unset is simulation; `true` is production.
- The official simulation page lists the APIs supported in simulation. Its omission of `account_balance` is not treated here as proof of runtime behavior. The implemented simulation path does not call `account_balance`; it requires user-supplied `--equity`.
- Authentication: a 2026-09-18 real-server probe returned HTTP 200 from `POST /api/v1/portfolio/account_balance` without an `Authorization` header. Trading requests therefore omit the header when either optional client credential is absent or empty.
- Snapshot: `POST /api/v1/data/snapshots` with `{"contracts":[{"security_type":"STK","exchange":"TSE"|"OTC","code":"..."}]}` returns a snapshot array with `datetime`, `open`, `high`, `low`, `close`, `buy_price`, `sell_price`, and `total_volume`.
- Place order: `POST /api/v1/order/place_order` accepts contract data and stock-order fields including `action`, `price`, `quantity`, `price_type`, `order_type`, `order_lot`, `order_cond`, `custom_field`, and optional `account`. The official stock-order reference permits `MKT` and `IOC`; the implemented request uses `price: 0`, `MKT`, `IOC`, and `Common`.
- Order status: `POST /api/v1/order/trades` with `{}` returns trades with order identity, status, order and deal quantities, deal prices, and either a string `status.order_datetime` or numeric epoch-seconds `status.order_ts`. A placement initially reported as `PendingSubmit` must be queried through this endpoint before its result is known.
- Positions: `POST /api/v1/portfolio/position_unit` with `{"account_type":"S","unit":"Common"}` returns position condition, Common-lot quantity, last price, margin purchase amount, and interest used by simulation planning.
- Position details: `POST /api/v1/portfolio/position_detail` with `{"account_type":"S","detail_id":ID}` uses the aggregate position's integer `id` and returns dated per-lot stock details. A read-only `detail_id:0` probe returned `[]` for the empty account.
- Balance and settlements: a real-account probe began on 2026-09-16 with `acc_balance` TWD 100,000 and zero T+0 through T+2 amounts. After a one-share 0050 buy filled at TWD 106.45, the rounded TWD -107 payable appeared at T+2 on 2026-09-16, moved to T+1 on 2026-09-17 while `acc_balance` remained TWD 100,000, and moved to T+0 on 2026-09-18 when `acc_balance` fell to TWD 99,893. The Share-unit response reported quantity 1, average price TWD 107.0, and last price TWD 106.2. Negative settlement amounts are payables and positive amounts are credits.
- Accounts: orders omit `account` and therefore use the server's default stock account.
- CA: the official setup requires `SJ_CA_PATH` and `SJ_CA_PASSWD` for production order placement.

## Modules

The implemented layout is:

- `broker/shioaji.ml` + `.mli`: REST client for server info, snapshots, aggregate positions, dated position details, balance, settlements, Common-lot order placement, and today's trades. The base URL comes from `SHIOAJI_URL`; optional `SJ_API_KEY` and `SJ_SEC_KEY` add Bearer authentication only when both are nonempty.
- `engine/engine.ml` + `.mli`: exported pure fill planner used by the unchanged daily engine path and TW decision planning.
- `broker/live.ml` + `.mli`: TW decision, broker-derived production cash and equity, independent-calendar preparation, 18-month position-detail rollover planning, Common-lot translation, and sequential confirmed-fill execution beside the unchanged US arms.
- `market/data.ml` + `.mli`: FinMind `TaiwanStockTradingDate` query for the latest trading day strictly before the session plus adjustment-only refresh through the current session without advancing raw prices.
- `bin/bt.ml`: `bt live` and `bt target` accept TW, expose simulation `--equity TWD`, and reject that override in production.

## Daily cycle

Implemented TW simulation and production behavior, using fixed UTC+8 Asia/Taipei wall time:

1. On weekends, sleep toward Monday. On a weekday at or after 13:05, require a Shioaji snapshot dated today. A holiday or stale snapshot fails the day's cycle without trading.
2. Query FinMind's independent `TaiwanStockTradingDate` dataset for the latest session strictly before today. Fetch prices through that date, refresh dividend factors, cash dividends, and corporate-action events through today, and require the loaded price cache to end exactly at the previous session. Cached price dates are never used as the calendar.
3. At 13:20, request a fresh snapshot and validate its session plus internally consistent finite positive OHLCV fields. Build the provisional bar, evaluate the unchanged DSL path, and compute the final effective TW target.
4. Read Common-lot aggregate positions and dated `position_detail` rows for each margin position id. Simulation takes total equity from required `--equity TWD` and infers cash as equity minus cash inventory value minus margin inventory value plus loan principal plus interest. Production requires exactly one broker settlement row for each of T+0, T+1, and T+2 with no other T-day rows, computes spendable cash as `acc_balance + T+1 + T+2`, and values equity from that cash plus broker position values minus loans and interest. T+0 is already reflected in `acc_balance`; it remains required for window validation and audit but is excluded from the sum. Pending T+1 and T+2 settlements change the cash budget but never skip the session. A nonzero holding in another symbol is rejected.
5. For each dated `MarginTrading` lot at or beyond the engine's 18-calendar-month, month-end-clamped maturity, prepend a margin sell/rebuy pair before ordinary cash and margin planner legs. Floor every leg to 1000-share Common lots and retain the remainder.
6. Before each leg, require the Taipei date to remain the planned date and `13:20:00 <= now < 13:25:00`. Submit `MKT` + `IOC`, then refresh and poll its status. A successor is eligible only after one matching order record confirms the predecessor's complete fill and finite positive weighted price.
7. Carry cash and inventory forward from confirmed fills. A refinance rebuy requires its entire original lot count to remain funded. A capped ordinary buy stops with its remainder and every later leg unsubmitted. After 13:30, query and log today's resulting trades.

The pre-plan query for today's orders is conservative deduplication, not an exactly-once guarantee. A crash between orders or two concurrent daemons can still leave ambiguous exposure. A refinance sell and rebuy are sequential orders, not atomic. If a matured lot's sale cannot fund its complete Common-lot rebuy, dependent-leg gating stops after the sale; unlike the fractional daily engine, the daemon does not partially restore that lot.

## Safety and failure

- Fail-safe: an unavailable server, calendar or fetch failure, stale cache, stale or invalid snapshot, evaluation error, unsupported inventory, order-placement uncertainty, missing or ambiguous status, mismatched order fields, partial or failed fill, timeout, or cutoff stops every remaining leg. The daemon logs any observed trade and resulting exposure.
- Confirmation: the executor never infers a fill from successful POST return. It requires the placed order ID and one refreshed matching trade with `Filled`, full deal lots, and a finite positive weighted price before submitting a successor.
- Mode: simulation requires `--equity TWD` and `info.simulation = true`. Production rejects `--equity` and requires `info.simulation = false`.
- Startup: simulation logs the override equity. Production logs `acc_balance`, each T+0 through T+2 amount, derived spendable cash, and derived equity.
- No local state file: read-back account and trade state drive each cycle, subject to the documented lack of an exactly-once concurrent-process guarantee.
- Daily production: pending T+1 or T+2 payments alter spendable cash but do not suppress planning or execution. T+0 remains required and logged for audit, but is already reflected in `acc_balance`.

## Command surface

```
bt live STRAT [--live] [--equity TWD] [--data-dir DIR]
bt target STRAT [--live] [--equity TWD] [--data-dir DIR] [--provisional-close PRICE]
```

The market arm is chosen from the strategy's `stock "tw/..."` declaration. `--provisional-close` supplies a TW provisional price dated from the local Taipei clock, but still enforces server mode, independent-calendar lookup, historical fetch, and exact cache freshness. `SHIOAJI_URL` overrides the server address.

## Testing and verification

- Offline fixtures cover Shioaji server info, snapshots, mixed cash and margin positions, balance, settlements, placement responses, and refreshed trade statuses through production parsers.
- The exported engine planner has hand-derived two-inventory checks; the TW daily backtest output remains byte-identical to the standing reference.
- Calendar checks cover strict FinMind response parsing and a Tuesday-after-Monday-holiday previous session. TW decisions require the independent previous session and exact cache end date.
- Production checks derive TWD 99,893 for each day of the observed payable window: TWD 100,000 with T+2 or T+1 at TWD -107, and TWD 99,893 with T+0 at TWD -107. They also cover positive sale credit, malformed settlement-window rejection, non-finite rejection, and a decision with injected broker balance, settlements, and positions.
- Execution checks cover zero-lot plans; full sequential sell, refinance, and buy progress; confirmed-price cash updates; partial, failed, missing, mismatched, ambiguous, and timed-out statuses; cutoff before a successor; capped buys; and retained residual legs.

## Docs

- `docs/cli.md` documents TW target and daemon simulation and production, server environment, mode guards, cash and equity sourcing, lot flooring, and confirmed-fill execution.
- `docs/engine.md` distinguishes the daily close-fill backtest from the TW broker-backed daemon.
- `CHANGELOG.md` records simulation and production support under `[Unreleased]`.

## Authoritative sources

- [Shioaji HTTP server setup](https://sinotrade.github.io/env_setup/other/) documents installation, `.env` fields, server mode, CA activation, port 8080, and the info endpoint.
- [Shioaji simulation](https://sinotrade.github.io/tutor/simulation/) documents the simulation environment and its supported API list; this design does not infer undocumented `account_balance` behavior from that list.
- [Shioaji stock orders](https://sinotrade.github.io/tutor/order/Stock/) documents `MKT`, `IOC`, `Common`, order conditions, placement, and status refresh.
- [FinMind Taiwan technical datasets](https://finmind.github.io/tutor/TaiwanMarket/Technical/#taiwanstocktradingdate) documents the independent `TaiwanStockTradingDate` dataset.
- [TWSE trading mechanism](https://www.twse.com.tw/en/products/system/trading.html) documents continuous trading through 13:25 and the 13:25-13:30 closing call.

## Non-goals

- Futures, options, odd lots, short selling (`ShortSelling`, SBL), the fixed-price after-hours session, any closing-auction fallback.
- TW intraday trading; the daemon stays daily.
- Automated response to margin calls; the daemon only logs what it reads back.
- Multiple accounts or strategies.
- Any change to daily backtest behavior, the US live path, or `bt fetch`.
