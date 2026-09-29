# Rebalance Statement Implementation Plan

> **For the coordinator:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development (recommended) or superpowers:executing-plans; implement this plan task-by-task and track its `- [ ]` steps.

Implementers use executing-plans only. No subagents: never dispatch a reviewer or any other agent; the coordinator owns reviews.

**Goal:** Make one strategy-file rebalance declaration govern backtests, `bt target`, and both live decision paths, while undeclared files retain change-only behavior and warn.

**Architecture:** Parse the declaration into `Ast.Rebalance of bool` and extract it with `Dsl.rebalance_of ~filename`. Thread the bool into the engine's existing fill gates and TW planner; gate the US order action by the previous effective target without replacing US sizing. Keep intraday trading separate.

**Tech Stack:** OCaml, ocamllex, ocamlyacc, dune, assert-based `test/test_bt.ml`, opam local switch.

## Global Constraints

- Implement the approved contract in `docs/specs/rebalance-statement.md`; do not add dependencies, drift bands, US `plan_fills` integration, multi-stock live support, or broker margin-call automation.
- `Dsl.rebalance_of ~filename : Ast.stmt list -> bool option` yields `Some true` for `daily`, `Some false` for `on_change`, and `None` for absent; an absent declaration means on_change. The filename is needed for the two exact errors.
- `Engine.run` requires `~rebalance:bool`; `Live.decide` retains its signature and reads the strategy itself. The unchanged US action is exactly `Skip "target unchanged"`.
- Preserve the existing `bt run` bars rejection, and reject `bars` plus `rebalance` with `<file>: rebalance applies to daily strategies only` before that rejection. `bt daytrade` must reject this combination too.
- Warnings have exact text `warning: <file> does not declare rebalance; trading only when the target changes`; `bt run` and `bt target` use stderr only, once per undeclared strategy file; `bt live` uses the timestamped `Live.log` once, immediately after startup.
- Keep the two research strategies `/sandbox/research/strategies/us/dd_ladder/main.strat` and `/sandbox/research/strategies/tw/channel_ladder/main.strat` undeclared. Do not edit them or their baselines.
- No network calls or live broker execution in verification. Use local test fixtures only. Never invoke `bt live` or `bt target` against a broker.
- Follow `CONTRIBUTING.md`: ASCII, one space around `=`, no alignment spaces, no `for`/`while` loops, tail-recursive list traversals, warnings as errors, no floating-point reorder. Market branches use `match` arms and a default arm per `AGENTS.md`.
- New assertions belong in `test/test_bt.ml` and are registered in its final `let ()` list. Use its `assert_close`, `assert_failure`, `with_temp_strategy`, `with_temp_market`, live injection, and CLI capture patterns.
- Coordinator owns reviews; implementers never dispatch another agent. Task 7 is documentation/editorial work: the coordinator assigns it to the doc-editor agent. Implementers use executing-plans only.
- Every task's GREEN gate runs `opam exec --switch=/sandbox/stock -- dune build --root .` and `opam exec --switch=/sandbox/stock -- dune runtest --root . --force`, both with exit code 0. After any engine or CLI change, also run the six byte comparisons below. Running them after every task is acceptable and is prescribed in the task gates.
- For each byte gate, create fresh output directories and run these exact strategy/baseline/capital combinations. `cmp` of each of stdout, equity CSV, and trades CSV must exit 0; the undeclared warning may only appear on stderr:

```sh
us_out=$(mktemp -d)
tw_out=$(mktemp -d)
./_build/default/bin/bt.exe run /sandbox/research/strategies/us/dd_ladder/main.strat --baseline us/TQQQ --capital 100000 --data-dir data --out-dir "$us_out" --out-name fp --no-plot > "$us_out/stdout.txt"
cmp "$us_out/stdout.txt" .superpowers/sdd/us-paper-test/us-baseline/stdout.txt
cmp "$us_out/fp.csv" .superpowers/sdd/us-paper-test/us-baseline/fp.csv
cmp "$us_out/main.trades.csv" .superpowers/sdd/us-paper-test/us-baseline/main.trades.csv
./_build/default/bin/bt.exe run /sandbox/research/strategies/tw/channel_ladder/main.strat --baseline tw/00685L --capital 1000000 --data-dir data --out-dir "$tw_out" --out-name fp --no-plot > "$tw_out/stdout.txt"
cmp "$tw_out/stdout.txt" .superpowers/sdd/us-paper-test/tw-baseline/stdout.txt
cmp "$tw_out/fp.csv" .superpowers/sdd/us-paper-test/tw-baseline/fp.csv
cmp "$tw_out/main.trades.csv" .superpowers/sdd/us-paper-test/tw-baseline/main.trades.csv
```

- The above directories are generated artifacts, not repository edits. At every commit step: **Commit only after the coordinator confirms; use the co-author trailer the coordinator names; never push; never change git settings.** This planning assignment itself stages and commits nothing.

---

### Task 1: DSL declaration and validation

**Files:**
- Modify: `lang/lexer.mll:4-19` (keyword mapping; leave `-` and identifier rules alone)
- Modify: `lang/parser.mly:5-14,40-60`
- Modify: `lang/ast.ml:8-18`, `lang/ast.mli:10-19`
- Modify: `lang/dsl.ml:459-469,533-596`, `lang/dsl.mli:1-8`
- Test: `test/test_bt.ml:129-185,7476-7532`

**Interfaces:**
- Consumes: `Ast.stmt list`, `Dsl.parse_file : string -> Ast.file`, `Dsl.timeframe : Ast.file -> int option`.
- Produces: `Ast.Rebalance of bool`; `Dsl.rebalance_of ~filename : Ast.stmt list -> bool option` with the exact two filename-prefixed `Failure` messages.

