# Live Trading Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Execute docs/specs/live-trading.md: a `bt live` daemon and `bt target` one-shot for one strategy on one Alpaca account, MOC discipline, engine evaluation reused unchanged.

**Architecture:** `lib/alpaca.ml` is a curl+jq REST client (paper default, `--live` flips base URL); `lib/live.ml` holds the pure decision core and the clock-anchored daemon loop; `bin/bt.ml` wires both subcommands. The engine is not modified.

**Tech stack:** OCaml stdlib + unix only, curl and jq as subprocesses (existing fetch conventions), dune, existing test harness in test/test_bt.ml.

## Global constraints

- The spec docs/specs/live-trading.md is binding; the Verified Alpaca facts section holds exact endpoints, headers, and semantics - copy values from there, never from memory.
- Signal evaluation MUST go through the existing DSL compile + engine target path. Reimplementing any indicator or signal logic in live code is a rejected task.
- Strict TDD: failing test first with recorded red output in the report, then minimal code, then green with the full suite.
- Every new lib module ships its `.mli` in the same commit. Style per CONTRIBUTING.md and AGENTS.md: match on market (`| "us" -> ... | "tw" | _ -> usage error`), no loops, ASCII only.
- No network in tests: JSON parsing is tested against checked-in fixture files; network calls exist only behind the client functions.
- TW byte-identity gate after EVERY task: `_build/default/bin/bt.exe run /sandbox/research/strategies/tw/channel_ladder/main.strat --baseline tw/00685L --data-dir data --out-dir <dir> --out-name fp --no-plot` byte-identical to the pre-plan capture at /tmp/live-ref and /tmp/live-ref.txt (captured 2026-09-04, exit 0).
- `bt fetch` and `bt run` behavior is FROZEN for the duration of this plan: a concurrent agent is running a backtest study against them. All changes are additive (new modules, new subcommands); the byte-identity gate proves `bt run` untouched, and `bt fetch` code paths are not edited at all. If a task cannot proceed without changing fetch or run behavior, STOP and ask the user - never proceed.
- If Codex credits are exhausted mid-plan (subagent fails with usage_limit_reached), pause the task and wait for restoration: tell the user, retry the same dispatch periodically, never substitute a backend or do the work inline.
- Git: commits only, NEVER push, NEVER touch git settings or the author field; trailer `Co-authored-by: ChatGPT <noreply@openai.com>` (GPT 5.6 Sol implementers).
- Report per task: /sandbox/stock/.superpowers/sdd/live-trading/task-<n>-report.md with red/green evidence.

## Task 1: Alpaca client

**Files:** create lib/alpaca.ml, lib/alpaca.mli, test/fixtures/alpaca/{clock,account,position,order,snapshot}.json; modify test/test_bt.ml, lib/dune (add module only if dune requires listing).

**Produces (consumed by Tasks 2-3):**
- `type mode = Paper | Live`
- `val base_url : mode -> string` (paper-api / api per spec)
- `val clock : mode -> clock_t` with `clock_t = { timestamp : string; is_open : bool; next_open : string; next_close : string }`
- `val account : mode -> account_t` with `account_t = { equity : float; status : string; trading_blocked : bool; account_number : string }`
- `val position_qty : mode -> string -> float` (404 -> 0.)
- `val snapshot : string -> snapshot_t` with `snapshot_t = { day_open : float; day_high : float; day_low : float; latest : float; day_volume : float }` (data API, feed=iex)
- `val submit_moc : mode -> symbol:string -> qty:int -> side:[`Buy|`Sell] -> client_order_id:string -> order_t`
- `val order_by_client_id : mode -> string -> order_t option` with `order_t = { id : string; status : string; filled_avg_price : float option; filled_qty : float }`
- Auth headers `APCA-API-KEY-ID`/`APCA-API-SECRET-KEY` from env `APCA_API_KEY_ID`/`APCA_API_SECRET_KEY`; missing env is a hard error at first use, matching the TIINGO_TOKEN convention in lib/data.ml.

- [ ] RED: fixture-parse tests. Save the five fixture JSONs verbatim from the spec's documented examples (clock example from /v2/clock docs; account example with `equity` string "103820.56"; position with `qty` "5"; order with `client_order_id` and `status`; snapshot with `dailyBar` o/h/l/c/v and `latestTrade`). Tests assert parsed records equal hand-written expected values, including string-to-float decimal parsing and position-404-to-zero handling (parse function takes the raw curl output plus HTTP code).
- [ ] Run: `opam exec -- dune runtest --force`. Expected: FAIL, `Alpaca` module undefined. Record.
- [ ] GREEN: implement the client. One internal `request : mode -> path:string -> ...` helper wrapping curl (headers, base URL by mode) piped through jq extraction in the style of lib/data.ml's Tiingo functions; per-endpoint parse functions are pure (raw string in, record out) so fixtures test them without network.
- [ ] Run: suite green. TW byte-identity gate. Commit `feat: Alpaca REST client` (ChatGPT trailer).

