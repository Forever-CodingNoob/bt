# Multi-Stock Live Stage 2 Implementation Plan

> **For the coordinator:** REQUIRED SUB-SKILL: superpowers:executing-plans; implement this plan task-by-task and track its `- [ ]` steps. The coordinator owns every review and assigns Task 6 to the doc-editor.

Implementers use executing-plans only. No subagents: never dispatch a reviewer or any other agent; the coordinator owns reviews.

**Goal:** Execute the already-merged N-asset TW decisions across all strategy codes, with phase barriers, FOK lots, and a production trading-budget and suspension pre-check.

**Architecture:** Keep the shared compiler, planner, decision record, code-tagged legs, position-set aggregation, and batched snapshot client from stage 1. Add the two Shioaji accounting/contract clients; check the entire production decision's buy holds before submission; replace the scalar executor with declaration-ordered per-code state and one running cash balance; migrate the daemon to N codes. Rollover and refinance pairs remain sequential, ordinary Common sells form a confirmation barrier, and ordinary buys reserve quote costs before batch reconciliation.

**Tech Stack:** OCaml standard library and unix, dune, the existing opam switch, curl/jq broker clients, injected JSON fixtures, and plain asserts in `test/test_bt.ml`.

## Contents

- [Global Constraints](#global-constraints)
- [Scope and file map](#scope-and-file-map)
- [Tasks](#tasks)
  - [Task 1: Add contract info and trading limits clients and FOK requests](#task-1-add-contract-info-and-trading-limits-clients-and-fok-requests)
  - [Task 2: Check the production decision budget and suspended codes](#task-2-check-the-production-decision-budget-and-suspended-codes)
  - [Task 3: Replace the scalar TW executor with per-code phases](#task-3-replace-the-scalar-tw-executor-with-per-code-phases)
    - [Executor inputs and state](#executor-inputs-and-state)
    - [Phase placement and reconciliation](#phase-placement-and-reconciliation)
    - [Offline execution scenarios](#offline-execution-scenarios)
  - [Task 4: Run the TW daemon over all strategy codes](#task-4-run-the-tw-daemon-over-all-strategy-codes)
  - [Task 5: Drive the existing US sell restart through us_step](#task-5-drive-the-existing-us-sell-restart-through-us_step)
  - [Task 6: Update stage 2 documentation and changelog](#task-6-update-stage-2-documentation-and-changelog)
- [Coordinator acceptance after the branch](#coordinator-acceptance-after-the-branch)
- [Self-Review](#self-review)

## Global Constraints

- Implement stage 2 of `/sandbox/stock-multi-stock-2/docs/specs/multi-stock-live.md`, released as v0.13.0 only after coordinator production acceptance. The reviewed working-tree TW budget pre-check in `/sandbox/stock/docs/specs/multi-stock-live.md` is authoritative; the coordinator carries that reviewed text into the execution worktree before starting. Stage 1 is merged on main at c21ef88; do not recreate its N-asset decision, snapshot parser, planner, leg tags, US phases, or date intersection.
- The coordinator creates `/sandbox/stock-multi-stock-2` before execution. Every implementation read, edit, and command uses absolute paths there; set every command's working directory to `/sandbox/stock-multi-stock-2`. Never touch `/sandbox/stock`. The only exceptions are read-only inputs: `/sandbox/stock/data`, `/sandbox/stock/.superpowers/sdd/us-paper-test/`, `/sandbox/research/strategies/`, the `/sandbox/stock` opam switch, and the authoritative reviewed spec and production probe log used for planning. The dune `--root .` resolves in the worktree. This planning assignment writes only `/sandbox/stock/docs/plans/multi-stock-live-stage-2.md`, and stages and commits nothing.
- Run build, test, and git through Python `subprocess`, not the host bash wrapper, which stalls. The Python blocks below are execution cells, not foreign code embedded in `.ml` files. Every git command shown is conditional on coordinator confirmation. Run commands with `check=True`; a nonzero exit stops the task.
- Never make network calls during implementation or verification. Never run `bt live` or `bt target` against a broker. Inject the previous TW session, snapshots, positions, details, balance, settlements, contract info and trading limits into offline decisions. Production acceptance is a coordinator activity after the branch, not an implementer task.
- Follow CONTRIBUTING Style rules: standard library and unix only; ASCII; one space around `=`; no alignment spaces; no new `for` or `while` loops; side effects sequenced with `let () = e in`; tail-recursive list traversal; arrays for series math; warnings as errors; preserve floating-point operation order. Market dispatch uses `match` with `| "us"`, `| "tw"`, and a default/error arm, never a market-string `if`.
- Follow CONTRIBUTING Documentation style: full-depth Contents, tables for enumerable material, one H1, ASCII, and no mid-sentence hard wrapping. Put assert-based tests in `/sandbox/stock-multi-stock-2/test/test_bt.ml` and register every new test in its final `let ()` list. Preserve independent derivation comments and exact byte pins. No new testing framework.
- Read relevant sections again before editing; use language-server references for exported symbol/type changes and inspect known consumers in `/sandbox/stock-multi-stock-2/bin/bt.ml` and `/sandbox/stock-multi-stock-2/test/test_bt.ml`. No scalar compatibility wrappers, duplicate executor, or retry after a POST. Remove the stage 1 one-code guard only when the N-code daemon is wired.
- Keep the stage 1 one-stock pins passing without changing target, quantity, leg-list or leg-order values: `test_multi_stock_one_stock_pins`, `test_us_plan_state`, `test_us_plan_action_orders`, `test_us_live_fractional`, `test_us_live_quantity_limit`. The accepted stage 2 N=1 changes are named where they land: FOK in Task 1; budget and suspension pre-check in Task 2; phase batching including the rejected/uncertain/FOK-killed sell stop before refinances and buys in Task 3. The US positions-list accepted change is already merged; Task 5 adds coverage, not new US behavior.
- Do not change `engine/`, `lang/`, date arithmetic, share quantum, costs, cash settlement math, lock scope, historical baselines, dependencies, foreign-holding rules, or the open-order US re-plan fidelity warning. Do not add short trading, mixed markets, multi-strategy attribution, retries, telemetry, or a broker-hold model beyond the stated assumption.
- At each GREEN gate run the following two commands from the worktree, then the six byte comparisons below. Every command exits 0. Task 3's executor/interface/caller migration is atomic: its intermediate RED steps are not commit points.

```python
import subprocess
root = "/sandbox/stock-multi-stock-2"
subprocess.run(["opam", "exec", "--switch=/sandbox/stock", "--", "dune", "build", "--root", "."], cwd=root, check=True)
subprocess.run(["opam", "exec", "--switch=/sandbox/stock", "--", "dune", "runtest", "--root", ".", "--force"], cwd=root, check=True)
```

The reference gates are copied from `/sandbox/stock/docs/plans/multi-stock-live-stage-1.md:43-60`, with only the executable worktree path changed. Do not edit their strategies, capital, cache, or baselines. The child shell is launched by Python, bypassing the host bash wrapper; the six `cmp` commands are exactly the stage 1 comparisons.

```python
import subprocess
subprocess.run(["/bin/sh", "-eu", "-c", r"""
us_out=$(mktemp -d)
tw_out=$(mktemp -d)
/sandbox/stock-multi-stock-2/_build/default/bin/bt.exe run /sandbox/research/strategies/us/dd_ladder/main.strat --baseline us/TQQQ --capital 100000 --data-dir /sandbox/stock/data --out-dir "$us_out" --out-name fp --no-plot > "$us_out/stdout.txt"
cmp "$us_out/stdout.txt" /sandbox/stock/.superpowers/sdd/us-paper-test/us-baseline/stdout.txt
cmp "$us_out/fp.csv" /sandbox/stock/.superpowers/sdd/us-paper-test/us-baseline/fp.csv
cmp "$us_out/main.trades.csv" /sandbox/stock/.superpowers/sdd/us-paper-test/us-baseline/main.trades.csv
/sandbox/stock-multi-stock-2/_build/default/bin/bt.exe run /sandbox/research/strategies/tw/channel_ladder/main.strat --baseline tw/00685L --capital 1000000 --data-dir /sandbox/stock/data --out-dir "$tw_out" --out-name fp --no-plot > "$tw_out/stdout.txt"
cmp "$tw_out/stdout.txt" /sandbox/stock/.superpowers/sdd/us-paper-test/tw-baseline/stdout.txt
cmp "$tw_out/fp.csv" /sandbox/stock/.superpowers/sdd/us-paper-test/tw-baseline/fp.csv
cmp "$tw_out/main.trades.csv" /sandbox/stock/.superpowers/sdd/us-paper-test/tw-baseline/main.trades.csv
"""], cwd="/sandbox/stock-multi-stock-2", check=True)
```

For scoped smoke calls, define this Python runner once after the task's build. It reads the real worktree implementation and test definitions into memory and calls only the specified scenarios. It creates no source scaffold, changes no interface, and invokes no unselected test or broker call. Pass the complete OCaml scenario block from the task to `smoke(code)`; the runner checks the toplevel's error text as well as its exit status because OCaml can exit 0 after a rejected phrase.

```python
from pathlib import Path
import subprocess

def smoke(code):
    root = Path("/sandbox/stock-multi-stock-2")
    libraries = [("series", "series"), ("market", "data"), ("engine", "engine"),
                 ("lang", "lang"), ("metrics", "metrics"), ("report", "report"),
                 ("intraday", "intraday"), ("broker", "broker")]
    command = ["opam", "exec", "--switch=/sandbox/stock", "--", "ocaml", "-noinit", "-noprompt", "-I", "+unix"]
    for directory, library in libraries:
        command += ["-I", str(root / "_build/default" / directory / ("." + library + ".objs/byte"))]
    command += ["unix.cma"] + [str(root / "_build/default" / directory / (library + ".cma")) for directory, library in libraries]
    tests = (root / "test/test_bt.ml").read_text().rsplit("\nlet () =\n", 1)[0]
    source = "module Live = struct\n" + (root / "broker/live.ml").read_text() + "\nend;;\n"
    source += "module Check = struct\n" + tests + "\nend;;\n" + code + ";;\n"
    source += 'print_endline "PLAN_SMOKE_OK";;\n'
    result = subprocess.run(command, input=source, text=True, capture_output=True, cwd=root, check=True)
    assert "Error:" not in result.stdout and "Exception:" not in result.stdout, result.stdout[-8000:] + result.stderr
    assert "PLAN_SMOKE_OK" in result.stdout, result.stdout[-8000:] + result.stderr
    print("PLAN_SMOKE_OK")
```

- At every commit step: Commit only after the coordinator confirms; use the co-author trailer the coordinator names; never push; never change git settings. The coordinator supplies the full trailer at execution time through `COAUTHOR_TRAILER`; never guess an identity.

## Scope and file map

| Files under `/sandbox/stock-multi-stock-2/` | Responsibility | Tasks |
|---|---|---|
| `broker/shioaji.ml`, `broker/shioaji.mli` | Six trading-limit fields, seven contract-info fields, clients, parsers, FOK lot request | 1 |
| `test/fixtures/shioaji/trading_limits.json`, `test/fixtures/shioaji/contract_info.json` | Documented response shapes with probe-grounded limits and the real 0050 info values | 1 |
| `broker/live.ml`, `broker/live.mli` | Production decision pre-check, per-code executor state, batch barriers, N-code daemon | 2-4 |
| `test/test_bt.ml` | Parsers, budgets, phase execution, existing N-decision coverage, end-to-end US restart | 1-5 |
| `docs/specs/tw-live-trading.md`, `docs/cli.md`, `docs/engine.md`, `CHANGELOG.md` | Stage 2 semantics, accepted N=1 changes, four release entries | 6 |
| `docs/specs/multi-stock-live.md`, `docs/specs/share-quantum-and-odd-lots.md` | Authoritative design and dated supersession note for changed execution rules | 6; coordinator measurements |

The existing `test_shioaji_snapshot_codes` covers two out-of-order contracts plus missing, extra and duplicate codes, and `test_tw_live_pair_decide` covers declaration order, joint scaling, previous-row targets, summed cash/debit, both rollover pairs, and phase-ordered legs. Retain these instead of duplicating spec Tests rows 7 and 15. Task 4 additionally exercises N-contract daemon preparation through an injected smoke.

## Tasks

### Task 1: Add contract info and trading limits clients and FOK requests

**Files:**

| Operation | Absolute path and section |
|---|---|
| Modify | `/sandbox/stock-multi-stock-2/broker/shioaji.ml`: types before `lot`, parser helpers at 101-147, parsers after `parse_info`, clients near `balance`, `order_body` at 440-475 |
| Modify | `/sandbox/stock-multi-stock-2/broker/shioaji.mli`: record types, parser/client exports, `order_request` comment |
| Create | `/sandbox/stock-multi-stock-2/test/fixtures/shioaji/trading_limits.json` |
| Create | `/sandbox/stock-multi-stock-2/test/fixtures/shioaji/contract_info.json` |
| Modify/test | `/sandbox/stock-multi-stock-2/test/test_bt.ml`: `shioaji_fixture`, parser tests, `test_tw_odd_order_body`, final registration |

**Interfaces:**

| Direction | Contract |
|---|---|
| Consumes | Existing `jq_fields`, finite numeric parsers, `bool_field`, `request`, `expect_ok`, `shioaji_fixture`, `read_file` |
| Produces | `Shioaji.trading_limits` record and `trading_limits : unit -> trading_limits`; `Shioaji.contract_info` record and `contract_info : code:string -> contract_info`; `parse_trading_limits : string -> trading_limits`; `parse_contract_info : string -> contract_info` |
| Preserves | `Shioaji.order_request`, `placed`, `trade`, and N-contract `snapshot` signatures; IntradayOdd LMT/ROD form |

- [ ] **Step 1 (RED): Add both fixture files with the following complete content.** The limits use the documented flat response shape and the Monday 09:05 probe's TWD 1,000,000 available, zero used and zero margin allowance. They are fixture data, not a claim that a fresh network response was captured during implementation. The contract values are the reviewed real 0050 response, with `update_date` retained as provenance, not an eighth parsed field.

`trading_limits.json`:

```json
{"trading_limit":1000000,"trading_used":0,"trading_available":1000000,"margin_limit":0,"margin_used":0,"margin_available":0}
```

`contract_info.json`:

```json
{"reference":112.8,"limit_up":124.05,"limit_down":101.55,"day_trade":"Yes","unit":1000.0,"margin_loan_ratio":0.6,"trading_suspended":false,"update_date":"2026-10-05"}
```

- [ ] **Step 2 (RED): Add and register these parser tests; update the existing Common order assertion to FOK.** That is the accepted N=1 FOK change. Keep the existing odd-order price, ROD, cash-only and 1-999-share boundary checks. Replace only the existing Common comment and assertion; do not duplicate the odd tests.

```ocaml
let test_shioaji_contract_info_parse () =
  let actual = Shioaji.parse_contract_info
    (shioaji_fixture "contract_info.json") in
  (* Recorded 0050 fields: band is 101.55-124.05 around reference 112.8;
     one Common lot is 1000 shares, margin ratio is 0.6, not suspended. *)
  let expected : Shioaji.contract_info =
    { reference = 112.8; limit_up = Some 124.05; limit_down = 101.55;
      day_trade = "Yes"; unit = 1000.; margin_loan_ratio = 0.6;
      trading_suspended = false } in
  let () = assert (actual = expected) in
  let without_band value = Shioaji.parse_contract_info
    ("{\"reference\":100,\"limit_down\":90,\"day_trade\":\"No\",\"unit\":1000," ^
     "\"margin_loan_ratio\":0,\"trading_suspended\":false" ^ value ^ "}") in
  (* Missing/null/non-positive limit-up is the specified no-band case. *)
  let () = List.iter (fun value ->
    assert ((without_band value).Shioaji.limit_up = None))
    [""; ",\"limit_up\":null"; ",\"limit_up\":0"; ",\"limit_up\":-1"] in
  (* Required fields cannot silently default, and a nonnumeric band is malformed. *)
  let () = assert_failure (fun () -> ignore (Shioaji.parse_contract_info {|{}|})) in
  assert_failure (fun () -> ignore (without_band ",\"limit_up\":\"bad\""))

let test_shioaji_trading_limits_parse () =
  let actual = Shioaji.parse_trading_limits
    (shioaji_fixture "trading_limits.json") in
  (* Monday start: full 1000000 cash allowance, no daily usage or margin. *)
  let expected : Shioaji.trading_limits =
    { trading_limit = 1000000.; trading_used = 0.; trading_available = 1000000.;
      margin_limit = 0.; margin_used = 0.; margin_available = 0. } in
  let () = assert (actual = expected) in
  (* Simulation's all-zero limits must parse; they are not a production allowance. *)
  let zero = Shioaji.parse_trading_limits
    {|{"trading_limit":0,"trading_used":0,"trading_available":0,"margin_limit":0,"margin_used":0,"margin_available":0}|} in
  let () = assert (zero.trading_available = 0. && zero.margin_available = 0.) in
  assert_failure (fun () -> ignore (Shioaji.parse_trading_limits
    {|{"trading_limit":100,"trading_used":0,"trading_available":-1,"margin_limit":0,"margin_used":0,"margin_available":0}|}))
```

In `test_tw_odd_order_body`:

```ocaml
  (* Common is MKT FOK with two lots, not two shares; price remains zero. *)
  let () = assert (contains common
    {|"price":0,"quantity":2,"price_type":"MKT","order_type":"FOK","order_lot":"Common"|}) in
```

Registration beside the other Shioaji parser calls:

```ocaml
  let () = test_shioaji_contract_info_parse () in
  let () = test_shioaji_trading_limits_parse () in
```

- [ ] **Step 3: Run RED through Python.** Expected: the new types/parsers are unbound, or the Common assertion fails until FOK lands; no broker is contacted.

```python
import subprocess
subprocess.run(["opam", "exec", "--switch=/sandbox/stock", "--", "dune", "runtest", "--root", ".", "--force"], cwd="/sandbox/stock-multi-stock-2", check=True)
```

- [ ] **Step 4 (GREEN): Add the records to both `.ml` and `.mli`, and the four exports to `.mli`.** Use the option only for the specified absent/null/non-positive band; do not default a missing reference, unit, suspension flag or budget field.

```ocaml
type contract_info = {
  reference : float;
  limit_up : float option;
  limit_down : float;
  day_trade : string;
  unit : float;
  margin_loan_ratio : float;
  trading_suspended : bool;
}

type trading_limits = {
  trading_limit : float;
  trading_used : float;
  trading_available : float;
  margin_limit : float;
  margin_used : float;
  margin_available : float;
}
```

```ocaml
val parse_contract_info : string -> contract_info
val parse_trading_limits : string -> trading_limits
val contract_info : code:string -> contract_info
val trading_limits : unit -> trading_limits
```

- [ ] **Step 5 (GREEN): Implement the parsers with the existing jq helpers and finite numeric parsing.** Numeric JSON types remain enforced at the boundary. Keep `limit_down` nonnegative for band-less contracts and reference/unit positive. The documented margin ratio is a fraction, not a percentage.

```ocaml
let parse_contract_info raw =
  match jq_fields "contract info"
    "if ((.reference | type) == \"number\" and (.limit_down | type) == \"number\" and (.day_trade | type) == \"string\" and (.unit | type) == \"number\" and (.margin_loan_ratio | type) == \"number\" and (.trading_suspended | type) == \"boolean\" and (.limit_up == null or (.limit_up | type) == \"number\")) then [(.reference | tostring), (if .limit_up == null then \"\" else (.limit_up | tostring) end), (.limit_down | tostring), .day_trade, (.unit | tostring), (.margin_loan_ratio | tostring), (.trading_suspended | tostring)] | @tsv else error(\"invalid contract info fields\") end" raw with
  | [reference; limit_up; limit_down; day_trade; unit; margin_loan_ratio;
     trading_suspended] ->
      let limit_up = match limit_up with
        | "" -> None
        | value -> let value = float_field "contract info limit_up" value in
            if value > 0. then Some value else None in
      let ratio = nonnegative_float_field "contract info margin_loan_ratio"
        margin_loan_ratio in
      let () = if ratio > 1. then failwith "invalid Shioaji contract info ratio" in
      { reference = positive_float_field "contract info reference" reference;
        limit_up; limit_down = nonnegative_float_field "contract info limit_down" limit_down;
        day_trade; unit = positive_float_field "contract info unit" unit;
        margin_loan_ratio = ratio;
        trading_suspended = bool_field "contract info trading_suspended" trading_suspended }
  | _ -> failwith "invalid Shioaji contract info response"

let parse_trading_limits raw =
  match jq_fields "trading limits"
    "[.trading_limit, .trading_used, .trading_available, .margin_limit, .margin_used, .margin_available] | if all(.[]; type == \"number\") then map(tostring) | @tsv else error(\"invalid trading limits fields\") end" raw with
  | [trading_limit; trading_used; trading_available; margin_limit; margin_used;
     margin_available] ->
      { trading_limit = nonnegative_float_field "trading limits trading_limit" trading_limit;
        trading_used = nonnegative_float_field "trading limits trading_used" trading_used;
        trading_available = nonnegative_float_field "trading limits trading_available" trading_available;
        margin_limit = nonnegative_float_field "trading limits margin_limit" margin_limit;
        margin_used = nonnegative_float_field "trading limits margin_used" margin_used;
        margin_available = nonnegative_float_field "trading limits margin_available" margin_available }
  | _ -> failwith "invalid Shioaji trading limits response"
```

- [ ] **Step 6 (GREEN): Add the clients and change the single Common match arm.** Update `.mli`'s order comment to "Common market FOK or intraday-odd limit ROD order". Do not change quantity, price, condition or custom-field building.

```ocaml
let contract_info ~code =
  request ~path:("/api/v1/data/contracts/" ^ code ^ "/info") ()
  |> expect_ok "contract info" parse_contract_info

let trading_limits () =
  request ~method_:"POST" ~body:{|{"account_type":"S"}|}
    ~path:"/api/v1/portfolio/trading_limits" ()
  |> expect_ok "trading limits" parse_trading_limits
```

```ocaml
    | Common -> "Common", 0., "MKT", "FOK"
```

- [ ] **Step 7: Run GREEN gates and all six byte comparisons.** The actual fixture parsers and request-body builder run in the test executable; inspect their asserts, not a source-text test. Expected: valid info/limits, zero simulation limits, no-band cases and unchanged odd rules pass; FOK is the only request change.

```python
import subprocess
subprocess.run(["opam", "exec", "--switch=/sandbox/stock", "--", "dune", "build", "--root", "."], cwd="/sandbox/stock-multi-stock-2", check=True)
subprocess.run(["opam", "exec", "--switch=/sandbox/stock", "--", "dune", "runtest", "--root", ".", "--force"], cwd="/sandbox/stock-multi-stock-2", check=True)
```

- [ ] **Step 8: Commit only after coordinator review.** Commit only after the coordinator confirms; use the co-author trailer the coordinator names; never push; never change git settings.

```python
import os, subprocess
root = "/sandbox/stock-multi-stock-2"
subprocess.run(["git", "-C", root, "add", root + "/broker/shioaji.ml", root + "/broker/shioaji.mli", root + "/test/test_bt.ml", root + "/test/fixtures/shioaji/trading_limits.json", root + "/test/fixtures/shioaji/contract_info.json"], cwd=root, check=True)
subprocess.run(["git", "-C", root, "commit", "-m", "feat: add TW contract and trading limits clients and FOK lots", "-m", os.environ["COAUTHOR_TRAILER"]], cwd=root, check=True)
```

### Task 2: Check the production decision budget and suspended codes

**Files:**

| Operation | Absolute path and section |
|---|---|
| Modify | `/sandbox/stock-multi-stock-2/broker/live.ml`: helper before `decide`, optional arguments at 635-637, TW result assembly at 777-783 |
| Modify | `/sandbox/stock-multi-stock-2/broker/live.mli`: budget-check signature and `decide` injections |
| Modify/test | `/sandbox/stock-multi-stock-2/test/test_bt.ml`: Shioaji fixture helpers, existing injected production calls in `test_tw_live_decide_override` at 7512, 7570, 7593, new budget tests, main registration |

**Interfaces:**

| Direction | Contract |
|---|---|
| Consumes | Task 1's seven-field info and six-field limits records; stage 1's `decision.legs` with `leg.code`; snapshot array and symbol array in declaration order |
| Produces | `check_tw_budget : log:(string -> unit) -> symbols:string array -> snapshots:Shioaji.snapshot array -> contract_infos:Shioaji.contract_info array -> limits:Shioaji.trading_limits -> leg list -> unit` |
| Extends | `decide` with `?tw_contract_infos:Shioaji.contract_info array`, `?tw_trading_limits:Shioaji.trading_limits`, `?tw_log:(string -> unit)`; all existing labels and the return record remain |
| Placement boundary | `decide Live` fails the whole session before returning if suspended or over either allowance. Paper does not read contract info or limits. `run_tw` supplies its timestamped logger in Task 4. `bt target --live` receives the same production check and logs audit lines to stderr, preserving decision stdout. |

The accepted N=1 change is the TW production budget and suspension pre-check. Count all buy legs, including rollover and refinance rebuys, once. Do not net sells, assume sell add-back, retry a failed check, or discount a margin hold by its financing ratio.

- [ ] **Step 1 (RED): Add the reusable documented records and concrete budget assertions.** Put them before `test_tw_live_decide_override` so the existing production fixture calls can consume them. The helper defaults are test data only; production has no fallback allowance.

```ocaml
let tw_test_info : Shioaji.contract_info =
  { reference = 10.; limit_up = Some 11.; limit_down = 9.; day_trade = "Yes";
    unit = 1000.; margin_loan_ratio = 0.6; trading_suspended = false }

let tw_test_limits : Shioaji.trading_limits =
  { trading_limit = 1000000000.; trading_used = 0.;
    trading_available = 1000000000.; margin_limit = 1000000000.;
    margin_used = 0.; margin_available = 1000000000. }

let test_tw_buy_budget () =
  let symbols = [|"2330"; "2890"|] in
  let snapshot ask : Shioaji.snapshot =
    { datetime = "2026-05-26T13:20:00+08:00"; open_ = 10.; high = 10.;
      low = 10.; close = 10.; bid = 9.; ask; total_volume = 0. } in
  let snapshots = [|snapshot 10.; snapshot 20.|] in
  let cash : Live.leg =
    { code = "2330"; exchange = "TSE"; action = "Buy"; cond = "Cash";
      lot = Shioaji.Common; quantity = 2 } in
  let odd = { cash with code = "2890"; exchange = "OTC";
    lot = Shioaji.IntradayOdd; quantity = 3 } in
  let margin = { cash with code = "2890"; exchange = "OTC";
    cond = "MarginTrading"; quantity = 1 } in
  let infos = [|tw_test_info; { tw_test_info with limit_up = Some 22. }|] in
  let run infos limits legs = Live.check_tw_budget ~log:(fun _ -> ())
    ~symbols ~snapshots ~contract_infos:infos ~limits legs in
  let fails expected function_ = match function_ () with
    | () -> assert false
    | exception Failure actual -> assert (actual = expected) in
  (* Cash = 11*2*1000 + 20*3 = 22060; margin = 22*1*1000 = 22000.
     Equality passes. A sell never offsets either sum. *)
  let limits = { tw_test_limits with trading_available = 22060.;
    margin_available = 22000. } in
  let legs = [{ cash with action = "Sell" }; cash; odd; margin] in
  let () = run infos limits legs in
  let () = fails "TW buy budget short: planned 22060, available 22059"
    (fun () -> run infos { limits with trading_available = 22059. } legs) in
  let () = fails "TW margin budget short: planned 22000, available 21999"
    (fun () -> run infos { limits with margin_available = 21999. } legs) in
  (* A rebuy is still a buy hold; no special exemption for the preceding sale. *)
  let () = fails "TW margin budget short: planned 22000, available 0"
    (fun () -> run infos { limits with margin_available = 0. }
      [{ margin with action = "Sell" }; margin]) in
  let messages = ref [] in
  let fallback_infos = [|{ tw_test_info with reference = 100.; limit_up = None };
    infos.(1)|] in
  let () = Live.check_tw_budget ~log:(fun text -> messages := text :: !messages)
    ~symbols ~snapshots ~contract_infos:fallback_infos
    ~limits:{ limits with trading_available = 221000. } [cash] in
  (* No band: 100*1.10*2*1000 = 220000; no snapshot-close pricing. *)
  let () = assert (List.exists (fun line -> contains line
    "code=2330 budget-price-fallback=reference*1.10 price=110") !messages) in
  let () = assert (List.exists (fun line -> contains line
    "buy-hold=220000 trading-available=221000 margin-hold=0 margin-available=22000") !messages) in
  fails "TW symbol 2890 is suspended" (fun () -> run
    [|infos.(0); { infos.(1) with trading_suspended = true }|] limits [])
```

- [ ] **Step 2 (RED): Add a production `Live.decide` scenario and supply budgets to the three existing production fixture calls.** The new callback value preserves the test's offline boundary. Keep original account/cash/settlement assertions; passing budget data changes no expected pinned decision.

```ocaml
let test_tw_decide_production_precheck () =
  with_tw_decision_cache (fun data_dir ->
    with_temp_strategy
      "stock \"tw/2330\" as a\nstock \"tw/2890\" as b\nrebalance daily\na.target 0.2\nb.target 0.3\n"
      (fun strat_path ->
        let snapshot : Shioaji.snapshot =
          { datetime = "2026-05-26T13:20:00+08:00"; open_ = 10.; high = 10.;
            low = 10.; close = 10.; bid = 10.; ask = 10.; total_volume = 0. } in
        let choose mode infos limits = Live.decide
          ~previous_session:"2026-05-22"
          ?equity:(match mode with Live.Paper -> Some 100000. | Live.Live -> None)
          ~tw_balance:100000.
          ~tw_settlements:[{ Shioaji.day = 0; amount = 0. };
            { Shioaji.day = 1; amount = 0. }; { Shioaji.day = 2; amount = 0. }]
          ~tw_positions:[] ~tw_position_details:[]
          ~tw_snapshots:[|snapshot; snapshot|]
          ~tw_contract_infos:infos ~tw_trading_limits:limits ~tw_log:(fun _ -> ())
          mode ~session_date:"2026-05-26" ~strat_path ~data_dir in
        let baseline = choose Live.Paper [||]
          { tw_test_limits with trading_available = 0.; margin_available = 0. } in
        let funded = choose Live.Live [|tw_test_info; tw_test_info|] tw_test_limits in
        (* Zero inventory and zero settlements give the same 100000 cash/equity;
           simulation's zero allowances are deliberately not consulted. *)
        let () = assert (funded = baseline) in
        match choose Live.Live
          [|tw_test_info; { tw_test_info with trading_suspended = true }|]
          tw_test_limits with
        | _ -> assert false
        | exception Failure message -> assert (message = "TW symbol 2890 is suspended")))
```

Add to each existing injected one-symbol production call in `test_tw_live_decide_override`:

```ocaml
              ~tw_contract_infos:[|tw_test_info|]
              ~tw_trading_limits:tw_test_limits ~tw_log:(fun _ -> ())
```

Register both new tests:

```ocaml
  let () = test_tw_buy_budget () in
  let () = test_tw_decide_production_precheck () in
```

```python
import subprocess
subprocess.run(["opam", "exec", "--switch=/sandbox/stock", "--", "dune", "runtest", "--root", ".", "--force"], cwd="/sandbox/stock-multi-stock-2", check=True)
```

Expected RED: new checker and `decide` labels do not yet exist.

- [ ] **Step 3 (GREEN): Define the checker before `decide` and export its signature.** Logs print all seven contract fields per symbol; a missing usable band is `-` in the info line and has a separate fallback line. These are live audit lines, not a change to `print_decision`. Logging all info first makes every read visible even when a later code is suspended.

```ocaml
let check_tw_budget ~log ~symbols ~snapshots ~contract_infos
    ~(limits : Shioaji.trading_limits) legs =
  let () = if Array.length snapshots <> Array.length symbols
    || Array.length contract_infos <> Array.length symbols then
    failwith "TW budget inputs do not match symbols" in
  let () = Array.iteri (fun i code ->
    let info : Shioaji.contract_info = contract_infos.(i) in
    log (Printf.sprintf
      "code=%s reference=%.10g limit-up=%s limit-down=%.10g day-trade=%s unit=%.10g margin-loan-ratio=%.10g trading-suspended=%b"
      code info.reference
      (match info.limit_up with None -> "-" | Some v -> Printf.sprintf "%.10g" v)
      info.limit_down info.day_trade info.unit info.margin_loan_ratio
      info.trading_suspended)) symbols in
  let () = Array.iteri (fun i code ->
    if contract_infos.(i).Shioaji.trading_suspended then
      failwith ("TW symbol " ^ code ^ " is suspended")) symbols in
  let prices = Array.mapi (fun i (info : Shioaji.contract_info) ->
    match info.limit_up with
    | Some value when Float.is_finite value && value > 0. -> value
    | Some _ | None ->
        let price = info.reference *. 1.10 in
        let () = log (Printf.sprintf
          "code=%s budget-price-fallback=reference*1.10 price=%.10g" symbols.(i) price) in
        price) contract_infos in
  let index code =
    let rec find i =
      if i = Array.length symbols then failwith ("TW budget has unknown code " ^ code)
      else if symbols.(i) = code then i else find (i + 1) in
    find 0 in
  let cash, margin = List.fold_left (fun (cash, margin) (leg : leg) ->
    if leg.action <> "Buy" then cash, margin
    else
      let i = index leg.code in
      let hold = match leg.lot with
        | Shioaji.Common -> prices.(i) *. float_of_int leg.quantity
            *. contract_infos.(i).unit
        | Shioaji.IntradayOdd ->
            let ask = snapshots.(i).Shioaji.ask in
            (* The existing executor skips an odd order with no usable ask. *)
            if Float.is_finite ask && ask > 0. then ask *. float_of_int leg.quantity
            else 0. in
      match leg.cond with
      | "Cash" -> cash +. hold, margin
      | "MarginTrading" -> cash, margin +. hold
      | cond -> failwith ("unsupported TW buy condition " ^ cond)) (0., 0.) legs in
  let () = log (Printf.sprintf
    "buy-hold=%.10g trading-available=%.10g margin-hold=%.10g margin-available=%.10g"
    cash limits.trading_available margin limits.margin_available) in
  let () = if cash > limits.trading_available then failwith (Printf.sprintf
    "TW buy budget short: planned %.10g, available %.10g" cash limits.trading_available) in
  if margin > limits.margin_available then failwith (Printf.sprintf
    "TW margin budget short: planned %.10g, available %.10g" margin limits.margin_available)
```

Add the checker export to the `.mli` before `decide`:

```ocaml
val check_tw_budget :
  log:(string -> unit) -> symbols:string array ->
  snapshots:Shioaji.snapshot array -> contract_infos:Shioaji.contract_info array ->
  limits:Shioaji.trading_limits -> leg list -> unit
```

- [ ] **Step 4 (GREEN): Extend `decide` in both files and invoke the checker after the complete rollover-plus-plan leg list, before returning the decision.** Production reads once per symbol and once per session; daemon injection later must not re-read them. Paper skips the entire block, even if test injections contain suspended info or all-zero limits.

```ocaml
let decide ?provisional_close ?previous_session ?equity ?tw_balance
    ?tw_settlements ?tw_positions ?tw_position_details ?tw_snapshots
    ?tw_contract_infos ?tw_trading_limits
    ?(tw_log = fun text -> Printf.eprintf "%s\n%!" text) mode
    ~session_date ~strat_path ~data_dir =
```

Insert after the existing `let legs = rollover @ legs_of_plan ... in`:

```ocaml
      let () = match mode with
        | Paper -> ()
        | Live ->
            let contract_infos = match tw_contract_infos with
              | Some infos -> infos
              | None -> Array.map (fun code -> Shioaji.contract_info ~code) symbols in
            let limits = match tw_trading_limits with
              | Some limits -> limits
              | None -> Shioaji.trading_limits () in
            check_tw_budget ~log:tw_log ~symbols ~snapshots ~contract_infos ~limits legs in
```

Add to the existing `.mli` `decide` optional labels, before `mode`:

```ocaml
  ?tw_contract_infos:Shioaji.contract_info array ->
  ?tw_trading_limits:Shioaji.trading_limits ->
  ?tw_log:(string -> unit) ->
```

- [ ] **Step 5: Run GREEN gates, six comparisons and the injected production scenario.** In a scoped OCaml smoke load the test helpers and call `test_tw_buy_budget ()` and `test_tw_decide_production_precheck ()` directly; observe the exact cash/margin/suspension errors and the fallback log. Do not launch a broker-backed CLI. Expected: equality passes, both shortage messages match exactly, all rebuys count, and Paper remains unchanged.

```python
import subprocess
subprocess.run(["opam", "exec", "--switch=/sandbox/stock", "--", "dune", "build", "--root", "."], cwd="/sandbox/stock-multi-stock-2", check=True)
subprocess.run(["opam", "exec", "--switch=/sandbox/stock", "--", "dune", "runtest", "--root", ".", "--force"], cwd="/sandbox/stock-multi-stock-2", check=True)
```

```python
smoke('let () = Check.test_tw_buy_budget (); Check.test_tw_decide_production_precheck (); print_endline "TW_BUDGET_SMOKE_OK"')
```

- [ ] **Step 6: Commit only after coordinator review.** Commit only after the coordinator confirms; use the co-author trailer the coordinator names; never push; never change git settings.

```python
import os, subprocess
root = "/sandbox/stock-multi-stock-2"
subprocess.run(["git", "-C", root, "add", root + "/broker/live.ml", root + "/broker/live.mli", root + "/test/test_bt.ml"], cwd=root, check=True)
subprocess.run(["git", "-C", root, "commit", "-m", "feat: precheck TW production buy holds and suspensions", "-m", os.environ["COAUTHOR_TRAILER"]], cwd=root, check=True)
```

### Task 3: Replace the scalar TW executor with per-code phases

**Files:**

| Operation | Absolute path and section |
|---|---|
| Modify | `/sandbox/stock-multi-stock-2/broker/live.ml`: execution types near `tw_execution`, replace `execute_tw_legs` at 1181-1597, scalar daemon call at 1736-1740 |
| Modify | `/sandbox/stock-multi-stock-2/broker/live.mli`: execution asset record, execution cash, replace scalar executor signature/comment |
| Modify/test | `/sandbox/stock-multi-stock-2/test/test_bt.ml`: `tw_trade`, `execute_tw_test`, `scripted_placements`, executor tests at 7233-7281 and 7940-8401, new two-code scenarios, final registration |

**Interfaces:**

| Direction | Contract |
|---|---|
| Consumes | Stage 1 `leg.code`/`exchange`, `position_totals` over symbol and price arrays, existing `tw_order_cost`, injected `place_order` and code-labelled `orders_today` |
| Produces | `tw_execution_asset = { code; exchange; bid; ask; price; financing_ratio; costs }`; executor takes `~assets:tw_execution_asset array` in place of the seven scalar quote/contract/cost labels |
| Returns | Existing `trades`, `remaining`, `stop_reason`, plus `cash : float`, the conservative final running cash used to prove the quote-reservation/deal-price invariant; no new daemon log field |
| Dependencies | Paired successor matching includes `sell.code = buy.code` and exchange, not just quantity/lot/condition. This closes stage 1 security note TW5-XDEP. |

This task changes N=1 execution visibly: ordinary sells and buys batch by phase, and a rejected, uncertain or FOK-killed Common sell with no fill stops before refinance pairs and buys. A definitive failed buy does not stop sibling buys. Keep the 13:24:30 placement cutoff, 13:25 poll cutoff, five rounds, partial-fill guard, odd-lot skip/guard/no-credit rules, full-dependent funding, capped-buy remainder, and cash-overrun stop.

#### Executor inputs and state

- [ ] **Step 1 (RED): Add the two-code tests in Offline execution scenarios before changing production execution, register them, and migrate the test helper signature.** `tw_trade` on main already uses `leg.code`; retain it rather than re-hardcoding 2330. Add the two request identity checks to `scripted_placements`. Define the record in both production declarations and replace the executor signature so all callers migrate atomically.

```ocaml
type tw_execution_asset = {
  code : string;
  exchange : string;
  bid : float;
  ask : float;
  price : float;
  financing_ratio : float;
  costs : Engine.costs;
}
```

Add to `tw_execution` in `.ml` and `.mli`:

```ocaml
  cash : float;
```

New exported signature (remove all scalar quote/code/exchange/cost labels):

```ocaml
val execute_tw_legs :
  mode:mode -> assets:tw_execution_asset array ->
  now:(unit -> string) -> sleep:(float -> unit) ->
  place_order:(Shioaji.order_request -> Shioaji.placed) ->
  orders_today:(code:string -> today:string -> Shioaji.trade list) ->
  date:string -> cash:float -> positions:Shioaji.position list ->
  leg list -> tw_execution
```

Replace `execute_tw_test` with:

```ocaml
let execute_tw_test ?(mode = Live.Live) ?(bid = 10.) ?(ask = 10.)
    ?(price = 10.) ?assets
    ?(now = fun () -> "2026-05-22T13:20:00+08:00")
    ?(sleep = fun _ -> ())
    ?(place_order = fun _ ->
      { Shioaji.order_id = "1"; status = "PendingSubmit" })
    ?(orders_today = fun ~code:_ ~today:_ -> [])
    ?(costs = zero_costs) ~cash ~positions legs =
  let assets = match assets with
    | Some assets -> assets
    | None -> [|{ Live.code = "2330"; exchange = "TSE"; bid; ask; price;
        financing_ratio = 0.6; costs }|] in
  Live.execute_tw_legs ~mode ~assets ~now ~sleep ~place_order ~orders_today
    ~date:"2026-05-22" ~cash ~positions legs
```

Insert before the existing `request.action` assertion in `scripted_placements`:

```ocaml
        let () = assert (request.code = expected.code) in
        let () = assert (request.exchange = expected.exchange) in
```

```python
import subprocess
subprocess.run(["opam", "exec", "--switch=/sandbox/stock", "--", "dune", "runtest", "--root", ".", "--force"], cwd="/sandbox/stock-multi-stock-2", check=True)
```

Expected RED: implementation/interface mismatch and the new batching assertions fail until the replacement lands. No intermediate commit.

- [ ] **Step 2 (GREEN): Replace the scalar function's setup and money helpers with the following per-code implementation.** Keep one account cash ref; share one symbol/price array aggregation. The guard scans every leg before the first POST: a later unknown code or wrong exchange still rejects the entire request list, preserving `test_tw_live_input_guards`' safety assertion. Each pending Common order captures its cash reservation and reserves its proportional loan/interest repayment at placement; the phase owns those values, not a global predecessor from another code.

The next three blocks form one complete replacement for `execute_tw_legs`; concatenate them in their displayed order. Keep `tw_order_cost` immediately before it unchanged.

```ocaml
let execute_tw_legs ~mode ~(assets : tw_execution_asset array)
    ~now ~sleep ~(place_order : Shioaji.order_request -> Shioaji.placed)
    ~orders_today ~date ~cash ~positions legs =
  let () = validate_date "order" date in
  let () = if not (Float.is_finite cash) then
    failwith "TW execution cash is not finite" in
  let symbols = Array.map (fun (a : tw_execution_asset) -> a.code) assets in
  let prices = Array.map (fun (a : tw_execution_asset) -> a.price) assets in
  let () = Array.iter (fun (a : tw_execution_asset) ->
    let () = if not (Float.is_finite a.price) || a.price <= 0. then
      failwith "TW execution price must be finite and positive" in
    if not (Float.is_finite a.financing_ratio)
      || a.financing_ratio < 0. || a.financing_ratio > 1. then
      failwith "TW financing ratio must be between zero and one") assets in
  let index (leg : leg) =
    let rec find i =
      if i = Array.length assets then
        failwith "TW leg code does not match executor code"
      else if assets.(i).code = leg.code then
        if assets.(i).exchange = leg.exchange then i
        else failwith "TW leg code does not match executor code"
      else find (i + 1) in
    find 0 in
  let () = List.iter (fun leg -> ignore (index leg)) legs in
  let totals = position_totals ~symbols ~prices positions in
  let cash_shares = Array.map (fun (cs, _, _, _, _, _) -> int_of_float cs) totals in
  let margin_lots = Array.map (fun (_, ms, _, _, _, _) -> int_of_float (ms /. 1000.)) totals in
  let loans = Array.map (fun (_, _, _, _, loan, _) -> loan) totals in
  let interests = Array.map (fun (_, _, _, _, _, interest) -> interest) totals in
  let () = Array.iteri (fun i lots ->
    if lots = 0 && (loans.(i) <> 0. || interests.(i) <> 0.) then
      failwith "TW margin liabilities have no margin inventory") margin_lots in
  let cash = ref cash in
  let trades = ref [] in
  let stop_reason = ref None in
  let set_stop reason = if !stop_reason = None then stop_reason := Some reason in
  let open_window () =
    let timestamp = now () in
    timestamp_date timestamp = date && taipei_phase ~now:timestamp = `Decide in
  let submission_window () =
    let timestamp = now () in
    let local = Unix.gmtime
      (float_of_int (rfc3339_seconds timestamp + (8 * 60 * 60))) in
    timestamp_date timestamp = date && taipei_phase ~now:timestamp = `Decide
    && (local.tm_hour * 60 + local.tm_min) * 60 + local.tm_sec
      < (13 * 60 + 24) * 60 + 30 in
  let shares (leg : leg) quantity = match leg.lot with
    | Shioaji.Common -> quantity * 1000
    | Shioaji.IntradayOdd -> quantity in
  let cash_required i (leg : leg) quantity price =
    let amount = shares leg quantity in
    let value = float_of_int amount *. price in
    let cost = tw_order_cost assets.(i).costs ~action:"Buy" ~price ~shares:amount in
    match leg.cond with
    | "Cash" -> value +. cost
    | "MarginTrading" -> ((1. -. assets.(i).financing_ratio) *. value) +. cost
    | cond -> failwith ("unsupported TW buy condition " ^ cond) in
  let affordable_quantity i leg maximum quote =
    let rec search low high =
      if low >= high then low
      else let middle = low + ((high - low + 1) / 2) in
        if cash_required i leg middle quote <= Float.max 0. !cash then search middle high
        else search low (middle - 1) in
    search 0 maximum in
  let reserve_inventory i (leg : leg) direction =
    match leg.action, leg.cond with
    | "Sell", "Cash" -> cash_shares.(i) <- cash_shares.(i) + direction * shares leg leg.quantity
    | "Sell", "MarginTrading" -> margin_lots.(i) <- margin_lots.(i) + direction * leg.quantity
    | "Buy", _ -> ()
    | _ -> assert false in
  let settle i (leg : leg) reserved repayment interest
      (trade : Shioaji.trade) =
    let price = match trade.deal_price with Some price -> price | None -> assert false in
    let amount = shares leg trade.deal_quantity in
    let value = float_of_int amount *. price in
    let cost = tw_order_cost assets.(i).costs ~action:leg.action ~price ~shares:amount in
    let cash_effect = match leg.action, leg.cond with
      | "Sell", "Cash" -> value -. cost
      | "Sell", "MarginTrading" ->
          value -. repayment -. interest -. cost
      | "Buy", "Cash" ->
          let () = cash_shares.(i) <- cash_shares.(i) + amount in
          -. (value +. cost)
      | "Buy", "MarginTrading" ->
          let () = margin_lots.(i) <- margin_lots.(i) + trade.deal_quantity in
          let () = loans.(i) <- loans.(i) +. assets.(i).financing_ratio *. value in
          -. (((1. -. assets.(i).financing_ratio) *. value) +. cost)
      | _ -> assert false in
    let () = cash := !cash +. reserved +. cash_effect in
    if !cash < -. 1e-9 then set_stop (Printf.sprintf
      "confirmed fill exceeded cash budget by %.10g" (-. !cash)) in
  let rejected status = List.mem status ["Failed"; "Inactive"; "Cancelled"; "Rejected"] in
  let classify (leg : leg) order_id history =
    let error reason observed = `Uncertain ("order " ^ order_id ^ " " ^ reason, observed) in
    match history with
    | Error reason -> error ("status unavailable: " ^ reason) None
    | Ok history ->
        match List.filter (fun (t : Shioaji.trade) -> t.order_id = order_id) history with
        | [] -> error "has no status" None
        | _ :: _ :: _ -> error "has ambiguous status" None
        | [trade] ->
            if trade.code <> leg.code || trade.action <> leg.action
              || trade.cond <> leg.cond || trade.lot <> leg.lot then
              error "status does not match request" (Some trade)
            else if trade.status = "Filled" && trade.deal_quantity = leg.quantity
              && trade.order_quantity = leg.quantity then
              (match trade.deal_price with
               | Some price when Float.is_finite price && price > 0. -> `Filled trade
               | Some _ | None -> error "filled without a valid price" (Some trade))
            else if trade.status = "Filled" || trade.status = "PartFilled" then
              error (Printf.sprintf "partially filled %d of %d"
                trade.deal_quantity leg.quantity) (Some trade)
            else if rejected trade.status && trade.deal_quantity = 0 then `Rejected trade
            else if List.mem trade.status ["PendingSubmit"; "PreSubmitted"; "Submitted"] then
              if trade.deal_quantity <> 0 then error "has unconfirmed partial exposure" (Some trade)
              else if trade.order_quantity <> 0 && trade.order_quantity <> leg.quantity then
                error "status quantity does not match request" (Some trade)
              else `Pending trade
            else error ("has unsupported status " ^ trade.status) (Some trade) in
```

#### Phase placement and reconciliation

- [ ] **Step 3 (GREEN): Add the batched poll and placement implementation below inside that replacement.** A round reads `orders_today` once per code with a still-pending order. Observe every sibling in a round even after one failed result; retain already-observed trades once. Pending siblings receive up to five rounds total, one second apart, including after an uncertain placement has stopped further POSTs. A pending odd sell never joins the barrier and never increases cash.

```ocaml
  let histories = Array.make (Array.length assets) None in
  let poll_group pending =
    let record = function None -> () | Some trade -> trades := trade :: !trades in
    let rec round remaining pending =
      if pending = [] then ()
      else if not (open_window ()) then
        List.iter (fun (_, _, id, _, _, _) ->
          set_stop ("order " ^ id ^ " status unconfirmed at cutoff")) pending
      else
        let () = Array.fill histories 0 (Array.length histories) None in
        let history i = match histories.(i) with
          | Some result -> result
          | None ->
              let result = try Ok (orders_today ~code:assets.(i).code ~today:date)
                with error -> Error (error_text error) in
              let () = histories.(i) <- Some result in
              result in
        let rec observe waiting = function
          | [] -> List.rev waiting
          | ((i, (leg : leg), id, reserved, repayment, interest) as item) :: rest ->
              let outcome = classify leg id (history i) in
              let () = match outcome with
                | `Filled trade ->
                    let () = record (Some trade) in
                    settle i leg reserved repayment interest trade
                | `Rejected trade ->
                    let () = record (Some trade) in
                    let () = reserve_inventory i leg 1 in
                    let () = loans.(i) <- loans.(i) +. repayment in
                    let () = interests.(i) <- interests.(i) +. interest in
                    let () = cash := !cash +. reserved in
                    let reason = "order " ^ id ^ " " ^ String.lowercase_ascii trade.status in
                    let () = log "code=%s submitted=skip:%s" leg.code reason in
                    if leg.action = "Sell" then set_stop reason
                | `Uncertain (reason, trade) ->
                    let () = record trade in set_stop reason
                | `Pending trade when remaining = 1 ->
                    let () = record (Some trade) in set_stop ("order " ^ id ^ " status timed out")
                | `Pending _ -> () in
              let waiting = match outcome with
                | `Pending _ when remaining > 1 -> item :: waiting
                | _ -> waiting in
              observe waiting rest in
        let waiting = observe [] pending in
        if waiting <> [] then let () = sleep 1. in round (remaining - 1) waiting in
    round 5 pending in
  let custom_field = "bt" ^ String.sub date 5 2 ^ String.sub date 8 2 in
  let run_group dependent group =
    let pending = ref [] in
    let hard_stop reason remaining = let () = set_stop reason in remaining in
    let rec place = function
      | [] -> []
      | (leg : leg) :: rest ->
          let i = index leg in
          if leg.lot = Shioaji.IntradayOdd && mode = Paper then
            let () = log "submitted=skip:odd-lot-unsupported-in-simulation" in place rest
          else
            let quote = match leg.lot, leg.action with
              | Shioaji.Common, _ -> assets.(i).price
              | Shioaji.IntradayOdd, "Buy" -> assets.(i).ask
              | Shioaji.IntradayOdd, "Sell" -> assets.(i).bid
              | _, action -> failwith ("unsupported TW order action " ^ action) in
            if not (Float.is_finite quote) || quote <= 0. then
              let () = log "submitted=skip:odd-lot-quote-unavailable" in place rest
            else
              let quantity = match leg.action with
                | "Buy" -> affordable_quantity i leg leg.quantity quote
                | "Sell" -> leg.quantity
                | action -> failwith ("unsupported TW order action " ^ action) in
              if dependent && quantity <> leg.quantity then
                hard_stop (Printf.sprintf "dependent %s %s %d is not fully funded"
                  leg.action leg.cond leg.quantity) (leg :: rest)
              else if quantity = 0 then
                hard_stop (Printf.sprintf "insufficient confirmed cash for %s %s %d"
                  leg.action leg.cond leg.quantity) (leg :: rest)
              else
                let submitted = { leg with quantity } in
                let inventory_ok = match submitted.action, submitted.cond, submitted.lot with
                  | "Sell", "Cash", _ -> shares submitted quantity <= cash_shares.(i)
                  | "Sell", "MarginTrading", Shioaji.Common -> quantity <= margin_lots.(i)
                  | "Buy", ("Cash" | "MarginTrading"), _ -> true
                  | _, cond, _ -> failwith ("unsupported TW order condition " ^ cond) in
                if not inventory_ok then hard_stop (Printf.sprintf
                  "insufficient %s inventory for %d shares" leg.cond
                  (shares submitted quantity)) (leg :: rest)
                else
                  let guarded = match submitted.lot with
                    | Shioaji.Common -> Ok ()
                    | Shioaji.IntradayOdd ->
                        (try
                          let history = orders_today ~code:submitted.code ~today:date in
                          if List.exists (fun (trade : Shioaji.trade) ->
                            trade.code = submitted.code && trade.lot = Shioaji.IntradayOdd
                            && trade.action <> submitted.action && trade.deal_quantity > 0)
                            history then Error "opposite-direction odd-lot fill today"
                          else Ok ()
                         with error -> Error ("odd-lot trade history unavailable: " ^ error_text error)) in
                  match guarded with
                  | Error reason -> hard_stop reason (leg :: rest)
                  | Ok () ->
                      let request : Shioaji.order_request =
                        { exchange = submitted.exchange; code = submitted.code;
                          action = submitted.action; lot = submitted.lot;
                          quantity; price = (if submitted.lot = Shioaji.Common then 0. else quote);
                          cond = submitted.cond; custom_field } in
                      if not (submission_window ()) then hard_stop (Printf.sprintf
                        "submission window closed before %s %s %d"
                        leg.action leg.cond leg.quantity) (leg :: rest)
                      else
                        let reserved = if submitted.action = "Buy" then
                          cash_required i submitted quantity quote else 0. in
                        let repayment, interest =
                          if submitted.action = "Sell" && submitted.cond = "MarginTrading" then
                            let fraction = float_of_int quantity /. float_of_int margin_lots.(i) in
                            loans.(i) *. fraction, interests.(i) *. fraction
                          else 0., 0. in
                        let () = cash := !cash -. reserved in
                        let () = reserve_inventory i submitted (-1) in
                        let () = loans.(i) <- loans.(i) -. repayment in
                        let () = interests.(i) <- interests.(i) -. interest in
                        match (try Ok (place_order request) with error -> Error (error_text error)) with
                        | Error reason -> hard_stop ("order submission uncertain: " ^ reason) rest
                        | Ok placed when rejected placed.Shioaji.status ->
                            let () = cash := !cash +. reserved in
                            let () = reserve_inventory i submitted 1 in
                            let () = loans.(i) <- loans.(i) +. repayment in
                            let () = interests.(i) <- interests.(i) +. interest in
                            let () = log "code=%s submitted=skip:%s-rejected" submitted.code
                              (if submitted.lot = Shioaji.IntradayOdd then "odd-lot" else "common") in
                            let () = if submitted.action = "Sell" then set_stop
                              ("order " ^ placed.order_id ^ " " ^ String.lowercase_ascii placed.status) in
                            place rest
                        | Ok placed when placed.Shioaji.order_id = "" ->
                            hard_stop "order submission returned no order id" rest
                        | Ok placed ->
                            let () = match submitted.lot with
                              | Shioaji.Common -> pending :=
                                  (i, submitted, placed.order_id, reserved, repayment, interest) :: !pending
                              | Shioaji.IntradayOdd ->
                                  log "submitted=intraday-odd-rod-pending quantity=%d" quantity in
                            if quantity <> leg.quantity then hard_stop (Printf.sprintf
                              "capped %s %s from %d to %d funded %s" leg.action leg.cond
                              leg.quantity quantity
                              (match leg.lot with Shioaji.Common -> "lots" | Shioaji.IntradayOdd -> "shares"))
                              ({ leg with quantity = leg.quantity - quantity } :: rest)
                            else place rest in
    let remaining = place group in
    let () = poll_group (List.rev !pending) in
    remaining in
```

- [ ] **Step 4 (GREEN): Finish the replacement with code-aware pair grouping and the phase runner.** The existing leg list already encodes pairs: adjacent Common sell/rebuy legs of the same code and quantity, with a margin rebuy. Leading rollover pairs run first; ordinary sells batch until refinance pairs; refinance pairs run one leg at a time; the remainder is the buy phase. A cross-code adjacent sell and buy is never classified as a dependent pair. Do not move pair sells into the ordinary sell batch.

```ocaml
  let paired (sell : leg) (buy : leg) =
    sell.code = buy.code && sell.exchange = buy.exchange
    && sell.action = "Sell" && buy.action = "Buy"
    && buy.cond = "MarginTrading" && sell.lot = Shioaji.Common
    && buy.lot = Shioaji.Common && sell.quantity = buy.quantity in
  let rec take_pairs acc = function
    | sell :: buy :: rest when paired sell buy ->
        take_pairs ((true, [buy]) :: (false, [sell]) :: acc) rest
    | rest -> List.rev acc, rest in
  let leading, rest = take_pairs [] legs in
  let rec take_sells acc = function
    | sell :: buy :: _ as rest when paired sell buy -> List.rev acc, rest
    | (leg : leg) :: rest when leg.action = "Sell" -> take_sells (leg :: acc) rest
    | rest -> List.rev acc, rest in
  let sells, rest = take_sells [] rest in
  let refinances, buys = take_pairs [] rest in
  let () = if List.exists (fun (leg : leg) -> leg.action <> "Buy") buys then
    failwith "TW legs are not in phase order" in
  let groups = leading @ [false, sells] @ refinances @ [false, buys] in
  let rec execute = function
    | [] -> []
    | (dependent, group) :: rest ->
        let remaining = run_group dependent group in
        if !stop_reason = None then execute rest
        else remaining @ List.concat_map snd rest in
  let remaining = execute groups in
  { trades = List.rev !trades; remaining; stop_reason = !stop_reason; cash = !cash }
```

Update the `.mli` doc comment to state: ordinary Common sells/buys place then batch-poll; rollover/refinance pairs are sequential; odd ROD sells are unpolled and provide no same-session cash; every leg must match one declared execution asset; result cash includes pending-buy reservations.

- [ ] **Step 5 (GREEN): Migrate the daemon's existing one-code call immediately, without lifting its startup guard yet.** This is not a compatibility wrapper: it calls the sole N-asset executor with a one-element array, the N=1 form that remains valid after Task 4.

```ocaml
                          let execution = execute_tw_legs ~mode
                            ~assets:[|{ code = symbol; exchange; bid = snapshot.bid;
                              ask = snapshot.ask; price = asset.provisional.c;
                              financing_ratio; costs }|]
                            ~now:taipei_now ~sleep:Unix.sleepf
                            ~place_order:Shioaji.place_order ~orders_today:Shioaji.orders_today
                            ~date ~cash ~positions legs in
```

#### Offline execution scenarios

- [ ] **Step 6: Add the two-code sell barrier, failure, odd-sell and cross-code dependency assertions.** The event order proves both sells POST before the first phase poll and no ordinary buy crosses a failed Common sell. Use each code's inventory and TSE/OTC contract. A placement uncertainty stops the remaining POSTs but does not erase the first sibling's confirmed fill. Preserve this test permanently.

```ocaml
let tw_pair_assets : Live.tw_execution_asset array =
  [|{ code = "2330"; exchange = "TSE"; price = 10.; bid = 9.; ask = 11.;
      financing_ratio = 0.6; costs = zero_costs };
    { code = "2890"; exchange = "OTC"; price = 20.; bid = 19.; ask = 21.;
      financing_ratio = 0.5; costs = zero_costs }|]

let test_tw_pair_sell_barrier () =
  let sell : Live.leg = { code = "2330"; exchange = "TSE"; action = "Sell";
    cond = "Cash"; lot = Shioaji.Common; quantity = 1 } in
  let second = { sell with code = "2890"; exchange = "OTC" } in
  let buy = { second with action = "Buy" } in
  let positions : Shioaji.position list =
    [{ id = 0; code = "2330"; cond = "Cash"; shares = 1000;
       last_price = 10.; loan_amount = 0.; interest = 0. };
     { id = 1; code = "2890"; cond = "Cash"; shares = 1000;
       last_price = 20.; loan_amount = 0.; interest = 0. }] in
  let run outcome =
    let events = ref [] in
    let emit text = events := text :: !events in
    let result = execute_tw_test ~assets:tw_pair_assets ~cash:0. ~positions
      ~place_order:(fun request ->
        let () = emit ("post:" ^ request.Shioaji.action ^ ":" ^ request.code) in
        if outcome = "uncertain" && request.code = "2890" && request.action = "Sell"
        then failwith "lost response"
        else { Shioaji.order_id = request.action ^ request.code;
          status = if outcome = "placement-rejected" && request.action = "Sell"
            && request.code = "2330" then "Rejected" else "Submitted" })
      ~orders_today:(fun ~code ~today:_ ->
        let () = emit ("poll:" ^ code) in
        let leg = if code = "2330" then sell else second in
        let status = if code = "2330" && outcome = "rejected" then "Rejected"
          else if code = "2330" && outcome = "killed" then "Cancelled" else "Filled" in
        let filled = if status = "Filled" then 1 else 0 in
        let trade = { (tw_trade ("Sell" ^ code) leg status filled) with
          Shioaji.deal_price = if filled = 0 then None
            else Some (if code = "2330" then 10. else 20.) } in
        [trade; { (tw_trade "Buy2890" buy "Filled" 1) with deal_price = Some 20. }])
      [sell; second; buy] in
    result, List.rev !events in
  let complete, events = run "filled" in
  (* Both 1000-share sales precede status reads. Cash buy needs 20000 cash;
     10000+20000 proceeds fund it, leaving 10000. *)
  let () = assert (events = ["post:Sell:2330"; "post:Sell:2890";
    "poll:2330"; "poll:2890"; "post:Buy:2890"; "poll:2890"]) in
  let () = assert (complete.remaining = [] && complete.stop_reason = None) in
  let () = assert_close 10000. complete.cash in
  let () = List.iter (fun outcome ->
    let result, events = run outcome in
    (* A rejected, killed or uncertain sell forbids every refinance/buy;
       the confirmed first/sibling order is still observed after placements stop. *)
    let () = assert (result.remaining = [buy]) in
    let () = assert (Option.is_some result.stop_reason) in
    let () = assert (not (List.mem "post:Buy:2890" events)) in
    if outcome = "uncertain" then assert (result.trades = [tw_trade "Sell2330" sell "Filled" 1]))
    ["rejected"; "killed"; "placement-rejected"; "uncertain"] in
  let odd = { sell with lot = Shioaji.IntradayOdd; quantity = 1 } in
  let odd_buy = { buy with cond = "MarginTrading" } in
  let events = ref [] in
  let odd_result = execute_tw_test ~assets:tw_pair_assets ~cash:10000. ~positions
    ~place_order:(fun request ->
      let () = events := ("post:" ^ request.Shioaji.code) :: !events in
      { Shioaji.order_id = request.code; status = "Submitted" })
    ~orders_today:(fun ~code ~today:_ ->
      let () = events := ("read:" ^ code) :: !events in
      if code = "2330" then []
      else [{ (tw_trade "2890" odd_buy "Filled" 1) with deal_price = Some 20. }])
    [odd; odd_buy] in
  (* Cross-code equal-quantity sell/buy is not a dependent pair (TW5-XDEP).
     The one odd-sell history read is its round-trip guard, not a fill poll.
     Pending odd proceeds add zero; the pre-existing 10000 alone funds the buy. *)
  let () = assert (List.rev !events = ["read:2330"; "post:2330";
    "post:2890"; "read:2890"]) in
  let () = assert (odd_result.stop_reason = None) in
  assert_close 0. odd_result.cash
```

Add the explicit refinance-stop and uncertain-buy sibling cases alongside that function:

```ocaml
let test_tw_sell_stop_before_refinance () =
  let sell : Live.leg = { code = "2330"; exchange = "TSE"; action = "Sell";
    cond = "Cash"; lot = Shioaji.Common; quantity = 1 } in
  let odd = { sell with code = "2890"; exchange = "OTC";
    lot = Shioaji.IntradayOdd; quantity = 1 } in
  let rebuy = { sell with action = "Buy"; cond = "MarginTrading" } in
  let buy = { sell with code = "2890"; exchange = "OTC"; action = "Buy" } in
  let posted = ref [] in
  let result = execute_tw_test ~assets:tw_pair_assets ~cash:100000.
    ~positions:[{ (tw_position "Cash" 2) with Shioaji.code = "2330" };
      { (tw_position "Cash" 1) with code = "2890"; shares = 1 }]
    ~place_order:(fun request ->
      let () = posted := (request.Shioaji.code, request.lot) :: !posted in
      { Shioaji.order_id = request.code; status = "Submitted" })
    ~orders_today:(fun ~code ~today:_ ->
      if code = "2890" then [] else [tw_trade "2330" sell "Cancelled" 0])
    [sell; odd; sell; rebuy; buy] in
  (* Ordinary Common sale is FOK-killed. Even ample cash cannot bypass the
     sell barrier to submit the cash-to-margin refinance pair or the other buy. *)
  let () = assert (List.rev !posted = ["2330", Shioaji.Common;
    "2890", Shioaji.IntradayOdd]) in
  let () = assert (result.remaining = [sell; rebuy; buy]) in
  assert (result.stop_reason = Some "order 2330 cancelled")

let test_tw_uncertain_buy_reconciles_sibling () =
  let buy : Live.leg = { code = "2330"; exchange = "TSE"; action = "Buy";
    cond = "Cash"; lot = Shioaji.Common; quantity = 1 } in
  let second = { buy with code = "2890"; exchange = "OTC" } in
  let third = { buy with cond = "MarginTrading" } in
  let events = ref [] in
  let result = execute_tw_test ~assets:tw_pair_assets ~cash:40000. ~positions:[]
    ~place_order:(fun request ->
      let () = events := ("post:" ^ request.Shioaji.code) :: !events in
      if request.code = "2890" then failwith "lost response"
      else { Shioaji.order_id = "first"; status = "Submitted" })
    ~orders_today:(fun ~code ~today:_ ->
      let () = events := ("poll:" ^ code) :: !events in
      [{ (tw_trade "first" buy "Filled" 1) with Shioaji.deal_price = Some 9. }])
    [buy; second; third] in
  (* Second POST is uncertain: third is unsent, but first is still polled.
     Keep the unknown 20000 hold and settle first at 9000: 40000-20000-9000=11000. *)
  let () = assert (List.rev !events = ["post:2330"; "post:2890"; "poll:2330"]) in
  let () = assert (result.remaining = [third]) in
  let () = assert (result.trades =
    [{ (tw_trade "first" buy "Filled" 1) with Shioaji.deal_price = Some 9. }]) in
  let () = assert (result.stop_reason = Some "order submission uncertain: lost response") in
  assert_close 11000. result.cash
```

- [ ] **Step 7: Add quote-reservation, sibling-buy failure, capped-buy and per-code polling checks.** The first two Common buys are both reserved before either is polled. A cheaper first fill cannot make a later buy eligible retroactively. Failed buys release their known no-fill reservation at reconciliation; an uncertain placement retains it conservatively. A funded cap stops later placements and still reconciles earlier orders.

```ocaml
let test_tw_pair_buy_reservations () =
  let buy : Live.leg = { code = "2330"; exchange = "TSE"; action = "Buy";
    cond = "Cash"; lot = Shioaji.Common; quantity = 1 } in
  let second = { buy with code = "2890"; exchange = "OTC" } in
  let third = { buy with quantity = 1 } in
  let run ?(cash = 30000.) status quantity more =
    let events = ref [] in
    let result = execute_tw_test ~assets:tw_pair_assets ~cash ~positions:[]
      ~place_order:(fun request ->
        let () = events := ("post:" ^ request.Shioaji.code ^ ":" ^
          string_of_int request.quantity) :: !events in
        { Shioaji.order_id = request.code; status = "Submitted" })
      ~orders_today:(fun ~code ~today:_ ->
        let () = events := ("poll:" ^ code) :: !events in
        let leg = if code = "2330" then buy
          else { second with quantity = (if quantity = 2 then 1 else quantity) } in
        let status = if code = "2330" then status else "Filled" in
        let filled = if status = "Filled" then leg.quantity else 0 in
        [{ (tw_trade code leg status filled) with
          Shioaji.deal_price = if filled = 0 then None
            else Some (if code = "2330" then 9. else 19.) }])
      ([buy; { second with quantity }] @ more) in
    result, List.rev !events in
  let filled, events = run "Filled" 1 [] in
  (* Reserve 10000+20000 before polling; actual costs are 9000+19000.
     Final cash is 30000-28000=2000, not 0 and not credited twice. *)
  let () = assert (events = ["post:2330:1"; "post:2890:1";
    "poll:2330"; "poll:2890"]) in
  let () = assert_close 2000. filled.cash in
  let failed, events = run "Cancelled" 1 [] in
  (* FOK kill with no fill on a buy cannot suppress sibling 2890.
     Release 2330's 10000 reservation; only 19000 is ultimately spent. *)
  let () = assert (failed.stop_reason = None && failed.remaining = []) in
  let () = assert (events = ["post:2330:1"; "post:2890:1";
    "poll:2330"; "poll:2890"]) in
  let () = assert_close 11000. failed.cash in
  let capped, events = run "Filled" 2 [third] in
  (* First reserves 10000, leaving 20000: second requests two 20000 lots
     but sends one. Third and the second's unfunded lot stay unsubmitted. *)
  let () = assert (events = ["post:2330:1"; "post:2890:1";
    "poll:2330"; "poll:2890"]) in
  let () = assert (capped.remaining = [second; third]) in
  let () = assert (capped.stop_reason =
    Some "capped Buy Cash from 2 to 1 funded lots") in
  let () = assert_close 2000. capped.cash in
  let reserved, events = run "Filled" 1 [third] in
  (* A third lot cannot spend the future 2000 refund before fills are read. *)
  let () = assert (reserved.remaining = [third]) in
  assert (events = ["post:2330:1"; "post:2890:1"; "poll:2330"; "poll:2890"])
```

Register:

```ocaml
  let () = test_tw_pair_sell_barrier () in
  let () = test_tw_pair_buy_reservations () in
  let () = test_tw_sell_stop_before_refinance () in
  let () = test_tw_uncertain_buy_reconciles_sibling () in
```

- [ ] **Step 8: Add a same-code two-order polling scenario and keep exact boundary assertions.** Reuse the two-code fixture to show one status read per code per round, not one read per order. This catches double application of a completed sibling while another waits.

```ocaml
let test_tw_phase_poll_rounds () =
  let buy : Live.leg = { code = "2330"; exchange = "TSE"; action = "Buy";
    cond = "Cash"; lot = Shioaji.Common; quantity = 1 } in
  let margin = { buy with cond = "MarginTrading" } in
  let reads = ref 0 and posts = ref 0 in
  let result = execute_tw_test ~cash:20000. ~positions:[]
    ~place_order:(fun _ ->
      let () = incr posts in
      { Shioaji.order_id = string_of_int !posts; status = "Submitted" })
    ~orders_today:(fun ~code ~today:_ ->
      let () = assert (code = "2330" && !posts = 2) in
      let () = incr reads in
      [tw_trade "1" buy "Filled" 1;
       tw_trade "2" margin (if !reads = 1 then "Submitted" else "Filled")
         (if !reads = 1 then 0 else 1)]) [buy; margin] in
  (* Two orders in 2330 share one read in round one. Cash order settles once;
     only margin is still pending in round two. Spend 10000+4000, leave 6000. *)
  let () = assert (!reads = 2 && !posts = 2) in
  let () = assert (result.stop_reason = None) in
  assert_close 6000. result.cash
```

```ocaml
  let () = test_tw_phase_poll_rounds () in
```

The following existing tests remain behavior pins, with only their injected placement/poll timing migrated:

| Existing test | Required adaptation or invariant |
|---|---|
| `test_tw_live_input_guards` | Default helper's one known asset rejects later unknown code or wrong exchange before POST; N-leg/position shape and duplicate-symbol guards stay |
| `test_tw_execution_rechecks_cutoff` | Replace the queue of assumed `now` calls with a mutable timestamp changed to `13:24:30` by the first `place_order`; assert the second is unsent and the first still polls before 13:25 |
| `test_tw_execution_submission_window` | Keep before `13:24:29` pass and at `13:24:30` exact stop unchanged |
| `test_tw_odd_guard_rechecks_submission_window` | Keep deadline crossing during the odd history read; no POST |
| `test_tw_execution_polls_zero_qty_pending`, `test_tw_execution_times_out` | Accept PendingSubmit `order_quantity=0`; up to five rounds, timeout stops |
| `test_tw_execution_stops_on_predecessor` | Full fill needed for same-code pair; Failed/partial/missing/mismatched sell forbids rebuy |
| `test_tw_execution_tracks_refinanced_loan` | Sequential pairs retain proportional loan repayment and subsequent capped funded quantity |
| `test_tw_odd_quote_and_skip`, `test_tw_odd_independence_and_guard` | Missing quote/simulation skips stay; failed buys still permit their odd sibling; opposite filled odd direction is code-local |
| `test_tw_odd_reservation_and_minimums` | Odd buys reserve full quote cost and minimums; pending odd sells credit no cash |
| `test_tw_execution_remaining_stops` | Preserve ambiguous/partial/invalid price/mismatched quantity/missing ID/uncertain/inventory/no-cash guards; confirmed overrun still stops |

Also pin the per-code liability reservation when two pending margin sales share a code:

```ocaml
let test_tw_margin_sale_reservations () =
  let sell : Live.leg = { code = "2330"; exchange = "TSE"; action = "Sell";
    cond = "MarginTrading"; lot = Shioaji.Common; quantity = 1 } in
  let posted = ref 0 in
  let result = execute_tw_test ~cash:0.
    ~positions:[{ (tw_position "MarginTrading" 2) with
      Shioaji.loan_amount = 12000.; interest = 200. }]
    ~place_order:(fun _ ->
      let () = incr posted in
      { Shioaji.order_id = string_of_int !posted; status = "Submitted" })
    ~orders_today:(fun ~code:_ ~today:_ ->
      [tw_trade "1" sell "Filled" 1; tw_trade "2" sell "Filled" 1]) [sell; sell] in
  (* Reserve each 1000-share sale and its proportional liability before polling:
     20000 proceeds - 12000 principal - 200 interest = 7800, no double repayment. *)
  let () = assert (result.stop_reason = None) in
  assert_close 7800. result.cash
```

```ocaml
  let () = test_tw_margin_sale_reservations () in
```

Concrete cutoff injection replacing the old timestamp queue:

```ocaml
  let timestamp = ref "2026-05-22T13:24:29+08:00" in
  let result = execute_tw_test ~now:(fun () -> !timestamp)
    ~place_order:(fun request ->
      let () = assert (request.Shioaji.cond = "Cash") in
      let () = timestamp := "2026-05-22T13:24:30+08:00" in
      { Shioaji.order_id = "1"; status = "Submitted" })
    ~orders_today:(fun ~code:_ ~today:_ -> [tw_trade "1" first "Filled" 1])
    ~cash:20000. ~positions:[] [first; second] in
```

- [ ] **Step 9: Run the atomic GREEN gate, injected phase smoke, and six byte comparisons.** The assertions exercise actual placements, reads, reservations, settlement and stop transitions. The coordinator reviews the code/phase transition table before approving a commit.

```python
import subprocess
subprocess.run(["opam", "exec", "--switch=/sandbox/stock", "--", "dune", "build", "--root", "."], cwd="/sandbox/stock-multi-stock-2", check=True)
subprocess.run(["opam", "exec", "--switch=/sandbox/stock", "--", "dune", "runtest", "--root", ".", "--force"], cwd="/sandbox/stock-multi-stock-2", check=True)
```

```python
smoke('let () = Check.test_tw_pair_sell_barrier (); Check.test_tw_sell_stop_before_refinance (); Check.test_tw_uncertain_buy_reconciles_sibling (); Check.test_tw_pair_buy_reservations (); Check.test_tw_phase_poll_rounds (); Check.test_tw_margin_sale_reservations (); Check.test_multi_stock_one_stock_pins (); print_endline "TW_PHASE_SMOKE_OK"')
```

| Smoke | Observed result required |
|---|---|
| Filled two-code sells | Both sell POST events before either poll; first buy after both full fills |
| Rejected/FOK-killed sell | No ordinary buy or refinance placement; all previously placed siblings are observed |
| Uncertain placement | Later placements stop; previously accepted sibling is still polled and logged |
| Failed buy | Both sibling placements occur; confirmed no-fill hold is released |
| Quote reservations | Both costs reserved before polling; final cash 2000 at 9/19 deal prices |
| Cap | One funded lot sent, unfunded lot plus later buy remain, earlier orders reconciled |
| Cutoff | Each POST independently checks `< 13:24:30`; reads may continue until `< 13:25` |

- [ ] **Step 10: Commit only after coordinator review.** Commit only after the coordinator confirms; use the co-author trailer the coordinator names; never push; never change git settings.

```python
import os, subprocess
root = "/sandbox/stock-multi-stock-2"
subprocess.run(["git", "-C", root, "add", root + "/broker/live.ml", root + "/broker/live.mli", root + "/test/test_bt.ml"], cwd=root, check=True)
subprocess.run(["git", "-C", root, "commit", "-m", "feat: execute TW legs in per-code sell and buy phases", "-m", os.environ["COAUTHOR_TRAILER"]], cwd=root, check=True)
```

### Task 4: Run the TW daemon over all strategy codes

**Files:**

| Operation | Absolute path and section |
|---|---|
| Modify | `/sandbox/stock-multi-stock-2/broker/live.ml`: `prepare_tw` at 1113-1143, `run_tw` at 1598-1774, TW arm of `run` at 1812-1818 (line numbers before earlier tasks) |
| Modify/test | `/sandbox/stock-multi-stock-2/test/test_bt.ml`: remove only the obsolete TW startup guard part of `test_live_pair_cli_guards`; retain N-snapshot and N-decision tests |

**Interfaces:**

| Direction | Contract |
|---|---|
| Consumes | Task 3 `execute_tw_legs ~assets`, Task 2 `decide ?tw_log`, existing `Shioaji.snapshot ~contracts:(string * string) array`, N-asset decision and per-code totals |
| Produces | Private `prepare_tw ~contracts ~date ~data_dir` returns one independent previous session after checking/fetching all codes; private `run_tw ~symbols:string array` executes all codes |
| Preserves | Public `Live.run` signature, startup mode/equity checks, one market/mode lock, same calendar/sleep schedule, 13:20 decision, conservative existing-order dedupe, one failure skips the day |

The visible startup change here is removal of `TW live trading needs one stock in this release`; the executor's guard remains a full-list strategy-code/exchange check, not deletion of validation. The seven contract fields and one two-budget line acquire the daemon's `date=DATE` and UTC log prefix. Simulation performs no contract/limits reads, since its reported limits are zero.

- [ ] **Step 1: Retain and directly exercise existing spec Tests rows 7 and 15.** They already run on main, so do not invent RED or duplicate tests. Confirm the snapshot fixture maps requested codes rather than response position, and the decision assertions still use joint targets and total cash/debit. Keep their final registrations.

```ocaml
  let () = test_shioaji_snapshot_codes () in
  let () = test_tw_live_pair_decide () in
  let () = test_multi_stock_one_stock_pins () in
```

```python
import subprocess
subprocess.run(["opam", "exec", "--switch=/sandbox/stock", "--", "dune", "runtest", "--root", ".", "--force"], cwd="/sandbox/stock-multi-stock-2", check=True)
```

- [ ] **Step 2: Replace `prepare_tw` with the N-contract form.** The optional functions are private offline seams, mirroring the existing injected live helpers. Preparation makes one batched snapshot call, checks every date, queries the independent calendar once, then fetches and validates each symbol in declaration order. It does not reuse the 13:05 quote at 13:20.

```ocaml
let prepare_tw ?(snapshot = Shioaji.snapshot)
    ?(previous_trading_day = Data.previous_trading_day)
    ?(fetch = Data.fetch) ?(fetch_adjustments = Data.fetch_tw_adjustments)
    ~contracts ~date ~data_dir () =
  let snapshots = snapshot ~contracts in
  let () = if Array.length snapshots <> Array.length contracts then
    failwith "invalid Shioaji snapshot response" in
  let () = Array.iter (fun snapshot ->
    let snapshot_date = tw_snapshot_date snapshot in
    if snapshot_date <> date then failwith (Printf.sprintf
      "snapshot session %s is not trading date %s" snapshot_date date)) snapshots in
  let previous_session = previous_trading_day ~before:date in
  let () = Array.iter (fun (_, symbol) ->
    let () = fetch ~market:"tw" ~symbol ~from_:None ~to_:previous_session ~data_dir in
    let () = fetch_adjustments ~symbol ~to_:date ~data_dir in
    let asset = Data.load_asset ~market:"tw" ~symbol ~from_:None
      ~to_:(Some previous_session) ~data_dir in
    let through = match Array.length asset.signal with
      | 0 -> failwith "TW cache has no previous trading session"
      | length -> asset.signal.(length - 1).date in
    if through <> previous_session then failwith (Printf.sprintf
      "stale TW cache: fetched through %s, expected %s" through previous_session)) contracts in
  previous_session
```

The trailing `()` is required because preparation now has optional arguments. Migrate both `run_tw` call sites explicitly:

```ocaml
                   prepare_tw ~contracts ~date ~data_dir ())
```

- [ ] **Step 3: Change `run_tw`'s input and metadata to arrays.** Leave the entire startup accounting block and phase/sleep dispatcher unchanged. Replace only the scalar header and the three metadata bindings after `log_rebalance_warning`.

```ocaml
let run_tw mode ~equity ~symbols ~strat_path ~data_dir ~rebalance_choice =
```

```ocaml
  let exchanges = Array.map (exchange_of_symbol ~data_dir) symbols in
  let contracts = Array.mapi (fun i code -> exchanges.(i), code) symbols in
  let costs = Array.map tw_live_debit_costs symbols in
  let ratios = Array.map (fun symbol ->
    Data.financing_ratio ~market:"tw" ~data_dir ~symbol) symbols in
```

- [ ] **Step 4: Replace the existing-order lookup and the skip's single symbol line.** Read all codes before deciding. Any strategy-code order today skips the whole day; do not trade the other symbols on a partial TW restart. Keep the existing account `skip:existing-orders` line and startup-equity placeholders.

```ocaml
               let existing = Array.to_list symbols
                 |> List.concat_map (fun code -> Shioaji.orders_today ~code ~today:date) in
```

```ocaml
                    let () = Array.iter (fun symbol -> log
                      "date=%s symbol=%s provisional-close=- target=- cash-shares=- margin-shares=- loan=- planned-legs=none"
                      date symbol) symbols in
```

- [ ] **Step 5: Replace the empty-existing-orders branch's snapshot/details and decision/executor inputs.** There is one fresh batched snapshot request at 13:20; positions, balance and settlements remain account-wide reads. Per-symbol detail fetches use the existing share-consistency guard. Production budget reads occur only inside `decide`, once, and its failure is caught by the existing day-skip handler before execution.

```ocaml
                    let snapshots = Shioaji.snapshot ~contracts in
                    let positions = Shioaji.positions () in
                    let position_details = Array.to_list symbols
                      |> List.concat_map (fun symbol -> fetch_position_details symbol positions) in
```

Leave the existing `tw_balance, tw_settlements` mode match intact. Replace the decision call and the scalar asset/totals bindings:

```ocaml
                    let decision = decide ~previous_session ?equity ?tw_balance
                      ?tw_settlements ~tw_positions:positions
                      ~tw_position_details:position_details ~tw_snapshots:snapshots
                      ~tw_log:(fun text -> log "date=%s %s" date text)
                      mode ~session_date:date ~strat_path ~data_dir in
                    let prices = Array.map (fun (asset : asset_decision) -> asset.provisional.c)
                      decision.assets in
                    let totals = position_totals ~symbols ~prices positions in
                    let execution_assets = Array.mapi (fun i code ->
                      { code; exchange = exchanges.(i); bid = snapshots.(i).Shioaji.bid;
                        ask = snapshots.(i).ask; price = prices.(i);
                        financing_ratio = ratios.(i); costs = costs.(i) }) symbols in
                    let cash = decision.cash in
```

Replace Task 3's one-element executor call:

```ocaml
                          let execution = execute_tw_legs ~mode ~assets:execution_assets
                            ~now:taipei_now ~sleep:Unix.sleepf
                            ~place_order:Shioaji.place_order ~orders_today:Shioaji.orders_today
                            ~date ~cash ~positions legs in
```

Keep the existing `outcome, legs`, execution trade logging, stop/remaining description and account decision log. Replace only the final scalar symbol log with:

```ocaml
                    let () = Array.iteri (fun i (asset : asset_decision) ->
                      let cash_shares, margin_shares, _, _, loans, _ = totals.(i) in
                      let symbol_legs = List.filter (fun (leg : leg) -> leg.code = asset.symbol) legs in
                      log
                        "date=%s symbol=%s provisional-close=%.10g target=%.10g cash-shares=%.10g margin-shares=%.10g loan=%.10g planned-legs=%s"
                        date asset.symbol asset.provisional.c asset.target cash_shares margin_shares
                        loans (tw_legs_description symbol_legs)) decision.assets in
```

- [ ] **Step 6: Reconcile every code after close, then lift the startup guard in the market match.** Preserve the existing day-level failure catch and one-market lock. Remove the obsolete guard assertion from the tail of `test_live_pair_cli_guards`; never call `Live.run` offline once it would reach Shioaji. Keep the mixed-market, duplicate-symbol and single-price override checks unchanged.

Replace the after-close scalar trade query and `match trades` block:

```ocaml
          let () = Array.iter (fun code ->
            match Shioaji.orders_today ~code ~today:date with
            | [] -> log "date=%s code=%s fill-status=none" date code
            | trades -> List.iter (log_tw_trade date) trades) symbols in
```

Replace the whole TW arm in `run`:

```ocaml
  | "tw" ->
      let fd = lock_daemon ~directory ~market:"tw" mode in
      Fun.protect ~finally:(fun () -> Unix.close fd)
        (fun () -> run_tw mode ~equity ~symbols ~strat_path ~data_dir ~rebalance_choice)
```

- [ ] **Step 7: Run an offline N-contract preparation smoke through the actual private implementation and the existing decision/execution scenarios.** Use the Global Constraints smoke runner with the complete OCaml block below. It loads implementation source in memory, so the private preparation function is exercised without adding a production export or contacting FinMind/Shioaji. The scheduler itself is not run against a broker offline; the coordinator exercises that surface in production acceptance.

```python
smoke(r"""
let () =
  Check.with_tw_decision_cache (fun data_dir ->
    let requests = ref [] and refreshed = ref [] in
    let snapshot : Shioaji.snapshot =
      { datetime = "2026-05-26T13:05:00+08:00"; open_ = 10.; high = 10.; low = 10.;
        close = 10.; bid = 10.; ask = 10.; total_volume = 0. } in
    let previous = Live.prepare_tw
      ~snapshot:(fun ~contracts ->
        let () = requests := contracts :: !requests in [|snapshot; snapshot|])
      ~previous_trading_day:(fun ~before ->
        let () = assert (before = "2026-05-26") in "2026-05-22")
      ~fetch:(fun ~market ~symbol ~from_ ~to_ ~data_dir:_ ->
        let () = assert (market = "tw" && from_ = None && to_ = "2026-05-22") in
        refreshed := ("price:" ^ symbol) :: !refreshed)
      ~fetch_adjustments:(fun ~symbol ~to_ ~data_dir:_ ->
        let () = assert (to_ = "2026-05-26") in
        refreshed := ("adjust:" ^ symbol) :: !refreshed)
      ~contracts:[|"TSE", "2330"; "OTC", "2890"|]
      ~date:"2026-05-26" ~data_dir () in
    (* One N-contract request, one previous session, both symbols refreshed
       and cache-checked in declaration order. *)
    let () = assert (previous = "2026-05-22") in
    let () = assert (!requests = [[|"TSE", "2330"; "OTC", "2890"|]]) in
    assert (List.rev !refreshed = ["price:2330"; "adjust:2330";
      "price:2890"; "adjust:2890"]));
  Check.test_shioaji_snapshot_codes ();
  Check.test_tw_live_pair_decide ();
  Check.test_tw_decide_production_precheck ();
  Check.test_tw_pair_sell_barrier ();
  Check.test_tw_pair_buy_reservations ();
  print_endline "TW_N_CODE_SMOKE_OK"
""")
```

- [ ] **Step 8: Run GREEN gates and all six comparisons.** Expected: stage 1 one-stock decisions remain pinned, the three CLI guards remain offline, production decision pre-checks fail closed, all two-code injected flows pass, and both backtests remain byte-identical.

```python
import subprocess
subprocess.run(["opam", "exec", "--switch=/sandbox/stock", "--", "dune", "build", "--root", "."], cwd="/sandbox/stock-multi-stock-2", check=True)
subprocess.run(["opam", "exec", "--switch=/sandbox/stock", "--", "dune", "runtest", "--root", ".", "--force"], cwd="/sandbox/stock-multi-stock-2", check=True)
```

- [ ] **Step 9: Commit only after coordinator review.** Commit only after the coordinator confirms; use the co-author trailer the coordinator names; never push; never change git settings.

```python
import os, subprocess
root = "/sandbox/stock-multi-stock-2"
subprocess.run(["git", "-C", root, "add", root + "/broker/live.ml", root + "/test/test_bt.ml"], cwd=root, check=True)
subprocess.run(["git", "-C", root, "commit", "-m", "feat: run TW live across the strategy symbol set", "-m", os.environ["COAUTHOR_TRAILER"]], cwd=root, check=True)
```

### Task 5: Drive the existing US sell restart through us_step

**Files:**

| Operation | Absolute path and section |
|---|---|
| Modify/test | `/sandbox/stock-multi-stock-2/test/test_bt.ml`: beside `test_us_pair_restart_routing`, helpers `us_pair_decision`, `us_fixture_order`, final registration |
| Read | `/sandbox/stock-multi-stock-2/broker/live.ml`: `us_step` at 1014-1059, `execute_decision` at 893-1003 |

**Interfaces:**

| Direction | Contract |
|---|---|
| Consumes | Merged `us_step ~symbols ~lookup ~decide ~execute ~finish ~sleep_until ~retry ~continue clock`; `execute_decision ?existing ?sleep ?finish ?order_by_client_id ?clock ?submit_market mode date next_close decision` |
| Produces | Permanent `test_us_open_sell_restart_end_to_end : unit -> unit`, joining the real restart routing to the real executor, rather than checking an injected execute callback's captured arguments |
| Behavior | No US implementation change is planned. Preserve sell barrier, done-symbol dedupe, finish pass, cutoff stop and no retry after any POST. This closes the stage 1 ledger's end-to-end open-sell restart follow-up. |

- [ ] **Step 1: Add and register the integrated regression below.** It drives an existing SPY sell and a remaining QQQ buy through both production functions. Unlike the stage 1 routing-only test, the `execute` injection calls `Live.execute_decision` and exercises its real sell poll. Inject only broker I/O, clock, sleep and decision data; nothing uses the network.

```ocaml
let test_us_open_sell_restart_end_to_end () =
  let date = "2025-06-24" in
  let initial : Alpaca.clock_t =
    { timestamp = date ^ "T15:45:00-04:00"; is_open = true;
      next_open = "2025-06-25T09:30:00-04:00";
      next_close = date ^ "T16:00:00-04:00" } in
  let decision = us_pair_decision
    [|Live.Order { side = `Sell; qty = 1.; id = "bt-SPY-2025-06-24" };
      Live.Order { side = `Buy; qty = 1.; id = "bt-QQQ-2025-06-24" }|] in
  let run outcome =
    let polls = ref 0 and decisions = ref 0 and retries = ref 0 in
    let continued = ref 0 and posted = ref [] and finished = ref [] in
    let events = ref [] in
    let emit text = events := text :: !events in
    let output = capture_stdout (fun () ->
      Live.us_step ~symbols:[|"SPY"; "QQQ"|]
        ~lookup:(fun id ->
          let () = emit ("lookup:" ^ id) in
          if id = "bt-SPY-2025-06-24" then
            Some (us_fixture_order "SPY" "sell" "accepted") else None)
        ~decide:(fun actual_date ->
          let () = assert (actual_date = date) in
          let () = incr decisions in decision)
        ~execute:(fun existing clock actual ->
          let () = assert (actual.Live.assets.(0).action = Live.Skip "existing order") in
          Live.execute_decision ~existing
            ~order_by_client_id:(fun _ id ->
              if id <> "bt-SPY-2025-06-24" then None
              else
                let () = incr polls in
                let status = if outcome = "rejected" then "rejected"
                  else if outcome = "filled" && !polls = 2 then "filled"
                  else "accepted" in
                let () = emit ("sell:" ^ status) in
                Some (us_fixture_order "SPY" "sell" status))
            ~clock:(fun _ ->
              if outcome = "open-at-cutoff" then
                { initial with timestamp = date ^ "T15:58:00-04:00" } else initial)
            ~sleep:(fun seconds ->
              let () = assert (seconds = 15.) in emit "wait-sell")
            ~submit_market:(fun _ ~symbol ~qty ~side ~client_order_id ->
              let () = assert (symbol = "QQQ" && qty = 1. && side = `Buy
                && client_order_id = "bt-QQQ-2025-06-24") in
              let () = assert (outcome = "filled" && !polls = 2) in
              let () = posted := symbol :: !posted in
              let () = emit "post:QQQ" in us_fixture_order symbol "buy" "filled")
            ~finish:(fun _ _ symbol _ ->
              let () = finished := symbol :: !finished in emit ("finish:" ^ symbol))
            Live.Paper date clock.Alpaca.next_close actual)
        ~finish:(fun _ _ _ _ -> assert false)
        ~sleep_until:(fun timestamp ->
          let () = assert (timestamp = initial.next_open) in emit "next-open")
        ~retry:(fun () -> incr retries)
        ~continue:(fun () -> incr continued) initial) in
    (* The restart re-plans once, never resubmits SPY, and ends once without retry. *)
    let () = assert (!decisions = 1 && !retries = 0 && !continued = 1) in
    let events = List.rev !events in
    let () = assert (List.filter (fun event -> contains event "lookup:") events =
      ["lookup:bt-SPY-2025-06-24"; "lookup:bt-QQQ-2025-06-24"]) in
    if outcome = "filled" then
      (* QQQ POST follows the existing sell's second, filled observation. *)
      let () = assert (!posted = ["QQQ"] && !polls = 2) in
      let () = assert (List.filter (fun event ->
        contains event "sell:" || event = "post:QQQ") events =
        ["sell:accepted"; "sell:filled"; "post:QQQ"]) in
      assert (List.rev !finished = ["SPY"; "QQQ"])
    else
      (* Rejected or cutoff-open sell sends no buy, but still finishes the known sell. *)
      let () = assert (!posted = [] && List.rev !finished = ["SPY"]) in
      assert (contains output (if outcome = "rejected" then
        "error=sell SPY rejected order=skip"
        else "error=sell SPY open at cutoff order=skip")) in
  List.iter run ["filled"; "rejected"; "open-at-cutoff"]
```

```ocaml
  let () = test_us_open_sell_restart_end_to_end () in
```

- [ ] **Step 2: Run the scoped restart smoke, then GREEN gates and six comparisons.** This is a missing-coverage task, not a claimed new failing implementation path: the test is expected to pass on merged stage 1. Do not alter US behavior if a test fixture assumption fails; check the existing function contracts first.

Global smoke runner call:

```python
smoke(r"""
let () =
  Check.test_us_open_sell_restart_end_to_end ();
  print_endline "US_OPEN_SELL_RESTART_SMOKE_OK"
""")
```

```python
import subprocess
subprocess.run(["opam", "exec", "--switch=/sandbox/stock", "--", "dune", "build", "--root", "."], cwd="/sandbox/stock-multi-stock-2", check=True)
subprocess.run(["opam", "exec", "--switch=/sandbox/stock", "--", "dune", "runtest", "--root", ".", "--force"], cwd="/sandbox/stock-multi-stock-2", check=True)
```

- [ ] **Step 3: Commit only after coordinator review.** Commit only after the coordinator confirms; use the co-author trailer the coordinator names; never push; never change git settings.

```python
import os, subprocess
root = "/sandbox/stock-multi-stock-2"
subprocess.run(["git", "-C", root, "add", root + "/test/test_bt.ml"], cwd=root, check=True)
subprocess.run(["git", "-C", root, "commit", "-m", "test: drive existing US sell restart through execution", "-m", os.environ["COAUTHOR_TRAILER"]], cwd=root, check=True)
```

### Task 6: Update stage 2 documentation and changelog

**Owner:** The coordinator assigns this task to the doc-editor after Tasks 1-5. The doc-editor uses executing-plans only and dispatches no agent. Coordinator reviews all edits and release claims.

**Files:**

| Operation | Absolute path and section |
|---|---|
| Modify | `/sandbox/stock-multi-stock-2/docs/specs/tw-live-trading.md`: Decisions, Verified Shioaji facts, Modules, Daily cycle, Safety and failure, Testing and verification |
| Modify | `/sandbox/stock-multi-stock-2/docs/cli.md`: shared validation, TW target failures, live STRAT table, TW prerequisites/cycle/orders/logs/failures |
| Modify | `/sandbox/stock-multi-stock-2/docs/engine.md`: TW Live trading fidelity, IOC sentences at 216 and 223, budget fidelity gap |
| Modify | `/sandbox/stock-multi-stock-2/docs/specs/share-quantum-and-odd-lots.md`: dated supersession note near Decisions and Contents if adding a heading |
| Modify | `/sandbox/stock-multi-stock-2/docs/specs/multi-stock-live.md`: implementation status only; retain reviewed budget assumptions until coordinator measurements |
| Modify | `/sandbox/stock-multi-stock-2/CHANGELOG.md`: four stage 2 entries under `[Unreleased]`, retaining stage 1 and historical releases |

**Interfaces:**

| Direction | Contract |
|---|---|
| Consumes | Shipped Task 1-4 behavior and exact logs/messages; no additional code change |
| Produces | Current documentation of N-code execution, four phase groups, FOK, production-only pre-check and assumptions, seven contract fields, new failure messages, and four distinct CHANGELOG entries |
| Intentionally unchanged | `docs/specs/live-trading.md` and the US live paragraphs already describe the merged N-symbol/positions-list path; no duplicate stage 1 entries or new US semantics |

- [ ] **Step 1: Update the TW design's current behavior and add this dated stage 2 note.** In current implementation prose, change Common `MKT` + `IOC` to `MKT` + `FOK`, including the Decisions order sentence, Verified place-order sentence, and Daily cycle execution step. Keep the existing settlement observations, quote/window caveats and historical stage 1 note; the new note supersedes its release boundary.

```text
> [!NOTE]
> 2026-10-05: stage 2 of [Design: multi-stock live trading](./multi-stock-live.md#stages) executes all N distinct TW codes in one account. Preparation and decision snapshots each fetch N contracts in one request and validate every code. Rollover pairs run one leg at a time, then ordinary sells are placed across codes and their Common orders are polled together, then refinance pairs run one leg at a time, then ordinary buys are placed and polled together. Every ordinary Common sell must be fully confirmed before refinances or ordinary buys start. A rejected, uncertain or FOK-killed Common sell with no fill stops that transition, including at N = 1. IntradayOdd sells stay unpolled ROD orders, are exempt from the Common confirmation barrier, and contribute no same-session proceeds. Lot legs now use MKT + FOK; odd legs remain LMT + ROD. Production decisions read contract info once per symbol and trading limits once per session before any order. Simulation skips these reads because its trading limits are zero.
```

Replace current sequential-confirmation/failure prose with this table, preserving full-dependent funding and no-retry caveats:

```text
| Phase | Placement and confirmation |
|---|---|
| Rollover pairs | Sell then full original-lot rebuy, one leg at a time, code-local dependency. |
| Ordinary sells | Place all eligible sells; batch-poll Common orders up to five rounds, one second apart, one orders_today read per code per round. Pending odd ROD sells need no fill confirmation and add no cash. |
| Refinance pairs | Run only after the Common sell barrier passes; sell then fully funded full-lot rebuy, one leg at a time. |
| Ordinary buys | Reserve each buy's quote-price cost from one running cash balance before placement of later buys; batch-poll Common orders and replace reservations with deal-price costs. |

A definitive failed buy, including an FOK kill with no fill, is logged and its siblings continue. A rejected sell, an uncertain result or a Common sell killed with no fill stops before the next phase. The first uncertain leg stops later placements, but already placed siblings are still polled and logged. A capped ordinary buy sends its funded quantity and leaves its remainder and later legs unsubmitted. A confirmed fill that takes cash below zero stops with `confirmed fill exceeded cash budget by VALUE`. Every POST still requires the same Taipei date and `13:20:00 <= now < 13:24:30`; Common status polling stops at 13:25. Nothing is retried after a POST.
```

Extend Modules/Verified facts with the two endpoint contracts:

```text
| Read | Endpoint | Parsed fields |
|---|---|---|
| Contract info | GET /api/v1/data/contracts/CODE/info | reference, limit_up, limit_down, day_trade, unit, margin_loan_ratio, trading_suspended |
| Trading limits | POST /api/v1/portfolio/trading_limits with {"account_type":"S"} | trading_limit, trading_used, trading_available, margin_limit, margin_used, margin_available |

Trading limits are available on trading days from 08:30 to 15:00 Taipei. The decision reads them once at 13:20, before the first order; a failed budget check stands for that session. Existing orders today on any strategy code skip the whole session. Reconciliation logs trades for every code after close.
```

- [ ] **Step 2: Document the actual hold calculation and exact errors on both TW CLI failure surfaces.** Add the following content to TW `bt target` and link it from TW `bt live`; both use `Live.decide`, so `--live` target also checks the production budget without placing orders. Paper/simulation does not make these reads. Keep the account/symbol output table from stage 1 and the one-stock `--provisional-close` restriction.

```text
| Buy leg | Production budget hold |
|---|---|
| Common, Cash | limit_up x lots x contract unit, summed against trading_available. |
| Common, MarginTrading | limit_up x lots x contract unit, summed against margin_available, not discounted by the financing ratio. |
| IntradayOdd, Cash | Snapshot ask, the actual LMT price, x shares, summed against trading_available. An unusable quote is skipped by the executor. |
| Rollover or refinance rebuy | Included once in the appropriate Cash or MarginTrading sum. |

For an absent, null or non-positive limit_up, use reference x 1.10 and log the fallback. The check never offsets a buy hold with a sell, never relies on an FOK kill releasing a hold, and never retries within that session. It assumes a market buy is held at limit-up and sells add nothing to trading_available; the production acceptance measures those assumptions. Trading usage resets daily. A resting cancel releases its hold, and a placement rejection takes none, as measured on 0050. Margin allowance was zero in the recorded probe, so any margin buy fails while margin_available remains zero.

| Message | Effect |
|---|---|
| TW symbol CODE is suspended | Any trading_suspended contract fails the whole decision; no other symbol trades. |
| TW buy budget short: planned X, available Y | Cash buy holds exceed trading_available; no order is submitted. |
| TW margin budget short: planned X, available Y | Margin buy holds exceed margin_available; no order is submitted. |

A failed production pre-check exits bt target without an order and makes the TW daemon log `date=DATE error=MESSAGE order=skip` and skip the day. No check is retried within the session.
```

Remove the `TW live trading needs one stock in this release` row from shared validation and replace TW prerequisites and the `bt live` STRAT description with:

```text
| STRAT | required | Read one daily strategy with N distinct US or TW symbols, all in one market. The account may hold only those strategy symbols. |

TW bt target and bt live both support every distinct code declared by the strategy. The single-price --provisional-close override still requires one stock.
```

- [ ] **Step 3: Replace TW CLI phase/order/log/failure descriptions with current stage 2 behavior.** Remove claims that every successor waits before its POST or a failed sell can allow independent buys. Keep odd quote skips and cash-only/quantity/round-trip rules; the opposite-direction history check remains per code. Update the odd placement-rejection table so a rejected odd buy continues, while a rejected odd sell prevents the next phase. The pending, accepted ROD sell remains exempt from confirmation.

```text
| Common order | Request | Confirmation |
|---|---|---|
| Lot leg | MKT + FOK, price 0, quantity in lots. | Complete fill or no-fill kill; retain a partial-fill safety guard. Ordinary phase orders poll together for up to five rounds, one second apart, one read per code per round. |
| Pair leg | MKT + FOK, price 0, quantity in lots. | Sequential sell then full original-lot rebuy; each sell must be fully confirmed and the rebuy fully funded. |

Each decision logs one account line and one declaration-ordered symbol line per code. Production also logs one contract line per code, then one budget line before any placement:

date=DATE code=CODE reference=VALUE limit-up=VALUE limit-down=VALUE day-trade=VALUE unit=VALUE margin-loan-ratio=VALUE trading-suspended=BOOL
date=DATE buy-hold=VALUE trading-available=VALUE margin-hold=VALUE margin-available=VALUE
date=DATE fetched-through=DATE equity=VALUE cash=VALUE debit=VALUE submitted=OUTCOME
date=DATE symbol=CODE provisional-close=VALUE target=VALUE cash-shares=VALUE margin-shares=VALUE loan=VALUE planned-legs=LEGS

For a band-less symbol, the contract line prints limit-up=- and a separate line prints `code=CODE budget-price-fallback=reference*1.10 price=VALUE`. Contract and budget audit lines in bt target go to stderr; its account and symbol decision stdout is unchanged. Simulation emits neither contract nor budget lines. Every daemon line keeps its UTC prefix. OUTCOME keeps complete, skip:no-order-legs, skip:existing-orders, or stop:REASON remaining:LEGS. Existing-order skips log placeholders for every strategy code. Trade lines retain code=CODE and custom_field remains btMMDD.

A rejected, uncertain or FOK-killed Common sell with no fill prevents the refinance and buy phases. The first uncertain result stops remaining placements but already placed siblings are still reconciled. Failed buys are logged and sibling buys continue. Odd ROD sells remain unpolled and may be pending when buys start; their proceeds are never spent that session.
```

Remove `partial or cancelled IOC quantities` from the current warning, replacing it with `FOK kills, the retained partial-fill guard`. Do not delete the fidelity warning itself.

- [ ] **Step 4: Update TW engine fidelity and supersede historical odd-lot execution rules without changing engine contracts.** Replace the stage 1 one-code paragraph with the current N-symbol account description; replace the two current IOC references with FOK; replace the sequential ordinary-order statement with phases. Retain differences in commission, odd-book pricing, minimum fees, settlements and broker margin eligibility.

```text
The TW daemon and bt target use the strategy's entire symbol set. Simulation infers cash as equity minus summed cash and margin inventory values plus summed loans and interest; production values equity from those sums and verified spendable cash. A nonzero holding outside the set fails the decision. One compiler call, joint target normalization, per-code financing ratios and costs, and one fill planner call produce the N-code session. Rollover pairs precede ordinary sells, refinance pairs and ordinary buys.

Common legs use MKT + FOK, while IntradayOdd legs remain LMT + ROD. All placed ordinary Common sells must be fully confirmed before refinances or buys; rejected, uncertain or FOK-killed no-fill sells stop that transition even for a one-stock strategy. Pending odd sells are exempt and provide no same-session cash. Buys reserve quote costs, then replace Common reservations with confirmed deal-price costs. Failed buys do not suppress their siblings. Rollover and refinance pairs remain sequential and fully dependent.

Production additionally checks every contract's suspension flag and the summed cash/margin buy holds before any order. Common buys use limit-up x lots x unit, or reference x 1.10 without a usable band; odd buys use their LMT ask. This conservative broker-budget check is separate from the executor's cash/commission affordability check. It assumes sells add nothing and market buys are held at limit-up; production acceptance must measure the remaining hold/add-back/kill-release questions before v0.13.0. Simulation skips the pre-check because its limits are zero.
```

Add the following note to `share-quantum-and-odd-lots.md`, leaving its original historical quantities and quantum decisions intact:

```text
> [!NOTE]
> 2026-10-05: [Multi-stock live stage 2](./multi-stock-live.md#tw-execution) supersedes this design's IOC and independent-sell continuation rules: Common legs use MKT + FOK, ordinary sells and buys batch by phase, and rejected, uncertain or FOK-killed no-fill Common sells stop before refinances and buys. Pending IntradayOdd ROD sells remain unpolled and add no same-session cash; failed buys still permit siblings. Code and exchange are now part of every live leg. The share quantum, odd-lot request restrictions, commission accounting and production lot-plus-odd acceptance remain unchanged.
```

Change the multi-stock design's status to `implemented; stage 2 production acceptance pending` only after the coordinator confirms offline implementation. Retain its reviewed budget section and all three explicitly unmeasured questions; do not write unobserved production conclusions.

- [ ] **Step 5: Add four separate stage 2 CHANGELOG entries under `[Unreleased]`.** These distinguish N-code startup, phase batching/stop semantics, FOK and pre-check. Preserve already-merged US positions-list and output changes. If the existing Unreleased multi-stock entry still claims TW remains one-code, replace that current claim with the new Added entry below; do not rewrite historical version sections. The coordinator handles version cuts after acceptance.

```text
### Added

- Multi-stock TW live execution in one market and one account, with per-code snapshots, inventory, exchange, financing ratio and costs; every declared TW code now executes instead of the stage 1 one-code startup guard.
- TW production decisions pre-check all buy holds against trading_available and margin_available, including rollover and refinance rebuys, and fail the whole session on a suspended contract. The daemon logs seven contract fields per code and both planned and available budgets; band-less codes use logged reference x 1.10 pricing. Simulation skips these reads.

### Changed

- TW execution batches ordinary sells and buys by phase, with rollover and refinance pairs still sequential. A sell rejected, uncertain or Common FOK-killed with no fill stops before refinances and buys, including at N = 1. Pending IntradayOdd ROD sells are exempt from the Common confirmation gate and provide no same-session proceeds. Failed buys are logged and their siblings continue.
- TW Common lot legs use MKT + FOK instead of MKT + IOC; IntradayOdd legs remain LMT + ROD.
```

- [ ] **Step 6: Check documentation links, full-depth Contents and stage boundaries, then run GREEN gates and six comparisons.** This doc-editor step uses Python for subprocesses and read-only text checks. Remaining IOC mentions must be explicitly historical or comparisons to the replaced order form, never current execution guidance. Remaining one-stock claims must describe only the single-price override or historical releases, not TW startup.

```python
from pathlib import Path
root = Path("/sandbox/stock-multi-stock-2")
paths = ["docs/specs/tw-live-trading.md", "docs/cli.md", "docs/engine.md",
         "docs/specs/share-quantum-and-odd-lots.md", "docs/specs/multi-stock-live.md", "CHANGELOG.md"]
for relative in paths:
    path = root / relative
    for number, line in enumerate(path.read_text().splitlines(), 1):
        if any(term in line for term in ["IOC", "one-code", "one stock in this release", "budget", "suspended", "FOK"]):
            print(f"{path}:{number}:{line}")
```

```python
import subprocess
subprocess.run(["opam", "exec", "--switch=/sandbox/stock", "--", "dune", "build", "--root", "."], cwd="/sandbox/stock-multi-stock-2", check=True)
subprocess.run(["opam", "exec", "--switch=/sandbox/stock", "--", "dune", "runtest", "--root", ".", "--force"], cwd="/sandbox/stock-multi-stock-2", check=True)
```

- [ ] **Step 7: Commit only after coordinator review.** Commit only after the coordinator confirms; use the co-author trailer the coordinator names; never push; never change git settings.

```python
import os, subprocess
root = "/sandbox/stock-multi-stock-2"
paths = [root + "/" + path for path in ["docs/specs/tw-live-trading.md", "docs/cli.md", "docs/engine.md", "docs/specs/share-quantum-and-odd-lots.md", "docs/specs/multi-stock-live.md", "CHANGELOG.md"]]
subprocess.run(["git", "-C", root, "add", *paths], cwd=root, check=True)
subprocess.run(["git", "-C", root, "commit", "-m", "docs: describe stage two TW execution and production budgets", "-m", os.environ["COAUTHOR_TRAILER"]], cwd=root, check=True)
```

## Coordinator acceptance after the branch

This is not an offline implementer task. Only the coordinator performs broker-facing acceptance after every task, review and offline gate has passed. Do not tag v0.13.0 before the TW session, lot-plus-odd gate, and all three measurements are recorded. No implementation task runs these commands.

| Acceptance | Coordinator action and evidence |
|---|---|
| Account and limits | Confirm the account holds only the two strategy codes and confirm margin_limit. While margin_limit is zero, use cash-only targets whose sum is at most 1. Read contract info and limits within their trading-day 08:30-15:00 Taipei window. |
| Two-code session | Use 0050 and 00685L, aliases, rebalance daily, and account-derived cash targets that actually plan a Common lot plus an IntradayOdd remainder for each code. Inspect bt target before submitting. Adjust the targets from the real equity, holdings, quote and both allowances so the planned holds pass and both lot/odd quantities are present; do not substitute an odd-only session. |
| Contract/budget logs | One seven-field contract line per code and one two-budget line, both planned sums at or below the corresponding available figures. |
| Ordinary sell barrier | Every ordinary Common sell is placed and fully confirmed before the first ordinary buy. Pending IntradayOdd ROD sells are exempt and may remain pending; rollover and refinance pairs are exempt from the ordinary batch rule but each sell precedes its own full rebuy. |
| Order forms | Each Common trade is Filled in full or killed with no fill; odd legs are LMT + ROD. This session closes share-quantum-and-odd-lots' production cash leg with both lot and odd orders. |
| Sell add-back measurement | Place/fill a sell while trading_used is above zero. Read trading_limits before placement, after placement and after fill. Only a rise in trading_available after fill supports add-back; the previous zero-used probe could not distinguish it. |
| FOK kill measurement | One accepted Common FOK lot order the broker kills with no fill. Read trading_limits before and after. Return of trading_used to its earlier value supports release. A placement rejection is not this measurement. |
| MKT hold measurement | One MKT Common buy of one 00685L lot that fills. Read limits before placement, immediately after acceptance and after fill; record the usage/available deltas, reference, limit_up, unit, quantity and deal price. The measured hold sets the pricing basis; it never changes FOK. |
| Uncertain probe | Any timeout, nonzero exit or lost response after placement is unknown order state: reconcile trades and positions before another placement; never repeat that POST. |
| Release record | Write all readings into multi-stock-live.md's Measured and unmeasured and Budget rule before v0.13.0. Record what was measured versus inferred; revise a pricing basis only from the MKT hold evidence and rerun affected offline budget assertions. |

Example strategy shape; actual targets are fixed by the coordinator's pre-session account sizing, not by this planning assignment:

```text
stock "tw/0050" as a
stock "tw/00685L" as b
rebalance daily
a.target 0.4
b.target 0.6
```

Broker-facing commands, coordinator only, after the strategy and account checks above:

```python
import subprocess
root = "/sandbox/stock-multi-stock-2"
binary = root + "/_build/default/bin/bt.exe"
strategy = "/sandbox/research/strategies/tw/live_pair_probe/main.strat"
subprocess.run([binary, "target", strategy, "--live", "--data-dir", "/sandbox/stock/data"], cwd=root, check=True)
subprocess.run([binary, "live", strategy, "--live", "--data-dir", "/sandbox/stock/data"], cwd=root, check=True)
```

The production server owns its CA and mode credentials. The coordinator chooses an approved executable path under the repo's egress rules before running broker commands; do not assume an implementation build is network-authorized. Keep the real pre/post limits responses and trade identities with the acceptance record. Spec measurements remain pending until actually observed.

## Self-Review

| Review | Result |
|---|---|
| Stage 2 coverage | Tasks 1-4 cover all TW requirements in Stages. Task 5 closes the US restart integration follow-up without changing US behavior. Task 6 covers stage 2 documentation and four CHANGELOG entries. Coordinator acceptance lists all production gates and three measurements. No stage 2 requirement is unmapped. |
| Main compatibility | Stage 1 N-asset records, code-tagged legs, position-set totals and batched code-matched snapshot client are reused. The two-code decision and snapshot tests are retained, not recreated. The one-code startup guard is removed only in Task 4 after the executor/callers migrate. |
| N=1 accepted changes | Task 1 names FOK; Task 2 names budget/suspension checks; Task 3 names phase batching and the rejected/uncertain/no-fill sell stop before refinances and buys. One-stock planner pins retain their exact values. The obsolete startup-guard assertion is removed with its obsolete behavior, not re-pinned. |
| Budget accounting | Cash and margin buy holds are separate, gross, include all rebuys once, use limit-up x lots x unit or the logged reference x 1.10 fallback, and price odd buys at ask. No proceeds offset or kill-release assumption funds a session. Zero simulation limits are parsed but Paper never reads/checks them. Both exact shortage messages and suspension are exercised. |
| Execution safety | Every leg is checked against the declared code/exchange set before POST. Pair dependency includes code (TW5-XDEP). Inventories, liabilities, quote, costs, ratio and orders_today are per code; cash is account-wide. Common sells gate refinances/buys; accepted odd sells are exempt and never credit proceeds. Placements stop on uncertainty while known siblings still reconcile. Caps, per-placement 13:24:30, per-round 13:25, five-round polling, partial fill and cash-overrun guards remain. |
| Test mapping | Rows 5, 10, TW parsers in 12 and 14 get concrete assert code; rows 7 and 15 are already covered and remain registered; row 9 gains a real us_step-to-executor open-sell restart. New tests assert consumer-visible money, identity, placement ordering and stops, not source text or forwarding echoes. |
| Documentation | Current TW order/phase/failure descriptions change, historical entries remain historical, and a dated odd-lot design note makes its superseded execution rules explicit. No duplicate US output/positions-list implementation. All headings appear in Contents. |
| Placeholder and type scan | Every implementation step contains concrete code or exact executable commands. Records/signatures are defined before later tasks consume them; all metadata and snapshot arrays use declaration order. No absent named helper or unfinished marker is allowed. |
| Snippet proof | In-memory projections of the new Shioaji records/parsers/clients, production decision labels/checker, complete per-code executor, N-code preparation/daemon, and concrete test definitions typechecked against the existing built libraries. Twenty-nine selected parser/budget/execution/restart and affected existing TW pin scenarios plus N-contract preparation exited 0, printing PLAN_FINAL_SCOPED_CHECKS_OK and TW_N_CODE_SMOKE_OK. No implementation source file or fixture was created; authored new JSON bytes were supplied in memory. This proves plan-example compatibility, not the future full build or broker acceptance. |
| Verification scope | This planning assignment does not run a project build, full suite, formatter, network request, broker CLI, staging or commit. Scoped in-memory snippet verification is separate from implementation gates. Implementers run the exact build/full-suite/six-byte gates and injected smoke scenarios; only coordinator acceptance exercises the real daemon scheduler/broker surface. |

| Spec Tests table rows | Stage 2 mapping |
|---|---|
| 5 | Task 2 cash/margin messages, equality, fallback, rebuys, suspension, production integration and simulation bypass |
| 7 | Existing test_shioaji_snapshot_codes; Task 4 private N-contract preparation smoke |
| 9 | Task 5 existing open sell through real us_step and real execute_decision |
| 10 | Task 1 existing order_body test changed to FOK, odd ROD boundaries retained |
| 12, TW contract/limits parsers | Task 1 documented fixtures, parser checks and no-band/zero-limit cases |
| 14 | Task 3 two-code sell/fill/reject/kill/uncertain, sibling-buy failure, cap, quote reservation and final cash; per-code rounds and existing safety cases |
| 15 | Existing test_tw_live_pair_decide retained and exercised in Task 4; Task 2 adds production pre-check integration |
| Single-stock pins and six byte gates | Global Constraints; every GREEN gate |
| Stage 2 production acceptance | Coordinator acceptance after the branch, including all three open measurements |