- [ ] **Step 1 (RED): Add the DSL behavior test and register it after `test_parser ()`.** Parse through a temporary file so the actual filename is checked. This test also pins keyword reservation and the `bars` conflict, not just a hand-built AST.

```ocaml
let test_rebalance_declaration () =
  let check source expected =
    with_temp_strategy source (fun path ->
      assert (Dsl.rebalance_of ~filename:path (Dsl.parse_file path) = expected))
  in
  check "stock \"tw/0050\"\nrebalance daily\ntarget 1.0\n" (Some true);
  check "stock \"tw/0050\"\nrebalance on_change\ntarget 1.0\n" (Some false);
  check "stock \"tw/0050\"\ntarget 1.0\n" None;
  let rejects source suffix =
    with_temp_strategy source (fun path ->
      match Dsl.rebalance_of ~filename:path (Dsl.parse_file path) with
      | _ -> assert false
      | exception Failure message -> assert (message = path ^ suffix))
  in
  rejects "rebalance daily\nrebalance on_change\n"
    ": duplicate rebalance declaration";
  rejects "stock \"us/SPY\"\nbars 5m\nrebalance daily\ntarget 1.0\n"
    ": rebalance applies to daily strategies only";
  with_temp_strategy "rebalance on-change\n" (fun path ->
    assert_failure (fun () -> ignore (Dsl.parse_file path)))
```

```ocaml
  test_parser ();
  test_rebalance_declaration ();
  test_default_costs ();
```

- [ ] **Step 2 (RED): Run the focused test executable before implementing the DSL.**

```sh
opam exec --switch=/sandbox/stock -- dune runtest --root . --force
```

Expected: the test does not compile because `Dsl.rebalance_of` is not exported yet (and `Ast.Rebalance` is absent).

- [ ] **Step 3 (GREEN): Add tokens, parser productions, and the constructor to both AST type declarations.** Insert `Rebalance` after `Bars` in both `.ml` and `.mli`; the lexer identifiers already include `_` and cannot include `-`.

```ocaml
(* lang/lexer.mll, inside let keyword = function *)
  | "rebalance" -> REBALANCE
  | "daily" -> DAILY
  | "on_change" -> ON_CHANGE
```

```ocaml
/* lang/parser.mly, token declarations and stmt alternatives */
%token REBALANCE DAILY ON_CHANGE
```

```ocaml
| REBALANCE DAILY { Rebalance true }
| REBALANCE ON_CHANGE { Rebalance false }
```

```ocaml
(* lang/ast.ml and lang/ast.mli, after Bars of int *)
  | Rebalance of bool
```

- [ ] **Step 4 (GREEN): Export and implement validation, and make compilation ignore the metadata statement.** Detect duplicates while folding, then the `Bars _` conflict. In `compile_ast` extend the existing metadata arm; in `compile`, validate immediately after `parse_file` so its direct-file API rejects conflicting declarations too.

```ocaml
(* lang/dsl.mli *)
(** Return the daily rebalance choice, or [None] for change-only files.
    Duplicate declarations and use with [bars] name [filename]. *)
val rebalance_of : filename:string -> Ast.stmt list -> bool option
```

```ocaml
(* lang/dsl.ml, beside timeframe *)
let rebalance_of ~filename statements =
  let chosen =
    List.fold_left
      (fun chosen -> function
        | Rebalance value ->
            (match chosen with
             | None -> Some value
             | Some _ ->
                 failwith
                   (Printf.sprintf "%s: duplicate rebalance declaration" filename))
        | _ -> chosen)
      None statements
  in
  let () =
    if chosen <> None
       && List.exists (function Bars _ -> true | _ -> false) statements
    then failwith
      (Printf.sprintf "%s: rebalance applies to daily strategies only" filename)
  in
  chosen
```

```ocaml
(* existing compile_ast statement match: replace the last two arms *)
        | Bars _ ->
            let () = ignore (timeframe statements) in
            environment
        | Stock _ | Rebalance _ -> environment)
```

```ocaml
(* existing Dsl.compile, immediately after let ast = parse_file source in *)
  let () = ignore (rebalance_of ~filename:source ast) in
```

- [ ] **Step 5 (GREEN): Run all three shared gates.** The research strategies remain undeclared, so this task cannot alter their output.

```sh
opam exec --switch=/sandbox/stock -- dune build --root .
opam exec --switch=/sandbox/stock -- dune runtest --root . --force
```

Then execute the six exact `cmp` commands and their two `bt.exe run` commands in Global Constraints. Expected: both dune commands and all six comparisons exit 0.

- [ ] **Step 6: Commit this DSL slice only after confirmation.**

```sh
git add lang/lexer.mll lang/parser.mly lang/ast.ml lang/ast.mli lang/dsl.ml lang/dsl.mli test/test_bt.ml
git commit -m "feat: parse rebalance declarations"
```

Commit only after the coordinator confirms; use the co-author trailer the coordinator names; never push; never change git settings.

### Task 2: Engine fill cadence and CLI callsites

**Files:**
- Modify: `engine/engine.ml:983-986,2111-2117,2122-2153`
- Modify: `engine/engine.mli:168-181`
- Modify: `bin/bt.ml:288-300,415-477,480-505,585-596,656-665`
- Test: `test/test_bt.ml:267-385,4035-4120,7476-7696` (migrate every existing `Engine.run` call, retaining every assertion)

**Interfaces:**
- Consumes: `Dsl.rebalance_of ~filename : Ast.stmt list -> bool option`, `Engine.plan_fills ~force:bool`, `Engine.effective_targets`.
- Produces: required `Engine.run ~rebalance:bool` in both engine files and all callers. A run strategy uses `Option.value (Dsl.rebalance_of ~filename:path ast) ~default:false`; the report baseline and intraday baseline use false.

