# Design: short positions and the overnight cycle

Date: 2026-10-10
Status: approved, not implemented

> [!IMPORTANT]
> The engine gains a general short position model, parameterized by the market profile, and the DSL gains an `overnight` statement that enters a position at the close and exits it at the next open. The reversed overnight cycle (sell short at the close, buy to cover at the open) is one use of both. Live support is US only.

## Contents

- [Context](#context)
- [Decisions](#decisions)
- [Design](#design)
  - [Market profile](#market-profile)
  - [DSL](#dsl)
  - [Engine inventory](#engine-inventory)
  - [Planning](#planning)
  - [Carried shorts](#carried-shorts)
  - [Overnight cadence](#overnight-cadence)
  - [Live account mapping](#live-account-mapping)
  - [Live entry](#live-entry)
  - [Live exit and cover](#live-exit-and-cover)
  - [Live daily mode](#live-daily-mode)
- [Errors](#errors)
- [Tests](#tests)
- [Acceptance](#acceptance)
- [Docs](#docs)
- [Out of scope](#out-of-scope)

## Context

bt is long-only. `Engine.clamp_target` maps a negative target to 0 (`engine/engine.ml:217-218`), `Intraday.normalize` rejects one (`intraday/intraday.ml:40-43`), and the US live decision rejects an account that holds a short (`broker/live.ml:127-128`). Every engine helper assumes nonnegative inventory: `required_margin` sums only positive values (`engine.ml:1180-1187`), `sell_inventory` acts only on `amount > 0` (`1343-1425`), trips open only from a long (`1711-1712`, `1853`), dividends are booked only when the per-asset total is positive (`1228`), and the end-of-run close requires `total_value > 0` (`2206`).

`Engine.run` fills at one point per bar, chosen for the whole run by `~fill` (`engine/engine.mli:171-182`; `walk_bars` at `engine.ml:2072`): `Close_same` fills at close t with the bar's target, `Open_next` fills at open t with the previous bar's target. A strategy that holds a position from one close to the next open needs two fill points per bar, which no mode gives.

The US daemon decides once a day at close minus 15 minutes and submits by close minus 2 (`broker/live.ml:358-370`); between the close and the next decision `us_step` sleeps (`1114-1159`). It has no step at the open. Alpaca's rules that shape the live design: a short sale is a `sell` with no position; shorts are whole shares only, since fractional sell orders are marked long (fractional-trading doc, Notes); a market `day` order submitted after the close is queued for the next session and a market order received before 09:28 ET fills at the Nasdaq official opening price (orders doc, Time in Force and Order Handling Standards); `opg` orders need a sales enablement and never apply to fractional orders; buying power for a market short is checked at 3% above the ask; a short of a non-ETB name needs a locate.

The user's request is 反向隔日沖: sell short at the close, buy to cover at the next open, flat during the day, for US symbols. The chosen scope (option 2 in the brainstorm) is the general short model, with the overnight cycle as one use of it, and a design abstract enough that another broker's rules are a profile change, not an engine change.

## Decisions

| Topic | Decision |
| --- | --- |
| Scope | A general short model in the engine (carried shorts allowed in daily strategies), plus an `overnight` statement for the close-to-open cycle in either direction. Live support for both is US only. |
| Opt-in | Shorts are opt-in per file through a `short` statement. Without it the target floor stays at 0 and every existing file compiles exactly as before. `overnight` with a negative target also needs the declaration. |
| Broker rules | Short terms live in `Engine.market_profile` as data, with Alpaca's values as the US defaults and flag overrides. The engine names no broker. TW declares shorts unsupported. |
| Representation | A separate short leg per asset (`short_values`, `short_lots`), all arrays nonnegative, the sign in the target. Long paths are untouched. |
| Collateral | Reserved cash: a short lot reserves its proceeds plus the collateral (`(1 + short_initial_ratio) x proceeds`), a buying-power constraint inside `plan_fills`, counted in equity. Opening a short changes equity only by costs. |
| Whole shares | The short leg is floored to whole shares through its own quantum; the long leg stays fractional. |
| Overnight exit (live) | Submitted by a post-close gate the same evening as a market `day` order with its own client order id, then verified at 09:35 ET with bounded resubmission under distinct ids, each after the previous exit is canceled and confirmed terminal. Order cancel and order listing are new Alpaca calls. |
| Late exit | A position still open at the 15:45 decision is closed at the close first, logged, and only then is the new entry planned. No entry is placed while an old position is open. |
| Proof | Unit parity against the engine, plus a five-session paper week of `overnight` with a short target on QQQ, after the current paper run finishes. |

## Design

### Market profile

`Engine.market_profile` (`engine/engine.mli:112-122`) gains:

| Field | Meaning | US default | TW |
| --- | --- | --- | --- |
| `short_initial_ratio : float` | Collateral reserved per unit of short proceeds; the position is held at `1 + ratio` times proceeds. | 0.5 (Reg T 150%) | n/a |
| `short_maintenance : short_maintenance` | `Tiers of short_tier list` or `Unsupported`, where `short_tier = { price_below : float; per_share : float; rate : float }`. Tiers are ordered by `price_below` ascending; the first tier whose `price_below` is strictly above the mark price applies; the last tier has `price_below = infinity`. The requirement is `max (per_share x shares) (rate x short_value)`. | `Tiers [ { price_below = 5.0; per_share = 2.5; rate = 1.0 }; { price_below = infinity; per_share = 5.0; rate = 0.30 } ]` | `Unsupported` |
| `default_borrow_rate : float` | Annual borrow fee on the short value, per `interest_day_count`. | 0.0 (ETB); `--borrow-rate PCT` overrides | n/a |
| `short_owes_dividends : bool` | The short pays the cash dividend on the ex-date. | true | n/a |
| `short_share_quantum : float` | Minimum short share increment. | 1.0 | n/a |

`bt run` gains `--borrow-rate PCT` and `--short-maintenance-ratio PCT` (a flat rate that replaces the tiers, like `--maintenance-ratio` for longs). `Engine.margin` carries the two overrides as options.

### DSL

- `short` statement (one per file; a second fails with `<file>: duplicate short declaration`): declares that targets may be negative. Allowed only in daily strategies (`bars` plus `short` fails with `<file>: short applies to daily strategies only`).
- `target` may evaluate below 0 only in a file with `short`; `Dsl.compile_ast` floors the target at `-short_cap` for such files and at 0 otherwise, where `short_cap = 1 / short_initial_ratio` (2.0 at the US default); the DSL has no upper cap today and gains none, the engine keeps its upper handling. A file without `short` keeps the zero floor whatever the target evaluates to; there is no error for a negative target. `Engine.effective_targets` scales longs by their down payment `target x (1 - ratio)` and shorts by their collateral `|target| x short_initial_ratio` in one joint `need`, so the account can fund the whole book.
- `overnight` statement (one per file; `bars` plus `overnight` fails with `<file>: overnight applies to daily strategies only`): each bar's target is the position held from that bar's close to the next bar's open; the exit is forced. `overnight` with a negative target needs `short`; without it the target clamps to 0 like any other file. `bt run --fill` with `overnight` fails with `overnight does not take --fill`.
- `rebalance` applies as today; under `overnight` every bar re-enters, so `rebalance daily` and `on_change` differ only in whether an unchanged target re-enters (it does under daily; under on_change the exit still happens and the entry is skipped, leaving the account flat). The entry gate compares against the previous close-entry targets, which the forced exit does not overwrite (see Overnight cadence).
- `Dsl.short_of` and `Dsl.overnight_of` follow `Dsl.rebalance_of`'s shape.

### Engine inventory

Per asset, beside `cash_values`, `margin_values`, `margin_lots` (`engine.ml:1040-1058`):

- `short_values : float array`: the current market value of the short exposure, nonnegative.
- `short_reserved : float array` and `short_borrow : float array`: the reserved cash and the accrued borrow fee per asset. One short position per asset, no lot list: every field is proportional on a partial cover and the borrow fee accrues on the marked value, so `proceeds = reserved / (1 + short_initial_ratio)` and the share count `short_value x capital / price` are derived, never stored. Every per-share amount (`per_share` maintenance, `cash_per_share` dividends) multiplies that share count and is divided by `capital` before it enters cash or the requirement, so for USD 1,000 capital and three shares a USD 1 dividend is `3 x 1 / 1000 = 0.003` engine units.

Equity keeps every existing term (`total_receivables`, `total_liabilities`, `engine.ml:1149-1168`) and adds the short ones: `equity = cash + sum long + receivables - sum short - loans - interest - debt - borrow_accrued`. `total_value index = long_value - short_values.(index)`.

Reserved cash: a short position holds `reserved = (1 + short_initial_ratio) x proceeds`, the proceeds plus the collateral, so the account cannot spend the proceeds (Reg T 150%). Cash includes the reserved amount and equity counts it; `available_cash = cash - sum reserved` is what `plan_fills` may spend on longs. The own-equity cost of a short of exposure `|t|` is therefore `short_initial_ratio x |t|`, which is the collateral term in the joint `need`. A long and a short never coexist in one asset: a sign flip covers or sells the whole old leg before opening the new one, in the same bar.

### Planning

`plan_fills` (`engine.ml:282-944`) routes a negative effective target to the short leg:

- Trade on the short leg is the change in short magnitude at the bar's price: `desired = |eff| x e1`, `trade = desired - short_value`.
- Opening or adding: proceeds raise cash; `reserved = (1 + short_initial_ratio) x proceeds` is reserved; the sale pays the sell-side charge (`charge` at `178-198`, delta < 0). The short quantity is floored to `short_share_quantum` in a flooring step applied to the short leg only, so the long path's `quantized` branch (`305`) is untouched.
- Covering or reducing: the cover pays the buy-side charge; reserved cash is released in proportion; proceeds are consumed.
- Funding: `available` (`435-440`) subtracts reserved cash; a short adds no refinance capacity. The leverage predicate (`unlevered = sum eff <= 1.`, `304`) changes to the sum of the positive targets only, so long 1.5 with short -0.5 is levered and funds its long leg through the refinance waterfall as today; without this change the signed sum 1.0 would send the long leg to the cash-only cap.
- `planned_asset` gains `plan_short_open` and `plan_short_cover` values; `legs_of_plan` (TW) ignores them, since TW rejects shorts at parse time.

### Carried shorts

In daily mode a short persists across bars:

- Borrow fee: `short_value x borrow_rate / interest_day_count x days` accrues into `short_borrow`, where `days` is the calendar difference between the bar's date and the next bar's date (a weekend is three days, as `accrue_interest` already computes at `1672-1681`); charged from cash when the position closes (and marked in equity meanwhile), like margin interest.
- Dividends: on the ex-date, a short pays `shares x cash_per_share / capital` from cash, with no withholding; booked where `process_dividends` books the long receipt (`1207-1283`), at the open before fills.
- Maintenance: `required_margin` (`1180-1187`) adds, per short asset, the tier requirement from the profile (`max (per_share x shares / capital) (rate x short_value)`), or `rate x short_value` with the flat override. The two gates that today run only when `total_loans () > 0.` (`track_maintenance` at `1426-1442`, the daily call trigger at `2187-2193`) run when `total_loans () > 0. || sum short_values > 0.`, so a loan-free short book with equity below its requirement records a call and cures. A breach is cured by buy-to-cover on the short leg, mirroring `minimum_cure` (`1923-2052`), whose zero-long-margin bankruptcy guard gains the short case: a book with no long margin and no short is bankrupt, a short-only book cures by covering. The cure order is longs first then shorts, each the minimum that restores the requirement. Bankruptcy covers every short. `guard_solvency` (`1898-1903`) counts short exposure.
- Trips: a short opens a trip on the first sale from zero and closes it on the cover to zero; the trip carries the sign; `net_ret` for a short is `(entry - exit) / entry`.
- End of run: open shorts are covered at the last close like longs are sold (`2203-2215`).

### Overnight cadence

With `overnight`, `walk_bars` runs a third cadence beside `Close_same` and `Open_next`, which stay unchanged:

1. At open t: scale values to the open; book ex-date dividends on the position held overnight (a long receives, a short pays); `guard_solvency` at open prices, so an adverse gap that makes equity nonpositive liquidates at the open like the existing cadences do before their fill pass (bankruptcy covers every short and the run holds no position afterwards); then, if solvent, the exit fill: `apply_fills` to target 0 for every asset at open prices with `force:true`, called with a new `~remember:false` so `prev_eff` keeps the last close-entry targets (today `apply_fills` blits `eff` into `prev_eff` unconditionally, `1896`). The open mark is internal: it feeds solvency, maintenance, and the fill rows; the equity curve keeps one point per bar at the close, so `Report.write_equity` and `Metrics.daily_returns` are unchanged.
2. The daily maintenance check keeps its place at the close, after the entry, so `min_maintenance` tracks the held position; a call recorded at the close is dropped at the next open before the exit, since the forced exit covers everything at the price a cure would use.
3. At close t: the entry fill to the bar's effective target at close prices (skipped after bankruptcy); equity marked; `prev_eff` updated.
4. Interest and borrow accrue for the calendar days from the bar's date to the next bar's date; the last bar accrues nothing because the end-of-run close liquidates at its close.

Settlement lag counts bars as today. The fill log stays an event log with the existing five columns and no new field: `record_fill` writes a row per asset per nonzero trade, so a bar has up to two rows per asset, the exit row at the open price first, then the entry row at the close price; a skipped entry or a flat bar writes nothing; the end-of-run close writes its row as today, after the last entry. A reader selects the close entry of a date as the row for that symbol and date whose `to_exposure` is nonzero; exit rows, including the end-of-run close, end at 0.

### Live account mapping

`us_plan_state` (`broker/live.ml:91-110`) gains the short leg: a negative `position_qty` (Alpaca reports signed quantities) becomes `short_values = -qty x price` and one short lot with `proceeds = short_values` and `reserved = (1 + short_initial_ratio) x proceeds`; cash is Alpaca's cash (it already includes the proceeds). Checks (`112-164`):

- Check 2 becomes: every short in the account belongs to a strategy symbol in a file that declares `short`; otherwise `US account holds a short outside the strategy`. A file without `short` keeps today's rejection message.
- The 1% mark check runs on long and short legs separately: `long_market_value` against the long legs as today (`135-136`); `-short_market_value` against `sum short_values`, since Alpaca reports the short mark as a negative number (`equity = cash + long_market_value + short_market_value` in the account schema), with the finite check and a tolerance of `0.01 x (-short_market_value)`.
- `initial_margin` and `shorting_enabled` are parsed into `account_t` for the startup log; sizing uses the profile, not Alpaca's fields.
- `us_plan_action` (`150-151`) nets the short fields too: `net = plan_buy_cash + plan_buy_margin + plan_short_cover - plan_sell_cash - plan_sell_margin - plan_short_open`; a negative net is a sell, which may take the position below zero only when the asset's effective target is negative and the file declares `short`; the short part of the quantity is floored to whole shares.
- Sign flip (daily mode only; under `overnight` the position is flat at the decision): the live daemon never flips in one session. The decision closes the old leg under `bt-SYM-DATE` (fractional allowed for a long close) and opens the new leg at the next decision, so the new leg sizes against real holdings and the one-order path, restart routing, and the submit window stay as they are. One net order is impossible because Alpaca marks a fractional sell long. So that the deferred leg opens under `rebalance on_change`, `us_plan_state` in a `short` file without `overnight` replaces `previous_targets.(i)` with the signed held exposure fraction (`held_value / equity`, 0 when flat) whenever its sign differs from the target's sign; `us_plan_action`'s skips (`140-148`) and `plan_fills`'s own `changed` gate (`engine.ml:320-323`) then both see a change for that asset only. The backtest flips in one bar; the runbook records the one-session lag as a fidelity limit.

### Live entry

The 15:45 decision plans through `plan_fills` as today. A short entry is a whole-share `sell` with `client_order_id = bt-SYM-DATE`. At startup `run_us` reads `GET /v2/assets/{sym}` for every symbol in a `short` file and fails closed unless `shortable` and `easy_to_borrow` are true (`<symbol> is not shortable` / `<symbol> is not easy to borrow`).

### Live exit and cover

Under `overnight`:

1. Evening: the exit is submitted by a post-close gate, never by the entry's fill: after the session close (`clock.is_open = false` and the timestamp is past the session's `next_close`), for every entry that is `filled` or `partially_filled` the daemon submits the exit for the quantity held per a positions read: a market `day` `buy` with `client_order_id = bt-SYM-DATE-cover` for a short, a market `day` `sell` with `bt-SYM-DATE-exit` for a long (fractional allowed on the long side). An entry still nonterminal at close plus 5 minutes (the existing `poll_fill` deadline) goes through the settle step: call the new `Alpaca.cancel_order` (`DELETE /v2/orders/{id}`; a 422 means the order is not cancelable, which is not proof of a final state), then poll the order until its status is final: `filled`, `canceled`, `expired`, or `rejected` (the states Alpaca's lifecycle doc marks as receiving no further updates); `pending_cancel` and `stopped` (a guaranteed trade not yet executed) are outstanding, and a fill during the cancel counts as filled. The settle step's final set is narrower than `terminal_order_status` (`live.ml:969-971`), which keeps `stopped` for its logging consumers. Then re-read the positions and submit only a nonzero remainder. Alpaca queues the exit and fills it at the opening print; a fractional-only sell fills at the NBBO when it is worked at the open, and a mixed whole-plus-fraction sell prices the fraction at the whole-share fill (fractional-trading doc, Notes). The backtest uses the open for both; the runbook records the fractional-only case as a fidelity limit.
2. 09:35 ET step (new in `us_step`): look up the exit id series (`-cover`, `-cover2`, ... or `-exit`, `-exit2`, ...). Filled: done. Outstanding (`new`, `accepted`, `partially_filled`, `pending_cancel`, `stopped`): re-check every 60 s until 09:50. Final and unfilled, or 09:50 reached with a remainder: run the settle step on the latest exit (no-op when it is already final), then submit a market order for the quantity still held under the next id in the series; at most three resubmissions, then log `overnight exit unfilled` and leave the position for the late-exit rule. A resubmission is never placed while a previous exit in the series is outstanding.
3. Late exit: if the decision at close minus 15 minutes finds an overnight position still open, it closes it as the session's first order (`bt-SYM-DATE-late`), logs `overnight position closed late`, and plans the new entry only after that order is `filled` and a positions read shows the symbol flat, and only while the submit window is still open (close minus 2 minutes from `clock.next_close`); otherwise it logs `overnight entry skipped` and the session stays flat. A canceled, expired, rejected, or stopped late close counts as not closed.

Restart discovery: `us_step` today builds ids from the current date only (`1129-1146`) and the finish dispatch resolves unsuffixed entry ids only (`1186-1188`). Both change: at startup and at the 09:35 step the daemon lists recent orders through a new `Alpaca.list_orders` (`GET /v2/orders?status=all&limit=500&direction=desc&after=<7 days ago>&symbols=...`, paged with `until=<submitted_at of the last row>` until a page is short), keeps ids with the `bt-SYM-` prefix, and takes the latest such order per symbol, entry or exit. The date in that id anchors the symbol's series: the daemon resumes that series (verify the latest exit, settle, resubmit under the next number) until it is final and the symbol is flat, and allocates a new series only then. So a Monday restart finds Friday's entry and its exit, a restart between the entry fill and the exit submission submits the missing exit at once if the session is closed, and a restart after an entry-less exit resumes that exit under its own date. A strategy symbol held with no `bt-SYM-` order in the window (the daemon was down longer than a week) is treated as an overnight position with an unknown entry: the daemon logs `overnight position without entry` and exits it at the next exit point (evening if the session is closed, else the 09:35 step, else the late exit) under today's ids. The finish dispatch resolves a suffixed id by stripping the suffix. An existing exit in the series means verify, never resubmit blindly.

### Live daily mode

A file with `short` and without `overnight` carries shorts across sessions: the entry path is the same; no exit step; the decision at close minus 15 minutes resizes the short like a long, and a sign flip takes two sessions (see Live account mapping). Alpaca's overnight maintenance applies on the broker side; bt's profile rule sizes the backtest.

## Errors

| Message | Where |
| --- | --- |
| `<file>: duplicate short declaration`, `<file>: short applies to daily strategies only` | parse validation |
| `<file>: duplicate overnight declaration`, `<file>: overnight applies to daily strategies only` | parse validation |
| `overnight does not take --fill` | bt run |
| `short targets are not supported for tw`, `overnight is not supported for tw` | bt run, bt target, bt live, at parse validation with the file name |
| `<symbol> is not shortable`, `<symbol> is not easy to borrow` | run_us startup |
| `US account holds a short outside the strategy` | decide, check 2 |
| `overnight exit unfilled`, `overnight position closed late`, `overnight entry skipped`, `overnight position without entry` | daemon log lines, not failures |

## Tests

| # | Subject | Cases |
| --- | --- | --- |
| 1 | Opt-in clamp | Without `short`, `effective (-1.) = 0` stays pinned and compiles without error; with `short`, a negative target is kept and capped at `-short_cap`. |
| 2 | Joint scaling | Mixed long and short targets scale together by down payment plus collateral; long 1.5 with short -0.5 is classified levered and the long leg is financed, never cut to the cash cap. |
| 3 | Short leg | Open from flat: proceeds in cash, `reserved = 1.5 x proceeds`, `available_cash` excludes the proceeds, equity unchanged except costs; add; reduce; cover to zero releases the reserve; sign flip in one bar; equity identity keeps receivables and debt (existing `test_tw_dividend_receivable` and `test_engine_exit_fee_bankruptcy` unchanged). |
| 4 | Whole shares | A short of 2.6 shares plans 2; the long leg of the same run stays fractional. |
| 5 | Carried short | Borrow fee accrues per calendar day (Friday to Monday is three); dividend owed on the ex-date at capital 1000 (0.003 engine units for three shares and USD 1); maintenance tiers with the per-share floor at capital 1000 and the band switch at 5; a loan-free short book below its requirement records a call and cures by buy-to-cover; bankruptcy covers; end-of-run cover; short trip with signed return. |
| 6 | Overnight cadence | Entry at close, exit at next open, one equity point per bar; an overnight short across an ex-date pays the dividend before the exit; an adverse opening gap to nonpositive equity liquidates at the open and places no close entry; `rebalance on_change` with an unchanged target exits and does not re-enter (the forced exit leaves `prev_eff` intact); the last bar accrues no night; `--fill` rejected. |
| 7 | Byte gates | The six pinned gates stay identical (no `short`, no `overnight`). |
| 8 | DSL errors | Every message in the Errors table, including the TW boundary in bt run, target, and live. |
| 9 | Live mapping | `us_plan_state` with a negative position; the flipped check 2; the split mark check against a negative `short_market_value`, including the tolerance sign. |
| 10 | Live parity | The whole-share short quantity equals the engine's short fill for the same state (cash and levered book); a flat-account short plan yields a sell order, never `no trade planned`; a sign flip yields the close only, and the next decision with an unchanged target opens the new leg under `rebalance on_change` because `previous_targets` carries the held exposure for that asset while other unchanged assets stay skipped. |
| 11 | Exit submission | Submitted only by the post-close gate, also for an entry filled at the decision; an entry nonterminal at close plus 5 minutes goes through the settle step, including a fill during the cancel and a 422 on an already terminal order; cover for a short, sell for a long; ids `-cover` / `-exit`; quantity from the positions read; a zero remainder submits nothing. |
| 12 | 09:35 step | Filled; open then filled; terminal unfilled then resubmitted under `-cover2`; open at 09:50 is settled to a final status before the resubmission; a `stopped` exit is outstanding and blocks the resubmission; partial then remainder; three resubmissions then `overnight exit unfilled`; restart with an existing `-cover` never resubmits blindly; a Monday restart discovers Friday's entry and exit through `list_orders` across more than one page; a restart after the entry fill with no exit submits the exit; a restart after an entry-less exit resumes that series under its own date; a held symbol with no `bt-SYM-` order in the window logs `overnight position without entry` and is exited. |
| 13 | Late exit | A still-open position at the decision is closed first; the entry waits for `filled` plus flat holdings; a canceled late close places no entry; a close past the submit window logs `overnight entry skipped`. |
| 14 | Asset flags | Startup fails closed on `shortable = false` and on `easy_to_borrow = false`. |

## Acceptance

After the current US paper run finishes (its last comparison needs the 2026-10-13 bar) and from a flat paper account, one daemon per market and mode:

1. A paper probe file: `stock "us/QQQ"`, `short`, `overnight`, `rebalance daily`, `target -0.3`. QQQ is ETB and has no leveraged-ETF maintenance rate.
2. Five sessions. Each session checks three things: the short quantity at the decision equals the engine's close-entry fill for the same state; the queued cover fills at the open and the 09:35 step logs it; the account is flat by 09:50.
3. One extra session with `target 0.3` proves the long cycle: entry buy at the close, queued fractional sell at the open.
4. Per-session comparison, after the next session's bar is cached: `bt run <session file> --from <session date> --to <next session date> --capital <equity at the decision>`. The replay starts flat at the session date, enters at its close, and exits at the next open, which is the live cycle; the entry row is the session-date row with nonzero `to_exposure`. The live order is sized at the decision-time price and the replay at the final close, so the runbook records both prices and checks two equalities: the live quantity equals `floor(0.3 x (equity - c) / decision price)` and the replay quantity equals `floor(0.3 x (equity - c) / close)`, where `c` is the short entry cost at that price from the US cost profile (`Engine.charge`, sell side: the per-share fee plus the rate on the value), matching the planner's `desired = |eff| x e1` with `e1 = e0 - cost`; they may differ by one share only when those two floors differ.

## Docs

`docs/strategy.md` (the `short` and `overnight` statements, negative targets, the grammar), `docs/engine.md` (short model, profile fields, overnight cadence, the two fill rows per bar), `docs/cli.md` (`--borrow-rate`, `--short-maintenance-ratio`, the cover and exit log lines, the new errors, the 09:35 step), `docs/specs/live-trading.md` (the daily cycle with the open step), `CHANGELOG.md` entries: short positions in the backtest; the overnight cycle; US live shorts and the queued exit.

## Out of scope

TW shorts and TW overnight (the TW arm rejects both at parse time); hard-to-borrow names and locates; `opg` orders; short-side leveraged-ETF maintenance rates (Alpaca publishes none; the per-share-or-rate rule applies); intraday (`bars`) shorts; a cover during the day on a price condition.
