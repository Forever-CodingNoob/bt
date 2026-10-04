# Multi-Stock Live Stage 1 Implementation Plan

> **For the coordinator:** REQUIRED SUB-SKILL: superpowers:executing-plans; implement this plan task-by-task and track its `- [ ]` steps. The coordinator owns every review and assigns Task 7 to the doc-editor.

Implementers use executing-plans only. No subagents: never dispatch a reviewer or any other agent; the coordinator owns reviews.

**Goal:** Use the backtest's N-asset decision and planner for US live trading and both markets' `bt target`, while preserving the pinned one-stock decisions.

**Architecture:** Move the existing date intersection into Data, compile and normalize all assets together, and build one account decision with declaration-ordered assets and a separate TW session leg list. Split the US account debit proportionally, check its positions list, and execute ordinary sells before buys with symbol-specific restart routing. TW decisions become N-asset, but the TW daemon remains one-stock until stage 2.

**Tech Stack:** OCaml standard library and unix, dune, the existing opam switch, curl/jq broker clients, injected JSON fixtures, and plain asserts in `test/test_bt.ml`.

## Contents

- [Global Constraints](#global-constraints)
- [Scope and file map](#scope-and-file-map)
- [Tasks](#tasks)
  - [Task 1: Pin one-stock decisions before refactoring](#task-1-pin-one-stock-decisions-before-refactoring)
  - [Task 2: Share the existing date intersection](#task-2-share-the-existing-date-intersection)
  - [Task 3: Parse US positions and order sides and match TW snapshots by code](#task-3-parse-us-positions-and-order-sides-and-match-tw-snapshots-by-code)
  - [Task 4: Plan all US assets in one engine call](#task-4-plan-all-us-assets-in-one-engine-call)
  - [Task 5: Tag and phase-order TW decision legs](#task-5-tag-and-phase-order-tw-decision-legs)
  - [Task 6: Cut over decisions, output, US execution, and restart routing](#task-6-cut-over-decisions-output-us-execution-and-restart-routing)
    - [Decision assembly](#decision-assembly)
    - [Output and startup validation](#output-and-startup-validation)
    - [US execution and restart routing](#us-execution-and-restart-routing)
    - [Offline behavioral checks](#offline-behavioral-checks)
    - [Atomic cutover gate](#atomic-cutover-gate)
  - [Task 7: Update stage 1 documentation and changelog](#task-7-update-stage-1-documentation-and-changelog)
- [Coordinator acceptance after the branch](#coordinator-acceptance-after-the-branch)
- [Self-Review](#self-review)

## Global Constraints

- Implement stage 1 of `docs/specs/multi-stock-live.md`, not stage 2. Do not change engine arithmetic, add dependencies, introduce short trading, tolerate foreign holdings, attribute equity to multiple strategies, or add retry-after-POST behavior.
- The coordinator creates `/sandbox/stock-multi-stock` before execution. Every implementation read, edit, and command uses absolute paths there; set every command's working directory to `/sandbox/stock-multi-stock`. Never touch `/sandbox/stock`. The only exceptions are read-only inputs: `/sandbox/stock/data`, `/sandbox/stock/.superpowers/sdd/us-paper-test/`, `/sandbox/research/strategies/`, and the `/sandbox/stock` opam switch. The dune `--root .` resolves in the worktree. This planning assignment writes only `/sandbox/stock/docs/plans/multi-stock-live-stage-1.md`, and stages and commits nothing.
- Never make network calls during implementation or verification. Never run `bt live` or `bt target` against a broker. CLI error probes below exit before broker dispatch; injected `Live.decide` tests supply the previous TW session, positions, details, and snapshots. Real paper acceptance belongs to the coordinator after the branch, not to implementation tasks.
- Follow CONTRIBUTING Style rules: standard library and unix only; ASCII; one space around `=`; no alignment spaces; no new `for` or `while` loops; side effects sequenced with `let () = e in`; tail-recursive list traversal; arrays for series math; warnings as errors; preserve floating-point operation order. Market dispatch uses `match` with `| "us"`, `| "tw"`, and a default/error arm, never a market-string `if`.
- Follow CONTRIBUTING Documentation style: full-depth Contents, tables for enumerable material, one H1, ASCII, and no mid-sentence hard wrapping. Put assert-based tests in `/sandbox/stock-multi-stock/test/test_bt.ml` and register every new test in its final `let ()` list. Preserve independent derivation comments and exact byte pins. No new testing framework.
- Read the relevant absolute-path file sections again before editing, and use the language server's references for exported symbol/type changes. The current language server returns local-module references; inspect the known external consumers in `bin/bt.ml` and `test/test_bt.ml` as well. No compatibility aliases or permanent scalar wrappers: migrate every caller.
- At each GREEN gate run the following two commands from the worktree, then the six byte comparisons below. Every command exits 0. Task 6 is one atomic public-record/execution cutover: its intermediate RED steps are not commit points.

```sh
opam exec --switch=/sandbox/stock -- dune build --root .
opam exec --switch=/sandbox/stock -- dune runtest --root . --force
```

The reference gates are copied from `docs/plans/us-live-planner.md:35-46`, with only the executable worktree path changed. Do not edit their strategies, capital, cache, or baselines.

```sh
us_out=$(mktemp -d)
tw_out=$(mktemp -d)
/sandbox/stock-multi-stock/_build/default/bin/bt.exe run /sandbox/research/strategies/us/dd_ladder/main.strat --baseline us/TQQQ --capital 100000 --data-dir /sandbox/stock/data --out-dir "$us_out" --out-name fp --no-plot > "$us_out/stdout.txt"
cmp "$us_out/stdout.txt" /sandbox/stock/.superpowers/sdd/us-paper-test/us-baseline/stdout.txt
cmp "$us_out/fp.csv" /sandbox/stock/.superpowers/sdd/us-paper-test/us-baseline/fp.csv
cmp "$us_out/main.trades.csv" /sandbox/stock/.superpowers/sdd/us-paper-test/us-baseline/main.trades.csv
/sandbox/stock-multi-stock/_build/default/bin/bt.exe run /sandbox/research/strategies/tw/channel_ladder/main.strat --baseline tw/00685L --capital 1000000 --data-dir /sandbox/stock/data --out-dir "$tw_out" --out-name fp --no-plot > "$tw_out/stdout.txt"
cmp "$tw_out/stdout.txt" /sandbox/stock/.superpowers/sdd/us-paper-test/tw-baseline/stdout.txt
cmp "$tw_out/fp.csv" /sandbox/stock/.superpowers/sdd/us-paper-test/tw-baseline/fp.csv
cmp "$tw_out/main.trades.csv" /sandbox/stock/.superpowers/sdd/us-paper-test/tw-baseline/main.trades.csv
```

- At every commit step: Commit only after the coordinator confirms; use the co-author trailer the coordinator names; never push; never change git settings. The shown commit commands are conditional on that confirmation, and the coordinator supplies the trailer at execution time.

## Scope and file map

Stage 1 releases as v0.12.0 only after both US paper acceptances. FOK, `trading_limits`, `contract_info`, TW execution batching, the TW budget pre-check, N-symbol `run_tw`, and TW production acceptance belong to stage 2/v0.13.0. Keep `MKT` + `IOC`, sequential TW execution, and its existing stop rules unchanged here. Do not copy stage 2 error messages into shipped stage 1 docs.

| Files under `/sandbox/stock-multi-stock/` | Responsibility | Tasks |
|---|---|---|
| `test/test_bt.ml` | One-stock pins, parsers, planner parity, injected decisions, execution and CLI guards | 1-6 |
| `market/data.ml`, `market/data.mli`, `bin/bt.ml` | One shared `common_dates`, unchanged backtest filtering | 2 |
| `broker/alpaca.ml`, `broker/alpaca.mli`, `test/fixtures/alpaca/positions.json` | Position-symbol list and order side | 3 |
| `broker/shioaji.ml`, `broker/shioaji.mli` | N-contract snapshot request, code-matched response | 3 |
| `broker/live.ml`, `broker/live.mli` | N-asset account planning, decisions, legs, phases and routing | 4-6 |
| `bin/bt.ml` | Market/symbol/override guards and account-then-symbol output | 6 |
| `docs/specs/live-trading.md`, `docs/specs/tw-live-trading.md`, `docs/cli.md`, `docs/engine.md`, `CHANGELOG.md` | Stage 1 shipped semantics, with TW execution boundary explicit | 7 |

## Tasks

### Task 1: Pin one-stock decisions before refactoring

**Files:**

| Operation | Absolute path and section |
|---|---|
| Modify/test | `/sandbox/stock-multi-stock/test/test_bt.ml`: existing US tests at 4799-5065, TW injected cache/decision pattern at 7027-7412, final registration at 8028-8259 |
| Read | `/sandbox/stock-multi-stock/broker/live.ml`: `decide`, `us_plan_action`, `legs_of_plan` |

**Interfaces:**

| Direction | Contract |
|---|---|
| Consumes | Current scalar `Live.us_plan_action`, `Live.decide ?provisional_close ?previous_session ?equity ?tw_positions ?tw_position_details ?tw_snapshot`, `with_temp_market`, `with_temp_strategy`, `bar`, `assert_close` |
| Produces | `with_tw_decision_cache : (string -> unit) -> unit`, `test_multi_stock_one_stock_pins : unit -> unit`; existing US exact order/fraction/limit assertions remain the US pins |

- [ ] **Step 1: Add the reusable injected TW cache beside `test_tw_live_decide_override`.** This is the existing fixture pattern, not a new broker abstraction. It allows the second code to be present in the cache without declaring it in a one-stock pin.

```ocaml
let with_tw_decision_cache function_ =
  with_temp_market "tw" (fun data_dir tw_dir ->
    let write path contents =
      let output = open_out path in
      Fun.protect ~finally:(fun () -> close_out output)
        (fun () -> output_string output contents)
    in
    let () =
      write (Filename.concat tw_dir "stockinfo.csv")
        "stock_id,type,date\n2330,twse,2026-01-01\n2890,tpex,2026-01-01\n"
    in
    let () =
      List.iter (fun code ->
        let directory = Filename.concat tw_dir code in
        let () = Unix.mkdir directory 0o700 in
        let path suffix = Filename.concat directory (code ^ suffix) in
        let () = write (path ".csv")
          "date,open,high,low,close,volume\n\
           2026-05-14,1870,1880,1860,1870,900\n\
           2026-05-15,1880,1890,1870,1880,900\n\
           2026-05-21,1950,1960,1940,1950,1100\n\
           2026-05-22,1980,1990,1970,1980,1200\n" in
        let () = write (path ".div.csv") "date,factor\n" in
        let () = write (path ".events.csv") "date,factor\n" in
        write (path ".cashdiv.csv") "ex_date,cash_per_share,pay_date\n")
        ["2330"; "2890"]
    in
    function_ data_dir)

let test_multi_stock_one_stock_pins () =
  with_tw_decision_cache (fun data_dir ->
    let position : Shioaji.position =
      { id = 0; code = "2330"; cond = "Cash"; shares = 10000;
        last_price = 200.; loan_amount = 0.; interest = 0. }
    in
    let choose policy target details =
      with_temp_strategy
        (Printf.sprintf "stock \"tw/2330\"\nrebalance %s\ntarget %.10g\n"
          policy target)
        (fun strat_path ->
          Live.decide ~provisional_close:200.
            ~previous_session:"2026-05-22" ~equity:3000000.
            ~tw_positions:[position] ~tw_position_details:details
            Live.Paper ~session_date:"2026-05-26" ~strat_path ~data_dir)
    in
    let constant = choose "on_change" 0.5 [] in
    (* Both rows target 0.5; the 10000-share drift stays, with no legs. *)
    let () = assert (constant.target = 0.5 && constant.held = 10000.) in
    let () = assert (constant.action = Live.Orders []) in
    let drift = choose "daily" 0.8 [] in
    (* E1 = 3000000 - 200*q*0.001425; floor(0.8*E1/200)-10000
       is 1997: one Common lot and 997 odd shares, in that order. *)
    let () = assert (drift.target = 0.8 && drift.held = 10000.) in
    let () = assert (drift.action = Live.Orders
      [{ Live.action = "Buy"; cond = "Cash"; lot = Shioaji.Common; quantity = 1 };
       { Live.action = "Buy"; cond = "Cash"; lot = Shioaji.IntradayOdd; quantity = 997 }]) in
    let levered = choose "on_change" 1.5 [] in
    (* 1.5*(1-0.6) = 0.6 < 1, so normalization leaves 1.5 unchanged;
       equal previous target preserves the same drift and emits no legs. *)
    let () = assert (levered.target = 1.5 && levered.held = 10000.) in
    let () = assert (levered.action = Live.Orders []) in
    let matured =
      with_temp_strategy "stock \"tw/2330\"\nrebalance on_change\ntarget 1.5\n"
        (fun strat_path ->
          Live.decide ~provisional_close:200.
            ~previous_session:"2026-05-22" ~equity:3000000.
            ~tw_positions:[{ position with cond = "MarginTrading";
              shares = 3000; loan_amount = 360000. }]
            ~tw_position_details:
              [{ Shioaji.code = "2330"; cond = "MarginTrading";
                 date = "2024-11-26"; lots = 2 };
               { Shioaji.code = "2330"; cond = "MarginTrading";
                 date = "2024-05-31"; lots = 1 }]
            Live.Paper ~session_date:"2026-05-26" ~strat_path ~data_dir)
    in
    (* 18 months gives 2026-05-26 and clamped 2025-11-30; both mature.
       Ordinary target is unchanged, so these four legs are the entire list. *)
    let () = assert (matured.target = 1.5 && matured.held = 3000.) in
    assert (matured.action = Live.Orders
      [{ Live.action = "Sell"; cond = "MarginTrading"; lot = Shioaji.Common; quantity = 2 };
       { Live.action = "Buy"; cond = "MarginTrading"; lot = Shioaji.Common; quantity = 2 };
       { Live.action = "Sell"; cond = "MarginTrading"; lot = Shioaji.Common; quantity = 1 };
       { Live.action = "Buy"; cond = "MarginTrading"; lot = Shioaji.Common; quantity = 1 }]))
```

- [ ] **Step 2: Register the TW pins and retain the US pin registrations.** Do not derive expected US quantities from the planner under test; existing assertions already pin full closes, truncation, minimum value, quantity limit, and on_change policy.

```ocaml
  test_us_plan_action_orders ();
  test_us_plan_action_matches_run ();
  test_us_live_fractional ();
  test_us_live_plan_policy ();
  test_us_live_quantity_limit ();
```

```ocaml
  let () = test_multi_stock_one_stock_pins () in
  let () = test_tw_live_decide_override () in
```

- [ ] **Step 3: Run the baseline pin suite and GREEN gates before any production refactor.** New pins describe current behavior, so there is no deliberately failing refactor test in this task. Observe their actual values now; do not change them later to match a changed implementation.

```sh
opam exec --switch=/sandbox/stock -- dune build --root .
opam exec --switch=/sandbox/stock -- dune runtest --root . --force
```

Run all six Global Constraints comparisons. Expected: every assert and byte comparison passes on the current implementation.

- [ ] **Step 4: Commit only after coordinator review.**

```sh
git -C /sandbox/stock-multi-stock add /sandbox/stock-multi-stock/test/test_bt.ml
git -C /sandbox/stock-multi-stock commit -m "test: pin one-stock live decisions before multi-stock cutover"
```

Commit only after the coordinator confirms; use the co-author trailer the coordinator names; never push; never change git settings.

### Task 2: Share the existing date intersection

**Files:**

| Operation | Absolute path and section |
|---|---|
| Modify | `/sandbox/stock-multi-stock/market/data.ml`: beside `filter_dates` at 1560 |
| Modify | `/sandbox/stock-multi-stock/market/data.mli`: beside `filter_dates` at 68 |
| Modify | `/sandbox/stock-multi-stock/bin/bt.ml`: remove 160-178; callers at 383 and 638 |
| Test | `/sandbox/stock-multi-stock/test/test_bt.ml`: beside `test_filter_dates`, main registration |

**Interfaces:**

| Direction | Contract |
|---|---|
| Consumes | `Data.bar array list`, existing `Data.filter_dates : keep:(string -> bool) -> Data.bar array -> Data.bar array` |
| Produces | `Data.common_dates : Data.bar array list -> string list`, sorted/deduplicated intersection, exactly the old body |

- [ ] **Step 1 (RED): Add and register the intersection behavior test.**

```ocaml
let test_common_dates () =
  let bars dates = Array.of_list (List.map (fun date -> bar date 100. 100.) dates) in
  let left = bars ["2026-05-22"; "2026-05-14"; "2026-05-15"; "2026-05-15"] in
  let right = bars ["2026-05-15"; "2026-05-21"; "2026-05-22"] in
  (* Intersection retains 15 and 22 once each, sorted, irrespective of order. *)
  assert (Data.common_dates [left; right] = ["2026-05-15"; "2026-05-22"]);
  assert (Data.common_dates [left] = ["2026-05-14"; "2026-05-15"; "2026-05-22"]);
  assert (Data.common_dates [] = []);
  assert (Data.common_dates [left; [||]] = [])
```

```ocaml
  test_filter_dates ();
  test_common_dates ();
```

```sh
opam exec --switch=/sandbox/stock -- dune runtest --root . --force
```

Expected: missing `Data.common_dates` export.

- [ ] **Step 2 (GREEN): Move the body unchanged into Data.** Within Data use the local `bar` type in annotations; removing the `Data.` qualifier is the only body change. Export the signature, delete the CLI-local definition, and change both known CLI callers.

```ocaml
let common_dates = function
  | [] -> []
  | first :: rest ->
      let initial =
        Array.to_list (Array.map (fun (bar : bar) -> bar.date) first)
        |> List.sort_uniq String.compare
      in
      List.fold_left
        (fun common bars ->
          let present = Hashtbl.create (Array.length bars) in
          Array.iter (fun (bar : bar) -> Hashtbl.replace present bar.date ()) bars;
          List.filter (fun date -> Hashtbl.mem present date) common)
        initial rest
```

```ocaml
(** Sorted common trading dates, with duplicates removed. *)
val common_dates : bar array list -> string list
```

```ocaml
(* Both bt run and bt daytrade. *)
  let dates = Data.common_dates arrays in
```

- [ ] **Step 3: Run GREEN gates and the six byte comparisons.** These directly exercise the moved helper through actual `bt run`, not just the unit test.

```sh
opam exec --switch=/sandbox/stock -- dune build --root .
opam exec --switch=/sandbox/stock -- dune runtest --root . --force
```

- [ ] **Step 4: Commit only after coordinator review.**

```sh
git -C /sandbox/stock-multi-stock add /sandbox/stock-multi-stock/market/data.ml /sandbox/stock-multi-stock/market/data.mli /sandbox/stock-multi-stock/bin/bt.ml /sandbox/stock-multi-stock/test/test_bt.ml
git -C /sandbox/stock-multi-stock commit -m "refactor: share backtest date intersection in Data"
```

Commit only after the coordinator confirms; use the co-author trailer the coordinator names; never push; never change git settings.

### Task 3: Parse US positions and order sides and match TW snapshots by code

**Files:**

| Operation | Absolute path and section |
|---|---|
| Modify | `/sandbox/stock-multi-stock/broker/alpaca.ml`: `order_t`, `parse_order`, `position_qty` |
| Modify | `/sandbox/stock-multi-stock/broker/alpaca.mli`: `order_t` and parser/REST exports |
| Create fixture | `/sandbox/stock-multi-stock/test/fixtures/alpaca/positions.json` |
| Modify | `/sandbox/stock-multi-stock/broker/shioaji.ml`: `parse_snapshot` at 196-212, `snapshot` at 390-397 |
| Modify | `/sandbox/stock-multi-stock/broker/shioaji.mli`: snapshot exports |
| Modify | `/sandbox/stock-multi-stock/broker/live.ml`: TW snapshot callers in `decide`, `prepare_tw`, `run_tw` |
| Test | `/sandbox/stock-multi-stock/test/test_bt.ml`: Alpaca order fixtures/literals, Shioaji snapshot tests and parser rejection tests |

**Interfaces:**

| Direction | Contract |
|---|---|
| Produces | `Alpaca.parse_positions : string -> string list`; `Alpaca.positions : Alpaca.mode -> string list`; `Alpaca.order_t.side : string` |
| Produces | `Shioaji.parse_snapshot : codes:string array -> string -> Shioaji.snapshot array`; `Shioaji.snapshot : contracts:(string * string) array -> Shioaji.snapshot array` |
| Ordering | Snapshot array is request order, not response order. Snapshot record fields remain unchanged; code is a response matching key, not another record field. |
| Migration | Existing one-stock snapshot callers pass `[|exchange, symbol|]` and take `.(0)` until the N-decision cutover in Task 6. No scalar snapshot alias remains. |

- [ ] **Step 1 (RED): Add a documented-response-shaped Alpaca fixture and parser assertions.** The fixture projects only documented position fields; it is synthetic, not a claim of an account probe. Add `side = "buy"` to the expected `order.json` record and `side = "sell"` to the inline filled order and its expected record. Every constructed Alpaca order in US execution/routing tests gains its actual injected side, normally `"buy"`.

```json
[{"symbol":"TQQQ","qty":"5","side":"long"},{"symbol":"QQQ","qty":"2","side":"long"}]
```

```ocaml
let test_alpaca_positions_parse () =
  (* The two response rows name TQQQ and QQQ; quantities remain per-symbol reads. *)
  assert (Alpaca.parse_positions (alpaca_fixture "positions.json") = ["TQQQ"; "QQQ"]);
  assert (Alpaca.parse_positions "[]" = []);
  assert_failure (fun () -> ignore (Alpaca.parse_positions "{}"));
  assert_failure (fun () -> ignore (Alpaca.parse_positions "[{\"qty\":\"1\"}]"))
```

```ocaml
(* test_alpaca_order_parse: inline filled response and corresponding record. *)
  let filled = Alpaca.parse_order
    {|{"id":"filled-id","status":"filled","side":"sell","filled_avg_price":"172.55","filled_qty":"2"}|} in
  let filled_expected : Alpaca.order_t =
    { id = "filled-id"; status = "filled"; side = "sell";
      filled_avg_price = Some 172.55; filled_qty = 2. }
```

```ocaml
  test_alpaca_position_parse ();
  test_alpaca_positions_parse ();
  test_alpaca_order_parse ();
```

```sh
opam exec --switch=/sandbox/stock -- dune runtest --root . --force
```

Expected: missing positions parser and order side field.

- [ ] **Step 2 (GREEN): Implement the positions projection and order-side parse.** `jq_fields` splits tabs; a valid empty list deliberately emits an empty string, which is mapped to `[]`. Do not shell out once per symbol to obtain the positions list.

```ocaml
(* Add to order_t in both alpaca.ml and alpaca.mli. *)
  side : string;
```

```ocaml
let parse_positions raw =
  match jq_fields "positions"
    "if type == \"array\" and all(.[]; (.symbol | type) == \"string\" and (.symbol | length) > 0) then map(.symbol) | join(\"\\t\") else error(\"expected position symbols\") end" raw with
  | [""] -> []
  | symbols -> symbols

let parse_order raw =
  match jq_fields "order"
    "[.id, .status, (if .side == \"buy\" or .side == \"sell\" then .side else error(\"invalid side\") end), (.filled_avg_price // \"\"), .filled_qty] | @tsv" raw with
  | [id; status; side; filled_avg_price; filled_qty] ->
      { id; status; side;
        filled_avg_price =
          (match filled_avg_price with
           | "" -> None
           | value -> Some (float_field "order filled_avg_price" value));
        filled_qty = float_field "order filled_qty" filled_qty }
  | _ -> failwith "invalid Alpaca order response"
```

```ocaml
(* After account, where request and expect_ok are already defined. *)
let positions mode =
  request mode ~path:"/v2/positions" |> expect_ok "positions" parse_positions
```

```ocaml
val parse_positions : string -> string list
val positions : mode -> string list
```

- [ ] **Step 3 (RED): Add the two-contract code-matching test before changing Shioaji's interface.** Keep the recorded one-stock fixture assertion, changing only its invocation to `~codes:[|"2330"|]` and taking `.(0)`. Replace every other parser invocation and one-stock REST call with the new labelled contract, including malformed-response tests.

```ocaml
let test_shioaji_snapshot_codes () =
  let row code close = Printf.sprintf
    "{\"code\":\"%s\",\"datetime\":\"2026-05-26T13:20:00\",\"open\":10,\"high\":20,\"low\":5,\"close\":%g,\"buy_price\":10,\"sell_price\":11,\"total_volume\":100}" code close in
  let raw = "[" ^ row "2890" 12. ^ "," ^ row "2330" 10. ^ "]" in
  let snapshots = Shioaji.parse_snapshot ~codes:[|"2330"; "2890"|] raw in
  (* Declaration order is 2330 then 2890, although the response reverses it. *)
  assert (Array.map (fun (s : Shioaji.snapshot) -> s.close) snapshots = [|10.; 12.|]);
  List.iter (fun raw ->
    match Shioaji.parse_snapshot ~codes:[|"2330"; "2890"|] raw with
    | _ -> assert false
    | exception Failure message -> assert (message = "invalid Shioaji snapshot response"))
    ["[" ^ row "2330" 10. ^ "]";
     "[" ^ row "2330" 10. ^ "," ^ row "2330" 10. ^ "]";
     "[" ^ row "2330" 10. ^ "," ^ row "9999" 10. ^ "]"]
```

```ocaml
  let () = test_shioaji_snapshot_codes () in
```

```sh
opam exec --switch=/sandbox/stock -- dune runtest --root . --force
```

Expected: current parser has no `codes` argument.

- [ ] **Step 4 (GREEN): Replace the snapshot parser and REST request, and migrate the scalar consumers.** The current jq helpers already support rows and arguments. Require exactly the requested code set, once per code; parse fields with existing nonnegative parsers. Keep all existing OHLCV validation in `tw_provisional_bar`.

```ocaml
let parse_snapshot ~codes raw =
  let rows = jq_rows "snapshot"
    "if type == \"array\" then map([.code, .datetime, (.open | tostring), (.high | tostring), (.low | tostring), (.close | tostring), (.buy_price | tostring), (.sell_price | tostring), (.total_volume | tostring)] | @tsv) | join(\"\\n\") else error(\"expected snapshots\") end" raw in
  let invalid () = failwith "invalid Shioaji snapshot response" in
  let requested = Hashtbl.create (Array.length codes) in
  let () = Array.iter (fun code ->
    if Hashtbl.mem requested code then invalid ();
    Hashtbl.add requested code ()) codes in
  let found = Hashtbl.create (Array.length codes) in
  let () = List.iter (function
    | [code; datetime; open_; high; low; close; bid; ask; total_volume] ->
        let () = if not (Hashtbl.mem requested code) || Hashtbl.mem found code
          then invalid () in
        let snapshot =
          { datetime;
            open_ = nonnegative_float_field "snapshot open" open_;
            high = nonnegative_float_field "snapshot high" high;
            low = nonnegative_float_field "snapshot low" low;
            close = nonnegative_float_field "snapshot close" close;
            bid = nonnegative_float_field "snapshot buy_price" bid;
            ask = nonnegative_float_field "snapshot sell_price" ask;
            total_volume = nonnegative_float_field "snapshot total_volume" total_volume }
        in
        Hashtbl.add found code snapshot
    | _ -> invalid ()) rows in
  Array.map (fun code -> match Hashtbl.find_opt found code with
    | Some snapshot -> snapshot
    | None -> invalid ()) codes

let snapshot ~contracts =
  let contracts_text = Array.to_list contracts
    |> List.map (fun (exchange, code) -> exchange ^ "\t" ^ code)
    |> String.concat "\n" in
  let body = jq_object "snapshot" ["--arg"; "contracts"; contracts_text]
    "{contracts:($contracts | split(\"\\n\") | map(split(\"\\t\") | {security_type:\"STK\",exchange:.[0],code:.[1]}))}" in
  let codes = Array.map snd contracts in
  request ~method_:"POST" ~body ~path:"/api/v1/data/snapshots" ()
  |> expect_ok "snapshot" (parse_snapshot ~codes)
```

```ocaml
val parse_snapshot : codes:string array -> string -> snapshot array
val snapshot : contracts:(string * string) array -> snapshot array
```

```ocaml
(* Existing one-code callers in decide, prepare_tw and run_tw. *)
  let snapshot = (Shioaji.snapshot ~contracts:[| exchange, symbol |]).(0) in
```

- [ ] **Step 5: Run GREEN gates and six byte comparisons.** This task makes no live REST request; parser tests exercise real jq subprocesses and recorded JSON.

```sh
opam exec --switch=/sandbox/stock -- dune build --root .
opam exec --switch=/sandbox/stock -- dune runtest --root . --force
```

- [ ] **Step 6: Commit only after coordinator review.**

```sh
git -C /sandbox/stock-multi-stock add /sandbox/stock-multi-stock/broker/alpaca.ml /sandbox/stock-multi-stock/broker/alpaca.mli /sandbox/stock-multi-stock/broker/shioaji.ml /sandbox/stock-multi-stock/broker/shioaji.mli /sandbox/stock-multi-stock/broker/live.ml /sandbox/stock-multi-stock/test/test_bt.ml /sandbox/stock-multi-stock/test/fixtures/alpaca/positions.json
git -C /sandbox/stock-multi-stock commit -m "feat: parse broker symbol lists and code-matched snapshots"
```

Commit only after the coordinator confirms; use the co-author trailer the coordinator names; never push; never change git settings.

### Task 4: Plan all US assets in one engine call

**Files:**

| Operation | Absolute path and section |
|---|---|
| Modify | `/sandbox/stock-multi-stock/broker/live.ml`: `us_plan_state`, `us_plan_action`, current US `decide` call |
| Modify | `/sandbox/stock-multi-stock/broker/live.mli`: planner signatures |
| Test | `/sandbox/stock-multi-stock/test/test_bt.ml`: 4706-5065 and main list |

**Interfaces:**

| Direction | Contract |
|---|---|
| Produces | `us_plan_state : cash:float -> held:float array -> prices:float array -> ratio:float -> previous_targets:float array -> Engine.plan_state` |
| Produces | `us_plan_action : rebalance:bool -> symbols:string array -> date:string -> account:Alpaca.account_t -> position_symbols:string list -> held:float array -> prices:float array -> targets:float array -> previous_targets:float array -> Engine.plan_state * action array` |
| Preserves | Existing ratio guard, five ordered account checks, no-interest state, target policy, ordinary net-only orders, exact full close, 9-decimal formatter, USD 1 buy minimum |

- [ ] **Step 1 (RED): Add the debit split and bit-for-bit one-stock state pin.** Keep all existing ratio, cash-only, ordinary debit and clamp cases; migrate scalar arguments to singleton arrays rather than weakening assertions.

```ocaml
let test_us_plan_state_split () =
  let state = Live.us_plan_state ~cash:(-30000.) ~held:[|600.; 300.|]
    ~prices:[|100.; 100.|] ~ratio:0.5 ~previous_targets:[|0.8; 0.4|] in
  (* Values 60000+30000 split debit 30000 as 20000+10000;
     margin 40000+20000, cash inventory 20000+10000, equity 60000. *)
  assert (state.Engine.loans = [|20000.; 10000.|]);
  assert (state.margin_values = [|40000.; 20000.|]);
  assert (state.cash_values = [|20000.; 10000.|]);
  assert (state.cash = 0. && state.equity = 60000.);
  let empty = Live.us_plan_state ~cash:(-6.) ~held:[|0.; 0.|]
    ~prices:[|100.; 100.|] ~ratio:0.5 ~previous_targets:[|0.; 0.|] in
  (* Zero total value splits debit equally, 6/2 = 3 per entry. *)
  assert (empty.loans = [|3.; 3.|]);
  List.iter (fun (cash, held) ->
    let value = held *. 100. in
    let debit = Float.max 0. (-. cash) in
    let margin = Float.min value (debit /. 0.5) in
    let free = Float.max cash 0. in
    let expected : Engine.plan_state =
      { equity = free +. value -. debit; cash = free;
        cash_values = [|value -. margin|]; margin_values = [|margin|];
        loans = [|debit|]; interests = [|0.|]; tail_interests = [|0.|];
        debt = 0.; receivables = 0.; previous_targets = [|1.5|] } in
    let actual = Live.us_plan_state ~cash ~held:[|held|] ~prices:[|100.|]
      ~ratio:0.5 ~previous_targets:[|1.5|] in
    (* This is the previous scalar operation order, not a tolerance check. *)
    assert (Marshal.to_bytes expected [] = Marshal.to_bytes actual []))
    [50000., 100.; -20000., 600.; -40000., 600.]
```

- [ ] **Step 2 (RED): Add foreign-position precedence and two-asset parity.** The three flat bars retain E2 before the terminal close. Targets initially occupy one symbol, so the cash-to-margin inventory split after bar 1 matches both the engine state and the account mapping. The last case's new QQQ margin position is funded by refinancing SPY cash inventory across assets; refinance rows are excluded from ordinary quantities but explicitly required in that case.

```ocaml
let test_us_plan_action_foreign_symbol () =
  let account : Alpaca.account_t =
    { equity = 1.; cash = -600.; long_market_value = 999.;
      short_market_value = 0.; status = "ACTIVE";
      trading_blocked = false; account_number = "fixture" } in
  match Live.us_plan_action ~rebalance:false ~symbols:[|"SPY"; "QQQ"|]
    ~date:"2025-06-24" ~account ~position_symbols:["SPY"; "FOREIGN"]
    ~held:[|5.; 0.|] ~prices:[|100.; 100.|]
    ~targets:[|0.5; 0.|] ~previous_targets:[|0.5; 0.|] with
  | _ -> assert false
  (* Foreign membership check wins over mark mismatch and nonpositive equity. *)
  | exception Failure message ->
      assert (message = "US account holds unsupported symbol FOREIGN")

let test_us_plan_action_pair_matches_run () =
  let symbols = [|"SPY"; "QQQ"|] in
  let price = 100. and capital = 1000. in
  let bars = [|bar "2025-06-23" price price;
    bar "2025-06-24" price price; bar "2025-06-25" price price|] in
  let profile = Engine.profile_of_market "us" in
  let costs = Array.map (fun symbol -> Engine.default_costs ~market:"us" ~symbol) symbols in
  let margin : Engine.margin =
    { financing_rate = 0.; maintenance_override = None;
      ratios = [|0.5; 0.5|]; loan_term_months = None } in
  let check refinance t0 t1 =
    let result = Engine.run
      (Array.map (fun symbol -> "us/" ^ symbol, bars) symbols)
      { Engine.targets = Array.mapi (fun i first -> [|first; t1.(i); t1.(i)|]) t0 }
      costs ~profile ~margin ~capital ~fill:Engine.Close_same ~rebalance:false in
    let e1 = List.assoc "2025-06-23" result.equity_curve *. capital in
    let e2 = List.assoc "2025-06-24" result.equity_curve *. capital in
    let ordinary = List.filter (fun (f : Engine.fill_event) ->
      f.date = "2025-06-24" && f.from_e <> f.to_e) result.fills in
    let () = assert (List.exists (fun (f : Engine.fill_event) ->
      f.date = "2025-06-24" && f.from_e = f.to_e) result.fills = refinance) in
    let held = Array.mapi (fun i _ ->
      let label = "us/" ^ symbols.(i) in
      match List.find_opt (fun (f : Engine.fill_event) -> f.stock = label) ordinary with
      | Some f -> f.from_e *. e1 /. price
      | None -> t0.(i) *. e1 /. price) symbols in
    let value = Array.fold_left (fun sum shares -> sum +. shares *. price) 0. held in
    let account : Alpaca.account_t =
      { equity = 1.; cash = e1 -. value; long_market_value = value;
        short_market_value = 0.; status = "ACTIVE";
        trading_blocked = false; account_number = "fixture" } in
    let state, actions = Live.us_plan_action ~rebalance:false ~symbols
      ~date:"2025-06-24" ~account ~position_symbols:["SPY"; "QQQ"]
      ~held ~prices:[|price; price|] ~targets:t1 ~previous_targets:t0 in
    let () = assert_close e1 state.Engine.equity in
    Array.iteri (fun i action ->
      match List.find_opt (fun (f : Engine.fill_event) ->
        f.stock = "us/" ^ symbols.(i)) ordinary with
      | None -> assert (action = Live.Skip "target unchanged")
      | Some fill ->
          (* Exposure times equity yields absolute position value;
             delta/100 is the signed ordinary quantity, before 9-digit truncation. *)
          let expected = (fill.to_e *. e2 -. fill.from_e *. e1) /. price in
          match action with
          | Live.Order { side; qty; _ } ->
              assert (side = if expected > 0. then `Buy else `Sell);
              assert (abs_float (qty -. abs_float expected) <= 1e-9)
          | Live.Skip _ | Live.Orders _ -> assert false) actions
  in
  (* Cash sell/buy; levered sell repays half its proceeds, so the sibling
     buy needs a refinance; unlevered exit; cross-asset refinance scale-in. *)
  check false [|0.8; 0.|] [|0.3; 0.5|];
  check true [|1.5; 0.|] [|1.2; 0.3|];
  check false [|1.5; 0.|] [|0.6; 0.4|];
  check true [|0.8; 0.|] [|0.8; 0.7|]
```

```ocaml
  test_us_plan_state_split ();
  test_us_plan_action_foreign_symbol ();
  test_us_plan_action_pair_matches_run ();
```

```sh
opam exec --switch=/sandbox/stock -- dune runtest --root . --force
```

Expected: old scalar signatures reject array arguments.

- [ ] **Step 3 (GREEN): Replace both US functions and both signatures.** Sum from zero, divide value by total before multiplying debit, and keep the scalar arithmetic sequence in each asset. Retain the tolerance comment, but remove its obsolete suggestion to add a positions list later: this task now implements that list.

```ocaml
let us_plan_state ~cash ~held ~prices ~ratio ~previous_targets =
  let () = if not (Float.is_finite ratio) || ratio <= 0. then
    failwith "US financing ratio is not positive" in
  let values = Array.mapi (fun i shares -> shares *. prices.(i)) held in
  let total = Array.fold_left ( +. ) 0. values in
  let debit = Float.max 0. (-. cash) in
  let count = Array.length values in
  let loans = Array.map (fun value ->
    if total = 0. then debit /. float_of_int count
    else debit *. (value /. total)) values in
  let margin_values = Array.mapi (fun i value ->
    Float.min value (loans.(i) /. ratio)) values in
  let cash = Float.max cash 0. in
  { Engine.equity = cash +. total -. debit; cash;
    cash_values = Array.mapi (fun i value -> value -. margin_values.(i)) values;
    margin_values; loans; interests = Array.make count 0.;
    tail_interests = Array.make count 0.; debt = 0.; receivables = 0.;
    previous_targets }

let us_plan_action ~rebalance ~symbols ~date ~(account : Alpaca.account_t)
    ~position_symbols ~held ~prices ~targets ~previous_targets =
  let profile = Engine.profile_of_market "us" in
  let ratio = profile.default_financing_ratio in
  let state = us_plan_state ~cash:account.cash ~held ~prices ~ratio ~previous_targets in
  let rec held_value index value =
    if index = Array.length held then value
    else held_value (index + 1) (value +. held.(index) *. prices.(index)) in
  let value = held_value 0 0. in
  let () = if not (Float.is_finite account.cash) then
    failwith "US account cash is not finite" in
  let () = if account.short_market_value <> 0. || Array.exists (fun h -> h < 0.) held then
    failwith "US account holds a short position" in
  let () = List.iter (fun symbol ->
    if not (Array.exists (( = ) symbol) symbols) then
      failwith ("US account holds unsupported symbol " ^ symbol)) position_symbols in
  let () =
    (* ponytail: 1% tolerance for broker marks versus provisional prices;
       retain alongside the positions-list check for valuation consistency. *)
    if not (Float.is_finite account.long_market_value)
      || abs_float (account.long_market_value -. value) > 0.01 *. account.long_market_value
    then failwith "US account holds other symbols" in
  let () = if not (Float.is_finite state.equity) || state.equity <= 0. then
    failwith "US account equity is not positive" in
  if not rebalance && targets = previous_targets then
    state, Array.make (Array.length symbols) (Skip "target unchanged")
  else
    let plan = Engine.plan_fills
      ~costs:(Array.map (fun symbol -> Engine.default_costs ~market:"us" ~symbol) symbols)
      ~capital:1. ~profile ~financing_ratios:(Array.make (Array.length symbols) ratio)
      ~state ~prices ~targets ~force:rebalance in
    let actions = Array.mapi (fun i (item : Engine.planned_asset) ->
      if not rebalance && targets.(i) = previous_targets.(i) then Skip "target unchanged"
      else
        let net = item.plan_buy_cash +. item.plan_buy_margin
          -. item.plan_sell_cash -. item.plan_sell_margin in
        if net = 0. then Skip "no trade planned"
        else
          let price = prices.(i) in
          let side, shares =
            if net > 0. then `Buy, net /. price
            else `Sell, (if item.plan_final_value = 0. then held.(i)
              else Float.min (-. net /. price) held.(i)) in
          let qty = float_of_string (Alpaca.qty_string shares) in
          if qty = 0. || (side = `Buy && qty *. price < 1.) then
            Skip "below $1 minimum order value"
          else Order { side; qty; id = client_order_id ~symbol:symbols.(i) ~date })
      plan.planned_assets in
    state, actions
```

- [ ] **Step 4: Migrate every existing pure US test and the current one-stock US decision call.** Existing test-local closures keep their scalar convenience arguments, but invoke the new public API directly with singleton arrays and unpack `actions.(0)`. They are not exported adapters. Preserve every expected value and the six current decision literals until Task 6.

```ocaml
(* us_plan_state test's existing local state closure. *)
  let state cash held = Live.us_plan_state ~cash ~held:[|held|]
    ~prices:[|100.|] ~ratio:0.5 ~previous_targets:[|1.5|] in
```

```ocaml
(* Existing us_plan_action test closures: their existing bindings supply all values. *)
  let state, actions = Live.us_plan_action ~rebalance ~symbols:[|"SPY"|]
    ~date:"2025-06-24" ~account ~position_symbols:["SPY"]
    ~held:[|held|] ~prices:[|price|] ~targets:[|target|]
    ~previous_targets:[|previous_target|] in
  state, actions.(0)
```

```ocaml
(* Current US decide, from account read through returned record. *)
      let account = Alpaca.account mode in
      let held = Alpaca.position_qty mode symbol in
      let position_symbols = Alpaca.positions mode in
      let state, actions = us_plan_action ~rebalance ~symbols:[|symbol|]
        ~date:provisional.date ~account ~position_symbols ~held:[|held|]
        ~prices:[|provisional.c|] ~targets:[|target|]
        ~previous_targets:[|previous_target|] in
      { fetched_through; provisional; target; equity = state.equity;
        cash = state.cash; debit = state.loans.(0); held; action = actions.(0) }
```

- [ ] **Step 5: Run GREEN gates and six comparisons.** The array mapper must retain exact one-stock pins and the ordered errors even under on_change. The new pair check executes `Engine.run` and compares actual fills, not a mock planner echo.

```sh
opam exec --switch=/sandbox/stock -- dune build --root .
opam exec --switch=/sandbox/stock -- dune runtest --root . --force
```

- [ ] **Step 6: Commit only after coordinator review.**

```sh
git -C /sandbox/stock-multi-stock add /sandbox/stock-multi-stock/broker/live.ml /sandbox/stock-multi-stock/broker/live.mli /sandbox/stock-multi-stock/test/test_bt.ml
git -C /sandbox/stock-multi-stock commit -m "feat: plan US assets jointly and split account debit"
```

Commit only after the coordinator confirms; use the co-author trailer the coordinator names; never push; never change git settings.

### Task 5: Tag and phase-order TW decision legs

**Files:**

| Operation | Absolute path and section |
|---|---|
| Modify | `/sandbox/stock-multi-stock/broker/live.ml`: `leg`, `legs_of_plan`, `maturity_rollover_legs`, `position_totals`, scalar consumers |
| Modify | `/sandbox/stock-multi-stock/broker/live.mli`: leg fields and pure TW exports |
| Test | `/sandbox/stock-multi-stock/test/test_bt.ml`: all `Live.leg` literals, TW split/rollover tests, TW executor fixtures |

**Interfaces:**

| Direction | Contract |
|---|---|
| Produces | `Live.leg` adds `code : string` and `exchange : string` in both declarations |
| Produces | `legs_of_plan : codes:string array -> exchanges:string array -> prices:float array -> Engine.fill_plan -> leg list` |
| Produces | `position_totals : symbols:string array -> prices:float array -> Shioaji.position list -> (float * float * float * float * float * float) array`, entries `(cash_shares, margin_shares, cash_value, margin_value, loans, interests)` |
| Produces | `maturity_rollover_legs : session_date:string -> symbol:string -> exchange:string -> Shioaji.position_detail list -> leg list` |
| Preserves | TW executor's one-code arguments and sequential IOC behavior; Task 6 changes decision assembly, not TW execution batching |

- [ ] **Step 1 (RED): Add two-asset leg ordering and position-set checks, and register them.** Modify one existing split plan to have two deliberately populated assets. This tests the translation boundary directly, without making expected legs depend on a planner call's output.

```ocaml
let test_tw_live_pair_legs () =
  let base = Engine.plan_fills ~costs:[|zero_costs|] ~capital:1.
    ~profile:(Engine.profile_of_market "tw") ~financing_ratios:[|0.6|]
    ~state:{ Engine.equity = 100000.; cash = 100000.;
      cash_values = [|0.|]; margin_values = [|0.|]; loans = [|0.|];
      interests = [|0.|]; tail_interests = [|0.|]; debt = 0.;
      receivables = 0.; previous_targets = [|0.|] }
    ~prices:[|10.|] ~targets:[|0.|] ~force:true in
  let item = base.planned_assets.(0) in
  let a = { item with Engine.plan_sell_margin = 10000.;
    plan_sell_cash = 15000.; plan_refinance_cash = 10000.;
    plan_buy_cash = 12000.; plan_buy_margin = 10000. } in
  let b = { item with Engine.plan_sell_margin = 20000.;
    plan_sell_cash = 20000.; plan_refinance_margin = 20000.;
    plan_buy_cash = 22000.; plan_buy_margin = 20000. } in
  let plan = { base with Engine.planned_assets = [|a; b|] } in
  let legs = Live.legs_of_plan ~codes:[|"2330"; "2890"|]
    ~exchanges:[|"TSE"; "OTC"|] ~prices:[|10.; 20.|] plan in
  let rows = List.map (fun (l : Live.leg) ->
    l.code, l.exchange, l.action, l.cond, l.lot, l.quantity) legs in
  (* Each value/price is a share count: margin values give one lot;
     cash sells give 1500 and 1000; cash buys give 1200 and 1100.
     Both sells precede pairs, pairs precede both buys. *)
  assert (rows =
    ["2330", "TSE", "Sell", "MarginTrading", Shioaji.Common, 1;
     "2890", "OTC", "Sell", "MarginTrading", Shioaji.Common, 1;
     "2330", "TSE", "Sell", "Cash", Shioaji.Common, 1;
     "2330", "TSE", "Sell", "Cash", Shioaji.IntradayOdd, 500;
     "2890", "OTC", "Sell", "Cash", Shioaji.Common, 1;
     "2330", "TSE", "Sell", "Cash", Shioaji.Common, 1;
     "2330", "TSE", "Buy", "MarginTrading", Shioaji.Common, 1;
     "2890", "OTC", "Sell", "MarginTrading", Shioaji.Common, 1;
     "2890", "OTC", "Buy", "MarginTrading", Shioaji.Common, 1;
     "2330", "TSE", "Buy", "Cash", Shioaji.Common, 1;
     "2330", "TSE", "Buy", "Cash", Shioaji.IntradayOdd, 200;
     "2890", "OTC", "Buy", "Cash", Shioaji.Common, 1;
     "2890", "OTC", "Buy", "Cash", Shioaji.IntradayOdd, 100;
     "2330", "TSE", "Buy", "MarginTrading", Shioaji.Common, 1;
     "2890", "OTC", "Buy", "MarginTrading", Shioaji.Common, 1])

let test_tw_position_totals_set () =
  let p code cond shares loan_amount interest : Shioaji.position =
    { id = 0; code; cond; shares; last_price = 1.; loan_amount; interest } in
  let positions = [p "2330" "Cash" 1000 0. 0.;
    p "2890" "MarginTrading" 2000 12000. 10.] in
  let totals = Live.position_totals ~symbols:[|"2330"; "2890"|]
    ~prices:[|10.; 20.|] positions in
  (* Provisional, not last-price, valuation: 1000*10 and 2000*20. *)
  assert (totals = [|1000., 0., 10000., 0., 0., 0.;
    0., 2000., 0., 40000., 12000., 10.|]);
  match Live.position_totals ~symbols:[|"2330"; "2890"|]
    ~prices:[|10.; 20.|] (positions @ [p "9999" "Cash" 1 0. 0.]) with
  | _ -> assert false
  | exception Failure message ->
      assert (message = "TW account holds unsupported symbol 9999")
```

```ocaml
  let () = test_tw_live_pair_legs () in
  let () = test_tw_position_totals_set () in
```

```sh
opam exec --switch=/sandbox/stock -- dune runtest --root . --force
```

Expected: new array signatures and leg fields are absent.

- [ ] **Step 2 (GREEN): Replace `legs_of_plan` with five explicit groups.** Each group follows asset declaration order. Preserve cash-pair before margin-pair within each asset, and the existing Common-before-odd split. No public phase framework is needed.

```ocaml
let legs_of_plan ~codes ~exchanges ~prices (plan : Engine.fill_plan) =
  let leg i ~odd action cond value =
    let price = prices.(i) in
    let () = if not (Float.is_finite price) || price <= 0. then
      failwith "TW planning price must be finite and positive" in
    let shares = int_of_float (Engine.shares_of_value ~capital:1. ~price value) in
    let make lot quantity =
      { code = codes.(i); exchange = exchanges.(i); action; cond; lot; quantity } in
    let common = if shares / 1000 > 0 then
      [make Shioaji.Common (shares / 1000)] else [] in
    let remainder = shares mod 1000 in
    if odd && remainder > 0 then common @ [make Shioaji.IntradayOdd remainder]
    else common
  in
  let group function_ =
    Array.to_list (Array.mapi function_ plan.planned_assets) |> List.concat in
  group (fun i (a : Engine.planned_asset) ->
    leg i ~odd:false "Sell" "MarginTrading" a.plan_sell_margin)
  @ group (fun i (a : Engine.planned_asset) ->
    leg i ~odd:true "Sell" "Cash" a.plan_sell_cash)
  @ group (fun i (a : Engine.planned_asset) ->
    leg i ~odd:false "Sell" "Cash" a.plan_refinance_cash
    @ leg i ~odd:false "Buy" "MarginTrading" a.plan_refinance_cash
    @ leg i ~odd:false "Sell" "MarginTrading" a.plan_refinance_margin
    @ leg i ~odd:false "Buy" "MarginTrading" a.plan_refinance_margin)
  @ group (fun i (a : Engine.planned_asset) ->
    leg i ~odd:true "Buy" "Cash" a.plan_buy_cash)
  @ group (fun i (a : Engine.planned_asset) ->
    leg i ~odd:false "Buy" "MarginTrading" a.plan_buy_margin)
```

- [ ] **Step 3: Replace `position_totals`, keeping its validation and arithmetic order.** Foreign active positions are checked against the entire strategy set before per-symbol aggregation. Foreign zero rows still pass. Export the exact pure signature in the Interfaces block.

```ocaml
let position_totals ~symbols ~prices positions =
  let () = Array.iter (fun price ->
    if not (Float.is_finite price) || price <= 0. then
      failwith "TW planning price must be finite and positive") prices in
  let () = List.iter (fun (p : Shioaji.position) ->
    let active = p.shares <> 0 || p.loan_amount <> 0. || p.interest <> 0. in
    let () = if p.shares < 0 || not (Float.is_finite p.loan_amount)
      || p.loan_amount < 0. || not (Float.is_finite p.interest) || p.interest < 0.
      then failwith "TW position contains invalid account values" in
    let () = if active && not (Array.exists (( = ) p.code) symbols) then
      failwith ("TW account holds unsupported symbol " ^ p.code) in
    if active && p.cond <> "Cash" && p.cond <> "MarginTrading" then
      failwith ("TW account holds unsupported inventory " ^ p.cond)) positions in
  Array.mapi (fun i symbol ->
    let cs, ms, loans, interests = List.fold_left
      (fun (cs, ms, loans, interests) (p : Shioaji.position) ->
        if p.code <> symbol then cs, ms, loans, interests
        else match p.cond with
          | "Cash" -> cs +. float_of_int p.shares, ms, loans, interests
          | "MarginTrading" -> cs, ms +. float_of_int p.shares,
              loans +. p.loan_amount, interests +. p.interest
          | _ -> cs, ms, loans, interests)
      (0., 0., 0., 0.) positions in
    cs, ms, cs *. prices.(i), ms *. prices.(i), loans, interests) symbols
```

- [ ] **Step 4: Add leg fields and migrate current scalar consumers and every test literal.** `maturity_rollover_legs` takes `~exchange` and tags both legs; the date and detail-order logic stays unchanged. Existing tests normally use code `"2330"` and exchange `"TSE"`; test plans deliberately for another code must use that code instead. Use references and syntax-aware record discovery, not a blind global replacement of `quantity`, which also appears in broker order records.

```ocaml
(* leg in live.ml and live.mli. *)
type leg = {
  code : string;
  exchange : string;
  action : string;
  cond : string;
  lot : Shioaji.lot;
  quantity : int;
}
```

```ocaml
(* maturity_rollover_legs: signature and emitted pair. *)
let maturity_rollover_legs ~session_date ~symbol ~exchange details =
  let () = validate_date "session" session_date in
  List.concat_map (fun (detail : Shioaji.position_detail) ->
    let () = validate_date "position origination" detail.date in
    if detail.code = symbol && detail.cond = "MarginTrading" && detail.lots > 0
      && session_date >= Engine.add_months_clamped detail.date 18 then
      [{ code = symbol; exchange; action = "Sell"; cond = "MarginTrading";
         lot = Shioaji.Common; quantity = detail.lots };
       { code = symbol; exchange; action = "Buy"; cond = "MarginTrading";
         lot = Shioaji.Common; quantity = detail.lots }]
    else []) details
```

```ocaml
(* Current one-stock decide and run_tw aggregates; executor uses code instead of symbol. *)
  let cash_shares, margin_shares, cash_value, margin_value, loans, interests =
    (position_totals ~symbols:[|symbol|] ~prices:[|provisional.c|] positions).(0) in
```

```ocaml
(* execute_tw_legs's initial aggregate remains one code. *)
  let cash_shares, margin_shares, _, _, loans, interests =
    (position_totals ~symbols:[|code|] ~prices:[|price|] positions).(0) in
```

```ocaml
(* Existing one-stock decide action; resolve the cached exchange before building legs. *)
      let exchange = exchange_of_symbol ~data_dir symbol in
      let action = Orders
        (maturity_rollover_legs ~session_date ~symbol ~exchange position_details
         @ legs_of_plan ~codes:[|symbol|] ~exchanges:[|exchange|]
             ~prices:[|provisional.c|] plan) in
```

```ocaml
(* Representative complete existing leg literal after migration. *)
  let buy : Live.leg =
    { code = "2330"; exchange = "TSE"; action = "Buy"; cond = "Cash";
      lot = Shioaji.Common; quantity = 1 } in
```

Update existing `legs_of_plan ~price` tests to `~codes:[|"2330"|] ~exchanges:[|"TSE"|] ~prices:[|10.|]`, and each maturity invocation to `~exchange:"TSE"`. Add the two fields to exact expected legs, including Task 1 pins; do not alter their target, held, quantity, condition, lot, or list order. Extend record patterns with `; _` when they intentionally inspect only the old fields. `tw_trade` can now read `leg.code`, but `execute_tw_test` still supplies its one-code executor parameters unchanged.

```ocaml
let tw_trade id (leg : Live.leg) status deal_quantity : Shioaji.trade =
  { order_id = id; code = leg.code; action = leg.action; cond = leg.cond;
    lot = leg.lot; status; order_quantity = leg.quantity; deal_quantity;
    deal_price = if deal_quantity = 0 then None else Some 10. }
```

- [ ] **Step 5: Run GREEN gates and all six byte comparisons.** Both new pure tests and every one-stock decision/executor test must pass. No FOK, batching, or TW stop-rule changes are permitted.

```sh
opam exec --switch=/sandbox/stock -- dune build --root .
opam exec --switch=/sandbox/stock -- dune runtest --root . --force
```

- [ ] **Step 6: Commit only after coordinator review.**

```sh
git -C /sandbox/stock-multi-stock add /sandbox/stock-multi-stock/broker/live.ml /sandbox/stock-multi-stock/broker/live.mli /sandbox/stock-multi-stock/test/test_bt.ml
git -C /sandbox/stock-multi-stock commit -m "feat: build code-tagged phase-ordered TW decision legs"
```

Commit only after the coordinator confirms; use the co-author trailer the coordinator names; never push; never change git settings.

### Task 6: Cut over decisions, output, US execution, and restart routing

**Files:**

| Operation | Absolute path and section |
|---|---|
| Modify | `/sandbox/stock-multi-stock/broker/live.ml`: public decision, `decide`, output helpers, `execute_decision`, `us_step`, `run_us`, `prepare_tw`, `run_tw`, `run` |
| Modify | `/sandbox/stock-multi-stock/broker/live.mli`: decision, `decide`, execution and routing signatures |
| Modify | `/sandbox/stock-multi-stock/bin/bt.ml`: `print_decision`, `live_command_args`, `target` |
| Test | `/sandbox/stock-multi-stock/test/test_bt.ml`: injected TW decisions, US execution/routing and CLI guard patterns, main list |

**Interfaces:**

| Direction | Contract |
|---|---|
| Produces | `asset_decision = { symbol : string; provisional : Data.bar; target : float; held : float; action : action }` |
| Produces | `decision = { fetched_through : string; equity : float; cash : float; debit : float; assets : asset_decision array; legs : leg list }` |
| Produces | `strategy_market : (string option * string * string) list -> string`, validates single market and distinct symbols; reused by CLI, `decide`, and `run` |
| Produces | `align_history : symbols:string array -> Data.bar array list -> string * Data.bar array list`, gap check before intersection filtering |
| Changes | `decide`'s optional `tw_snapshot` is removed in favor of `tw_snapshots : Shioaji.snapshot array`; every injected caller supplies declaration order |
| Changes | `execute_decision` takes `?existing:(string * Alpaca.order_t) list`, `?sleep:(float -> unit)`, `?finish:(string -> string -> string -> Alpaca.order_t -> unit)` plus existing broker injections, then `mode -> string -> string -> decision -> unit`; positional strings are session date and next close |
| Changes | `us_step` takes `symbols:string array`, `execute:((string * Alpaca.order_t) list -> Alpaca.clock_t -> decision -> unit)` and the existing lookup/decide/finish/scheduler callbacks |
| Preserves | `run : ?equity:float -> mode -> strat_path:string -> data_dir:string -> unit`, per-market/mode lock, startup account equity, clock scheduling and pre-POST retry |

The record, all consumers, and execution route change in one task because a half-migrated record cannot compile or trade safely. Steps remain bite-sized, but there is only one GREEN/commit boundary.

#### Decision assembly

- [ ] **Step 1 (RED): Add the gap-rule and actual two-code decision tests from Offline behavioral checks before the implementation.** Register them in the main list. Run the following command; expected failure is missing `assets`, `tw_snapshots`, or `align_history`.

```sh
opam exec --switch=/sandbox/stock -- dune runtest --root . --force
```

- [ ] **Step 2: Replace the decision record in `.ml` and `.mli`, and add the shared guards and alignment helper immediately before `decide`.** Copy the exact record from Interfaces, with `asset_decision` defined before `decision`. `strategy_market` raises `Failure`; the CLI translates the mixed-market message into `usage_error` so exit 2 stays explicit. The union's last five dates, not the intersection or the calendar, define the gap window.

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

```ocaml
let strategy_market stocks =
  match stocks with
  | [] -> failwith "live trading needs one market"
  | (_, market, _) :: rest ->
      let () = if not (List.for_all (fun (_, other, _) -> other = market) rest)
        then failwith "live trading needs one market" in
      let seen = Hashtbl.create (List.length stocks) in
      let () = List.iter (fun (_, _, symbol) ->
        if Hashtbl.mem seen symbol then
          failwith ("live trading needs distinct symbols: " ^ symbol);
        Hashtbl.add seen symbol ()) stocks in
      market

let align_history ~symbols arrays =
  let dates bars = Array.to_list (Array.map (fun (b : Data.bar) -> b.date) bars) in
  let union = List.concat_map dates arrays |> List.sort_uniq String.compare in
  let recent = List.rev union |> List.to_seq |> Seq.take 5 |> List.of_seq in
  let () = List.iteri (fun i bars ->
    let present = Hashtbl.create (Array.length bars) in
    let () = Array.iter (fun (b : Data.bar) -> Hashtbl.replace present b.date ()) bars in
    if List.exists (fun date -> not (Hashtbl.mem present date)) recent then
      failwith ("history gap in " ^ symbols.(i) ^ " within the last 5 sessions")) arrays in
  let common = Data.common_dates arrays in
  let fetched_through = match List.rev common with
    | date :: _ -> date
    | [] -> failwith "live history has no common trading dates" in
  let keep = Hashtbl.create (List.length common) in
  let () = List.iter (fun date -> Hashtbl.replace keep date ()) common in
  fetched_through, List.map
    (Data.filter_dates ~keep:(fun date -> Hashtbl.mem keep date)) arrays
```

```ocaml
val strategy_market : (string option * string * string) list -> string
val align_history :
  symbols:string array -> Data.bar array list -> string * Data.bar array list
```

- [ ] **Step 3: Replace `decide`'s dispatch and US arm with N-symbol loads, preserving existing fetch/freshness/override behavior.** Define private `decision_targets` once and call it from both market arms. All compile inputs follow declaration order; normalize each row once over all ratios.

```ocaml
let decision_targets ast stocks arrays provisional ratios =
  let index = ref 0 in
  let assets = List.map2 (fun (alias, _, _) bars ->
    let provisional_bar = provisional.(!index) in
    let () = incr index in
    alias, Array.append bars [|provisional_bar|]) stocks arrays in
  let strategy = Dsl.compile_ast ast ~params:[] ~assets in
  let length = Array.length strategy.Engine.targets.(0) in
  let row i = Array.map (fun targets -> targets.(i)) strategy.targets in
  let effective i = fst (Engine.effective_targets ~financing_ratios:ratios (row i)) in
  effective (length - 1),
  (if length = 1 then Array.make (List.length stocks) 0. else effective (length - 2))

let decide ?provisional_close ?previous_session ?equity ?tw_balance
    ?tw_settlements ?tw_positions ?tw_position_details ?tw_snapshots mode
    ~session_date ~strat_path ~data_dir =
  let ast = Dsl.parse_file strat_path in
  let rebalance = Option.value (Dsl.rebalance_of ~filename:strat_path ast) ~default:false in
  let stocks = Dsl.stocks_of ~filename:strat_path ast in
  let market = strategy_market stocks in
  let symbols = Array.of_list (List.map (fun (_, _, s) -> s) stocks) in
  let () = if provisional_close <> None && Array.length symbols <> 1 then
    failwith "--provisional-close needs a one-stock strategy" in
  let check_session (bar : Data.bar) =
    match snapshot_session ~session_date ~provisional_date:bar.date with
    | `Proceed -> ()
    | `Skip reason -> failwith reason in
  match market with
  | "us" ->
      let loaded = Array.map (fun symbol ->
        let snapshot = match provisional_close with
          | None -> Alpaca.snapshot symbol
          | Some price ->
              let path = Filename.concat
                (Filename.concat (Filename.concat data_dir "us") symbol) (symbol ^ ".csv") in
              let prev_day_date = match Data.last_cached_date path with
                | Some date -> date
                | None -> failwith (Printf.sprintf
                    "%s has no cached rows; run bt fetch us/%s" path symbol) in
              override_snapshot ~session_date ~prev_day_date ~price in
        let () = Data.fetch ~market:"us" ~symbol ~from_:None
          ~to_:snapshot.prev_day_date ~data_dir in
        let asset = Data.load_asset ~market:"us" ~symbol ~from_:None
          ~to_:(Some snapshot.prev_day_date) ~data_dir in
        let through = asset.signal.(Array.length asset.signal - 1).date in
        let () = if not (cache_is_fresh ~last_cached:through
          ~prev_trading_day:snapshot.prev_day_date) then
          failwith (Printf.sprintf "stale cache: fetched through %s, expected %s"
            through snapshot.prev_day_date) in
        asset.signal, provisional_bar snapshot) symbols in
      let fetched_through, arrays = align_history ~symbols
        (Array.to_list (Array.map fst loaded)) in
      let provisional = Array.map snd loaded in
      let () = Array.iter check_session provisional in
      let ratios = Array.make (Array.length symbols)
        (Engine.profile_of_market "us").default_financing_ratio in
      let targets, previous_targets =
        decision_targets ast stocks arrays provisional ratios in
      let account = Alpaca.account mode in
      let held = Array.map (Alpaca.position_qty mode) symbols in
      let position_symbols = Alpaca.positions mode in
      let prices = Array.map (fun (b : Data.bar) -> b.c) provisional in
      let state, actions = us_plan_action ~rebalance ~symbols ~date:session_date
        ~account ~position_symbols ~held ~prices ~targets ~previous_targets in
      { fetched_through; equity = state.equity; cash = state.cash;
        debit = Array.fold_left ( +. ) 0. state.loans; legs = [];
        assets = Array.mapi (fun i symbol ->
          { symbol; provisional = provisional.(i); target = targets.(i);
            held = held.(i); action = actions.(i) }) symbols }
```

Step 4 continues this same `match` expression with the TW and default arms; do not install two `decide` functions.

- [ ] **Step 4: Replace the TW arm with N-snapshot, N-position, and N-state assembly.** Keep the original session/equity validations and cash operation order. Fetch an independent previous session only once. With an injected previous session, no fetch occurs, as in the existing fixture seam.

```ocaml
  | "tw" ->
      let () = validate_date "session" session_date in
      let () = match mode, equity with
        | Paper, Some v when Float.is_finite v && v > 0. -> ()
        | Paper, Some _ -> failwith "simulation equity must be finite and positive"
        | Paper, None -> failwith "simulation mode requires --equity"
        | Live, Some _ -> failwith "--equity is not allowed in production"
        | Live, None -> () in
      let fetch_required = Option.is_none previous_session in
      let previous_session = match previous_session with
        | Some date -> date
        | None -> Data.previous_trading_day ~before:session_date in
      let () = validate_date "previous session" previous_session in
      let () = if previous_session >= session_date then failwith
        (Printf.sprintf "previous TW trading session %s is not before %s"
          previous_session session_date) in
      let exchanges = Array.map (exchange_of_symbol ~data_dir) symbols in
      let snapshots = match provisional_close, tw_snapshots with
        | Some price, _ ->
            [|{ Shioaji.datetime = session_date ^ "T13:20:00+08:00";
                open_ = price; high = price; low = price; close = price;
                bid = price; ask = price; total_volume = 0. }|]
        | None, Some snapshots -> snapshots
        | None, None -> Shioaji.snapshot ~contracts:
            (Array.mapi (fun i code -> exchanges.(i), code) symbols) in
      let () = if Array.length snapshots <> Array.length symbols then
        failwith "invalid Shioaji snapshot response" in
      let arrays = Array.map (fun symbol ->
        let () = if fetch_required then
          let () = Data.fetch ~market:"tw" ~symbol ~from_:None ~to_:previous_session ~data_dir in
          Data.fetch_tw_adjustments ~symbol ~to_:session_date ~data_dir in
        let asset = Data.load_asset ~market:"tw" ~symbol ~from_:None
          ~to_:(Some previous_session) ~data_dir in
        let through = match Array.length asset.signal with
          | 0 -> failwith "TW cache has no previous trading session"
          | n -> asset.signal.(n - 1).date in
        let () = if through <> previous_session then
          failwith (Printf.sprintf "stale TW cache: fetched through %s, expected %s"
            through previous_session) in
        asset.signal) symbols |> Array.to_list in
      let fetched_through, arrays = align_history ~symbols arrays in
      let provisional = Array.map tw_provisional_bar snapshots in
      let () = Array.iter check_session provisional in
      let prices = Array.map (fun (b : Data.bar) -> b.c) provisional in
      let ratios = Array.map
        (fun symbol -> Data.financing_ratio ~market:"tw" ~data_dir ~symbol) symbols in
      let targets, previous_targets =
        decision_targets ast stocks arrays provisional ratios in
      let positions = match tw_positions with
        | Some positions -> positions | None -> Shioaji.positions () in
      let details = match tw_position_details, tw_positions with
        | Some details, _ -> details
        | None, Some _ -> []
        | None, None -> Array.to_list symbols
            |> List.concat_map (fun symbol -> fetch_position_details symbol positions) in
      let totals = position_totals ~symbols ~prices positions in
      let cash_values = Array.map (fun (_, _, cv, _, _, _) -> cv) totals in
      let margin_values = Array.map (fun (_, _, _, mv, _, _) -> mv) totals in
      let loans = Array.map (fun (_, _, _, _, l, _) -> l) totals in
      let interests = Array.map (fun (_, _, _, _, _, i) -> i) totals in
      let sum values = Array.fold_left ( +. ) 0. values in
      let cv = sum cash_values and mv = sum margin_values in
      let loan = sum loans and interest = sum interests in
      let cash, equity = match mode, equity with
        | Paper, Some equity -> equity -. cv -. mv +. loan +. interest, equity
        | Live, None ->
            let balance = match tw_balance with Some b -> b | None -> Shioaji.balance () in
            let settlements = match tw_settlements with
              | Some s -> s | None -> Shioaji.settlements () in
            let cash = tw_production_cash ~balance ~settlements in
            cash, cash +. cv +. mv -. loan -. interest
        | Paper, None | Live, Some _ -> assert false in
      let () = if not (Float.is_finite cash) then
        failwith "TW inferred cash balance is not finite" in
      let () = if not (Float.is_finite equity) || equity <= 0. then
        failwith "TW account equity is not positive" in
      let state : Engine.plan_state =
        { equity; cash; cash_values; margin_values; loans; interests;
          tail_interests = Array.make (Array.length symbols) 0.;
          debt = 0.; receivables = 0.; previous_targets } in
      let plan = Engine.plan_fills ~costs:(Array.map tw_live_debit_costs symbols)
        ~capital:1. ~profile:(Engine.profile_of_market "tw")
        ~financing_ratios:ratios ~state ~prices ~targets ~force:rebalance in
      let rollover = Array.to_list (Array.mapi (fun i symbol ->
        maturity_rollover_legs ~session_date ~symbol ~exchange:exchanges.(i) details) symbols)
        |> List.concat in
      let legs = rollover @ legs_of_plan ~codes:symbols ~exchanges ~prices plan in
      { fetched_through; equity; cash; debit = loan; legs;
        assets = Array.mapi (fun i symbol ->
          let cs, ms, _, _, _, _ = totals.(i) in
          { symbol; provisional = provisional.(i); target = targets.(i);
            held = cs +. ms;
            action = Orders (List.filter (fun (l : leg) -> l.code = symbol) legs) }) symbols }
  | _ -> failwith "live trading supports us and tw only"
```

Update the `.mli` `decide` declaration by replacing its sole `?tw_snapshot:Shioaji.snapshot` parameter with `?tw_snapshots:Shioaji.snapshot array`. Keep its other optional labels and required arguments identical.

#### Output and startup validation

- [ ] **Step 5: Replace `print_decision` with account lines followed by asset blocks.** Keep the action formats exactly; leg codes belong to the containing symbol block, not the textual `leg:` format.

```ocaml
let print_decision provisional_close (decision : Live.decision) =
  let () = match provisional_close with
    | None -> ()
    | Some price -> Printf.printf "provisional: override %.10g\n" price in
  let () = Printf.printf "fetched-through: %s\n" decision.fetched_through in
  let () = Printf.printf "equity: %.10g\n" decision.equity in
  let () = Printf.printf "cash: %.10g\n" decision.cash in
  let () = Printf.printf "debit: %.10g\n" decision.debit in
  Array.iter (fun (asset : Live.asset_decision) ->
    let bar = asset.provisional in
    let () = Printf.printf "symbol: %s\n" asset.symbol in
    let () = Printf.printf "provisional-date: %s\n" bar.date in
    let () = Printf.printf "provisional-open: %.10g\n" bar.o in
    let () = Printf.printf "provisional-high: %.10g\n" bar.h in
    let () = Printf.printf "provisional-low: %.10g\n" bar.l in
    let () = Printf.printf "provisional-close: %.10g\n" bar.c in
    let () = Printf.printf "provisional-volume: %.10g\n" bar.v in
    let () = Printf.printf "target: %.10g\n" asset.target in
    let () = Printf.printf "held: %.10g\n" asset.held in
    match asset.action with
    | Live.Order { side; qty; id } ->
        let side = match side with `Buy -> "buy" | `Sell -> "sell" in
        let () = Printf.printf "action: order\n" in
        let () = Printf.printf "side: %s\n" side in
        let () = Printf.printf "quantity: %s\n" (Alpaca.qty_string qty) in
        Printf.printf "client-order-id: %s\n" id
    | Live.Skip reason ->
        let () = Printf.printf "action: skip\n" in
        Printf.printf "reason: %s\n" reason
    | Live.Orders legs ->
        let () = Printf.printf "action: orders\n" in
        List.iter (fun (leg : Live.leg) ->
          let lot = match leg.lot with
            | Shioaji.Common -> "Common" | Shioaji.IntradayOdd -> "IntradayOdd" in
          Printf.printf "leg: %s %s %s %d\n"
            leg.action leg.cond lot leg.quantity) legs) decision.assets
```

- [ ] **Step 6: Replace the CLI exactly-one check and reject a multi-stock override before broker calls.** `strategy_market` is shared rather than establishing another duplicate validation convention.

```ocaml
(* live_command_args: replace its existing let market block. *)
  let market =
    match Live.strategy_market (Dsl.stocks_of ~filename:strat_path ast) with
    | market -> market
    | exception Failure message when message = "live trading needs one market" ->
        usage_error message
  in
```

```ocaml
(* target: immediately after live_command_args, before warning or broker dispatch. *)
  let () =
    if !provisional_close <> None
      && List.length (Dsl.stocks_of ~filename:strat_path (Dsl.parse_file strat_path)) <> 1
    then failwith "--provisional-close needs a one-stock strategy"
  in
```

- [ ] **Step 7: Replace `Live.run`'s one-stock match with a market match and the temporary TW startup guard.** The guard precedes locks and Shioaji I/O. Resolve symbols once for `run_us`; delete its redundant parse/exactly-one block and add `~symbols` to its parameters.

```ocaml
(* Live.run, after ast/rebalance_choice/directory bindings. *)
  let stocks = Dsl.stocks_of ~filename:strat_path ast in
  let market = strategy_market stocks in
  let symbols = Array.of_list (List.map (fun (_, _, s) -> s) stocks) in
  match market with
  | "us" ->
      let fd = lock_daemon ~directory ~market:"us" mode in
      Fun.protect ~finally:(fun () -> Unix.close fd)
        (fun () -> run_us mode ~symbols ~strat_path ~data_dir ~rebalance_choice)
  | "tw" ->
      let () = if Array.length symbols <> 1 then
        failwith "TW live trading needs one stock in this release" in
      let symbol = symbols.(0) in
      let fd = lock_daemon ~directory ~market:"tw" mode in
      Fun.protect ~finally:(fun () -> Unix.close fd)
        (fun () -> run_tw mode ~equity ~symbol ~strat_path ~data_dir ~rebalance_choice)
  | _ -> failwith "live trading supports us and tw only"
```

- [ ] **Step 8: Migrate the one-code TW daemon to the new record and log schema without altering its executor.** `prepare_tw` requests an array of contracts and checks every returned snapshot date with `Array.iter`, still called with its singleton here. `run_tw` supplies `~tw_snapshots:[|snapshot|]`, selects `decision.assets.(0)` for its one execution price, and uses `decision.legs` directly, never rebuilding execution order from per-asset actions.

```ocaml
(* prepare_tw: snapshot fetch and validation replace its scalar block. *)
  let snapshots = Shioaji.snapshot ~contracts:[|exchange, symbol|] in
  let () = Array.iter (fun snapshot ->
    let snapshot_date = tw_snapshot_date snapshot in
    if snapshot_date <> date then failwith
      (Printf.sprintf "snapshot session %s is not trading date %s" snapshot_date date))
    snapshots in
```

```ocaml
(* run_tw, immediately after decide. *)
                    let asset = decision.assets.(0) in
                    let cash_shares, margin_shares, _, _, loans, _ =
                      (position_totals ~symbols:[|symbol|]
                        ~prices:[|asset.provisional.c|] positions).(0) in
                    let cash = decision.cash in
                    let outcome, legs =
                      match decision.legs with
                      | [] -> "skip:no-order-legs", []
                      | legs ->
                          let execution = execute_tw_legs ~mode ~bid:snapshot.bid
                            ~ask:snapshot.ask ~now:taipei_now ~sleep:Unix.sleepf
                            ~place_order:Shioaji.place_order ~orders_today:Shioaji.orders_today
                            ~exchange ~code:symbol ~date ~price:asset.provisional.c
                            ~financing_ratio ~costs ~cash ~positions legs in
                          let () = List.iter (log_tw_trade date) execution.trades in
                          let outcome = match execution.stop_reason with
                            | None -> "complete"
                            | Some reason -> Printf.sprintf "stop:%s remaining:%s" reason
                                (tw_legs_description execution.remaining) in
                          outcome, legs in
                    let () = log
                      "date=%s fetched-through=%s equity=%.10g cash=%.10g debit=%.10g submitted=%s"
                      date decision.fetched_through decision.equity decision.cash
                      decision.debit outcome in
                    let () = log
                      "date=%s symbol=%s provisional-close=%.10g target=%.10g cash-shares=%.10g margin-shares=%.10g loan=%.10g planned-legs=%s"
                      date symbol asset.provisional.c asset.target cash_shares margin_shares
                      loans (tw_legs_description legs) in
```

Delete `production_cash` from `run_tw`'s balance/settlement tuple and its now-unused branch: `decision.cash` is the authoritative pre-trade cash. Keep `tw_balance, tw_settlements`, passing their existing options to `decide`. The existing-orders branch logs the account line with startup equity and unavailable cash/debit as `-`, then the symbol line with unavailable asset fields, preserving `submitted=skip:existing-orders`. This branch has not computed a decision and must not invent account values.

```ocaml
                    let () = log
                      "date=%s fetched-through=%s equity=%.10g cash=- debit=- submitted=skip:existing-orders"
                      date previous_session startup_equity in
                    let () = log
                      "date=%s symbol=%s provisional-close=- target=- cash-shares=- margin-shares=- loan=- planned-legs=none"
                      date symbol in
```

Add `code=%s` after `date=%s` in `log_tw_trade`'s existing format and pass `trade.code` immediately after date; keep every remaining field and the post-close query unchanged.

```ocaml
  log "date=%s code=%s order-id=%s action=%s cond=%s lot=%s fill-status=%s deal-quantity=%d fill-price=%s"
    date trade.code trade.order_id trade.action trade.cond (lot_name trade.lot)
    trade.status trade.deal_quantity price
```

#### US execution and restart routing

- [ ] **Step 9 (RED): Add the execution/restart tests below and migrate the six existing scalar decision literals.** All contain the same single asset, with their original distinct action expression; wrap that asset rather than changing quantities or order policy.

```ocaml
(* Representative complete test decision, using the new record. *)
  let decision : Live.decision =
    { fetched_through = "2025-06-23"; equity = 1000.; cash = 1000.; debit = 0.;
      legs = [];
      assets = [|{ Live.symbol = "SPY";
        provisional = { Data.date = "2025-06-24"; o = 300.; h = 300.;
          l = 300.; c = 300.; v = 0. };
        target = 0.5; held = 0.;
        action = Live.Order { side = `Buy; qty = 1.; id = "bt-SPY-2025-06-24" } }|] } in
```

```ocaml
(* test_us_decision_logs_after_preflight: replace its old record update. *)
  let skipped = { decision with Live.assets =
    [|{ decision.assets.(0) with action = Live.Skip "no trade" }|] } in
```

Every existing execution invocation changes its old positional `"SPY"` argument to `"2025-06-24"`; the symbol now comes from `decision.assets`. Existing routing tests change `~symbol:"SPY"` to `~symbols:[|"SPY"|]` and add the first `existing` parameter to injected `execute` callbacks. Preserve preflight-empty-output and uncertain/rejected/log-failure no-retry assertions.

```sh
opam exec --switch=/sandbox/stock -- dune runtest --root . --force
```

- [ ] **Step 10: Replace `log_decision` and add symbol identity to fill/error lines.** No-change returns one account/skip line instead of N symbol lines. Ordinary account and asset lines are emitted only after the relevant preflight succeeds, as before.

```ocaml
let log_decision date (decision : decision) =
  if Array.for_all (fun (a : asset_decision) ->
    a.action = Skip "target unchanged") decision.assets then
    log "date=%s fetched-through=%s equity=%.10g cash=%.10g debit=%.10g order=skip:target unchanged"
      date decision.fetched_through decision.equity decision.cash decision.debit
  else
    let () = log "date=%s fetched-through=%s equity=%.10g cash=%.10g debit=%.10g"
      date decision.fetched_through decision.equity decision.cash decision.debit in
    Array.iter (fun (a : asset_decision) ->
      log "date=%s symbol=%s provisional-close=%.10g target=%.10g held=%.10g order=%s fill=pending"
        date a.symbol a.provisional.c a.target a.held (order_description a.action))
      decision.assets
```

`log_fill`'s argument list gains `symbol` immediately after date; both format strings gain `symbol=%s` immediately after date. `poll_fill` and `finish_order` gain the same argument and thread it through their recursion/logs. Preserve terminal statuses, 15-second interval and close+5-minute deadline. The injected `finish` seam below is only a scheduler boundary for deterministic execution tests, and defaults to that same production `finish_order`.

- [ ] **Step 11: Replace `execute_decision` with a per-symbol dedupe and two-phase executor.** Before any POST, lookup/clock failures propagate to `us_step` for retry. Once a POST is attempted, every failure is caught and logs skip without retry, including broken stdout. Existing orders mean the session already has a POST, so later preflight failures must not trigger another attempt. Finish every known placed order, even after a sell-phase stop. A missing sell lookup is still open, never permission to buy.

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
  let posted = ref (existing <> []) in
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
  let execute () =
    (* Complete every dedupe lookup before logging or submitting. *)
    let pending = List.filter (fun (symbol, _, _, id) ->
      match order_by_client_id mode id with
      | None -> true
      | Some order ->
          let () = placed := (symbol, order) :: !placed in
          let () = posted := true in
          let () = log "date=%s symbol=%s order=existing:%s fill=pending" date symbol id in
          false) orders in
    let preflight () =
      let c = clock mode in
      if not c.is_open || next_actions ~now:c.timestamp ~next_close <> `Decide
      then failwith "submit cutoff passed" in
    let restarting_sell = List.exists
      (fun (_, (o : Alpaca.order_t)) -> o.side = "sell") !placed in
    let pending_sell = List.exists (fun (_, side, _, _) -> side = `Sell) pending in
    let () = if pending <> [] && (not restarting_sell || pending_sell) then preflight () in
    let () = log_decision date decision in
    let submit (symbol, side, qty, id) =
      let () = preflight () in
      let () = posted := true in
      match submit_market mode ~symbol ~qty ~side ~client_order_id:id with
      | order ->
          let () = placed := (symbol, order) :: !placed in
          if order.status = "rejected" then
            failwith (if side = `Sell then "sell " ^ symbol ^ " rejected"
              else "Alpaca rejected the order")
      | exception error ->
          failwith (if side = `Sell then "sell " ^ symbol ^ " uncertain"
            else "order submission uncertain: " ^ Printexc.to_string error) in
    let submit_checked ((symbol, _, _, _) as request) =
      match submit request with
      | () -> ()
      | exception error ->
          let () = (try log "date=%s symbol=%s error=%s order=skip"
            date symbol (error_text error) with _ -> ()) in
          raise error in
    let sells, buys = List.partition (fun (_, side, _, _) -> side = `Sell) pending in
    let has_sell = sells <> [] || List.exists
      (fun (_, (o : Alpaca.order_t)) -> o.side = "sell") !placed in
    if not has_sell || buys = [] then List.iter submit_checked pending
    else
      let () = List.iter submit_checked sells in
      let rec wait_sells () =
        let stop = ref None in
        let open_sell = ref None in
        let () = placed := List.map (fun (symbol, (order : Alpaca.order_t)) ->
          if order.side <> "sell" then symbol, order
          else
            let current =
              match order_by_client_id mode (client_order_id ~symbol ~date) with
              | None -> order
              | Some current -> current
              | exception _ -> failwith ("sell " ^ symbol ^ " uncertain") in
            let () = if current.status <> "filled" then
              if terminal_order_status current.status then
                (if !stop = None then stop := Some ("sell " ^ symbol ^ " " ^ current.status))
              else if !open_sell = None then open_sell := Some symbol in
            symbol, current) !placed in
        match !stop, !open_sell with
        | Some reason, _ -> failwith reason
        | None, None -> ()
        | None, Some symbol ->
            let c = clock mode in
            if not c.is_open || next_actions ~now:c.timestamp ~next_close <> `Decide then
              failwith ("sell " ^ symbol ^ " open at cutoff")
            else let () = sleep 15. in wait_sells () in
      let () = wait_sells () in
      List.iter submit_checked buys in
  match execute () with
  | () -> (try finish_all () with _ -> ())
  | exception error when !posted ->
      let () = (try log "date=%s error=%s order=skip" date (error_text error) with _ -> ()) in
      (try finish_all () with _ -> ())
  | exception Failure message when message = "submit cutoff passed" ->
      log "date=%s error=submit cutoff passed order=skip" date
  | exception error -> raise error
```


- [ ] **Step 12: Replace `us_step` with all-symbol lookup, done-symbol filtering and side-aware routing.** Lookups occur even at the cutoff. When all symbols are done, do not decide. A partial restart evaluates all N assets from current holdings once, passes existing orders to execution, and replaces done assets' actions with `Skip "existing order"` only for execution. Existing buys do not gate sells; existing sells gate remaining buys.

```ocaml
let us_step ~symbols ~lookup ~decide ~execute ~finish ~sleep_until ~retry
    ~continue (clock : Alpaca.clock_t) =
  if not clock.is_open then
    let () = sleep_until clock.next_open in continue ()
  else match next_actions ~now:clock.timestamp ~next_close:clock.next_close with
  | `Sleep_until timestamp -> let () = sleep_until timestamp in continue ()
  | `Post_close -> let () = sleep_until clock.next_open in continue ()
  | (`Decide | `Cutoff_passed as phase) ->
      let date = timestamp_date clock.timestamp in
      let existing = ref [] in
      let end_day () = let () = sleep_until clock.next_open in continue () in
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
        if List.length !existing = Array.length symbols || phase = `Cutoff_passed then
          let () = reconcile () in `End
        else
          let decision = decide date in
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

At the cutoff with missing symbols, preserve the old explicit cutoff log before reconciliation/end:

```ocaml
        let () = if phase = `Cutoff_passed
          && List.length !existing <> Array.length symbols then
          log "date=%s error=submit cutoff passed order=skip" date in
```

Place this after the lookup `Array.iter`, before the all-done/cutoff branch.

- [ ] **Step 13: Thread the final signatures into `run_us` and `.mli`.** Keep the startup read/guard/log and 60-second retry clock unchanged.

```ocaml
  and step clock =
    us_step ~symbols ~lookup:(Alpaca.order_by_client_id mode)
      ~decide:(fun date -> decide mode ~session_date:date ~strat_path ~data_dir)
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
```

```ocaml
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

val us_step :
  symbols:string array ->
  lookup:(string -> Alpaca.order_t option) ->
  decide:(string -> decision) ->
  execute:((string * Alpaca.order_t) list -> Alpaca.clock_t -> decision -> unit) ->
  finish:(Alpaca.clock_t -> string -> string -> Alpaca.order_t -> unit) ->
  sleep_until:(string -> unit) -> retry:(unit -> unit) ->
  continue:(unit -> unit) -> Alpaca.clock_t -> unit
```

#### Offline behavioral checks

- [ ] **Step 14: Implement and register the gap test.** The seven union dates mean day 1 is old and day 6 is recent. Compare filtered bars themselves, not only lengths.

```ocaml
let test_live_history_gap () =
  let dates = List.init 7 (fun i -> Printf.sprintf "2026-05-%02d" (i + 11)) in
  let bars dates = Array.of_list (List.map (fun d -> bar d 100. 100.) dates) in
  let full = bars dates in
  let old = bars (List.tl dates) in
  let fetched, aligned = Live.align_history ~symbols:[|"A"; "B"|] [full; old] in
  (* Union's last five are May 13-17; the missing May 11 is older and passes.
     Both arrays equal bt run's intersection filter, May 12-17. *)
  assert (fetched = "2026-05-17");
  assert (aligned = [old; old]);
  let recent = bars (List.filter (( <> ) "2026-05-16") dates) in
  match Live.align_history ~symbols:[|"A"; "B"|] [full; recent] with
  | _ -> assert false
  | exception Failure message ->
      assert (message = "history gap in B within the last 5 sessions")
```

- [ ] **Step 15: Implement the actual two-code TW decision assembly test.** This traverses cache loading, the DSL compiler, joint effective targets, aggregate account values, rollover prepend, and action partitioning. Use the Task 1 helper and inject both snapshots so no REST/calendar call occurs.

```ocaml
let test_tw_live_pair_decide () =
  with_tw_decision_cache (fun data_dir ->
    let snapshot price : Shioaji.snapshot =
      { datetime = "2026-05-26T13:20:00+08:00"; open_ = price;
        high = price; low = price; close = price; bid = price; ask = price;
        total_volume = 0. } in
    let positions : Shioaji.position list =
      [{ id = 0; code = "2330"; cond = "Cash"; shares = 1000;
         last_price = 1.; loan_amount = 0.; interest = 0. };
       { id = 1; code = "2330"; cond = "MarginTrading"; shares = 1000;
         last_price = 1.; loan_amount = 6000.; interest = 10. };
       { id = 2; code = "2890"; cond = "MarginTrading"; shares = 2000;
         last_price = 1.; loan_amount = 24000.; interest = 20. }] in
    let details : Shioaji.position_detail list =
      [{ code = "2330"; cond = "MarginTrading"; date = "2024-11-26"; lots = 1 };
       { code = "2890"; cond = "MarginTrading"; date = "2024-11-26"; lots = 2 }] in
    let choose rebalance ta tb details =
      with_temp_strategy
        (Printf.sprintf
          "stock \"tw/2330\" as a\nstock \"tw/2890\" as b\nrebalance %s\na.target %s\nb.target %s\n"
          rebalance ta tb)
        (fun strat_path -> Live.decide ~previous_session:"2026-05-22"
          ~equity:100000. ~tw_positions:positions ~tw_position_details:details
          ~tw_snapshots:[|snapshot 10.; snapshot 20.|] Live.Paper
          ~session_date:"2026-05-26" ~strat_path ~data_dir) in
    let scaled = choose "on_change" "2.0" "2.0" details in
    (* Funding need 2*0.4 + 2*0.4 = 1.6; scale 1/1.6 makes both 1.25.
       CV=10000, MV=10000+40000, L=6000+24000, I=10+20:
       cash=100000-10000-50000+30000+30=70030, debit=30000. *)
    let () = assert (Array.map (fun (a : Live.asset_decision) -> a.symbol)
      scaled.assets = [|"2330"; "2890"|]) in
    let () = Array.iter (fun (a : Live.asset_decision) -> assert_close 1.25 a.target)
      scaled.assets in
    let () = assert (scaled.cash = 70030. && scaled.debit = 30000.) in
    let () = assert (scaled.legs =
      [{ Live.code = "2330"; exchange = "TSE"; action = "Sell";
         cond = "MarginTrading"; lot = Shioaji.Common; quantity = 1 };
       { Live.code = "2330"; exchange = "TSE"; action = "Buy";
         cond = "MarginTrading"; lot = Shioaji.Common; quantity = 1 };
       { Live.code = "2890"; exchange = "OTC"; action = "Sell";
         cond = "MarginTrading"; lot = Shioaji.Common; quantity = 2 };
       { Live.code = "2890"; exchange = "OTC"; action = "Buy";
         cond = "MarginTrading"; lot = Shioaji.Common; quantity = 2 }]) in
    (* Both prior closes are 1980: num(close>1000)=1. Provisional prices
       are 10 and 20: each becomes zero, so each asset fully closes.
       This distinguishes previous-row targets from zeros or today's row. *)
    let closed = choose "on_change" "num(a.close > 1000.0)"
      "num(b.close > 1000.0)" [] in
    let () = assert (List.map (fun (l : Live.leg) -> l.code, l.cond, l.quantity)
      closed.legs = ["2330", "MarginTrading", 1;
        "2890", "MarginTrading", 2; "2330", "Cash", 1]) in
    Array.iter (fun (a : Live.asset_decision) -> match a.action with
      | Live.Orders legs -> assert (legs = List.filter
          (fun (l : Live.leg) -> l.code = a.symbol) closed.legs)
      | Live.Order _ | Live.Skip _ -> assert false) closed.assets)
```

- [ ] **Step 16: Implement the US execution harness and phase cases, including per-order-safe finishing.** A scheduler seam prevents any wall-clock wait or network finish call. The scripted queue gives a deterministic clock; all known orders are reconciled through the injected finish callback. A failed first finish must not block the second order, including when its error logger raises on broken stdout.

```ocaml
let us_pair_decision actions : Live.decision =
  { fetched_through = "2025-06-23"; equity = 1000.; cash = 500.; debit = 0.;
    legs = []; assets = Array.mapi (fun i action ->
      { Live.symbol = [|"SPY"; "QQQ"|].(i);
        provisional = bar "2025-06-24" 100. 100.; target = 0.5;
        held = 5.; action }) actions }

let us_fixture_order symbol side status : Alpaca.order_t =
  { id = "broker-" ^ symbol; side; status;
    filled_avg_price = if status = "filled" then Some 100. else None;
    filled_qty = if status = "filled" then 1. else 0. }

let with_us_finish_failure ~broken_log function_ =
  let saved = Unix.dup Unix.stdout in
  let read_only = Unix.openfile "/dev/null" [Unix.O_RDONLY] 0 in
  let finished = ref [] in
  let finish symbol =
    let () = finished := symbol :: !finished in
    if symbol = "SPY" then
      let () = if broken_log then Unix.dup2 read_only Unix.stdout in
      failwith "SPY fill lookup unavailable"
  in
  Fun.protect
    ~finally:(fun () ->
      Unix.dup2 saved Unix.stdout;
      flush stdout;
      Unix.close saved;
      Unix.close read_only)
    (fun () ->
      let () = function_ finish in
      List.rev !finished)

let test_us_pair_execution () =
  let date = "2025-06-24" and close = "2025-06-24T16:00:00-04:00" in
  let action symbol side = Live.Order
    { side; qty = 1.; id = Live.client_order_id ~symbol ~date } in
  let decision = us_pair_decision [|action "SPY" `Sell; action "QQQ" `Buy|] in
  let run sell_status cutoff existing decision =
    let events = ref [] and submitted = ref false in
    let record x = events := x :: !events in
    let output = capture_stdout (fun () ->
      Live.execute_decision ~existing ~sleep:(fun _ -> record "sleep")
        ~finish:(fun _ _ symbol _ -> record ("finish:" ^ symbol))
        ~clock:(fun _ -> { Alpaca.timestamp =
            (if (!submitted || existing <> []) && cutoff then "2025-06-24T15:58:00-04:00"
             else "2025-06-24T15:45:00-04:00");
          is_open = true; next_open = "2025-06-25T09:30:00-04:00"; next_close = close })
        ~order_by_client_id:(fun _ id ->
          if (!submitted || existing <> []) && id = "bt-SPY-2025-06-24" then
            let () = record ("poll:" ^ sell_status) in
            Some (us_fixture_order "SPY" "sell" sell_status)
          else None)
        ~submit_market:(fun _ ~symbol ~qty:_ ~side ~client_order_id:_ ->
          let () = record ("post:" ^ symbol) in
          let () = submitted := true in
          us_fixture_order symbol (if side = `Sell then "sell" else "buy") "filled")
        Live.Paper date close decision) in
    List.rev !events, output
  in
  (* Sell POST and its filled poll precede the buy POST. *)
  let events, _ = run "filled" false [] decision in
  assert (events = ["post:SPY"; "poll:filled"; "post:QQQ";
    "finish:SPY"; "finish:QQQ"]);
  let events, output = run "accepted" true [] decision in
  (* Open sell at cutoff forbids QQQ; SPY still reaches the finish pass. *)
  assert (not (List.mem "post:QQQ" events));
  assert (List.mem "finish:SPY" events);
  assert (contains output "sell SPY open at cutoff");
  List.iter (fun status ->
    let events, output = run status false [] decision in
    assert (not (List.mem "post:QQQ" events));
    assert (contains output ("sell SPY " ^ status)))
    ["rejected"; "canceled"; "expired"; "stopped"];
  let single = { decision with Live.assets = [|decision.assets.(0)|] } in
  (* No mixed phases: N=1 posts once then finishes, without a sell-phase poll. *)
  let events, _ = run "accepted" false [] single in
  assert (events = ["post:SPY"; "finish:SPY"]);
  let existing = ["SPY", us_fixture_order "SPY" "sell" "accepted"] in
  let events, output = run "accepted" true existing decision in
  (* A restarted sell counts as a sell and blocks the remaining buy at cutoff. *)
  assert (not (List.mem "post:SPY" events || List.mem "post:QQQ" events));
  assert (contains output "sell SPY open at cutoff");
  let events, _ = run "filled" false existing decision in
  assert (not (List.mem "post:SPY" events));
  assert (List.mem "poll:filled" events && List.mem "post:QQQ" events);
  let events, _ = run "filled" false
    ["SPY", us_fixture_order "SPY" "buy" "accepted"] decision in
  (* An existing buy joins only the finish pass, never the sell-phase poll. *)
  assert (events = ["post:QQQ"; "finish:SPY"; "finish:QQQ"]);
  let buys = us_pair_decision [|action "SPY" `Buy; action "QQQ" `Buy|] in
  List.iter (fun broken_log ->
    let finished = with_us_finish_failure ~broken_log (fun finish ->
      Live.execute_decision
        ~order_by_client_id:(fun _ _ -> None)
        ~clock:(fun _ ->
          { Alpaca.timestamp = date ^ "T15:45:00-04:00"; is_open = true;
            next_open = "2025-06-25T09:30:00-04:00"; next_close = close })
        ~submit_market:(fun _ ~symbol ~qty:_ ~side:_ ~client_order_id:_ ->
          us_fixture_order symbol "buy" "filled")
        ~finish:(fun _ _ symbol _ -> finish symbol)
        Live.Paper date close buys) in
    (* Both known orders need reconciliation. A SPY lookup failure, and
       a failure logging it on broken stdout, must leave QQQ reachable. *)
    assert (finished = ["SPY"; "QQQ"])) [false; true]
```

- [ ] **Step 17: Add restart-routing checks at the `us_step` seam, including independent finish failures.** This tests the actual passed decision and existing-side list, not just callback counts. The existing-buy case is not a sell barrier, while the executor test above exercises an existing sell's actual polling. Both the all-done route and the cutoff error route must finish the second known symbol once even when the first finish or its error logger fails.

```ocaml
let test_us_pair_restart_routing () =
  let date = "2025-06-24" in
  let decision = us_pair_decision
    [|Live.Order { side = `Sell; qty = 1.; id = "bt-SPY-2025-06-24" };
      Live.Order { side = `Buy; qty = 1.; id = "bt-QQQ-2025-06-24" }|] in
  let clock : Alpaca.clock_t =
    { timestamp = date ^ "T15:45:00-04:00"; is_open = true;
      next_open = "2025-06-25T09:30:00-04:00"; next_close = date ^ "T16:00:00-04:00" } in
  let run both side =
    let decisions = ref 0 and finished = ref [] and executed = ref None in
    let order symbol = us_fixture_order symbol side "filled" in
    Live.us_step ~symbols:[|"SPY"; "QQQ"|]
      ~lookup:(fun id ->
        if id = "bt-SPY-2025-06-24" then Some (order "SPY")
        else if both then Some (order "QQQ") else None)
      ~decide:(fun _ -> let () = incr decisions in decision)
      ~execute:(fun existing _ d -> executed := Some (existing, d))
      ~finish:(fun _ _ id _ -> finished := id :: !finished)
      ~sleep_until:(fun _ -> ()) ~retry:(fun () -> assert false)
      ~continue:(fun () -> ()) clock;
    !decisions, !finished, !executed in
  List.iter (fun side ->
    let calls, finished, executed = run false side in
    assert (calls = 1 && finished = []);
    match executed with
    | None -> assert false
    | Some (existing, actual) ->
        (* One done symbol is dropped; the other planned action is unchanged. *)
        assert ((List.assoc "SPY" existing).Alpaca.side = side);
        assert (actual.Live.assets.(0).action = Live.Skip "existing order");
        assert (actual.assets.(1).action = decision.assets.(1).action))
    ["sell"; "buy"];
  let calls, finished, executed = run true "buy" in
  (* All done routes only to reconciliation, with no re-plan or execute. *)
  assert (calls = 0 && executed = None);
  assert (List.sort String.compare finished = ["bt-QQQ-2025-06-24"; "bt-SPY-2025-06-24"]);
  List.iter (fun broken_log ->
    List.iter (fun cutoff ->
      let finished = with_us_finish_failure ~broken_log (fun finish ->
        let symbols = if cutoff then [|"SPY"; "QQQ"; "DIA"|]
          else [|"SPY"; "QQQ"|] in
        let clock = if cutoff then
          { clock with Alpaca.timestamp = date ^ "T15:58:00-04:00" }
          else clock in
        Live.us_step ~symbols
          ~lookup:(fun id ->
            if id = "bt-SPY-2025-06-24" then
              Some (us_fixture_order "SPY" "buy" "filled")
            else if id = "bt-QQQ-2025-06-24" then
              Some (us_fixture_order "QQQ" "buy" "filled")
            else failwith "DIA order lookup unavailable")
          ~decide:(fun _ -> assert false)
          ~execute:(fun _ _ _ -> assert false)
          ~finish:(fun _ _ id _ ->
            finish (if id = "bt-SPY-2025-06-24" then "SPY" else "QQQ"))
          ~sleep_until:(fun _ -> ())
          ~retry:(fun () -> assert false)
          ~continue:(fun () -> ()) clock) in
      (* All-done or a failed third lookup at cutoff uses one finish pass.
         Failure of SPY's finish/error log cannot prevent QQQ's finish. *)
      assert (finished = ["SPY"; "QQQ"])) [false; true]) [false; true]
```

- [ ] **Step 18: Add CLI rejection tests and the TW startup guard.** These commands cannot reach a broker because all inputs fail validation before dispatch. Copy the existing temporary strategy/stderr command pattern. Test `Live.run` directly for the TW N>1 guard so it is exercised before any Shioaji call.

```ocaml
let test_live_pair_cli_guards () =
  let binary = locate ["_build/default/bin/bt.exe"; "../bin/bt.exe"] in
  let check source options expected =
    let stderr_path = Filename.temp_file "bt-live-guard-" ".txt" in
    Fun.protect ~finally:(fun () -> Sys.remove stderr_path) (fun () ->
      with_temp_strategy source (fun path ->
        let command = String.concat " "
          [Filename.quote binary; "target"; Filename.quote path; options;
           ">/dev/null"; "2>" ^ Filename.quote stderr_path] in
        let status = Sys.command command in
        assert (status <> 0);
        assert (contains (read_file stderr_path) expected);
        if expected = "live trading needs one market" then assert (status = 2))) in
  check "stock \"us/SPY\" as a\nstock \"tw/2330\" as b\na.target 0.5\nb.target 0.5\n"
    "" "live trading needs one market";
  check "stock \"us/SPY\" as a\nstock \"us/SPY\" as b\na.target 0.5\nb.target 0.5\n"
    "" "live trading needs distinct symbols: SPY";
  check "stock \"us/SPY\" as a\nstock \"us/QQQ\" as b\na.target 0.5\nb.target 0.5\n"
    "--provisional-close 100" "--provisional-close needs a one-stock strategy";
  with_temp_strategy
    "stock \"tw/2330\" as a\nstock \"tw/2890\" as b\na.target 0.5\nb.target 0.5\n"
    (fun strat_path ->
      match Live.run ~equity:100000. Live.Paper ~strat_path ~data_dir:"unused" with
      | () -> assert false
      | exception Failure message ->
          assert (message = "TW live trading needs one stock in this release"))
```

- [ ] **Step 19: Register all five new behavior checks and migrate existing injected decisions to the new API.** Update every `~tw_snapshot:x` to `~tw_snapshots:[|x|]`, including record-update expressions. Replace old decision asset accesses with `assets.(0)` accesses in the existing one-stock tests, while `equity`, `cash`, `debit`, and `fetched_through` stay at account level. Task 1's mature/drift pin uses `assets.(0).action` and also asserts that `decision.legs` equals the recorded legs; do not weaken its complete-leg equality.

```ocaml
  let () = test_live_history_gap () in
  let () = test_tw_live_pair_decide () in
  let () = test_us_pair_execution () in
  let () = test_us_pair_restart_routing () in
  let () = test_live_pair_cli_guards () in
```

There are five new named checks in this registration block; Task 5's two direct TW checks and Task 4's three US checks were already registered at their own gates.

#### Atomic cutover gate

- [ ] **Step 20: Run the GREEN gates and all six byte comparisons, then observe the injected runtime smoke.** The suite exercises real DSL compilation, cache loading, engine fills, jq parsing, scheduler routing and POST-order constraints. Use this exact stdin-only command to run the changed output function without CLI dispatch, a temporary source file, or broker calls. Compare its output with the account/symbol ordering below.

```text
fetched-through: 2025-06-23
equity: 1000
cash: 500
debit: 0
symbol: SPY
provisional-date: 2025-06-24
provisional-open: 100
provisional-high: 101
provisional-low: 99
provisional-close: 100
provisional-volume: 1000
target: 0.5
held: 5
action: order
side: sell
quantity: 1
client-order-id: bt-SPY-2025-06-24
symbol: QQQ
provisional-date: 2025-06-24
provisional-open: 100
provisional-high: 101
provisional-low: 99
provisional-close: 100
provisional-volume: 1000
target: 0.5
held: 5
action: order
side: buy
quantity: 1
client-order-id: bt-QQQ-2025-06-24
```

```sh
python3 - <<'PY' | opam exec --switch=/sandbox/stock -- ocaml -noinit -noprompt -I +unix -I /sandbox/stock-multi-stock/_build/default/market/.data.objs/byte -I /sandbox/stock-multi-stock/_build/default/engine/.engine.objs/byte -I /sandbox/stock-multi-stock/_build/default/series/.series.objs/byte -I /sandbox/stock-multi-stock/_build/default/lang/.lang.objs/byte -I /sandbox/stock-multi-stock/_build/default/broker/.broker.objs/byte unix.cma /sandbox/stock-multi-stock/_build/default/market/data.cma /sandbox/stock-multi-stock/_build/default/engine/engine.cma /sandbox/stock-multi-stock/_build/default/series/series.cma /sandbox/stock-multi-stock/_build/default/lang/lang.cma /sandbox/stock-multi-stock/_build/default/broker/broker.cma -stdin
from pathlib import Path
s = Path("/sandbox/stock-multi-stock/bin/bt.ml").read_text()
start = s.index("let print_decision ")
stop = s.index("\nlet live_command_args ", start)
print(s[start:stop] + ";;")
print(r'''
let date = "2025-06-24";;
let asset symbol side : Live.asset_decision =
  { symbol; provisional = { Data.date; o = 100.; h = 101.; l = 99.; c = 100.; v = 1000. };
    target = 0.5; held = 5.;
    action = Live.Order { side; qty = 1.; id = Live.client_order_id ~symbol ~date } };;
let decision : Live.decision =
  { fetched_through = "2025-06-23"; equity = 1000.; cash = 500.; debit = 0.;
    assets = [|asset "SPY" `Sell; asset "QQQ" `Buy|]; legs = [] };;
print_decision None decision;;
''')
PY
```

```sh
opam exec --switch=/sandbox/stock -- dune build --root .
opam exec --switch=/sandbox/stock -- dune runtest --root . --force
rg -n 'requires exactly one stock|requires exactly one planned asset|strategy must declare exactly one stock|tw_snapshot:' /sandbox/stock-multi-stock/broker /sandbox/stock-multi-stock/bin /sandbox/stock-multi-stock/test
```

Expected: dune and comparisons exit 0; obsolete runtime-message/label scan has no matches. Keep the intentionally temporary TW daemon one-stock guard, but delete every obsolete exactly-one decision/target/planned-asset arm.

- [ ] **Step 21: Commit only after coordinator review of the complete cutover.**

```sh
git -C /sandbox/stock-multi-stock add /sandbox/stock-multi-stock/broker/live.ml /sandbox/stock-multi-stock/broker/live.mli /sandbox/stock-multi-stock/bin/bt.ml /sandbox/stock-multi-stock/test/test_bt.ml
git -C /sandbox/stock-multi-stock commit -m "feat: trade US symbol sets through one live decision and sell barrier"
```

Commit only after the coordinator confirms; use the co-author trailer the coordinator names; never push; never change git settings.

### Task 7: Update stage 1 documentation and changelog

**Files:**

| Operation | Absolute path and section |
|---|---|
| Modify | `/sandbox/stock-multi-stock/docs/specs/live-trading.md`: account surface at 42/48, daily cycle, safety/logging, dated notes |
| Modify | `/sandbox/stock-multi-stock/docs/specs/tw-live-trading.md`: dated stage 1 decision note and snapshot description |
| Modify | `/sandbox/stock-multi-stock/docs/cli.md`: target options/output/prerequisites/failures and both live output sections |
| Modify | `/sandbox/stock-multi-stock/docs/engine.md`: US fidelity at 141-143, TW decision/account description at 211-214 |
| Modify | `/sandbox/stock-multi-stock/CHANGELOG.md`: `[Unreleased]` Added and Changed |

**Interfaces:**

| Direction | Contract |
|---|---|
| Consumes | Final public N-asset decision, symbol checks, joint normalization, US positions check and two-phase execution, one-stock TW runtime boundary |
| Produces | Stage 1 documentation only; no code change, no tag or release, no claim that TW FOK/batching/budget has shipped |
| Assignment | Coordinator assigns this task to the doc-editor; the editor uses executing-plans and dispatches nobody |

- [ ] **Step 1: Update US live design with a dated note and the positions-list surface.** Put this after the existing 2026-09-30 note. Replace the architecture client's "position for one symbol" with "per-symbol position quantities and the account positions list". Update the paper-account sentence to refer to all strategy holdings, and daily steps 4-7 to this shipped text.

```text
> [!NOTE]
> 2026-10-04: one strategy runs per account with N distinct symbols in one market; see [Design: multi-stock live trading](./multi-stock-live.md). One N-asset planner call sizes the session. The account debit is split in proportion to provisional-close position values, and the positions-list check rejects any symbol outside the strategy before the mark-tolerance check. When sells and buys coexist, every sell must reach `filled` before any buy is submitted. A rejected, canceled, expired, stopped, uncertain, or still-open-at-cutoff sell stops the buy phase.

4. Read account cash, long and short market values, every strategy symbol's held quantity, and the account positions list. Split negative cash across symbols in proportion to their provisional-close values and map each split into cash and margin inventory. Call `Engine.plan_fills` once for all N assets, using joint effective targets and US costs. Net ordinary buys and sells per symbol into fractional orders. Refinance pairs place no order. Keep the 9-decimal truncation, USD 1 buy minimum, held-quantity cap, and exact full-close rule.
5. Query every `bt-<symbol>-<YYYY-MM-DD>` client order ID before deciding. Existing symbols receive no new order. If all symbols are done, reconcile them without deciding. A partial restart re-plans all assets from current holdings, drops done symbols' actions, polls existing sells in the sell barrier, and follows existing buys in the finish pass.
6. Submit before `next_close - 2min`. With sells and buys, POST all sells, then poll every sell every 15 seconds until each is filled or the cutoff stops the session; only then POST buys, checking the clock before every request. A one-direction session keeps the original POST-then-finish path. Never retry a POST or any failure after a POST.
7. Follow known open orders after the close until terminal status or five minutes after close, then sleep to the next open. Log one account line and one symbol line per asset; an all-unchanged on_change session logs only the account/skip line.
```

Retain the buying-power/multiplier, ETF maintenance, paper dividend and unposted-interest caveats. Add the restart warning rather than suggesting that open orders are included in planner state.

```text
> [!WARNING]
> A partial restart plans from holdings and cash, not open orders. An unfilled order of a done symbol is invisible to that re-plan, so remaining symbols can be sized from cash the open order will spend. Symbol deduplication prevents resubmission but does not eliminate this buying-power gap.
```

- [ ] **Step 2: Update TW design for the N-asset decision only.** Do not change its implemented IOC order discipline, sequential execution steps, budget behavior or current no-fill independent-leg policy. Snapshot requests now use N contracts even though `run_tw` supplies one.

```text
> [!NOTE]
> 2026-10-04: stage 1 of [Design: multi-stock live trading](./multi-stock-live.md#stages) makes `bt target` decisions for N distinct TW codes in one market. It intersects history, checks the last five union sessions for gaps, compiles and normalizes targets jointly, aggregates account cash and debit, and plans all codes once. Snapshots are fetched in one request and matched by code. Code-tagged rollover pairs precede the phase-ordered ordinary legs. `bt live` still executes one TW code and rejects more with `TW live trading needs one stock in this release`. N-code execution, phase batching, FOK, contract info, trading limits and the budget pre-check ship in stage 2; this release keeps sequential `MKT` + `IOC` lot execution.
```

Replace the snapshot fact with:

```text
- Snapshot: `POST /api/v1/data/snapshots` takes one contract per requested code in `contracts` and returns snapshots with `code`, `datetime`, `open`, `high`, `low`, `close`, `buy_price`, `sell_price`, and `total_volume`. bt matches responses by code to declaration order and rejects missing, duplicate or extra codes.
```

- [ ] **Step 3: Replace the target output table and single-stock claims in CLI docs.** Target prerequisites at 214/252/314 accept N distinct symbols in one market. Live prerequisites at 404/421 accept N US symbols; replace TW's old "exactly one" at 480 with the explicit release guard, not an unsupported N-code execution claim. `--provisional-close` remains one-stock only, and live accounts may hold only symbols in the strategy.

```text
| Argument or option | Default | Description |
|---|---|---|
| `STRAT` | required | Read one daily strategy with N distinct US or TW symbols, all in one market. |
| `--data-dir DIR` | `data/` | Use that market's Tiingo or FinMind cache. |
| `--provisional-close PRICE` | - | Supply one positive price; requires a one-stock strategy and prints `provisional: override PRICE` first. |
| `-h`, `-help`, `--help` | - | Print target help and exit 0. |

Both markets print the account fields once, then one symbol block per stock in declaration order. Each block includes its existing market-specific action fields.

| Scope | Field | Meaning |
|---|---|---|
| Account | `provisional` | Optional `override PRICE` line, first. |
| Account | `fetched-through` | Last common historical session. |
| Account | `equity` | Equity passed to the planner, valued at provisional prices. |
| Account | `cash` | Free US cash or inferred/production TW spendable cash. |
| Account | `debit` | US account debit or summed TW loan principal. |
| Symbol block | `symbol` | Symbol/code that starts this block. |
| Symbol block | `provisional-date` | Current provisional session date. |
| Symbol block | `provisional-open` | Provisional open. |
| Symbol block | `provisional-high` | Provisional high. |
| Symbol block | `provisional-low` | Provisional low. |
| Symbol block | `provisional-close` | Provisional decision price. |
| Symbol block | `provisional-volume` | Provisional volume. |
| Symbol block | `target` | Jointly normalized effective target. |
| Symbol block | `held` | Shares currently held. |
| Symbol block | `action` | US `order` or `skip`; TW `orders`. |
```

Keep the existing `side`, `quantity`, `client-order-id`, `reason`, and `leg` output tables/forms. Replace the TW target simulation warning's one-stock wording with "the strategy's symbol set", and its cash description with the sum over all strategy positions. In the TW live prerequisites use:

```text
TW `bt target` supports N distinct codes. TW `bt live` still needs one code in this release and fails at startup with `TW live trading needs one stock in this release`; N-code TW execution belongs to stage 2.
```

- [ ] **Step 4: Document stage 1 errors and the joint history/planning policy.** Add this shared validation table to the target failure section, refer to it from live, and insert US check 3 before the existing long-market-value check. Preserve all four existing account failures.

```text
| Message | Effect |
|---|---|
| `live trading needs one market` | Mixed-market strategy is a usage error, exit 2. |
| `live trading needs distinct symbols: SYMBOL` | Repeated broker symbol fails the command, even under distinct aliases. |
| `--provisional-close needs a one-stock strategy` | A multi-stock override fails before broker calls. |
| `history gap in SYMBOL within the last 5 sessions` | Decision fails on the first declaration-ordered symbol missing a recent union date. US retries until cutoff; TW skips the day. |
| `US account holds unsupported symbol SYMBOL` | The positions list contains a foreign symbol; US retries until cutoff. |
| `TW live trading needs one stock in this release` | Multi-code TW daemon does not start in stage 1. |

History is loaded and freshness-checked per symbol. A gap in any of the last five dates of the union fails the decision; older gaps pass. Every symbol is filtered to the common dates, as `bt run` does, before its provisional bar is appended. The DSL compiler runs once with all assets, and `Engine.effective_targets` scales the final and previous target rows jointly. Under on_change, a symbol whose effective target is unchanged keeps its drift; when every symbol is unchanged, US skips before planning.

| US account check | Condition |
|---|---|
| `US account holds unsupported symbol SYMBOL` | An open position's symbol is outside the strategy; this check follows cash and short checks and precedes the long-market-value tolerance and positive-equity checks. |
```

The existing mark-tolerance row now compares `long_market_value` with the sum of all provisional-close holdings, not one stock's value.

- [ ] **Step 5: Replace daemon output and phase descriptions with the shipped formats.** Keep the UTC prefix, startup fields and lock caveats. Add the sell-stop table to US failure handling, and keep TW's IOC table at line 513 unchanged.

```text
US logs one account line, followed by one line per symbol:

date=DATE fetched-through=DATE equity=VALUE cash=VALUE debit=VALUE
date=DATE symbol=SYMBOL provisional-close=VALUE target=VALUE held=VALUE order=ORDER fill=pending

ORDER keeps SIDE:QUANTITY:CLIENT-ORDER-ID or skip:REASON. An all-unchanged on_change session logs only the account line with `order=skip:target unchanged`. Existing-order, fill and per-order error lines include `symbol=SYMBOL`. Client IDs remain `bt-SYMBOL-DATE`.

| US sell-phase stop | Result |
|---|---|
| `sell SYMBOL open at cutoff` | No buy POST; known open orders still enter the finish pass. |
| `sell SYMBOL STATE` | No buy POST when STATE is rejected, canceled, expired, stopped or uncertain. |

The US sell phase POSTs its sells, polls all of them every 15 seconds, and starts buys only after every sell reaches filled. It checks the clock before each POST. A session with no sell or no buy posts its orders before the finish pass, including the original one-order path. Existing sells on restart join the barrier; existing buys enter only the finish pass. No request is retried after a POST.

TW logs one account line followed by its one supported live symbol:

date=DATE fetched-through=DATE equity=VALUE cash=VALUE debit=VALUE submitted=OUTCOME
date=DATE symbol=CODE provisional-close=VALUE target=VALUE cash-shares=VALUE margin-shares=VALUE loan=VALUE planned-legs=LEGS

OUTCOME remains complete, skip:no-order-legs, skip:existing-orders, or stop:REASON remaining:LEGS. In an existing-orders skip, cash/debit and per-symbol values not evaluated that day print `-`; equity is the startup equity, as before. Each TW trade line includes `code=CODE`. `custom_field` remains `btMMDD`. Lot execution stays sequential MKT+IOC and odd lots stay LMT+ROD in stage 1.
```

- [ ] **Step 6: Update engine fidelity text without altering engine contracts.** Replace the one-stock US paragraph with the N-state description; qualify TW's symbol-set description for `bt target` versus the guarded daemon. Keep TW IOC/FOK sentences unchanged in this stage.

```text
Under on_change, the US daemon preserves each unchanged effective target's drift and skips before planning when all targets are unchanged. Otherwise one `Engine.plan_fills` call plans N assets with Alpaca's cash and provisional-close holdings. The account debit is split in proportion to position value, with equal splits when total value is zero, into each asset's margin lot. The account positions list rejects foreign holdings before the existing 1% mark-tolerance check. Net ordinary buys and sells become one fractional order per symbol; refinance pairs place no order. Sells must fill before buys in mixed sessions. USD 1 buy minimums, 9-decimal truncation, and unavailable unposted interest remain fidelity gaps.

TW `bt target` supports the strategy's entire symbol set: simulation cash is equity minus summed cash and margin values plus summed loans and interests; production equity uses those sums and the verified spendable cash. Any active code outside the set fails the decision. The TW daemon still supports one code in stage 1, with its existing sequential IOC lot executor. The N-code decision leg list is rollover pairs followed by margin sells, cash sells, refinance pairs, cash buys, and margin buys.
```

- [ ] **Step 7: Add stage 1 entries under `[Unreleased]`, preserving the prior US live planner entries and historical release sections.** The new positions-list check is its own Changed entry, even at N=1. Do not claim phase batching, FOK, budgets or suspension checks have shipped.

```text
### Added

- Multi-stock US live trading in one market, with one joint decision and fill plan for all strategy symbols. TW `bt target` also plans N codes; TW `bt live` remains one-code in this release.
- Shared live decisions reject mixed markets, duplicate symbols, multi-stock provisional-price overrides, and history gaps in the last five union sessions.

### Changed

- `bt target` prints account fields once followed by declaration-ordered symbol blocks. US and TW daemon logs separate account and symbol lines.
- US live executes sells before buys in mixed sessions and stops the buy phase unless every sell fills before the cutoff. Restart deduplication routes existing sells to the sell barrier and existing buys to the finish pass.
- US decisions check the account positions list before the existing market-value tolerance, rejecting every symbol outside the strategy with `US account holds unsupported symbol SYMBOL`, including for one-stock strategies.
```

- [ ] **Step 8: Run GREEN gates and six comparisons, then inspect stage boundaries and Contents.** No paper account command belongs to this task.

```sh
opam exec --switch=/sandbox/stock -- dune build --root .
opam exec --switch=/sandbox/stock -- dune runtest --root . --force
rg -n 'exactly one|one-stock|FOK|IOC|positions list|stage 2|history gap|symbol=' /sandbox/stock-multi-stock/docs/cli.md /sandbox/stock-multi-stock/docs/engine.md /sandbox/stock-multi-stock/docs/specs/live-trading.md /sandbox/stock-multi-stock/docs/specs/tw-live-trading.md /sandbox/stock-multi-stock/CHANGELOG.md
```

Expected: remaining one-stock statements describe only the TW runtime guard, the single-price override, historical releases or historical notes; IOC remains the shipped TW executor. Every newly added heading is in that file's full-depth Contents.

- [ ] **Step 9: Commit only after coordinator review.**

```sh
git -C /sandbox/stock-multi-stock add /sandbox/stock-multi-stock/docs/specs/live-trading.md /sandbox/stock-multi-stock/docs/specs/tw-live-trading.md /sandbox/stock-multi-stock/docs/cli.md /sandbox/stock-multi-stock/docs/engine.md /sandbox/stock-multi-stock/CHANGELOG.md
git -C /sandbox/stock-multi-stock commit -m "docs: describe stage one multi-stock decisions and US execution"
```

Commit only after the coordinator confirms; use the co-author trailer the coordinator names; never push; never change git settings.

## Coordinator acceptance after the branch

This is not an offline implementer task. Only the coordinator performs broker-facing acceptance after every task and offline gate has passed. Do not tag v0.12.0 before both acceptance records pass.

| Acceptance | Coordinator action and evidence |
|---|---|
| Pair strategy | Create `/sandbox/research/strategies/us/paper_pair_probe/main.strat` with TQQQ/QQQ aliases, `rebalance daily`, targets 0.2/0.8. Paper account holds no other symbol. |
| Three sessions | Run paper sessions at 0.2/0.8, then 0.25/1.0 for one session, then 0.3/0.7. Before each decision inspect broker-backed `bt target` account lines and one block per symbol. |
| Exposure | Compute `(held + signed quantity) * provisional close / equity` per symbol from the decision. Once a later session is cached, run `/sandbox/stock-multi-stock/_build/default/bin/bt.exe run /sandbox/research/strategies/us/paper_pair_probe/main.strat --capital 100000 --fill close --data-dir /sandbox/stock/data --out-dir /sandbox/stock-multi-stock/out/paper_pair_probe --no-plot` on cached bars. Compare the ordinary session-date `stock=us/TQQQ` and `stock=us/QQQ` trade rows' `to_exposure` to four decimals; exclude refinance equal-exposure rows and final liquidation rows on the later cached date. |
| Sell barrier | Third-session order records must show QQQ sell `filled_at` before TQQQ buy `submitted_at`. |
| Debit | Session after the 1.25 fill prints `cash: 0`; `debit` equals summed holdings at provisional prices minus equity, around 0.25 times equity. If ETF maintenance liquidates a position in between, repeat; the spec computes about 0.4875 times equity requirement for the pair. |
| Existing US planner gate | Separately complete `docs/specs/us-live-planner.md#acceptance` at 0.2, 1.25, 0.2 on `/sandbox/research/strategies/us/paper_probe/main.strat`. Do not copy the reference plan's obsolete 1.5 acceptance instruction; the committed spec says 1.25. |
| Stage boundary | No TW production acceptance, limit probe, FOK order, or budget measurement is part of this branch. These belong to stage 2. |

```text
stock "us/TQQQ" as tqqq
stock "us/QQQ" as qqq
rebalance daily
tqqq.target 0.2
qqq.target 0.8
```

## Self-Review

| Review | Result |
|---|---|
| Stage 1 specification coverage | Tasks 1-6 cover all shared/US requirements and the TW N-decision boundary. Task 7 covers all stage 1 documentation. Coordinator acceptance preserves both v0.12.0 release gates. No stage 1 requirement is unmapped. |
| One-stock invariance | Task 1 executes the pins before refactoring; Task 4 retains byte-exact scalar state values and all US fractional/order/limit expectations; Tasks 5-6 only migrate record fields, labels and asset access for the pins. Positions-list check is the sole stage 1 accepted N=1 behavior change. |
| Data/compiler parity | Task 2 retains the exact intersection body and both backtest callers. Task 6 checks gaps on the last five union dates, filters before appending, compiles once, normalizes both rows jointly, and sets fetched-through to last common date. |
| US tests | Debit split, N=1 state bytes, account check precedence, foreign symbols, cash/levered/cross-asset refinance parity, sell terminal/cutoff barrier, one-order path, partial/all-done restart and parser side are mapped to concrete assert functions and main registrations. Executor finishing, all-done reconciliation, and cutoff-error reconciliation each assert that a failed first finish or failed per-order error log still reaches the second known order once. Existing uncertain/rejected/preflight/cutoff tests remain. |
| TW stage 1 tests | Two-code legs, position set, code-matched snapshots, and injected `Live.decide` aggregate/scaling/previous-row/rollover assembly are concrete checks. TW executor batching, FOK and budget tests are intentionally excluded. |
| Output/guards | Shared output and daemon formats are implemented; mixed market is usage exit 2; duplicate symbol and multi-stock override fail before broker calls; TW N>1 daemon is guarded before lock/server calls. |
| Placeholder scan | No unfinished implementation marker or absent named helper. Every code step supplies real code or exact field/call migration; command-only gates state expected outcomes. |
| Type consistency | Both decision declarations use `assets` and `legs`; each asset owns its symbol/provisional/target/held/action. US arrays share declaration order. TW snapshot parse returns request-ordered arrays; legs carry code/exchange; planner and routing signatures are defined before consumption. Scalar compatibility exports are removed. |
| Snippet proof | In-memory OCaml projections against the actual built libraries typechecked the new broker, planner, decision and executor snippets. Pure debit/byte-state, foreign-symbol, N-asset Engine.run parity, history gap, TW leg/set, US phase/restart and independently planned drift-quantity checks exited 0. No source file was generated or implementation file edited. This is scoped plan-example verification, not a project build or the final implementation gate. |
| Finish-isolation review | Task 6 Steps 11-12 catch each order's finish error and guard its error log inside the iterator; the cutoff handler invokes that safe reconcile once. Steps 16-17 exercise a first-order finish failure with both working and broken stdout in executor, all-done, and cutoff-error routes; each asserts SPY then QQQ exactly once. The scoped in-memory OCaml projection typechecked and executed both updated test functions with exit 0 and `FINISH_SIBLING_REVIEW_CHECKS_OK`. No interface change or new stage 1 coverage gap. |
| Verification scope | This plan-writing assignment runs no build, full suite, formatter, broker call, staging or commit. Implementers run RED/GREEN gates, actual injected scenarios, the output smoke, and the six pinned CLI byte comparisons. Coordinator owns reviews and real paper acceptance. |

| Spec Tests table rows | Stage 1 mapping |
|---|---|
| Pins; 1; 2; 13 | Tasks 1 and 4 |
| 3 | Tasks 2 and 6 |
| 4; 6 | Task 5 |
| 7; US parts of 12 | Task 3 |
| 8; 9; 11; 15 | Task 6 |
| 5; 10; TW contract/limits parts of 12; 14 | Stage 2, excluded explicitly |