- [ ] **Step 1 (RED): Add a constant-target, two-bar drift test for the close-fill mode and both policies.** On the second bar the position moves from 0.5 to 0.55 at a 10% rise while equity moves from 1 to 1.05; a daily reset sells value 0.025 at that bar's close. The cure test below separately exercises the open-price cure followed by the close-fill pass.

```ocaml
let test_engine_rebalance_constant () =
  let bars =
    [| bar "2020-01-01" 100. 100.;
       bar "2020-01-02" 110. 110. |]
  in
  let run rebalance =
    Engine.run ~rebalance ~profile:tw_profile [| "tw/TEST", bars |]
      { Engine.targets = [| [| 0.5; 0.5 |] |] } [| zero_costs |]
      ~margin:(no_margin 1) ~capital:1. ~fill:Engine.Close_same
  in
  let changes result =
    List.filter
      (fun (fill : Engine.fill_event) -> fill.date = "2020-01-02"
        && fill.from_e <> 0. && fill.to_e <> 0.)
      result.Engine.fills
  in
  (* Value 0.55 divided by equity 1.05 exceeds target 0.5. *)
  let () = assert (changes (run false) = []) in
  match changes (run true) with
  | [fill] ->
      assert_close (0.55 /. 1.05) fill.Engine.from_e;
      assert_close 0.5 fill.Engine.to_e
  | _ -> assert false
```

- [ ] **Step 2 (RED): Add the levered margin-call regression and register both tests in the engine portion of main.** Three bars at 10, 6.5, 6.5, TW 60% financing and target 1.9 trigger a collateral/loan breach on the middle close and liquidation of margin inventory on the last open. The last bar's daily fill buys back toward the initial-margin-safe target; change-only does not. Check the buy direction, not merely fill count.

```ocaml
let test_engine_rebalance_after_cure () =
  let bars =
    [| bar "2020-01-02" 10. 10.;
       bar "2020-01-03" 6.5 6.5;
       bar "2020-01-06" 6.5 6.5 |]
  in
  let margin : Engine.margin =
    { financing_rate = 0.; maintenance_override = None;
      ratios = [| 0.6 |]; loan_term_months = None }
  in
  let run rebalance =
    Engine.run ~rebalance ~profile:tw_profile [| "tw/TEST", bars |]
      { Engine.targets = [| [| 1.9; 1.9; 1.9 |] |] }
      [| zero_costs |] ~margin ~capital:1. ~fill:Engine.Close_same
  in
  let rebuys result =
    List.filter
      (fun (fill : Engine.fill_event) ->
        fill.date = "2020-01-06" && fill.to_e > fill.from_e)
      result.Engine.fills
  in
  let unchanged = run false in
  let daily = run true in
  (* Entry splits into cash value 0.4 and margin value 1.5, with loan 0.9.
     At 6.5, margin value 0.975 / loan 0.9 = 1.0833, below TW's 1.3;
     the next-open liquidation leaves cash inventory and repaid debt. *)
  assert (unchanged.Engine.margin_stats.margin_call_dates = ["2020-01-03"]);
  assert (daily.Engine.margin_stats.margin_call_dates = ["2020-01-03"]);
  assert (rebuys unchanged = []);
  match rebuys daily with
  | [fill] -> assert_close ~tolerance:1e-8 1.9 fill.Engine.to_e
  | _ -> assert false
```

```ocaml
  test_engine_drift ();
  test_engine_rebalance_constant ();
  test_engine_rebalance_after_cure ();
  test_inventory_split ();
```

- [ ] **Step 3 (RED): Run the test executable.** Before changing the signature this fails compilation at `~rebalance`.

```sh
opam exec --switch=/sandbox/stock -- dune runtest --root . --force
```

- [ ] **Step 4 (GREEN): Require the engine argument and change both fill gates, not `plan_fills`.** The open mode retains its `t > 0` guard, and both modes retain bankruptcy guards. The `rebalance=false` conditions and `cash_landed` force are structurally identical to today.

```ocaml
(* engine/engine.mli, insert before result *)
  rebalance:bool ->
```

```ocaml
(* engine/engine.ml, add to run's final labelled arguments *)
    ~capital:(capital : float) ~fill ~rebalance =
```

```ocaml
(* Close_same fill gate *)
                  if rebalance || cash_landed || differs eff then
                    apply_fills ~bar_index:t ~date ~eff ~clamped
                      ~force:(rebalance || cash_landed) (fun i -> close_at i t)
```

```ocaml
(* Open_next fill gate; scheduled remains `differs eff` *)
                  if not !bankrupt && (rebalance || cash_landed || scheduled) then
                    apply_fills ~bar_index:t ~date ~eff ~clamped
                      ~force:(rebalance || cash_landed) (fun i -> open_at i t)
```

- [ ] **Step 5 (GREEN): Thread `~rebalance` through every production caller.** In `bt run`, validate rebalance before the bars rejection, derive it from each already-loaded `input.ast` and its original path (add `path : string` to `strategy_input` and set it in the existing `inputs` record), and leave the two baselines change-only. In `bt daytrade`, validate the bars conflict after parsing and before `Dsl.timeframe`; its intraday engine is separate, but its daily baseline uses `Engine.run ~rebalance:false`.

```ocaml
(* bin/bt.ml, strategy_input *)
  path : string;
```

```ocaml
(* bin/bt.ml, run's parsed mapper after let ast = Dsl.parse_file path in *)
        let () = ignore (Dsl.rebalance_of ~filename:path ast) in
        let () =
          if List.exists (function Ast.Bars _ -> true | _ -> false) ast then
            failwith "day trading strategies run under bt daytrade"
        in
        let stocks = Dsl.stocks_of ~filename:path ast in
        (path, name, ast, stocks, Dsl.declared_params_ast ast))
```

