# TW Live Trading Implementation Plan

> **For agentic workers:** Implementers use superpowers:executing-plans ONLY, one task per dispatch. Implementers never dispatch subagents of any kind; the coordinator owns every review. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Execute docs/specs/tw-live-trading.md: `bt live` and `bt target` for the Taiwan market through the local Shioaji HTTP server, with live sizing produced by the engine's own fill planner, margin legs included.

**Architecture:** New `broker/shioaji.ml` REST client (curl+jq against `localhost:8080`); the engine's per-bar fill planner extracted to an exported pure function with `Engine.run` partially applying it; `broker/live.ml` gains `"tw"` match arms beside the untouched `"us"` arms; `bin/bt.ml` gains `--equity`.

**Tech stack:** OCaml stdlib + unix, curl and jq subprocesses, dune per-concern libraries, assert tests with JSON fixtures.

## Global constraints

- Work ONLY in the worktree `/sandbox/stock-tw-live` on branch `tw-live`. Never build, test, or edit in `/sandbox/stock` (a concurrent study runs from its `_build`). Daily caches are read via `--data-dir /sandbox/stock/data` (read-only).
- The spec docs/specs/tw-live-trading.md is binding: copy endpoint paths, JSON field names, enum values, error messages, and flag names from it verbatim.
- Additive only: `Engine.run` is touched only by the planner extraction (byte-identical bodies, partial application at the existing call site); no edits to `Data.fetch*`, no changes to the `"us"` arms of `live.ml`, no changes to existing CLI dispatch arms beyond the `tw` acceptance and the `--equity` flag, no changes to existing `.mli` exports.
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
- Gates after EVERY task, all from the worktree: `opam exec -- dune build` clean; `opam exec -- dune runtest --force` exit 0; TW byte-identity: `_build/default/bin/bt.exe run /sandbox/research/strategies/tw/channel_ladder/main.strat --baseline tw/00685L --data-dir /sandbox/stock/data --out-dir <dir> --out-name fp --no-plot` byte-identical to `/tmp/tw-ref` (files) and `/tmp/tw-ref.txt` (stdout), captured at efb319a.
- No network in tests. The only network smoke (Task 4) requires the user's Shioaji server; record exact commands and defer when absent, never fake output.
- Codex exhaustion (`usage_limit_reached`): pause the task and wait for restoration; never substitute a backend or do the work inline.
- Git: commits only, NEVER push, NEVER touch git settings or the author field; trailer `Co-authored-by: ChatGPT <noreply@openai.com>`.
- Report per task: `/sandbox/stock-tw-live/.superpowers/sdd/tw-live-trading/task-<n>-report.md` with red/green evidence.

## Task 1: Shioaji client

**Files:** create broker/shioaji.ml, broker/shioaji.mli, test/fixtures/shioaji/{info,snapshot,positions,balance,place_order,update_status}.json; modify test/test_bt.ml, test/dune (add `(glob_files fixtures/shioaji/*.json)`). broker/dune already links `data engine lang`; add nothing unless the compiler demands.

**Produces (consumed by Tasks 3-4):**
- `val base_url : unit -> string` (`SHIOAJI_URL` or `http://localhost:8080`).
- `type info = { simulation : bool; version : string }`, `val info : unit -> info` (`GET /api/v1/info`).
- `type snapshot = { datetime : string; open_ : float; high : float; low : float; close : float; bid : float; ask : float; total_volume : float }`, `val snapshot : exchange:string -> code:string -> snapshot` (`POST /api/v1/data/snapshots`, exchange `TSE` or `OTC`, security_type `STK`; the response is a one-element array).
- `type position = { code : string; cond : string; lots : int; yd_lots : int; avg_price : float; last_price : float; loan_amount : float; interest : float }`, `val positions : unit -> position list` (`POST /api/v1/portfolio/position_unit` with `{"account_type":"S","unit":"Common"}`; `quantity` is lots; `margin_purchase_amount` maps to `loan_amount`).
- `val balance : unit -> float` (`POST /api/v1/portfolio/account_balance`, `acc_balance`; raise `Failure` with `errmsg` when non-empty).
- `type order_request = { exchange : string; code : string; action : string; lots : int; cond : string; custom_field : string }`, `type placed = { order_id : string; status : string }`, `val place_order : order_request -> placed` (`POST /api/v1/order/place_order` with `price 0`, `price_type MKT`, `order_type ROD`, `order_lot Common`; account omitted so the server default applies).
- `type trade = { order_id : string; code : string; action : string; cond : string; status : string; order_lots : int; deal_lots : int; deal_price : float option; order_datetime : string }`, `val orders_today : code:string -> today:string -> trade list` (`POST /api/v1/order/update_status` with `{}` then parse the returned Trade array; filter `order_datetime` date prefix = today and contract code).
- All parse functions pure (`parse_info : string -> info` etc.) so fixtures test them offline; `request` helper mirrors `Alpaca.request` (curl `--max-time 60`, `-H 'Content-Type: application/json'`, transport failure -> `Failure "curl failed while calling Shioaji"`, non-2xx -> `Failure` with the HTTP code).

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

