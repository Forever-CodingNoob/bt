# Design: TW live trading via Shioaji

Date: 2026-09-06
Status: implemented for TW simulation and production

> [!IMPORTANT]
> Verified across 2026-09-16 through 2026-09-18: spendable cash is `acc_balance + T+1 + T+2` using signed settlement amounts, and equity is spendable cash plus position value minus loans and interest. The TWD -107 purchase payable moved from T+2 to T+1 while `acc_balance` stayed TWD 100,000, then appeared at T+0 when `acc_balance` fell to TWD 99,893, so the bank balance already reflects T+0 on settlement morning. Production still requires and logs exactly one T+0 row for window validation and audit, but excludes it from the sum.

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

Extend `bt live` and `bt target` to the Taiwan market through SinoPac's Shioaji API. Strategies validated by the daily backtester then run through the same planner for DAILY simulation or production execution, including margin financing. The US path, the daily engine, `bt fetch`, and all backtest outputs stay byte-identical.

## Decisions

- Fill discipline: decide at 13:20 Taipei on the live near-close quote and submit immediately into continuous trading. FinMind daily data has no intraday bar, so the backtester's close-fill assumption stands in for "the price minutes before the close". The daemon does not hold orders for the 13:25-13:30 closing call and does not use the after-hours fixed-price session.
- Order discipline: every `Common` leg is `price_type: MKT`, `order_type: FOK`, and `price: 0`, matching the official Shioaji stock-order fields. `IntradayOdd` legs are limit `ROD`; see [Design: share quantum and odd lots](./share-quantum-and-odd-lots.md#tw-live-lot-and-odd-lot-orders). The executor rechecks the session and the `< 13:24:30` order cutoff before every order, and the `< 13:25` end of continuous trading while polling it. New orders first shared the `< 13:25` cutoff with polls. Continuous trading ends at 13:25, so new orders now stop 30 seconds earlier; the margin reduces the chance that a checked order reaches the broker in the closing call. It cannot rule that out: a Shioaji request can take up to its 60-second curl timeout, and the server may still forward an order after bt gives up on the request.
- Margin from day one: exposure that the engine funds with an exchange-ratio loan goes out as `order_cond: MarginTrading`, and cash-inventory exposure goes out as `order_cond: Cash`. The broker runs the actual loans, interest, and maintenance; bt's maintenance and call machinery stays backtest-only.
- Engine alignment: the daemon reuses the engine's sizing. `Engine.run` and TW decision planning share one exported pure per-bar fill planner. TW execution also splits legs into lot and odd-lot orders and applies confirmed-fill cash and inventory constraints between orders.
- Transport: the official Shioaji HTTP server (`shioaji server start`) reads its local `.env` with `SJ_API_KEY`, `SJ_SEC_KEY`, `SJ_CA_PATH`, `SJ_CA_PASSWD`, and `SJ_PRODUCTION`. `bt` reaches it through `SHIOAJI_URL`, default `http://localhost:8080`, using curl and jq. Client-side `SJ_API_KEY` and `SJ_SEC_KEY` are optional; `bt` sends `Authorization: Bearer <key>:<secret>` only when both are set and nonempty, for servers that enforce Bearer authentication. The CA path, CA password, and production setting remain server-only.
- Share quantum: the engine floors cash quantities to whole shares and margin quantities to 1000-share lots, and each cash leg goes out as `Common` lots plus one `IntradayOdd` remainder. See [Design: share quantum and odd lots](./share-quantum-and-odd-lots.md).
- One strategy, one stock account, every distinct TW code the strategy declares; simulation by default, `--live` requests production. Production derives broker cash and equity before sizing.

## Verified Shioaji facts

- The official HTTP-server setup documents `shioaji server start`, the local `.env`, port 8080, and `GET /api/v1/info` with a `simulation` field. `SJ_PRODUCTION=false` or unset is simulation; `true` is production.
- The official simulation page lists the APIs supported in simulation. This design does not treat its omission of `account_balance` as proof of runtime behavior. The implemented simulation path does not call `account_balance`; it requires user-supplied `--equity`.
- Authentication: a 2026-09-18 real-server probe returned HTTP 200 from `POST /api/v1/portfolio/account_balance` without an `Authorization` header. Trading requests therefore omit the header when either optional client credential is absent or empty.
- Snapshot: `POST /api/v1/data/snapshots` takes one contract per requested code in `contracts`, each `{"security_type":"STK","exchange":"TSE"|"OTC","code":"..."}`, and returns a snapshot array with `code`, `datetime`, `open`, `high`, `low`, `close`, `buy_price`, `sell_price`, and `total_volume`. bt matches responses to the requested codes in declaration order and rejects missing, duplicate, or extra codes.
- Place order: `POST /api/v1/order/place_order` accepts contract data and stock-order fields including `action`, `price`, `quantity`, `price_type`, `order_type`, `order_lot`, `order_cond`, `custom_field`, and optional `account`. The official stock-order reference permits `MKT` pricing and the `ROD`, `IOC`, and `FOK` order types; the implemented lot request uses `price: 0`, `MKT`, `FOK`, and `Common`. The odd-lot request uses `LMT`, `ROD`, and `IntradayOdd`; see [Design: share quantum and odd lots](./share-quantum-and-odd-lots.md#market-facts).
- Order status: `POST /api/v1/order/trades` with `{}` returns trades with order identity, status, order and deal quantities, deal prices, and either a string `status.order_datetime` or numeric epoch-seconds `status.order_ts`. If a placement first reports `PendingSubmit`, you must query this endpoint before its result is known.
- Positions: `POST /api/v1/portfolio/position_unit` with `{"account_type":"S","unit":"Share"}` returns position condition, share quantity, last price, margin purchase amount, and interest used by planning.
- Position details: `POST /api/v1/portfolio/position_detail` with `{"account_type":"S","detail_id":ID}` uses the aggregate position's integer `id` and returns dated per-lot stock details. A read-only `detail_id:0` probe returned `[]` for the empty account.
- Balance and settlements: a real-account probe began on 2026-09-16 with `acc_balance` TWD 100,000 and zero T+0 through T+2 amounts. After a one-share 0050 buy filled at TWD 106.45, the rounded TWD -107 payable appeared at T+2 on 2026-09-16, moved to T+1 on 2026-09-17 while `acc_balance` remained TWD 100,000, and moved to T+0 on 2026-09-18 when `acc_balance` fell to TWD 99,893. The Share-unit response reported quantity 1, average price TWD 107.0, and last price TWD 106.2. Negative settlement amounts are payables and positive amounts are credits.
- Accounts: orders omit `account` and therefore use the server's default stock account.
- CA: the official setup requires `SJ_CA_PATH` and `SJ_CA_PASSWD` for production order placement.

Production decisions also read two budget endpoints:

| Read | Endpoint | Parsed fields |
|---|---|---|
| Contract info | `GET /api/v1/data/contracts/CODE/info` | `reference`, `limit_up`, `limit_down`, `day_trade`, `unit`, `margin_loan_ratio`, `trading_suspended` |
| Trading limits | `POST /api/v1/portfolio/trading_limits` with `{"account_type":"S"}` | `trading_limit`, `trading_used`, `trading_available`, `margin_limit`, `margin_used`, `margin_available` |

The contract parser treats an absent, null, or non-positive `limit_up` as no usable band. It requires a positive `reference`, a `limit_down` and `limit_up` that bracket it, a `margin_loan_ratio` from 0 to 1, and a `unit` of 1000. Every trading-limit field must be a nonnegative number. Trading limits are available on trading days from 08:30 to 15:00 Taipei ([Shioaji accounting reference](https://github.com/Sinotrade/rshioaji/blob/main/skills/shioaji/references/ACCOUNTING.md)). The production probe readings and the three unmeasured hold questions are in [Measured and unmeasured](./multi-stock-live.md#measured-and-unmeasured).

## Modules

The implemented layout is:

- `broker/shioaji.ml` + `.mli`: REST client for server info, snapshots, contract info, trading limits, aggregate positions, dated position details, balance, settlements, `Common` and `IntradayOdd` order placement, and today's trades. The base URL comes from `SHIOAJI_URL`; optional `SJ_API_KEY` and `SJ_SEC_KEY` add Bearer authentication only when both are nonempty.
- `engine/engine.ml` + `.mli`: exported pure fill planner used by the unchanged daily engine path and TW decision planning.
- `broker/live.ml` + `.mli`: TW decision, broker-derived production cash and equity, the production budget pre-check, independent-calendar preparation, 18-month position-detail rollover planning, lot and odd-lot translation, and phase-batched confirmed-fill execution beside the unchanged US arms.
- `market/data.ml` + `.mli`: FinMind `TaiwanStockTradingDate` query for the latest trading day strictly before the session plus adjustment-only refresh through the current session without advancing raw prices.
- `bin/bt.ml`: `bt live` and `bt target` accept TW, expose simulation `--equity TWD`, and reject that override in production.

## Daily cycle

Implemented TW simulation and production behavior, using fixed UTC+8 Asia/Taipei wall time:

1. On weekends, sleep toward Monday. On a weekday at or after 13:05, require a Shioaji snapshot dated today. A holiday or stale snapshot fails the day's cycle without trading.
2. Query FinMind's independent `TaiwanStockTradingDate` dataset for the latest session strictly before today. Fetch prices through that date, refresh dividend factors, cash dividends, and corporate-action events through today, and require the loaded price cache to end exactly at the previous session. bt never uses cached price dates as the calendar.
3. At 13:20, request a fresh snapshot and validate its session. Open, high, and low must be finite and positive, with low <= open <= high. Volume must be finite and nonnegative. The close must be usable: a finite positive close, or else the midpoint of a finite positive bid/ask pair with bid <= ask. The chosen close must lie within the session's low-high range. Build the provisional bar, evaluate the unchanged DSL path, and compute the effective TW targets for the final and previous bars. Under `rebalance daily`, the planner runs forced and plans back to the effective target every session. Under `rebalance on_change`, or without a declaration, equal effective targets preserve the drifted broker inventory, and a changed target trades from that inventory.
4. Read aggregate positions in shares and dated `position_detail` rows for each margin position id. Simulation takes total equity from required `--equity TWD` and infers cash as equity minus cash inventory value minus margin inventory value plus loan principal plus interest. Production requires exactly one broker settlement row for each of T+0, T+1, and T+2 with no other T-day rows, computes spendable cash as `acc_balance + T+1 + T+2`, and values equity from that cash plus position values at the provisional close minus loans and interest. A non-positive equity fails the session before planning. T+0 is already reflected in `acc_balance`; it remains required for window validation and audit but is excluded from the sum. Pending T+1 and T+2 settlements change the cash budget but never skip the session. A nonzero holding in another symbol is rejected. Planner state is absolute TWD, so capital is 1 and the TWD 1 minimum commission is not rescaled.
5. For each dated `MarginTrading` lot at or beyond the engine's 18-calendar-month, month-end-clamped maturity, prepend a margin sell/rebuy pair before ordinary cash and margin planner legs. Translate the planner's quantities, already floored by the engine's share quantum, into `Common` and `IntradayOdd` orders as described in [Design: share quantum and odd lots](./share-quantum-and-odd-lots.md#tw-live-lot-and-odd-lot-orders).
6. In production, read contract info once per code and trading limits once, then run the budget pre-check described in [Safety and failure](#safety-and-failure). A failed check skips the day before any order. Simulation skips both reads.
7. Before each POST, require the Taipei date to remain the planned date and `13:20:00 <= now < 13:24:30`. Submit `Common` legs as `MKT` + `FOK` and `IntradayOdd` legs as `LMT` + `ROD`, in the phases below. Poll `Common` status while the date holds and `now < 13:25:00`. bt does not poll `IntradayOdd` legs.
8. Carry cash and inventory forward from confirmed `Common` fills and from the full cost of each sent odd-lot buy. After 13:30, query and log today's trades for every code.

| Phase | Placement and confirmation |
|---|---|
| Rollover pairs | Sell, then rebuy the full original lot count of the same code, one leg at a time. |
| Ordinary sells | Place every eligible sell across codes, then poll the placed `Common` orders together: up to five rounds, one second apart, with at most one `orders_today` read per code per round. Pending odd-lot `ROD` sells need no fill confirmation and add no cash. |
| Refinance pairs | Run only after every ordinary `Common` sell is confirmed filled. Sell, then rebuy the full lot count when it is fully funded, one leg at a time. |
| Ordinary buys | Reserve each buy's cost at its quote price from one running cash balance before the next buy is sized. Poll the placed `Common` buys together, and replace each reservation with the deal-price cost. |

A definitive failed buy is logged and its siblings continue. A rejected or uncertain sell, or a `Common` sell that ends with no fill, stops the session before the next phase. The first uncertain leg stops the later placements of its phase, but bt still polls and logs the siblings already placed. A capped ordinary buy sends its funded quantity and leaves its remainder and the later legs unsubmitted. A confirmed fill that takes cash below zero stops with `confirmed fill exceeded cash budget by VALUE`. Nothing is retried after a POST.

> [!NOTE]
> 2026-09-29: the strategy's `rebalance` statement now selects drift handling in both live paths; see [Design: rebalance statement](./rebalance-statement.md). Step 3 passes the declaration to the planner as `force`, and maturity rollover pairs from step 5 run under either choice. For an undeclared strategy, the daemon logs one warning right after the `startup` line. Under on_change, the planner plans no ordinary legs until the target next changes, so the position keeps any gap from ordinary price drift, a target that flips between the provisional decision price and the final close, a missed or rejected session, a partial fill, or a leg sequence that a stop cut short. `rebalance daily` re-plans toward the target every session, though whole-share and 1000-share-lot quanta can leave a residual. Under daily, the backtest re-plans after a simulated next-open cure. Neither daemon detects a broker margin call; under daily, the next session buys back toward the target like any other shortfall.

> [!NOTE]
> 2026-10-04: stage 1 of [Design: multi-stock live trading](./multi-stock-live.md#stages) makes `bt target` decisions for N distinct TW codes in one market. It intersects history, checks the last five union sessions for gaps, compiles and normalizes targets jointly, aggregates account cash and debit, and plans all codes once. Snapshots are fetched in one request and matched by code. Code-tagged rollover pairs precede the phase-ordered ordinary legs. `bt live` still executes one TW code and rejects more with `TW live trading needs one stock in this release`. N-code execution, phase batching, FOK, contract info, trading limits, and the budget pre-check ship in stage 2; this release keeps sequential `MKT` + `IOC` lot execution.

> [!NOTE]
> 2026-10-05: stage 2 of [Design: multi-stock live trading](./multi-stock-live.md#stages) executes all N distinct TW codes in one account. Preparation and decision snapshots each fetch N contracts in one request and validate every code. Rollover pairs run one leg at a time, then ordinary sells are placed across codes and their `Common` orders are polled together, then refinance pairs run one leg at a time, then ordinary buys are placed and polled together. Every ordinary `Common` sell must be fully confirmed before refinances or ordinary buys start. A rejected or uncertain sell, or a `Common` sell that FOK kills with no fill, stops the session before the next phase, including at N = 1. `IntradayOdd` sells stay unpolled `ROD` orders, are exempt from the `Common` confirmation barrier, and contribute no same-session proceeds. Lot legs now use `MKT` + `FOK`; odd legs remain `LMT` + `ROD`. Production decisions read contract info once per symbol and trading limits once per session before any order. Simulation skips these reads because Shioaji's simulation returns zero trading limits. This note supersedes the release boundary of the stage 1 note above.

The pre-plan query for today's orders gives conservative deduplication without an exactly-once guarantee. A crash between orders or two concurrent daemons can still leave ambiguous exposure. A refinance sell and rebuy are sequential, non-atomic orders. If a matured lot's sale cannot fund its complete Common-lot rebuy, dependent-leg gating stops after the sale. The daily engine rebuys the fundable whole lots, but the daemon does not partially restore that lot.

## Safety and failure

- Fail-safe: an unavailable server, calendar or fetch failure, stale cache, stale or invalid snapshot, evaluation error, unsupported inventory, order-placement uncertainty, missing or ambiguous status, mismatched order fields, partial fill, timeout, or cutoff stops every remaining leg. FOK rules out a partial lot fill at the broker, and the partial-fill check stays as a guard. A rejected sell, or a `Common` sell that ends with no fill, stops the session before the next phase; a rejected buy is logged and its siblings continue. The daemon logs each observed trade, the pre-trade holdings, and any stop reason with the unsubmitted legs.
- Confirmation: the executor never infers a `Common` fill from a successful POST return. Before the next phase or pair leg starts, it requires each placed order ID and one refreshed matching trade. That trade shows either `Filled` with full deal lots at a finite positive weighted price, or `Failed`, `Inactive`, `Cancelled`, or `Rejected` with no fill. An FOK kill counts as a no-fill end only when the broker reports one of those four statuses; any other status stops the session as uncertain.
- Budget pre-check: production logs each code's seven contract fields, fails the session when any code is `trading_suspended`, and sums the hold of every buy leg, rollover and refinance rebuys included. A `Common` buy holds `limit_up x lots x unit`, with `reference x 1.10` in place of `limit_up` when the code has no usable band. An odd-lot buy holds its snapshot ask times its shares, or nothing when that ask is zero or negative, because the executor skips such a buy; a non-finite ask fails the check with `TW budget inputs are not finite`. Sells offset nothing. The cash sum must not exceed `trading_available`, and the margin sum must not exceed `margin_available`. The check assumes a market buy is held at `limit_up`, a filled sell adds nothing to `trading_available`, and an FOK kill releases its hold; the [stage 2 acceptance](./multi-stock-live.md#stage-2-tw-production) measures these. The messages are listed in the [TW target failure handling](../cli.md#failure-handling-1).
- Mode: simulation requires `--equity TWD` and `info.simulation = true`. Production rejects `--equity` and requires `info.simulation = false`.
- Startup: simulation logs the override equity. Production logs `acc_balance`, each T+0 through T+2 amount, derived spendable cash, and derived equity.
- No local state file: read-back account and trade state drive each cycle. The documented lack of an exactly-once guarantee across concurrent processes still applies.
- Daily production: pending T+1 or T+2 payments alter spendable cash but do not suppress planning or execution. T+0 remains required and logged for audit, but is already reflected in `acc_balance`.

## Command surface

```
bt live STRAT [--live] [--equity TWD] [--data-dir DIR]
bt target STRAT [--live] [--equity TWD] [--data-dir DIR] [--provisional-close PRICE]
```

The strategy's `stock "tw/..."` declaration selects the market arm. `--provisional-close` supplies a TW provisional price dated from the local Taipei clock, but the command still enforces server mode, independent-calendar lookup, historical fetch, and exact cache freshness. `SHIOAJI_URL` overrides the server address.

## Testing and verification

- Offline fixtures cover Shioaji server info, snapshots, contract info, trading limits, mixed cash and margin positions, balance, settlements, placement responses, and refreshed trade statuses through production parsers.
- The exported engine planner has hand-derived two-inventory checks; the TW daily backtest output remains byte-identical to the standing reference.
- Calendar checks cover strict FinMind response parsing and a Tuesday-after-Monday-holiday previous session. TW decisions require the independent previous session and exact cache end date.
- Production checks derive TWD 99,893 for each day of the observed payable window: TWD 100,000 with T+2 or T+1 at TWD -107, and TWD 99,893 with T+0 at TWD -107. They also cover positive sale credit, malformed settlement-window rejection, non-finite rejection, and a decision with injected broker balance, settlements, and positions.
- Execution checks cover zero-lot plans; phase progress across codes; confirmed-price cash updates; partial, failed, missing, mismatched, ambiguous, and timed-out statuses; cutoff before a later leg; capped buys; and retained residual legs.
- Stage 2 checks cover the contract-info and trading-limit parsers, the cash and margin budget sums with the reference fallback and the suspension failure, a production decision with injected contract info and limits, the sell barrier before refinance pairs, the sell stop before refinances and buys, an uncertain buy whose placed sibling is still reconciled, buy reservations, batched poll rounds, margin-sale reservations, and an existing order on a second code that skips the session.

## Docs

- `docs/cli.md` documents TW target and daemon simulation and production, server environment, mode guards, cash and equity sourcing, lot and odd-lot orders, and confirmed-fill execution.
- `docs/engine.md` distinguishes the daily close-fill backtest from the TW broker-backed daemon.
- `CHANGELOG.md` records simulation and production support under `[0.10.0]`.

## Authoritative sources

- [Shioaji HTTP server setup](https://sinotrade.github.io/env_setup/other/) documents installation, `.env` fields, server mode, CA activation, port 8080, and the info endpoint.
- [Shioaji simulation](https://sinotrade.github.io/tutor/simulation/) documents the simulation environment and its supported API list; this design does not infer undocumented `account_balance` behavior from that list.
- [Shioaji stock orders](https://sinotrade.github.io/tutor/order/Stock/) documents `MKT`, the `ROD`, `IOC`, and `FOK` order types, `Common`, order conditions, placement, and status refresh.
- [TWSE intraday odd-lot rules](https://www.twse.com.tw/downloads/zh/trading/introduce/introduce4-1.pdf) documents limit `ROD` orders of 1 to 999 shares and the 09:00 to 13:30 session.
- [FinMind Taiwan technical datasets](https://finmind.github.io/tutor/TaiwanMarket/Technical/#taiwanstocktradingdate) documents the independent `TaiwanStockTradingDate` dataset.
- [TWSE trading mechanism](https://www.twse.com.tw/en/products/system/trading.html) documents continuous trading through 13:25 and the 13:25-13:30 closing call.

## Non-goals

- Futures, options, the after-hours odd-lot session (`Odd`), short selling (`ShortSelling`, SBL), the fixed-price after-hours session, any closing-auction fallback.
- TW intraday trading; the daemon stays daily.
- Automated response to margin calls; the daemon only logs what it reads back.
- Multiple accounts or strategies.
- Any change to daily backtest behavior, the US live path, or `bt fetch`.