## Task 2: decision core and bt target

**Files:** create lib/live.ml, lib/live.mli; modify bin/bt.ml, test/test_bt.ml, docs/cli.md.

**Consumes:** Task 1 signatures exactly as listed. Existing: the strat load + DSL compile + engine evaluation path `bt run` uses (reuse the same functions bin/bt.ml already calls; the evaluation must return the final bar's target exposure), the Tiingo fetch routine, cache reads.

**Produces (consumed by Task 3):**
- `val provisional_bar : snapshot_t -> bar` (today's o/h/l, latest as close)
- `val cache_is_fresh : last_cached:string -> prev_trading_day:string -> bool`
- `val desired_shares : target:float -> equity:float -> price:float -> int` (floor toward zero)
- `val order_delta : desired:int -> held:float -> int` (desired - round held)
- `val below_threshold : delta:int -> price:float -> bool` ($1 minimum order value)
- `val client_order_id : symbol:string -> date:string -> string` (`bt-<symbol>-<YYYY-MM-DD>`)
- `val decide : mode -> strat_path:string -> data_dir:string -> decision` where `decision` carries fetched-through date, provisional bar, target, equity, held, and `action = Order of {side; qty; id} | Skip of string` - the whole cycle up to but excluding submission.

- [ ] RED: pure-function tests with hand-derived values: `desired_shares` (target 1.994, equity 10000., price 500. -> 39; negative target -> negative shares; flooring toward zero both signs), `order_delta`, `below_threshold` boundary at exactly $1, `client_order_id` format, `cache_is_fresh` (equal dates true, older false), `provisional_bar` field mapping from a snapshot record. Plus a CLI test: a tw strat under `bt target` exits with the usage error `live trading supports us only` (match arms, never if-else).
- [ ] Run: expected FAIL, `Live` module undefined. Record.
- [ ] GREEN: implement lib/live.ml pure parts and `decide` (composing fetch, staleness check, snapshot, engine evaluation, account+position reads); wire `bt target <strat> [--live] [--data-dir DIR]` in bin/bt.ml printing the decision one field per line and never submitting. Market check is a `match` on the strat's market.
- [ ] Docs: cli.md gains the `bt target` section (flags, env vars, mode default, output fields).
- [ ] Run: suite green. TW byte-identity gate. Commit `feat: live decision core and bt target` (ChatGPT trailer).

## Task 3: daemon, docs, and smoke

**Files:** modify lib/live.ml, lib/live.mli, bin/bt.ml, test/test_bt.ml, docs/cli.md, docs/engine.md, CHANGELOG.md.

**Consumes:** Tasks 1-2 signatures exactly as listed.

- [ ] RED: schedule arithmetic tests on a pure helper `next_actions : now:string -> next_close:string -> [`Sleep_until of string | `Decide | `Submit_window | `Post_close]` (RFC3339 inputs; decide at close-15min, submit by close-10min, early-close timestamps like 13:00 ET handled by the same arithmetic - fixture uses one 16:00 close and one 13:00 close). Startup-guard test: account status not ACTIVE or trading_blocked true -> refuse to start (pure predicate `startup_ok : account_t -> (unit, string) result`).
- [ ] Run: expected FAIL. Record.
- [ ] GREEN: daemon loop in lib/live.ml - wake, clock, fetch at close-15, `decide`, query-then-submit via `order_by_client_id` then `submit_moc` by close-10, post-close poll and fill log, sleep to next open; every failure path logs one ASCII line and skips the day (spec Safety section verbatim). `bt live <strat> [--live] [--data-dir DIR]` wired with startup banner (mode, account number, equity).
- [ ] Docs: cli.md `bt live` section; engine.md gap section one-line addition (live daemon implements the close-fill assumption via provisional evaluation at close minus 15 minutes plus MOC); CHANGELOG `[Unreleased]` Added entry.
- [ ] Run: suite green. TW byte-identity gate.
- [ ] Smoke (needs user-side keys): `bt target` on a `stock "us/SPY"` buy-and-hold temp strat against the paper account; record output in the report. If keys are unavailable in the sandbox, record the exact command for the user and mark the step deferred - do not fake output.
- [ ] Commit `feat: bt live daemon` then `docs: live trading` (ChatGPT trailer).

## Reviews

Reviewer agent after each task (diff against the task's base, spec compliance + code quality, file:line evidence); fix waves re-gate and re-review before the next task starts. Final whole-branch review after Task 3.