```ocaml
(* bin/bt.ml, all_markets mapper: replace its pattern only *)
      (fun (_, _, _, stocks, _) ->
        List.map (fun (_, market, _) -> market) stocks)
```

```ocaml
(* bin/bt.ml, inputs mapper: replace its pattern only *)
      (fun (path, name, ast, stocks, declarations) ->
        let assets =
          List.map
            (fun (_, market, symbol) -> load_cached ~market ~symbol)
            stocks
        in
        { path; name; stocks; ast; declarations; assets })
```


```ocaml
(* bin/bt.ml, strategy result call *)
          Engine.run ~dividends
            ~dividend_tax:(!dividend_tax /. 100.)
            engine_assets strategy costs
            ~profile ~margin:margin_config ~capital ~fill:!fill
            ~rebalance:(Option.value
              (Dsl.rebalance_of ~filename:input.path input.ast)
              ~default:false)
```

```ocaml
(* bin/bt.ml, both baseline Engine.run calls, before the final `)` *)
             ~capital ~fill:!fill ~rebalance:false)
```

```ocaml
(* bin/bt.ml, daytrade mapper after let ast = Dsl.parse_file path in *)
    let () = ignore (Dsl.rebalance_of ~filename:path ast) in
```

- [ ] **Step 6 (GREEN): Migrate every existing `Engine.run` call in `test/test_bt.ml` to `~rebalance:false`, including `run_single`, without changing its assertions.** Use a callsite inventory to make omission visible, then append the label to each existing call's terminal labelled-argument line. Do not change `Engine.plan_fills` calls.

```sh
rg -n 'Engine\.run' bin/bt.ml test/test_bt.ml
```

```ocaml
(* test/test_bt.ml: run_single, with existing argument order preserved *)
  Engine.run ~profile:tw_profile [| ("tw/TEST", bars) |]
    { Engine.targets = [| target |] }
    [| costs |] ~margin:(no_margin 1) ~capital ~fill ~rebalance:false
```

- [ ] **Step 7 (GREEN): Run build, full suite, and all six byte comparisons in Global Constraints.** Every command must exit 0; the old test assertions and undeclared research baselines must remain unchanged.

```sh
opam exec --switch=/sandbox/stock -- dune build --root .
opam exec --switch=/sandbox/stock -- dune runtest --root . --force
```

- [ ] **Step 8: Commit the engine slice only after confirmation.**

```sh
git add engine/engine.ml engine/engine.mli bin/bt.ml test/test_bt.ml
git commit -m "feat: apply declared rebalance cadence in backtests"
```

Commit only after the coordinator confirms; use the co-author trailer the coordinator names; never push; never change git settings.

### Task 3: CLI warnings on run and target

**Files:**
- Modify: `bin/bt.ml:288-300,792-827`
- Test: `test/test_bt.ml:1884-1905,3824-3848,7476-7696`

**Interfaces:**
- Consumes: `Dsl.rebalance_of ~filename : Ast.stmt list -> bool option`; `Live.decide` remains unchanged.
- Produces: exact `warning: <file> does not declare rebalance; trading only when the target changes` on stderr for `bt run` and `bt target`, never stdout. `bt run` evaluates each file separately.

- [ ] **Step 1 (RED): Add a CLI test for the actual `bt run` binary with a local TW cache.** Reuse `with_temp_market`; redirect stdout and stderr to separate files. Compare an undeclared run with an explicit `rebalance on_change` run: stdout must be byte-equal, and only the undeclared run warns. The output names must match so the printed report is identical.

```ocaml
let test_rebalance_cli_warning () =
  with_temp_market "tw" (fun data_dir tw_dir ->
    let stock_dir = Filename.concat tw_dir "AA" in
    let () = Unix.mkdir stock_dir 0o700 in
    let write path text =
      let output = open_out path in
      Fun.protect ~finally:(fun () -> close_out output)
        (fun () -> output_string output text)
    in
    write (Filename.concat stock_dir "AA.csv")
      "date,open,high,low,close,volume\n2020-01-01,100,100,100,100,1000\n2020-01-02,100,100,100,100,1000\n";
    write (Filename.concat stock_dir "AA.div.csv") "date,factor\n";
    write (Filename.concat stock_dir "AA.events.csv") "date,factor\n";
    write (Filename.concat stock_dir "AA.cashdiv.csv")
      "ex_date,cash_per_share,pay_date\n";
    let binary = locate ["_build/default/bin/bt.exe"; "../bin/bt.exe"] in
    let run path label =
      let stdout_path = Filename.concat data_dir (label ^ ".stdout") in
      let stderr_path = Filename.concat data_dir (label ^ ".stderr") in
      let command =
        String.concat " "
          [Filename.quote binary; "run"; Filename.quote path;
           "--capital"; "100000"; "--financing-ratio"; "60";
           "--data-dir"; Filename.quote data_dir;
           "--out-dir"; Filename.quote data_dir; "--out-name"; "same";
           "--no-plot"; ">" ^ Filename.quote stdout_path;
           "2>" ^ Filename.quote stderr_path]
      in
      assert (Sys.command command = 0);
      read_file stdout_path, read_file stderr_path
    in
    let strategy = Filename.concat data_dir "same.strat" in
    let write_strategy text = write strategy text in
    write_strategy "stock \"tw/AA\"\ntarget 0.5\n";
    let implicit_stdout, implicit_stderr = run strategy "implicit" in
    write_strategy "stock \"tw/AA\"\nrebalance on_change\ntarget 0.5\n";
    let explicit_stdout, explicit_stderr = run strategy "explicit" in
    (* Both strategies have the same basename and target, so report bytes match. *)
    assert (implicit_stdout = explicit_stdout);
    assert (explicit_stderr = "");
    assert
      (implicit_stderr =
       Printf.sprintf
         "warning: %s does not declare rebalance; trading only when the target changes\n"
         strategy))
```

