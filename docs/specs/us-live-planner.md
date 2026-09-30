# Design: US live planner

Date: 2026-09-29
Status: approved, not implemented

> [!IMPORTANT]
> US live sizes its daily order with `Engine.plan_fills`, the planner `bt run` uses. It maps Alpaca's account-level debit into one margin lot, so a levered target up to the Reg T cap of 2.0 gets the quantity the backtest plans for the same account state.

## Contents

- [Context](#context)
- [Decisions](#decisions)
- [Design](#design)
  - [Alpaca account](#alpaca-account)
  - [Plan state](#plan-state)
  - [Interest](#interest)
  - [Planner call](#planner-call)
  - [Decision record and output](#decision-record-and-output)
- [Errors](#errors)
- [Tests](#tests)
- [Acceptance](#acceptance)
- [Docs](#docs)
- [Out of scope](#out-of-scope)

## Context

US live sizes its order in `Live.decide_action` (`broker/live.ml:70-79`). It buys or sells `target x equity / price - held` shares, where `equity` is Alpaca's `equity` field. It caps a sell at `held`, truncates the quantity to 9 decimals with `Alpaca.qty_string`, and skips a buy under USD 1. `Live.us_rebalance_action` (`broker/live.ml:81-86`) puts the on_change skip `target unchanged` in front of it. The US arm of `Live.decide` calls it at `broker/live.ml:609-615`.

The backtest sizes the same bar with `Engine.plan_fills` (`engine/engine.ml:282-944`). The planner holds each position as cash inventory and margin inventory with loans. A sell takes margin inventory first and repays its loan in proportion (`engine/engine.ml:355-389`). The planner charges costs inside equity and funds a levered buy from cash, refinancing, and the financing ratio. TW live already calls it (`broker/live.ml:752-763`). US live does not, so a levered US target trades a different quantity live than in `bt run`. [Design: rebalance statement](./rebalance-statement.md#decisions) deferred this move because it needs a mapping from Alpaca account data to `plan_state` margin fields.

Alpaca reports one debit for the whole account, with no lots. A margin account that borrows shows a negative `cash`. The recorded fixture `test/fixtures/alpaca/account.json` holds `cash` -23140.2, `long_market_value` 126960.76, and `short_market_value` 0. Its `equity` of 103820.56 is their sum, as the Alpaca account schema documents. `Alpaca.parse_account` (`broker/alpaca.ml:102-113`) reads only `equity`, `status`, `trading_blocked`, and `account_number` today.

## Decisions

- Purpose: US live sizes like the backtest, levered targets included. `Engine.effective_targets` already caps a single target at 2.0: it scales targets so that `target x (1 - ratio)` stays at or below 1 (`engine/engine.ml:237-256`), and the US ratio is 0.5 (`engine/engine.ml:134`).
- Mapping: the account debit becomes one margin lot on the strategy's one stock.
- `Alpaca.account_t` gains `cash`, `long_market_value`, and `short_market_value`.
- Position value V is `held x provisional.c`, the price the planner trades at. Alpaca's `equity` field feeds only the startup log line.
- The new pure function `Live.us_plan_state` builds the `Engine.plan_state`. The new pure function `Live.us_plan_action` checks the account, plans, and returns the order. `Live.decide_action` and `Live.us_rebalance_action` go away, with their `broker/live.mli` entries (`broker/live.mli:63-78`).
- The state carries no accrued interest. [Interest](#interest) bounds the gap.
- Four account checks fail the decision before planning. See [Errors](#errors).
- The on_change skip `target unchanged` stays in front of the planner. The v0.11.0 docs and tests pin its text.
- `bt target` prints `cash:` and `debit:` after `equity:`.

## Design

### Alpaca account

`Alpaca.account_t` (`broker/alpaca.ml:10-15`, `broker/alpaca.mli:13`) gains three float fields: `cash`, `long_market_value`, and `short_market_value`. `parse_account` adds `.cash`, `.long_market_value`, and `.short_market_value` to its jq TSV projection and parses each with `float_field`, as it parses `equity`. `float_field` wraps `float_of_string` (`broker/alpaca.ml:76-78`), so it accepts `nan` and `inf`. The cash check in [Errors](#errors) rejects both.

`equity` stays in the record. `run_us` still logs it at startup (`broker/live.ml:1006-1007`). Sizing stops reading it.

### Plan state

```ocaml
val us_plan_state :
  cash:float -> held:float -> price:float -> ratio:float ->
  previous_target:float -> Engine.plan_state
```

The body, with V as `value` and the debit D as `debit`:

```ocaml
let us_plan_state ~cash ~held ~price ~ratio ~previous_target =
  let value = held *. price in
  let debit = Float.max 0. (-. cash) in
  let margin_value = Float.min value (debit /. ratio) in
  let cash = Float.max cash 0. in
  { Engine.equity = cash +. value -. debit; cash;
    cash_values = [| value -. margin_value |];
    margin_values = [| margin_value |]; loans = [| debit |];
    interests = [| 0. |]; tail_interests = [| 0. |];
    debt = 0.; receivables = 0.;
    previous_targets = [| previous_target |] }
```

The caller passes `ratio` as `(Engine.profile_of_market "us").default_financing_ratio`, which is 0.5 (`engine/engine.ml:129-136`).

The engine keeps cash and loans apart. A margin buy pays `(1 - ratio)` of its value from cash and books the rest as a loan (`engine/engine.ml:1872-1878`). Alpaca nets both into one signed `cash`. A negative `cash` is the loan and leaves no free cash, so the state's cash is 0 and its loan is D. A positive `cash` is free cash, and D is 0. In both cases the state's equity reduces to `cash + V`, Alpaca's own equity formula priced at the provisional close.

`D / ratio` is the position value that a loan of D finances at the initial ratio. That much of the position becomes margin inventory, and the rest becomes cash inventory. For example, cash -20000 and V 60000 give D 20000, margin value `min 60000 40000` = 40000, cash value 20000, and equity 40000.

A debit above `V x ratio` clamps the margin value to V. Cash -40000 and V 60000 give margin value 60000, cash value 0, loan 40000, and equity 20000. The loan then exceeds `ratio x margin value`, and the planner handles it as it handles a backtest margin lot in that state. A sell takes margin inventory first and repays the loan in proportion (`engine/engine.ml:355-389`). The lot adds no refinance capacity, because its margin rate `ratio - loan / margin value` clamps at 0 (`engine/engine.ml:486-493`).

V uses the provisional close, not `long_market_value`, because the planner prices every leg at `provisional.c`. TW made the same choice in v0.11.0 (`CHANGELOG.md:18`). `long_market_value` serves only the other-symbols check.

### Interest

Alpaca charges margin interest as `(settlement-date debit x rate) / 360`. Interest accrues daily and posts to the account at month end. The rate is 6.50% for non-elite and 5.00% for elite accounts, per [Alpaca: Margin and Short Selling](https://docs.alpaca.markets/us/docs/margin-and-short-selling) (updated 2026-09-17). The account endpoint exposes no unposted accrual. Its schema documents `accrued_fees` only as "The fees collected."

`us_plan_state` sets `interests` to 0, so the planner's equity misses the interest accrued since the last posting. The overstatement stays under about one month of accrual: `debit x 0.065 / 360 x 31`, about 0.56% of the debit. At target 1.5 that is about 0.28% of equity. This spec accepts the gap as a known difference from the backtest; no slippage comparison supports it. The backtest instead accrues interest per bar (`docs/engine.md:115`). Posted interest lowers `cash`, so the next session's state includes it.

bt's US default financing rate stays 6.25% (`engine/engine.ml:133`). `bt run --financing-rate PERCENT` sets another rate for the backtest (`docs/cli.md:563`).

### Planner call

```ocaml
val us_plan_action :
  rebalance:bool -> symbol:string -> date:string ->
  account:Alpaca.account_t -> held:float -> price:float ->
  target:float -> previous_target:float ->
  Engine.plan_state * action
```

`us_plan_action` runs these steps in order:

1. Build the state with `us_plan_state ~cash:account.cash ~held ~price ~ratio ~previous_target`.
2. Run the four account checks in [Errors](#errors).
3. If `not rebalance && target = previous_target`, return `Skip "target unchanged"`.
4. Plan the fill:

   ```ocaml
   Engine.plan_fills
     ~costs:[| Engine.default_costs ~market:"us" ~symbol |]
     ~capital:1. ~profile ~financing_ratios:[| ratio |] ~state
     ~prices:[| price |] ~targets:[| target |] ~force:rebalance
   ```

5. Take the one planned asset's net trade value: `plan_buy_cash + plan_buy_margin - plan_sell_cash - plan_sell_margin`.
6. Turn the net into an action:
   - Net 0: `Skip "no trade planned"`.
   - Net above 0: a buy of `net / price` shares.
   - Net below 0: a sell of `min (-. net /. price) held` shares. When the plan's `plan_final_value` is 0, the sell is exactly `held`.
   - The quantity passes through `float_of_string (Alpaca.qty_string quantity)`, as `decide_action` does today (`broker/live.ml:75`).
   - A quantity of 0, or a buy worth under USD 1, returns `Skip "below $1 minimum order value"`.
   - Anything else returns `Order { side; qty; id = client_order_id ~symbol ~date }`.

`capital:1.` makes plan values absolute USD, as in the TW arm (`broker/live.ml:237`). The US default costs charge no buy commission; a sell pays 0.206 bps tax and a per-share sell fee capped at USD 9.79 (`engine/engine.ml:144-146`). The planner sizes after those costs, as the backtest does.

A levered buy short of cash can make the planner refinance: it sells cash inventory and rebuys the same value on margin (`plan_refinance_cash`, `plan_refinance_margin`). TW live sends both legs of each pair (`broker/live.ml:255-258`). An Alpaca margin account borrows at the account level, so the net excludes both fields, and a refinance pair never produces an order.

The full-close rule mirrors the engine, which zeroes a position's inventory when its final value is 0 (`engine/engine.ml:1733-1736`). Without it, `held x price / price` can land one ulp below `held`, and 9-decimal truncation would leave a 1e-9-share residue.

The US arm of `Live.decide` keeps its target and previous-target code (`broker/live.ml:589-608`). It then reads `Alpaca.account mode` and `Alpaca.position_qty mode symbol` and calls `us_plan_action ~rebalance ~symbol ~date:provisional.date ~account ~held ~price:provisional.c ~target ~previous_target`.

### Decision record and output

`Live.decision` (`broker/live.ml:21-28`, `broker/live.mli:24-31`) gains `cash : float` and `debit : float` after `equity`.

| Arm | `equity` | `cash` | `debit` |
|---|---|---|---|
| US | the state's `equity` | the state's `cash` | the state's loan, D |
| TW | unchanged | the inferred `cash` (`broker/live.ml:723-742`) | the `loans` total from `position_totals` (`broker/live.ml:718-720`) |

`print_decision` (`bin/bt.ml:682-724`) prints `cash: %.10g` and `debit: %.10g` between `equity:` and `held:`, for both arms. The daemon's decision line (`broker/live.ml:828-834`) keeps its fields. Its `equity=` now carries the planner's equity.

`execute_decision` (`broker/live.ml:876-917`) does not change. It still receives one `Order` or one `Skip`.

## Errors

`us_plan_action` raises `Failure` for these account states, in this order, before it plans. The order lets each message name the cause: the short check runs before the equity check, because a short position can also make equity negative.

| Order | Condition | Message |
|---|---|---|
| 1 | `account.cash` is NaN or infinite | `US account cash is not finite` |
| 2 | `account.short_market_value <> 0.` or `held < 0.` | `US account holds a short position` |
| 3 | `abs_float (account.long_market_value -. v) > 0.01 *. account.long_market_value`, with `v = held *. price` | `US account holds other symbols` |
| 4 | the state's `equity` is NaN, infinite, or at most 0 | `US account equity is not positive` |

Check 3 carries a `ponytail:` comment. The 1% tolerance absorbs the gap between Alpaca's real-time mark and the provisional close. If a false positive skips a session, list `/v2/positions` instead. `bt target --provisional-close PRICE` with a price more than about 1% away from Alpaca's mark trips this check on an account that holds the stock.

Each failure takes the existing `run_us` path. `us_step` catches the exception from `decide`, logs `date=<date> error=Failure("<message>") order=retry`, and retries every 60 seconds (`broker/live.ml:969-972`). Once the submit cutoff passes, the session ends with `error=submit cutoff passed order=skip` (`broker/live.ml:953-956`). `bt target` fails the decision without an order, as it does for a stale cache (`docs/cli.md:292`).

Existing errors stay. `Alpaca.qty_string` still raises `Invalid_argument` for 2^22 shares or more (`broker/alpaca.ml:247-249`). An Alpaca rejection, for example for insufficient buying power, still logs `error=Alpaca rejected the order order=skip` (`broker/live.ml:903-905`).

## Tests

Tests follow `CONTRIBUTING.md`: plain asserts in `test/test_bt.ml`, injected values, no broker, and a derivation comment above each expected value.

1. `us_plan_state`, ratio 0.5, price 100:
   - Cash only: cash 50000, held 100. V is 10000 and D is 0, so margin value 0, cash value 10000, loan 0, cash 50000, equity 60000.
   - Levered: cash -20000, held 600. V is 60000 and D is 20000, so margin value 40000, cash value 20000, loan 20000, cash 0, equity 40000.
   - Clamp: cash -40000, held 600. `D / ratio` is 80000, above V, so margin value 60000, cash value 0, loan 40000, equity 20000.
2. Same-state equivalence with `Engine.run`. Run two bars at one flat price P with `Close_same` fills, zero financing rate, the US profile, and US default costs. Bar 1 builds a position from capital at target t0, and bar 2 moves to t1. Cover a cash buy (0.3 to 0.6), a cash sell (0.6 to 0.3), a levered buy (1.5 to 1.8), and a levered sell (1.5 to 1.2). Take E1 and E2 from the equity curve and `from_e` and `to_e` from the bar-2 fill. The backtest trades `(to_e x E2 - from_e x E1) / P` shares. Feed `us_plan_action` the same account: held `from_e x E1 / P`, cash `E1 - held x P`, long market value `held x P`, previous target t0, target t1. Assert that its quantity matches the backtest's within 1e-9 shares, one truncation step. The flat price and zero rate make the one-lot mapping exact: the engine's bar-1 loan is then `ratio x margin inventory`, which `D / ratio` recovers.
3. Account checks: one case per message in [Errors](#errors), including held -1 with `short_market_value` 0. A long market value of `1.005 x V` passes check 3, and `1.02 x V` fails it.
4. Skips:
   - On_change with `target = previous_target` returns `Skip "target unchanged"`.
   - Daily with held 0, cash 1000, target 0, and previous target 0 returns `Skip "no trade planned"`.
   - Held 1, price 300, cash 0.6, target 1 plans a 0.002-share buy worth USD 0.60 and returns `Skip "below $1 minimum order value"`.
5. `bt target` prints `cash:` and `debit:` right after `equity:`. The suite has no offline path into `bt target`'s US arm: `Live.decide` always runs `Data.fetch`, which needs `TIINGO_TOKEN`, and reads the Alpaca account. [Acceptance](#acceptance) checks these lines in the paper session.

Migrations:

- `test_us_live_fractional`, `test_us_live_rebalance_action`, and `test_us_live_quantity_limit` (`test/test_bt.ml:4703-4821`) call `us_plan_action` with cash `equity - held x price` and long market value `held x price`. The quantity-limit cases pass `~rebalance:true`, since their target and previous target are both 0. The expected values stay: US buys pay no commission or slippage, and a full close sells exactly `held`.
- `test_alpaca_account_parse` (`test/test_bt.ml:4551-4560`) expects `cash` -23140.2, `long_market_value` 126960.76, and `short_market_value` 0 from the fixture.
- The decision records built at `test/test_bt.ml:4860`, `4894`, `4920`, `4947`, and `4985` gain `cash` and `debit`.

Gates: the build and the full suite exit 0. `engine/` does not change.

## Acceptance

Run a paper session on `/sandbox/research/strategies/us/paper_probe/main.strat`. The file declares `stock "us/TQQQ"` and `target 0.2`. The paper account must hold no symbol other than TQQQ.

1. Add `rebalance daily` to the file.
2. Run `bt live main.strat` on paper for at least three sessions: target 0.2, then 1.5 for one session, then 0.2 again.
3. Before each session's decision, run `bt target main.strat`. Check that it prints `cash:` and `debit:` right after `equity:`.
4. From each session's decision line, compute the post-trade exposure `(held + signed quantity) x provisional close / equity`.
5. After the session's bar lands in the cache, run `bt run main.strat --capital 100000 --fill close` on the same cached bars. Read that date's `to_exposure` from `main.trades.csv`, skipping refinance rows, whose `from_exposure` equals `to_exposure`. It must match the post-trade exposure from step 4 to 4 decimal places.
6. In the session after the 1.5 fill, `bt target` must print `cash: 0` and a `debit` equal to `held x provisional close - equity`, about 0.5 x equity. The sell back to 0.2 must reach 0.2 exposure by step 5.

> [!WARNING]
> TQQQ is a 3x leveraged ETF, and Alpaca's overnight maintenance for 3x ETFs is 75% of market value. At exposure 1.5 the requirement is `0.75 x 1.5 = 1.125 x equity`, above equity, so holding overnight can draw a margin call the next morning. Hold 1.5 for one session only. A paper margin call does not invalidate the sizing checks.

> [!NOTE]
> `docs/specs/live-trading.md:42` records that paper accounts do not simulate dividends. This spec assumes paper posts no margin interest either, so the acceptance makes no interest check.

## Docs

Update these files with the implementation:

- `docs/specs/live-trading.md`: step 4 (line 65) sizes through the planner from `cash` and the position value. Line 42 no longer says bt sizes from the account's `equity`. The margin paragraph (line 72) corrects the financing rate to 6.50% non-elite and 5.00% elite, charged as `debit x rate / 360`, accrued daily, and posted at month end. It keeps bt's 6.25% backtest default and names `bt run --financing-rate PERCENT` as the override. The non-goal at line 98 narrows to financing interest, maintenance, and cures, since sizing now uses the planner. A dated note links this spec.
- `docs/cli.md`: the shared `bt target` output table (lines 224-236) gains `cash` and `debit`, and its `equity` row describes the planner's equity. The US decision cycle (line 276) describes planner sizing and `no trade planned`. US `bt target` failure handling (line 292) and US `bt live` failure handling (line 447) list the four account messages. The `bt live` sizing sentence (line 439) follows the planner.
- `docs/engine.md`: the US live paragraph (line 143) says the daemon sizes with `plan_fills` from the account's cash, position value, and debit.
- `CHANGELOG.md` under `[Unreleased]`: Changed, US live sizes through the backtest planner and maps the account debit into one margin lot. Added, `bt target` prints `cash` and `debit`. Changed, US live fails a session with the four account messages.

## Out of scope

- Alpaca's maintenance table, margin calls, and the concentrated-position rule.
- The pattern-day-trader intraday multiplier 4, which the fixture's `multiplier` shows.
- Short positions.
- Options.
- Multi-stock live trading, which has its own deferred spec.
- Modelling accrued margin interest.
