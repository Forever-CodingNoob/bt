# TW Live Trading Implementation Plan

This plan delivers TW simulation; production accounting and the Shioaji network smoke remain open.

## Contents

- [Global constraints](#global-constraints)
- [Task 1: Shioaji client](#task-1-shioaji-client)
- [Task 2: engine fill-planner extraction](#task-2-engine-fill-planner-extraction)
- [Task 3: TW decision and daemon arms](#task-3-tw-decision-and-daemon-arms)
- [Task 4: docs and smoke](#task-4-docs-and-smoke)
- [Reviews](#reviews)

**Goal:** Execute docs/specs/tw-live-trading.md: `bt live` and `bt target` for the Taiwan market through the local Shioaji HTTP server, with live sizing produced by the engine's own fill planner, margin legs included. The completed milestone is TW simulation; production remains required.

**Architecture:** `broker/shioaji.ml` is the curl+jq REST client for the official Shioaji server; the engine's per-bar fill planner is an exported pure function that `Engine.run` and TW decision planning both call; `broker/live.ml` has `"tw"` arms beside the untouched `"us"` arms; `market/data.ml` queries FinMind's independent `TaiwanStockTradingDate` calendar; `bin/bt.ml` exposes `--equity`.

**Tech stack:** OCaml stdlib + unix, curl and jq subprocesses, dune per-concern libraries, assert tests with JSON fixtures.

## Global constraints

**For agentic workers:** Implementers use superpowers:executing-plans ONLY, one task per dispatch. Implementers never dispatch subagents of any kind; the coordinator owns every review. Steps use checkbox (`- [ ]`) syntax for tracking.

- Continue implementation in `/sandbox/stock-tw-live` on branch `tw-live`. The study in `/sandbox/stock` is complete, so its previous source/build restriction is lifted. Use the existing switch with `opam exec --switch=/sandbox/stock -- ...`; daily caches remain under `/sandbox/stock/data`.
- Approved requirements remain binding. Current-status notes distinguish implemented behavior from missing requirements; implementation differences do not reduce the required DAILY production scope.
- The US path and daily backtest behavior remain unchanged. TW additions include the independent FinMind calendar, Shioaji client, simulation target and daemon, and `--equity`.
- Strict TDD per behavior: failing test first with recorded red output in the report, then minimal code, then green with the full suite. Hand-derived fixtures with derivation comments.
- Code style, copied verbatim from CONTRIBUTING.md Style rules, all binding:
  - Use the OCaml standard library and `unix` only. Do not add opam package dependencies.
  - No `for` or `while` loops. Sequence side effects with `let () = e in`.
  - Branch on the market with `match` arms (`| "tw" -> ... | "us" -> ...`), never `if market = ...`. New markets must slot in as new arms.
  - Make list recursion tail-recursive. Use an accumulator and `List.rev`. Use `Array` index loops for series math.
  - Preserve floating-point operation order. Do not rewrite arithmetic that would change rounding.
  - A numeric series is a `float array`. Warmup values are `Float.nan`. A comparison with NaN gives `false`.
  - Put one space on each side of `=`. Do not align code with extra spaces.
  - Network and JSON work goes through `curl` and `jq` as subprocesses. Do not parse JSON in OCaml.
  - Do not embed Python (or other foreign code) in `.ml` files. Python scripts are standalone files in `scripts/`.
  - ASCII-only typography in code and docs (no arrows, em dashes, typographic quotes; CJK content terms allowed).
  - Functional style throughout: no `ref` or `mutable` outside the existing `Arg`-parsing CLI functions; state flows through fold accumulators and explicit arguments; every new module ships its `.mli` in the same commit with a doc comment per export.
- Docs per CONTRIBUTING.md Documentation style in full: one h1, disciplined h2-h4, alerts with fixed semantics (NOTE context, TIP usage, IMPORTANT load-bearing, WARNING fidelity gaps, CAUTION destructive), tables for enumerable content with a Default column in cli.md, full-depth ToCs regenerated, no mid-sentence hard wraps.
- Gates from the worktree: `opam exec --switch=/sandbox/stock -- dune build --root .`; `opam exec --switch=/sandbox/stock -- dune runtest --root . --force`; TW byte-identity: `_build/default/bin/bt.exe run /sandbox/research/strategies/tw/channel_ladder/main.strat --baseline tw/00685L --data-dir /sandbox/stock/data --out-dir <dir> --out-name fp --no-plot`. The byte-identity reference and its provenance are recorded in the task report.
- No network in tests. The only network smoke (Task 4) requires the user's Shioaji server; record exact commands and defer when absent, never fake output or invent an unused blessed binary name.
- Codex exhaustion (`usage_limit_reached`): pause the task and wait for restoration; never substitute a backend or do the work inline.
- Git: obtain user confirmation of staged changes before every commit; NEVER push, touch git settings, or override the author field. Use trailer `Co-authored-by: ChatGPT <noreply@openai.com>`.
- Report per task: `/sandbox/stock-tw-live/.superpowers/sdd/tw-live-trading/task-<n>-report.md` with red/green evidence.

## Task 1: Shioaji client

**Files:** create broker/shioaji.ml, broker/shioaji.mli, test/fixtures/shioaji/{info,snapshot,positions,balance,place_order,update_status}.json; modify test/test_bt.ml, test/dune (add `(glob_files fixtures/shioaji/*.json)`). broker/dune already links `data engine lang`; add nothing unless the compiler demands.

**Produces (consumed by Tasks 3-4):**
- `val base_url : unit -> string` (`SHIOAJI_URL` or `http://localhost:8080`).
- `type info = { simulation : bool; version : string }`, `val info : unit -> info` (`GET /api/v1/info`).
- `type snapshot = { datetime : string; open_ : float; high : float; low : float; close : float; bid : float; ask : float; total_volume : float }`, `val snapshot : exchange:string -> code:string -> snapshot` (`POST /api/v1/data/snapshots`, exchange `TSE` or `OTC`, security_type `STK`; the response is a one-element array).
- `type position = { code : string; cond : string; lots : int; yd_lots : int; avg_price : float; last_price : float; loan_amount : float; interest : float }`, `val positions : unit -> position list` (`POST /api/v1/portfolio/position_unit` with `{"account_type":"S","unit":"Common"}`; `quantity` is lots; `margin_purchase_amount` maps to `loan_amount`).
- `val balance : unit -> float` (`POST /api/v1/portfolio/account_balance`, `acc_balance`; raise `Failure` with `errmsg` when non-empty).
- `type order_request = { exchange : string; code : string; action : string; lots : int; cond : string; custom_field : string }`, `type placed = { order_id : string; status : string }`, `val place_order : order_request -> placed` (`POST /api/v1/order/place_order` with `price 0`, `price_type MKT`, `order_type IOC`, `order_lot Common`; account omitted so the server default applies).
- `type trade = { order_id : string; code : string; action : string; cond : string; status : string; order_lots : int; deal_lots : int; deal_price : float option; order_datetime : string }`, `val orders_today : code:string -> today:string -> trade list` (`POST /api/v1/order/trades` with `{}` then parse the returned Trade array; accept string `status.order_datetime` or numeric `status.order_ts` converted to Taipei RFC3339, and filter that date plus contract code).
- All parse functions pure (`parse_info : string -> info` etc.) so fixtures test them offline; authenticated requests use a mode-`0600` curl header file containing `Authorization: Bearer <SJ_API_KEY>:<SJ_SEC_KEY>` and JSON content type, missing credentials raise a `Failure` export hint, `/api/v1/info` remains unauthenticated, transport failure raises `Failure "curl failed while calling Shioaji"`, and non-2xx raises `Failure` with the HTTP code.

- [ ] RED: fixture-parse tests. Fixtures verbatim from the spec's documented examples: info `{"name":"Shioaji API Server","version":"1.7.2",...,"simulation":false}`; the documented snapshot array for 2330 (datetime `2026-05-18T14:30:00`, close 2240, buy_price 2240, sell_price 2245); positions with the two documented Cash entries plus one hand-written MarginTrading entry (`quantity 3, margin_purchase_amount 120000, interest 35`); balance `{"acc_balance":100000.0,"date":"...","errmsg":""}` plus an error fixture with non-empty errmsg; place_order Trade response with `order.id "a647f23d"` and `status.status "PendingSubmit"`; update_status array with the documented Filled trade (deal_quantity 2, deals[0].price 27.1, order_datetime `2026-05-20T11:24:30+08:00`). Assert parsed records equal hand-written expected values; `orders_today` filter keeps the 2026-05-20 trade for today `2026-05-20` and drops it for `2026-05-21`.
- [ ] Run: `opam exec -- dune runtest --force`. Expected: FAIL, `Shioaji` unbound. Record.
- [ ] GREEN: implement the client.
- [ ] Gates. Commit `feat: Shioaji REST client`.

## Task 2: engine fill-planner extraction

**Files:** modify engine/engine.ml, engine/engine.mli, test/test_bt.ml.

**Consumes:** nothing new. Read `Engine.run`'s per-bar fill planning region first (the code that, given current cash inventory, margin inventory, loan, cash, equity, and the bar's effective target, decides cash-first buys, standard-ratio loan buys, and sell allocation across the two inventories; the two-inventory margin spec docs/specs/two-inventory-margin.md describes it).

**Produces (consumed by Task 3):**
- A top-level exported pure function, name and record types pinned from the actual code (indicative: `val plan_fills : profile:market_profile -> financing_ratio:float -> costs:costs -> capital:float option -> state:plan_state -> price:float -> target:float -> plan` where `plan_state = { cash : float; cash_shares : float; margin_shares : float; loan : float; interest : float }` and `plan = { buy_cash_shares : float; buy_margin_shares : float; sell_cash_shares : float; sell_margin_shares : float; new_loan : float }`), with a doc comment stating it is the exact planner `run` uses.
- `Engine.run` calls the extracted function at the existing site through partial application; no other change.

- [ ] RED: a test calling the new function on a hand-derived two-inventory case (equity 1,000,000 TWD, price 10, financing ratio 0.6: target 0 -> 1.0 yields cash-only buy of 100,000 shares; 1.0 -> 2.0 yields a margin buy with loan = 0.6 x notional and the remaining cash covering 0.4; 2.0 -> 0 sells both inventories and repays the loan) with derivation comments matching the engine's documented rules; plus an equality test that the extracted function and the pre-extraction behavior agree on the sentinel scenario (`test_engine_buyhold_costs` stays bit-for-bit).
- [ ] Run: expected FAIL, function unbound. Record.
- [ ] GREEN: extract (byte-identical body moved out, explicit arguments for everything it closed over), re-wire `run`. If the planner is entangled with fill execution in a way that resists a clean lift, STOP and report the exact lines to the coordinator instead of refactoring more broadly.
- [ ] Gates - the TW byte-identity gate is the proof of this task. Commit `refactor: export the engine fill planner`.

## Task 3: TW decision and daemon arms

**Files:** modify broker/live.ml, broker/live.mli, bin/bt.ml, market/data.mli only if an existing stockinfo exchange lookup needs exporting (read data.ml first; the stockinfo table already classifies symbols), test/test_bt.ml.

**Consumes:** Task 1 client types and functions; Task 2 planner; existing `Live.decide` structure, `Engine.effective_targets`, `Engine.profile_of_market "tw"`, `Data.financing_ratio`, the FinMind fetch, and the US arms as the template.

**Implemented simulation surface:**

- `taipei_phase` divides weekdays into before 13:05, 13:05-13:20 preparation, 13:20-13:25 decision and execution, and after-cutoff phases. `legs_of_plan` floors to 1000-share Common lots and emits cash, margin, and refinance legs. `exchange_of_symbol` maps cached stock information to `TSE` or `OTC`.
- `Data.previous_trading_day` queries FinMind `TaiwanStockTradingDate` independently. Preparation validates today's snapshot, fetches once through that previous session, and requires the cache to end exactly there. Decision reuses the verified previous session and still validates a fresh snapshot.
- Simulation `--equity` is total account equity. With the supported one-stock account, inferred cash is equity minus cash and margin inventory values plus loans and interest. Nonzero inventory in another symbol is rejected.
- Every leg is floored to Common lots and submitted as `MKT` + `IOC` before 13:25. The executor confirms one fully filled matching status and a finite positive weighted deal price before any successor. Partial, failed, missing, ambiguous, mismatched, timed-out, cutoff, and uncertain submissions stop the remaining legs and log observed exposure.
- Refinance sells and rebuys are sequential, not atomic. The dependent rebuy requires a complete confirmed predecessor and full funding. Confirmed-fill cash can cap an ordinary buy, after which its residual and later legs remain unsubmitted.
- The pre-plan query for today's orders is conservative deduplication only. It does not guarantee exactly-once behavior under concurrent daemons or every crash timing.
- Mode guards require `--equity` plus a simulation server for simulation and require `--live` plus a production server for production. TW production then raises the unresolved real-money accounting blocker before sizing; it does not skip days merely because settlements are pending.

- [ ] Production: establish and exercise the DAILY real-money equity and spendable-cash formula from `account_balance`, positions, and T+0 through T+2 settlements without double-counting, omission, or pending-payment session skips.
- [x] Simulation: independent calendar, freshness, target planning, Common-lot translation, MKT+IOC execution, confirmed-fill sequencing, exposure logging, CLI guards, and offline checks.
- [ ] Gates and completion review for the full production requirement.

## Task 4: docs and smoke

**Files:** modify docs/cli.md, docs/engine.md, CHANGELOG.md, CONTRIBUTING.md, docs/specs/tw-live-trading.md, and docs/plans/tw-live-trading.md; create the Task 4 report; leave README.md unchanged because it does not enumerate live markets.

- [x] Docs: cli.md `bt live` and `bt target` sections document the official server prerequisite and `.env` fields, `SHIOAJI_URL`, `SJ_API_KEY`, `SJ_SEC_KEY`, `FINMIND_TOKEN`, `--equity` with Default `-`, mode guards, Common-lot flooring, sequential fills, and the production blocker; engine.md records simulation/live fidelity; CHANGELOG and CONTRIBUTING are updated; ToCs are regenerated.
- [ ] Gates. The coordinator owns validation and review.
- [ ] Network smoke: deferred because the `shioaji` command is not installed and no running server or reachable `SHIOAJI_URL` is configured. Discover an actually unused blessed `bt-test` name at smoke time; do not invent one in advance. The exact deferred command sequence is recorded in `.superpowers/sdd/tw-live-trading/task-4-report.md`.

## Reviews

Reviewer agent dispatched by the coordinator after each task (diff against the task's base; spec compliance plus code quality with file:line evidence); fix waves re-gate and re-review before the next task starts. Final whole-branch review after Task 4.