```ocaml
  test_rebalance_cli_warning ();
  test_capital_required ();
```

- [ ] **Step 2 (RED): Run the test; the missing-warning assertion must fail.** No `bt target` or `bt live` invocation is permitted in this offline test because either would contact a broker.

```sh
opam exec --switch=/sandbox/stock -- dune runtest --root . --force
```

- [ ] **Step 3 (GREEN): Print once per undeclared input in `run` before loading assets, and once before the market decision in `target`.** For `target`, parse the file again locally after `live_command_args`; that parser currently returns no AST, and no new public live signature is warranted. Continue to use the existing `match market` with its `_` arm.

```ocaml
(* bin/bt.ml, inside run's List.map2, after the rebalance validation *)
        let () =
          if Dsl.rebalance_of ~filename:path ast = None then
            Printf.eprintf
              "warning: %s does not declare rebalance; trading only when the target changes\n"
              path
        in
```

```ocaml
(* bin/bt.ml, target, immediately after live_command_args *)
  let ast = Dsl.parse_file strat_path in
  let () =
    if Dsl.rebalance_of ~filename:strat_path ast = None then
      Printf.eprintf
        "warning: %s does not declare rebalance; trading only when the target changes\n"
        strat_path
  in
```

- [ ] **Step 4 (GREEN): Run build, full suite, and the six comparisons in Global Constraints.** All commands must exit 0; warnings from both undeclared research files must not contaminate redirected stdout.

```sh
opam exec --switch=/sandbox/stock -- dune build --root .
opam exec --switch=/sandbox/stock -- dune runtest --root . --force
```

- [ ] **Step 5: Commit the CLI warning slice only after confirmation.**

```sh
git add bin/bt.ml test/test_bt.ml
git commit -m "feat: warn on undeclared rebalance in CLI decisions"
```

Commit only after the coordinator confirms; use the co-author trailer the coordinator names; never push; never change git settings.

### Task 4: Taiwan live planner cadence

**Files:**
- Modify: `broker/live.ml:523-528,731-742`
- Test: `test/test_bt.ml:6534-6635,7674-7678`

**Interfaces:**
- Consumes: `Dsl.rebalance_of ~filename`, `Engine.plan_fills ~force:bool`, existing `Live.decide` optional TW broker-data injections.
- Produces: `Live.decide` unchanged signature; TW ordinary legs use `~force:rebalance`, with `None` mapped to false; maturity rollover still precedes ordinary legs.

- [ ] **Step 1 (RED): Add an injected TW decision check to `test_tw_live_decide_override`, using its existing `decide_drift` closure and below-target holding.** Put this beside the existing unchanged-target assertion; `decide_drift` uses 10,000 shares at TWD 200 and TWD 3,000,000 equity, so target 0.8 needs TWD 2,400,000 (2,000 more shares) and on_change stays at 10,000.

```ocaml
      let unchanged_below =
        decide_drift "stock \"tw/2330\"\nrebalance on_change\ntarget 0.8\n"
      in
      let daily_below =
        decide_drift "stock \"tw/2330\"\nrebalance daily\ntarget 0.8\n"
      in
      (* TWD 2,000,000 held versus TWD 2,400,000 desired; at TWD 200
         the daily plan needs a positive 2,000-share cash purchase. *)
      let () = assert (unchanged_below.Live.action = Live.Orders []) in
      let () =
        match daily_below.Live.action with
        | Live.Orders legs ->
            assert (List.exists (fun (leg : Live.leg) ->
              leg.action = "Buy" && leg.quantity > 0) legs)
        | Live.Skip _ | Live.Order _ -> assert false
      in
```

- [ ] **Step 2 (RED): Run the test; daily returns no buy legs before the fix.**

```sh
opam exec --switch=/sandbox/stock -- dune runtest --root . --force
```

- [ ] **Step 3 (GREEN): Extract the choice once at the top of `Live.decide`, before the market `match`, and pass it into the existing TW planner.** Keep existing `previous_targets` and rollover code.

```ocaml
  let ast = Dsl.parse_file strat_path in
  let rebalance =
    Option.value (Dsl.rebalance_of ~filename:strat_path ast) ~default:false
  in
  match Dsl.stocks_of ~filename:strat_path ast with
```

```ocaml
          ~prices:[| provisional.c |] ~targets:[| target |] ~force:rebalance
```

- [ ] **Step 4 (GREEN): Run build, full suite, and all six comparisons in Global Constraints; expect exit 0 throughout.**

```sh
opam exec --switch=/sandbox/stock -- dune build --root .
opam exec --switch=/sandbox/stock -- dune runtest --root . --force
```

- [ ] **Step 5: Commit the TW decision slice only after confirmation.**

```sh
git add broker/live.ml test/test_bt.ml
git commit -m "feat: apply rebalance choice in TW decisions"
```

Commit only after the coordinator confirms; use the co-author trailer the coordinator names; never push; never change git settings.

### Task 5: US live previous-target decision

**Files:**
- Modify: `broker/live.ml:70-79,523-600`
- Modify: `broker/live.mli:63-74` (small pure offline test seam; `val decide` stays unchanged)
- Test: `test/test_bt.ml:4517-4574,7500-7503`

**Interfaces:**
- Consumes: `Dsl.rebalance_of ~filename`, the TW effective-target computation pattern, `Engine.effective_targets`, and `Live.decide_action` without changing its sizing.
- Produces: US `Live.decide` unchanged signature; the offline-testable `Live.us_rebalance_action` returns `Live.action`; unchanged target under on_change yields exactly `Skip "target unchanged"`.

