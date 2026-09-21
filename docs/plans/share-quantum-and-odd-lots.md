# Share Quantum and Odd Lots Implementation Plan

> **For agentic workers:** Implementers use superpowers:executing-plans ONLY, one task per dispatch. Implementers never dispatch subagents of any kind; the coordinator owns every review. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Execute docs/specs/share-quantum-and-odd-lots.md: make `--capital` mandatory, round TW backtest and live quantities to whole shares (cash) and whole lots (margin) through one profile-driven rule in the engine, submit TW cash legs as `Common` plus `IntradayOdd` orders, and move US live to fractional market day orders.

**Architecture:** `Engine.market_profile` gains `cash_share_quantum` and `margin_share_quantum`; `Engine.plan_fills` floors planned quantities to them using the now-mandatory capital scale. `Live.legs_of_plan` translates floored share counts into Shioaji lot and odd-lot orders; `Alpaca` submits fractional market day orders. Docs and the changelog are updated and `[0.10.0]` is cut at the end.

**Tech stack:** OCaml stdlib + unix, curl and jq subprocesses, dune per-concern libraries, assert tests with JSON fixtures.

## Contents

- [Global constraints](#global-constraints)
- [Task 1: mandatory capital](#task-1-mandatory-capital)
- [Task 2: engine share quantum](#task-2-engine-share-quantum)
- [Task 3: TW fee defaults](#task-3-tw-fee-defaults)
- [Task 4: TW live lot and odd-lot orders](#task-4-tw-live-lot-and-odd-lot-orders)
- [Task 5: US live fractional shares](#task-5-us-live-fractional-shares)
- [Task 6: docs, changelog, release cut](#task-6-docs-changelog-release-cut)
- [Reviews](#reviews)

## Global constraints

- Work in the worktree `/sandbox/stock-tw-live` on branch `tw-live`. Use the switch with `opam exec --switch=/sandbox/stock -- ...`. Daily caches are read via `--data-dir /sandbox/stock/data`.
- The spec docs/specs/share-quantum-and-odd-lots.md is binding: copy field names, enum values, flag names, and error messages from it and from this plan verbatim.
- Strict TDD per behavior: failing test first with recorded red output in the task report, then minimal code, then green with the full suite. Hand-derived fixtures with derivation comments.
- Code style per CONTRIBUTING.md Style rules and skill://ponytail: OCaml stdlib and `unix` only; no `for`/`while`; `let () = e in` sequencing; market branching with `match` arms; tail-recursive list recursion; preserve floating-point operation order; one space around `=`; curl and jq for network and JSON; ASCII only; no `ref`/`mutable` outside the existing `Arg` parsing; every new export has an `.mli` doc comment; clean, minimal, no speculative abstraction.
- Use the `lsp` tool (ocamllsp is configured for this worktree) for definitions and references; do not grep blindly for symbols.
- Docs per CONTRIBUTING.md Documentation style: one H1, disciplined H2-H4, fixed alert semantics, tables with a Default column in cli.md, full-depth ToCs, ASCII only, no mid-sentence hard wraps, US and TW sections parallel.
- Gates after every task: `opam exec --switch=/sandbox/stock -- dune build --root /sandbox/stock-tw-live` exit 0; `opam exec --switch=/sandbox/stock -- dune runtest --root /sandbox/stock-tw-live --force` exit 0; the byte-identity gates defined in Task 1 (US) and Task 2 (TW) as they come into force.
- No network in tests. The only network smoke (Task 4) needs the user's Shioaji server; record exact commands and defer when absent; never fake output. Never place a broker order without the user's explicit approval in the coordinator session.
- Codex exhaustion (`usage_limit_reached`): pause and wait for restoration; never substitute a backend.
- Git: commits only, NEVER push, NEVER touch git settings or the author field; trailer `Co-authored-by: ChatGPT <noreply@openai.com>`. The coordinator confirms every commit with the user first.
- Report per task: `/sandbox/stock-tw-live/.superpowers/sdd/share-quantum-and-odd-lots/task-<n>-report.md` with red/green evidence.

## Task 1: mandatory capital

**Files:** modify engine/engine.ml, engine/engine.mli, bin/bt.ml, broker/live.ml, test/test_bt.ml, examples/*.strat invocations in README.md and docs/strategy.md only where a command line is shown (docs proper are Task 6).

**Interfaces:**
- Consumes: `Engine.charge costs capital index ~equity_before ~delta ~price`, `Engine.absolute_sell_cost costs capital index ~price value`, `Engine.plan_fills ~costs ~capital:(float option) ...`, `Engine.run ... ~capital:(float option) ~fill`, `bin/bt.ml` `run_command` and `daytrade_command` `capital : float option ref`.
- Produces: `Engine.plan_fills ~capital:float`, `Engine.run ~capital:float`, `Engine.charge costs capital` with `capital : float`, `Engine.absolute_sell_cost` with `capital : float`; `bt run` and `bt daytrade` reject a missing `--capital` with the usage error `run: --capital is required` and `daytrade: --capital is required`.

- [ ] RED: in test/test_bt.ml add a CLI test that runs `bt run` on the existing TW fixture strategy without `--capital` and asserts the first stderr line is exactly `run: --capital is required` and exit code 2; and the same for `bt daytrade` with `daytrade: --capital is required`. Add an engine test asserting `Engine.plan_fills` applied at `~capital:1.` on the Task 2 sentinel state (equity 1,000,000, price 10, TW default costs, target 1) charges the TWD 20 minimum: expected `plan_trade_cost` for a 1,000,000 buy is `max(1000000 * 3.99 / 10000, 20) = 399.` (derivation comment: 3.99 bps of 1,000,000 is 399, above the 20 minimum).
- [ ] Run: `opam exec --switch=/sandbox/stock -- dune runtest --root . --force`. Expected: FAIL (CLI currently accepts the missing flag; engine signature is `float option`). Record.
- [ ] GREEN: change `capital : float option` to `capital : float` in `charge`, `absolute_sell_cost`, `plan_fills`, and `run` in engine/engine.ml and engine/engine.mli; delete the `| _ -> commission` and `| _ -> 0.` no-capital arms so `min_fee` and per-share fees always apply. In bin/bt.ml, keep `capital : float option ref` for `Arg` parsing and resolve it with `match !capital with Some value when Float.is_finite value && value > 0. -> value | _ -> usage_error "run: --capital is required"` (and the daytrade equivalent) before calling the engine. In broker/live.ml change `~capital:(Some 1.)` to `~capital:1.` at the TW planner call and any `Some equity`/`None` at other engine calls. Update the two usage strings at bin/bt.ml lines 12 and 14 to `--capital TWD` and `--capital USD` without brackets.
- [ ] Update every test call to `Engine.run`/`Engine.plan_fills` from `~capital:None` or `~capital:(Some x)` to a float; re-derive `test_engine_buyhold_costs` once with `~capital:1.` (the US sentinel; record the old and new pinned values in the report) and pin it.
- [ ] Capture the US byte-identity reference at the commit BEFORE this task: build `git stash`-free from `HEAD` in a temporary tree (`git archive HEAD | tar -x -C <tmp>`), run `<tmp>/_build/default/bin/bt.exe run /sandbox/research/strategies/us/dd_ladder/main.strat --baseline us/TQQQ --capital 100000 --data-dir /sandbox/stock/data --out-dir <ref> --out-name fp --no-plot`, and save stdout, `fp.csv`, `main.trades.csv` plus a `provenance.json` (commit, command, cache last row) under `.superpowers/sdd/share-quantum-and-odd-lots/us-baseline/`. Every later US gate reruns this exact command with the current binary and compares byte for byte.
- [ ] Gate: build, full suite, and the current binary's output for the same US command byte-identical to `us-baseline`. Commit `feat: require --capital for bt run and bt daytrade`.

## Task 2: engine share quantum

**Files:** modify engine/engine.ml, engine/engine.mli, broker/live.ml (pass the profile), test/test_bt.ml.

**Interfaces:**
- Consumes: Task 1 `plan_fills ~capital:float`; `Engine.market_profile`; `Engine.profile_of_market`.
- Produces: `Engine.market_profile` gains `cash_share_quantum : float` and `margin_share_quantum : float` (TW `1.` and `1000.`, US `0.` and `0.`); `Engine.plan_fills` gains `~profile:market_profile`; `Engine.run` passes its `~profile` through.

- [ ] RED: add `test_engine_share_quantum`: TW profile, capital 1,000,000 (so normalized 1 = TWD 1,000,000), price 10, target 1 from cash 1: expected `plan_buy_cash` value corresponds to `floor(1000000 / 10) = 100000` shares, i.e. `plan_buy_cash = 1000000.` (derivation: exact multiple, no change); then price 11: `floor(1000000 / 11) = 90909` shares, `plan_buy_cash = 90909 * 11 = 999999.` (derivation comment shows the floor). Margin case: target 2 with ratio 0.6 at price 11: margin shares floor to a multiple of 1000, so the margin buy is `floor(1000000 / 11 / 1000) * 1000 = 90000` shares = `990000.` value. Refinance case: reuse the existing `test_engine_fill_planner` scale-in fixture at price 10 and assert the refinance value is a multiple of `10 * 1000`. US profile: identical inputs produce the pre-change fractional values (assert equality with the numbers the existing planner test already pins).
- [ ] Run: expected FAIL, `profile` argument unbound. Record.
- [ ] GREEN: add the two fields to `market_profile` in engine.mli and `profile_of_market` in engine.ml; add `~profile` to `plan_fills`; inside `compute_plan`, immediately after each of `sell_margin`, `sell_cash`, cash buy, margin buy, and both refinance amounts is computed, apply `floor_value ~quantum ~price value = if quantum > 0. then Float.floor (value *. capital /. price /. quantum) *. quantum *. price /. capital else value` with the cash quantum for cash quantities and the margin quantum for margin and refinance quantities. Keep the remainder in cash by leaving `available`/`cash` arithmetic untouched (it uses the floored trade values). `Engine.run` passes `~profile` at its existing partial application. `Live.decide` passes `Engine.profile_of_market "tw"` (US arm unchanged because it does not call the planner).
- [ ] Gate: build; full suite; US byte-identity (Task 1 reference) unchanged; capture the NEW TW reference from the current binary with `--capital 1000000` on `/sandbox/research/strategies/tw/channel_ladder/main.strat --baseline tw/00685L`, hand-check the first fill in `main.trades.csv` (share count is `floor(value / price)`, commission is the max of 3.99 bps and 20), and save it under `.superpowers/sdd/share-quantum-and-odd-lots/tw-baseline/` with provenance. Commit `feat: floor TW quantities to shares and lots in the engine`.

## Task 3: TW fee defaults

**Files:** modify engine/engine.ml, test/test_bt.ml.

**Interfaces:**
- Consumes: `Engine.default_costs ~market:"tw"`.
- Produces: TW `fee_bps = 2.85`, `min_fee = 1.`.

- [ ] RED: assert `(Engine.default_costs ~market:"tw" ~symbol:"2330").fee_bps = 2.85` and `.min_fee = 1.`; assert a TWD 1,000 buy at capital 1 charges `max(1000 * 2.85 / 10000, 1) = 1.` (derivation: 0.285 is below the 1 minimum) and a TWD 100,000 buy charges `28.5`.
- [ ] Run: expected FAIL on 3.99/20. Record.
- [ ] GREEN: change the two literals in `default_costs`. Re-pin any TW cost test that hard-codes 3.99 or 20 with a derivation comment; re-capture the TW reference from Task 2 (the fee change alters it) and record the hand-check again.
- [ ] Gate: build; full suite; US reference unchanged; TW reference re-captured. Commit `feat: SinoPac promotion commission defaults for TW`.

## Task 4: TW live lot and odd-lot orders

**Files:** modify broker/shioaji.ml, broker/shioaji.mli, broker/live.ml, broker/live.mli, test/test_bt.ml, test/fixtures/shioaji/positions_share.json (new).

**Interfaces:**
- Consumes: Task 2 floored plan values; `Shioaji.place_order`, `Shioaji.positions`, `Live.legs_of_plan`, `Live.execute_tw_legs`.
- Produces: `Shioaji.lot = Common | IntradayOdd`; `Shioaji.order_request = { exchange; code; action; lot : lot; quantity : int; cond; custom_field }` (quantity in lots for `Common`, shares for `IntradayOdd`); `Shioaji.positions ()` requests `unit:"Share"` and `position.shares : int` replaces `lots`; `Live.leg = { action; cond; lot : Shioaji.lot; quantity : int }`; `Live.legs_of_plan ~price plan` returns the split legs.

- [ ] Verify the odd-lot order contract: fetch the official stock-order reference (`curl -sS https://sinotrade.github.io/tutor/order/Stock/`) and record in the report whether `IntradayOdd` accepts `price_type: MKT`; if it requires `LMT`, use the snapshot ask for buys and bid for sells and say so in the report and the docs.
- [ ] RED: `test_tw_live_legs_split`: at price 10, a cash buy value of 865,800 (86,580 shares) yields `[ {Buy; Cash; Common; 86}; {Buy; Cash; IntradayOdd; 580} ]`; 9,990 (999 shares) yields only the odd leg; 10,000 yields only `Common 1`; a margin buy value of 865,800 yields `Common 86` only (580 shares retained; the engine already floored to 86,000 so the plan value is 860,000 and the test asserts that). Refinance values yield `Common` only. `test_tw_live_positions_share`: a fixture with `quantity: 1` under `unit: Share` totals 1 share. Executor tests with the injected callbacks: a leg whose `Common` order fails still submits its `IntradayOdd` order; `mode = Paper` skips odd orders and logs `submitted=skip:odd-lot-unsupported-in-simulation`; an `IntradayOdd` sell today followed by a planned `IntradayOdd` buy is refused with a stop reason; funding math for a `Common` fill of 86 lots uses 86,000 shares.
- [ ] Run: expected FAIL. Record.
- [ ] GREEN: add `lot` and the record changes in shioaji.ml/.mli; `place_order` emits `order_lot` from `lot` and `quantity` as given; `positions` sends `unit:"Share"` and parses `quantity` as shares. In live.ml, `legs_of_plan` computes `shares = int_of_float (Float.floor (value /. price))` then splits cash legs into `shares / 1000` lots and `shares mod 1000` odd shares, margin and refinance legs into `shares / 1000` lots only. `execute_tw_legs` treats the lot and odd orders of one leg as independent, converts `Common` fills to shares by `* 1000`, applies the same-day opposite-direction odd guard from the trades listing, and skips odd orders when the daemon mode is `Paper`. `position_totals` and `equity_of` use shares directly.
- [ ] Gate: build; full suite; TW and US references unchanged (live-only change). Smoke: bless `cp _build/default/bin/bt.exe /sandbox/stock/bt-test<n+1>.exe && chmod +x` with a fresh n and run `SHIOAJI_URL=http://shioaji-server:8081 /sandbox/stock/bt-test<n+1>.exe target /sandbox/research/strategies/tw/channel_ladder/main.strat --equity 1000000 --data-dir /sandbox/stock/data` against the simulation server if the coordinator confirms it is in simulation mode; record output; production submission only on the user's explicit approval. Commit `feat: TW live submits Common lots plus IntradayOdd remainders`.

## Task 5: US live fractional shares

**Files:** modify broker/alpaca.ml, broker/alpaca.mli, broker/live.ml, broker/live.mli, test/test_bt.ml.

**Interfaces:**
- Consumes: `Alpaca.submit_moc mode ~symbol ~qty ~side ~client_order_id`, `Live.desired_shares`, `Live.order_delta`, `Live.decide_action`, `Live.action = Order of { side; qty : int; id }`.
- Produces: `Alpaca.submit_market mode ~symbol ~qty:float ~side ~client_order_id` sending `{symbol, qty (string with up to 9 decimals, trailing zeros trimmed), side, type:"market", time_in_force:"day", client_order_id}`; `Live.action = Order of { side; qty : float; id }`; `Live.desired_shares ~target ~equity ~price : float`; `Live.order_delta ~desired ~held : float`.

- [ ] RED: `test_us_live_fractional`: target 0.5, equity 1,000, price 300 -> desired `1.6666666667` shares (derivation: 500 / 300); held 0 -> order qty `1.666666667` (9 decimals); delta whose notional is below USD 1 (`0.002` shares at 300) is skipped with the existing message; `Alpaca.order_body` output parsed with jq has `type == "market"`, `time_in_force == "day"`, and `qty == "1.666666667"`. Existing MOC tests are deleted (they pin the removed behavior).
- [ ] Run: expected FAIL. Record.
- [ ] GREEN: rename `submit_moc` to `submit_market`, change `qty` to float formatted with `Printf.sprintf "%.9f"` then trailing-zero trimmed, set `time_in_force:"day"`; in live.ml make `desired_shares` return `target *. equity /. price`, `order_delta` return `desired -. held`, `below_threshold` compare `abs_float (delta *. price) < 1.`, and `Order.qty` a float; the daemon submits at the existing decision time and no longer waits for the MOC cutoff (delete `can_submit_moc` and the `Submit_window` phase if nothing else uses them; check with `lsp references`).
- [ ] Gate: build; full suite; US and TW references unchanged (live-only). Commit `feat: US live submits fractional market day orders`.

## Task 6: docs, changelog, release cut

**Files:** modify docs/cli.md, docs/engine.md, docs/specs/tw-live-trading.md, README.md, docs/strategy.md, CHANGELOG.md, CONTRIBUTING.md (only if a rule text changes).

- [ ] docs/cli.md: `bt run` and `bt daytrade` tables mark `--capital` required with Default `-`; delete every "applies only with `--capital`" clause; TW cost rows 2.85 bps and TWD 1 minimum; `bt target` and `bt live` US sections describe the fractional market day order and remove MOC; TW sections describe `Common` plus `IntradayOdd` cash legs, lots-only margin and refinance legs, the simulation skip, the same-day odd guard, and `unit: Share` positions. Keep US and TW subsections parallel.
- [ ] docs/engine.md: sizing row (TW whole shares and lots, US fractional), TW cost defaults, US live fidelity (near-close market fill covered by `--slip-bps`), TW live fidelity (odd fills priced in the odd book).
- [ ] docs/specs/tw-live-trading.md: replace board-lot sentences with references to docs/specs/share-quantum-and-odd-lots.md.
- [ ] README.md and docs/strategy.md: every `bt run` or `bt daytrade` command line carries `--capital`.
- [ ] CHANGELOG.md: add under `[Unreleased]` a `### Changed` list: `--capital` required for `bt run` and `bt daytrade`; TW quantities floored to whole shares (cash) and 1000-share lots (margin) in backtest and live; TW default commission 0.0285% with TWD 1 minimum; TW live submits `Common` lots plus one `IntradayOdd` remainder per cash leg; US live submits fractional market day orders instead of market-on-close. Then rename `## [Unreleased]` to `## [0.10.0] - <today>`, add an empty `## [Unreleased]` above it, and update the compare links (`[Unreleased]: .../compare/v0.10.0...HEAD`, `[0.10.0]: .../compare/v0.9.0...v0.10.0`). The tag and GitHub pre-release are the user's.
- [ ] Regenerate every ToC; verify anchors, ASCII, and no hard wraps with a script; record the output in the report.
- [ ] Gate: build and full suite (docs only, but confirm nothing broke). Commit `docs: share quantum, odd lots, and v0.10.0`.

## Reviews

Reviewer agent dispatched by the coordinator after each task (diff against the task's base; spec compliance plus code quality with file:line evidence and executable reproductions); the coordinator validates findings by execution before dispatching fixes; fix waves re-gate and re-review before the next task starts. Final whole-branch review after Task 6.
