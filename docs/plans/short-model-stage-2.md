# Short Model Stage 2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> Implementers use executing-plans only. No subagents: never dispatch a reviewer or any other agent; the coordinator owns reviews.

**Goal:** Let `bt target` and `bt live` run a US `short` or `overnight` strategy against Alpaca: map a held short into the planner, size whole-share short entries, queue the overnight exit after the close, verify it at 09:35 with bounded resubmission, close a leftover position late, and document the cycle.

**Architecture:** `Alpaca` gains order cancel, lookup by id, paged order listings, asset flags, and two account fields. `Engine.plan_fills` gains a `~frozen` array so a blocked symbol is never re-planned. `Live.us_plan_state` maps a negative Alpaca quantity into the engine's short leg and `Live.us_plan_action` nets the short fields, checks the two marks separately, freezes blocked symbols, and defers the second leg of a sign flip; `execute_decision` posts closes (long sells, covers) before opens (long buys, short sells). The overnight machinery is a set of pure functions over an injected `overnight_broker` record (`settle`, `clear_open`, `drive_exit`, `overnight_exits`, `late_exit`) that `us_step` calls at three points: the closed clock (exit gate), the pre-decision open phase (09:35 step), and the decision (late exit and the entry guard). One invariant guards every order the daemon places for a `short` or `overnight` file: list the symbol's open orders, settle each within a bound, size only from the position read afterwards. Everything is tested with fakes; no network.

**Tech Stack:** OCaml 5 (stdlib and `unix` only), dune, curl and jq subprocesses for Alpaca. No new dependencies.

## Global Constraints