**Produces (consumed by Task 4):**
- Pure helpers in live.ml: `taipei_phase : now:string -> [ `Weekend | `Before_fetch | `Fetch | `Decide | `After_close ]` (Taipei wall clock from the local clock with a fixed +8 offset: weekend, before 13:05, 13:05-13:19, 13:20-13:29, 13:30 onward); `lots_of_shares : float -> int * float` (floor to 1000-share lots, remainder); `exchange_of_symbol : data_dir:string -> string -> string` (`TSE` or `OTC` from stockinfo); `equity_of : balance:float -> positions:Shioaji.position list -> float` (cash plus lots x 1000 x last_price minus loans minus interest); `legs_of_plan : Engine.plan -> leg list` with `leg = { action : string; cond : string; lots : int }` dropping sub-lot legs.
- `Live.decide` `"tw"` arm: fetch (FinMind), freshness against the snapshot date, provisional bar from the snapshot (close, or bid/ask midpoint when close is stale), evaluation through the shared path, `effective_targets` with the tw profile, state from positions and equity (production: `balance` + positions; simulation: `--equity`), the planner call, legs; `bt target` prints the legs.
- Daemon `"tw"` arm: phase loop, dedup via `orders_today`, per-leg `place_order` with `custom_field` = `"bt" ^ MMDD`, post-13:30 `orders_today` log of status/deal lots/price, sleep to the next session. Every failure path: one log line, skip the day. Startup guard: `--live` requires `info.simulation = false`; simulation requires `--equity`; production rejects `--equity`.
- bin/bt.ml: `--equity TWD` on `live` and `target`; the `| "tw" ->` acceptance replaces the current rejection arm in `live_command_args`; `"us"` behavior unchanged.

- [ ] RED: pure tests with hand-derived values for each helper (phase boundaries at 13:04:59/13:05/13:19:59/13:20/13:30; 1500 shares -> 1 lot remainder 500; 999 -> 0 lots; equity case with one cash and one margin position; legs for the three planner cases from Task 2 including a sub-lot drop); decide-level test with an override snapshot proving the tw arm runs the shared evaluation and returns legs; CLI tests: `bt target` on a tw strat without `--equity` in simulation fails with the exact message `simulation mode requires --equity`; `--live --equity` fails with `--equity is not allowed in production`; a us strat still works as before (existing tests untouched).
- [ ] Run: expected FAIL. Record.
- [ ] GREEN: implement the arms and helpers.
- [ ] Gates. Commit `feat: TW live decision and daemon via Shioaji`.

## Task 4: docs and smoke

**Files:** modify docs/cli.md, docs/engine.md, CHANGELOG.md, CONTRIBUTING.md (module layout: broker/shioaji), README.md only if it enumerates live markets.

- [ ] Docs: cli.md `bt live` and `bt target` sections gain a `### Taiwan market` subsection each (server prerequisite with the `.env` fields, `SHIOAJI_URL`, `--equity` row in the options table with Default `-` and the simulation-only note, mode mapping, board-lot rule) with [!IMPORTANT] for the CA and production requirements and [!WARNING] for simulation equity being user-supplied; engine.md TW gap section gains the live counterpart bullet list; CHANGELOG `[Unreleased]` Added; CONTRIBUTING module layout row; ToCs regenerated.
- [ ] Gates. Commit `docs: TW live trading`.
- [ ] Smoke (requires the user's SinoPac API key and `shioaji server start` in simulation on this host or a reachable `SHIOAJI_URL`): bless `cp _build/default/bin/bt.exe /sandbox/stock/bt-test<n+1>.exe && chmod +x`; `bt target /sandbox/research/strategies/tw/channel_ladder/main.strat --equity 1000000 --data-dir /sandbox/stock/data`; record the printed legs and hand-check them against the planner rules. If the server is absent, record the exact commands and mark deferred.

## Reviews

Reviewer agent dispatched by the coordinator after each task (diff against the task's base; spec compliance plus code quality with file:line evidence); fix waves re-gate and re-review before the next task starts. Final whole-branch review after Task 4.
