# Design: multi-stock live trading

Date: 2026-10-04
Status: approved, not implemented

> [!IMPORTANT]
> Live trading must behave like the backtest and the strategy file. A strategy with N `stock` lines trades all N symbols live through one decision, one planner call, and one execution, as `bt run` plans them. One code path serves every N, including N = 1.

## Contents

- [Context](#context)
- [Decisions](#decisions)
- [Design](#design)
  - [Stages](#stages)
  - [Strategy and market](#strategy-and-market)
  - [Data](#data)
  - [Targets](#targets)
  - [Decision record](#decision-record)
  - [Output](#output)
    - [bt target](#bt-target)
    - [Daemon log](#daemon-log)
  - [US planner](#us-planner)
    - [Plan state](#plan-state)
    - [Account checks](#account-checks)
    - [Planner call](#planner-call)
  - [US execution](#us-execution)
    - [US phases](#us-phases)
    - [Restarts](#restarts)
    - [Buying power note](#buying-power-note)
  - [TW planner](#tw-planner)
    - [Positions and state](#positions-and-state)
    - [Snapshot](#snapshot)
    - [Legs](#legs)
  - [TW execution](#tw-execution)
    - [TW phases](#tw-phases)
    - [Lot order type](#lot-order-type)
    - [TW daemon](#tw-daemon)
  - [TW budget pre-check](#tw-budget-pre-check)
    - [Contract info](#contract-info)
    - [Trading limits](#trading-limits)
    - [Budget rule](#budget-rule)
    - [Measured and unmeasured](#measured-and-unmeasured)
- [Errors](#errors)
- [Tests](#tests)
  - [Single-stock pins](#single-stock-pins)
  - [New tests](#new-tests)
  - [Gates](#gates)
- [Acceptance](#acceptance)
  - [Stage 1: US paper](#stage-1-us-paper)
  - [Stage 2: TW production](#stage-2-tw-production)
- [Docs](#docs)
- [Out of scope](#out-of-scope)

## Context

Live trading runs one stock today. `live_command_args` rejects any other count with `<command>: strategy must declare exactly one stock` (`bin/bt.ml:778-785`). `Live.decide` has one arm per market for a one-element stock list and otherwise fails with `live trading requires exactly one stock` (`broker/live.ml:594-830`). `run_us` and `Live.run` match the same way (`broker/live.ml:1052-1057`, `1823-1834`).

`bt run` already trades N stocks. All stocks must share one market (`bin/bt.ml:320-326`). `common_dates` intersects the stocks' dates, and `bt run` keeps only those dates for every stock (`bin/bt.ml:160-178`, `383-395`). `Dsl.compile_ast` takes one `(alias, bars)` pair per stock and returns one target series per stock in declaration order (`lang/dsl.ml:490-777`). `Engine.effective_targets` scales all targets of a bar by one factor when the sum of `target x (1 - ratio)` exceeds 1 (`engine/engine.ml:237-256`). One `plan_fills` call plans every asset (`engine/engine.ml:282-944`). `apply_fills` then applies all sells, all refinances, and all buys, in that order (`engine/engine.ml:1705-1757`, `1762-1847`, `1848-1882`).

US live maps Alpaca's debit into one margin lot in `Live.us_plan_state` (`broker/live.ml:72-86`). `Live.us_plan_action` plans one asset into one `Order` or `Skip` (`broker/live.ml:88-143`). Its third check compares `long_market_value` with `held x price` within 1% (`broker/live.ml:104-111`). With one stock, that check also catches any other holding. `execute_decision` submits the one order and follows it to a terminal status after the close (`broker/live.ml:925-976`). `us_step` looks up the day's one client order id before it decides (`broker/live.ml:987-1048`).

TW live sums one code in `position_totals` and fails on any other active code (`broker/live.ml:509-554`). The snapshot request sends one contract, and `parse_snapshot` requires a one-element array (`broker/shioaji.ml:196-212`, `390-397`). `legs_of_plan` requires exactly one planned asset (`broker/live.ml:284-317`). `execute_tw_legs` takes one code and one exchange (`broker/live.ml:1180-1182`). It sends legs one at a time and polls each `Common` leg before it sends the next (`broker/live.ml:1370-1591`). A `Common` leg that ends with no fill lets later independent legs run, buys after a failed sell included (`broker/live.ml:1530-1541`). `order_body` sends a `Common` leg as `MKT` + `IOC` (`broker/shioaji.ml:434-436`).

A production probe on Friday 2026-10-02 read SinoPac's trading limits around one odd-lot buy (`.superpowers/sdd/tw-limits-probe/log.md`). [Trading limits](#trading-limits) records the readings.

## Decisions

| Topic | Decision |
|---|---|
| Symbol count | N is the number of `stock` lines. One code path serves every N. The one-stock arms of `Live.decide` and the exactly-one check in `live_command_args` go away. |
| Stages | The work ships in two stages, each with its own plan and release. Stage 1 is the shared N-asset decision plus US, released as v0.12.0 together with the [US live planner acceptance](./us-live-planner.md#acceptance). Stage 2 is TW execution, released as v0.13.0 after the TW production session. |
| Single-stock pins | Before any refactor, injected-fixture tests pin today's one-stock decisions. Every later task keeps them passing, apart from the four accepted changes. The six byte gates stay. |
| Accepted changes | Four changes also apply to one-stock strategies, each with its own CHANGELOG entry: TW phase batching, FOK on lot legs, the TW budget pre-check, and the US positions-list check. Phase batching includes the sell-phase stop rule: a sell that is rejected, has an uncertain outcome, or is FOK-killed with no fill stops the session before the refinance pairs and the buys, at N = 1 too. Today the executor records a rejected or unfilled sell as failed and lets later independent legs run, buys included (`broker/live.ml:1487-1493`, `1530-1541`). An uncertain outcome already stops the session today (`broker/live.ml:1486`, `1542-1544`). |
| Holdings | The account holds exactly the strategy's symbols. Any other holding fails the session closed. |
| Market | All symbols share one market, the rule `bt run` applies. |
| History | History loads per symbol as today. `common_dates` moves into `Data`, and both `bt run` and live call it. A gap in any of the last 5 sessions fails the decision. |
| Targets | `Dsl.compile_ast` and `Engine.effective_targets` run once with N assets, so live scales targets jointly, as the backtest does. |
| Decision record | The record holds the account fields once and one entry per asset. |
| Planner | One `plan_fills` call per session plans all N assets in both markets. |
| Phase order | In both markets, the sell phase ends before the buy phase starts. In TW, the buy phase waits for every placed `Common` sell to be confirmed. Odd-lot sells stay pending `ROD` orders, and rollover and refinance pairs run one leg at a time outside the two phases. |
| Lot order type | TW lot legs become `MKT` + `FOK`. Odd-lot legs stay `LMT` + `ROD`. |
| Budget | TW production checks the broker's trading budget for the session's buys before it sends any order. |

## Design

### Stages

| Stage | Scope | Release |
|---|---|---|
| 1 | `Data.common_dates`; market and symbol checks; the N-asset `Live.decide` for both markets, including TW plan state, snapshot, and legs; the decision record and output; US plan state, account checks, planner call, and execution | v0.12.0, after the [stage 1 acceptance](#stage-1-us-paper) and the [US live planner acceptance](./us-live-planner.md#acceptance) |
| 2 | TW phases, per-leg code and exchange in `execute_tw_legs`, FOK, contract info, trading limits, the budget pre-check, and the N-symbol `run_tw` | v0.13.0, after the [stage 2 production session](#stage-2-tw-production) |

Stage 1 gives `bt target` TW decisions for N stocks, but `run_tw` still executes one code. Until stage 2, `Live.run` fails a TW strategy with more than one stock at startup with `TW live trading needs one stock in this release`. Stage 2 deletes that check.

### Strategy and market

`live_command_args` (`bin/bt.ml:778-785`) drops its exactly-one check and applies these rules to the stock list from `Dsl.stocks_of`:

- All stocks share one market. Otherwise it fails with the usage error `live trading needs one market`. The rule matches `bt run` (`bin/bt.ml:320-326`).
- Each symbol appears once. Otherwise it fails with `live trading needs distinct symbols: <symbol>`. `Dsl.stocks_of` accepts one market and symbol under two aliases (`lang/dsl.ml:440-457` labels them apart). The broker reports one position per symbol, so live cannot split it between two assets.

`Dsl.stocks_of` already requires an alias on every stock of a multi-stock file (`lang/dsl.ml:391-401`).

`bt target --provisional-close PRICE` supplies one price, so it needs a one-stock strategy. With N > 1 it fails with `--provisional-close needs a one-stock strategy`.

`Live.run` matches on the one market with `| "us"`, `| "tw"`, and a default arm.

### Data

`Live.decide` fetches, loads, and checks history per symbol, in declaration order, as each market arm does today:

- US: one Alpaca snapshot per symbol, `Data.fetch` through that snapshot's `prev_day_date`, `Data.load_asset`, and the freshness check `stale cache: fetched through <date>, expected <date>` (`broker/live.ml:596-634`).
- TW: one previous session from FinMind's calendar for all symbols, `Data.fetch` and `Data.fetch_tw_adjustments` per symbol, `Data.load_asset`, and the freshness check `stale TW cache: fetched through <date>, expected <date>` (`broker/live.ml:686-734`).

`common_dates` moves from `bin/bt.ml:160-178` to `market/data.ml` as `Data.common_dates`, with the same body. `bt run` (`bin/bt.ml:383`), `bt daytrade` (`bin/bt.ml:638`), and `Live.decide` call it.

`Live.decide` then applies the gap rule. Take R, the last 5 dates of the union of all symbols' loaded dates. When a symbol lacks any date in R, the decision fails with `history gap in <symbol> within the last 5 sessions`, naming the first such symbol in declaration order. K is fixed at 5. An older gap passes. `Data.filter_dates` then keeps only the common dates for every symbol, as `bt run` does (`bin/bt.ml:386-395`), so live drops the same dates the backtest drops.

`Live.decide` appends each symbol's provisional bar and checks its date with `snapshot_session` (`broker/live.ml:58-66`). `fetched_through` is the last common date.

With N = 1, the intersection is the symbol's own dates and R holds only its own dates, so the gap rule never fires and the bars match today's.

### Targets

`Live.decide` calls `Dsl.compile_ast` once with the N `(alias, bars)` pairs. It reads the last row of the N target series as the targets and the row before as the previous targets, with previous targets of 0 when only one bar exists (`broker/live.ml:655-663`).

`Engine.effective_targets` runs once per row with N financing ratios: the US profile's 0.5 for every US symbol (`engine/engine.ml:129-136`), and `Data.financing_ratio` per TW symbol (`broker/live.ml:744-746`). When the sum of `target x (1 - ratio)` exceeds 1, every target shrinks by the same factor (`engine/engine.ml:250`). With N = 1 the call equals today's.

### Decision record

`Live.decision` (`broker/live.ml:21-30`, `broker/live.mli:24-33`) becomes:

```ocaml
type asset_decision = {
  symbol : string;
  provisional : Data.bar;
  target : float;
  held : float;
  action : action;
}

type decision = {
  fetched_through : string;
  equity : float;
  cash : float;
  debit : float;
  assets : asset_decision array;
  legs : leg list;
}
```

`assets` follows declaration order. A US asset's action is an `Order` or a `Skip`. A TW asset's action is `Orders` with that symbol's legs. `legs` holds the TW session's leg list in execution order and is empty for US. The phase order interleaves symbols, so per-asset lists cannot rebuild it. `Live.leg` (`broker/live.ml:3-8`) gains `code : string` and `exchange : string`.

### Output

Both markets and both surfaces print the account values once, then one entry per symbol.

#### bt target

`print_decision` (`bin/bt.ml:682-726`) prints the account lines, then one block per symbol that starts with `symbol:`:

```
provisional: override PRICE
fetched-through: DATE
equity: VALUE
cash: VALUE
debit: VALUE
symbol: SYMBOL
provisional-date: DATE
provisional-open: VALUE
provisional-high: VALUE
provisional-low: VALUE
provisional-close: VALUE
provisional-volume: VALUE
target: VALUE
held: VALUE
action: order | skip | orders
```

The first line appears only with `--provisional-close`. The action lines after `action:` keep today's form: `side:`, `quantity:`, and `client-order-id:` for an order, `reason:` for a skip, and one `leg: <action> <cond> <lot> <quantity>` line per leg for TW.

#### Daemon log

The US daemon logs one account line, then one line per symbol:

```
date=DATE fetched-through=DATE equity=VALUE cash=VALUE debit=VALUE
date=DATE symbol=SYMBOL provisional-close=VALUE target=VALUE held=VALUE order=ORDER fill=pending
```

`ORDER` keeps the form of `order_description` (`broker/live.ml:870-885`). Under on_change, when every asset's target equals its previous target, the daemon logs one line instead: `date=DATE fetched-through=DATE equity=VALUE cash=VALUE debit=VALUE order=skip:target unchanged`. The existing-order line and the per-order error lines gain `symbol=SYMBOL` after `date=`. The client order id stays `bt-<symbol>-<date>` (`broker/live.ml:69-70`).

The TW daemon logs one account line, then one line per symbol:

```
date=DATE fetched-through=DATE equity=VALUE cash=VALUE debit=VALUE submitted=OUTCOME
date=DATE symbol=CODE provisional-close=VALUE target=VALUE cash-shares=VALUE margin-shares=VALUE loan=VALUE planned-legs=LEGS
```

`OUTCOME` keeps today's values: `complete`, `skip:no-order-legs`, `skip:existing-orders`, or `stop:<reason> remaining:<legs>` (`broker/live.ml:1693`, `1735-1759`). Each trade line (`broker/live.ml:1152-1162`) gains `code=CODE`. The order `custom_field` stays `bt<MMDD>` (`broker/live.ml:1369`).

### US planner

#### Plan state

```ocaml
val us_plan_state :
  cash:float -> held:float array -> prices:float array -> ratio:float ->
  previous_targets:float array -> Engine.plan_state
```

Each asset's value is `V_i = held_i x price_i`, and D is the debit `max 0 (-cash)`. The state splits D across the assets in proportion to value:

- `loan_i = D x (V_i / sum V)`. When `sum V` is 0, `loan_i = D / N`.
- `margin_value_i = min V_i (loan_i / ratio)`.
- `cash_value_i = V_i - margin_value_i`.
- `cash = max cash 0`, and `equity = cash + sum V - D`.
- Interests and tail interests are 0, as today.

The function sums V with a left fold from 0 and computes `V_i / sum V` before it multiplies by D. With N = 1, `V / V` is exactly 1, so the state equals today's `loan = D` and `margin_value = min V (D / ratio)` (`broker/live.ml:72-86`) bit for bit.

Example, ratio 0.5: cash -30000, V = 60000 and 30000. D is 30000. The loans are 20000 and 10000. The margin values are `min 60000 40000` = 40000 and `min 30000 20000` = 20000. The cash values are 20000 and 10000. Equity is `0 + 90000 - 30000` = 60000.

#### Account checks

`us_plan_action` raises `Failure` for these states, in this order, before it plans:

| Order | Condition | Message |
|---|---|---|
| 1 | `account.cash` is NaN or infinite | `US account cash is not finite` |
| 2 | `account.short_market_value <> 0.` or any `held_i < 0.` | `US account holds a short position` |
| 3 | `Alpaca.positions` lists a symbol outside the strategy | `US account holds unsupported symbol <symbol>` |
| 4 | `long_market_value` is not finite, or differs from `sum held_i x price_i` by more than 1% of `long_market_value` | `US account holds other symbols` |
| 5 | the state's `equity` is NaN, infinite, or at most 0 | `US account equity is not positive` |

Check 3 is new. `Alpaca.positions mode` calls `GET /v2/positions`, which lists the account's open positions ([Alpaca: All Open Positions](https://docs.alpaca.markets/us/reference/getallopenpositions)), and returns their symbols. `held_i` still comes from `Alpaca.position_qty` per symbol (`broker/alpaca.ml:236-240`). Check 4 keeps today's tolerance and its `ponytail:` comment (`broker/live.ml:104-111`), with the sum in place of the one value. Check 3 runs before check 4, so a foreign holding gets the message that names it.

#### Planner call

```ocaml
val us_plan_action :
  rebalance:bool -> symbols:string array -> date:string ->
  account:Alpaca.account_t -> position_symbols:string list ->
  held:float array -> prices:float array ->
  targets:float array -> previous_targets:float array ->
  Engine.plan_state * action array
```

`us_plan_action` runs these steps:

1. Build the state with `us_plan_state`, with `ratio` from the US profile.
2. Run the five account checks.
3. If `not rebalance` and every target equals its previous target, return `Skip "target unchanged"` for every asset without planning.
4. Call `Engine.plan_fills` once with `capital:1.`, the US profile, one `Engine.default_costs ~market:"us" ~symbol` per symbol, N copies of the ratio, the state, the N prices and targets, and `~force:rebalance`.
5. For each asset, take the net `plan_buy_cash + plan_buy_margin - plan_sell_cash - plan_sell_margin` and turn it into one action:
   - An asset whose target equals its previous target under on_change returns `Skip "target unchanged"`. The planner leaves such an asset unchanged (`engine/engine.ml:320-323`).
   - Otherwise the net becomes an `Order` or a `Skip` by today's rules (`broker/live.ml:130-143`): `no trade planned`, a full close of `held` when `plan_final_value` is 0, 9-decimal truncation, and `below $1 minimum order value`.

Refinance pairs still place no order. With N = 1, step 3 covers the unchanged case, and the result equals today's.

`Live.decide` reads `Alpaca.account`, `Alpaca.position_qty` per symbol, and `Alpaca.positions`, then calls `us_plan_action`.

### US execution

#### US phases

`execute_decision` (`broker/live.ml:935-976`) handles all N actions:

1. When the session has no sell or no buy, every order goes out as today: one POST each, then the finish pass. With N = 1 the session has one order, so it runs this path, unchanged.
2. Otherwise the sell phase POSTs every sell, then polls all of them with `Alpaca.order_by_client_id` every 15 seconds. Polling ends when every sell is terminal (`broker/live.ml:910-912`) or the submit cutoff arrives, 2 minutes before `next_close` (`broker/live.ml:335-347`).
3. The buy phase starts only when every sell reached `filled`. Before its POSTs it checks the clock again, as today (`broker/live.ml:946-950`).
4. A sell still open at the cutoff stops the session before any buy with `sell <symbol> open at cutoff`. A sell that ends `rejected`, `canceled`, `expired`, or `stopped`, or whose POST failed, stops it with `sell <symbol> <state>`, where the state is the status or `uncertain`.
5. After the buy POSTs, the finish pass follows every order still open with `finish_order` (`broker/live.ml:925-933`): it sleeps to `next_close`, then polls until a terminal status or 5 minutes after the close.

Nothing is retried after a POST. A failure after the first POST logs `order=skip` and ends the session, as today (`broker/live.ml:951-972`). A failure before any POST still makes `us_step` retry every 60 seconds until the cutoff (`broker/live.ml:1016-1031`).

The engine applies sells before buys (`engine/engine.ml:1705-1882`), so sells first matches the backtest. It also makes the US rule match TW.

#### Restarts

`us_step` (`broker/live.ml:987-1048`) takes the symbol list and looks up `bt-<symbol>-<date>` for every symbol before it decides.

`Alpaca.order_t` (`broker/alpaca.ml:30-35`, `broker/alpaca.mli:35`) holds only `id`, `status`, `filled_avg_price`, and `filled_qty`, so a lookup cannot tell a sell from a buy. It gains `side : string`, and `parse_order` (`broker/alpaca.ml:147-161`) reads it from the response's `side` field, `"buy"` or `"sell"` (`test/fixtures/alpaca/order.json:24`). The restart rules route each existing order by that field:

- A symbol with an order is done. The daemon logs `date=DATE symbol=SYMBOL order=existing:ID fill=pending` and places no new order for it.
- When every symbol is done, the session runs the finish pass and ends, as today.
- Otherwise `Live.decide` plans all N assets from the current holdings, and execution drops the actions of the done symbols. An existing order with side `sell` counts as placed and joins the sell-phase poll. An existing order with side `buy` goes to the finish pass.
- An existing sell counts as a session sell in step 1 of [US phases](#us-phases). A remaining buy therefore waits until that sell reaches `filled`, and step 4's stop rules apply to it.

> [!WARNING]
> The re-plan reads holdings and cash, not open orders. An order of a done symbol that has not filled is invisible to it, so the re-plan can size the remaining symbols from cash that order will spend.

#### Buying power note

Alpaca's account document gives three `buying_power` formulas, one per `multiplier` ([Alpaca: Trading Account](https://docs.alpaca.markets/us/docs/account-plans), `buying_power`). Multiplier 4 uses `(last_equity - last_maintenance_margin) x 4`, prior-close figures. Multiplier 2 uses `max(equity - initial_margin, 0) x 2`. Multiplier 1 uses `cash`. Whether a same-day sell raises the figure Alpaca checks a buy against therefore depends on the multiplier. The recorded fixture reports multiplier 4 ([Design: live trading via Alpaca](./live-trading.md#daily-cycle), margin paragraph). This spec does not claim that Alpaca requires sells first.

### TW planner

#### Positions and state

`position_totals` (`broker/live.ml:509-554`) takes the symbol set and the N provisional closes. It returns today's six totals for each symbol: cash shares, margin shares, cash value, margin value, loans, and interests. An active position in a code outside the set still fails with `TW account holds unsupported symbol <code>` (`broker/live.ml:530-534`).

The plan state holds one entry per symbol in `cash_values`, `margin_values`, `loans`, and `interests`, with zero tail interests. Let `CV`, `MV`, `L`, and `I` be the sums of the cash values, margin values, loans, and interests, each a left fold from 0:

- Simulation: `cash = equity - CV - MV + L + I`, with `--equity` as equity.
- Production: cash comes from `tw_production_cash` as today (`broker/live.ml:235-257`), and `equity = cash + CV + MV - L - I`.

These keep today's operation order (`broker/live.ml:781-800`), so N = 1 reproduces today's values. `debit` is `L`, and each asset's `held` is its cash shares plus margin shares. `fetch_position_details` and `maturity_rollover_legs` run per symbol (`broker/live.ml:388-405`, `556-581`). `plan_fills` runs once with `tw_live_debit_costs` per symbol (`broker/live.ml:584-585`).

#### Snapshot

`Shioaji.snapshot` takes N `(exchange, code)` contracts and sends them in one `POST /api/v1/data/snapshots`. `parse_snapshot` reads each element's `code`, which the response carries (`test/fixtures/shioaji/snapshot.json`), and returns one snapshot per requested code. A missing, extra, or duplicate code fails with `invalid Shioaji snapshot response`. `prepare_tw` checks every snapshot's date (`broker/live.ml:1108-1116`), and `Live.decide` builds each provisional bar with `tw_provisional_bar` (`broker/live.ml:474-506`).

#### Legs

```ocaml
val legs_of_plan :
  codes:string array -> exchanges:string array -> prices:float array ->
  Engine.fill_plan -> leg list
```

`legs_of_plan` keeps today's per-asset split into `Common` lots and one `IntradayOdd` remainder (`broker/live.ml:295-309`) and tags each leg with its code and exchange. It orders the session's legs by phase, assets in declaration order within each group:

1. Margin sells of all assets.
2. Cash sells of all assets, each as lots then the odd remainder.
3. Refinance pairs of all assets, each asset's cash pair before its margin pair.
4. Cash buys of all assets, each as lots then the odd remainder.
5. Margin buys of all assets.

`Live.decide` puts the maturity rollover pairs of all assets in front of that list, as today (`broker/live.ml:822-826`). With N = 1 the list equals today's (`broker/live.ml:310-317`).

### TW execution

#### TW phases

`execute_tw_legs` (`broker/live.ml:1180-1591`) drops its `~exchange`, `~code`, `~bid`, `~ask`, `~price`, `~financing_ratio`, and `~costs` arguments for per-code values. Each leg carries its code and exchange. The executor keeps inventory, loans, and interests per code, reads `orders_today` per code, and keeps one running cash total. It runs the leg list in four phases:

1. Rollover pairs, one leg at a time, as today.
2. Sells. The executor places every sell after today's inventory, odd-lot, and window checks. Then it polls all placed `Common` sells together: each round reads `orders_today` once per code, for up to 5 rounds 1 second apart, today's limit per order (`broker/live.ml:1355-1367`). Odd-lot sells stay unpolled `ROD` orders whose proceeds no later buy spends (`broker/live.ml:1496-1521`).
3. Refinance pairs, one leg at a time, with today's dependency rule (`broker/live.ml:1382-1395`).
4. Buys, which start only after every placed `Common` sell is confirmed. The executor sizes each buy from the running cash with `affordable_quantity` (`broker/live.ml:1238-1249`), reserves its cost at the quote when it places it, and polls all placed `Common` buys together. A confirmed fill replaces the reservation with the deal-price cost.

Stop rules:

- A sell rejected at placement or after polling, or with an uncertain outcome, stops the session before the next phase.
- A `Common` sell that FOK kills with no fill stops the session before the next phase, the same as a rejected sell, because the buys were planned on that sell's proceeds and its held quantity.
- The executor logs a failed buy, an FOK kill with no fill included, and its sibling buys continue.
- The first uncertain leg in any phase stops the remaining placements. The executor still polls the orders it placed, so the log records them.
- A capped buy is placed for its funded quantity, and the buys after it stay unsubmitted, as today.
- A confirmed fill that takes cash below 0 stops the session with `confirmed fill exceeded cash budget by <value>` (`broker/live.ml:1569-1576`).
- Simulation still skips odd lots (`broker/live.ml:1396-1398`).

The odd-lot and lot rules of [Design: share quantum and odd lots](./share-quantum-and-odd-lots.md) stay.

#### Lot order type

`order_body` (`broker/shioaji.ml:434-436`) sends a `Common` leg as `MKT` + `FOK` instead of `MKT` + `IOC`. Shioaji's stock order accepts `ROD`, `IOC`, and `FOK` ([Shioaji stock orders](https://sinotrade.github.io/tutor/order/Stock/)). An FOK lot fills completely or not at all, so a lot leg never leaves a partial fill to track. `IntradayOdd` legs stay `LMT` + `ROD`. The executor keeps its partial-fill check (`broker/live.ml:1332-1336`) as a guard.

#### TW daemon

`run_tw` (`broker/live.ml:1592-1793`) takes the symbol list and the market's exchanges:

- `prepare_tw` fetches and checks every symbol (`broker/live.ml:1108-1140`).
- The existing-orders check reads `orders_today` for every code. Any order today on any strategy code skips the session with `submitted=skip:existing-orders`, as today for one code (`broker/live.ml:1686-1697`).
- After `Live.decide`, production reads [contract info](#contract-info) and [trading limits](#trading-limits) and runs the [budget rule](#budget-rule) before `execute_tw_legs`.
- After the close, the daemon logs the trades of every code (`broker/live.ml:1776-1785`).

A failure anywhere in the cycle still logs `date=DATE error=MESSAGE order=skip` and skips the day (`broker/live.ml:1786-1791`). `lock_daemon` stays one lock per market and mode (`broker/live.ml:1795-1813`).

### TW budget pre-check

The pre-check runs in production only. Shioaji's simulation returns zero trading limits ([Shioaji accounting reference](https://github.com/Sinotrade/rshioaji/blob/main/skills/shioaji/references/ACCOUNTING.md), simulation notes), so simulation keeps today's path.

#### Contract info

`Shioaji.contract_info ~code` calls `GET /api/v1/data/contracts/{code}/info` and parses `reference`, `limit_up`, `limit_down`, `day_trade`, `unit`, `margin_loan_ratio`, and `trading_suspended` ([Shioaji contracts](https://sinotrade.github.io/tutor/contract/#contract-details)). The daemon reads it once per symbol per session and logs one line per symbol with the seven fields. `trading_suspended = true` on any symbol fails the whole session with `TW symbol <code> is suspended`. `bt run` drops a date that any stock lacks, so the backtest also trades no symbol on such a day.

#### Trading limits

`Shioaji.trading_limits ()` calls `POST /api/v1/portfolio/trading_limits` with `{"account_type":"S"}` and parses `trading_limit`, `trading_used`, `trading_available`, `margin_limit`, `margin_used`, and `margin_available`. The server answers on trading days from 08:30 to 15:00 Taipei only ([Shioaji accounting reference](https://github.com/Sinotrade/rshioaji/blob/main/skills/shioaji/references/ACCOUNTING.md)). The daemon reads it once per session, at the 13:20 decision. [Measured and unmeasured](#measured-and-unmeasured) lists how orders change the figures on the production account.

#### Budget rule

The pre-check prices every buy leg in `decision.legs` at the broker's assumed hold:

| Leg | Hold |
|---|---|
| `Common` buy | `limit_up x lots x unit` |
| `IntradayOdd` buy | its limit price, the snapshot ask (`broker/live.ml:1400-1404`), `x shares` |

A symbol without a usable `limit_up` (absent, null, or not positive) is priced at `reference x 1.10`, and the daemon logs that fallback. The pre-check sums the `Cash` buys and, separately, the `MarginTrading` buys, rollover and refinance rebuys included. It logs both sums with both available figures. Then:

- When the cash sum exceeds `trading_available`, the session fails before any order with `TW buy budget short: planned X, available Y`.
- When the margin sum exceeds `margin_available`, the session fails before any order with `TW margin budget short: planned X, available Y`.

The daemon reads the limits once, before the first order, and does not retry within the session, so a failed check stands for the day. `trading_used` resets daily, so each session checks against that day's limits. A sell placement takes no hold, a cancelled order releases its hold at once, and an order rejected at placement holds nothing. The pre-check assumes that a filled sell adds nothing to `trading_available`, which can only make the check stricter.

The pre-check also assumes that an FOK kill releases its hold, as a cancel does, but no session depends on it. The executor places each buy leg once and the sum counts each buy leg once, so a kill that kept its hold would still leave the total hold within the checked sum. The next session starts from reset limits. With `margin_limit` 0, any plan with a margin buy fails this check.

The `limit_up` basis assumes the broker holds a market buy at the limit-up price. The [stage 2 acceptance](#stage-2-tw-production) measures the real hold on one 00685L lot. That measurement may lower the pricing basis. It never changes the order type.

#### Measured and unmeasured

Readings on the production SinoPac account with 0050, on Friday 2026-10-02 and Monday 2026-10-05 (`.superpowers/sdd/tw-limits-probe/log.md`):

| Question | Reading | Log lines |
|---|---|---|
| Does `trading_used` reset? | Daily. It read 112 at Friday's 13:30 and 0 at Monday's 09:05. | 7, 23 |
| When does a buy take its hold? | At placement, at its limit price, before any fill. A `LMT` `IntradayOdd` buy of 1 share at 112.6 took `trading_used` from 0 to 112 about 20 seconds after placement. The fill 6 minutes later left it at 112. | 2-5 |
| Does a sell placement consume the limit? | No. A sell of 1 share at 115.65 left `trading_used` at 0. | 24 |
| Does a cancel release the hold? | Yes, at once. A resting buy of 1 share at 105 took `trading_used` from 0 to 105, and its cancel took it back to 0. | 34-35 |
| Does an order rejected at placement hold anything? | No. A buy priced below `limit_down` failed at placement and left `trading_used` at 0. | 26, 33 |
| What is `margin_limit`? | 0 at every reading. | 2, 7, 28 |

> [!WARNING]
> Three behaviors are unmeasured. The pre-check runs on the assumption in the last column until the [stage 2 acceptance](#stage-2-tw-production) measures them.

| Question | Why unmeasured | Assumption |
|---|---|---|
| Does a filled sell add to `trading_available`? | The probe placed its sell while `trading_used` was 0, so "adds back" and "adds nothing" read the same. | Sells add nothing. |
| Does an FOK kill after acceptance release its hold? | The probe placed no lot order. A cancel releases its hold, so a kill is expected to release too. | Kills release. No session depends on it (see the [budget rule](#budget-rule)). |
| What hold does the broker take for a `MKT` lot buy? | The probe placed no `MKT` order. | `limit_up x lots x unit`. |

## Errors

New messages:

| Message | Raised by | Effect |
|---|---|---|
| `live trading needs one market` | `live_command_args` | usage error, exit 2 |
| `live trading needs distinct symbols: <symbol>` | `live_command_args` | command fails |
| `--provisional-close needs a one-stock strategy` | `bt target` | command fails |
| `TW live trading needs one stock in this release` | `Live.run`, stage 1 only | daemon does not start |
| `history gap in <symbol> within the last 5 sessions` | `Live.decide` | US: retry until the cutoff; TW: skip the day |
| `US account holds unsupported symbol <symbol>` | `us_plan_action`, check 3 | retry until the cutoff |
| `sell <symbol> open at cutoff` | US sell phase | no buy; open orders go to the finish pass |
| `sell <symbol> <state>` | US sell phase | no buy |
| `TW symbol <code> is suspended` | `run_tw` | skip the day before any order |
| `TW buy budget short: planned X, available Y` | `run_tw` | skip the day before any order |
| `TW margin budget short: planned X, available Y` | `run_tw` | skip the day before any order |

Existing messages stay, with the scope this spec gives them: the four US account messages in [Account checks](#account-checks), `stale cache: ...` and `stale TW cache: ...` per symbol, `TW account holds unsupported symbol <code>` relative to the symbol set, `TW account holds unsupported inventory <cond>`, `TW position contains invalid account values`, `TW account equity is not positive`, and `invalid Shioaji snapshot response`. US failures before planning retry every 60 seconds until the cutoff (`broker/live.ml:1028-1031`). TW failures log `order=skip` and skip the day (`broker/live.ml:1786-1791`).

These messages go away: `<command>: strategy must declare exactly one stock` (`bin/bt.ml:784`), `live trading requires exactly one stock` (`broker/live.ml:830`, `1057`, `1834`), `live trading requires exactly one stock target` (`broker/live.ml:664`, `763`), `live trading requires exactly one planned asset` (`broker/live.ml:292`), and `live trading supports us only` (`broker/live.ml:1056`).

## Tests

Tests follow `CONTRIBUTING.md`: plain asserts in `test/test_bt.ml`, injected values, no broker, and a derivation comment above each expected value.

### Single-stock pins

Before any refactor, pin today's one-stock decisions and record their targets, quantities, leg lists, and leg order:

- TW `Live.decide` with injected snapshot, positions, position details, and simulation equity: a constant target, drift from target, a levered target, and a matured margin lot with rollover legs.
- `us_plan_action`: the cases of `test_us_plan_action_orders`, `test_us_live_fractional`, and `test_us_live_quantity_limit`.

Later tasks adapt the pins to the new signatures and record type. The recorded values do not change. The four accepted changes leave the pinned decisions alone, because they act in execution, in `order_body`, or in a check that the pins pass. Executor cases for a sell that ends with no fill assert the new stop before the refinance pairs and the buys, not today's continue. `test_tw_execution_stops_on_predecessor` already expects a stop for a `Failed` sell before its dependent margin buy (`test/test_bt.ml:7677-7701`).

### New tests

| # | Subject | Cases |
|---|---|---|
| 1 | `us_plan_state` | Splits the debit: the [Plan state](#plan-state) example, and N = 1 equal bit for bit to the `test_us_plan_state` values. |
| 2 | N-asset parity with `Engine.run` | Extends `test_us_plan_action_matches_run` (`test/test_bt.ml:4857-4926`) to two assets. Cover cash and levered targets, a buy and a sell in the same session, and a refinance in one asset funded across assets. Each asset's quantity matches the backtest within 1e-9 shares. |
| 3 | The gap rule | A gap in one symbol within the last 5 union dates fails with the exact message. An older gap passes, and the bars match `bt run`'s filtering. |
| 4 | TW `legs_of_plan` over two assets | The sells of both come before the buys of both, each leg carries its code and exchange, and refinance pairs sit between. |
| 5 | The budget rule | An exact `TW buy budget short: planned X, available Y` message, an exact margin message, the `reference x 1.10` fallback, and a suspended symbol. |
| 6 | `position_totals` | Accepts every code of the set and fails on an active foreign code. |
| 7 | `parse_snapshot` | Two contracts, matched by code, and a missing code. |
| 8 | US two-phase execution | Injected `submit_market`, `order_by_client_id`, and `clock`: sells reach `filled` before any buy POST; a sell open at the cutoff stops the session with no buy; a rejected sell stops it; one order runs today's path. |
| 9 | `us_step` restarts | One symbol with an existing order and one without plans only the second; all symbols with orders run the finish pass only. An existing sell joins the sell-phase poll, an existing buy goes to the finish pass, and a remaining buy waits behind an existing sell that has not filled. |
| 10 | `order_body` | Emits `FOK` for `Common` and `ROD` for `IntradayOdd`. |
| 11 | `live_command_args` | Fails a mixed-market strategy, a repeated symbol, and `--provisional-close` with two stocks. |
| 12 | Parsers | `Alpaca.positions`, `Shioaji.contract_info`, and `Shioaji.trading_limits` against new fixtures, and `Alpaca.parse_order` reading `side` from `test/fixtures/alpaca/order.json`. The `Alpaca.positions` and `Shioaji.contract_info` fixtures come from the documented responses, and the `Shioaji.trading_limits` fixture comes from a recorded production response. |
| 13 | `us_plan_action` foreign symbol | A foreign symbol in `position_symbols` fails with `US account holds unsupported symbol <symbol>`. |
| 14 | TW two-code execution | `execute_tw_legs` with two codes and injected `place_order` and `orders_today`: a rejected sell blocks the buy phase; an FOK-killed `Common` sell with no fill blocks it too; an uncertain placement stops later placements while the executor still polls and logs the siblings it already placed; a failed buy lets its sibling buys continue; a capped buy goes out for its funded quantity and the buys after it stay unsubmitted; two placed buys reserve at the quote, and the final cash reflects their deal-price costs. |
| 15 | TW two-code `Live.decide` | Injected fixtures in the pattern of `test_tw_live_decide_override` (`test/test_bt.ml:7027`): `assets` follows declaration order, and the legs follow phase order with codes in declaration order within each group; two targets whose `target x (1 - ratio)` sum exceeds 1 shrink by one factor; the previous targets come from the row before the last; `cash` and `debit` use the sums over both codes ([Positions and state](#positions-and-state)); the rollover pairs of both codes come before the phase-ordered legs. |

The executor harness `tw_trade` and `execute_tw_test` (`test/test_bt.ml:6998-7013`) hardcode code `2330` and exchange `TSE`. Test 14 needs them to take each leg's code and exchange. The existing single-code executor tests adapt where the phase order changes their placements or polls.

### Gates

The build and the full suite exit 0. The six byte comparisons of `docs/plans/us-live-planner.md:33-46` stay byte-identical: stdout, `fp.csv`, and `main.trades.csv` for the US dd_ladder and the TW channel_ladder baselines. They cover the move of `common_dates`.

## Acceptance

### Stage 1: US paper

Create `/sandbox/research/strategies/us/paper_pair_probe/main.strat`:

```
stock "us/TQQQ" as tqqq
stock "us/QQQ" as qqq
rebalance daily
tqqq.target 0.2
qqq.target 0.8
```

The paper account must hold no symbol other than TQQQ and QQQ.

1. Run `bt live main.strat` on paper for at least three sessions: targets 0.2 and 0.8, then 0.25 and 1.0 for one session, then 0.3 and 0.7. The third session sells QQQ and buys TQQQ in one session.
2. Before each session's decision, run `bt target main.strat`. Check the account lines, then one block per symbol.
3. From each per-symbol decision line, compute the post-trade exposure `(held + signed quantity) x provisional close / equity`.
4. After at least one later session's bar is cached, run `bt run main.strat --capital 100000 --fill close` on the cached bars. `Engine.run` sells every remaining inventory on the last cached date (`engine/engine.ml:2203-2213`), and those terminal rows carry `to_exposure` 0. For each symbol, read the session date's `to_exposure` from `main.trades.csv` in the ordinary row whose `stock` is `us/TQQQ` or `us/QQQ`. Exclude refinance rows, whose `from_exposure` equals `to_exposure`, and the terminal rows, which fall on the later date. The value must match step 3 to 4 decimal places.
5. In the third session, Alpaca's order records show the QQQ sell's `filled_at` before the TQQQ buy's `submitted_at`.
6. In the session after the 1.25 fill, `bt target` prints `cash: 0` and a `debit` equal to the sum of `held x provisional close` minus `equity`, about 0.25 x equity.

> [!WARNING]
> TQQQ is a 3x leveraged ETF, and Alpaca's overnight maintenance for 3x ETFs is 75% of market value ([Design: live trading via Alpaca](./live-trading.md#daily-cycle), margin paragraph). At 0.25 TQQQ and 1.0 QQQ the requirement is about `0.25 x 0.75 + 1.0 x 0.30` = 0.4875 x equity, using the 30% band for prices above USD 6 ([Design: US market run with Alpaca-modeled defaults](./us-market-run.md)). If paper liquidates a position before the next session, step 6 is void and the run must be repeated.

The US live planner acceptance must also pass before v0.12.0.

### Stage 2: TW production

Precondition: `margin_limit` is confirmed. While it reads 0, the strategy uses cash targets only.

Run one production session of `bt live --live` on a strategy with two TW codes, `rebalance daily`, and targets that plan a `Common` lot plus an `IntradayOdd` remainder for each code. Check in the log:

- One contract line per code and one budget line with both sums at or below the available figures.
- Every ordinary `Common` sell placed and confirmed before the first ordinary buy. `IntradayOdd` sells are exempt: they stay unpolled `ROD` orders and may still be pending when the buys start. The rollover and refinance pairs are also exempt, because they run one leg at a time with each sell before its own rebuy.
- Every `Common` trade `Filled` in full or killed with no fill.
- The odd-lot legs placed as `LMT` + `ROD`.

This session also closes the open production gate of [Design: share quantum and odd lots](./share-quantum-and-odd-lots.md#testing-and-gates), a cash leg that produces both a lot order and an odd order.

Around the same session, measure the three open items of [Measured and unmeasured](#measured-and-unmeasured), with `trading_limits` read before and after each order:

- A sell placed while `trading_used` is above 0. A rise in `trading_available` after its fill means a filled sell adds back.
- One `Common` FOK lot order that the broker kills. `trading_used` back at its earlier value means a kill releases its hold.
- One `MKT` `Common` buy of one 00685L lot that fills. The pricing basis follows the measured hold.

Write the readings into [Measured and unmeasured](#measured-and-unmeasured) and the [budget rule](#budget-rule) before v0.13.0.

## Docs

Update these files with the implementation of each stage:

- `docs/specs/live-trading.md`: a dated note that one strategy runs per account with N symbols, the sell phase before the buy phase, and the positions-list check. Line 48's "position for one symbol" gains the positions list.
- `docs/specs/tw-live-trading.md`: a dated note on N symbols per account, the phases, FOK in place of IOC (lines 30, 43, and 70), the budget pre-check, and contract info.
- `docs/cli.md`: the `bt target` output table (lines 222-238) becomes account lines plus symbol blocks. Remove "exactly one" at lines 214, 252, 314, 404, 421, and 480. List the new errors in the failure sections. Line 513 changes `IOC` to `FOK`.
- `docs/engine.md`: line 212's "supported one-stock account" becomes the strategy's symbol set. The US live paragraph (lines 141-143) describes one plan for N symbols. Lines 216 and 223 change `IOC` to `FOK`.
- `CHANGELOG.md` under `[Unreleased]`: Added, multi-stock live trading in one market. Changed, the `bt target` output and the daemon log lines. Changed, TW phase batching, including the stop rule: a sell rejected, uncertain, or FOK-killed with no fill stops the session before the refinance pairs and the buys. Changed, TW lot legs use FOK. Added, the TW budget pre-check and contract-info suspension check. Changed, the US positions-list check.

## Out of scope

- Tolerating holdings outside the strategy.
- Per-strategy equity attribution and several daemons per account.
- Strategies that mix markets.
- Skipping one halted symbol while trading the others.
- Alpaca batch endpoints.
- Modelling the broker's `MKT` hold beyond the stated assumption.