- Base: branch `short-model` at commit `53139fb` in worktree `/sandbox/stock-short`. Never touch `/sandbox/stock` (daemons run there); `/sandbox/stock/data` and `/sandbox/stock/_opam` are read-only inputs. AGENTS.md is gitignored and does not load in the worktree; this section carries its facts.
- Spec: `/sandbox/stock-short/docs/specs/short-overnight.md`. Stage 2 covers Live account mapping, Live entry, Live exit and cover, Live daily mode, the daemon rows of Errors, Tests 9-14, Acceptance (the paper week is the coordinator's, after this plan lands), and the live parts of the Docs row (`docs/cli.md` log lines and the 09:35 step, `docs/specs/live-trading.md` daily cycle, the CHANGELOG entry for US live shorts and the queued exit). Stage 1 is committed; its plan is `docs/plans/short-model-stage-1.md`, which introduced `short_values`, `short_reserved`, `short_borrow`, `plan_short_open`, `plan_short_cover`, `plan_short_final`, `Engine.Overnight`, `Dsl.short_of`, `Dsl.overnight_of`, `Dsl.compile_ast ?short_cap`, `Engine.effective_targets ?short_ratio`, and the guard `short and overnight are not supported by bt target and bt live yet` in `live_command_args`, which this plan removes.
- Build and tests, in the worktree: `eval $(opam env --switch=/sandbox/stock --set-switch) && dune build --root . 2>&1 && dune build --root . @runtest --force 2>&1`. The build must print nothing (zero compiler warnings; warnings are errors, so an unused binding fails the build) and the runner's last line must be `ok`.
- Byte gates: six pinned gates, baselines in `/sandbox/stock/.superpowers/sdd/us-paper-test/{us,tw}-baseline/` (`fp.csv`, `main.trades.csv`, `stdout.txt`) generated at `--to 2026-10-02`; they must stay byte-identical and the coordinator runs them after Tasks 2 and 4. The commands are `bt run /sandbox/research/strategies/tw/channel_ladder/main.strat --baseline tw/00685L --to 2026-10-02 --capital 1000000 --data-dir /sandbox/stock/data --out-dir OUT --out-name fp --no-plot` and `bt run /sandbox/research/strategies/us/dd_ladder/main.strat --baseline us/TQQQ --to 2026-10-02 --capital 100000 --data-dir /sandbox/stock/data --out-dir OUT --out-name fp --no-plot`, each compared with `cmp` against the three baseline files (stdout captured to a file). The one engine change (`plan_fills ~frozen`, Task 2) adds a boolean conjunct to `changed` and `run` passes `[||]`, so no float operation moves; `broker/live.ml`'s long-only path stays bit-identical (Marshal gate in `test_us_plan_state_split`).
- Network is forbidden for implementers. The live code is tested with the existing fakes in `test/test_bt.ml` (`us_step`, `execute_decision`, `finish_order`, `poll_fill`, and the clock are exercised through injected closures and `Alpaca.clock_t` literals) and with `Alpaca` request builders and parsers tested offline against recorded fixtures.
- Alpaca facts, verified from the docs: market `day` orders submitted after the close queue for the next session; market orders received before 09:28 ET get the opening print; fractional sells are marked long (shorts are whole shares); `DELETE /v2/orders/{id}` returns 204, or 422 when the order is not cancelable; order statuses with no further updates are `filled`, `canceled`, `expired`, `rejected` (`stopped` and `pending_cancel` are outstanding); `GET /v2/orders?status=all&limit=500&direction=desc&after=&until=&symbols=` is sorted by `submitted_at` and `until` is exclusive; `short_market_value` is negative; `GET /v2/assets/{sym}` has `shortable` and `easy_to_borrow`.
- Style (CONTRIBUTING.md): stdlib and `unix` only; no `for` or `while` loops; sequence side effects with `let () = e in`; branch on the market with `match` arms plus an error or default `_` arm; string and open matches always carry a default arm; preserve floating-point operation order; one space on each side of `=`; ASCII only; network and JSON work through `curl` and `jq` subprocesses; typed signatures where possible; succinct code without speculative abstractions; a deliberate ceiling gets a `ponytail:` comment.
- Tests (CONTRIBUTING.md): plain asserts in `test/test_bt.ml`, exact values with a derivation comment above each expected value, one check per non-trivial branch; byte-identity gates are never weakened to tolerances.
- Documentation style (CONTRIBUTING.md): one H1, disciplined H2-H4, full-depth table of contents, tables for enumerable content with a `Default` column in `docs/cli.md`, alerts only with their fixed meanings, no mid-sentence newlines, ASCII only. Every notable behavior change adds an entry under `[Unreleased]` in `CHANGELOG.md` (Keep a Changelog 1.1.0).
- Commits: one per task, only after the coordinator confirms. Commit trailer for implementers (Claude models): `Co-Authored-By: Claude <noreply@anthropic.com>`. Never push; never change git settings.
- Line numbers in this plan are from `53139fb` and are informational; later tasks shift them. Resolve drift by the named function, type, or quoted anchor line.
- Every task's requirements implicitly include this section.

---

## Contents

- [Global Constraints](#global-constraints)
- [Spec readings](#spec-readings)
- [File map](#file-map)
- [Tasks](#tasks)
  - [Task 1: Alpaca additions](#task-1-alpaca-additions)
  - [Task 2: Live account mapping](#task-2-live-account-mapping)
  - [Task 3: Live entry](#task-3-live-entry)
  - [Task 4: Overnight exit machinery](#task-4-overnight-exit-machinery)
  - [Task 5: Docs and changelog](#task-5-docs-and-changelog)
- [Self-review](#self-review)
  - [Spec coverage](#spec-coverage)
  - [Placeholder scan](#placeholder-scan)
  - [Type consistency](#type-consistency)
  - [Offline verification](#offline-verification)

## Spec readings

These are the points where the spec left room or where its sentences pull apart; each task follows the reading stated here.

| Point | Reading |
| --- | --- |
| Where the held-sign rule runs | The spec says `us_plan_state` in a `short` file without `overnight` replaces `previous_targets.(i)` with the signed held exposure fraction whenever its sign differs from the target's sign. `us_plan_state` has no targets, so the rule runs in `us_plan_action` right after the state is built and before both skip gates, and the adjusted array is written back into the returned state (`{ state with previous_targets }`) so `plan_fills`'s own `changed` gate sees it too. "Its sign" is the held exposure's sign; a flat holding (exposure 0) differs in sign from any nonzero target, which is what makes the deferred leg open from flat under `rebalance on_change`. |
| `short_initial_ratio` in `us_plan_state` | The function keeps its signature and reads `(Engine.profile_of_market "us").short_initial_ratio`, as `us_plan_action` already reads the US profile; the reserve is `(1 + 0.5) x short value`. |
| Check 2 under `short` | "Every short in the account belongs to a strategy symbol in a file that declares `short`" is read as: with `short`, a nonzero `short_market_value` while no strategy symbol is held short fails with `US account holds a short outside the strategy`; a short mark that does not match the strategy's short holdings within 1% fails the split mark check with the existing `US account holds other symbols` (the spec names no new message for the short mark). A foreign symbol held short still fails the positions-list check first, as today. |
| Short mark tolerance sign | `abs_float (-. short_market_value -. short_value) > 0.01 *. (-. short_market_value)`; with `short_market_value = 0.` and no short held the long-only path evaluates `0. > -0.`, false, so the check is unconditional and the long-only output is unchanged. |
| Quantity of the short leg | `plan_fills` with `~capital:1.` already floors the short leg to whole shares, so the live quantity is `final - current` on the share count: `final = Engine.shares_of_value ~capital:1. ~price item.plan_short_final` (the floored final holding, as `legs_of_plan` does for TW) and `current = -held`; a cover to zero has `final = 0` and buys `-held` exactly, mirroring the long full-close rule. A sign flip (held long with a negative target, or held short with a positive target) nets to a sell or buy that trades the held leg only. |
| `order_t` unchanged | `Alpaca.list_orders` returns a new `listed_t = { client_order_id; submitted_at; order : order_t }` rather than adding fields to `order_t`, so the seven `order_t` literals in tests and `log_fill` are untouched. Pagination is driven by an injected `?page` function so the two-page case is tested offline against the API contract: pages are newest first and `until` is the exclusive `submitted_at` of the last row. |
| The POST invariant | Before every order the daemon places for a `short` or `overnight` file (the evening exit, a morning resubmission, the `-late` close, and the entry itself), `clear_open` lists the symbol's open orders with `GET /v2/orders?status=open&symbols=SYM` (no date window, any client id; the daemon owns the symbol per check 2), runs the bounded `settle` on each, and returns the position read afterwards, which is the only quantity source. Any order still outstanding makes `clear_open` return `None` after logging `note=overnight exit outstanding`; the caller places nothing for that symbol in the pass, the other symbols continue, and the next pass rediscovers it. For the entry, the Decide arm of `us_step` runs `clear_open` (through `late_exit` under `overnight`) for every symbol without an existing entry and passes the blocked symbols to `decide ~frozen`; `decide` then reads the positions itself, so the entry is sized from the cleared book. |
| The settle bound | `settle` cancels once and polls the order by its Alpaca id (`broker.order`, `GET /v2/orders/{id}`) every 15 seconds for at most 20 polls (5 minutes). It returns `Final order` or `Outstanding order`, a variant, never a fake final order. Neither a 422 on the cancel nor the timeout authorizes a successor; only `Final` does. |
| Orphan family | A held strategy symbol with no `bt-SYM-` order in the week exits under its own id family `bt-SYM-DATE-orphan`, `-orphan2`, ... (today's date), which `series_of_order` recognizes with `orphan = true`, so the day's entry series (`-cover`/`-exit`) can never collide with it. The spec's numbered-series scheme is kept; no time-stamped ids. |
| Grace period | A resubmission placed at or after the 09:50 deadline is followed by `follow ~polls:8` (every 15 seconds, 2 minutes) before `drive_exit` settles it, so a post-deadline POST does not race its own cancel. The three-resubmission bound (ids up to number 4) is unchanged. |
| Remainder after a filled exit | A final exit, filled or not, hands whatever is still held to the next number of its series: `drive_exit` runs `clear_open` (which re-reads the position) after every final exit and posts only a nonzero remainder; a flat book posts nothing. |
| Entry follow before the settle | In the evening gate an entry (or late close) still nonfinal is followed by `follow` to its session's close plus 5 minutes, computed from the exchange calendar for the series date (`broker.session_close`, backed by `Alpaca.calendar` and `Data.et_offset_minutes`, early closes included), and only then settled by the POST invariant. On the normal path `finish_order` has already waited to the close plus 5 minutes, so the follow is a no-op; it matters on a restart while closed. |
| Frozen symbols | A symbol blocked at the decision (a late close that did not fill flat inside the window, an outstanding order, or a pass that raised) is frozen before the joint `plan_fills`: `us_plan_action ~frozen` sets its target and previous target to the held exposure fraction and passes `~frozen` into `Engine.plan_fills`, whose `changed.(i)` becomes `(not frozen.(i)) && (force || eff.(i) <> prev_eff.(i))`, so under `rebalance daily` (`force:true`) the frozen asset's trade is exactly zero and the others are sized around its holding and its reserve; its action is `Skip "overnight entry skipped"`. `plan_fills ~frozen` is a required label (an optional one is unerasable, every argument being labelled); an empty array freezes nothing and `run`, the TW arm, and the sixteen existing test calls pass `[||]`. `us_step`'s `decide` callback takes `~frozen`. |
| Funding order of submissions | `execute_decision` classifies each order by its effect on the symbol's exposure, using the decision's held quantity: a sell with `held > 0` (long sell) and a buy with `held < 0` (cover) are closes; a buy with `held >= 0` (long buy) and a sell with `held <= 0` (short open) are opens. Closes post first and the opens wait for every close to be `filled`, exactly the sell barrier of today; without shorts every sell is a close and every buy an open, so the long-only order and messages are unchanged. Stop messages name the side: `sell SYM rejected` for a long close, `buy SYM rejected` for a cover. An existing order found on a restart is classified by its recorded side against the holding it was placed on, never the post-fill holding: a sell with `held >= 0` is a long sell (a flat holding is its own fill) and a buy with `held < 0` is a cover, so a fully filled existing sell keeps today's barrier lookup and a failed lookup still raises `sell SYM uncertain` with no buy POST. |
| Late-close sizing and wait cap | `clear_open` returns `(position, unfilled)`, where `unfilled` is `Some (qty - filled_qty)` summed over the orders it settled on the closing side of the position (`None` when it settled none); `late_exit` sizes `-late` as `min (abs position) unfilled` when a closing order was settled and `abs position` otherwise, and when that quantity is 0 with a nonzero position it posts nothing and keeps the symbol blocked until a read confirms it flat, so a positions read lagging a fill during the settle cannot close twice while a partial cover (3 requested, 2 filled, position -1) still closes the 1 left. Each symbol's wait for its close is capped at `min 3 minutes (left / symbols still to process)` in 15-second polls, where `left` is the cutoff minus the broker clock read for that symbol's window check (one clock read serves both), so every symbol gets its late close submitted before the cutoff. |
| Remainder bound | A remainder after a final exit is `min (abs held) (qty - filled_qty)` of that exit, where `qty` is the requested quantity carried by `listed_t.qty` (new) into `series.qty`; a fully filled exit has bound 0 and posts nothing even when the positions read lags, and a bound check precedes the guard so no listing is made. An entry or orphan exit has no bound (the positions read). |
| Open-order listing exhausted | `Alpaca.open_orders` pages like `list_orders`: `status=open&limit=500&direction=desc&symbols=SYM`, `until` set to the last row's `submitted_at` while a page is full, through a shared `paged_orders`; `clear_open` therefore settles every open order of the symbol. |
| Late-close clock checks | `late_exit` checks the clock (`is_open` and `next_actions = `` `Decide ``) immediately before every `-late` POST and again after a filled close reads a flat position, before releasing the entry; a close found past the window blocks the symbol. The day's `-late` is looked up by client id first: an existing one is followed, never re-posted, and then `clear_open` runs over the symbol's other orders before the entry is released. A symbol whose pass raises (in `late_exit`, the daily-`short` guard, or `overnight_exits`) logs `date=DATE symbol=SYM error=... order=skip` and is blocked; the other symbols continue. |
| Where the exit gate runs | `us_step`'s closed-clock arm runs `overnight_exits` with no deadline on every closed clock read, then sleeps to the open plus 5 minutes. The decision day ends at the close plus 5 minutes (not the next open), so the next clock read is closed and runs the gate the same evening; a restart while closed runs the same arm, which covers "a restart between the entry fill and the exit submission submits the missing exit at once if the session is closed". A final exit with a remainder found while closed is resubmitted there too, since the daemon resumes the series at its next exit point. |
| Where the 09:35 step runs | The pre-decision open phase (`next_actions` returns `` `Sleep_until ``) runs `overnight_exits` with the 09:50 deadline derived from the step clock's date and zone (`session_seconds clock "09:50:00"`), then sleeps to 15:45. The closed arm wakes at the open plus 5 minutes, so the normal path runs it at 09:35; a restart at any later open time runs it at once, and past 09:50 an outstanding exit is settled and resubmitted at once. |
| Finish dispatch and suffixed ids | Exit and late orders never enter `existing`, so `run_us`'s finish dispatch is never asked to resolve a suffixed id and stays as it is; `drive_exit` and `late_exit` follow their own orders and log them with `log_fill`. A `-late` order left outstanding past the submit window is followed and settled by the evening gate (it classifies as `exits = 0`, like an entry). |
| Late exit and the decision | `late_exit` runs before `decide` in the `` `Decide `` arm for every symbol without an existing entry, so `decide` reads the flattened positions; the blocked symbols reach `decide ~frozen` and come back as `Skip "overnight entry skipped"`, which still flows through `execute_decision` and is logged as a skip. A daily `short` file (no `overnight`) runs `clear_open` alone at the same point, so its entry obeys the invariant too. |
| Log lines for the daemon notes | `date=DATE symbol=SYMBOL note=overnight exit unfilled`, `... note=overnight exit outstanding` (new, the settle bound), `... note=overnight position closed late`, `... note=overnight entry skipped`, `... note=overnight position without entry`. Exit submissions log `date=DATE symbol=SYMBOL held=VALUE order=SIDE:QTY:ID fill=pending`; their fills, and every order the guard settles, use `log_fill`. A symbol whose pass raises logs `date=DATE symbol=SYMBOL error=... order=skip` and the other symbols continue. |
| Startup log | `startup mode=%s account=%s equity=%.10g initial-margin=%.10g shorting-enabled=%b`. |
| Test 10 "levered book" | `check [|1.2; 0.|] [|0.8; -0.3|]`: SPY sells 0.4 of a 1.2 margin position, repaying its loan, and the freed cash funds the QQQ short's collateral; both quantities match the engine run (verified offline: SPY sells 4.000258884, QQQ sells 2). The short order quantity is the change from the held whole-share count to the planner's quantized final holding, `Engine.shares_of_value ~capital:1. ~price item.plan_short_final`, exact on a full close; two parity cases at price 100.1 (add 3 to 4, reduce 4 to 2) pin it where dollar values are not share multiples. |
| Task order and the stage 1 guard | The brief orders entry before the exit machinery. Task 3 therefore narrows the stage 1 guard to `overnight is not supported by bt target and bt live yet` (a `short` daily file is complete after Task 3), and Task 4 removes it when the daemon is wired. Each task leaves the suite green. |
| Repeated fill lines | On a later morning or evening with nothing to do, the latest order is a filled exit and the step logs its fill line again; one line per symbol per step is accepted. |

## File map

| File | Responsibility in this plan |
| --- | --- |
| `broker/alpaca.ml`, `broker/alpaca.mli` | `account_t` fields `initial_margin`, `shorting_enabled`; `listed_t`, `asset_t`; `parse_orders`, `parse_asset`, `parse_cancel`; `cancel_order`, `order_by_id`, `open_orders_path`, `open_orders`, `asset`, `orders_path`, `list_orders ?page`. |
| `broker/live.ml`, `broker/live.mli` | Short leg in `us_plan_state`; `us_plan_action ~frozen ~short ~overnight`; `decision_targets ?short_ratio`; `decide ?frozen`; `shortable_ok`; `overnight_broker`, `series`, `settled`, `final_order_status`, `series_of_order`, `exit_id`, `follow`, `settle`, `clear_open`, `drive_exit`, `overnight_exits`, `late_exit`, `session_close_of`, `us_step ?broker ?overnight`, `run_us ~short ~overnight`, exported `rfc3339_seconds`. |
| `bin/bt.ml` | `live_command_args`: the stage 1 guard narrowed (Task 3) then removed (Task 4). |
| `test/test_bt.ml`, `test/fixtures/alpaca/asset.json`, `test/fixtures/alpaca/orders.json` | Tests 9-14 and the Alpaca parser and paging tests. |
| `docs/cli.md`, `docs/specs/live-trading.md`, `CHANGELOG.md` | Docs row, live parts. |

## Tasks

### Task 1: Alpaca additions

**Files:**
- Modify: `broker/alpaca.ml:10-36` (`account_t`, `order_t`), `broker/alpaca.ml:106-121` (`parse_account`), after `parse_order` (`broker/alpaca.ml:154-169`), before `order_by_client_id` (`broker/alpaca.ml:297`)
- Modify: `broker/alpaca.mli:12-41`, `broker/alpaca.mli:61-62`, `broker/alpaca.mli:104-105`
- Create: `test/fixtures/alpaca/asset.json`, `test/fixtures/alpaca/orders.json`
- Test: `test/test_bt.ml:5107-5119` (`test_alpaca_account_parse`), ten `Alpaca.account_t` literals (`test/test_bt.ml:5110-5117, 5338-5341, 5388-5391, 5459-5462, 5514-5517, 5612-5615, 5658-5662, 5714-5717, 5752-5755, 6138-6145`), new tests before `test_alpaca_snapshot_parse` (`test/test_bt.ml:5169`), registration at `test/test_bt.ml:10195-10196`

**Interfaces:**
- Consumes: `Alpaca.request`, `expect_ok`, `jq_fields`, `float_field`, `bool_field`, `url_encode`, `failf` (all existing in `broker/alpaca.ml`).
- Produces: `account_t` fields `initial_margin : float` and `shorting_enabled : bool`; `type listed_t = { client_order_id : string; submitted_at : string; order : order_t }`; `type asset_t = { shortable : bool; easy_to_borrow : bool }`; `val parse_orders : string -> listed_t list`; `val parse_asset : string -> asset_t`; `val parse_cancel : http_code:int -> unit`; `val cancel_order : mode -> string -> unit` (Alpaca order id); `val order_by_id : mode -> string -> order_t option` (Alpaca order id, 404 is `None`); `val open_orders_path : symbol:string -> string`; `val open_orders : mode -> string -> listed_t list`; `val asset : mode -> string -> asset_t`; `val orders_path : symbols:string list -> after:string -> until:string option -> string`; `val list_orders : ?page:(string -> listed_t list) -> mode -> symbols:string list -> after:string -> listed_t list` (pages are newest first; `until` is the exclusive `submitted_at` of the last row).

- [ ] **Step 1: Add the fixtures**

Create `test/fixtures/alpaca/asset.json` (documented asset fields; QQQ is shortable and easy to borrow):

```json
{
  "id": "904837e3-3b76-47ec-b432-046db621571b",
  "class": "us_equity",
  "exchange": "NASDAQ",
  "symbol": "QQQ",
  "name": "Invesco QQQ Trust, Series 1",
  "status": "active",
  "tradable": true,
  "marginable": true,
  "shortable": true,
  "easy_to_borrow": true,
  "fractionable": true,
  "maintenance_margin_requirement": 30
}
```

Create `test/fixtures/alpaca/orders.json` (three documented order rows, newest first: a filled cover, the filled entry it exits, and a canceled order with a null `client_order_id`):

```json
[
  {
    "id": "61e69015-8549-4bfd-b9c3-01e75843f47d",
    "client_order_id": "bt-QQQ-2026-10-09-cover",
    "created_at": "2026-10-09T20:05:12.102Z",
    "updated_at": "2026-10-12T13:30:01.330Z",
    "submitted_at": "2026-10-09T20:05:12.080Z",
    "filled_at": "2026-10-12T13:30:01.300Z",
    "expired_at": null,
    "canceled_at": null,
    "failed_at": null,
    "replaced_at": null,
    "replaced_by": null,
    "replaces": null,
    "asset_id": "904837e3-3b76-47ec-b432-046db621571b",
    "symbol": "QQQ",
    "asset_class": "us_equity",
    "notional": null,
    "qty": "3",
    "filled_qty": "3",
    "filled_avg_price": "601.25",
    "order_class": "",
    "order_type": "market",
    "type": "market",
    "side": "buy",
    "time_in_force": "day",
    "limit_price": null,
    "stop_price": null,
    "status": "filled",
    "extended_hours": false,
    "legs": null,
    "trail_percent": null,
    "trail_price": null,
    "hwm": null
  },
  {
    "id": "0c6c3ed5-9a0b-4f5b-8f1e-5d4d2b1c0a7e",
    "client_order_id": "bt-QQQ-2026-10-09",
    "created_at": "2026-10-09T19:45:40.512Z",
    "updated_at": "2026-10-09T19:45:40.900Z",
    "submitted_at": "2026-10-09T19:45:40.500Z",
    "filled_at": "2026-10-09T19:45:40.880Z",
    "expired_at": null,
    "canceled_at": null,
    "failed_at": null,
    "replaced_at": null,
    "replaced_by": null,
    "replaces": null,
    "asset_id": "904837e3-3b76-47ec-b432-046db621571b",
    "symbol": "QQQ",
    "asset_class": "us_equity",
    "notional": null,
    "qty": "3",
    "filled_qty": "3",
    "filled_avg_price": "600.5",
    "order_class": "",
    "order_type": "market",
    "type": "market",
    "side": "sell",
    "time_in_force": "day",
    "limit_price": null,
    "stop_price": null,
    "status": "filled",
    "extended_hours": false,
    "legs": null,
    "trail_percent": null,
    "trail_price": null,
    "hwm": null
  },
  {
    "id": "7b08df51-c1ac-453c-99f9-323a5f075f0d",
    "client_order_id": null,
    "created_at": "2026-10-08T15:02:10.000Z",
    "updated_at": "2026-10-08T15:02:10.200Z",
    "submitted_at": "2026-10-08T15:02:10.000Z",
    "filled_at": null,
    "expired_at": null,
    "canceled_at": "2026-10-08T15:02:10.200Z",
    "failed_at": null,
    "replaced_at": null,
    "replaced_by": null,
    "replaces": null,
    "asset_id": "904837e3-3b76-47ec-b432-046db621571b",
    "symbol": "QQQ",
    "asset_class": "us_equity",
    "notional": null,
    "qty": "1",
    "filled_qty": "0",
    "filled_avg_price": null,
    "order_class": "",
    "order_type": "limit",
    "type": "limit",
    "side": "buy",
    "time_in_force": "gtc",
    "limit_price": "500",
    "stop_price": null,
    "status": "canceled",
    "extended_hours": false,
    "legs": null,
    "trail_percent": null,
    "trail_price": null,
    "hwm": null
  }
]
```

The `test/dune` stanza already globs `fixtures/alpaca/*.json`, so no dune change is needed.

- [ ] **Step 2: Write the failing tests**

Replace `test_alpaca_account_parse` (`test/test_bt.ml:5107-5119`) with:

```ocaml
let test_alpaca_account_parse () =
  let actual = Alpaca.parse_account (alpaca_fixture "account.json") in
  (* Fixture equity = -23140.2 + 126960.76 + 0. = 103820.56; initial_margin
     and shorting_enabled are copied from the documented account response. *)
  let expected : Alpaca.account_t =
    { equity = 103820.56;
      cash = -23140.2;
      long_market_value = 126960.76;
      short_market_value = 0.;
      initial_margin = 63480.38;
      shorting_enabled = true;
      status = "ACTIVE";
      trading_blocked = false;
      account_number = "010203ABCD" }
  in
  assert (actual = expected)
```

In each of the other nine `Alpaca.account_t` literals in `test/test_bt.ml` (base lines 5338-5341 in `test_us_plan_action_foreign_symbol`, 5388-5391 in `test_us_plan_action_pair_matches_run`, 5459-5462 in `test_us_plan_action_checks`, 5514-5517 in `test_us_plan_action_orders`, 5612-5615 in `test_us_plan_action_matches_run`, 5658-5662 in `test_us_live_fractional`, 5714-5717 in `test_us_live_plan_policy`, 5752-5755 in `test_us_live_quantity_limit`, 6138-6145 in `test_live_startup_guard`), insert the two fields `initial_margin = 0.; shorting_enabled = true;` between the `short_market_value = ...;` field and `status = "ACTIVE";`. For example the literal at 5338-5341 becomes:

```ocaml
  let account : Alpaca.account_t =
    { equity = 1.; cash = -600.; long_market_value = 999.;
      short_market_value = 0.; initial_margin = 0.; shorting_enabled = true;
      status = "ACTIVE"; trading_blocked = false; account_number = "fixture" } in
```

Insert before `let test_alpaca_snapshot_parse () =` (`test/test_bt.ml:5169`):

```ocaml
let test_alpaca_orders_parse () =
  let listed = Alpaca.parse_orders (alpaca_fixture "orders.json") in
  (* The fixture lists three rows newest first: the filled cover, the
     filled entry, and a canceled order with a null client id. *)
  let ids = List.map (fun (item : Alpaca.listed_t) -> item.client_order_id) listed in
  assert (ids = ["bt-QQQ-2026-10-09-cover"; "bt-QQQ-2026-10-09"; "-"]);
  let cover = List.hd listed in
  assert (cover.submitted_at = "2026-10-09T20:05:12.080Z");
  assert (cover.qty = 3.);
  let expected : Alpaca.order_t =
    { id = "61e69015-8549-4bfd-b9c3-01e75843f47d"; status = "filled";
      side = "buy"; filled_avg_price = Some 601.25; filled_qty = 3. }
  in
  assert (cover.order = expected);
  let canceled = List.nth listed 2 in
  assert (canceled.order.filled_avg_price = None && canceled.order.status = "canceled");
  assert (Alpaca.parse_orders "[]" = []);
  assert_failure (fun () -> ignore (Alpaca.parse_orders "{}"));
  assert_failure (fun () ->
    ignore (Alpaca.parse_orders {|[{"client_order_id":"x","submitted_at":"t","id":"i","status":"new","side":"hold","filled_qty":"0"}]|}))

let test_alpaca_asset_parse () =
  (* Both flags are copied from the documented asset response. *)
  assert (Alpaca.parse_asset (alpaca_fixture "asset.json")
    = { Alpaca.shortable = true; easy_to_borrow = true });
  assert (Alpaca.parse_asset {|{"shortable":false,"easy_to_borrow":true}|}
    = { Alpaca.shortable = false; easy_to_borrow = true });
  assert_failure (fun () -> ignore (Alpaca.parse_asset {|{"shortable":"yes"}|}))

let test_alpaca_cancel_and_listing () =
  (* 204 is canceled and 422 is not cancelable; neither is a final state. *)
  let () = Alpaca.parse_cancel ~http_code:204 in
  let () = Alpaca.parse_cancel ~http_code:422 in
  assert_failure (fun () -> Alpaca.parse_cancel ~http_code:500);
  let after = "2026-10-05T20:05:00-04:00" in
  let base =
    "/v2/orders?status=all&limit=500&direction=desc&after=2026-10-05T20%3A05%3A00-04%3A00&symbols=QQQ%2CSPY"
  in
  assert (Alpaca.orders_path ~symbols:["QQQ"; "SPY"] ~after ~until:None = base);
  assert (Alpaca.orders_path ~symbols:["QQQ"; "SPY"] ~after
    ~until:(Some "2026-10-09T20:05:12.080Z")
    = base ^ "&until=2026-10-09T20%3A05%3A12.080Z");
  (* Rows come newest first: row 0 is 09:59 and row 599 is 00:00. *)
  let row index : Alpaca.listed_t =
    { client_order_id = "bt-QQQ-" ^ string_of_int index;
      submitted_at = Printf.sprintf "2026-10-09T%02d:%02d:00Z"
        ((599 - index) / 60) ((599 - index) mod 60);
      qty = 1.;
      order = { id = string_of_int index; status = "filled"; side = "buy";
                filled_avg_price = None; filled_qty = 0. } }
  in
  (* The open listing pages the same way: 500 rows, then the exclusive
     cursor; the fake refuses a path without the 500 limit. *)
  let open_path = "/v2/orders?status=open&limit=500&direction=desc&symbols=QQQ" in
  assert (Alpaca.open_orders_path ~symbol:"QQQ" ~until:None = open_path);
  let open_paths = ref [] in
  let open_page path =
    let () = assert (contains path "limit=500") in
    let () = open_paths := path :: !open_paths in
    if List.length !open_paths = 1 then List.init 500 row else [row 500]
  in
  assert (List.length (Alpaca.open_orders ~page:open_page Alpaca.Paper "QQQ") = 501);
  assert (List.rev !open_paths = [open_path; open_path ^ "&until=2026-10-09T01%3A40%3A00Z"]);
  let paths = ref [] in
  let page path =
    let () = paths := path :: !paths in
    match List.length !paths with
    | 1 -> List.init 500 row
    | 2 -> List.init 2 (fun index -> row (500 + index))
    | _ -> assert false
  in
  let listed = Alpaca.list_orders ~page Alpaca.Paper ~symbols:["QQQ"] ~after in
  (* A full first page continues with until set to its last row's
     submitted_at, row 499 at 01:40:00 (exclusive, so the second page holds
     rows 500 and 501 at 01:39 and 01:38); 502 rows in page order. *)
  assert (List.length listed = 502);
  assert ((List.nth listed 500).Alpaca.client_order_id = "bt-QQQ-500");
  assert ((List.nth listed 500).Alpaca.submitted_at = "2026-10-09T01:39:00Z");
  assert (List.rev !paths
    = [ "/v2/orders?status=all&limit=500&direction=desc&after=2026-10-05T20%3A05%3A00-04%3A00&symbols=QQQ";
        "/v2/orders?status=all&limit=500&direction=desc&after=2026-10-05T20%3A05%3A00-04%3A00&symbols=QQQ&until=2026-10-09T01%3A40%3A00Z" ]);
  (* A short first page is the whole listing. *)
  let single = Alpaca.list_orders ~page:(fun _ -> [row 1]) Alpaca.Paper
    ~symbols:["QQQ"] ~after in
  assert (List.length single = 1)
```

Register them in the `let () =` block: after `  test_alpaca_order_parse ();` (`test/test_bt.ml:10195`) add:

```ocaml
  test_alpaca_orders_parse ();
  test_alpaca_asset_parse ();
  test_alpaca_cancel_and_listing ();
```

- [ ] **Step 3: Run the build to verify it fails**

Run: `dune build --root . 2>&1 | head -20`
Expected: a type error on the `initial_margin` field (unbound record field) in `test/test_bt.ml`.

- [ ] **Step 4: Add the types and fields**

In `broker/alpaca.ml`, replace `type account_t` through the end of `type order_t` (lines 10-36) with:

```ocaml
type account_t = {
  equity : float;
  cash : float;
  long_market_value : float;
  short_market_value : float;
  initial_margin : float;
  shorting_enabled : bool;
  status : string;
  trading_blocked : bool;
  account_number : string;
}

type snapshot_t = {
  day_date : string;
  prev_day_date : string;
  day_open : float;
  day_high : float;
  day_low : float;
  latest : float;
  day_volume : float;
}

type order_t = {
  id : string;
  status : string;
  side : string;
  filled_avg_price : float option;
  filled_qty : float;
}

type listed_t = {
  client_order_id : string;
  submitted_at : string;
  qty : float;
  order : order_t;
}

type asset_t = {
  shortable : bool;
  easy_to_borrow : bool;
}
```

Replace `parse_account` (lines 106-121) with:

```ocaml
let parse_account raw =
  match
    jq_fields "account"
      "[.equity, .cash, .long_market_value, .short_market_value, .initial_margin, (.shorting_enabled | tostring), .status, (.trading_blocked | tostring), .account_number] | @tsv"
      raw
  with
  | [equity; cash; long_market_value; short_market_value; initial_margin;
     shorting_enabled; status; trading_blocked; account_number] ->
      { equity = float_field "account equity" equity;
        cash = float_field "account cash" cash;
        long_market_value = float_field "account long_market_value" long_market_value;
        short_market_value = float_field "account short_market_value" short_market_value;
        initial_margin = float_field "account initial_margin" initial_margin;
        shorting_enabled = bool_field "account shorting_enabled" shorting_enabled;
        status;
        trading_blocked = bool_field "account trading_blocked" trading_blocked;
        account_number }
  | _ -> failwith "invalid Alpaca account response"
```

- [ ] **Step 5: Add the parsers**

Insert after `parse_order` (after line 169, before `let require_env name =`):

```ocaml
let order_of_fields id status side filled_avg_price filled_qty =
  { id;
    status;
    side;
    filled_avg_price =
      (match filled_avg_price with
       | "" -> None
       | value -> Some (float_field "order filled_avg_price" value));
    filled_qty = float_field "order filled_qty" filled_qty }

let parse_orders raw =
  let fields =
    jq_fields "orders"
      {|if type == "array" then [.[] | (.client_order_id // "-"), .submitted_at, (.qty // "0"), .id, .status, (if .side == "buy" or .side == "sell" then .side else error("invalid side") end), (.filled_avg_price // ""), .filled_qty] | @tsv else error("expected orders") end|}
      raw
  in
  let rec collect fields acc =
    match fields with
    | [] | [""] -> List.rev acc
    | client_order_id :: submitted_at :: qty :: id :: status :: side
      :: filled_avg_price :: filled_qty :: rest ->
        collect rest
          ({ client_order_id; submitted_at; qty = float_field "order qty" qty;
             order = order_of_fields id status side filled_avg_price filled_qty }
           :: acc)
    | _ -> failwith "invalid Alpaca orders response"
  in
  collect fields []

let parse_asset raw =
  match
    jq_fields "asset"
      "[(.shortable | tostring), (.easy_to_borrow | tostring)] | @tsv" raw
  with
  | [shortable; easy_to_borrow] ->
      { shortable = bool_field "asset shortable" shortable;
        easy_to_borrow = bool_field "asset easy_to_borrow" easy_to_borrow }
  | _ -> failwith "invalid Alpaca asset response"

let parse_cancel ~http_code =
  match http_code with
  | 204 | 422 -> ()
  | code -> failf "Alpaca order cancel failed with HTTP %d" code
```

`order_of_fields` is `parse_order`'s record construction lifted out so both parsers share it; `parse_order` itself is unchanged. The `// "-"` guards a null `client_order_id` because `jq_fields` trims the output and a leading tab would misalign the row; `"-"` never carries the `bt-` prefix.

- [ ] **Step 6: Add the calls**

Insert before `let order_by_client_id mode client_order_id =` (line 297):

```ocaml
let cancel_order mode id =
  let _, http_code =
    request ~method_:"DELETE" mode ~path:("/v2/orders/" ^ url_encode id)
  in
  parse_cancel ~http_code

let order_by_id mode id =
  let raw, http_code =
    request mode ~path:("/v2/orders/" ^ url_encode id)
  in
  match http_code with
  | 200 -> Some (parse_order raw)
  | 404 -> None
  | code -> failf "Alpaca order lookup failed with HTTP %d" code

let asset mode symbol =
  request mode ~path:("/v2/assets/" ^ url_encode symbol)
  |> expect_ok "asset" parse_asset

let with_until path until =
  match until with
  | None -> path
  | Some value -> path ^ "&until=" ^ url_encode value

let open_orders_path ~symbol ~until =
  with_until
    ("/v2/orders?status=open&limit=500&direction=desc&symbols=" ^ url_encode symbol)
    until

let orders_path ~symbols ~after ~until =
  with_until
    (Printf.sprintf
       "/v2/orders?status=all&limit=500&direction=desc&after=%s&symbols=%s"
       (url_encode after) (url_encode (String.concat "," symbols)))
    until

(* ponytail: a page boundary drops orders that share the last row's
   submitted_at; bt submits seconds apart, so none are lost in practice. *)
let paged_orders ?page mode path_of =
  let page =
    match page with
    | Some page -> page
    | None -> fun path -> request mode ~path |> expect_ok "orders" parse_orders
  in
  let rec pages until acc =
    let rows = page (path_of ~until) in
    let acc = List.rev_append rows acc in
    match List.rev rows with
    | last :: _ when List.length rows = 500 ->
        pages (Some last.submitted_at) acc
    | _ -> List.rev acc
  in
  pages None []

let open_orders ?page mode symbol =
  paged_orders ?page mode (fun ~until -> open_orders_path ~symbol ~until)

let list_orders ?page mode ~symbols ~after =
  paged_orders ?page mode (fun ~until -> orders_path ~symbols ~after ~until)
```

- [ ] **Step 7: Mirror the interface**

In `broker/alpaca.mli`, replace from `(** Alpaca account fields used by live sizing and safety checks. *)` through the closing `}` of `order_t` (lines 12-41) with:

```ocaml
(** Alpaca account fields used by live sizing and safety checks. *)
type account_t = {
  equity : float;
  cash : float;
  long_market_value : float;
  short_market_value : float;
  initial_margin : float;
  shorting_enabled : bool;
  status : string;
  trading_blocked : bool;
  account_number : string;
}

(** Alpaca snapshot fields used to build a provisional daily bar. *)
type snapshot_t = {
  day_date : string;
  prev_day_date : string;
  day_open : float;
  day_high : float;
  day_low : float;
  latest : float;
  day_volume : float;
}

(** Alpaca order fields used for idempotency and fill reporting. *)
type order_t = {
  id : string;
  status : string;
  side : string;
  filled_avg_price : float option;
  filled_qty : float;
}

(** One row of an order listing: the client identifier and submission time
    that anchor an overnight series, with the order fields. *)
type listed_t = {
  client_order_id : string;
  submitted_at : string;
  qty : float;
  order : order_t;
}

(** Alpaca asset flags that gate a short sale. *)
type asset_t = {
  shortable : bool;
  easy_to_borrow : bool;
}
```

Replace `(** Parse an order response. *)` and its `val parse_order` (lines 61-62) with:

```ocaml
(** Parse an order response. *)
val parse_order : string -> order_t

(** Parse an order listing in response order; a null client id reads as
    ["-"]. *)
val parse_orders : string -> listed_t list

(** Parse an asset response. *)
val parse_asset : string -> asset_t

(** Map a cancel response: 204 canceled and 422 not cancelable both succeed,
    since neither proves a final state; any other code fails. *)
val parse_cancel : http_code:int -> unit
```

Replace `(** Find an order by its client-supplied identifier. *)` and its `val order_by_client_id` (lines 104-105) with:

```ocaml
(** Find an order by its client-supplied identifier. *)
val order_by_client_id : mode -> string -> order_t option

(** Request cancellation of an order by its Alpaca id ([DELETE /v2/orders/ID]);
    see [parse_cancel] for the accepted responses. *)
val cancel_order : mode -> string -> unit

(** Find an order by its Alpaca id; 404 is [None]. *)
val order_by_id : mode -> string -> order_t option

(** Build the listing path of one symbol's open orders, whatever their
    client ids: 500 rows, newest first, before the exclusive [until] when
    given. *)
val open_orders_path : symbol:string -> until:string option -> string

(** List every open order of one symbol, newest first, paging with [until]
    set to the last row's [submitted_at] until a page is shorter than 500
    rows. [page] fetches one path and defaults to the trading API. *)
val open_orders : ?page:(string -> listed_t list) -> mode -> string -> listed_t list

(** Fetch the shortability flags of one symbol. *)
val asset : mode -> string -> asset_t

(** Build the listing path: all statuses, 500 rows, newest first, submitted
    after [after] (and before the exclusive [until] when given), on the
    comma-joined [symbols]. *)
val orders_path :
  symbols:string list -> after:string -> until:string option -> string

(** List every order on [symbols] submitted after [after], newest first,
    paging with [until] set to the last row's [submitted_at] until a page is
    shorter than 500 rows. [page] fetches one path and defaults to the
    trading API. *)
val list_orders :
  ?page:(string -> listed_t list) ->
  mode -> symbols:string list -> after:string -> listed_t list
```

- [ ] **Step 8: Build and run the tests**

Run: `dune build --root . 2>&1` then `dune build --root . @runtest --force 2>&1 | tail -3`
Expected: the build prints nothing; the runner's last line is `ok`.

- [ ] **Step 9: Commit**

Commit only after the coordinator confirms; use the co-author trailer the coordinator names; never push; never change git settings.

```bash
git add broker/alpaca.ml broker/alpaca.mli test/test_bt.ml test/fixtures/alpaca/asset.json test/fixtures/alpaca/orders.json
git commit -m "feat: Alpaca order cancel, lookup by id, order listings, asset flags, margin fields"
```

### Task 2: Live account mapping

**Files:**
- Modify: `engine/engine.ml:341-347` (`plan_fills` head), `engine/engine.ml:392-395` (`changed`), `engine/engine.ml:1527-1528` (`run`'s partial application); `engine/engine.mli:197-208` (`val plan_fills`)
- Modify: `broker/live.ml:91-165` (`us_plan_state`, `us_plan_action`), `broker/live.ml:634-645` (`decision_targets`), `broker/live.ml:724-733` and `767-776` (`decide`, its signature and US arm), `broker/live.ml:865` (the TW `Engine.plan_fills` call)
- Modify: `broker/live.mli:85-101` (`us_plan_state`, `us_plan_action` docs and signatures), `broker/live.mli:237-238` (`val decide`)
- Test: nine `Live.us_plan_action` call sites (`test/test_bt.ml:5343, 5352, 5392, 5465, 5520, 5618, 5664, 5719, 5757`), sixteen `Engine.plan_fills` call sites (`test/test_bt.ml:4591, 4616, 4680, 7034, 7095, 7130, 7292, 7321, 7354, 7383, 7398, 7925, 8004, 8070, 8128, 8291` at the base; the first three shift by the Task 1 insertions), new tests before `test_us_live_fractional` (`test/test_bt.ml:5646`), registration after `test_us_plan_action_matches_run ();` (`test/test_bt.ml:10206`)

**Interfaces:**
- Consumes: `Engine.plan_state` short fields, `Engine.planned_asset.plan_short_open`, `plan_short_cover`, `plan_short_final`, `Engine.shares_of_value`, `Engine.effective_targets ?short_ratio`, `Dsl.compile_ast ?short_cap`, `Dsl.short_of`, `Dsl.overnight_of`, `Alpaca.account_t` (Task 1 fields in the tests).
- Produces: `val plan_fills : frozen:bool array -> costs:costs array -> ... -> force:bool -> fill_plan` (a frozen asset is never `plan_changed`; `[||]` freezes nothing); `val us_plan_state` unchanged in signature, now mapping a negative holding into `short_values` and `short_reserved`; `val us_plan_action : frozen:string list -> short:bool -> overnight:bool -> rebalance:bool -> symbols:string array -> date:string -> account:Alpaca.account_t -> position_symbols:string list -> held:float array -> prices:float array -> targets:float array -> previous_targets:float array -> Engine.plan_state * action array` (a frozen symbol is planned at its held exposure and skipped with `overnight entry skipped`); `decision_targets ?short_ratio` (internal); `val decide : ?frozen:string list -> ...` (the rest unchanged), computing `short` and `overnight` from the file. Task 4's `late_exit` relies on `decide` accepting a held short in a `short` file and on `?frozen`.

- [ ] **Step 1: Write the failing tests**

Prefix `~frozen:[] ~short:false ~overnight:false` to every existing `Live.us_plan_action ~rebalance` call (nine sites: `test/test_bt.ml:5343, 5352, 5392, 5465, 5520, 5618, 5664, 5719, 5757`), so for example line 5343 reads `  assert (match Live.us_plan_action ~frozen:[] ~short:false ~overnight:false ~rebalance:false ~symbols:[|"SPY"; "QQQ"|]`.

Insert `~frozen:[||]` after `Engine.plan_fills` at every existing call in `test/test_bt.ml` (sixteen sites, fifteen of the form `Engine.plan_fills ~costs` on one line and one at base line 8004 where `~costs` starts the next line), so for example base line 4591 reads `    Engine.plan_fills ~frozen:[||] ~costs:[| zero_costs; zero_costs |] ~capital:1000000.`.

Insert before `let test_us_live_fractional () =` (`test/test_bt.ml:5646`):

```ocaml
let test_us_short_plan_state () =
  let state = Live.us_plan_state ~cash:1600. ~held:[|-3.; 4.|]
    ~prices:[|100.; 100.|] ~ratio:0.5 ~previous_targets:[|-0.3; 0.4|] in
  (* -3 shares at 100 is a 300 short leg reserving 1.5 * 300 = 450; the
     4 long shares are 400 of cash inventory; equity 1600 + 400 - 300. *)
  assert (state.Engine.short_values = [|300.; 0.|]);
  assert (state.short_reserved = [|450.; 0.|]);
  assert (state.short_borrow = [|0.; 0.|]);
  assert (state.cash_values = [|0.; 400.|]);
  assert (state.margin_values = [|0.; 0.|] && state.loans = [|0.; 0.|]);
  assert (state.cash = 1600. && state.equity = 1700.);
  (* A debit splits over the long values only: cash -100 against 600 of
     SPY funds 200 of margin inventory; equity 0 + 600 - 300 - 100 = 200. *)
  let levered = Live.us_plan_state ~cash:(-100.) ~held:[|-3.; 6.|]
    ~prices:[|100.; 100.|] ~ratio:0.5 ~previous_targets:[|-0.3; 0.6|] in
  assert (levered.loans = [|0.; 100.|]);
  assert (levered.margin_values = [|0.; 200.|]);
  assert (levered.cash_values = [|0.; 400.|]);
  assert (levered.short_values = [|300.; 0.|]);
  assert (levered.equity = 200.)

let test_us_short_plan_checks () =
  let base : Alpaca.account_t =
    { equity = 1.; cash = 1600.; long_market_value = 400.;
      short_market_value = -300.; initial_margin = 0.; shorting_enabled = true;
      status = "ACTIVE"; trading_blocked = false; account_number = "paper-account" }
  in
  let choose ?(short = true) account held =
    Live.us_plan_action ~frozen:[] ~short ~overnight:false ~rebalance:false
      ~symbols:[|"SPY"; "QQQ"|] ~date:"2025-06-24" ~account
      ~position_symbols:["SPY"; "QQQ"] ~held ~prices:[|100.; 100.|]
      ~targets:[|-0.3; 0.4|] ~previous_targets:[|-0.3; 0.4|]
  in
  let fails ?short expected account held =
    assert_failure (fun () ->
      match choose ?short account held with
      | _ -> assert false
      | exception Failure message ->
          assert (message = expected);
          failwith message)
  in
  (* A file without short keeps the old rejection for a held short. *)
  fails ~short:false "US account holds a short position" base [|-3.; 4.|];
  (* With short, a short mark but no short strategy holding is foreign. *)
  fails "US account holds a short outside the strategy" base [|0.; 4.|];
  (* -3 SPY at 100 matches the -300 mark; both targets are unchanged. *)
  let state, actions = choose base [|-3.; 4.|] in
  assert (state.Engine.equity = 1700.);
  assert (actions = [|Live.Skip "target unchanged"; Live.Skip "target unchanged"|]);
  (* The short mark check tolerates 1% of -short_market_value: 298 and 302
     differ from 300 by 2, under 2.98 and 3.02; 295 and 305 differ by 5. *)
  List.iter (fun short_market_value ->
    ignore (choose { base with short_market_value } [|-3.; 4.|]))
    [-298.; -302.];
  List.iter (fun short_market_value ->
    fails "US account holds other symbols" { base with short_market_value } [|-3.; 4.|])
    [-295.; -305.; Float.nan];
  (* The long mark is still checked on its own leg: 403 passes, 410 fails. *)
  ignore (choose { base with long_market_value = 403. } [|-3.; 4.|]);
  fails "US account holds other symbols" { base with long_market_value = 410. } [|-3.; 4.|];
  (* A short-only book has a zero long mark and equity 1600 - 300 = 1300. *)
  let state, _ = choose { base with long_market_value = 0. } [|-3.; 0.|] in
  assert (state.Engine.equity = 1300.)

let test_us_short_plan_parity () =
  let symbols = [|"SPY"; "QQQ"|] in
  let capital = 1000. in
  let profile = Engine.profile_of_market "us" in
  let costs = Array.map (fun symbol -> Engine.default_costs ~market:"us" ~symbol) symbols in
  let margin : Engine.margin =
    { financing_rate = 0.; maintenance_override = None;
      ratios = [|0.5; 0.5|]; loan_term_months = None } in
  let check ?(price = 100.) t0 t1 =
    let bars = [|bar "2025-06-23" price price;
      bar "2025-06-24" price price; bar "2025-06-25" price price|] in
    let result = Engine.run
      (Array.map (fun symbol -> "us/" ^ symbol, bars) symbols)
      { Engine.targets = Array.mapi (fun i first -> [|first; t1.(i); t1.(i)|]) t0 }
      costs ~profile ~margin ~capital ~fill:Engine.Close_same ~rebalance:false in
    let e1 = List.assoc "2025-06-23" result.equity_curve *. capital in
    let e2 = List.assoc "2025-06-24" result.equity_curve *. capital in
    let ordinary = List.filter (fun (f : Engine.fill_event) ->
      f.date = "2025-06-24" && f.from_e <> f.to_e) result.fills in
    (* The signed holding is the bar-1 fill's exposure times E1 over the
       price. Alpaca reports a short as a negative whole-share quantity, so
       the short leg is rounded off the product's last-ulp error. *)
    let held = Array.map (fun symbol ->
      match List.find_opt (fun (f : Engine.fill_event) ->
        f.date = "2025-06-23" && f.stock = "us/" ^ symbol) result.fills with
      | Some fill ->
          let shares = fill.to_e *. e1 /. price in
          if shares < 0. then Float.round shares else shares
      | None -> 0.) symbols in
    let long_value = Array.fold_left (fun sum h -> sum +. Float.max 0. (h *. price)) 0. held in
    let short_value = Array.fold_left (fun sum h -> sum +. Float.min 0. (h *. price)) 0. held in
    let account : Alpaca.account_t =
      { equity = 1.; cash = e1 -. long_value -. short_value;
        long_market_value = long_value; short_market_value = short_value;
        initial_margin = 0.; shorting_enabled = true; status = "ACTIVE";
        trading_blocked = false; account_number = "fixture" } in
    let state, actions = Live.us_plan_action ~frozen:[] ~short:true
      ~overnight:false ~rebalance:false ~symbols ~date:"2025-06-24" ~account
      ~position_symbols:["SPY"; "QQQ"] ~held ~prices:[|price; price|]
      ~targets:t1 ~previous_targets:t0 in
    let () = assert_close ~tolerance:1e-9 e1 state.Engine.equity in
    Array.iteri (fun i action ->
      match List.find_opt (fun (f : Engine.fill_event) ->
        f.stock = "us/" ^ symbols.(i)) ordinary with
      | None -> assert (action = Live.Skip "target unchanged")
      | Some fill ->
          (* Exposure times equity is the signed position value; the delta
             over the price is the signed quantity the engine filled, whole
             shares on the short leg. *)
          let expected = (fill.to_e *. e2 -. fill.from_e *. e1) /. price in
          match action with
          | Live.Order { side; qty; _ } ->
              assert (side = if expected > 0. then `Buy else `Sell);
              assert_close ~tolerance:1.01e-9 (abs_float expected) qty
          | Live.Skip _ | Live.Orders _ -> assert false) actions;
    actions
  in
  (* Open from flat: 0.3 of 1000 less the sell charge is 2.9999 shares,
     so the order is a 2-share sell, never a skip. *)
  let opened = check [|0.; 0.|] [|-0.3; 0.|] in
  assert (opened.(0) = Live.Order { side = `Sell; qty = 2.; id = "bt-SPY-2025-06-24" });
  (* Add 2 to 4 shares, reduce 4 to 1, and cover 2 to zero on a cash book. *)
  assert ((check [|-0.3; 0.|] [|-0.5; 0.|]).(0)
    = Live.Order { side = `Sell; qty = 2.; id = "bt-SPY-2025-06-24" });
  assert ((check [|-0.5; 0.|] [|-0.2; 0.|]).(0)
    = Live.Order { side = `Buy; qty = 3.; id = "bt-SPY-2025-06-24" });
  assert ((check [|-0.3; 0.|] [|0.; 0.|]).(0)
    = Live.Order { side = `Buy; qty = 2.; id = "bt-SPY-2025-06-24" });
  (* A levered book: SPY 1.2 sells to 0.8, repaying its loan, and the freed
     cash funds the QQQ short's collateral. *)
  ignore (check [|1.2; 0.|] [|0.8; -0.3|]);
  (* At 100.1 the dollar values are not share multiples: the order is the
     change from the held count to the planner's floored final holding.
     Add 3 to 4 (0.49 of 999.98 at 100.1 is 4.89 shares, floored to 4);
     reduce 4 to 2 (0.21 of 999.98 is 2.09, floored to 2). *)
  assert ((check ~price:100.1 [|-0.31; 0.|] [|-0.49; 0.|]).(0)
    = Live.Order { side = `Sell; qty = 1.; id = "bt-SPY-2025-06-24" });
  assert ((check ~price:100.1 [|-0.49; 0.|] [|-0.21; 0.|]).(0)
    = Live.Order { side = `Buy; qty = 2.; id = "bt-SPY-2025-06-24" })

let test_us_short_sign_flip () =
  let account ~cash ~held : Alpaca.account_t =
    { equity = 1.; cash;
      long_market_value = Array.fold_left (fun s h -> s +. Float.max 0. (h *. 100.)) 0. held;
      short_market_value = Array.fold_left (fun s h -> s +. Float.min 0. (h *. 100.)) 0. held;
      initial_margin = 0.; shorting_enabled = true; status = "ACTIVE";
      trading_blocked = false; account_number = "paper-account" } in
  let choose ?(overnight = false) ?(frozen = []) ~date ~cash ~held
      ~previous_targets () =
    snd (Live.us_plan_action ~frozen ~short:true ~overnight ~rebalance:false
      ~symbols:[|"SPY"; "QQQ"|] ~date ~account:(account ~cash ~held)
      ~position_symbols:["SPY"; "QQQ"] ~held ~prices:[|100.; 100.|]
      ~targets:[|-0.3; 0.4|] ~previous_targets)
  in
  (* Session 1: SPY flips from 0.5 long to -0.3 short. The planner would
     sell 5 and open the short in one bar; the live order closes the 5
     held shares only. QQQ at 0.4 is unchanged. *)
  let first = choose ~date:"2025-06-24" ~cash:100. ~held:[|5.; 4.|]
    ~previous_targets:[|0.5; 0.4|] () in
  assert (first = [|Live.Order { side = `Sell; qty = 5.; id = "bt-SPY-2025-06-24" };
    Live.Skip "target unchanged"|]);
  (* Session 2: SPY is flat and its target is still -0.3. The flat holding
     has no sign, so the previous target becomes 0 and the leg opens:
     0.3 * (1000 - 0.007 of SEC and TAF sell fees) / 100 = 2.99998 shares,
     floored to 2. QQQ still skips. *)
  let second = choose ~date:"2025-06-25" ~cash:600. ~held:[|0.; 4.|]
    ~previous_targets:[|-0.3; 0.4|] () in
  assert (second = [|Live.Order { side = `Sell; qty = 2.; id = "bt-SPY-2025-06-25" };
    Live.Skip "target unchanged"|]);
  (* Under overnight the flat account keeps the strategy's previous target,
     so an unchanged target skips and the session stays flat. *)
  let flat = choose ~overnight:true ~date:"2025-06-25" ~cash:600. ~held:[|0.; 4.|]
    ~previous_targets:[|-0.3; 0.4|] () in
  assert (flat = [|Live.Skip "target unchanged"; Live.Skip "target unchanged"|]);
  (* A frozen SPY keeps its 5 held shares (target 0.5 of the 1000 equity):
     the joint plan sizes QQQ around it from 6 shares down to 0.4 of E1,
     where E1 is 1000 less the sell charges of about 0.014, so the sell is
     2 shares plus 0.4 * 0.014 / 100, about 2.00006; SPY skips with the
     overnight reason even though its target flipped. *)
  let frozen = choose ~overnight:true ~frozen:["SPY"] ~date:"2025-06-25"
    ~cash:(-100.) ~held:[|5.; 6.|] ~previous_targets:[|0.5; 0.6|] () in
  assert (frozen.(0) = Live.Skip "overnight entry skipped");
  (match frozen.(1) with
   | Live.Order { side = `Sell; qty; id } ->
       assert (id = "bt-QQQ-2025-06-25" && qty > 2. && qty < 2.0001)
   | _ -> assert false)
```

Register them after `  test_us_plan_action_matches_run ();` (`test/test_bt.ml:10206`):

```ocaml
  test_us_short_plan_state ();
  test_us_short_plan_checks ();
  test_us_short_plan_parity ();
  test_us_short_sign_flip ();
```

- [ ] **Step 2: Run the build to verify it fails**

Run: `dune build --root . 2>&1 | head -20`
Expected: `The function applied to this argument has type ... This argument cannot be applied with label ~frozen` at the first `us_plan_action` call.

- [ ] **Step 3: Freeze assets in the planner**

In `engine/engine.ml`, replace the head of `plan_fills` (lines 341-347, from `let plan_fills ~costs ~capital ~profile ~financing_ratios` through `  let asset_count = Array.length state.cash_values in`) with:

```ocaml
let plan_fills ~frozen ~costs ~capital ~profile ~financing_ratios
    ~(state : plan_state) ~prices ~targets ~force =
  let () =
    if not (Float.is_finite capital && capital > 0.) then
      invalid_arg "Engine.plan_fills: capital must be positive and finite"
  in
  let asset_count = Array.length state.cash_values in
  let () =
    if Array.length frozen <> 0 && Array.length frozen <> asset_count then
      invalid_arg "Engine.plan_fills: frozen length mismatch"
  in
  let is_frozen index = Array.length frozen > 0 && frozen.(index) in
```

Replace the `changed` binding in `compute_plan` (lines 392-395) with:

```ocaml
        let changed =
          Array.init asset_count
            (fun index ->
              (not (is_frozen index))
              && (force || eff.(index) <> prev_eff.(index)))
        in
```

In `run` (lines 1527-1528), change `    plan_fills ~costs ~capital ~profile ~financing_ratios:margin.ratios` to `    plan_fills ~frozen:[||] ~costs ~capital ~profile ~financing_ratios:margin.ratios`. In `engine/engine.mli`, replace `(** Return the exact pure per-bar fill plan used by [run]; capital must be` through the end of `val plan_fills` (lines 197-208) with:

```ocaml
(** Return the exact pure per-bar fill plan used by [run]; capital must be
    finite and strictly positive. A [frozen] asset is never [plan_changed],
    whatever its target and [force]: its trade is exactly zero and the other
    assets are sized around its holding. An empty [frozen] freezes nothing;
    otherwise its length must match the assets. *)
val plan_fills :
  frozen:bool array ->
  costs:costs array ->
  capital:float ->
  profile:market_profile ->
  financing_ratios:float array ->
  state:plan_state ->
  prices:float array ->
  targets:float array ->
  force:bool ->
  fill_plan
```

`not false && x` is `x`, so with `[||]` every `changed` value and every float operation is what it was; the six byte gates stay identical (verified offline).

- [ ] **Step 4: Map the short leg and net the short fields**

Replace `us_plan_state` and `us_plan_action` (`broker/live.ml:91-165`, from `let us_plan_state ~cash ~held ~prices ~ratio ~previous_targets =` through `    state, actions`) with:

```ocaml
let us_plan_state ~cash ~held ~prices ~ratio ~previous_targets =
  let count = Array.length held in
  let () = if Array.length prices <> count || Array.length previous_targets <> count then
    invalid_arg "US plan arrays differ in length" in
  let () = if not (Float.is_finite ratio) || ratio <= 0. then
    failwith "US financing ratio is not positive" in
  let values = Array.mapi (fun i shares -> Float.max 0. (shares *. prices.(i))) held in
  (* A negative Alpaca quantity is the short leg: its value is the proceeds
     and the reserve holds them plus the Reg T collateral. *)
  let short_values = Array.mapi (fun i shares ->
    Float.max 0. (-. shares *. prices.(i))) held in
  let short_ratio = (Engine.profile_of_market "us").short_initial_ratio in
  let total = Array.fold_left ( +. ) 0. values in
  let short_total = Array.fold_left ( +. ) 0. short_values in
  let debit = Float.max 0. (-. cash) in
  let loans = Array.map (fun value ->
    if total = 0. then debit /. float_of_int count
    else debit *. (value /. total)) values in
  let margin_values = Array.mapi (fun i value ->
    Float.min value (loans.(i) /. ratio)) values in
  let cash = Float.max cash 0. in
  { Engine.equity = cash +. total -. short_total -. debit; cash;
    cash_values = Array.mapi (fun i value -> value -. margin_values.(i)) values;
    margin_values; loans; interests = Array.make count 0.;
    tail_interests = Array.make count 0.; debt = 0.; receivables = 0.;
    previous_targets; short_values;
    short_reserved = Array.map (fun value -> (1. +. short_ratio) *. value) short_values;
    short_borrow = Array.make count 0. }

let us_plan_action ~frozen ~short ~overnight ~rebalance ~symbols ~date
    ~(account : Alpaca.account_t) ~position_symbols ~held ~prices ~targets
    ~previous_targets =
  let count = Array.length symbols in
  let () = if Array.length held <> count || Array.length prices <> count
    || Array.length targets <> count || Array.length previous_targets <> count then
    invalid_arg "US plan arrays differ in length" in
  let profile = Engine.profile_of_market "us" in
  let ratio = profile.default_financing_ratio in
  let state = us_plan_state ~cash:account.cash ~held ~prices ~ratio ~previous_targets in
  let rec leg_values index long short =
    if index = Array.length held then long, short
    else
      let value = held.(index) *. prices.(index) in
      if value < 0. then leg_values (index + 1) long (short -. value)
      else leg_values (index + 1) (long +. value) short in
  let long_value, short_value = leg_values 0 0. 0. in
  let () = if not (Float.is_finite account.cash) then
    failwith "US account cash is not finite" in
  let held_short = Array.exists (fun h -> h < 0.) held in
  let () = if short then
      (if account.short_market_value <> 0. && not held_short then
        failwith "US account holds a short outside the strategy")
    else if account.short_market_value <> 0. || held_short then
      failwith "US account holds a short position" in
  let () = List.iter (fun symbol ->
    if not (Array.exists (( = ) symbol) symbols) then
      failwith ("US account holds unsupported symbol " ^ symbol)) position_symbols in
  let () =
    (* ponytail: 1% tolerance for broker marks versus provisional prices;
       retain alongside the positions-list check for valuation consistency. *)
    if not (Float.is_finite account.long_market_value)
      || abs_float (account.long_market_value -. long_value) > 0.01 *. account.long_market_value
    then failwith "US account holds other symbols" in
  let () =
    (* Alpaca marks the short leg as a negative number. *)
    if not (Float.is_finite account.short_market_value)
      || abs_float (-. account.short_market_value -. short_value)
         > 0.01 *. (-. account.short_market_value)
    then failwith "US account holds other symbols" in
  let () = if not (Float.is_finite state.equity) || state.equity <= 0. then
    failwith "US account equity is not positive" in
  let exposure i = held.(i) *. prices.(i) /. state.equity in
  (* A frozen symbol keeps its holding: the joint plan sizes the others
     around it and its own action is a skip. *)
  let is_frozen i = List.mem symbols.(i) frozen in
  let targets = Array.mapi (fun i target ->
    if is_frozen i then exposure i else target) targets in
  let previous_targets = Array.mapi (fun i previous ->
    if is_frozen i then exposure i else previous) previous_targets in
  (* A carried short never flips in one session: the held sign replaces a
     previous target of the other sign, so the deferred leg opens under
     on_change at the next decision and nothing else changes. *)
  let previous_targets =
    if short && not overnight then
      Array.mapi (fun i previous ->
        if compare (exposure i) 0. <> compare targets.(i) 0. then exposure i else previous)
        previous_targets
    else previous_targets in
  let state = { state with previous_targets } in
  if not rebalance && targets = previous_targets then
    state, Array.make (Array.length symbols) (Skip "target unchanged")
  else
    let plan = Engine.plan_fills ~frozen:(Array.mapi (fun i _ -> is_frozen i) symbols)
      ~costs:(Array.map (fun symbol -> Engine.default_costs ~market:"us" ~symbol) symbols)
      ~capital:1. ~profile ~financing_ratios:(Array.make (Array.length symbols) ratio)
      ~state ~prices ~targets ~force:rebalance in
    let actions = Array.mapi (fun i (item : Engine.planned_asset) ->
      if is_frozen i then Skip "overnight entry skipped"
      else if not rebalance && targets.(i) = previous_targets.(i) then Skip "target unchanged"
      else
        let net = item.plan_buy_cash +. item.plan_buy_margin +. item.plan_short_cover
          -. item.plan_sell_cash -. item.plan_sell_margin -. item.plan_short_open in
        if net = 0. then Skip "no trade planned"
        else
          let price = prices.(i) in
          (* A sign flip closes the old leg only. The short leg is whole
             shares: the order is the change from the held count to the
             planner's quantized final holding, exact on a full cover. *)
          let short_shares =
            Engine.shares_of_value ~capital:1. ~price item.plan_short_final in
          let side, shares =
            if net > 0. then
              `Buy, (if held.(i) < 0. then -. held.(i) -. short_shares
               else net /. price)
            else
              `Sell, (if held.(i) > 0. then
                (if item.plan_final_value = 0. then held.(i)
                 else Float.min (-. net /. price) held.(i))
               else short_shares +. held.(i)) in
          let qty = float_of_string (Alpaca.qty_string shares) in
          if qty = 0. || (side = `Buy && qty *. price < 1.) then
            Skip "below $1 minimum order value"
          else Order { side; qty; id = client_order_id ~symbol:symbols.(i) ~date })
      plan.planned_assets in
    state, actions
```

Long-only identity: `Float.max 0. (shares *. prices.(i))` returns the product unchanged for a nonnegative product (and `+0.` for `-0.`, which `Marshal` in `test_us_plan_state_split` pins), `short_total` is `0.` so `cash +. total -. 0. -. debit` equals the old `cash +. total -. debit` exactly, `leg_values` adds the same products in the same order, the short mark check compares `0.` against `-0.`, and the quantity rule falls through to the old expressions when `held.(i) >= 0.`.

In the TW arm of `decide` (`broker/live.ml:865`), change `      let plan = Engine.plan_fills ~costs:(Array.map tw_live_debit_costs symbols)` to `      let plan = Engine.plan_fills ~frozen:[||] ~costs:(Array.map tw_live_debit_costs symbols)`.

- [ ] **Step 5: Pass the short cap and ratio into the decision**

Replace `decision_targets` (`broker/live.ml:634-645`) with:

```ocaml
let decision_targets ?short_ratio ast stocks arrays provisional ratios =
  let index = ref 0 in
  let assets = List.map2 (fun (alias, _, _) bars ->
    let provisional_bar = provisional.(!index) in
    let () = incr index in
    alias, Array.append bars [|provisional_bar|]) stocks arrays in
  let short_cap = Option.map (fun ratio -> 1. /. ratio) short_ratio in
  let strategy = Dsl.compile_ast ?short_cap ast ~params:[] ~assets in
  let length = Array.length strategy.Engine.targets.(0) in
  let row i = Array.map (fun targets -> targets.(i)) strategy.targets in
  let effective i =
    fst (Engine.effective_targets ?short_ratio ~financing_ratios:ratios (row i)) in
  effective (length - 1),
  (if length = 1 then Array.make (List.length stocks) 0. else effective (length - 2))
```

In `decide` (`broker/live.ml:724-733`), change its first line from `let decide ?provisional_close ?previous_session ?equity ?tw_balance` to `let decide ?(frozen = []) ?provisional_close ?previous_session ?equity ?tw_balance`, and after `  let rebalance = Option.value (Dsl.rebalance_of ~filename:strat_path ast) ~default:false in` insert:

```ocaml
  let short = Dsl.short_of ~filename:strat_path ast in
  let overnight = Dsl.overnight_of ~filename:strat_path ast in
```

In the `"us"` arm, replace lines 767-776 (from `      let ratios = Array.make (Array.length symbols)` through `        ~account ~position_symbols ~held ~prices ~targets ~previous_targets in`) with:

```ocaml
      let profile = Engine.profile_of_market "us" in
      let ratios = Array.make (Array.length symbols) profile.default_financing_ratio in
      let short_ratio = if short then Some profile.short_initial_ratio else None in
      let targets, previous_targets =
        decision_targets ?short_ratio ast stocks arrays provisional ratios in
      let account = Alpaca.account mode in
      let held = Array.map (Alpaca.position_qty mode) symbols in
      let position_symbols = Alpaca.positions mode in
      let prices = Array.map (fun (b : Data.bar) -> b.c) provisional in
      let state, actions = us_plan_action ~frozen ~short ~overnight ~rebalance
        ~symbols ~date:session_date ~account ~position_symbols ~held ~prices
        ~targets ~previous_targets in
```

The TW arm is untouched: it calls `decision_targets ast stocks arrays provisional ratios` without `?short_ratio`, which keeps the zero floor and the clamp, and ignores `frozen` (TW has no overnight machinery).

In `broker/live.mli`, insert `  ?frozen:string list ->` after `val decide :` (line 237), before `  ?provisional_close:float ->`.

- [ ] **Step 6: Mirror the interface**

In `broker/live.mli`, replace from `(** Map Alpaca signed cash and holdings at provisional prices to engine` through the end of `val us_plan_action` (lines 85-101, ending `  Engine.plan_state * action array`) with:

```ocaml
(** Map Alpaca signed cash and holdings at provisional prices to engine
    margin lots with value-proportional debit; unposted interest stays zero.
    A negative holding is a short leg valued at its price, reserving
    [(1 + short_initial_ratio)] times that value of the cash it raised.
    Raise [Failure] if [ratio] is non-finite or not positive.
    Raise [Invalid_argument] if the input arrays differ in length. *)
val us_plan_state :
  cash:float -> held:float array -> prices:float array -> ratio:float ->
  previous_targets:float array -> Engine.plan_state

(** Fail closed on unsupported US account states, then jointly plan Alpaca
    orders or skips without broker I/O; return the state used for the decision.
    [short] allows held and planned shorts (whole-share sells) and checks the
    long and short marks separately; with [short] and not [overnight], a held
    exposure whose sign differs from the target replaces that asset's previous
    target so the deferred leg of a sign flip opens under on_change. A
    [frozen] symbol is planned at its held exposure and skipped with
    [overnight entry skipped], so the joint plan sizes the others around it.
    Raise [Invalid_argument] if the input arrays differ in length. *)
val us_plan_action :
  frozen:string list ->
  short:bool -> overnight:bool ->
  rebalance:bool -> symbols:string array -> date:string ->
  account:Alpaca.account_t -> position_symbols:string list ->
  held:float array -> prices:float array ->
  targets:float array -> previous_targets:float array ->
  Engine.plan_state * action array
```

- [ ] **Step 7: Build and run the tests**

Run: `dune build --root . 2>&1` then `dune build --root . @runtest --force 2>&1 | tail -3`
Expected: the build prints nothing; the runner's last line is `ok`. `test_us_plan_state_split`'s Marshal comparison and `test_us_plan_action_checks` pin the long-only path; the coordinator reruns the six byte gates after this task.

- [ ] **Step 8: Commit**

Commit only after the coordinator confirms; use the co-author trailer the coordinator names; never push; never change git settings.

```bash
git add engine/engine.ml engine/engine.mli broker/live.ml broker/live.mli test/test_bt.ml
git commit -m "feat: map Alpaca shorts into the US live planner and freeze blocked assets"
```

### Task 3: Live entry

**Files:**
- Modify: `broker/live.ml:373-377` (after `startup_ok`), `broker/live.ml:997-1107` (`execute_decision`), `broker/live.ml:1165-1174` (`run_us` head), `broker/live.ml:1784-1799` (`run`)
- Modify: `broker/live.mli:180-185` (`execute_decision` comment), after `val startup_ok` (line 211)
- Modify: `bin/bt.ml:789-800` (`live_command_args` guard)
- Test: `test/test_bt.ml:6136-6153` (`test_live_startup_guard`), `test/test_bt.ml:6486-6496` (the stage 1 block of `test_short_cli_errors`), new `test_us_closes_before_opens` before `test_tw_session_existing_second_code` (`test/test_bt.ml:10119`), registration after `  let () = test_us_open_sell_restart_end_to_end () in` (`test/test_bt.ml:10427`)

**Interfaces:**
- Consumes: `Alpaca.asset`, `Alpaca.asset_t`, `account_t.initial_margin`, `account_t.shorting_enabled` (Task 1); `Dsl.short_of`.
- Produces: `val shortable_ok : string -> Alpaca.asset_t -> (unit, string) result`; `execute_decision` unchanged in signature, now posting closes (long sells, covers) before opens (long buys, short sells) with side-named stop messages; `run_us ... ~short` (internal); the startup line `startup mode=%s account=%s equity=%.10g initial-margin=%.10g shorting-enabled=%b`; `bt target` and `bt live` accept US `short` files; US `overnight` files still stop with `overnight is not supported by bt target and bt live yet` until Task 4.

- [ ] **Step 1: Write the failing tests**

Replace `test_live_startup_guard` (`test/test_bt.ml:6136-6153`) with:

```ocaml
let test_live_startup_guard () =
  (* No position and no debit imply equity = cash = 10000. *)
  let account : Alpaca.account_t =
    { equity = 10000.;
      cash = 10000.;
      long_market_value = 0.;
      short_market_value = 0.;
      initial_margin = 0.;
      shorting_enabled = true;
      status = "ACTIVE";
      trading_blocked = false;
      account_number = "paper-account" }
  in
  assert (Live.startup_ok account = Ok ());
  assert
    (Live.startup_ok { account with status = "ACCOUNT_CLOSED" }
     = Error "account status is ACCOUNT_CLOSED");
  assert
    (Live.startup_ok { account with trading_blocked = true }
     = Error "account trading is blocked");
  (* A short file fails closed unless both asset flags are true. *)
  let asset : Alpaca.asset_t = { shortable = true; easy_to_borrow = true } in
  assert (Live.shortable_ok "QQQ" asset = Ok ());
  assert
    (Live.shortable_ok "QQQ" { asset with shortable = false }
     = Error "QQQ is not shortable");
  assert
    (Live.shortable_ok "QQQ" { asset with easy_to_borrow = false }
     = Error "QQQ is not easy to borrow")
```

In `test_short_cli_errors`, replace the stage 1 block (`test/test_bt.ml:6486-6496`, from `  (* Stage 1 stops US declarations before a target or live broker call. *)` through `    ["target"; "live"]`) with:

```ocaml
  (* The overnight daemon is not wired yet: a US overnight file stops before
     a target or live broker call. *)
  List.iter
    (fun command ->
      invoke "stock \"us/SPY\"\novernight\ntarget 1\n" command []
        (fun _ -> "overnight is not supported by bt target and bt live yet"))
    ["target"; "live"]
```

Insert before `let test_tw_session_existing_second_code () =` (`test/test_bt.ml:10119`):

```ocaml
let test_us_closes_before_opens () =
  (* Cash 3000 with QQQ short 20 at 100: equity 1000. The decision covers
     QQQ and opens SPY short; the cover frees the buying power the opening
     sell consumes, so it posts first and the sell waits for its fill. *)
  let date = "2025-06-24" and close = "2025-06-24T16:00:00-04:00" in
  let decision : Live.decision =
    { fetched_through = "2025-06-23"; equity = 1000.; cash = 3000.; debit = 0.;
      legs = []; assets =
        [|{ Live.symbol = "SPY"; provisional = bar date 100. 100.; target = -0.2; held = 0.;
            action = Live.Order { side = `Sell; qty = 1.; id = "bt-SPY-2025-06-24" } };
          { Live.symbol = "QQQ"; provisional = bar date 100. 100.; target = 0.; held = -20.;
            action = Live.Order { side = `Buy; qty = 20.; id = "bt-QQQ-2025-06-24" } }|] }
  in
  let run cover_status =
    let events = ref [] in
    let record x = events := x :: !events in
    let output = capture_stdout (fun () ->
      Live.execute_decision ~sleep:(fun _ -> record "sleep")
        ~finish:(fun _ _ symbol _ -> record ("finish:" ^ symbol))
        ~clock:(fun _ -> { Alpaca.timestamp = date ^ "T15:45:00-04:00"; is_open = true;
          next_open = "2025-06-25T09:30:00-04:00"; next_close = close })
        ~order_by_client_id:(fun _ id ->
          if id = "bt-QQQ-2025-06-24" && List.mem "post:QQQ" !events then
            let () = record ("poll:" ^ cover_status) in
            Some (us_fixture_order "QQQ" "buy" cover_status)
          else None)
        ~submit_market:(fun _ ~symbol ~qty:_ ~side ~client_order_id:_ ->
          let () = record ("post:" ^ symbol) in
          us_fixture_order symbol (if side = `Sell then "sell" else "buy")
            (if symbol = "QQQ" then cover_status else "filled"))
        Live.Paper date close decision) in
    List.rev !events, output
  in
  let events, _ = run "filled" in
  assert (events = ["post:QQQ"; "poll:filled"; "post:SPY"; "finish:QQQ"; "finish:SPY"]);
  (* A rejected cover stops the session before the opening sell. *)
  let events, output = run "rejected" in
  assert (not (List.mem "post:SPY" events));
  assert (contains output "buy QQQ rejected");
  (* A sell of a long and a buy of a long keep today's order: sell first. *)
  let longs = { decision with assets =
    [|{ decision.assets.(0) with held = 5.;
        action = Live.Order { side = `Sell; qty = 1.; id = "bt-SPY-2025-06-24" } };
      { decision.assets.(1) with held = 2.;
        action = Live.Order { side = `Buy; qty = 1.; id = "bt-QQQ-2025-06-24" } }|] } in
  let events = ref [] in
  let () = capture_stdout (fun () ->
    Live.execute_decision ~finish:(fun _ _ _ _ -> ())
      ~clock:(fun _ -> { Alpaca.timestamp = date ^ "T15:45:00-04:00"; is_open = true;
        next_open = "2025-06-25T09:30:00-04:00"; next_close = close })
      ~order_by_client_id:(fun _ id ->
        if id = "bt-SPY-2025-06-24" && !events <> [] then
          Some (us_fixture_order "SPY" "sell" "filled") else None)
      ~submit_market:(fun _ ~symbol ~qty:_ ~side ~client_order_id:_ ->
        let () = events := symbol :: !events in
        us_fixture_order symbol (if side = `Sell then "sell" else "buy") "filled")
      Live.Paper date close longs) |> ignore in
  assert (List.rev !events = ["SPY"; "QQQ"]);
  (* Restart after the SPY sell fully filled: held reads 0, so the existing
     sell is still a close and keeps its barrier lookup before the QQQ buy;
     a failed lookup escapes to the retry with no buy POST. *)
  let after_sale = { decision with assets =
    [|{ decision.assets.(0) with held = 0.; action = Live.Skip "existing order" };
      { decision.assets.(1) with held = 2.;
        action = Live.Order { side = `Buy; qty = 1.; id = "bt-QQQ-2025-06-24" } }|] } in
  let run lookup =
    let events = ref [] in
    let outcome = capture_stdout (fun () ->
      match Live.execute_decision ~existing:["SPY", us_fixture_order "SPY" "sell" "accepted"]
        ~finish:(fun _ _ symbol _ -> events := ("finish:" ^ symbol) :: !events)
        ~clock:(fun _ -> { Alpaca.timestamp = date ^ "T15:45:00-04:00"; is_open = true;
          next_open = "2025-06-25T09:30:00-04:00"; next_close = close })
        ~order_by_client_id:(fun _ id ->
          let () = events := ("lookup:" ^ id) :: !events in
          if id = "bt-SPY-2025-06-24" then lookup () else None)
        ~submit_market:(fun _ ~symbol ~qty:_ ~side:_ ~client_order_id:_ ->
          let () = events := ("post:" ^ symbol) :: !events in
          us_fixture_order symbol "buy" "filled")
        Live.Paper date close after_sale with
      | () -> events := "returned" :: !events
      | exception Failure message -> events := ("raised:" ^ message) :: !events) in
    ignore outcome;
    List.rev !events
  in
  assert (run (fun () -> Some (us_fixture_order "SPY" "sell" "filled"))
    = ["lookup:bt-QQQ-2025-06-24"; "lookup:bt-SPY-2025-06-24"; "post:QQQ";
       "finish:SPY"; "finish:QQQ"; "returned"]);
  assert (run (fun () -> failwith "lookup unavailable")
    = ["lookup:bt-QQQ-2025-06-24"; "lookup:bt-SPY-2025-06-24"; "raised:sell SPY uncertain"])
```

Register it after `  let () = test_us_open_sell_restart_end_to_end () in` (`test/test_bt.ml:10427`): `  let () = test_us_closes_before_opens () in`. The last case restarts after SPY's sell fully filled (held 0): the existing sell is still a close, its barrier lookup runs before the QQQ buy, and a failed lookup raises `sell SPY uncertain` with no buy POST.

- [ ] **Step 2: Run the build to verify it fails**

Run: `dune build --root . 2>&1 | head -20`
Expected: `Unbound value Live.shortable_ok`.

- [ ] **Step 3: Add the asset gate and the startup fields**

In `broker/live.ml`, insert after `startup_ok` (after line 377):

```ocaml
let shortable_ok symbol (asset : Alpaca.asset_t) =
  match asset.shortable, asset.easy_to_borrow with
  | true, true -> Ok ()
  | false, _ -> Error (symbol ^ " is not shortable")
  | true, false -> Error (symbol ^ " is not easy to borrow")
```

Replace the head of `run_us` (lines 1165-1174, from `let run_us mode ~symbols ~strat_path ~data_dir ~rebalance_choice =` through `  let () = log_rebalance_warning strat_path rebalance_choice in`) with:

```ocaml
let run_us mode ~symbols ~strat_path ~data_dir ~rebalance_choice ~short =
  let account = Alpaca.account mode in
  let () =
    match startup_ok account with
    | Ok () -> ()
    | Error reason -> failwith reason
  in
  log "startup mode=%s account=%s equity=%.10g initial-margin=%.10g shorting-enabled=%b"
    (mode_name mode) account.account_number account.equity
    account.initial_margin account.shorting_enabled;
  let () = log_rebalance_warning strat_path rebalance_choice in
  let () = if short then Array.iter (fun symbol ->
    match shortable_ok symbol (Alpaca.asset mode symbol) with
    | Ok () -> ()
    | Error reason -> failwith reason) symbols in
```

In `run` (line 1786), after `  let rebalance_choice = Dsl.rebalance_of ~filename:strat_path ast in` insert `  let short = Dsl.short_of ~filename:strat_path ast in`, and change the `"us"` arm's call (line 1799) to `        (fun () -> run_us mode ~symbols ~strat_path ~data_dir ~rebalance_choice ~short)`.

In `broker/live.mli`, insert after `val startup_ok : Alpaca.account_t -> (unit, string) result` (line 211):

```ocaml
(** Reject a symbol a [short] file may sell short unless Alpaca flags it
    shortable and easy to borrow. *)
val shortable_ok : string -> Alpaca.asset_t -> (unit, string) result
```

- [ ] **Step 4: Post closes before opens**

Replace `execute_decision` (`broker/live.ml:997-1107`, from `let execute_decision ?(existing = []) ?(sleep = Unix.sleepf) ?finish` through `  | exception error -> raise error`) with:

```ocaml
let execute_decision ?(existing = []) ?(sleep = Unix.sleepf) ?finish
    ?(order_by_client_id = Alpaca.order_by_client_id)
    ?(clock = Alpaca.clock) ?(submit_market = Alpaca.submit_market)
    mode date next_close (decision : decision) =
  let finish = match finish with
    | Some finish -> finish
    | None -> fun next_close date symbol order ->
        finish_order mode next_close date symbol (client_order_id ~symbol ~date) order in
  let error_text = function
    | Failure message -> message
    | error -> Printexc.to_string error in
  let posted = ref false in
  let stopped = ref false in
  let placed = ref existing in
  let finish_all () = List.iter (fun (symbol, order) ->
    try finish next_close date symbol order with error ->
      (try log "date=%s symbol=%s error=%s order=skip"
        date symbol (Printexc.to_string error) with _ -> ())) (List.rev !placed) in
  let orders = Array.to_list decision.assets
    |> List.filter (fun (a : asset_decision) ->
      not (List.mem_assoc a.symbol existing))
    |> List.filter_map (fun (a : asset_decision) -> match a.action with
      | Order { side; qty; id } -> Some (a.symbol, side, qty, id)
      | Skip _ -> None
      | Orders _ -> failwith "TW order legs require Shioaji") in
  (* An order that reduces the symbol's exposure (a long sell, a buy to
     cover) frees buying power and goes first; one that increases it (a long
     buy, a short sell) waits for every close to fill. *)
  let held symbol =
    match Array.find_opt (fun (a : asset_decision) -> a.symbol = symbol) decision.assets with
    | Some asset -> asset.held
    | None -> 0. in
  let closing symbol side =
    match side with `Sell -> held symbol > 0. | `Buy -> held symbol < 0. in
  (* An existing order is classified by its side against the sign of the
     holding it was placed on, never the post-fill holding: a sell with a
     holding at or above zero is a long sell (a flat holding is its fill), a
     buy with a holding below zero is a cover. *)
  let order_closing symbol (order : Alpaca.order_t) =
    if order.side = "sell" then held symbol >= 0. else held symbol < 0. in
  let side_name = function `Sell -> "sell" | `Buy -> "buy" in
  let execute () =
    (* Complete every dedupe lookup before logging or submitting. *)
    let pending = List.filter (fun (symbol, _, _, id) ->
      match order_by_client_id mode id with
      | None -> true
      | Some order ->
          let () = placed := (symbol, order) :: !placed in
          let () = log "date=%s symbol=%s order=existing:%s fill=pending" date symbol id in
          false) orders in
    let preflight () =
      let c = clock mode in
      if not c.is_open || next_actions ~now:c.timestamp ~next_close <> `Decide
      then failwith "submit cutoff passed" in
    let restarting_close = List.exists
      (fun (symbol, order) -> order_closing symbol order) !placed in
    let pending_close = List.exists (fun (symbol, side, _, _) -> closing symbol side) pending in
    let () = if pending <> [] && (not restarting_close || pending_close) then preflight () in
    let () = log_decision date decision in
    let submit (symbol, side, qty, id) =
      let () = preflight () in
      let () = posted := true in
      match submit_market mode ~symbol ~qty ~side ~client_order_id:id with
      | order ->
          let () = placed := (symbol, order) :: !placed in
          if order.status = "rejected" then
            failwith (if closing symbol side then side_name side ^ " " ^ symbol ^ " rejected"
              else "Alpaca rejected the order")
      | exception error ->
          failwith (if closing symbol side then side_name side ^ " " ^ symbol ^ " uncertain"
            else "order submission uncertain: " ^ Printexc.to_string error) in
    let close_failure = ref None in
    let submit_checked ((symbol, side, _, _) as request) =
      match submit request with
      | () -> ()
      | exception error ->
          if not !posted then raise error
          else
            let () = (try log "date=%s symbol=%s error=%s order=skip"
              date symbol (error_text error) with _ -> ()) in
            if closing symbol side && !close_failure = None then
              close_failure := Some error in
    let closes, opens = List.partition (fun (symbol, side, _, _) -> closing symbol side) pending in
    let has_close = closes <> [] || List.exists
      (fun (symbol, order) -> order_closing symbol order) !placed in
    let () = List.iter submit_checked closes in
    let () = match !close_failure with
      | None -> ()
      | Some error -> raise error in
    if not has_close || opens = [] then List.iter submit_checked opens
    else
      let rec wait_closes () =
        let stop = ref None in
        let open_close = ref None in
        let () = placed := List.map (fun (symbol, (order : Alpaca.order_t)) ->
          if not (order_closing symbol order) then symbol, order
          else
            let current =
              match order_by_client_id mode (client_order_id ~symbol ~date) with
              | None -> order
              | Some current -> current
              | exception _ -> failwith (order.side ^ " " ^ symbol ^ " uncertain") in
            let () = if current.status <> "filled" then
              if terminal_order_status current.status then
                (if !stop = None then
                  stop := Some (order.side ^ " " ^ symbol ^ " " ^ current.status))
              else if !open_close = None then open_close := Some (order.side, symbol) in
            symbol, current) !placed in
        match !stop, !open_close with
        | Some reason, _ -> let () = stopped := true in failwith reason
        | None, None -> ()
        | None, Some (side, symbol) ->
            let c = clock mode in
            if not c.is_open || next_actions ~now:c.timestamp ~next_close <> `Decide then
              let () = stopped := true in
              failwith (side ^ " " ^ symbol ^ " open at cutoff")
            else let () = sleep 15. in wait_closes () in
      let () = wait_closes () in
      List.iter submit_checked opens in
  match execute () with
  | () -> (try finish_all () with _ -> ())
  | exception error when !posted || !stopped ->
      let () = (try log "date=%s error=%s order=skip" date (error_text error) with _ -> ()) in
      (try finish_all () with _ -> ())
  | exception Failure message when message = "submit cutoff passed" ->
      let () = (try log "date=%s error=submit cutoff passed order=skip" date with _ -> ()) in
      (try finish_all () with _ -> ())
  | exception error -> raise error
```

Only the classification changed: `closing symbol side` replaces `side = `` `Sell``, `order_closing` replaces `o.side = "sell"`, and the stop messages take the order's side. With no short held, `closing` is `side = `` `Sell`` for every asset, so `test_us_pair_execution`, `test_us_open_sell_restart_end_to_end`, and the other sell-barrier tests pass unchanged.

In `broker/live.mli`, replace the comment above `val execute_decision` (lines 180-185, from `(** Log a US decision after its pre-submit checks succeed. Submit an order` through `    [Alpaca]. *)`) with:

```ocaml
(** Log a US decision after its pre-submit checks succeed. Submit an order
    only while the market is open and before the cutoff 2 minutes before
    [next_close]. Orders that reduce a symbol's exposure (a long sell, a buy
    to cover, judged from the decision's held quantity) go first; orders that
    increase it (a long buy, a short sell) go out only after every close is
    [filled]. A failed or rejected order request is logged with [order=skip]
    and is not retried; after the cutoff, log
    [error=submit cutoff passed order=skip]. The broker calls default to
    [Alpaca]. *)
val execute_decision :
  ?existing:(string * Alpaca.order_t) list ->
  ?sleep:(float -> unit) ->
  ?finish:(string -> string -> string -> Alpaca.order_t -> unit) ->
  ?order_by_client_id:(mode -> string -> Alpaca.order_t option) ->
  ?clock:(mode -> Alpaca.clock_t) ->
  ?submit_market:
    (mode -> symbol:string -> qty:float -> side:[`Buy | `Sell] ->
     client_order_id:string -> Alpaca.order_t) ->
  mode -> string -> string -> decision -> unit
```

- [ ] **Step 5: Narrow the stage 1 guard**

In `bin/bt.ml` `live_command_args`, replace lines 789-800 (from `  let rebalance = Dsl.rebalance_of ~filename:strat_path ast in` through the `in` that closes the stage 1 guard) with:

```ocaml
  let rebalance = Dsl.rebalance_of ~filename:strat_path ast in
  let () = ignore (Dsl.short_of ~filename:strat_path ast) in
  let overnight = Dsl.overnight_of ~filename:strat_path ast in
  let () =
    if List.exists (function Ast.Bars _ -> true | _ -> false) ast then
      failwith "day trading strategies run under bt daytrade"
  in
  let () =
    (* The overnight daemon lands with the exit machinery; until then a daemon would hold the entry across sessions. *)
    if overnight then
      failwith "overnight is not supported by bt target and bt live yet"
  in
```

`short` is now consumed by `Live.decide` and `Live.run` themselves, so `live_command_args` only validates it (the TW message still comes from `Dsl.short_of`).

- [ ] **Step 6: Build and run the tests**

Run: `dune build --root . 2>&1` then `dune build --root . @runtest --force 2>&1 | tail -3`
Expected: the build prints nothing; the runner's last line is `ok`.

- [ ] **Step 7: Commit**

Commit only after the coordinator confirms; use the co-author trailer the coordinator names; never push; never change git settings.

```bash
git add broker/live.ml broker/live.mli bin/bt.ml test/test_bt.ml
git commit -m "feat: US live short entry, asset flag gate, closes before opens"
```

### Task 4: Overnight exit machinery

**Files:**
- Modify: `broker/live.ml` after `retry_clock` (`broker/live.ml:1109-1116`) and `us_step` (`broker/live.ml:1118-1163`), `run_us` (`broker/live.ml:1165-1198`), `run` (`broker/live.ml:1784-1804`)
- Modify: `broker/live.mli:197-205` (the whole `val us_step` block and its comment), after `val timestamp_date` (line 208)
- Modify: `bin/bt.ml` `live_command_args` (the Task 3 guard)
- Test: the six `~decide:` closures passed directly to `Live.us_step` (`test/test_bt.ml:6032, 9776, 9933, 9969, 10000, 10072`), new helpers and tests before `test_tw_session_existing_second_code` (`test/test_bt.ml:10119`), registration after `  let () = test_us_open_sell_restart_end_to_end () in` (`test/test_bt.ml:10427`), the Task 3 block of `test_short_cli_errors`

**Interfaces:**
- Consumes: `Alpaca.listed_t`, `Alpaca.list_orders`, `Alpaca.open_orders`, `Alpaca.cancel_order`, `Alpaca.order_by_id`, `Alpaca.order_by_client_id`, `Alpaca.position_qty`, `Alpaca.submit_market`, `Alpaca.clock`, `Alpaca.calendar` (Task 1 and existing); `Data.et_offset_minutes`; `client_order_id`, `log`, `log_fill`, `order_description`, `terminal_order_status`, `next_actions`, `shift_rfc3339`, `rfc3339_seconds`, `timezone_start`, `date_prefix`, `timestamp_date` (existing in `broker/live.ml`); `decide ?frozen`, `us_plan_action ~frozen` (Task 2); `run_us ~short` (Task 3).
- Produces (`clear_open` returns `(float * float option) option`): `type overnight_broker = { list_orders : after:string -> Alpaca.listed_t list; open_orders : string -> Alpaca.listed_t list; position : string -> float; submit : symbol:string -> qty:float -> side:[`Buy | `Sell] -> id:string -> Alpaca.order_t; cancel : string -> unit; order : string -> Alpaca.order_t option; lookup : string -> Alpaca.order_t option; clock : unit -> Alpaca.clock_t; session_close : string -> int; sleep : float -> unit }`; `type series = { series_date : string; exits : int; orphan : bool; series_id : string; qty : float; latest : Alpaca.order_t }`; `type settled = Final of Alpaca.order_t | Outstanding of Alpaca.order_t`; `val final_order_status : string -> bool`; `val series_of_order : symbol:string -> Alpaca.listed_t -> series option`; `val exit_id : symbol:string -> date:string -> held:float -> orphan:bool -> int -> string`; `val follow : overnight_broker -> polls:int -> Alpaca.order_t -> Alpaca.order_t`; `val settle : overnight_broker -> Alpaca.order_t -> settled`; `val clear_open : overnight_broker -> today:string -> symbol:string -> (float * float option) option`; `val drive_exit : overnight_broker -> today:string -> symbol:string -> deadline:int option -> series option -> unit`; `val overnight_exits : overnight_broker -> symbols:string array -> today:string -> after:string -> deadline:int option -> unit`; `val late_exit : overnight_broker -> date:string -> next_close:string -> string list -> string list`; `val us_step : ?broker:overnight_broker -> ?overnight:bool -> symbols:string array -> lookup:(string -> Alpaca.order_t option) -> decide:(frozen:string list -> string -> decision) -> ...` (the rest unchanged); `val rfc3339_seconds : string -> int`; `session_close_of` and `run_us ... ~short ~overnight` (internal).

- [ ] **Step 1: Write the failing tests**

`us_step`'s `decide` callback now takes `~frozen`. Change the six closures passed directly to `Live.us_step` so they accept it: at `test/test_bt.ml:6032` (`test_us_step_routing`'s wrapper) `~decide:(fun date -> record ("decide:" ^ date); decide date)` becomes `~decide:(fun ~frozen:_ date -> record ("decide:" ^ date); decide date)`; at 9776 (`test_us_restart_buy_post_failure_finishes`) `~decide:(fun _ -> decision)` becomes `~decide:(fun ~frozen:_ _ -> decision)`; at 9933 `~decide:(fun _ -> let () = incr decisions in decision)` becomes `~decide:(fun ~frozen:_ _ -> let () = incr decisions in decision)`; at 9969 `~decide:(fun _ -> assert false)` becomes `~decide:(fun ~frozen:_ _ -> assert false)`; at 10000 and 10072 `~decide:(fun actual_date ->` becomes `~decide:(fun ~frozen:_ actual_date ->`. The closures inside `test_us_step_routing` that go through its `run ... ~decide` wrapper (`unreachable`, `fun _ -> failwith "stale snapshot"`, `fun _ -> decision` at 6053-6075) stay unary.

Insert before `let test_us_closes_before_opens () =` (added in Task 3 before `test/test_bt.ml:10119`), so the Task 3 definition stays the only one:

```ocaml
let us_exit_order ?(id = "broker") status : Alpaca.order_t =
  { id; status; side = "buy";
    filled_avg_price = (if status = "filled" then Some 100. else None);
    filled_qty = (if status = "filled" then 3. else 0.) }

(* A listed order's Alpaca id carries its client id, so the fake can tell an
   entry fill from an exit fill. *)
let us_listed ?(submitted_at = "2025-06-24T20:05:00Z") ?(qty = 3.) id status
    : Alpaca.listed_t =
  { client_order_id = id; submitted_at; qty; order = us_exit_order ~id:("broker:" ^ id) status }

let us_client_id alpaca_id =
  if String.length alpaca_id > 7 && String.sub alpaca_id 0 7 = "broker:" then
    String.sub alpaca_id 7 (String.length alpaca_id - 7)
  else alpaca_id

let us_is_exit id =
  List.exists (fun suffix -> contains id suffix) ["-cover"; "-exit"; "-orphan"; "-late"]

(* A fake broker that records every call. [held] is the position: a fill
   read back through [order] or [lookup], or returned by [submit], moves it
   as a real fill would: an exit or late close flattens it, an entry sets it
   to [entry_fill]; a listed status is only history. [lookups] feeds [order]
   and [lookup] in call order and [clocks] feeds [clock], which returns
   [now] once the queue is empty. *)
let us_overnight_broker ~events ?(listed = []) ?(open_orders = fun _ -> [])
    ?(held = 0.) ?(entry_fill = -3.) ?(lookups = []) ?(clocks = [])
    ?(now = "2025-06-25T09:35:00-04:00") ?(submitted = "filled")
    ?(session_close = "2025-06-24T16:00:00-04:00") () =
  let emit text = events := text :: !events in
  let held = ref held in
  let lookups = ref lookups and clocks = ref clocks in
  let next name queue =
    match !queue with
    | [] -> failwith ("no " ^ name ^ " response left")
    | head :: rest -> let () = queue := rest in head
  in
  let fill id = held := (if us_is_exit id then 0. else entry_fill) in
  let read id status =
    let () = if status = "filled" then fill id in
    if status = "none" then None else Some (us_exit_order ~id:("broker:" ^ id) status)
  in
  let broker : Live.overnight_broker =
    { list_orders = (fun ~after -> let () = emit ("list:" ^ after) in listed);
      open_orders = (fun symbol -> let () = emit ("open:" ^ symbol) in open_orders symbol);
      position = (fun symbol ->
        let () = emit (Printf.sprintf "position:%s:%g" symbol !held) in !held);
      submit = (fun ~symbol:_ ~qty ~side ~id ->
        let side = if side = `Buy then "buy" else "sell" in
        let () = emit (Printf.sprintf "post:%s:%s:%s" side (Alpaca.qty_string qty) id) in
        let () = if submitted = "filled" then fill id in
        us_exit_order ~id:("broker:" ^ id) submitted);
      cancel = (fun id -> emit ("cancel:" ^ us_client_id id));
      order = (fun alpaca_id ->
        let id = us_client_id alpaca_id in
        let status = next "order" lookups in
        let () = emit (Printf.sprintf "order:%s:%s" id status) in
        read id status);
      lookup = (fun id ->
        let status = next "lookup" lookups in
        let () = emit (Printf.sprintf "lookup:%s:%s" id status) in
        read id status);
      clock = (fun () ->
        let timestamp = match !clocks with
          | [] -> now
          | _ -> let timestamp = next "clock" clocks in
            let () = emit ("clock:" ^ timestamp) in timestamp in
        { Alpaca.timestamp; is_open = true; next_open = "2025-06-26T09:30:00-04:00";
          next_close = "2025-06-25T16:00:00-04:00" });
      session_close = (fun _ -> Live.rfc3339_seconds session_close);
      sleep = (fun seconds -> emit (Printf.sprintf "sleep:%g" seconds)) }
  in
  broker, held

let us_overnight_step ?(symbols = [|"QQQ"|]) ?(overnight = true) ?lookup ?decide
    ?execute broker clock =
  let events = ref [] in
  let output = capture_stdout (fun () ->
    Live.us_step ~broker ~overnight ~symbols
      ~lookup:(match lookup with Some lookup -> lookup | None -> fun _ -> None)
      ~decide:(match decide with
        | Some decide -> decide
        | None -> fun ~frozen:_ _ -> failwith "unexpected decision")
      ~execute:(match execute with
        | Some execute -> execute
        | None -> fun _ _ _ -> failwith "unexpected execution")
      ~finish:(fun _ _ _ _ -> failwith "unexpected reconciliation")
      ~sleep_until:(fun timestamp -> events := ("sleep-until:" ^ timestamp) :: !events)
      ~retry:(fun () -> events := "retry" :: !events)
      ~continue:(fun () -> events := "continue" :: !events) clock) in
  List.rev !events, output

let us_evening : Alpaca.clock_t =
  { timestamp = "2025-06-24T16:05:00-04:00"; is_open = false;
    next_open = "2025-06-25T09:30:00-04:00"; next_close = "2025-06-25T16:00:00-04:00" }

let us_morning : Alpaca.clock_t =
  { timestamp = "2025-06-25T09:35:00-04:00"; is_open = true;
    next_open = "2025-06-26T09:30:00-04:00"; next_close = "2025-06-25T16:00:00-04:00" }

let us_decision_clock : Alpaca.clock_t =
  { timestamp = "2025-06-25T15:45:00-04:00"; is_open = true;
    next_open = "2025-06-26T09:30:00-04:00"; next_close = "2025-06-25T16:00:00-04:00" }

let accepted_forever = List.init 20 (fun _ -> "accepted")

let test_us_overnight_exit_gate () =
  let after = "2025-06-17T16:05:00-04:00" in
  let run ?symbols ?listed ?open_orders ?held ?lookups ?(clock = us_evening) () =
    let broker_events = ref [] in
    let broker, _ = us_overnight_broker ~events:broker_events ?listed ?open_orders
      ?held ?lookups ~now:clock.Alpaca.timestamp () in
    let events, output = us_overnight_step ?symbols broker clock in
    List.rev !broker_events, events, output
  in
  let entry status = us_listed "bt-QQQ-2025-06-24" status in
  (* A filled entry and a -3 position: the gate lists the week, finds no
     open order, reads the position, and queues a 3-share buy under -cover;
     the daemon then sleeps to the open plus 5 minutes. *)
  let broker_events, events, output = run ~listed:[entry "filled"] ~held:(-3.) () in
  assert (broker_events = ["list:" ^ after; "open:QQQ"; "position:QQQ:-3";
    "post:buy:3:bt-QQQ-2025-06-24-cover"]);
  assert (events = ["sleep-until:2025-06-25T09:35:00-04:00"; "continue"]);
  assert (contains output "symbol=QQQ held=-3 order=buy:3:bt-QQQ-2025-06-24-cover fill=pending");
  (* A long entry partially filled at 16:05, past its session close plus 5
     minutes: no further wait; the open-orders guard settles it (cancel, one
     15-second poll to canceled), then the 2.5 shares held exit under a
     fractional sell. *)
  let broker_events, _, _ = run ~symbols:[|"SPY"|]
    ~listed:[us_listed "bt-SPY-2025-06-24" "partially_filled"]
    ~open_orders:(fun _ -> [us_listed "bt-SPY-2025-06-24" "partially_filled"])
    ~held:2.5 ~lookups:["canceled"] () in
  assert (broker_events = ["list:" ^ after; "open:SPY"; "cancel:bt-SPY-2025-06-24";
    "sleep:15"; "order:bt-SPY-2025-06-24:canceled"; "position:SPY:2.5";
    "post:sell:2.5:bt-SPY-2025-06-24-exit"]);
  (* A restart at 16:02 follows the open entry to 16:05 first: at most 12
     polls of 15 seconds; the second poll finds it filled. *)
  let broker_events, _, _ = run ~listed:[entry "accepted"] ~held:(-3.)
    ~lookups:["accepted"; "filled"]
    ~clock:{ us_evening with timestamp = "2025-06-24T16:02:00-04:00" } () in
  assert (broker_events = ["list:2025-06-17T16:02:00-04:00"; "sleep:15";
    "order:bt-QQQ-2025-06-24:accepted"; "sleep:15"; "order:bt-QQQ-2025-06-24:filled";
    "open:QQQ"; "position:QQQ:-3"; "post:buy:3:bt-QQQ-2025-06-24-cover"]);
  (* A fill during the cancel counts as filled: pending_cancel, then filled;
     the position read after it is flat, so nothing is posted. A 422 on an
     already terminal order returns from cancel like a 204 and reaches the
     same poll. *)
  let broker_events, _, _ = run ~listed:[entry "accepted"]
    ~open_orders:(fun _ -> [entry "accepted"]) ~held:(-3.)
    ~lookups:["pending_cancel"; "filled"] () in
  assert (broker_events = ["list:" ^ after; "open:QQQ"; "cancel:bt-QQQ-2025-06-24";
    "sleep:15"; "order:bt-QQQ-2025-06-24:pending_cancel"; "sleep:15";
    "order:bt-QQQ-2025-06-24:filled"; "position:QQQ:-3"; "post:buy:3:bt-QQQ-2025-06-24-cover"]);
  (* A zero remainder submits nothing. *)
  let broker_events, _, _ = run ~listed:[entry "canceled"] () in
  assert (broker_events = ["list:" ^ after; "open:QQQ"; "position:QQQ:0"]);
  (* An exit already queued stays queued after the close. *)
  let broker_events, _, output = run ~held:(-3.)
    ~listed:[us_listed "bt-QQQ-2025-06-24-cover" "accepted"; entry "filled"] () in
  assert (broker_events = ["list:" ^ after]);
  assert (contains output "order=existing:bt-QQQ-2025-06-24-cover fill=pending");
  (* The settle bound: an entry that stays accepted through 20 polls is
     outstanding; the gate logs it and posts no exit for the symbol. *)
  let broker_events, _, output = run ~listed:[entry "accepted"]
    ~open_orders:(fun _ -> [entry "accepted"]) ~held:(-3.) ~lookups:accepted_forever () in
  assert (List.length (List.filter (fun e -> contains e "order:") broker_events) = 20);
  assert (not (List.exists (fun e -> contains e "post:") broker_events));
  assert (contains output "symbol=QQQ note=overnight exit outstanding");
  (* One symbol's failure is logged and the other symbol is still driven. *)
  let broker_events = ref [] in
  let broker, _ = us_overnight_broker ~events:broker_events
    ~listed:[entry "filled"; us_listed "bt-SPY-2025-06-24" "filled"] ~held:(-3.) () in
  let broker = { broker with position = (fun symbol ->
    if symbol = "SPY" then failwith "SPY position unavailable" else broker.position symbol) } in
  let events, output = us_overnight_step ~symbols:[|"SPY"; "QQQ"|] broker us_evening in
  assert (List.rev !broker_events = ["list:" ^ after; "open:SPY"; "open:QQQ";
    "position:QQQ:-3"; "post:buy:3:bt-QQQ-2025-06-24-cover"]);
  assert (contains output "symbol=SPY error=Failure(\"SPY position unavailable\") order=skip");
  assert (events = ["sleep-until:2025-06-25T09:35:00-04:00"; "continue"]);
  (* The decision never submits an exit: at 15:45 the entry goes out through
     the executor as before, after the symbol's open-orders guard. *)
  let broker_events = ref [] in
  let broker, _ = us_overnight_broker ~events:broker_events ~lookups:["none"] () in
  let executed = ref false in
  let events, _ = us_overnight_step broker us_decision_clock
    ~decide:(fun ~frozen _ -> let () = assert (frozen = []) in
      us_pair_decision [|Live.Order { side = `Sell; qty = 3.; id = "bt-SPY-2025-06-25" }|])
    ~execute:(fun _ _ _ -> executed := true) in
  assert (!executed && List.rev !broker_events = ["lookup:bt-QQQ-2025-06-25-late:none";
    "open:QQQ"; "position:QQQ:0"]);
  (* The day ends at the close plus 5 minutes so the closed clock runs the gate. *)
  assert (events = ["sleep-until:2025-06-25T16:05:00-04:00"; "continue"]);
  (* A failing listing logs order=retry and retries. *)
  let broker, _ = us_overnight_broker ~events:(ref []) () in
  let broker = { broker with list_orders = (fun ~after:_ -> failwith "orders unavailable") } in
  let events, output = us_overnight_step broker us_evening in
  assert (events = ["retry"]);
  assert (contains output "error=Failure(\"orders unavailable\") order=retry")

let test_us_overnight_morning_step () =
  let after = "2025-06-18T09:35:00-04:00" in
  let run ?listed ?open_orders ?held ?lookups ?clocks ?now ?submitted ?list_orders () =
    let broker_events = ref [] in
    let broker, _ = us_overnight_broker ~events:broker_events ?listed ?open_orders
      ?held ?lookups ?clocks ?now ?submitted () in
    let broker = match list_orders with
      | Some list_orders -> { broker with list_orders }
      | None -> broker in
    let events, output = us_overnight_step broker us_morning in
    List.rev !broker_events, events, output
  in
  let entry = us_listed "bt-QQQ-2025-06-24" "filled" in
  let series status = [us_listed "bt-QQQ-2025-06-24-cover" status; entry] in
  let at_0950 = "2025-06-25T09:50:00-04:00" in
  (* Filled and flat: the step logs the fill, checks the position, and the
     daemon sleeps to the decision. *)
  let broker_events, events, output = run ~listed:(series "filled") () in
  assert (broker_events = ["list:" ^ after]);
  assert (contains output "client-order-id=bt-QQQ-2025-06-24-cover fill-status=filled");
  assert (events = ["sleep-until:2025-06-25T15:45:00-04:00"; "continue"]);
  (* A fully filled exit (3 of 3) has no remainder: a positions read that
     still shows -3 is a lagging mark, and nothing is posted. *)
  let broker_events, _, _ = run ~listed:(series "filled") ~held:(-3.) () in
  assert (broker_events = ["list:" ^ after]);
  (* Filled 3 of 4 with -1 still held: -cover2 buys min 1 (held) 1 (unfilled)
     and its fill ends the series. *)
  let broker_events, _, _ = run ~held:(-1.)
    ~listed:[us_listed ~qty:4. "bt-QQQ-2025-06-24-cover" "filled"; entry] () in
  assert (broker_events = ["list:" ^ after; "open:QQQ"; "position:QQQ:-1";
    "post:buy:1:bt-QQQ-2025-06-24-cover2"]);
  (* The unfilled part caps the remainder: filled 3 of 4 while the positions
     read lags at -3 posts 1, not 3. *)
  let broker_events, _, _ = run ~held:(-3.)
    ~listed:[us_listed ~qty:4. "bt-QQQ-2025-06-24-cover" "filled"; entry] () in
  assert (List.nth broker_events 3 = "post:buy:1:bt-QQQ-2025-06-24-cover2");
  (* Open then filled: before 09:50 the step waits 60 seconds and re-reads;
     a restart with an existing -cover takes this path, never a blind POST. *)
  let broker_events, _, _ = run ~listed:(series "accepted") ~held:(-3.)
    ~lookups:["filled"] () in
  assert (broker_events = ["list:" ^ after; "sleep:60"; "order:bt-QQQ-2025-06-24-cover:filled"]);
  (* Terminal and unfilled: the remainder goes out under -cover2 after the
     open-orders guard. *)
  let broker_events, _, output = run ~listed:(series "canceled") ~held:(-3.) () in
  assert (broker_events = ["list:" ^ after; "open:QQQ"; "position:QQQ:-3";
    "post:buy:3:bt-QQQ-2025-06-24-cover2"]);
  assert (contains output "order=buy:3:bt-QQQ-2025-06-24-cover2 fill=pending");
  (* Open at 09:50: the exit is settled (cancel, poll to canceled) before the
     resubmission; a stopped exit is outstanding, so the settle keeps polling
     it and no resubmission is placed while it is open. *)
  let broker_events, _, _ = run ~listed:(series "accepted") ~held:(-3.) ~now:at_0950
    ~lookups:["stopped"; "canceled"] () in
  assert (broker_events = ["list:" ^ after; "cancel:bt-QQQ-2025-06-24-cover"; "sleep:15";
    "order:bt-QQQ-2025-06-24-cover:stopped"; "sleep:15"; "order:bt-QQQ-2025-06-24-cover:canceled";
    "open:QQQ"; "position:QQQ:-3"; "post:buy:3:bt-QQQ-2025-06-24-cover2"]);
  (* A stopped exit found at 09:40 waits like any outstanding exit. *)
  let broker_events, _, _ = run ~listed:(series "stopped") ~held:(-3.)
    ~now:"2025-06-25T09:40:00-04:00" ~lookups:["filled"] () in
  assert (broker_events = ["list:" ^ after; "sleep:60"; "order:bt-QQQ-2025-06-24-cover:filled"]);
  (* The grace period: a resubmission at 09:50 is followed every 15 seconds
     for up to 2 minutes before any settle; here it fills on the second poll. *)
  let broker_events, _, _ = run ~listed:(series "canceled") ~held:(-3.) ~now:at_0950
    ~submitted:"accepted" ~lookups:["accepted"; "filled"] () in
  assert (broker_events = ["list:" ^ after; "open:QQQ"; "position:QQQ:-3";
    "post:buy:3:bt-QQQ-2025-06-24-cover2"; "sleep:15"; "order:bt-QQQ-2025-06-24-cover2:accepted";
    "sleep:15"; "order:bt-QQQ-2025-06-24-cover2:filled"]);
  (* Grace expired: eight polls still accepted, then the settle (cancel and
     one poll to canceled) and -cover3, which fills on its first poll. *)
  let broker_events, _, _ = run ~listed:(series "canceled") ~held:(-3.) ~now:at_0950
    ~submitted:"accepted" ~lookups:(List.init 8 (fun _ -> "accepted") @ ["canceled"; "filled"]) () in
  assert (List.filter (fun e -> contains e "post:" || contains e "cancel:") broker_events
    = ["post:buy:3:bt-QQQ-2025-06-24-cover2"; "cancel:bt-QQQ-2025-06-24-cover2";
       "post:buy:3:bt-QQQ-2025-06-24-cover3"]);
  assert (List.length (List.filter (fun e -> contains e "order:") broker_events) = 10);
  (* The settle bound at 09:50: 20 polls still accepted leave the exit
     outstanding; no resubmission. *)
  let broker_events, _, output = run ~listed:(series "accepted") ~held:(-3.) ~now:at_0950
    ~lookups:accepted_forever () in
  assert (not (List.exists (fun e -> contains e "post:") broker_events));
  assert (List.length (List.filter (fun e -> contains e "order:") broker_events) = 20);
  assert (contains output "symbol=QQQ note=overnight exit outstanding");
  (* The fourth exit is the third resubmission; a canceled -cover4 logs
     overnight exit unfilled and leaves the position to the late exit. *)
  let broker_events, _, _ = run ~held:(-3.)
    ~listed:[us_listed "bt-QQQ-2025-06-24-cover3" "canceled"; entry] () in
  assert (List.nth broker_events 3 = "post:buy:3:bt-QQQ-2025-06-24-cover4");
  let broker_events, _, output = run ~held:(-3.)
    ~listed:[us_listed "bt-QQQ-2025-06-24-cover4" "canceled"; entry] () in
  assert (broker_events = ["list:" ^ after; "open:QQQ"; "position:QQQ:-3"]);
  assert (contains output "symbol=QQQ note=overnight exit unfilled");
  (* A Monday restart pages the week's listing through Alpaca.list_orders:
     the first page holds 500 newer foreign rows, newest first, down to
     Sunday 00:00; the second page, requested with until set to that
     exclusive cursor, holds Friday's entry and exit. The filled exit and
     the flat position need nothing. *)
  let monday : Alpaca.clock_t =
    { timestamp = "2025-06-23T09:35:00-04:00"; is_open = true;
      next_open = "2025-06-24T09:30:00-04:00"; next_close = "2025-06-23T16:00:00-04:00" } in
  let monday_after = "2025-06-16T09:35:00-04:00" in
  let pages = ref [] in
  let page path =
    let () = pages := path :: !pages in
    if List.length !pages = 1 then
      List.init 500 (fun index ->
        us_listed ~submitted_at:(Printf.sprintf "2025-06-22T%02d:%02d:00Z"
          ((499 - index) / 60) ((499 - index) mod 60)) "-" "canceled")
    else [us_listed ~submitted_at:"2025-06-20T20:05:12Z" "bt-QQQ-2025-06-20-cover" "filled";
          us_listed ~submitted_at:"2025-06-20T19:45:40Z" "bt-QQQ-2025-06-20" "filled"]
  in
  let broker_events = ref [] in
  let broker, _ = us_overnight_broker ~events:broker_events ~now:monday.timestamp () in
  let broker = { broker with list_orders = (fun ~after ->
    Alpaca.list_orders ~page Alpaca.Paper ~symbols:["QQQ"] ~after) } in
  let events, output = us_overnight_step broker monday in
  assert (List.rev !pages = [
    "/v2/orders?status=all&limit=500&direction=desc&after=2025-06-16T09%3A35%3A00-04%3A00&symbols=QQQ";
    "/v2/orders?status=all&limit=500&direction=desc&after=2025-06-16T09%3A35%3A00-04%3A00&symbols=QQQ&until=2025-06-22T00%3A00%3A00Z" ]);
  assert (!broker_events = []);
  assert (contains output "client-order-id=bt-QQQ-2025-06-20-cover fill-status=filled");
  assert (events = ["sleep-until:2025-06-23T15:45:00-04:00"; "continue"]);
  ignore monday_after;
  (* A restart after the entry fill with no exit submits the exit now. *)
  let broker_events, _, _ = run ~listed:[entry] ~held:(-3.) () in
  assert (broker_events = ["list:" ^ after; "open:QQQ"; "position:QQQ:-3";
    "post:buy:3:bt-QQQ-2025-06-24-cover"]);
  (* A restart after an entry-less exit resumes that series under its date. *)
  let broker_events, _, _ = run ~held:(-3.)
    ~listed:[us_listed "bt-QQQ-2025-06-20-cover" "expired"] () in
  assert (List.nth broker_events 3 = "post:buy:3:bt-QQQ-2025-06-20-cover2");
  (* A held symbol with no bt-QQQ- order in the window is exited under
     today's -orphan family after the note, so the day's entry series stays
     free; a later pass resumes the orphan series. *)
  let broker_events, _, output = run ~held:(-3.)
    ~listed:[us_listed "bt-SPY-2025-06-24" "filled"] () in
  assert (broker_events = ["list:" ^ after; "position:QQQ:-3"; "open:QQQ"; "position:QQQ:-3";
    "post:buy:3:bt-QQQ-2025-06-25-orphan"]);
  assert (contains output "symbol=QQQ note=overnight position without entry");
  let broker_events, _, _ = run ~held:(-3.)
    ~listed:[us_listed "bt-QQQ-2025-06-25-orphan" "canceled"] () in
  assert (List.nth broker_events 3 = "post:buy:3:bt-QQQ-2025-06-25-orphan2")

let test_us_overnight_late_exit () =
  let entry symbol = Live.Order { side = `Sell; qty = 3.; id = "bt-" ^ symbol ^ "-2025-06-25" } in
  let run ?(symbols = [|"QQQ"|]) ?open_orders ?lookups ?clocks ?submitted ~held () =
    let broker_events = ref [] in
    let broker, _ = us_overnight_broker ~events:broker_events ?open_orders ?lookups
      ?clocks ?submitted ~held ~now:"2025-06-25T15:46:00-04:00" () in
    let decided = ref None in
    let events, output = us_overnight_step ~symbols broker us_decision_clock
      ~decide:(fun ~frozen _ ->
        let () = decided := Some frozen in
        { (us_pair_decision [||]) with assets = Array.map (fun symbol ->
          { Live.symbol; provisional = bar "2025-06-25" 100. 100.; target = -0.3; held = 0.;
            action = if List.mem symbol frozen then Live.Skip "overnight entry skipped"
              else entry symbol }) symbols })
      ~execute:(fun _ _ decision ->
        Array.iter (fun (a : Live.asset_decision) ->
          broker_events := ("execute:" ^ Live.(match a.action with
            | Order { id; _ } -> id | Skip reason -> reason | Orders _ -> "legs"))
            :: !broker_events) decision.assets) in
    List.rev !broker_events, !decided, events, output
  in
  let late = "bt-QQQ-2025-06-25-late" in
  (* A -3 position at the decision is closed first under -late, after the
     open-orders guard and a clock check; the fill flattens the account, the
     position re-read confirms it inside the window, and only then is the
     decision taken and the entry executed. *)
  let broker_events, decided, events, output = run ~held:(-3.) ~lookups:["none"] () in
  assert (broker_events = ["lookup:" ^ late ^ ":none"; "open:QQQ"; "position:QQQ:-3";
    "post:buy:3:" ^ late; "position:QQQ:0"; "execute:bt-QQQ-2025-06-25"]);
  assert (decided = Some []);
  assert (contains output "symbol=QQQ note=overnight position closed late");
  assert (contains output ("held=-3 order=buy:3:" ^ late ^ " fill=pending"));
  assert (events = ["sleep-until:2025-06-25T16:05:00-04:00"; "continue"]);
  (* An accepted late close is polled every 15 seconds while the window is
     open; the entry waits for filled plus a flat position. *)
  let broker_events, _, _, _ = run ~held:(-3.) ~submitted:"accepted"
    ~lookups:["none"; "filled"] () in
  assert (broker_events = ["lookup:" ^ late ^ ":none"; "open:QQQ"; "position:QQQ:-3";
    "post:buy:3:" ^ late; "sleep:15"; "order:" ^ late ^ ":filled"; "position:QQQ:0";
    "execute:bt-QQQ-2025-06-25"]);
  (* A canceled late close places no entry: the symbol is frozen and the
     session logs the skip. *)
  let broker_events, decided, _, output = run ~held:(-3.) ~submitted:"accepted"
    ~lookups:["none"; "canceled"] () in
  assert (List.nth broker_events 6 = "execute:overnight entry skipped");
  assert (decided = Some ["QQQ"]);
  assert (contains output "symbol=QQQ note=overnight entry skipped");
  (* The clock is checked right before the POST: at 15:58 no late close goes
     out and the entry is skipped. *)
  let broker_events, _, _, output = run ~held:(-3.) ~lookups:["none"]
    ~clocks:["2025-06-25T15:58:00-04:00"] () in
  assert (broker_events = ["lookup:" ^ late ^ ":none"; "open:QQQ"; "position:QQQ:-3";
    "clock:2025-06-25T15:58:00-04:00"; "execute:overnight entry skipped"]);
  assert (contains output "note=overnight entry skipped");
  (* A close still open past the submit window skips the entry too. *)
  let broker_events, _, _, _ = run ~held:(-3.) ~submitted:"accepted" ~lookups:["none"]
    ~clocks:["2025-06-25T15:46:00-04:00"; "2025-06-25T15:58:00-04:00"] () in
  assert (broker_events = ["lookup:" ^ late ^ ":none"; "open:QQQ"; "position:QQQ:-3";
    "clock:2025-06-25T15:46:00-04:00"; "post:buy:3:" ^ late;
    "clock:2025-06-25T15:58:00-04:00"; "execute:overnight entry skipped"]);
  (* Filled after the cutoff: the fill and the flat position are confirmed,
     but the clock recheck finds 15:58, so the entry is skipped. *)
  let broker_events, _, _, _ = run ~held:(-3.) ~submitted:"accepted"
    ~lookups:["none"; "filled"]
    ~clocks:["2025-06-25T15:46:00-04:00"; "2025-06-25T15:46:00-04:00";
             "2025-06-25T15:58:00-04:00"] () in
  assert (broker_events = ["lookup:" ^ late ^ ":none"; "open:QQQ"; "position:QQQ:-3";
    "clock:2025-06-25T15:46:00-04:00"; "post:buy:3:" ^ late;
    "clock:2025-06-25T15:46:00-04:00"; "sleep:15"; "order:" ^ late ^ ":filled";
    "position:QQQ:0"; "clock:2025-06-25T15:58:00-04:00"; "execute:overnight entry skipped"]);
  (* An exit still open at the decision (the morning step never ran) is
     settled before the late close: cancel, poll to canceled, re-read the
     position, then -late. *)
  let broker_events, _, _, _ = run ~held:(-3.)
    ~open_orders:(fun _ -> [us_listed "bt-QQQ-2025-06-24-cover" "accepted"])
    ~lookups:["none"; "canceled"] () in
  assert (broker_events = ["lookup:" ^ late ^ ":none"; "open:QQQ"; "cancel:bt-QQQ-2025-06-24-cover";
    "sleep:15"; "order:bt-QQQ-2025-06-24-cover:canceled"; "position:QQQ:-3"; "post:buy:3:" ^ late;
    "position:QQQ:0"; "execute:bt-QQQ-2025-06-25"]);
  (* The settle bound before the late close: an exit still accepted after
     20 polls is outstanding, so no -late goes out and the entry is skipped. *)
  let broker_events, decided, _, output = run ~held:(-3.)
    ~open_orders:(fun _ -> [us_listed "bt-QQQ-2025-06-24-cover" "accepted"])
    ~lookups:("none" :: accepted_forever) () in
  assert (not (List.exists (fun e -> contains e "post:") broker_events));
  assert (decided = Some ["QQQ"]);
  assert (contains output "note=overnight exit outstanding");
  assert (contains output "note=overnight entry skipped");
  (* A restart with the day's -late already open follows it instead of
     posting a second close, then runs the guard before the entry. *)
  let broker_events, _, _, _ = run ~held:(-3.) ~lookups:["accepted"; "filled"] () in
  assert (broker_events = ["lookup:" ^ late ^ ":accepted"; "sleep:15";
    "order:" ^ late ^ ":filled"; "position:QQQ:0"; "open:QQQ"; "position:QQQ:0";
    "execute:bt-QQQ-2025-06-25"]);
  (* A filled -late with another order on the symbol still outstanding after
     the guard's 20 polls: the entry is skipped. *)
  let broker_events, decided, _, output = run ~held:(-3.)
    ~open_orders:(fun _ -> [us_listed "-" "accepted"])
    ~lookups:("filled" :: accepted_forever) () in
  assert (List.nth broker_events 2 = "open:QQQ" && List.nth broker_events 3 = "cancel:-");
  assert (decided = Some ["QQQ"]);
  assert (contains output "note=overnight exit outstanding");
  (* A symbol whose pass raises is logged and blocked; the other continues. *)
  let broker_events = ref [] in
  let broker, _ = us_overnight_broker ~events:broker_events ~held:(-3.)
    ~lookups:["none"; "none"] ~now:"2025-06-25T15:46:00-04:00" () in
  let broker = { broker with position = (fun symbol ->
    if symbol = "SPY" then failwith "SPY position unavailable" else broker.position symbol) } in
  let decided = ref None in
  let _, output = us_overnight_step ~symbols:[|"SPY"; "QQQ"|] broker us_decision_clock
    ~decide:(fun ~frozen _ -> let () = decided := Some frozen in us_pair_decision [||])
    ~execute:(fun _ _ _ -> ()) in
  assert (!decided = Some ["SPY"]);
  assert (contains output "symbol=SPY error=Failure(\"SPY position unavailable\") order=skip");
  assert (List.mem ("post:buy:3:" ^ late) (List.rev !broker_events));
  (* The guard's closing fills cap the late close. A morning -exit on a long
     of 5 that fills all 5 during the settle while the positions read still
     shows 5 leaves 0 unfilled: no -late goes out, and the symbol stays
     blocked until a read confirms it flat. A cover of 3 that fills 2 and is
     canceled with the position read at -1 leaves 1 unfilled: -late buys
     min 1 1 = 1. *)
  let guarded ~qty ~filled ~status ~position =
    let broker_events = ref [] in
    let side, id = if position < 0. then "buy", "bt-QQQ-2025-06-24-cover"
      else "sell", "bt-QQQ-2025-06-24-exit" in
    let broker, _ = us_overnight_broker ~events:broker_events
      ~open_orders:(fun _ -> [us_listed ~qty id "accepted"])
      ~lookups:["none"] ~now:"2025-06-25T15:46:00-04:00" () in
    let broker = { broker with
      position = (fun _ ->
        let () = broker_events := Printf.sprintf "position:%g" position :: !broker_events in
        position);
      order = (fun alpaca_id ->
        let () = broker_events :=
          ("order:" ^ us_client_id alpaca_id ^ ":" ^ status) :: !broker_events in
        Some { (us_exit_order ~id:alpaca_id status) with side; filled_qty = filled }) } in
    let decided = ref None in
    let _, output = us_overnight_step broker us_decision_clock
      ~decide:(fun ~frozen _ -> let () = decided := Some frozen in us_pair_decision [||])
      ~execute:(fun _ _ _ -> ()) in
    List.rev !broker_events, !decided, output
  in
  let events, decided, output = guarded ~qty:5. ~filled:5. ~status:"filled" ~position:5. in
  assert (events = ["lookup:" ^ late ^ ":none"; "open:QQQ"; "cancel:bt-QQQ-2025-06-24-exit";
    "sleep:15"; "order:bt-QQQ-2025-06-24-exit:filled"; "position:5"]);
  assert (decided = Some ["QQQ"] && contains output "note=overnight entry skipped");
  let events, _, _ = guarded ~qty:3. ~filled:2. ~status:"canceled" ~position:(-1.) in
  assert (List.nth events 5 = "position:-1" && List.nth events 6 = "post:buy:1:" ^ late);
  (* The wait cap: at 15:46 with two symbols, 12 minutes remain to the
     cutoff, so each symbol may wait min 3 (6) minutes, 12 polls. SPY's close
     stays accepted; after 12 polls SPY is blocked and QQQ still gets its
     late close. *)
  let broker_events = ref [] in
  let broker, _ = us_overnight_broker ~events:broker_events ~held:(-3.)
    ~submitted:"accepted" ~lookups:("none" :: List.init 12 (fun _ -> "accepted") @ ["none"])
    ~now:"2025-06-25T15:46:00-04:00" () in
  let decided = ref None in
  let _ = us_overnight_step ~symbols:[|"SPY"; "QQQ"|] broker us_decision_clock
    ~decide:(fun ~frozen _ -> let () = decided := Some frozen in us_pair_decision [||])
    ~execute:(fun _ _ _ -> ()) in
  let events = List.rev !broker_events in
  assert (!decided = Some ["SPY"; "QQQ"]);
  assert (List.length (List.filter (fun e -> contains e "order:bt-SPY-2025-06-25-late") events) = 12);
  assert (List.mem "post:buy:3:bt-QQQ-2025-06-25-late" events);
  (* A four-symbol restart at 15:55 with a clock that advances 15 seconds
     per sleep: 3 minutes remain, so the first symbol may wait 45 seconds
     (3 polls), and the budget is recomputed from the clock for each
     following symbol; every late close is posted before the 15:58 cutoff
     and the entry is skipped for all four. *)
  let symbols = [|"AAA"; "BBB"; "CCC"; "DDD"|] in
  let broker_events = ref [] in
  let seconds = ref 0 in
  let stamp () = Printf.sprintf "2025-06-25T15:%02d:%02d-04:00" (55 + !seconds / 60) (!seconds mod 60) in
  let broker, _ = us_overnight_broker ~events:broker_events ~held:(-3.)
    ~submitted:"accepted" ~lookups:(List.init 40 (fun i -> if i mod 10 = 0 then "none" else "accepted")) () in
  let posted_at = ref [] in
  let broker = { broker with
    sleep = (fun s -> let () = seconds := !seconds + int_of_float s in broker.sleep s);
    clock = (fun () -> { (broker.clock ()) with Alpaca.timestamp = stamp () });
    submit = (fun ~symbol ~qty ~side ~id ->
      let () = posted_at := !seconds :: !posted_at in broker.submit ~symbol ~qty ~side ~id);
    lookup = (fun id -> if contains id "-late" then None else broker.lookup id) } in
  let decided = ref None in
  let _ = us_overnight_step ~symbols broker
    { us_decision_clock with Alpaca.timestamp = "2025-06-25T15:55:00-04:00" }
    ~decide:(fun ~frozen _ -> let () = decided := Some frozen in us_pair_decision [||])
    ~execute:(fun _ _ _ -> ()) in
  assert (!decided = Some (Array.to_list symbols));
  (* Each symbol's wait is 45 seconds (3 polls): the POSTs land at 15:55:00,
     15:55:45, 15:56:30, and 15:57:15, all inside the window. *)
  assert (List.rev !posted_at = [0; 45; 90; 135]);
  (* A flat account places no late close and decides at once. *)
  let broker_events, _, _, _ = run ~held:0. ~lookups:["none"] () in
  assert (broker_events = ["lookup:" ^ late ^ ":none"; "open:QQQ"; "position:QQQ:0";
    "execute:bt-QQQ-2025-06-25"]);
  (* Two symbols crossing the cutoff: SPY's late close fills at 15:46, QQQ's
     clock check before its own POST finds 15:58, so SPY enters and QQQ
     skips. QQQ's position is read separately so SPY's fill does not flatten it. *)
  let broker_events = ref [] in
  let broker, _ = us_overnight_broker ~events:broker_events ~held:(-3.)
    ~lookups:["none"; "none"] ~now:"2025-06-25T15:46:00-04:00"
    ~clocks:["2025-06-25T15:46:00-04:00"; "2025-06-25T15:46:00-04:00";
             "2025-06-25T15:58:00-04:00"] () in
  let broker = { broker with position = (fun symbol ->
    if symbol = "QQQ" then let () = broker_events := "position:QQQ:-3" :: !broker_events in -3.
    else broker.position symbol) } in
  let decided = ref None in
  let _ = us_overnight_step ~symbols:[|"SPY"; "QQQ"|] broker us_decision_clock
    ~decide:(fun ~frozen _ -> let () = decided := Some frozen in us_pair_decision [||])
    ~execute:(fun _ _ _ -> ()) in
  assert (!decided = Some ["QQQ"]);
  assert (List.rev !broker_events = ["lookup:bt-SPY-2025-06-25-late:none"; "open:SPY";
    "position:SPY:-3"; "clock:2025-06-25T15:46:00-04:00"; "post:buy:3:bt-SPY-2025-06-25-late";
    "position:SPY:0"; "clock:2025-06-25T15:46:00-04:00"; "lookup:" ^ late ^ ":none";
    "open:QQQ"; "position:QQQ:-3"; "clock:2025-06-25T15:58:00-04:00"]);
  (* Series ids: the entry, the numbered covers, exits and orphans, and a
     late close. *)
  let order = us_exit_order "filled" in
  let series id = Live.series_of_order ~symbol:"QQQ"
    { Alpaca.client_order_id = id; submitted_at = ""; qty = 3.; order } in
  let expect ?(orphan = false) date exits id =
    Some { Live.series_date = date; exits; orphan; series_id = id; qty = 3.; latest = order } in
  assert (series "bt-QQQ-2025-06-24" = expect "2025-06-24" 0 "bt-QQQ-2025-06-24");
  assert (series "bt-QQQ-2025-06-24-late" = expect "2025-06-24" 0 "bt-QQQ-2025-06-24-late");
  assert (series "bt-QQQ-2025-06-24-cover" = expect "2025-06-24" 1 "bt-QQQ-2025-06-24-cover");
  assert (series "bt-QQQ-2025-06-24-exit3" = expect "2025-06-24" 3 "bt-QQQ-2025-06-24-exit3");
  assert (series "bt-QQQ-2025-06-24-orphan2"
    = expect ~orphan:true "2025-06-24" 2 "bt-QQQ-2025-06-24-orphan2");
  assert (series "bt-QQQQ-2025-06-24" = None && series "bt-QQQ-2025-06-24-x" = None
    && series "-" = None);
  assert (Live.exit_id ~symbol:"QQQ" ~date:"2025-06-24" ~held:(-3.) ~orphan:false 1
    = "bt-QQQ-2025-06-24-cover");
  assert (Live.exit_id ~symbol:"SPY" ~date:"2025-06-24" ~held:2.5 ~orphan:false 2
    = "bt-SPY-2025-06-24-exit2");
  assert (Live.exit_id ~symbol:"SPY" ~date:"2025-06-24" ~held:2.5 ~orphan:true 1
    = "bt-SPY-2025-06-24-orphan");
  (* stopped and pending_cancel are outstanding for the settle step. *)
  assert (Live.final_order_status "filled" && Live.final_order_status "rejected");
  assert (not (Live.final_order_status "stopped" || Live.final_order_status "pending_cancel"))

let test_us_overnight_frozen_entry () =
  (* Two symbols through the real planner and executor under rebalance daily:
     QQQ's late close is canceled, so QQQ is frozen at its -3 held shares and
     SPY's entry is the only POST. Account: cash 500 of which 450 is the
     reserve of the QQQ short (300 at 100), equity 200, available cash 50. *)
  let account : Alpaca.account_t =
    { equity = 1.; cash = 500.; long_market_value = 0.; short_market_value = -300.;
      initial_margin = 0.; shorting_enabled = true; status = "ACTIVE";
      trading_blocked = false; account_number = "paper-account" } in
  let held = [|0.; -3.|] and prices = [|10.; 100.|] and targets = [|-0.9; -1.5|] in
  let plan_action frozen date =
    Live.us_plan_action ~frozen ~short:true ~overnight:true ~rebalance:true
      ~symbols:[|"SPY"; "QQQ"|] ~date ~account ~position_symbols:["QQQ"] ~held
      ~prices ~targets ~previous_targets:[|0.; 0.|]
  in
  (* The planner itself: SPY's sell charge makes E1 < E0, so an unfrozen
     QQQ at its own -1.5 exposure would cover one share (1.5 * E1 / 100 =
     2.99 floors to 2) and release 150 of reserve, letting SPY open 17
     shares (0.9 * 200 / 10 less the charge) instead of the 9 that the 50 of
     available cash collateralizes (50 / 0.5 = 100 of proceeds, 9 shares
     after the charge). Frozen, QQQ's trade is exactly zero and SPY is
     clamped. *)
  let state, _ = plan_action ["QQQ"] "2025-06-25" in
  let plan frozen = Engine.plan_fills ~frozen
    ~costs:[| Engine.default_costs ~market:"us" ~symbol:"SPY";
              Engine.default_costs ~market:"us" ~symbol:"QQQ" |]
    ~capital:1. ~profile:(Engine.profile_of_market "us") ~financing_ratios:[|0.5; 0.5|]
    ~state:{ state with previous_targets = [|0.; 0.|] } ~prices ~targets ~force:true in
  let frozen = plan [|false; true|] and thawed = plan [||] in
  assert (not frozen.Engine.planned_assets.(1).Engine.plan_changed);
  assert (frozen.planned_assets.(1).plan_short_cover = 0.);
  assert (frozen.planned_assets.(0).plan_short_open = 90.);
  assert (thawed.planned_assets.(1).plan_short_cover = 100.);
  assert (thawed.planned_assets.(0).plan_short_open = 170.);
  let posted = ref [] in
  let decide ~frozen date =
    let state, actions = plan_action frozen date in
    { Live.fetched_through = "2025-06-24"; equity = state.Engine.equity; cash = state.cash;
      debit = 0.; legs = []; assets = Array.mapi (fun i symbol ->
        { Live.symbol; provisional = bar date prices.(i) prices.(i); target = targets.(i);
          held = held.(i); action = actions.(i) }) [|"SPY"; "QQQ"|] }
  in
  let execute existing clock decision =
    Live.execute_decision ~existing ~order_by_client_id:(fun _ _ -> None)
      ~clock:(fun _ -> clock)
      ~submit_market:(fun _ ~symbol ~qty ~side ~client_order_id ->
        let () = posted := (symbol, qty, side, client_order_id) :: !posted in
        us_fixture_order symbol "sell" "filled")
      ~finish:(fun _ _ _ _ -> ())
      Live.Paper "2025-06-25" clock.Alpaca.next_close decision
  in
  let broker_events = ref [] in
  let broker, _ = us_overnight_broker ~events:broker_events ~held:(-3.)
    ~submitted:"accepted" ~now:"2025-06-25T15:46:00-04:00"
    ~lookups:["none"; "canceled"] () in
  (* SPY is flat: its late lookup is skipped by the flat position read. *)
  let broker = { broker with
    position = (fun symbol -> if symbol = "SPY" then 0. else broker.position symbol);
    lookup = (fun id -> if contains id "SPY" then None else broker.lookup id) } in
  let output = capture_stdout (fun () ->
    Live.us_step ~broker ~overnight:true ~symbols:[|"SPY"; "QQQ"|]
      ~lookup:(fun _ -> None) ~decide ~execute ~finish:(fun _ _ _ _ -> ())
      ~sleep_until:(fun _ -> ()) ~retry:(fun () -> assert false)
      ~continue:(fun () -> ()) us_decision_clock) in
  assert (!posted = ["SPY", 9., `Sell, "bt-SPY-2025-06-25"]);
  assert (contains output "symbol=QQQ note=overnight entry skipped");
  assert (contains output "symbol=QQQ provisional-close=100 target=-1.5 held=-3 order=skip:overnight entry skipped")

let test_us_short_entry_guard () =
  (* A daily short file has no exit machinery, but its entry still runs the
     open-orders guard: an outstanding order freezes the symbol, a settled one
     lets the entry through. *)
  let run lookups =
    let broker_events = ref [] in
    let broker, _ = us_overnight_broker ~events:broker_events ~held:(-3.) ~lookups
      ~open_orders:(fun _ -> [us_listed "-" "accepted"])
      ~now:"2025-06-25T15:46:00-04:00" () in
    let decided = ref None in
    let _, output = us_overnight_step ~overnight:false broker us_decision_clock
      ~decide:(fun ~frozen _ ->
        let () = decided := Some frozen in
        us_pair_decision [|Live.Skip "no trade"|])
      ~execute:(fun _ _ _ -> ()) in
    List.rev !broker_events, !decided, output
  in
  let broker_events, decided, _ = run ["canceled"] in
  assert (broker_events = ["open:QQQ"; "cancel:-"; "sleep:15";
    "order:-:canceled"; "position:QQQ:-3"]);
  assert (decided = Some []);
  let broker_events, decided, output = run accepted_forever in
  assert (not (List.exists (fun e -> contains e "position:") broker_events));
  assert (decided = Some ["QQQ"]);
  assert (contains output "note=overnight exit outstanding");
  (* A failing listing blocks that symbol only. *)
  let broker_events = ref [] in
  let broker, _ = us_overnight_broker ~events:broker_events
    ~open_orders:(fun symbol -> if symbol = "SPY" then failwith "SPY orders unavailable" else [])
    ~now:"2025-06-25T15:46:00-04:00" () in
  let decided = ref None in
  let _, output = us_overnight_step ~symbols:[|"SPY"; "QQQ"|] ~overnight:false broker
    us_decision_clock
    ~decide:(fun ~frozen _ -> let () = decided := Some frozen in us_pair_decision [||])
    ~execute:(fun _ _ _ -> ()) in
  assert (!decided = Some ["SPY"]);
  assert (List.rev !broker_events = ["open:SPY"; "open:QQQ"; "position:QQQ:0"]);
  assert (contains output "symbol=SPY error=Failure(\"SPY orders unavailable\") order=skip")
```

Register them after `  let () = test_us_closes_before_opens () in` (added in Task 3 after `test/test_bt.ml:10427`):

```ocaml
  let () = test_us_overnight_exit_gate () in
  let () = test_us_overnight_morning_step () in
  let () = test_us_overnight_late_exit () in
  let () = test_us_overnight_frozen_entry () in
  let () = test_us_short_entry_guard () in
```

In `test_short_cli_errors`, delete the Task 3 block (from `  (* The overnight daemon is not wired yet: a US overnight file stops before` through `    ["target"; "live"]`) so the function ends with the `duplicate overnight declaration` invocation:

```ocaml
  invoke "stock \"us/SPY\"\novernight\novernight\ntarget 1\n" "run"
    ["--capital"; "1"]
    (fun path -> path ^ ": duplicate overnight declaration")
```

Fake shapes used by every case: a listed or submitted order's Alpaca id is `broker:` plus its client id, so the fake can tell an entry from an exit. `us_overnight_broker` records each broker call as `list:AFTER`, `open:SYMBOL`, `position:SYMBOL:QTY`, `post:SIDE:QTY:ID`, `cancel:CLIENT-ID`, `order:CLIENT-ID:STATUS` (lookup by Alpaca id), `lookup:CLIENT-ID:STATUS` (lookup by client id), `clock:TIMESTAMP` (only when the `clocks` queue supplies it; an empty queue returns `now` silently), `sleep:SECONDS` into `events`. `lookups` feeds both `order` and `lookup` in call order (`"none"` is `None`; running out fails the test); `clocks` is a queue of timestamps; `submit` returns a `submitted` status order (default `filled`); `held` is the position, moved by any `filled` read through `order`, `lookup`, or `submit`: an exit, orphan, or late id flattens it, an entry id sets it to `entry_fill` (default -3); a listed status is history and does not move it. `open_orders` is a closure per symbol; `us_listed ?qty` carries the requested quantity (default 3); `session_close` returns the epoch of `2025-06-24T16:00:00-04:00`. `us_overnight_step` runs `Live.us_step ~broker ~overnight` with the given `Alpaca.clock_t` and records `sleep-until:TIMESTAMP`, `retry`, and `continue`. The three clocks are `us_evening` (`2025-06-24T16:05:00-04:00`, closed, next open `2025-06-25T09:30:00-04:00`), `us_morning` (`2025-06-25T09:35:00-04:00`, open, next close `2025-06-25T16:00:00-04:00`) and `us_decision_clock` (`15:45:00-04:00`, open); the Monday case builds its own (`2025-06-23T09:35:00-04:00`, next close the same Monday at 16:00, next open Tuesday 09:30). `accepted_forever` is twenty `accepted` responses, the settle bound.

Per POST site, the cases that pin the invariant: evening gate: an exit already queued is left alone, an entry still accepted after 20 polls is `outstanding` with no exit POST, an entry that fills during the follow or the cancel moves the position to -3 and the cover for exactly that quantity follows; morning step: a `stopped` exit before 09:50 waits, an exit still accepted after 20 polls at 09:50 is `outstanding` with no resubmission, a fully filled exit posts nothing even when the positions read lags, a 3-of-4 fill posts the `min` of the held and unfilled quantities; late close: an open `-cover` is settled before `-late`, an exit still accepted after 20 polls blocks the late close and freezes the entry, an existing open `-late` is followed and then guarded, a filled `-late` with another order outstanding skips the entry, a symbol whose pass raises is blocked while the other continues, a morning `-exit` on a long of 5 that fills during the settle while the positions read lags at 5 posts no `-late` and keeps the symbol blocked, a cover of 3 filled 2 then canceled with the position read at -1 posts a 1-share `-late`, a two-symbol wait cap at 15:46 (12 minutes left over two symbols, so 3 minutes, 12 polls) blocks SPY after 12 polls and still posts QQQ's late close, a four-symbol restart at 15:55 with a clock advancing 15 seconds per sleep posts all four late closes at 0, 45, 90, and 135 seconds (the budget is recomputed from the clock per symbol); entry of a daily `short` file (`test_us_short_entry_guard`): a settled open order lets the entry through, one still accepted after 20 polls freezes the symbol, a failing listing blocks that symbol only. `test_us_overnight_frozen_entry` pins the engine freeze under `rebalance daily`: cash 500 holding a QQQ short of 3 at 100 (reserve 450, equity 200), targets SPY -0.9 at 10 and QQQ -1.5; thawed, QQQ covers 100 (one share) and the released reserve funds a 170 SPY open; frozen, QQQ's trade is zero and SPY opens 90 (9 shares), the only POST.

- [ ] **Step 2: Run the build to verify it fails**

Run: `dune build --root . 2>&1 | head -20`
Expected: `The function applied to this argument has type ... cannot be applied with label ~broker` (or `Unbound type constructor Live.overnight_broker`).

- [ ] **Step 3: Add the machinery**

In `broker/live.ml`, insert after `retry_clock` (after line 1116, before `let us_step`):

```ocaml
type overnight_broker = {
  list_orders : after:string -> Alpaca.listed_t list;
  open_orders : string -> Alpaca.listed_t list;
  position : string -> float;
  submit :
    symbol:string -> qty:float -> side:[`Buy | `Sell] -> id:string ->
    Alpaca.order_t;
  cancel : string -> unit;
  order : string -> Alpaca.order_t option;
  lookup : string -> Alpaca.order_t option;
  clock : unit -> Alpaca.clock_t;
  session_close : string -> int;
  sleep : float -> unit;
}

type series = {
  series_date : string;
  exits : int;
  orphan : bool;
  series_id : string;
  qty : float;
  latest : Alpaca.order_t;
}

type settled = Final of Alpaca.order_t | Outstanding of Alpaca.order_t

let final_order_status = function
  | "filled" | "canceled" | "expired" | "rejected" -> true
  | _ -> false

let suffix_number suffix kind =
  let length = String.length kind in
  if suffix = kind then Some 1
  else if String.length suffix > length && String.sub suffix 0 length = kind
  then int_of_string_opt (String.sub suffix length (String.length suffix - length))
  else None

let series_of_order ~symbol (item : Alpaca.listed_t) =
  let prefix = "bt-" ^ symbol ^ "-" in
  let start = String.length prefix in
  let id = item.client_order_id in
  if String.length id < start + 10 || String.sub id 0 start <> prefix then None
  else
    let series_date = String.sub id start 10 in
    let suffix = String.sub id (start + 10) (String.length id - start - 10) in
    let make exits orphan =
      Some { series_date; exits; orphan; series_id = id; qty = item.qty;
             latest = item.order } in
    match suffix with
    | "" | "-late" -> make 0 false
    | _ ->
        match suffix_number suffix "-cover", suffix_number suffix "-exit",
              suffix_number suffix "-orphan" with
        | Some exits, _, _ | _, Some exits, _ -> make exits false
        | None, None, Some exits -> make exits true
        | None, None, None -> None

let exit_id ~symbol ~date ~held ~orphan number =
  Printf.sprintf "%s-%s%s" (client_order_id ~symbol ~date)
    (if orphan then "orphan" else if held < 0. then "cover" else "exit")
    (if number = 1 then "" else string_of_int number)

let follow broker ~polls (order : Alpaca.order_t) =
  let rec loop polls (order : Alpaca.order_t) =
    if final_order_status order.status || polls <= 0 then order
    else
      let () = broker.sleep 15. in
      loop (polls - 1)
        (match broker.order order.id with
         | Some current -> current
         | None -> order)
  in
  loop polls order

let settle broker (order : Alpaca.order_t) =
  if final_order_status order.status then Final order
  else
    let () = broker.cancel order.id in
    let settled = follow broker ~polls:20 order in
    if final_order_status settled.status then Final settled
    else Outstanding settled

let clear_open broker ~today ~symbol =
  let items = broker.open_orders symbol in
  let settled =
    List.map (fun (item : Alpaca.listed_t) ->
      let settled = settle broker item.order in
      let () = log_fill today symbol item.client_order_id
        (Some (match settled with Final order | Outstanding order -> order)) in
      settled) items
  in
  if List.exists (function Outstanding _ -> true | Final _ -> false) settled then
    let () = log "date=%s symbol=%s note=overnight exit outstanding" today symbol in
    None
  else
    let position = broker.position symbol in
    (* What the closing orders settled here left unfilled caps a late close,
       so a positions read lagging their fills cannot close twice; [None]
       when no closing order was settled. *)
    let closing_side = if position < 0. then "buy" else "sell" in
    let unfilled =
      List.fold_left2 (fun unfilled (item : Alpaca.listed_t) settled ->
        match settled with
        | Final (order : Alpaca.order_t) when order.side = closing_side ->
            Some (Option.value unfilled ~default:0. +. item.qty -. order.filled_qty)
        | Final _ | Outstanding _ -> unfilled) None items settled
    in
    Some (position, unfilled)

let drive_exit broker ~today ~symbol ~deadline series =
  let now () = rfc3339_seconds (broker.clock ()).timestamp in
  (* [bound] caps a remainder at what the previous exit left unfilled, so a
     positions read that lags its fill cannot double the exit. *)
  let post ~date ~orphan ~bound number =
    if bound <= 0. then None
    else match Option.map fst (clear_open broker ~today ~symbol) with
    | None -> None
    | Some held when held = 0. -> None
    | Some _ when number > 4 ->
        let () = log "date=%s symbol=%s note=overnight exit unfilled" today symbol in
        None
    | Some held ->
        let qty = Float.min (abs_float held) bound in
        let side = if held < 0. then `Buy else `Sell in
        let id = exit_id ~symbol ~date ~held ~orphan number in
        let latest = broker.submit ~symbol ~qty ~side ~id in
        let () = log "date=%s symbol=%s held=%.10g order=%s fill=pending" today symbol
          held (order_description (Order { side; qty; id })) in
        Some { series_date = date; exits = number; orphan; series_id = id; qty; latest }
  in
  let rec step series =
    if series.exits = 0 then
      (* An entry or late close is followed to its session's close plus 5
         minutes; whatever is still open is settled before the exit. *)
      let () =
        if not (final_order_status series.latest.status) then
          let deadline = broker.session_close series.series_date + (5 * 60) in
          let polls = (deadline - now () + 14) / 15 in
          log_fill today symbol series.series_id
            (Some (follow broker ~polls series.latest))
      in
      after_post (post ~date:series.series_date ~orphan:false ~bound:Float.infinity 1)
    else if final_order_status series.latest.status then
      (* Filled or not, a final exit leaves whatever is still held, up to
         its own unfilled part, to the next number of the series. *)
      let () = log_fill today symbol series.series_id (Some series.latest) in
      after_post (post ~date:series.series_date ~orphan:series.orphan
        ~bound:(series.qty -. series.latest.filled_qty) (series.exits + 1))
    else
      match deadline with
      | None ->
          log "date=%s symbol=%s order=existing:%s fill=pending" today symbol
            series.series_id
      | Some deadline ->
          if now () < deadline then
            let () = broker.sleep 60. in
            let latest = match broker.order series.latest.id with
              | Some current -> current
              | None -> series.latest in
            step { series with latest }
          else
            match settle broker series.latest with
            | Final latest -> step { series with latest }
            | Outstanding latest ->
                let () = log_fill today symbol series.series_id (Some latest) in
                log "date=%s symbol=%s note=overnight exit outstanding" today symbol
  and after_post = function
    | None -> ()
    | Some series ->
        match deadline with
        | None -> ()
        | Some deadline ->
            if now () < deadline then step series
            else
              (* A resubmission past the deadline gets a 2-minute grace
                 period before it is settled. *)
              step { series with latest = follow broker ~polls:8 series.latest }
  in
  match series with
  | Some series -> step series
  | None ->
      if broker.position symbol <> 0. then
        let () = log "date=%s symbol=%s note=overnight position without entry"
          today symbol in
        after_post (post ~date:today ~orphan:true ~bound:Float.infinity 1)

let overnight_exits broker ~symbols ~today ~after ~deadline =
  let listed = broker.list_orders ~after in
  Array.iter (fun symbol ->
    match
      drive_exit broker ~today ~symbol ~deadline
        (List.find_map (series_of_order ~symbol) listed)
    with
    | () -> ()
    | exception error ->
        log "date=%s symbol=%s error=%s order=skip" today symbol
          (Printexc.to_string error)) symbols

let late_exit broker ~date ~next_close symbols =
  let cutoff = rfc3339_seconds next_close - (2 * 60) in
  let open_window (c : Alpaca.clock_t) =
    c.is_open && next_actions ~now:c.timestamp ~next_close = `Decide in
  let window () = open_window (broker.clock ()) in
  (* One clock read per symbol gives both the window check before its POST
     and its wait budget: 3 minutes, or the window left on that clock divided
     by the symbols still to process, so every symbol gets its late close
     submitted before the cutoff. *)
  let budget remaining (c : Alpaca.clock_t) =
    let left = cutoff - rfc3339_seconds c.timestamp in
    Int.min (3 * 60) (left / remaining) / 15
  in
  let rec run remaining blocked = function
    | [] -> List.rev blocked
    | symbol :: rest ->
        let id = client_order_id ~symbol ~date ^ "-late" in
        let rec wait polls (order : Alpaca.order_t) =
          if order.status = "filled" then
            let () = log_fill date symbol id (Some order) in
            not (broker.position symbol = 0. && window ())
          else if terminal_order_status order.status then
            let () = log_fill date symbol id (Some order) in true
          else if polls <= 0 || not (window ()) then true
          else
            let () = broker.sleep 15. in
            wait (polls - 1)
              (match broker.order order.id with
               | Some current -> current
               | None -> order)
        in
        let close () =
          match broker.lookup id with
          | Some order ->
              (* The day's close already exists: follow it, then run the
                 guard over the symbol's other orders before the entry. *)
              wait (budget remaining (broker.clock ())) order
              || (match clear_open broker ~today:date ~symbol with
                  | Some (held, _) -> held <> 0. || not (window ())
                  | None -> true)
          | None ->
              match clear_open broker ~today:date ~symbol with
              | None -> true
              | Some (held, unfilled) ->
                  let qty = match unfilled with
                    | Some unfilled -> Float.min (abs_float held) unfilled
                    | None -> abs_float held in
                  if held = 0. then false
                  else if qty <= 0. then true
                  else
                    let c = broker.clock () in
                    if not (open_window c) then true
                    else
                      let side = if held < 0. then `Buy else `Sell in
                      let () = log "date=%s symbol=%s note=overnight position closed late"
                        date symbol in
                      let order = broker.submit ~symbol ~qty ~side ~id in
                      let () = log "date=%s symbol=%s held=%.10g order=%s fill=pending" date
                        symbol held (order_description (Order { side; qty; id })) in
                      wait (budget remaining c) order
        in
        let is_blocked =
          match close () with
          | is_blocked -> is_blocked
          | exception error ->
              let () = log "date=%s symbol=%s error=%s order=skip" date symbol
                (Printexc.to_string error) in
              true
        in
        let () = if is_blocked then
          log "date=%s symbol=%s note=overnight entry skipped" date symbol in
        run (remaining - 1) (if is_blocked then symbol :: blocked else blocked) rest
  in
  run (List.length symbols) [] symbols

let week_before timestamp = shift_rfc3339 timestamp (-7 * 24 * 60 * 60)

let session_seconds (clock : Alpaca.clock_t) time =
  let start = timezone_start clock.timestamp in
  rfc3339_seconds
    (date_prefix clock.timestamp ^ "T" ^ time
     ^ String.sub clock.timestamp start (String.length clock.timestamp - start))

let session_close_of mode date =
  match Alpaca.calendar mode ~start:date ~end_:date with
  | [session] ->
      let offset = Data.et_offset_minutes date in
      rfc3339_seconds
        (Printf.sprintf "%sT%s:00%c%02d:%02d" date session.close
           (if offset < 0 then '-' else '+') (abs offset / 60) (abs offset mod 60))
  | _ -> failwith ("Alpaca calendar has no session on " ^ date)
```

`final_order_status` is narrower than `terminal_order_status` (which keeps `stopped` for the sell barrier and fill logging). `late_exit` uses `terminal_order_status` on purpose: a `stopped` late close counts as not closed. `clear_open` is the POST invariant and is the only place that calls `settle` on open orders; `drive_exit` calls `settle` directly only on the series' own latest exit at the 09:50 deadline. `session_close_of` turns the calendar's `HH:MM` close into an epoch second with the date's ET offset.

- [ ] **Step 4: Route the three steps in `us_step`**

Replace `us_step` (`broker/live.ml:1118-1163`, from `let us_step ~symbols ~lookup ~decide ~execute ~finish ~sleep_until ~retry` through `            retry ()`) with:

```ocaml
let us_step ?broker ?(overnight = false) ~symbols ~lookup ~decide ~execute ~finish
    ~sleep_until ~retry ~continue (clock : Alpaca.clock_t) =
  let date = timestamp_date clock.timestamp in
  let after_exits ~deadline next =
    match broker with
    | Some broker when overnight ->
        (match overnight_exits broker ~symbols ~today:date
           ~after:(week_before clock.timestamp) ~deadline with
         | () -> next ()
         | exception error ->
             let () = log "date=%s error=%s order=retry" date (Printexc.to_string error) in
             retry ())
    | Some _ | None -> next ()
  in
  let wake = if overnight then shift_rfc3339 clock.next_close (5 * 60) else clock.next_open in
  if not clock.is_open then
    after_exits ~deadline:None (fun () ->
      let () = sleep_until (if overnight then shift_rfc3339 clock.next_open (5 * 60)
        else clock.next_open) in
      continue ())
  else match next_actions ~now:clock.timestamp ~next_close:clock.next_close with
  | `Sleep_until timestamp ->
      after_exits ~deadline:(Some (session_seconds clock "09:50:00")) (fun () ->
        let () = sleep_until timestamp in continue ())
  | `Post_close -> let () = sleep_until wake in continue ()
  | (`Decide | `Cutoff_passed as phase) ->
      let existing = ref [] in
      let end_day () = let () = sleep_until wake in continue () in
      let reconcile () = List.iter (fun (symbol, order) ->
        try finish clock date (client_order_id ~symbol ~date) order with error ->
          (try log "date=%s symbol=%s error=%s order=skip"
            date symbol (Printexc.to_string error) with _ -> ())) (List.rev !existing) in
      match
        let () = Array.iter (fun symbol ->
          let id = client_order_id ~symbol ~date in
          match lookup id with
          | None -> ()
          | Some order ->
              let () = existing := (symbol, order) :: !existing in
              log "date=%s symbol=%s order=existing:%s fill=pending" date symbol id) symbols in
        let () = if phase = `Cutoff_passed
          && List.length !existing <> Array.length symbols then
          log "date=%s error=submit cutoff passed order=skip" date in
        if List.length !existing = Array.length symbols || phase = `Cutoff_passed then
          let () = reconcile () in `End
        else
          (* Before the entry: settle every open order of the symbol, close a
             held overnight position, and freeze what is not flat. *)
          let pending = List.filter (fun symbol -> not (List.mem_assoc symbol !existing))
            (Array.to_list symbols) in
          let frozen = match broker with
            | None -> []
            | Some broker when overnight ->
                late_exit broker ~date ~next_close:clock.next_close pending
            | Some broker ->
                List.filter (fun symbol ->
                  match clear_open broker ~today:date ~symbol with
                  | Some _ -> false
                  | None -> true
                  | exception error ->
                      let () = log "date=%s symbol=%s error=%s order=skip" date symbol
                        (Printexc.to_string error) in
                      true) pending in
          let decision = decide ~frozen date in
          let decision = { decision with assets = Array.map (fun (a : asset_decision) ->
            if List.mem_assoc a.symbol !existing then { a with action = Skip "existing order" }
            else a) decision.assets } in
          let () = execute (List.rev !existing) clock decision in
          `End
      with
      | `End -> end_day ()
      | exception error ->
          if phase = `Cutoff_passed then
            let () = (try log "date=%s error=%s order=skip" date
              (Printexc.to_string error) with _ -> ()) in
            let () = reconcile () in
            end_day ()
          else
            let () = log "date=%s error=%s order=retry" date (Printexc.to_string error) in
            retry ()
```

Without `?broker` every branch is the old code: `wake` is `clock.next_open`, `after_exits` calls `next ()` directly, and `frozen` is `[]`; `decide ~frozen:[] date` is the old call.

- [ ] **Step 5: Wire the broker in `run_us` and `run`**

Replace `run_us` (from `let run_us mode ~symbols ~strat_path ~data_dir ~rebalance_choice ~short =` through `  cycle ()`) with:

```ocaml
let run_us mode ~symbols ~strat_path ~data_dir ~rebalance_choice ~short ~overnight =
  let account = Alpaca.account mode in
  let () =
    match startup_ok account with
    | Ok () -> ()
    | Error reason -> failwith reason
  in
  log "startup mode=%s account=%s equity=%.10g initial-margin=%.10g shorting-enabled=%b"
    (mode_name mode) account.account_number account.equity
    account.initial_margin account.shorting_enabled;
  let () = log_rebalance_warning strat_path rebalance_choice in
  let () = if short then Array.iter (fun symbol ->
    match shortable_ok symbol (Alpaca.asset mode symbol) with
    | Ok () -> ()
    | Error reason -> failwith reason) symbols in
  let broker = if not (short || overnight) then None else Some
    { list_orders = (fun ~after ->
        Alpaca.list_orders mode ~symbols:(Array.to_list symbols) ~after);
      open_orders = Alpaca.open_orders mode;
      position = Alpaca.position_qty mode;
      submit = (fun ~symbol ~qty ~side ~id ->
        Alpaca.submit_market mode ~symbol ~qty ~side ~client_order_id:id);
      cancel = Alpaca.cancel_order mode;
      order = Alpaca.order_by_id mode;
      lookup = Alpaca.order_by_client_id mode;
      clock = (fun () -> Alpaca.clock mode);
      session_close = session_close_of mode;
      sleep = Unix.sleepf } in
  let rec cycle () =
    match Alpaca.clock mode with
    | exception error ->
        log "date=unknown error=%s order=retry"
          (Printexc.to_string error);
        retry_clock ~clock:(fun () -> Alpaca.clock mode) ~sleep:Unix.sleepf
          ~dispatch:step
    | clock -> step clock
  and step clock =
    us_step ?broker ~overnight ~symbols ~lookup:(Alpaca.order_by_client_id mode)
      ~decide:(fun ~frozen date ->
        decide ~frozen mode ~session_date:date ~strat_path ~data_dir)
      ~execute:(fun existing clock decision ->
        execute_decision ~existing mode (timestamp_date clock.timestamp)
          clock.next_close decision)
      ~finish:(fun clock date id order ->
        let symbol = Array.find_opt (fun symbol ->
          client_order_id ~symbol ~date = id) symbols |> Option.get in
        finish_order mode clock.next_close date symbol id order)
      ~sleep_until
      ~retry:(fun () ->
        retry_clock ~clock:(fun () -> Alpaca.clock mode) ~sleep:Unix.sleepf ~dispatch:step)
      ~continue:cycle clock
  in
  cycle ()
```

Replace `run` (from `let run ?equity mode ~strat_path ~data_dir =` to the end of the file) with:

```ocaml
let run ?equity mode ~strat_path ~data_dir =
  let ast = Dsl.parse_file strat_path in
  let rebalance_choice = Dsl.rebalance_of ~filename:strat_path ast in
  let short = Dsl.short_of ~filename:strat_path ast in
  let overnight = Dsl.overnight_of ~filename:strat_path ast in
  let directory =
    match Sys.getenv_opt "HOME" with
    | Some home when home <> "" -> Filename.concat home ".bt"
    | _ -> failwith "HOME must be set to run bt live"
  in
  let stocks = Dsl.stocks_of ~filename:strat_path ast in
  let market = strategy_market stocks in
  let symbols = Array.of_list (List.map (fun (_, _, s) -> s) stocks) in
  match market with
  | "us" ->
      let fd = lock_daemon ~directory ~market:"us" mode in
      Fun.protect ~finally:(fun () -> Unix.close fd)
        (fun () ->
          run_us mode ~symbols ~strat_path ~data_dir ~rebalance_choice ~short ~overnight)
  | "tw" ->
      let fd = lock_daemon ~directory ~market:"tw" mode in
      Fun.protect ~finally:(fun () -> Unix.close fd)
        (fun () -> run_tw mode ~equity ~symbols ~strat_path ~data_dir ~rebalance_choice)
  | _ -> failwith "live trading supports us and tw only"
```

- [ ] **Step 6: Mirror the interface**

In `broker/live.mli`, replace the whole `val us_step` block with its comment (lines 197-205, from `(** Advance one US daemon clock with injected broker and scheduling actions. *)` through `  continue:(unit -> unit) -> Alpaca.clock_t -> unit`) with:

```ocaml
(** Broker actions of the short and overnight entry and exit machinery,
    injected for tests. [order] finds an order by its Alpaca id, [lookup] by
    its client id; [session_close] gives the epoch second of a date's close. *)
type overnight_broker = {
  list_orders : after:string -> Alpaca.listed_t list;
  open_orders : string -> Alpaca.listed_t list;
  position : string -> float;
  submit :
    symbol:string -> qty:float -> side:[`Buy | `Sell] -> id:string ->
    Alpaca.order_t;
  cancel : string -> unit;
  order : string -> Alpaca.order_t option;
  lookup : string -> Alpaca.order_t option;
  clock : unit -> Alpaca.clock_t;
  session_close : string -> int;
  sleep : float -> unit;
}

(** The latest [bt-SYMBOL-] order of a symbol: its date, its place in the
    exit series ([0] for the entry or a late close, [n] for the n-th exit),
    whether the series is an entry-less [-orphan] one, its client id, its
    requested quantity, and the order as last read. *)
type series = {
  series_date : string;
  exits : int;
  orphan : bool;
  series_id : string;
  qty : float;
  latest : Alpaca.order_t;
}

(** Outcome of the settle step: a final order, or one still outstanding
    after the bounded poll. *)
type settled = Final of Alpaca.order_t | Outstanding of Alpaca.order_t

(** Statuses Alpaca's lifecycle marks as receiving no further updates;
    narrower than [terminal_order_status], which also treats [stopped] as
    done for fill logging. *)
val final_order_status : string -> bool

(** Classify one listed order of [symbol] by its client id, or [None] for an
    id outside bt's series. *)
val series_of_order : symbol:string -> Alpaca.listed_t -> series option

(** The [number]-th exit id of a series: [-cover] for a short holding,
    [-exit] for a long, [-orphan] for an entry-less position, numbered from
    the second one. *)
val exit_id :
  symbol:string -> date:string -> held:float -> orphan:bool -> int -> string

(** Re-read an order by its Alpaca id every 15 seconds, at most [polls]
    times, until its status is final. *)
val follow : overnight_broker -> polls:int -> Alpaca.order_t -> Alpaca.order_t

(** Cancel a nonfinal order and poll it every 15 seconds for at most 5
    minutes; a fill during the cancel is a fill, and a final order is
    returned as is without a cancel. Neither a 422 on the cancel nor the
    timeout proves a final state: the timeout is [Outstanding]. *)
val settle : overnight_broker -> Alpaca.order_t -> settled

(** The guard before every POST on [symbol]: list its open orders whatever
    their client ids, settle each, and return the position read afterwards
    with what the settled orders on the closing side left unfilled ([None]
    when none was settled), so a caller can size against a lagging
    positions read; [None] after logging
    [overnight exit outstanding] when any order is still outstanding, so the
    caller places nothing for the symbol. *)
val clear_open :
  overnight_broker -> today:string -> symbol:string -> (float * float option) option

(** Drive one symbol's series: follow a nonfinal entry or late close to its
    session close plus 5 minutes and exit what is held; after a final exit,
    exit whatever is still held, capped at that exit's unfilled quantity,
    under the next number (at most three resubmissions, then
    [overnight exit unfilled]); re-check an outstanding
    exit every 60 seconds until [deadline], settle it there and resubmit;
    without a deadline leave it queued. A resubmission past the deadline is
    followed for 2 minutes before it is settled. Every POST goes through
    [clear_open]. [None] with a held position logs
    [overnight position without entry] and exits under [today]'s [-orphan]
    ids. *)
val drive_exit :
  overnight_broker -> today:string -> symbol:string -> deadline:int option ->
  series option -> unit

(** List the [bt-SYMBOL-] orders since [after] and drive every symbol's
    latest series; a symbol's failure is logged and the others continue. *)
val overnight_exits :
  overnight_broker -> symbols:string array -> today:string -> after:string ->
  deadline:int option -> unit

(** Close every held symbol under [bt-SYMBOL-DATE-late] before the entry
    decision, each after [clear_open] and a clock check (an existing close is
    followed and then guarded the same way), sized as the position capped at
    what the guard's closing orders left unfilled, and return the symbols
    still blocked: an outstanding open order, a close not [filled] with a
    flat position while the submit window is open, a position the guard's
    fills already cover until a read confirms it flat, a wait past its cap
    (3 minutes or the window left on the broker clock over the symbols
    still to process), or a symbol whose pass raised, which is logged. *)
val late_exit :
  overnight_broker -> date:string -> next_close:string -> string list ->
  string list

(** Advance one US daemon clock with injected broker and scheduling actions.
    With [broker], the decision first runs [clear_open] (and, with
    [overnight], [late_exit]) for every symbol without an existing entry and
    passes the blocked symbols to [decide] as [frozen]. With [overnight], a
    closed clock runs the post-close exit gate and sleeps to the open plus 5
    minutes, the pre-decision open phase runs the 09:35 step with its 09:50
    deadline, and the day ends at the close plus 5 minutes. *)
val us_step :
  ?broker:overnight_broker ->
  ?overnight:bool ->
  symbols:string array ->
  lookup:(string -> Alpaca.order_t option) ->
  decide:(frozen:string list -> string -> decision) ->
  execute:((string * Alpaca.order_t) list -> Alpaca.clock_t -> decision -> unit) ->
  finish:(Alpaca.clock_t -> string -> string -> Alpaca.order_t -> unit) ->
  sleep_until:(string -> unit) -> retry:(unit -> unit) ->
  continue:(unit -> unit) -> Alpaca.clock_t -> unit
```

Then insert after `val timestamp_date : string -> string` (line 208):

```ocaml
(** Epoch seconds of an RFC3339 timestamp with a numeric offset or [Z]. *)
val rfc3339_seconds : string -> int
```

- [ ] **Step 7: Remove the guard**

In `bin/bt.ml` `live_command_args`, replace from `  let rebalance = Dsl.rebalance_of ~filename:strat_path ast in` through the `in` that closes the `overnight` guard (the Task 3 text) with:

```ocaml
  let rebalance = Dsl.rebalance_of ~filename:strat_path ast in
  let () = ignore (Dsl.short_of ~filename:strat_path ast) in
  let () = ignore (Dsl.overnight_of ~filename:strat_path ast) in
  let () =
    if List.exists (function Ast.Bars _ -> true | _ -> false) ast then
      failwith "day trading strategies run under bt daytrade"
  in
```

- [ ] **Step 8: Build and run the tests**

Run: `dune build --root . 2>&1` then `dune build --root . @runtest --force 2>&1 | tail -3`
Expected: the build prints nothing; the runner's last line is `ok`. The existing `test_us_step_routing`, `test_us_pair_restart_routing`, and `test_us_open_sell_restart_end_to_end` still pass unchanged, which pins the non-overnight routing.

- [ ] **Step 9: Commit**

Commit only after the coordinator confirms; use the co-author trailer the coordinator names; never push; never change git settings.

```bash
git add broker/live.ml broker/live.mli bin/bt.ml test/test_bt.ml
git commit -m "feat: overnight exit gate, 09:35 step, late exit, and the open-orders guard for US live"
```

### Task 5: Docs and changelog

**Files:**
- Modify: `docs/cli.md:258-269` (Strategy validation table), `docs/cli.md:297-305` (bt target US Decision cycle), `docs/cli.md:319-330` (bt target US Failure handling table), `docs/cli.md:475-485` (bt live US Prerequisites), `docs/cli.md:497-506` (bt live US Decision cycle table), `docs/cli.md:512-521` (Output and logs), `docs/cli.md:529-536` (the sell-phase stop table)
- Modify: `docs/specs/live-trading.md:76-77` (Daily cycle notes)
- Modify: `CHANGELOG.md:13` (the overnight entry) and a new `Added` entry after it

**Interfaces:**
- Consumes: the messages and log lines of Tasks 2-4.
- Produces: documentation only.

- [ ] **Step 1: Update `docs/cli.md`**

In the Strategy validation table (lines 262-270), delete the table row whose first cell is `short and overnight are not supported by bt target and bt live yet` (the row added by stage 1).

In the bt target US Decision cycle (after the paragraph that starts `The command nets each symbol's planned ordinary buys and sells into one order for that symbol.`, line 305), insert a blank line and this paragraph:

```markdown
In a strategy that declares `short`, a negative Alpaca quantity is the short leg: its value at the provisional close is the short exposure, and `(1 + 0.5)` times that value of the account cash is reserved, as the backtest does. The planner's short open and cover join the net: a short entry or add is a whole-share `sell`, a cover is a `buy` of the whole shares planned, and a cover to zero buys the whole held quantity. A sign flip never trades both legs in one session: the decision closes the held leg only (every held share, fractional for a long), and the next decision opens the new leg from the flat position, also under `rebalance on_change`, because the held exposure of that symbol replaces its previous target whenever their signs differ. A strategy without `short` keeps every target at or above 0 and rejects an account that holds a short.
```

In the bt target US Failure handling table (lines 323-330), replace the three rows whose first cells are `US account holds a short position`, `US account holds unsupported symbol SYMBOL`, and `US account holds other symbols` with these four rows:

```markdown
| `US account holds a short position` | The strategy does not declare `short`, and `short_market_value` is not 0 or a held quantity is negative. |
| `US account holds a short outside the strategy` | The strategy declares `short`, `short_market_value` is not 0, and no strategy symbol is held short. |
| `US account holds unsupported symbol SYMBOL` | An open position in Alpaca's positions list has a symbol outside the strategy. The check applies to one-stock strategies too. |
| `US account holds other symbols` | `long_market_value` is not finite, or differs from the sum of every long holding at its provisional close by more than 1% of `long_market_value`; or `short_market_value` is not finite, or its negation differs from the sum of every short holding at its provisional close by more than 1% of that negation. |
```

In the bt live US Prerequisites (line 477), replace the paragraph `The strategy must declare one or more distinct US stocks, and the account may hold only those symbols. The selected Alpaca account must be active and not trading-blocked.` with:

```markdown
The strategy must declare one or more distinct US stocks, and the account may hold only those symbols. The selected Alpaca account must be active and not trading-blocked. A strategy that declares `short` needs every symbol flagged `shortable` and `easy_to_borrow` at Alpaca; otherwise the daemon fails at startup with `SYMBOL is not shortable` or `SYMBOL is not easy to borrow`.
```

In bt live US Failure handling (lines 529-536), replace the paragraph `A sell-phase stop sends no buy and logs a session-level ...` and the `US sell-phase stop` table that follows it with:

```markdown
A close-phase stop sends no opening order and logs a session-level `error=REASON order=skip` line. Known orders still enter the finish pass. SIDE below is `sell` for a long close and `buy` for a cover.

| US close-phase stop | Result |
|---|---|
| `SIDE SYMBOL rejected` or `SIDE SYMBOL uncertain` at submission | The failed close logs `symbol=SYMBOL error=REASON order=skip`, and each other close still goes out if its pre-submit clock check passes. The first failed close names the stop, and no opening order is POSTed. |
| `submit cutoff passed` between submissions | Each close whose pre-submit clock check finds the cutoff logs `symbol=SYMBOL error=submit cutoff passed order=skip` and is not POSTed. No opening POST. |
| `SIDE SYMBOL STATE` while polling | No opening POST when STATE is `rejected`, `canceled`, `expired`, or `stopped`. A failed status lookup reports `SIDE SYMBOL uncertain`. |
| `SIDE SYMBOL open at cutoff` | No opening POST. |
```

In the bt live US Decision cycle (lines 501-506), replace the phase table (from `| Phase | Timing | Action |` through the `| Sleep |` row) with the table and paragraph below; the paragraph goes after the table and before the existing `The Submit phase ends 2 minutes before the close` paragraph, separated by blank lines:

```markdown
| Phase | Timing | Action |
|---|---|---|
| Open step (`overnight` only) | 09:35, re-checked every 60 seconds until 09:50 | List the week's `bt-SYMBOL-` orders and follow each symbol's latest exit. A final exit leaves any remainder still held, capped at that exit's unfilled quantity, to the next id of its series: a partially filled exit, a final unfilled exit, or one still open at 09:50 after the settle step is resubmitted, at most three times, then `note=overnight exit unfilled`. A resubmission at or after 09:50 is followed every 15 seconds for 2 minutes before it is settled. |
| Late exit (`overnight` only) | 15 minutes before the close, before Evaluate | Close any position still held with a `market` order under `bt-SYMBOL-DATE-late`, sized as the position capped at what the guard's closing orders left unfilled, after the open-orders guard and a clock check, and poll it every 15 seconds for at most 3 minutes (or the window left on that clock divided by the symbols still to process). A position the guard's fills already cover stays blocked until a read confirms it flat. The entry follows only once it is `filled`, the position reads flat, the guard finds no other order outstanding, and the clock still shows the submit window open; otherwise the symbol logs `note=overnight entry skipped` and is frozen: the planner keeps its holding whatever the target and `rebalance`, and sizes the other symbols around it. |
| Evaluate | 15 minutes before the close | Refresh Tiingo history and evaluate the provisional daily bar. |
| Submit | Until 2 minutes before the close | Query today's deterministic client order ID for every symbol, then submit fractional `market` orders with `time_in_force: day` where needed; a short entry is a whole-share sell. Orders that reduce a symbol's exposure (a long sell, a buy to cover) go first; orders that increase it (a long buy, a short sell) go out only after every close fills. An existing order found on a restart is classified by its side against the holding it was placed on, so a sell whose fill left the symbol flat is still a close. Without shorts that is the old sell-then-buy order. |
| Reconcile | After the close | Poll each open order every 15 seconds until it reaches a terminal status or 5 minutes pass after the close, then log its fill. |
| Exit gate (`overnight` only) | After the close plus 5 minutes, and whenever the daemon starts while the market is closed | An entry still open is followed to its session's close plus 5 minutes (from the exchange calendar, early closes included), then settled by the open-orders guard. Then queue a `market` `day` exit for the quantity held: a `buy` under `bt-SYMBOL-DATE-cover` for a short, a fractional `sell` under `bt-SYMBOL-DATE-exit` for a long. Alpaca fills it at the next opening print. |
| Sleep | After reconciliation | Sleep until the next open; under `overnight`, until the open plus 5 minutes. |

Before every order the daemon places for a `short` or `overnight` strategy (the evening exit, a morning resubmission, a late close, and the entry itself), it lists every open order of the symbol whatever its client id (`GET /v2/orders?status=open&limit=500&direction=desc&symbols=SYMBOL`, paged with `until`), runs the settle step on each, and sizes only from the position read afterwards. The settle step cancels the order and polls it every 15 seconds for at most 5 minutes until it is `filled`, `canceled`, `expired`, or `rejected`; `pending_cancel` and `stopped` are outstanding, a fill during the cancel is a fill, and a cancel that Alpaca answers with 422 (not cancelable) is followed by the same poll. An order still outstanding at the bound logs `note=overnight exit outstanding`; the symbol gets no order in that pass, the other symbols continue, and the next pass rediscovers it. Restart discovery anchors a symbol's series on the date in its latest `bt-SYMBOL-` order of the past week, entry or exit: an existing exit is verified, never resubmitted blindly, and a held strategy symbol with no such order logs `note=overnight position without entry` and is exited under today's `bt-SYMBOL-DATE-orphan`, `-orphan2`, ... ids at the next exit point, so the day's entry series stays free.
```

In Output and logs (lines 514-521), replace from `Each daemon line starts with a UTC timestamp` through the paragraph that ends with `fill-price`, and `filled-qty`. with (the block contains its own `text` fence, so it is shown inside a four-backtick fence):

````markdown
Each daemon line starts with a UTC timestamp in `YYYY-MM-DDTHH:MM:SSZ` format. The `startup` line records the selected `mode`, `account` number, `equity`, Alpaca's `initial-margin`, and `shorting-enabled`; sizing uses bt's profile, not those two fields. Each decision logs one account line, followed by one line per symbol:

```text
date=DATE fetched-through=DATE equity=VALUE cash=VALUE debit=VALUE
date=DATE symbol=SYMBOL provisional-close=VALUE target=VALUE held=VALUE order=ORDER fill=pending
```

ORDER holds the deterministic order as `SIDE:QUANTITY:CLIENT-ORDER-ID` or the skip reason as `skip:REASON`. An all-unchanged on_change session logs only the account line, ending in `order=skip:target unchanged`. Existing-order, fill, and per-order error lines include `symbol=SYMBOL`. Entry client order IDs remain `bt-SYMBOL-DATE`. Fill lines record `client-order-id`, `fill-status`, `fill-price`, and `filled-qty`.

Under `overnight`, the exit gate, the open step, and the late exit log each order they place as `date=DATE symbol=SYMBOL held=VALUE order=SIDE:QUANTITY:CLIENT-ORDER-ID fill=pending`, where the id is `bt-SYMBOL-DATE-cover` or `bt-SYMBOL-DATE-exit` for the first exit of the entry dated DATE, `-cover2`, `-cover3`, `-cover4` (or `-exit2` and so on) for its resubmissions, `bt-SYMBOL-DATE-orphan`, `-orphan2`, ... for an entry-less position found on DATE, and `bt-SYMBOL-DATE-late` for a late close. Their fills, and every order the open-orders guard settles, log as fill lines. An exit left queued after the close logs `order=existing:CLIENT-ORDER-ID fill=pending`. The cycle's own events log with a `note` field:

| Line | Meaning |
|---|---|
| `date=DATE symbol=SYMBOL note=overnight exit unfilled` | The fourth exit of the series ended with a remainder; the position waits for the late exit. |
| `date=DATE symbol=SYMBOL note=overnight exit outstanding` | An open order on the symbol was still not final 5 minutes after its cancel; no order is placed for the symbol in this pass. |
| `date=DATE symbol=SYMBOL note=overnight position closed late` | The decision found the position still open and is closing it under `-late`. |
| `date=DATE symbol=SYMBOL note=overnight entry skipped` | The late close did not fill flat inside the submit window, or an order on the symbol is outstanding; the symbol is planned at its held exposure and its decision line reads `order=skip:overnight entry skipped`. |
| `date=DATE symbol=SYMBOL note=overnight position without entry` | A held strategy symbol has no `bt-SYMBOL-` order in the past week; it is exited under today's `-orphan` ids. |
````

The Contents list needs no change: no heading is added.

- [ ] **Step 2: Update `docs/specs/live-trading.md`**

After the `> [!NOTE]` block dated 2026-10-04 (lines 76-77), insert a blank line and:

```markdown
> [!NOTE]
> 2026-10-11: a `short` strategy maps a negative Alpaca quantity into the planner's short leg, sizes short entries as whole-share sells, checks the long and short marks separately, and never flips a sign in one session; see [Design: short positions and the overnight cycle](./short-overnight.md). Under `overnight`, the cycle gains an open step: after step 7 the daemon waits until the close plus 5 minutes, follows an entry still open to its session's close plus 5 minutes, and queues the exit for the quantity held as a market day order under `bt-SYMBOL-DATE-cover` or `-exit`, which Alpaca fills at the next opening print. At 09:35 it verifies that exit, re-checking every 60 seconds until 09:50, and exits a remainder left by a final exit under the next numbered id at most three times, giving a resubmission placed at or after 09:50 a 2-minute grace period before settling it. A position still held at the next decision is closed first under `bt-SYMBOL-DATE-late`, and the entry follows only once that close is filled, the account is flat, and the clock still shows the submit window open; a symbol that is not flat is frozen: `Engine.plan_fills ~frozen` keeps its holding whatever the target and `rebalance`, so the joint plan sizes the others around it. Orders that reduce exposure (long sells, covers) go out before orders that increase it (long buys, short sells), since Alpaca replenishes buying power only when a cover executes; an existing order keeps its pre-fill classification on a restart. A late close is sized as the position capped at what the guard's closing orders left unfilled, and each symbol's wait for it is capped at 3 minutes or the window left on the broker clock over the symbols still to process. Before every one of these orders, and before the entry of a `short` or `overnight` strategy, the daemon lists every open order of the symbol (paged), settles each (cancel, then poll every 15 seconds for at most 5 minutes), and sizes only from the position read afterwards, capped at the previous exit's unfilled quantity for a remainder; an order still outstanding blocks the symbol for that pass. Restart discovery lists the week's `bt-SYMBOL-` orders and resumes the latest series rather than resubmitting blindly; a held position with no such order exits under the `-orphan` id family.

Margin: a target above 1.0 is a larger position. bt caps the US effective target at 2.0: `Engine.effective_targets` scales a target so that `target x (1 - ratio)` stays at or below 1, and the US Reg T initial-margin ratio is 0.5. Alpaca's account `multiplier` does not set that cap; the recorded account fixture reports 4. Alpaca enforces its own buying power and overnight maintenance: price-band requirements of 100%/50%/30%, plus 50%/75% house requirements for 2x/3x leveraged ETFs. Alpaca charges margin interest on the settlement-date debit at 6.50% per year for non-elite accounts or 5.00% for elite accounts, per [Alpaca: Margin and Short Selling](https://docs.alpaca.markets/us/docs/margin-and-short-selling) (updated 2026-09-17). The charge is `debit x rate / 360` per day, accrued daily and posted at month end. bt's US backtest financing default stays 6.25%; `bt run --financing-rate PERCENT` overrides it. bt reads no unposted interest from the account, so live sizing can overstate equity by up to about one month of interest before posting: at 6.50%, 31 days is about 0.56% of the debit. bt's default maintenance table omits the leveraged-ETF add-ons; `bt run --maintenance-ratio PERCENT` replaces the whole table with one flat rate for those ETFs. bt's maintenance and cure machinery stays backtest-only. bt logs a buying-power rejection and skips the day. Alpaca values buys at the far side of the NBBO, slightly tighter than the provisional price.
```

- [ ] **Step 3: Update `CHANGELOG.md`**

In the `Added` entry that starts `- The overnight cycle.` (line 13), cut the final clause so the sentence ends after `overnight is not supported for tw` (today it continues with a semicolon and `bt target` and `bt live` reject `short` and `overnight` files until live support lands), and add this entry directly after it, still under `### Added` of `[Unreleased]`:

```markdown
- US live shorts and the queued overnight exit. `bt target` and `bt live` accept `short` and `overnight` files: a negative Alpaca quantity maps into the planner's short leg with its Reg T reserve, the long and short marks are checked separately (`US account holds a short outside the strategy` replaces the short rejection in a `short` file), a short entry is a whole-share sell, and a sign flip closes the held leg in one session and opens the new leg at the next decision, also under `rebalance on_change`. The daemon fails at startup with `SYMBOL is not shortable` or `SYMBOL is not easy to borrow` and logs Alpaca's `initial-margin` and `shorting-enabled`. Under `overnight`, the day ends at the close plus 5 minutes with the exit gate, which follows an open entry to its session close plus 5 minutes and queues the exit under `bt-SYMBOL-DATE-cover` or `-exit`; the 09:35 open step verifies the exit until 09:50 and exits any remainder of a final exit under `-cover2` and so on, at most three times, with a 2-minute grace period for a resubmission placed at or after 09:50; a position still held at the decision is closed late under `-late` before the entry (sized within what the guard's closing orders left unfilled, each symbol's wait capped at 3 minutes or the window left on the broker clock over the remaining symbols), and a symbol that is not flat is frozen through the new `Engine.plan_fills ~frozen` argument (its trade is exactly zero whatever the target and `rebalance`; an empty array freezes nothing) and skipped. US submissions now order by funding effect: long sells and covers first, then long buys and short sells after every close fills; the close-phase stop messages read `SIDE SYMBOL ...` with `buy` for a cover, and an existing order keeps its pre-fill classification on a restart. Before every order of a `short` or `overnight` strategy the daemon lists every open order of the symbol (paged), settles each (cancel, then poll every 15 seconds for at most 5 minutes), and sizes from the position read afterwards, capped at the previous exit's unfilled quantity; an outstanding order blocks the symbol for that pass. An entry-less position exits under `bt-SYMBOL-DATE-orphan` ids. New `note=` log lines report an unfilled exit series, an outstanding order, a late close, a skipped entry, and a held position without an entry. `Alpaca.cancel_order`, `Alpaca.order_by_id`, `Alpaca.open_orders` and `Alpaca.list_orders` (both paged), `Alpaca.asset`, `Alpaca.listed_t.qty`, and the `initial_margin` and `shorting_enabled` account fields are new; `Live.us_plan_action` takes `~frozen ~short ~overnight`, `Live.decide` takes `?frozen`, and `Live.us_step` takes an optional broker, an `overnight` flag, and a `decide` callback that receives the frozen symbols.
```

- [ ] **Step 4: Check the docs**

Run: `LC_ALL=C grep -nP '[^\x00-\x7F]' docs/cli.md docs/specs/live-trading.md CHANGELOG.md`
Expected: no output (ASCII only). Then `dune build --root . 2>&1` prints nothing (docs do not affect the build; this confirms the tree still builds before the commit).

- [ ] **Step 5: Commit**

Commit only after the coordinator confirms; use the co-author trailer the coordinator names; never push; never change git settings.

```bash
git add docs/cli.md docs/specs/live-trading.md CHANGELOG.md
git commit -m "docs: US live shorts and the queued overnight exit"
```

## Self-review

### Spec coverage

| Spec section or row | Task |
| --- | --- |
| Live account mapping: short leg in `us_plan_state` (`short_values = -qty x price`, reserve `1.5 x proceeds`, cash as Alpaca reports it) | Task 2 (`us_plan_state`) |
| Live account mapping: check 2 (`US account holds a short outside the strategy`; the old message without `short`) | Task 2 (`us_plan_action`) |
| Live account mapping: split 1% mark check with the negative short mark, finite check, tolerance `0.01 x (-short_market_value)` | Task 2 |
| Live account mapping: `initial_margin` and `shorting_enabled` parsed into `account_t` for the startup log; sizing uses the profile | Tasks 1 and 3 |
| Live account mapping: netting with `plan_short_cover` and `plan_short_open`, negative net is a sell, short part floored to whole shares | Task 2 |
| Live account mapping: no one-session sign flip; `previous_targets` held-sign rule for `short` without `overnight` | Task 2 (see Spec readings) |
| Live entry: whole-share `sell` under `bt-SYM-DATE`; `GET /v2/assets` gate at startup with the two messages; review round 2: closes (long sells, covers) posted and filled before opens (long buys, short sells); review round 3: an existing order keeps its pre-fill classification | Tasks 2 and 3 (`execute_decision`, `test_us_closes_before_opens`) |
| Live exit and cover 1: post-close gate, positions-read quantity, `-cover` buy / `-exit` sell, settle step (cancel, final set, `pending_cancel` and `stopped` outstanding, fill during cancel, 422), zero remainder; review round 1: the entry followed to its session close plus 5 minutes, the settle bound with the `Outstanding` outcome, the open-orders guard before the POST | Task 4 (`follow`, `settle`, `clear_open`, `drive_exit`, closed arm of `us_step`) |
| Live exit and cover 2: 09:35 step, 60-second re-checks until 09:50, settle then resubmit under the next id, at most three resubmissions then `overnight exit unfilled`, never while outstanding; review round 1: the remainder of a filled exit, the 2-minute grace period after a post-deadline resubmission, the guard before every resubmission; review round 2: the remainder capped at the exit's unfilled quantity, the open listing paged to exhaustion | Tasks 1 and 4 (`drive_exit` with a deadline, `` `Sleep_until `` arm, `Alpaca.open_orders`) |
| Live exit and cover 3: late exit under `-late`, `overnight position closed late`, entry only after filled plus flat and inside the window, else `overnight entry skipped`; canceled, expired, rejected, stopped count as not closed; review round 1: the guard and a clock check before the `-late` POST, the clock recheck after filled plus flat, the frozen symbols planned at their held exposure before the joint plan, the guard before the entry of a daily `short` file; review round 2: the freeze inside `Engine.plan_fills` so `rebalance daily` cannot re-plan a frozen asset, the guard after an existing `-late`, per-symbol isolation in `late_exit` and the daily guard; review round 3: `-late` sized within the guard's unfilled quantity, the per-symbol wait cap; review round 4: the cap uses the settled order's unfilled quantity (not its cumulative fill) and the budget is recomputed from the broker clock per symbol | Tasks 2 and 4 (`plan_fills ~frozen`, `late_exit`, `clear_open`, `` `Decide `` arm, `us_plan_action ~frozen`) |
| Restart discovery: `list_orders` over 7 days, paged with `until`, latest `bt-SYM-` order anchors the series, resume rather than resubmit blindly, `overnight position without entry`; review round 1: the `-orphan` id family, per-symbol isolation in `overnight_exits`, the open-orders listing at a Decide-phase restart | Tasks 1 and 4 |
| Restart discovery: finish dispatch for suffixed ids | Not needed (see Spec readings: suffixed ids never reach `finish`) |
| Live daily mode: same entry path, no exit step, resize like a long, two-session flip | Task 2; `us_step` without `?overnight` is unchanged |
| Errors: `<symbol> is not shortable`, `<symbol> is not easy to borrow` | Task 3 |
| Errors: `US account holds a short outside the strategy` | Task 2 |
| Errors: the four daemon notes, plus `overnight exit outstanding` from review round 1 | Task 4 |
| Test 9 Live mapping | Task 2 (`test_us_short_plan_state`, `test_us_short_plan_checks`) |
| Test 10 Live parity (cash and levered book, flat-account sell, sign flip and deferred leg under on_change with other assets skipped, add and reduce at price 100.1, a frozen symbol) | Task 2 (`test_us_short_plan_parity`, `test_us_short_sign_flip`) |
| Test 11 Exit submission, plus the entry follow, the settle bound, and per-symbol isolation | Task 4 (`test_us_overnight_exit_gate`) |
| Test 12 09:35 step, all thirteen cases, plus the remainder of a filled exit, the grace period and its expiry, the settle bound, the orphan family, and the API-contract Monday paging | Task 4 (`test_us_overnight_morning_step`; the two-page listing runs through `Alpaca.list_orders ~page` and asserts both paths) |
| Test 13 Late exit, plus the clock check before the POST, filled after the cutoff, a two-symbol cutoff crossing, an open exit settled before `-late`, the settle bound, an existing `-late` followed | Task 4 (`test_us_overnight_late_exit`) |
| Review round 1: two-symbol failed late close through the real planner and executor; the entry guard of a daily `short` file (settled and outstanding) | Task 4 (`test_us_overnight_frozen_entry`, `test_us_short_entry_guard`) |
| Test 14 Asset flags | Task 3 (`test_live_startup_guard`) |
| Docs: `docs/cli.md` log lines and the 09:35 step, `docs/specs/live-trading.md` daily cycle, CHANGELOG entry | Task 5 |
| Acceptance (paper week) | Coordinator, after Task 5 lands; not part of this plan |

Gaps: none in stage 2 scope. `legs_of_plan` and the TW daemon are untouched.

### Placeholder scan

No "TBD", "TODO", "implement later", "similar to Task N", or code-free code steps. Every modified function is shown in full or by an exact replacement window anchored on its first and last line. The one temporary behavior (Task 3's narrowed guard) is removed in Task 4 of this same plan, and its test block is replaced in Task 3 and deleted in Task 4. The settle step is bounded (no open-ended poll remains).

### Type consistency

- `Alpaca.listed_t` (Task 1) is the row type of `list_orders`, `parse_orders`, `overnight_broker.list_orders`, `series_of_order`, and the `us_listed` test helper (Task 4).
- `Alpaca.asset_t` (Task 1) is consumed by `shortable_ok` (Task 3) and `run_us`'s gate; `Alpaca.asset` returns it.
- `Alpaca.parse_cancel ~http_code` (Task 1) is what `cancel_order` returns through; `overnight_broker.cancel : string -> unit` and `order : string -> Alpaca.order_t option` (Task 4) take the Alpaca order id (`order.id`), which `settle` and `follow` pass; `lookup` takes a client id and is used only for the day's `-late`.
- `us_plan_action ~frozen ~short ~overnight` (Task 2) is called with all three labels by `decide` (Task 2) and by every test; `decide ?frozen` defaults to `[]` for `bt target` and derives `short` and `overnight` with `Dsl.short_of` and `Dsl.overnight_of`; `us_step` (Task 4) calls `decide ~frozen date` through its callback of type `frozen:string list -> string -> decision`.
- `run_us ~short` (Task 3) becomes `run_us ~short ~overnight` (Task 4); `run` passes both from the parsed file; `run_us` builds the broker when `short || overnight` and passes `?broker ~overnight` to `us_step`.
- `us_step ?broker ?overnight` (Task 4) is erasable because `clock` is positional; tests pass `~broker ~overnight:true` (or `~overnight:false` for the daily `short` guard).
- `series.exits = 0` marks an entry or `-late` order; `exit_id ~held ~orphan number` with `number = 1` yields `-cover`/`-exit`/`-orphan` and `number > 1` appends the number, matching `suffix_number`'s parse; `drive_exit` stops at `number > 4` (three resubmissions after the first exit); the orphan flag of a resumed series is carried from `series_of_order` into the next id.
- `settled = Final | Outstanding` (Task 4) is produced by `settle` and consumed by `clear_open` and `drive_exit`; `follow ~polls` is called with `polls:20` by `settle`, `polls:8` for the grace period, and the calendar-derived count for an entry.
- `Alpaca.listed_t.qty` (Task 1) feeds `series.qty` (Task 4) through `series_of_order`; `drive_exit`'s `post ~bound` takes `series.qty -. series.latest.filled_qty` after a final exit and `Float.infinity` for an entry or orphan.
- `Engine.plan_fills ~frozen` (Task 2) takes a `bool array`; `us_plan_action` builds it from its `frozen : string list` with `Array.mapi (fun i _ -> is_frozen i) symbols`; `run`, the TW arm, and the test calls pass `[||]`.
- `execute_decision`'s `closing symbol side` (Task 3) reads `asset_decision.held`, which `decide` fills from `Alpaca.position_qty` (signed), so a short holding classifies its buy as a close; `order_closing` uses `held >= 0.` for a sell so an existing sell whose fill left the symbol flat stays a close.
- `clear_open`'s `(position, unfilled)` (Task 4) is consumed by `drive_exit` (`Option.map fst`), `late_exit` (both parts), and the daily guard (`Some _`); `late_exit`'s `budget remaining clock` takes the clock read made for the symbol's window check.
- `test_us_closes_before_opens` is defined once, in Task 3; Task 4's insertion goes before it.
- `final_order_status` (Task 4) is used by `follow`, `settle`, and `drive_exit`; `terminal_order_status` (existing) by `late_exit`, `poll_fill`, and the sell barrier.
- `broker.session_close : string -> int` is implemented by `session_close_of mode` (`Alpaca.calendar` plus `Data.et_offset_minutes`) in `run_us` and by a constant in the test fake; `rfc3339_seconds` is exported for the fake.
- Log lines: `order_description (Order { side; qty; id })` formats `SIDE:QTY:ID` for exits and the late close, and `log_fill` formats their fills, both consistent with `docs/cli.md` (Task 5).

### Offline verification

Every code block in Tasks 1-5, as revised after review rounds 1 to 4, was applied in task order to scratch copies of the worktree at `53139fb` outside the repo (one tree per task state) and built with the project switch (`dune build --root .`, zero warnings) at each task boundary. At each boundary the full suite passed (`dune build --root . @runtest --force` exited 0 and printed `ok`): Task 1 with `test_alpaca_orders_parse`, `test_alpaca_asset_parse`, `test_alpaca_cancel_and_listing` (newest-first paging with the exclusive `until` cursor and exact paths) and the extended `test_alpaca_account_parse`; Task 2 with `test_us_short_plan_state`, `test_us_short_plan_checks`, `test_us_short_plan_parity` (including the two price-100.1 cases), `test_us_short_sign_flip` (including the frozen symbol) and the sixteen `plan_fills ~frozen:[||]` call updates; Task 3 with the extended `test_live_startup_guard`, the narrowed `test_short_cli_errors`, and `test_us_closes_before_opens`; Task 4 with `test_us_overnight_exit_gate`, `test_us_overnight_morning_step`, `test_us_overnight_late_exit`, `test_us_overnight_frozen_entry`, `test_us_short_entry_guard`. The expected quantities in the parity and sign-flip tests were read from that build (engine fills and live actions printed side by side: at 100, open from flat sells 2, add sells 2, reduce buys 3, cover buys 2, levered SPY sells 4.000258884 and QQQ sells 2; at 100.1, add 3 to 4 sells 1 and reduce 4 to 2 buys 2, matching the engine's whole-share fills; the frozen two-symbol case sells 2.00005648 QQQ shares; the engine-freeze case plans QQQ cover 100 and SPY open 170 thawed, 0 and 90 frozen). Eleven deliberate breaks each made the build or suite fail (the grace period set to zero polls, the orphan suffix dropped, the settle bound raised to 25 polls, the `frozen` conjunct dropped from `changed`, the close partition reverted to `side = `` `Sell``, the remainder bound dropped, existing orders classified from the post-fill holding, the `-late` quantity not capped by the unfilled quantity, the wait cap removed, the wait budget computed from one fixed clock read, the unfilled cap ignored), so the daemon and planner tests bite. The six byte gates were rerun on the Task 5 build with the commands in Global Constraints and compared with `cmp` against the three baseline files per market: all six identical. The sources and docs were grepped for non-ASCII bytes: none.