- [ ] **Step 1 (RED): Test the action gate without broker/network access.** The existing `test_us_live_fractional` covers `decide_action` sizing, but cannot call US `Live.decide`: its Alpaca account/position functions have no injections and would make network requests. A small pure gate called by the real US arm permits an offline behavior test without altering `Live.decide`'s signature.

```ocaml
let test_us_live_rebalance_action () =
  let choose rebalance ~target ~previous_target =
    Live.us_rebalance_action ~rebalance ~target ~previous_target
      ~symbol:"SPY" ~date:"2025-06-24" ~equity:1000.
      ~price:100. ~held:4.
  in
  (* 0.5 * 1000 / 100 = 5 shares; held 4; the order is a 1-share buy. *)
  let buy = Live.Order
    { side = `Buy; qty = 1.; id = "bt-SPY-2025-06-24" } in
  assert (choose true ~target:0.5 ~previous_target:0.5 = buy);
  assert
    (choose false ~target:0.5 ~previous_target:0.5
     = Live.Skip "target unchanged");
  assert (choose true ~target:0.5 ~previous_target:0.2 = buy);
  assert (choose false ~target:0.5 ~previous_target:0.2 = buy)
```

```ocaml
  test_us_live_fractional ();
  test_us_live_rebalance_action ();
  test_us_live_quantity_limit ();
```

- [ ] **Step 2 (RED): Run the test; `Live.us_rebalance_action` does not yet exist.**

```sh
opam exec --switch=/sandbox/stock -- dune runtest --root . --force
```

- [ ] **Step 3 (GREEN): Add the pure gate beside `decide_action` and export only that testable action seam.** `decide_action` itself stays byte-for-byte unchanged.

```ocaml
(* broker/live.ml *)
let us_rebalance_action ~rebalance ~target ~previous_target
    ~symbol ~date ~equity ~price ~held =
  if not rebalance && target = previous_target then
    Skip "target unchanged"
  else
    decide_action ~symbol ~date ~target ~equity ~price ~held
```

```ocaml
(* broker/live.mli *)
(** Choose change-only skip or existing US share sizing without broker I/O. *)
val us_rebalance_action :
  rebalance:bool -> target:float -> previous_target:float ->
  symbol:string -> date:string -> equity:float -> price:float ->
  held:float -> action
```

- [ ] **Step 4 (GREEN): In the US arm, normalize both the last and previous effective targets using one US profile and its default financing ratio; select the pure action gate.** On the first bar previous target is zero; compare effective rather than raw targets. Keep existing Alpaca equity/held retrieval and order sizing.

```ocaml
      let profile = Engine.profile_of_market "us" in
      let effective_target raw =
        let effective, _ =
          Engine.effective_targets
            ~financing_ratios:[| profile.default_financing_ratio |]
            [| raw |]
        in
        effective.(0)
      in
      let target, previous_target =
        match strategy.Engine.targets with
        | [| targets |] when Array.length targets > 0 ->
            let last = Array.length targets - 1 in
            let target = effective_target targets.(last) in
            let previous =
              if last = 0 then 0. else effective_target targets.(last - 1)
            in
            target, previous
        | _ -> failwith "live trading requires exactly one stock target"
      in
```

```ocaml
      let action =
        us_rebalance_action ~rebalance ~target ~previous_target ~symbol
          ~date:provisional.date ~equity ~price:provisional.c ~held
      in
```

- [ ] **Step 5 (GREEN): Run build, full suite, and all six comparisons in Global Constraints; expect exit 0 throughout.** No US `bt target` invocation: tests exercise the pure action actually called by `Live.decide`.

```sh
opam exec --switch=/sandbox/stock -- dune build --root .
opam exec --switch=/sandbox/stock -- dune runtest --root . --force
```

- [ ] **Step 6: Commit the US decision slice only after confirmation.**

```sh
git add broker/live.ml broker/live.mli test/test_bt.ml
git commit -m "feat: skip unchanged US live targets"
```

Commit only after the coordinator confirms; use the co-author trailer the coordinator names; never push; never change git settings.

### Task 6: Live startup warning

**Files:**
- Modify: `broker/live.ml:964-981,1505-1545,1727-1744`
- Test: `test/test_bt.ml:7476-7696` (full suite; no broker daemon startup test)

**Interfaces:**
- Consumes: `Dsl.rebalance_of ~filename`, `Live.log`, `Live.run` unchanged public signature.
- Produces: one timestamped warning line immediately after either US or TW startup line for an undeclared file; declared files log none. Read rebalance once in `Live.run` and pass `bool option` to both private daemon functions, the smaller diff than re-parsing in each daemon.

- [ ] **Step 1 (RED): Check the existing startup callsites and the intended warning text before editing.** This static callsite check does not start a daemon or contact a broker. The current startup lines have no warning after them.

```sh
rg -n 'let run_us|let run_tw|let run \?equity|log "startup|Dsl.rebalance_of' broker/live.ml
```

Expected: `run_us` and `run_tw` log startup, but no `Dsl.rebalance_of` occurs in `Live.run`.

- [ ] **Step 2 (GREEN): Add a tiny private logger and pass the already-parsed optional choice from `Live.run`.** Keep the US startup log followed by the warning before `cycle ()`; keep the TW warning after `startup_equity` (the mode match logs exactly once) and before `exchange` setup. `None` is the only warning case.

```ocaml
let log_rebalance_warning strat_path = function
  | Some _ -> ()
  | None ->
      log "warning: %s does not declare rebalance; trading only when the target changes"
        strat_path
```

```ocaml
(* Extend the existing private signatures; retain each original body. *)
let run_us mode ~strat_path ~data_dir ~rebalance_choice =
```

```ocaml
let run_tw mode ~equity ~symbol ~strat_path ~data_dir ~rebalance_choice =
```

```ocaml
(* Insert after the existing run_us startup log, or after run_tw's
   startup_equity match and before its exchange setup. *)
  let () = log_rebalance_warning strat_path rebalance_choice in
