# US Live Planner Implementation Plan

> **For the coordinator:** REQUIRED SUB-SKILL: superpowers:executing-plans; implement this plan task-by-task and track its `- [ ]` steps. The coordinator owns every review and assigns Task 5 to the doc-editor.

Implementers use executing-plans only. No subagents: never dispatch a reviewer or any other agent; the coordinator owns reviews.

**Goal:** Size US live and `bt target` orders through the same `Engine.plan_fills` used by `bt run`, including leveraged targets, using Alpaca's account debit as one margin lot.

**Architecture:** Extend the Alpaca account parse, map signed cash and the held stock at the provisional close into a one-asset `Engine.plan_state`, and call the existing planner from a pure US action function. Keep the effective-target and on_change policy in `Live.decide`, expose the planner's cash and debit in both decisions, and leave the engine and order submission unchanged.

**Tech Stack:** OCaml, dune, the project-local opam switch, jq fixtures, plain asserts in `test/test_bt.ml`.

## Contents

- [Global Constraints](#global-constraints)
- [Tasks](#tasks)
  - [Task 1: Parse the Alpaca account's cash and market values](#task-1-parse-the-alpaca-accounts-cash-and-market-values)
  - [Task 2: Map an Alpaca debit into one pure engine plan state](#task-2-map-an-alpaca-debit-into-one-pure-engine-plan-state)
  - [Task 3: Plan the pure US action, guard the account, and prove quantity parity](#task-3-plan-the-pure-us-action-guard-the-account-and-prove-quantity-parity)
  - [Task 4: Route the US decision through the planner and expose cash and debit](#task-4-route-the-us-decision-through-the-planner-and-expose-cash-and-debit)
  - [Task 5: Update live, CLI, engine fidelity, and changelog docs](#task-5-update-live-cli-engine-fidelity-and-changelog-docs)
- [Coordinator acceptance after the branch](#coordinator-acceptance-after-the-branch)
- [Self-Review](#self-review)

## Global Constraints

- Implement `docs/specs/us-live-planner.md` exactly. Do not change `engine/`, add dependencies, implement short or multi-stock trading, accrued interest, maintenance or margin-call cures, or use the intraday multiplier. Preserve `run_us`'s startup log from Alpaca `account.equity`; US decision equity comes from the mapped state instead.
- Implementers work in `/sandbox/stock-us-planner`, an isolated worktree created by the coordinator. Every file read, edit, and command uses absolute paths in that worktree; never edit, stage, commit, or build in `/sandbox/stock`. The explicitly pinned `/sandbox/stock/data` cache, `/sandbox/stock/.superpowers/sdd/us-paper-test/` baseline files, `/sandbox/research/strategies/` research files, and `/sandbox/stock` opam switch are read-only inputs to the gates. Set command working directory to `/sandbox/stock-us-planner`; the mandated dune `--root .` resolves there. The coordinator creates the worktree before execution; no task creates it.
- Never make network calls during implementation or verification. Never invoke `bt live` or `bt target` against a broker in any task. The paper-account acceptance in the spec is a separate coordinator activity after this branch, not an implementer task or an offline gate.
- Follow `CONTRIBUTING.md`: ASCII-only code and docs, exactly one space around `=`, no alignment spaces, no `for`/`while` loops in new code, tail-recursive list traversal, warnings as errors, and preserve floating-point operation order. Follow `AGENTS.md`: market dispatch must use `match` arms (`| "tw"`, `| "us"`) and a default/error arm, never `if market = ...`.
- Assert-based tests belong in `/sandbox/stock-us-planner/test/test_bt.ml` and must be registered in its final `let ()` list. Reuse `assert_close`, `assert_failure`, `with_temp_strategy`, the existing injected `Live.decide` pattern for TW, and the Alpaca JSON fixture pattern. Above every non-trivial expected value, write its independent derivation. No broker-backed US decision test: `Live.decide` fetches Tiingo and Alpaca; test its actual pure US callee instead.
- At each GREEN gate run `opam exec --switch=/sandbox/stock -- dune build --root .` and `opam exec --switch=/sandbox/stock -- dune runtest --root . --force` from `/sandbox/stock-us-planner`, both exit 0. Also run the six byte comparisons below after every task; all six `cmp` calls must exit 0. These baselines are pinned from v0.10.1. The US gate is on `bt run` only, which this feature does not touch; it proves no engine regression, not live correctness. Undeclared-strategy warnings are stderr only.
- For the byte gate, create fresh output directories, use exactly these two strategies, baselines and capitals, and compare stdout, equity CSV and trades CSV. Do not change the research strategies or their baselines:

```sh
us_out=$(mktemp -d)
tw_out=$(mktemp -d)
/sandbox/stock-us-planner/_build/default/bin/bt.exe run /sandbox/research/strategies/us/dd_ladder/main.strat --baseline us/TQQQ --capital 100000 --data-dir /sandbox/stock/data --out-dir "$us_out" --out-name fp --no-plot > "$us_out/stdout.txt"
cmp "$us_out/stdout.txt" /sandbox/stock/.superpowers/sdd/us-paper-test/us-baseline/stdout.txt
cmp "$us_out/fp.csv" /sandbox/stock/.superpowers/sdd/us-paper-test/us-baseline/fp.csv
cmp "$us_out/main.trades.csv" /sandbox/stock/.superpowers/sdd/us-paper-test/us-baseline/main.trades.csv
/sandbox/stock-us-planner/_build/default/bin/bt.exe run /sandbox/research/strategies/tw/channel_ladder/main.strat --baseline tw/00685L --capital 1000000 --data-dir /sandbox/stock/data --out-dir "$tw_out" --out-name fp --no-plot > "$tw_out/stdout.txt"
cmp "$tw_out/stdout.txt" /sandbox/stock/.superpowers/sdd/us-paper-test/tw-baseline/stdout.txt
cmp "$tw_out/fp.csv" /sandbox/stock/.superpowers/sdd/us-paper-test/tw-baseline/fp.csv
cmp "$tw_out/main.trades.csv" /sandbox/stock/.superpowers/sdd/us-paper-test/tw-baseline/main.trades.csv
```

- At every commit step: **Commit only after the coordinator confirms; use the co-author trailer the coordinator names; never push; never change git settings.** The commands shown are for execution after that confirmation only. This planning assignment itself stages and commits nothing.

---

## Tasks

### Task 1: Parse the Alpaca account's cash and market values

**Files:**
- Modify: `/sandbox/stock-us-planner/broker/alpaca.ml:10-15,102-113`
- Modify: `/sandbox/stock-us-planner/broker/alpaca.mli:12-18`
- Test: `/sandbox/stock-us-planner/test/test_bt.ml:4551-4560,5145-5158` (existing registration `test_alpaca_account_parse ()` stays)
- Read-only fixture: `/sandbox/stock-us-planner/test/fixtures/alpaca/account.json`

**Interfaces:**
- Consumes: `Alpaca.parse_account : string -> Alpaca.account_t`, `float_field : string -> string -> float`, `alpaca_fixture : string -> string`.
- Produces: `Alpaca.account_t` with `cash : float`, `long_market_value : float`, and `short_market_value : float` in both `.ml` and `.mli`, alongside existing `equity`, `status`, `trading_blocked`, and `account_number`. `parse_account` projects and parses all seven fields. Task 3 consumes those exact names; `account.equity` remains for startup only.

- [ ] **Step 1 (RED): Extend the existing fixture parse assertion and the startup-test account literal.** The latter must compile once the new record type lands; preserve the startup status checks.

```ocaml
(* test_alpaca_account_parse; fixture has equity = -23140.2 + 126960.76 + 0. *)
  let expected : Alpaca.account_t =
    { equity = 103820.56;
      cash = -23140.2;
      long_market_value = 126960.76;
      short_market_value = 0.;
      status = "ACTIVE";
      trading_blocked = false;
      account_number = "010203ABCD" }
```

```ocaml
(* test_live_startup_guard; no position and no debit imply equity = cash. *)
  let account : Alpaca.account_t =
    { equity = 10000.;
      cash = 10000.;
      long_market_value = 0.;
      short_market_value = 0.;
      status = "ACTIVE";
      trading_blocked = false;
      account_number = "paper-account" }
```

- [ ] **Step 2 (RED): Run the full assert executable before changing the account type.**

```sh
opam exec --switch=/sandbox/stock -- dune runtest --root . --force
```

Expected: compilation fails because `Alpaca.account_t` has no `cash`, `long_market_value`, or `short_market_value` fields.

- [ ] **Step 3 (GREEN): Add the three fields to both record declarations and extend the jq projection and parse.** Preserve the existing projection order for its first field and its `float_field` parsing; `float_field` permits NaN/infinity, which Task 3 rejects for cash before planning.

```ocaml
(* broker/alpaca.ml and broker/alpaca.mli: account_t *)
  equity : float;
  cash : float;
  long_market_value : float;
  short_market_value : float;
  status : string;
  trading_blocked : bool;
  account_number : string;
```

```ocaml
(* broker/alpaca.ml: replace parse_account *)
let parse_account raw =
  match
    jq_fields "account"
      "[.equity, .cash, .long_market_value, .short_market_value, .status, (.trading_blocked | tostring), .account_number] | @tsv"
      raw
  with
  | [equity; cash; long_market_value; short_market_value; status;
     trading_blocked; account_number] ->
      { equity = float_field "account equity" equity;
        cash = float_field "account cash" cash;
        long_market_value = float_field "account long_market_value" long_market_value;
        short_market_value = float_field "account short_market_value" short_market_value;
        status;
        trading_blocked = bool_field "account trading_blocked" trading_blocked;
        account_number }
  | _ -> failwith "invalid Alpaca account response"
```

- [ ] **Step 4 (GREEN): Run both dune commands and all six byte comparisons from Global Constraints.** The fixture assertion must pass; startup tests must compile; every gate exits 0.

```sh
opam exec --switch=/sandbox/stock -- dune build --root .
opam exec --switch=/sandbox/stock -- dune runtest --root . --force
```

- [ ] **Step 5: Commit this account slice only after confirmation.**

```sh
git -C /sandbox/stock-us-planner add broker/alpaca.ml broker/alpaca.mli test/test_bt.ml
git -C /sandbox/stock-us-planner commit -m "feat: parse Alpaca cash and market values"
```

Commit only after the coordinator confirms; use the co-author trailer the coordinator names; never push; never change git settings.

### Task 2: Map an Alpaca debit into one pure engine plan state

**Files:**
- Modify: `/sandbox/stock-us-planner/broker/live.ml:67-87` (insert beside `client_order_id`, before replacing the old actions in Task 3)
- Modify: `/sandbox/stock-us-planner/broker/live.mli:60-78`
- Test: `/sandbox/stock-us-planner/test/test_bt.ml:4703-4704,7775-7779`

**Interfaces:**
- Consumes: `Engine.plan_state` from `engine/engine.mli:93-104`; no broker call. The caller in Task 3 supplies `(Engine.profile_of_market "us").default_financing_ratio`, currently `0.5`.
- Produces exactly `Live.us_plan_state : cash:float -> held:float -> price:float -> ratio:float -> previous_target:float -> Engine.plan_state`. `cash_values`, `margin_values`, and `loans` each have one entry; interest arrays are zero; `previous_targets` has one entry.

- [ ] **Step 1 (RED): Add a three-case pure state test before `test_us_live_fractional` and register it immediately before that test.** Use separate expected values for free cash, ordinary debit, and a debit exceeding the normal initial ratio.

```ocaml
let test_us_plan_state () =
  let state cash held =
    Live.us_plan_state ~cash ~held ~price:100. ~ratio:0.5
      ~previous_target:1.5
  in
  let check cash held ~free ~inventory ~margin ~loan ~equity =
    let actual = state cash held in
    assert_close free actual.Engine.cash;
    assert_close inventory actual.cash_values.(0);
    assert_close margin actual.margin_values.(0);
    assert_close loan actual.loans.(0);
    assert_close equity actual.equity;
    assert (actual.interests = [| 0. |]);
    assert (actual.tail_interests = [| 0. |]);
    assert (actual.debt = 0. && actual.receivables = 0.);
    assert (actual.previous_targets = [| 1.5 |])
  in
  (* 100 shares * 100 = 10000; no debit; 50000 + 10000 = 60000. *)
  check 50000. 100. ~free:50000. ~inventory:10000. ~margin:0.
    ~loan:0. ~equity:60000.;
  (* 600 * 100 = 60000; debit 20000 funds 40000 of margin inventory. *)
  check (-20000.) 600. ~free:0. ~inventory:20000. ~margin:40000.
    ~loan:20000. ~equity:40000.;
  (* 40000 / 0.5 = 80000 exceeds value 60000; clamp margin to 60000. *)
  check (-40000.) 600. ~free:0. ~inventory:0. ~margin:60000.
    ~loan:40000. ~equity:20000.
```

```ocaml
(* Final let () registration, after test_live_pure_decisions. *)
  test_live_pure_decisions ();
  test_us_plan_state ();
  test_us_live_fractional ();
```

- [ ] **Step 2 (RED): Run the assert executable; `Live.us_plan_state` is not exported yet.**

```sh
opam exec --switch=/sandbox/stock -- dune runtest --root . --force
```

- [ ] **Step 3 (GREEN): Add the documented signature in `broker/live.mli`, and add the exact one-stock mapping in `broker/live.ml`.** This does not check the account; Task 3 validates it before calling the planner. Use the provisional trade price, not `long_market_value`, for `value`. No accrued interest is available from Alpaca.

```ocaml
(* broker/live.mli, beside client_order_id *)
(** Map Alpaca signed cash and one holding at the provisional price to one
    engine margin lot; unposted interest is unavailable and stays zero. *)
val us_plan_state :
  cash:float -> held:float -> price:float -> ratio:float ->
  previous_target:float -> Engine.plan_state
```

```ocaml
(* broker/live.ml, after client_order_id *)
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

- [ ] **Step 4 (GREEN): Run both dune commands and the six byte comparisons in Global Constraints.** All must exit 0.

```sh
opam exec --switch=/sandbox/stock -- dune build --root .
opam exec --switch=/sandbox/stock -- dune runtest --root . --force
```

- [ ] **Step 5: Commit the pure state mapper only after confirmation.**

```sh
git -C /sandbox/stock-us-planner add broker/live.ml broker/live.mli test/test_bt.ml
git -C /sandbox/stock-us-planner commit -m "feat: map US account debit to one planner lot"
```

Commit only after the coordinator confirms; use the co-author trailer the coordinator names; never push; never change git settings.

### Task 3: Plan the pure US action, guard the account, and prove quantity parity

**Files:**
- Modify: `/sandbox/stock-us-planner/broker/live.ml:67-87` (add new function; old ones remain until Task 4)
- Modify: `/sandbox/stock-us-planner/broker/live.mli:60-78` (add new public pure seam; remove old entries in Task 4)
- Test: `/sandbox/stock-us-planner/test/test_bt.ml:4703-4821,7775-7780` (new tests here; migration in Task 4)

**Interfaces:**
- Consumes: `Live.us_plan_state : cash:float -> held:float -> price:float -> ratio:float -> previous_target:float -> Engine.plan_state`, Task 1's `Alpaca.account_t`, `Engine.profile_of_market`, `Engine.default_costs`, `Engine.plan_fills`, `Alpaca.qty_string`, `Live.client_order_id`.
- Produces exactly `Live.us_plan_action : rebalance:bool -> symbol:string -> date:string -> account:Alpaca.account_t -> held:float -> price:float -> target:float -> previous_target:float -> Engine.plan_state * Live.action`. Task 4 calls it unchanged and uses the returned state for `decision.equity`, `decision.cash`, and `decision.debit`.

- [ ] **Step 1 (RED): Add a pure fail-closed check with exact errors in the specified order; register it after `test_us_plan_state`.** The on_change pre-check must not suppress an invalid account. Both a reported short value and a negative held quantity are rejected; the 1% mark tolerance is checked on either side.

```ocaml
let test_us_plan_action_checks () =
  let base : Alpaca.account_t =
    { equity = 999999.; cash = 500.; long_market_value = 500.;
      short_market_value = 0.; status = "ACTIVE";
      trading_blocked = false; account_number = "paper-account" }
  in
  let choose account held =
    Live.us_plan_action ~rebalance:false ~symbol:"SPY" ~date:"2025-06-24"
      ~account ~held ~price:100. ~target:0.5 ~previous_target:0.5
  in
  let fails expected account held =
    match choose account held with
    | _ -> assert false
    | exception Failure message -> assert (message = expected)
  in
  (* A non-finite debit cannot be booked into a margin lot. *)
  fails "US account cash is not finite" { base with cash = Float.nan } 5.;
  fails "US account cash is not finite" { base with cash = Float.infinity } 5.;
  (* A short reported by the account or in the one held position is unsupported. *)
  fails "US account holds a short position"
    { base with short_market_value = -100. } 5.;
  fails "US account holds a short position"
    { base with long_market_value = 0. } (-1.);
  (* 1.005 * 500 differs by 2.5 < 1% of 502.5; 1.02 * 500 differs
     by 10 > 1% of 510, implying another symbol in this one-stock account. *)
  let within = { base with long_market_value = 502.5 } in
  let state, action = choose within 5. in
  assert_close 1000. state.Engine.equity;
  assert (action = Live.Skip "target unchanged");
  fails "US account holds other symbols"
    { base with long_market_value = 510. } 5.;
  (* Zero or negative total account value cannot fund a plan. *)
  fails "US account equity is not positive"
    { base with cash = -500. } 5.;
  fails "US account equity is not positive"
    { base with cash = -600. } 5.
```

```ocaml
(* Final registration, immediately before test_us_live_fractional. *)
  test_us_plan_state ();
  test_us_plan_action_checks ();
  test_us_live_fractional ();
```

- [ ] **Step 2 (RED): Add skip and order checks, including a changed-target buy and a full-close sell.** Reuse this test's local account constructor; the `equity` field intentionally differs from the computed equity so using it to size would fail the buy check.

```ocaml
let test_us_plan_action_orders () =
  let account ~cash ~held ~price : Alpaca.account_t =
    { equity = 1.; cash; long_market_value = held *. price;
      short_market_value = 0.; status = "ACTIVE";
      trading_blocked = false; account_number = "paper-account" }
  in
  let choose ~rebalance ~cash ~held ~price ~target ~previous_target =
    Live.us_plan_action ~rebalance ~symbol:"SPY" ~date:"2025-06-24"
      ~account:(account ~cash ~held ~price) ~held ~price ~target
      ~previous_target
  in
  let _, unchanged =
    choose ~rebalance:false ~cash:600. ~held:4. ~price:100.
      ~target:0.5 ~previous_target:0.5
  in
  assert (unchanged = Live.Skip "target unchanged");
  let state, changed =
    choose ~rebalance:false ~cash:600. ~held:4. ~price:100.
      ~target:0.5 ~previous_target:0.2
  in
  (* 600 free + 400 held = 1000; 0.5 exposure means 500 / 100 = 5
     shares, hence one more than the four held. The account.equity is 1. *)
  assert_close 1000. state.Engine.equity;
  assert
    (changed = Live.Order
      { side = `Buy; qty = 1.; id = "bt-SPY-2025-06-24" });
  let _, daily =
    choose ~rebalance:true ~cash:600. ~held:4. ~price:100.
      ~target:0.5 ~previous_target:0.5
  in
  assert (daily = changed);
  let _, idle =
    choose ~rebalance:true ~cash:1000. ~held:0. ~price:100.
      ~target:0. ~previous_target:0.
  in
  assert (idle = Live.Skip "no trade planned");
  let _, tiny =
    choose ~rebalance:true ~cash:0.6 ~held:1. ~price:300.
      ~target:1. ~previous_target:0.
  in
  (* 300.6 equity wants 1.002 shares; 0.002 more costs USD 0.60. *)
  assert (tiny = Live.Skip "below $1 minimum order value");
  let _, close =
    choose ~rebalance:true ~cash:999.4 ~held:0.002 ~price:300.
      ~target:0. ~previous_target:0.002
  in
  (* The full-close plan sets final value to zero: sell all 0.002 shares. *)
  assert (close = Live.Order
    { side = `Sell; qty = 0.002; id = "bt-SPY-2025-06-24" })
```

```ocaml
  test_us_plan_action_checks ();
  test_us_plan_action_orders ();
  test_us_live_fractional ();
```

- [ ] **Step 3 (RED): Add same-state quantity equivalence for four directions.** `Engine.run` overwrites the final equity-curve point after its automatic end-of-run close (`engine/engine.ml:2203-2223`); therefore use **three** flat bars, with the second bar carrying t1 and the third keeping t1, so E2 is the unmodified bar-2 equity. This necessary third observation is the only change to the spec's two-bar test recipe; the tested transition still uses just its first two bars. `~rebalance:false` makes the third bar inert before terminal close.

```ocaml
let test_us_plan_action_matches_run () =
  let price = 100. in
  let capital = 1000. in
  let ratio = (Engine.profile_of_market "us").default_financing_ratio in
  let margin : Engine.margin =
    { financing_rate = 0.; maintenance_override = None;
      ratios = [| ratio |]; loan_term_months = None }
  in
  let bars =
    [| bar "2025-06-23" price price;
       bar "2025-06-24" price price;
       bar "2025-06-25" price price |]
  in
  let check t0 t1 =
    let result =
      Engine.run [| "us/SPY", bars |]
        { Engine.targets = [| [| t0; t1; t1 |] |] }
        [| Engine.default_costs ~market:"us" ~symbol:"SPY" |]
        ~profile:(Engine.profile_of_market "us") ~margin ~capital
        ~fill:Engine.Close_same ~rebalance:false
    in
    let e1 = List.assoc "2025-06-23" result.equity_curve *. capital in
    let e2 = List.assoc "2025-06-24" result.equity_curve *. capital in
    let fill =
      List.find
        (fun (fill : Engine.fill_event) ->
          fill.date = "2025-06-24" && fill.from_e <> fill.to_e)
        result.fills
    in
    let held = fill.from_e *. e1 /. price in
    let cash = e1 -. held *. price in
    let account : Alpaca.account_t =
      { equity = 1.; cash; long_market_value = held *. price;
        short_market_value = 0.; status = "ACTIVE";
        trading_blocked = false; account_number = "paper-account" }
    in
    let state, action =
      Live.us_plan_action ~rebalance:false ~symbol:"SPY"
        ~date:"2025-06-24" ~account ~held ~price ~target:t1
        ~previous_target:t0
    in
    let expected = (fill.to_e *. e2 -. fill.from_e *. e1) /. price in
    (* The flat mark makes bar-1 account cash plus stock equal E1;
       bar-2 target value is to_e * E2 after the planner's sell costs. *)
    assert_close ~tolerance:1e-9 e1 state.Engine.equity;
    match action with
    | Live.Order { side; qty; id } ->
        assert (id = "bt-SPY-2025-06-24");
        assert (side = if expected > 0. then `Buy else `Sell);
        assert_close ~tolerance:1.01e-9 (abs_float expected) qty
    | Live.Skip _ | Live.Orders _ -> assert false
  in
  (* Cash buy/sell, then a margin-funded buy/sell at ratio 0.5. *)
  check 0.3 0.6;
  check 0.6 0.3;
  check 1.5 1.8;
  check 1.5 1.2
```

```ocaml
  test_us_plan_action_orders ();
  test_us_plan_action_matches_run ();
  test_us_live_fractional ();
```

- [ ] **Step 4 (RED): Run the assert executable before adding `us_plan_action`.** It fails compilation on the missing public function; the new tests call no broker or network.

```sh
opam exec --switch=/sandbox/stock -- dune runtest --root . --force
```

- [ ] **Step 5 (GREEN): Export and implement the exact pure action.** Construct state first, validate cash/shorts/other-symbols/equity in that order, then apply the on_change pre-check before planning. The `ponytail:` comment marks the deliberate 1% single-symbol heuristic. Net only ordinary buy and sell fields: equal-value refinancing legs are not broker orders. `plan_final_value = 0.` forces a complete close before 9-decimal formatting.

```ocaml
(* broker/live.mli, after us_plan_state *)
(** Fail closed on unsupported US account states, then plan one Alpaca order
    or skip without broker I/O; return the state used for the decision. *)
val us_plan_action :
  rebalance:bool -> symbol:string -> date:string ->
  account:Alpaca.account_t -> held:float -> price:float ->
  target:float -> previous_target:float -> Engine.plan_state * action
```

```ocaml
(* broker/live.ml, after us_plan_state *)
let us_plan_action ~rebalance ~symbol ~date
    ~(account : Alpaca.account_t) ~held ~price ~target ~previous_target =
  let profile = Engine.profile_of_market "us" in
  let ratio = profile.default_financing_ratio in
  let state =
    us_plan_state ~cash:account.cash ~held ~price ~ratio ~previous_target
  in
  let value = held *. price in
  let () =
    if not (Float.is_finite account.cash) then
      failwith "US account cash is not finite"
  in
  let () =
    if account.short_market_value <> 0. || held < 0. then
      failwith "US account holds a short position"
  in
  let () =
    (* ponytail: 1% tolerance for Alpaca's mark versus provisional close;
       list /v2/positions if false positives start skipping sessions. *)
    if abs_float (account.long_market_value -. value)
       > 0.01 *. account.long_market_value
    then failwith "US account holds other symbols"
  in
  let () =
    if not (Float.is_finite state.equity) || state.equity <= 0. then
      failwith "US account equity is not positive"
  in
  if not rebalance && target = previous_target then
    state, Skip "target unchanged"
  else
    let plan =
      Engine.plan_fills
        ~costs:[| Engine.default_costs ~market:"us" ~symbol |]
        ~capital:1. ~profile ~financing_ratios:[| ratio |] ~state
        ~prices:[| price |] ~targets:[| target |] ~force:rebalance
    in
    let item = plan.planned_assets.(0) in
    let net =
      item.plan_buy_cash +. item.plan_buy_margin
      -. item.plan_sell_cash -. item.plan_sell_margin
    in
    if net = 0. then state, Skip "no trade planned"
    else
      let side, shares =
        if net > 0. then `Buy, net /. price
        else
          `Sell,
          (if item.plan_final_value = 0. then held
           else Float.min (-. net /. price) held)
      in
      let qty = float_of_string (Alpaca.qty_string shares) in
      if qty = 0. || (side = `Buy && qty *. price < 1.) then
        state, Skip "below $1 minimum order value"
      else
        state, Order { side; qty; id = client_order_id ~symbol ~date }
```

- [ ] **Step 6 (GREEN): Run both dune commands and the six comparisons in Global Constraints.** The four backtest transitions agree within one 9-decimal truncation step; all gates exit 0.

```sh
opam exec --switch=/sandbox/stock -- dune build --root .
opam exec --switch=/sandbox/stock -- dune runtest --root . --force
```

- [ ] **Step 7: Commit the pure US planner and checks only after confirmation.**

```sh
git -C /sandbox/stock-us-planner add broker/live.ml broker/live.mli test/test_bt.ml
git -C /sandbox/stock-us-planner commit -m "feat: size US live actions with the engine planner"
```

Commit only after the coordinator confirms; use the co-author trailer the coordinator names; never push; never change git settings.

### Task 4: Route the US decision through the planner and expose cash and debit

**Files:**
- Modify: `/sandbox/stock-us-planner/broker/live.ml:21-28,70-87,609-616,718-769`
- Modify: `/sandbox/stock-us-planner/broker/live.mli:23-31,63-78`
- Modify: `/sandbox/stock-us-planner/bin/bt.ml:682-724`
- Test: `/sandbox/stock-us-planner/test/test_bt.ml:4703-4821,4857-4867,4892-4899,4918-4925,4945-4952,4983-4990,5020-5027,7775-7786`

**Interfaces:**
- Consumes: Task 3's exact `Live.us_plan_action : rebalance:bool -> symbol:string -> date:string -> account:Alpaca.account_t -> held:float -> price:float -> target:float -> previous_target:float -> Engine.plan_state * Live.action` and existing TW `position_totals` loan aggregate.
- Produces: `Live.decision` gains `cash : float` and `debit : float` immediately after `equity` in both record declarations. US uses `state.equity`, `state.cash`, `state.loans.(0)`; TW preserves its `equity`, uses already inferred `cash` and aggregated `loans`. `bt target` prints `cash:` and `debit:` immediately after `equity:` for both markets. Delete `decide_action`, `us_rebalance_action`, and both `.mli` entries, with all test callers migrated.

- [ ] **Step 1 (RED): Migrate the US fractional and on_change tests from both obsolete functions to the new pure seam.** Replace `test_us_live_fractional`'s local `order` and `test_us_live_rebalance_action`'s `choose` and rename that latter test to `test_us_live_plan_policy`; keep every existing assertion and `order_body` check. For the negative raw target in the fractional test use effective target zero, as the real US arm already normalizes it before action selection. Set long market value to `held * price` and signed cash to `equity - held * price`. For the policy test, 4 shares at 100 with 1000 equity means 600 free cash.

```ocaml
(* test_us_live_fractional: replace its local order closure *)
  let order ~target ~equity ~held =
    let account : Alpaca.account_t =
      { equity; cash = equity -. held *. 300.;
        long_market_value = held *. 300.; short_market_value = 0.;
        status = "ACTIVE"; trading_blocked = false;
        account_number = "paper-account" }
    in
    snd (Live.us_plan_action ~rebalance:true ~symbol:"SPY"
      ~date:"2025-06-24" ~account ~held ~price:300.
      ~target:(Float.max 0. target) ~previous_target:0.)
```

```ocaml
let test_us_live_plan_policy () =
  let choose rebalance ~target ~previous_target =
    let account : Alpaca.account_t =
      { equity = 1000.; cash = 600.; long_market_value = 400.;
        short_market_value = 0.; status = "ACTIVE";
        trading_blocked = false; account_number = "paper-account" }
    in
    snd (Live.us_plan_action ~rebalance ~target ~previous_target
      ~symbol:"SPY" ~date:"2025-06-24" ~account ~price:100. ~held:4.)
```

```ocaml
(* test_us_live_quantity_limit: replace only its local decide closure.
   Holding worth V and account cash 1 - V imply positive mapped equity 1.
   Both targets and previous target are zero, so force daily planning. *)
  let decide held =
    let value = held *. 300. in
    let account : Alpaca.account_t =
      { equity = 1.; cash = 1. -. value; long_market_value = value;
        short_market_value = 0.; status = "ACTIVE";
        trading_blocked = false; account_number = "paper-account" }
    in
    snd (Live.us_plan_action ~rebalance:true ~symbol:"SPY"
      ~date:"2025-06-24" ~account ~held ~price:300.
      ~target:0. ~previous_target:0.)
```

```ocaml
(* Main list: update the renamed policy test, retain its neighboring calls. *)
  test_us_live_fractional ();
  test_us_live_plan_policy ();
  test_us_live_quantity_limit ();
```

- [ ] **Step 2 (RED): Add `cash` and `debit` to the six `Live.decision` test literals, not just the five named in the spec.** The sixth is in `test_us_step_routing` at the original line 5022. All six have `equity = 1000.`, no position and an order/skip injection, so `cash = 1000.` and `debit = 0.`. Replace their field span with the shown literal lines, preserving their distinct `target`, `held`, and `action` expressions.

```ocaml
(* Each of test_us_live_submit_cutoff, test_us_uncertain_submission_stops,
   test_us_rejected_submission_stops, test_us_rejected_log_failure_stops,
   test_us_decision_logs_after_preflight, and test_us_step_routing. *)
      equity = 1000.;
      cash = 1000.;
      debit = 0.;
```

- [ ] **Step 3 (RED): Run the assert executable.** The new record fields are absent, so compilation fails before the production cutover.

```sh
opam exec --switch=/sandbox/stock -- dune runtest --root . --force
```

- [ ] **Step 4 (GREEN): Add the two fields to both `decision` declarations, remove the old action helpers and their interfaces, and wire the US arm.** Keep lines 589-608's effective target computation, the account and position fetch order, and `execute_decision` unchanged. Keep `run_us` startup `account.equity` unchanged. The returned state is the source of the US decision fields.

```ocaml
(* broker/live.ml and broker/live.mli: decision, after equity *)
  equity : float;
  cash : float;
  debit : float;
  held : float;
```

```ocaml
(* broker/live.ml: replace existing US arm from account fetch to record *)
      let account = Alpaca.account mode in
      let held = Alpaca.position_qty mode symbol in
      let state, action =
        us_plan_action ~rebalance ~symbol ~date:provisional.date ~account
          ~held ~price:provisional.c ~target ~previous_target
      in
      { fetched_through; provisional; target;
        equity = state.equity; cash = state.cash; debit = state.loans.(0);
        held; action }
```

```ocaml
(* broker/live.ml: replace only the TW result record; cash and loans
   are the existing bindings at lines 718-742, equity is unchanged. *)
      { fetched_through; provisional; target; equity; cash;
        debit = loans; held; action }
```


- [ ] **Step 5 (GREEN): Print the two added values in `bin/bt.ml` immediately after `equity:` and before `held:`.** This is the same `print_decision` function for US and TW, so one change covers both.

```ocaml
  Printf.printf "target: %.10g\n" decision.target;
  Printf.printf "equity: %.10g\n" decision.equity;
  Printf.printf "cash: %.10g\n" decision.cash;
  Printf.printf "debit: %.10g\n" decision.debit;
  Printf.printf "held: %.10g\n" decision.held;
```

- [ ] **Step 6 (GREEN): Run both dune commands and all six byte comparisons from Global Constraints.** Check no obsolete helper callsites remain using the exact search below; the old names must be absent. Do not call `bt target` against a broker to inspect output: the coordinator's later paper acceptance checks its actual printed lines.

```sh
opam exec --switch=/sandbox/stock -- dune build --root .
opam exec --switch=/sandbox/stock -- dune runtest --root . --force
rg -n 'decide_action|us_rebalance_action' /sandbox/stock-us-planner/broker /sandbox/stock-us-planner/bin /sandbox/stock-us-planner/test
```

Expected: dune and all six comparisons exit 0; the search has no matches (exit 1).

- [ ] **Step 7: Commit the clean cutover only after confirmation.**

```sh
git -C /sandbox/stock-us-planner add broker/live.ml broker/live.mli bin/bt.ml test/test_bt.ml
git -C /sandbox/stock-us-planner commit -m "feat: route US decisions through the planner"
```

Commit only after the coordinator confirms; use the co-author trailer the coordinator names; never push; never change git settings.

### Task 5: Update live, CLI, engine fidelity, and changelog docs

**Files:**
- Modify: `/sandbox/stock-us-planner/docs/specs/live-trading.md:39-42,65-72,83-98`
- Modify: `/sandbox/stock-us-planner/docs/cli.md:222-245,270-295,439-455`
- Modify: `/sandbox/stock-us-planner/docs/engine.md:139-150` (also correct the stale elite-tier sentence at line 150)
- Modify: `/sandbox/stock-us-planner/CHANGELOG.md:7-9`

**Interfaces:**
- Consumes: the shipped `Live.us_plan_action` state and account checks, `Live.decision.{equity,cash,debit}`, shared `bt target` output from Task 4, the fixed `Engine.profile_of_market "us"` defaults.
- Produces: documentation of the planner/debit mapping, one-stock fail-closed errors and unchanged-target skip, `cash` and `debit` for both target markets, daily posting of Alpaca interest, and three `[Unreleased]` changelog entries. No code/interface change. The coordinator assigns this editorial task to the doc-editor; the editor dispatches nobody.

- [ ] **Step 1: Correct the account and daily-cycle text in `docs/specs/live-trading.md`.** Replace its obsolete line 42 and step 4 with the following exact paragraphs, and put the dated note after the existing 2026-09-29 rebalance note. Preserve the paper dividend caveat and unchanged on_change policy.

```text
- Paper accounts default to $100k, use IEX data, and do not simulate dividends. bt reads signed cash, one held position, and the account's long and short market values; it sizes from the provisional-close position value and mapped planner equity, not from Alpaca's equity field. Paper results understate dividend cash relative to a backtest.

4. Read the signed account cash, long and short market values, and held position. At the provisional price, map a negative cash balance to one margin debit and split the position into cash and margin inventories. Pass that one-asset state to Engine.plan_fills. Net its ordinary buy and sell legs into one fractional order, truncated to 9 decimals; refinancing pairs net to no order. Skip a buy below USD 1; cap a sell at the held position and sell all held shares when the planned final value is zero.

> [!NOTE]
> 2026-09-30: US sizing now uses the backtest fill planner with the account debit mapped into one margin lot; see [Design: US live planner](./us-live-planner.md). Account cash must be finite, shorts and other symbols fail the decision, and mapped equity must be positive. The account endpoint exposes no unposted margin-interest accrual, so the mapped state includes posted interest in cash but sets unposted interest to zero.
```

- [ ] **Step 2: Replace the margin paragraph and narrow the old non-goal in that live spec.** The Alpaca overnight rates are 6.50% non-elite and 5.00% elite, NOT bt's 6.25% backtest default; Alpaca accrues `debit x rate / 360` daily and posts monthly. Correct the misleading multiplier assertion: the fixture's `multiplier` is 4 (intraday), not 2; the effective-target Reg T ceiling at ratio 0.5 is 2.0. Preserve the paragraph's tiered maintenance and leveraged-ETF add-on caveats.

```text
Margin: a target above 1.0 is a larger position. The backtest planner caps the US effective target at 2.0 using the Reg T 50% initial-margin ratio, independently of Alpaca's intraday account multiplier (4 in the recorded fixture). Alpaca enforces its own buying power and overnight maintenance: price-band requirements of 100%/50%/30%, with 50%/75% house requirements for 2x/3x leveraged ETFs. Alpaca charges margin interest on the settlement-date debit at 6.50% per year for non-elite accounts or 5.00% for elite accounts: debit x rate / 360, accrued daily and posted at month end. bt's US backtest financing default remains 6.25%; use bt run --financing-rate PERCENT to override it. The account endpoint exposes no unposted accrual, so live sizing can overstate equity until posting by at most about one month of interest (at 6.50%, 31 days is about 0.56% of the debit). bt's default maintenance table omits leveraged-ETF add-ons; bt run --maintenance-ratio PCT replaces it with one flat rate. The daemon does not reproduce broker maintenance or cures. An Alpaca buying-power rejection still ends the day with order=skip.

- Live replication of financing-interest accrual, broker maintenance, or margin-call cures. US order sizing itself now uses the engine planner.
```

- [ ] **Step 3: Update `docs/cli.md`'s shared output table and US decision/failure sections.** Insert `cash` and `debit` rows between `equity` and `held`; replace the stale desired-share paragraphs in the US target and live sections. Add the four exact failures to both target (fails without an order) and live (retries until cutoff) paragraphs, without changing either command's other errors.

```text
| `equity` | Show the planner's equity valued at the provisional close (US), or the unchanged inferred/simulation equity (TW). |
| `cash` | Show free cash passed to the fill planner: positive Alpaca cash for US or inferred spendable cash for TW. |
| `debit` | Show the mapped Alpaca account loan for US or total TW position loans. |
| `held` | Show the current share position. |

The US arm maps Alpaca signed cash and the stock position valued at the provisional close into one engine margin lot, then uses Engine.plan_fills with the US default costs and financing ratio. Under on_change an unchanged effective target skips before planning with `target unchanged`; daily planning or a changed target can return `no trade planned` if the net ordinary buy/sell is zero. Equal-value refinance legs require no Alpaca order. It truncates net quantities to 9 decimals, skips buys under USD 1 with `below $1 minimum order value`, caps sells at held shares, and sells the whole holding when the planner closes the position. Alpaca's equity field is logged at daemon startup but does not size orders.

The US decision fails without an order when account cash is non-finite (`US account cash is not finite`), a short is held or reported (`US account holds a short position`), the account's long market value differs from this stock's provisional value by more than 1% of that long market value (`US account holds other symbols`), or mapped equity is non-finite or non-positive (`US account equity is not positive`). These checks precede the unchanged-target skip. An unavailable account, stale cache or snapshot, failed history fetch, or strategy evaluation error also fails the decision.

The Submit phase ends 2 minutes before the close because Alpaca queues a day order sent after the close for the next session, and the order request can take up to its 60-second curl timeout. At or after that cutoff, the daemon logs `error=submit cutoff passed order=skip` and submits nothing. The US planner, `target unchanged` and `no trade planned` skips, 9-decimal fractional orders, and USD 1 buy minimum match `bt target`. The `target unchanged` skip logs `order=skip:target unchanged`.

Before the cutoff, `US account cash is not finite`, `US account holds a short position`, `US account holds other symbols`, or `US account equity is not positive` fails the decision and logs `error=Failure("<message>") order=retry`; the daemon retries every 60 seconds. If the account is still invalid after the cutoff, it logs `error=submit cutoff passed order=skip` and places no order. The existing stale-cache, fetch, snapshot, evaluation, order-lookup, pre-submit clock, rejection, and uncertain-submission policies still apply.
```

- [ ] **Step 4: Update `docs/engine.md`'s US live fidelity paragraph and the stale elite-tier gap.** Do not alter the engine's actual 6.25% default or its accrual algorithm.

```text
Under `rebalance on_change` or without a declaration, the daemon skips a session whose effective target equals the previous bar's, with the reason `target unchanged`. Under `rebalance daily`, it calls `Engine.plan_fills` each session using Alpaca signed cash, the one held stock at the provisional close, and its mapped account debit as one margin lot. The planner's net ordinary buy/sell becomes one fractional Alpaca order; refinancing pairs cancel. The daemon skips buys under USD 1 and truncates quantities to 9 decimal places, so tiny backtest fills can differ. Alpaca's unposted margin interest is unavailable to the live mapping; posted interest is reflected in cash.

- Alpaca's elite/non-elite margin rates (5.00%/6.50%) differ from bt's 6.25% backtest default; use `--financing-rate` to select either rate for a backtest. Live account data contains posted interest but not unposted accrual.
```

- [ ] **Step 5: Add the three Keep a Changelog entries under `[Unreleased]` in `CHANGELOG.md`; do not edit the v0.11.0 release block or its date.**

```text
### Added

- `bt target` prints planner `cash` and `debit` after `equity` for US and TW decisions.

### Changed

- US live and `bt target` size orders through the backtest fill planner, mapping Alpaca's signed account cash and one held stock into one margin lot so leveraged targets use planner quantities.
- US live fails a session with `US account cash is not finite`, `US account holds a short position`, `US account holds other symbols`, or `US account equity is not positive` before planning; the daemon retries before its submit cutoff.
```

- [ ] **Step 6 (GREEN): Run both dune commands and the six byte comparisons from Global Constraints, and inspect the four changed documents.** Every command exits 0; the docs describe the shipped names, the shared target output, and the unchanged engine default. No paper account calls are allowed in this task.

```sh
opam exec --switch=/sandbox/stock -- dune build --root .
opam exec --switch=/sandbox/stock -- dune runtest --root . --force
rg -n 'cash|debit|6\.50|5\.00|financing-rate|US account|plan_fills' /sandbox/stock-us-planner/docs/specs/live-trading.md /sandbox/stock-us-planner/docs/cli.md /sandbox/stock-us-planner/docs/engine.md /sandbox/stock-us-planner/CHANGELOG.md
```

- [ ] **Step 7: Commit the documentation only after confirmation.**

```sh
git -C /sandbox/stock-us-planner add docs/specs/live-trading.md docs/cli.md docs/engine.md CHANGELOG.md
git -C /sandbox/stock-us-planner commit -m "docs: describe US live planner and debit mapping"
```

Commit only after the coordinator confirms; use the co-author trailer the coordinator names; never push; never change git settings.

## Coordinator acceptance after the branch

After all offline gates, the coordinator alone performs the paper-session acceptance in `docs/specs/us-live-planner.md` on `/sandbox/research/strategies/us/paper_probe/main.strat`: declare `rebalance daily`, hold only TQQQ, observe three sessions at 0.2, 1.5, 0.2, inspect `cash:`/`debit:` immediately after `equity:` each session, compare post-trade exposure with the cached-bar backtest trade's `to_exposure` to four decimals while excluding refinance rows, and confirm the levered middle session reports zero free cash and a debit around half equity. A 3x ETF at 1.5 exposure has a 112.5%-of-equity overnight maintenance requirement, so hold 1.5 for only one session. This is not a task to execute from this plan; no implementer invokes broker-facing commands.

## Self-Review

- Spec coverage: Task 1 maps all three new account fields and their fixture; Task 2 maps signed cash, debit, one cash/margin lot, clamp, provisional pricing, and zero unposted interest with three worked examples; Task 3 maps the four ordered failures, 1% tolerance, unchanged-target pre-check, exact `plan_fills` parameters, net buy/sell, refinance cancellation, full-close, 9-decimal truncation, USD 1 skip, no-trade skip, and four `Engine.run` parity cases. Task 4 replaces both obsolete helpers, preserves effective target normalization and `run_us` startup log, updates TW/US decision values and all six existing decision literals, and prints both target fields. Task 5 maps every requested documentation section and `[Unreleased]` entries. The coordinator's distinct paper acceptance is specified after tasks. No spec requirement is unmapped; short/multi-stock/maintenance automation and accrued-interest modeling stay out of scope.
- Placeholder scan: no unfinished implementation marker, unexplained pseudo-code, missing implementation/test step, or referenced helper without a defining task. `<message>` in the CLI text is a literal template for the existing daemon log, not missing plan content. The negative-target migration normalizes to zero as `Live.decide` already does; the same-state test uses a third bar only to prevent the engine's automatic terminal close from overwriting E2.
- Type consistency: `Alpaca.account_t` has the same seven fields in `.ml`, `.mli`, fixtures, and all constructed test values. `us_plan_state` takes labelled `cash`, `held`, `price`, `ratio`, `previous_target` and returns `Engine.plan_state` in Tasks 2-4. `us_plan_action` takes the same eight labelled arguments and returns `Engine.plan_state * Live.action` in Tasks 3-4. `Live.decision` adds `cash` and `debit` in both declarations, both market arms, six record literals, and `print_decision`; `loans.(0)` is the one-asset US debit, TW `loans` is already the aggregated float.
- Verification scope: this plan-writing task performs no build, test, formatter, network access, broker call, staging, commit, or push. Every execution task includes RED where behavior can fail first, GREEN build/full-suite/byte gates, a coordinator review and conditional commit. The paper session is deferred exclusively to coordinator acceptance after the branch.