```

```ocaml
(* Live.run, immediately after parsing *)
  let rebalance_choice = Dsl.rebalance_of ~filename:strat_path ast in
```

```ocaml
(* Live.run market match: retain all arms, adding only the labelled input *)
  | [_, "us", _] ->
      let fd = lock_daemon ~directory ~market:"us" mode in
      Fun.protect ~finally:(fun () -> Unix.close fd)
        (fun () -> run_us mode ~strat_path ~data_dir ~rebalance_choice)
  | [_, "tw", symbol] ->
      let fd = lock_daemon ~directory ~market:"tw" mode in
      Fun.protect ~finally:(fun () -> Unix.close fd)
        (fun () -> run_tw mode ~equity ~symbol ~strat_path ~data_dir
          ~rebalance_choice)
  | [_, _, _] -> failwith "live trading supports us and tw only"
  | _ -> failwith "live trading requires exactly one stock"
```

- [ ] **Step 3 (GREEN): Run build, full suite, and all six comparisons in Global Constraints; expect exit 0 throughout.** Do not invoke a daemon to check the startup logger; that would touch a real broker. Check the emitted callsite with the static command below instead.

```sh
opam exec --switch=/sandbox/stock -- dune build --root .
opam exec --switch=/sandbox/stock -- dune runtest --root . --force
rg -n 'log_rebalance_warning strat_path rebalance_choice' broker/live.ml
```

- [ ] **Step 4: Commit the live logging slice only after confirmation.**

```sh
git add broker/live.ml
git commit -m "feat: log undeclared live rebalance policy at startup"
```

Commit only after the coordinator confirms; use the co-author trailer the coordinator names; never push; never change git settings.

### Task 7: Examples, daily test fixtures, docs, and changelog

**Files:**
- Modify: `examples/00685L_bh.strat:1-2`, `examples/bb_macd.strat:1-7`, `examples/sma_cross.strat:1-5`; do not modify `examples/daytrade_orb.strat` (it has `bars`)
- Modify: `test/test_bt.ml:129-185,1582-1600,1708-1720,1933-1936,2024-2029,2134-2139,2976-3058,3867-3875,4303-4345,4965-5058,5256-5258,6534-6665` (daily source fixtures)
- Modify: `docs/strategy.md:23-30,121-166`, `docs/engine.md:35-38,127-135,202-208`, `docs/cli.md:206-290,333-340,374-479,526-596`
- Modify: `docs/specs/live-trading.md:58-71`, `docs/specs/tw-live-trading.md:61-69`
- Modify: `CHANGELOG.md:7-9`
- Test: `test/test_bt.ml:129-185,7476-7696`

**Interfaces:**
- Consumes: `rebalance daily`, `rebalance on_change`, `Ast.Rebalance of bool`, the exact default warning and US `Skip "target unchanged"`.
- Produces: examples and daily parsed fixtures explicitly choose `rebalance on_change`; strategy grammar, both live docs, CLI docs, engine docs, and `[Unreleased]` changelog describe the shipped behavior.

- [ ] **Step 1 (RED): Inventory every inline stock fixture before changing any; distinguish daily from `bars` cases.** The list below is the observed `stock` fixture inventory. Daily fixtures are at lines 146-185, 1582-1600, 1710-1720, 1935, 2026-2029, 2136-2139, 2976-3058, 3867-3875, 4303-4345, 4965-5058, 5256 (the first item without `bars`), and 6566-6661. Leave the `bars` fixtures at lines 5196, 5230, 5257-5258, and 5279 unchanged. Some negative fixtures intentionally fail after parsing; a declaration preceding their invalid form does not change the error being tested. Do not add declarations to standalone AST lists without a file fixture.

```sh
rg -n 'stock \\"|stock "|bars [0-9]+m' test/test_bt.ml
```

Expected before editing: no `rebalance on_change` in the three daily examples, and daily inline fixtures remain undeclared.

- [ ] **Step 2 (RED): Pin the examples' new AST policy in the existing parser test.** This assertion fails before the examples change. Keep the existing example parse checks too.

```ocaml
let () =
  List.iter
    (fun path ->
      assert
        (Dsl.rebalance_of ~filename:path (Dsl.parse_file path)
         = Some false))
    [sma_strategy_path (); bb_strategy_path (); buy_hold_strategy_path ()]
in
```

Insert that binding immediately after the three example `Dsl.parse_file` calls in `test_parser`; retain their assertions and the subsequent temporary-strategy checks. Run RED:

```sh
opam exec --switch=/sandbox/stock -- dune runtest --root . --force
```

Expected: examples' `rebalance_of` results are `None`, not `Some false`.

- [ ] **Step 3 (GREEN): Insert `rebalance on_change` immediately after `stock` in each daily example and each daily inline fixture identified in Step 1.** The string-literal and raw-string spellings below are exact for this repo. Keep every intraday `bars` fixture and the intraday example untouched. Existing tests which match the complete AST must include `Ast.Rebalance false` at the matching position.

```text
stock "tw/00685L"
rebalance on_change
target 1.0
```

```ocaml
(* ordinary inline daily source, e.g. test_tw_live_decide_override *)
"stock \"tw/2330\"\nrebalance on_change\ntarget 1.0\n"
```

```ocaml
(* raw multiline daily fixture, e.g. test_multi_strat_fixture *)
{|stock "tw/FIXTURE"
rebalance on_change
target 1.0
|}
```

```ocaml
(* test_parser_aliases exact statement-list match after Stock *)
          Ast.Rebalance false;
```

- [ ] **Step 4 (GREEN): Update the strategy reference, including Target exposure, the Statements list, and the BNF alternative.** The syntax is a single file-level choice, not a per-alias statement; it rejects `bars` and defaults to change-only with a warning. Replace the existing Target exposure drift sentence, insert this exact grammar alternative, and add this exact list item under Statements.

```text
             | "rebalance" ( "daily" | "on_change" )
```

```text
- `rebalance daily` trades toward the effective target every daily bar; `rebalance on_change` trades when that target changes. Declare at most one per file. Without a declaration, the strategy uses on_change and bt warns. A `bars` strategy cannot declare rebalance.
```

```text
`target` sets the desired exposure for each bar. The expression must give a scalar or a numeric series, and a scalar applies to every bar. `rebalance daily` trades back toward the target every bar; `rebalance on_change` trades only when the effective target changes, so positions drift between fills. A missing rebalance declaration defaults to on_change and produces a warning.
```

- [ ] **Step 5 (GREEN): Replace the stale drift descriptions in engine and CLI docs; add per-strategy notes to both live specs.** The precise replacement text for `docs/engine.md` Targets and drift is below. In `docs/cli.md`, put the warning paragraph beside `bt run` arguments and both `bt target`/`bt live` sections; update US target and live decision text to say unchanged on_change skips, TW target and live planning to say daily re-plans; keep the separate real-market limitations and existing option defaults. Replace the old `docs/specs/tw-live-trading.md` line that says ordinary planning is never forced and add a dated note in `docs/specs/live-trading.md` after its daily cycle.

```text
A daily strategy declares `rebalance daily` to plan toward its effective target each bar, or `rebalance on_change` to trade only when that target changes. An undeclared strategy defaults to on_change and prints a warning. Under on_change, positions drift until a target change or dividend-cash fill. Under daily, a bar after a next-open maintenance cure may buy back toward target, limited by initial-margin financing. `--fill close` re-plans at the bar close; `--fill open` re-plans at the next bar open. Intraday `bars` strategies cannot declare rebalance.
```

```text
A strategy without `rebalance daily` or `rebalance on_change` trades only when its effective target changes. `bt run` and `bt target` print `warning: <file> does not declare rebalance; trading only when the target changes` once per undeclared file on stderr; stdout remains unchanged. `bt live` logs the same message once after the startup line.
```

```text
US: `rebalance daily` sizes the difference between desired and held shares each session. `rebalance on_change` (also the undeclared default) skips an unchanged effective target with `target unchanged`, but sizes a changed target with the existing fractional order rules. TW: `rebalance daily` passes `force` to the ordinary fill planner so it re-plans missed or partial legs; `rebalance on_change` preserves drift until a changed target. Rollover legs remain independent of this choice.
```

```text
In both live paths, drift handling is selected by the strategy's `rebalance daily` or `rebalance on_change` statement. An undeclared strategy defaults to on_change and logs one warning after startup. The daily engine re-plans after a simulated next-open cure; neither daemon automatically handles a broker margin call.
```

- [ ] **Step 6 (GREEN): Add Keep a Changelog entries under `[Unreleased]`.** No release version or date change.

```text
### Added

- Daily strategies can declare `rebalance daily` or `rebalance on_change` to select the same rebalancing rule for backtests and US/TW live decisions; undeclared strategies warn and default to on_change.

### Changed

- US live no longer rebalances unchanged targets daily when the strategy omits the declaration. Daily re-planning after a simulated maintenance cure is available with `rebalance daily`.
```

- [ ] **Step 7 (GREEN): Run build, full suite, and all six comparisons in Global Constraints.** Document changes cannot alter the research strategies; every gate must still exit 0. Inspect `rg` output for exactly the remaining `bars`-only fixtures before the coordinator review.

```sh
opam exec --switch=/sandbox/stock -- dune build --root .
opam exec --switch=/sandbox/stock -- dune runtest --root . --force
rg -n 'stock \\"|stock "|bars [0-9]+m' test/test_bt.ml
```

- [ ] **Step 8: Commit examples, fixtures, docs, and changelog only after confirmation.** Task 7 belongs to the doc-editor agent assigned by the coordinator; it does not dispatch anyone itself.

```sh
git add examples/00685L_bh.strat examples/bb_macd.strat examples/sma_cross.strat test/test_bt.ml docs/strategy.md docs/engine.md docs/cli.md docs/specs/live-trading.md docs/specs/tw-live-trading.md CHANGELOG.md
git commit -m "docs: describe strategy rebalance policies"
```

Commit only after the coordinator confirms; use the co-author trailer the coordinator names; never push; never change git settings.

## Self-Review

- Spec coverage: Task 1 maps syntax, keyword reservation, duplicate and bars errors; Task 2 maps both fill modes, cure, unchanged default, baseline/daytrade callsites and byte gates; Task 3 maps the stderr warnings; Tasks 4 and 5 map TW and US decisions; Task 6 maps live startup logging; Task 7 maps every example, daily file fixture, BNF, docs, and changelog. No requirement from the approved spec is unmapped. Non-goals remain excluded.
- Placeholder scan: no unfinished markers, unexplained pseudo-code, missing test implementation, invented source function, or deferred implementation step. The filename in warning text is intentionally shown as `<file>` in the user-visible contract, not as an implementation placeholder.
- Type consistency: `Ast.Rebalance of bool` appears in both AST declarations and `Dsl.compile_ast`; `Dsl.rebalance_of ~filename` has one `bool option` type everywhere; `Engine.run ~rebalance:bool` is required in its `.mli`, implementation, both CLI baselines and all tests; `Live.decide` is unchanged; US skip text and warning copy match the spec. The extra US pure gate exists solely for offline testing and is invoked by the US arm.
- Verification scope: no broker, network, build, test, formatter, stage, commit, or push was run while writing this plan. The coordinator runs project-wide gates during execution; this task only writes this plan.
