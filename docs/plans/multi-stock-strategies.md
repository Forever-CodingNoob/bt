# Multi-Stock Strategies Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One strat file can declare several stocks with `as` aliases, drive each stock's exposure from any stock's signals, and backtest them as one portfolio with one equity curve.

**Architecture:** The parser gains dotted qualification (`bull.close`, `bull.target ...`). The compiler groups statements per alias and compiles each group with the existing style compilers into per-asset target arrays. The engine becomes a portfolio loop over per-asset bars, exposures, and costs, with VWAP-based per-leg round trips. Single-stock files are the one-asset case and keep identical equity output.

**Tech Stack:** OCaml (stdlib + Unix), ocamllex/ocamlyacc, dune, single test binary `test/test_bt.ml`.

**Spec:** `docs/specs/multi-stock-strategies.md`

## Global Constraints

- Verification command for every task: `opam exec -- dune build && opam exec -- dune runtest` from the repo root (bare `dune` is unavailable; opam prints a harmless root-directory warning).
- Single-stock files keep byte-identical equity curves and metrics. The only sanctioned single-stock change: trip `net_ret` becomes the leg price return (exit VWAP / entry VWAP - 1, costs excluded), and `trades.csv` gains a `stock` column.
- Trip definition, verbatim from the spec: entry price = exposure-weighted average fill price over the trip's exposure increases; exit price = the same over decreases; `net_ret = exit_price / entry_price - 1`.
- `Open_next` accrual is joint: on a bar where no asset fills, one leg close-to-close; where at least one asset fills, two legs (all assets close-to-open on old exposures, fills at opens, all assets open-to-close on new exposures).
- Aliases are all-or-nothing per file. Aliased files qualify every stock-scoped statement and every bar series; bare `close`/`atr(n)` are errors there. Unaliased files: exactly one stock, today's syntax, unchanged.
- Statement qualification is dotted: `bull.target <expr>`, `bear.entry when <cond> [size <expr>]`, `bear.exit when ...`, `bull.size <expr>`, `bear.cap 1.0`. Series: `bull.close`; qualified builtin: `bull.atr(n)` (only `atr` accepts a qualifier).
- Code style: two-space indent, one space on each side of `=`, no alignment padding.
- Commit trailer: every commit in this plan is written by a GPT 5.6 Sol implementer and ends with `Co-authored-by: ChatGPT <noreply@openai.com>` after one blank line.
- All tests live in `test/test_bt.ml`, registered in the final `let () =` runner. `data/` is gitignored; never commit cache files.

---

### Task 1: Dotted syntax in AST, lexer, parser

**Files:**
- Modify: `lib/ast.ml` (whole file), `lib/lexer.mll`, `lib/parser.mly`, `lib/dsl.ml` (mechanical constructor updates only)
- Test: `test/test_bt.ml`

**Interfaces:**
- Produces: `Ast.Var of string option * string`, `Ast.Call of string option * string * expr list`, `Ast.Entry/Exit of string option * expr * expr option`, `Ast.Size/Target of string option * expr`, `Ast.Cap of string option * float`, `Ast.Stock of string * string option`. Task 3 consumes these.
- Behavior contract: single-stock semantics unchanged; alias-qualified statements parse but fail at compile with `unknown stock alias <a>` until Task 3.

- [ ] **Step 1: Write the failing test**

Append to `test/test_bt.ml` and register `test_parser_aliases ();` in the runner:

```ocaml
let test_parser_aliases () =
  with_temp_strategy
    "stock \"tw/00685L\" as bull\n\
     stock \"tw/00632R\" as bear\n\
     let crash = bull.close / lag(bull.close, 7) - 1 < -0.01\n\
     bull.target 2.0 * num(not crash)\n\
     bear.entry when crash size 0.5\n\
     bear.exit when not crash\n\
     bear.cap 1.0\n\
     bull.size 1.0\n"
    (fun path ->
      match Dsl.parse_file path with
      | [ Ast.Stock ("tw/00685L", Some "bull");
          Ast.Stock ("tw/00632R", Some "bear");
          Ast.Let ("crash", _);
          Ast.Target (Some "bull", _);
          Ast.Entry (Some "bear", Ast.Var (None, "crash"), Some (Ast.Num 0.5));
          Ast.Exit (Some "bear", Ast.Unop ("not", Ast.Var (None, "crash")), None);
          Ast.Cap (Some "bear", 1.0);
          Ast.Size (Some "bull", Ast.Num 1.0) ] -> ()
      | _ -> assert false);
  with_temp_strategy
    "stock \"tw/0050\"\n\
     entry when cross_above(close, sma(close, 5))\n\
     exit when cross_below(close, sma(close, 5))\n"
    (fun path ->
      match Dsl.parse_file path with
      | [ Ast.Stock ("tw/0050", None);
          Ast.Entry (None, _, None);
          Ast.Exit (None, _, None) ] -> ()
      | _ -> assert false);
  with_temp_strategy
    "stock \"tw/0050\" as etf\n\
     etf.target etf.atr(14) / etf.close\n"
    (fun path ->
      match Dsl.parse_file path with
      | [ Ast.Stock (_, Some "etf");
          Ast.Target (Some "etf",
            Ast.Binop ("/",
              Ast.Call (Some "etf", "atr", [Ast.Num 14.]),
              Ast.Var (Some "etf", "close"))) ] -> ()
      | _ -> assert false)
```

- [ ] **Step 2: Verify it fails**

Run: `opam exec -- dune build 2>&1 | head -20`
Expected: compile errors - `Ast.Stock` and friends have the old arities.

- [ ] **Step 3: Implement the syntax**

Replace `lib/ast.ml` entirely:

```ocaml
type expr =
  | Num of float
  | Var of string option * string          (* qualifier, name *)
  | Call of string option * string * expr list
  | Unop of string * expr
  | Binop of string * expr * expr

type stmt =
  | Param of string * float
  | Let of string * expr
  | Entry of string option * expr * expr option  (* alias, condition, inline size *)
  | Exit of string option * expr * expr option
  | Size of string option * expr
  | Target of string option * expr
  | Cap of string option * float
  | Stock of string * string option               (* "market/symbol", alias *)

type file = stmt list
```

`lib/lexer.mll`: add `| "as" -> AS` to the `keyword` function and a `| '.' { DOT }` rule beside the other single-character rules (after the `number` rule, so `1.5` still lexes as one number).

`lib/parser.mly`: declare `%token DOT AS`; replace the `stmt` and `expr` ident/call productions:

```
stmt:
  PARAM IDENT ASSIGN NUMBER { Param ($2, $4) }
| LET IDENT ASSIGN expr { Let ($2, $4) }
| ENTRY WHEN expr { Entry (None, $3, None) }
| ENTRY WHEN expr SIZE expr { Entry (None, $3, Some $5) }
| IDENT DOT ENTRY WHEN expr { Entry (Some $1, $5, None) }
| IDENT DOT ENTRY WHEN expr SIZE expr { Entry (Some $1, $5, Some $7) }
| EXIT WHEN expr { Exit (None, $3, None) }
| EXIT WHEN expr SIZE expr { Exit (None, $3, Some $5) }
| IDENT DOT EXIT WHEN expr { Exit (Some $1, $5, None) }
| IDENT DOT EXIT WHEN expr SIZE expr { Exit (Some $1, $5, Some $7) }
| SIZE expr { Size (None, $2) }
| IDENT DOT SIZE expr { Size (Some $1, $4) }
| TARGET expr { Target (None, $2) }
| IDENT DOT TARGET expr { Target (Some $1, $4) }
| CAP NUMBER { Cap (None, $2) }
| IDENT DOT CAP NUMBER { Cap (Some $1, $4) }
| STOCK STRING { Stock ($2, None) }
| STOCK STRING AS IDENT { Stock ($2, Some $4) }
;
```

and in `expr`:

```
| IDENT { Var (None, $1) }
| IDENT DOT IDENT { Var (Some $1, $3) }
| IDENT LPAREN arg_list RPAREN { Call (None, $1, $3) }
| IDENT DOT IDENT LPAREN arg_list RPAREN { Call (Some $1, $3, $5) }
```

`lib/dsl.ml` mechanical updates, preserving single-stock behavior:

- `string_of_expr`: `Var (None, name)` prints as before; `Var (Some q, name)` prints `q ^ "." ^ name`; same prefix treatment for `Call`.
- `eval`'s `Var` case builds one lookup key:

```ocaml
  | Var (qualifier, name) ->
      let key =
        match qualifier with None -> name | Some q -> q ^ "." ^ name
      in
      begin
        match List.assoc_opt key environment with
        | Some value -> value
        | None ->
            fail_expr expression (Printf.sprintf "unknown identifier %s" key)
      end
```

- `eval`'s `Call` case: `Call (Some q, _, _)` fails with `unknown stock alias q`; `Call (None, name, arguments)` keeps today's body.
- `compile_ast` fold arms: `Entry (None, ...)`, `Exit (None, ...)`, `Size (None, ...)`, `Target (None, ...)`, `Cap (None, ...)` keep today's bodies; one combined arm for `Entry (Some alias, _, _) | Exit (Some alias, _, _) | Size (Some alias, _) | Target (Some alias, _) | Cap (Some alias, _)` fails with `Printf.sprintf "unknown stock alias %s" alias`; `Stock _` still ignored.
- `stock_of`: patterns become `Stock (s, _)`; behavior unchanged (alias ignored until Task 3).
- Fix every other arity error `opam exec -- dune build` reports in `lib/` and `test/` by inserting `None` qualifiers; change no behavior.

- [ ] **Step 4: Verify build and tests pass**

Run: `opam exec -- dune build && opam exec -- dune runtest`
Expected: build clean (in particular no ocamlyacc conflict output), tests print `ok`.

- [ ] **Step 5: Commit**

```bash
git add lib/ast.ml lib/lexer.mll lib/parser.mly lib/dsl.ml test/test_bt.ml
git commit -m "feat: dotted alias syntax in the strategy language

Co-authored-by: ChatGPT <noreply@openai.com>"
```

---

### Task 2: Portfolio engine

**Files:**
- Modify: `lib/engine.ml` (types and `run`), `lib/dsl.ml:563` (strategy construction), `lib/report.ml:183-194` (fills log), `bin/bt.ml` (run callsites, baseline, targets), `test/test_bt.ml`

**Interfaces:**
- Produces: `Engine.strategy = { targets : float array array }`; `Engine.fill_event = { date; stock; price; from_e; to_e }`; `Engine.run : (string * Data.bar array) array -> strategy -> costs array -> capital:float option -> fill:fill -> result`. Task 3 consumes these.
- Consumes: `Data.bar`, existing `costs`, `fill`, `trip`, `result` types.

- [ ] **Step 1: Write the failing tests**

Append to `test/test_bt.ml` (near the other engine tests) and register all three in the runner:

```ocaml
let run_single bars target costs ~capital ~fill =
  Engine.run [| ("tw/TEST", bars) |] { Engine.targets = [| target |] }
    [| costs |] ~capital ~fill

let test_engine_portfolio_close () =
  let a =
    [| bar "2020-01-01" 100. 100.;
       bar "2020-01-02" 100. 110.;
       bar "2020-01-03" 110. 121. |]
  in
  let b =
    [| bar "2020-01-01" 50. 50.;
       bar "2020-01-02" 50. 45.;
       bar "2020-01-03" 45. 54. |]
  in
  let strategy : Engine.strategy =
    { targets = [| [| 0.5; 0.5; 0. |]; [| 0.; 0.4; 0. |] |] }
  in
  let result =
    Engine.run [| ("tw/A", a); ("tw/B", b) |] strategy
      [| zero_costs; zero_costs |] ~capital:None ~fill:Engine.Close_same
  in
  (* day 2: 1 + 0.5 * (110/100 - 1) = 1.05; B fills to 0.4 at 45.
     day 3: 1.05 * (1 + 0.5 * (121/110 - 1) + 0.4 * (54/45 - 1))
          = 1.05 * 1.13. Both close at day-3 closes. *)
  assert_close ~tolerance:1e-12 (1.05 *. 1.13) (final_equity result);
  assert (List.length result.fills = 4);
  assert (List.length result.trips = 2);
  let by_entry (trip : Engine.trip) = trip.entry_date in
  let sorted =
    List.sort (fun x y -> compare (by_entry x) (by_entry y)) result.trips
  in
  (match sorted with
   | [a_trip; b_trip] ->
       assert_close ~tolerance:1e-12 (121. /. 100. -. 1.) a_trip.net_ret;
       assert_close ~tolerance:1e-12 (54. /. 45. -. 1.) b_trip.net_ret
   | _ -> assert false);
  (match result.fills with
   | first :: _ -> assert (first.Engine.stock = "tw/A")
   | [] -> assert false)

let test_engine_portfolio_open () =
  let a =
    [| bar "2020-01-01" 100. 100.;
       bar "2020-01-02" 102. 104.;
       bar "2020-01-03" 106. 108. |]
  in
  let b =
    [| bar "2020-01-01" 50. 50.;
       bar "2020-01-02" 51. 52.;
       bar "2020-01-03" 53. 54. |]
  in
  let strategy : Engine.strategy =
    { targets = [| [| 1.; 1.; 1. |]; [| 0.; 0.5; 0.5 |] |] }
  in
  let result =
    Engine.run [| ("tw/A", a); ("tw/B", b) |] strategy
      [| zero_costs; zero_costs |] ~capital:None ~fill:Engine.Open_next
  in
  (* day 2: A fills at open 102; legs 1 (flat) then 104/102.
     day 3: B fills at open 53; leg 1: 106/104 - 1 on A alone;
     leg 2: (108/106 - 1) + 0.5 * (54/53 - 1).
     Final bar force-closes A at 108 and B at 54 (no cost). *)
  let expected =
    (104. /. 102.)
    *. (1. +. (106. /. 104. -. 1.))
    *. (1. +. (108. /. 106. -. 1.) +. 0.5 *. (54. /. 53. -. 1.))
  in
  assert_close ~tolerance:1e-12 expected (final_equity result);
  assert (List.length result.fills = 4);
  assert (List.length result.trips = 2)

let test_engine_vwap_trip () =
  let bars =
    [| bar "2020-01-01" 100. 100.;
       bar "2020-01-02" 105. 110.;
       bar "2020-01-03" 120. 126. |]
  in
  let result =
    run_single bars [| 0.5; 1.0; 0.0 |] zero_costs
      ~capital:None ~fill:Engine.Close_same
  in
  (* scale in 0.5 at 100 and 0.5 at 110: entry VWAP 105; exit all at 126 *)
  (match result.trips with
   | [trip] -> assert_close ~tolerance:1e-12 (126. /. 105. -. 1.) trip.net_ret
   | _ -> assert false)
```

- [ ] **Step 2: Verify they fail**

Run: `opam exec -- dune build 2>&1 | head -20`
Expected: compile errors - `Engine.strategy` has no `targets` field yet.

- [ ] **Step 3: Implement the portfolio engine**

In `lib/engine.ml`, replace the `strategy` and `fill_event` types and the whole `run` function (`default_costs`, `costs`, `fill`, `trip`, `result`, `clamp_target` stay):

```ocaml
type strategy = { targets : float array array }

type fill_event = {
  date : string;
  stock : string;
  price : float;
  from_e : float;
  to_e : float;
}
```

```ocaml
let run (assets : (string * Data.bar array) array) (strategy : strategy)
    (costs : costs array) ~capital:(capital : float option) ~fill =
  let asset_count = Array.length assets in
  if asset_count = 0 then invalid_arg "Engine.run: no assets";
  if Array.length strategy.targets <> asset_count then
    invalid_arg "Engine.run: targets/assets mismatch";
  if Array.length costs <> asset_count then
    invalid_arg "Engine.run: costs/assets mismatch";
  let length = Array.length (snd assets.(0)) in
  Array.iter
    (fun (_, bars) ->
      if Array.length bars <> length then
        invalid_arg "Engine.run: bar length mismatch")
    assets;
  Array.iter
    (fun target ->
      if Array.length target <> length then
        invalid_arg "Engine.run: target length mismatch")
    strategy.targets;
  let equity = ref 1. in
  let exposures = Array.make asset_count 0. in
  let entry_dates = Array.make asset_count "" in
  let buy_value = Array.make asset_count 0. in
  let buy_exposure = Array.make asset_count 0. in
  let sell_value = Array.make asset_count 0. in
  let sell_exposure = Array.make asset_count 0. in
  let fills = ref [] in
  let trips = ref [] in
  let equity_curve = ref [] in
  let charge index ~equity_before ~delta =
    let costs = costs.(index) in
    let amount = abs_float delta in
    let commission = amount *. costs.fee_bps /. 10000. in
    let commission =
      match capital with
      | Some value when costs.min_fee > 0. ->
          Float.max commission (costs.min_fee /. (equity_before *. value))
      | _ -> commission
    in
    let non_commission_bps =
      if delta > 0. then costs.slip_bps else costs.tax_bps +. costs.slip_bps
    in
    commission +. amount *. non_commission_bps /. 10000.
  in
  let trade index ~date ~price ~desired =
    let exposure = exposures.(index) in
    let delta = desired -. exposure in
    if delta <> 0. then begin
      if exposure = 0. then begin
        entry_dates.(index) <- date;
        buy_value.(index) <- 0.;
        buy_exposure.(index) <- 0.;
        sell_value.(index) <- 0.;
        sell_exposure.(index) <- 0.
      end;
      if delta > 0. then begin
        buy_value.(index) <- buy_value.(index) +. delta *. price;
        buy_exposure.(index) <- buy_exposure.(index) +. delta
      end
      else begin
        sell_value.(index) <- sell_value.(index) -. delta *. price;
        sell_exposure.(index) <- sell_exposure.(index) -. delta
      end;
      let equity_before = !equity in
      equity := equity_before *. (1. -. charge index ~equity_before ~delta);
      fills :=
        { date; stock = fst assets.(index); price;
          from_e = exposure; to_e = desired } :: !fills;
      exposures.(index) <- desired;
      if desired = 0. then begin
        let entry_price = buy_value.(index) /. buy_exposure.(index) in
        let exit_price = sell_value.(index) /. sell_exposure.(index) in
        trips :=
          { entry_date = entry_dates.(index); exit_date = date;
            net_ret = exit_price /. entry_price -. 1. } :: !trips
      end
    end
  in
  let close_at index t = (snd assets.(index)).(t).Data.c in
  let open_at index t = (snd assets.(index)).(t).Data.o in
  let joint now before =
    let sum = ref 0. in
    for index = 0 to asset_count - 1 do
      if exposures.(index) <> 0. then
        sum :=
          !sum +. exposures.(index) *. (now index /. before index -. 1.)
    done;
    !sum
  in
  for t = 0 to length - 1 do
    let date = (snd assets.(0)).(t).Data.date in
    (match fill with
     | Close_same ->
         if t > 0 then
           equity :=
             !equity
             *. (1. +. joint (fun i -> close_at i t)
                         (fun i -> close_at i (t - 1)));
         for index = 0 to asset_count - 1 do
           trade index ~date ~price:(close_at index t)
             ~desired:(clamp_target strategy.targets.(index).(t))
         done
     | Open_next ->
         if t > 0 then begin
           let changed = ref false in
           for index = 0 to asset_count - 1 do
             if clamp_target strategy.targets.(index).(t - 1)
                <> exposures.(index)
             then changed := true
           done;
           if !changed then begin
             equity :=
               !equity
               *. (1. +. joint (fun i -> open_at i t)
                           (fun i -> close_at i (t - 1)));
             for index = 0 to asset_count - 1 do
               trade index ~date ~price:(open_at index t)
                 ~desired:(clamp_target strategy.targets.(index).(t - 1))
             done;
             equity :=
               !equity
               *. (1. +. joint (fun i -> close_at i t)
                           (fun i -> open_at i t))
           end
           else
             equity :=
               !equity
               *. (1. +. joint (fun i -> close_at i t)
                           (fun i -> close_at i (t - 1)))
         end);
    equity_curve := (date, !equity) :: !equity_curve
  done;
  let last = length - 1 in
  let closed_any = ref false in
  for index = 0 to asset_count - 1 do
    if exposures.(index) > 0. then begin
      closed_any := true;
      trade index ~date:(snd assets.(index)).(last).Data.date
        ~price:(close_at index last) ~desired:0.
    end
  done;
  if !closed_any then
    (match !equity_curve with
     | _ :: rest ->
         equity_curve :=
           ((snd assets.(0)).(last).Data.date, !equity) :: rest
     | [] -> ());
  { equity_curve = List.rev !equity_curve;
    fills = List.rev !fills;
    trips = List.rev !trips }
```

Mechanical caller updates, no behavior change:

- `lib/dsl.ml:563`: `let strategy : Engine.strategy = { targets = [| target |] } in`.
- `lib/report.ml:183-194` (`write_fills`): header `date,stock,price,from_exposure,to_exposure`; row `Printf.fprintf output "%s,%s,%.17g,%.17g,%.17g\n" fill.date fill.stock fill.price fill.from_e fill.to_e`.
- `bin/bt.ml`: `baseline_strategy length` returns `{ targets = [| Array.make length 1. |] }`. The strategy run (line 307) becomes
  `Btlib.Engine.run [| (input.market ^ "/" ^ input.symbol, input.bars) |] strategy [| costs |] ~capital:!capital ~fill:!fill`
  and the tuple at line 311 passes `strategy.targets.(0)` for the footer. The baseline run (line 324) becomes
  `Btlib.Engine.run [| (market ^ "/" ^ symbol, bars) |] (baseline_strategy (Array.length bars)) [| costs |] ~capital:!capital ~fill:!fill`.
- `test/test_bt.ml`: replace every existing `Engine.run <bars> <strategy> <costs> ...` callsite with `run_single <bars> <target array> <costs> ...` (defining the target inline where a `strategy` record was built), or with a direct one-asset `Engine.run [| ("tw/TEST", bars) |] strategy [| costs |]` where the strategy comes from `Dsl.compile`. Existing assertions stay untouched: equity values are unchanged by construction, and the golden trip assertion already computes `net_ret` from fill prices, which matches the VWAP definition for all-in/all-out zero-cost trips.
- `test/test_bt.ml:324` reads `strategy.Engine.target`; it becomes `strategy.Engine.targets.(0)`. Fix any remaining field or arity error the build reports the same way, changing no assertion values.

- [ ] **Step 4: Verify build and tests pass**

Run: `opam exec -- dune build && opam exec -- dune runtest`
Expected: build clean, tests print `ok`, including the untouched golden test.

- [ ] **Step 5: Commit**

```bash
git add lib/engine.ml lib/dsl.ml lib/report.ml bin/bt.ml test/test_bt.ml
git commit -m "feat: portfolio engine with per-asset costs and VWAP trips

Co-authored-by: ChatGPT <noreply@openai.com>"
```

---

### Task 3: Multi-stock compilation and CLI wiring

**Files:**
- Modify: `lib/dsl.ml` (context, environments, qualified eval, per-group compile, `stocks_of`), `bin/bt.ml` (per-file asset loading, costs, footer), `test/test_bt.ml`

**Interfaces:**
- Consumes: Task 1 AST, Task 2 `Engine.strategy`/`Engine.run`.
- Produces:
  - `Dsl.stocks_of : filename:string -> Ast.file -> (string option * string * string) list` (alias, market, symbol; declaration order; all validation applied).
  - `Dsl.compile_ast : Ast.file -> params:(string * float) list -> assets:(string option * Data.bar array) list -> Engine.strategy` (targets in asset order).
  - `Dsl.compile : string -> params:(string * float) list -> Data.bar array -> Engine.strategy` stays for single-stock callers and rejects aliased files with `Dsl.compile supports single unaliased stocks; use compile_ast`.

- [ ] **Step 1: Write the failing tests**

Append to `test/test_bt.ml` and register both in the runner:

```ocaml
let test_multi_stock_compile () =
  let bull_bars =
    [| bar "2020-01-01" 100. 100.;
       bar "2020-01-02" 100. 90.;
       bar "2020-01-03" 90. 80.;
       bar "2020-01-04" 80. 85. |]
  in
  let bear_bars =
    [| bar "2020-01-01" 20. 20.;
       bar "2020-01-02" 20. 22.;
       bar "2020-01-03" 22. 24.;
       bar "2020-01-04" 24. 23. |]
  in
  with_temp_strategy
    "stock \"tw/00685L\" as bull\n\
     stock \"tw/00632R\" as bear\n\
     let falling = bull.close < lag(bull.close, 1)\n\
     bull.target num(not falling)\n\
     bear.entry when falling size 0.5\n\
     bear.exit when not falling\n"
    (fun path ->
      let ast = Dsl.parse_file path in
      (match Dsl.stocks_of ~filename:path ast with
       | [ (Some "bull", "tw", "00685L"); (Some "bear", "tw", "00632R") ] -> ()
       | _ -> assert false);
      let strategy =
        Dsl.compile_ast ast ~params:[]
          ~assets:[ (Some "bull", bull_bars); (Some "bear", bear_bars) ]
      in
      (* falling = [false; true; true; false] (first lag is NaN -> false).
         bull target: [1; 0; 0; 1]. bear orders: entry 0.5 on bars 2-3,
         clamped at 0.5 by cap 1.0 default... entries sum, so bar 2: 0.5,
         bar 3: 1.0 capped to 1.0? No: 0.5 + 0.5 = 1.0 <= cap. exit on
         bars 1 and 4. bear target: [0; 0.5; 1.0; 0]. *)
      assert (strategy.Engine.targets = [| [| 1.; 0.; 0.; 1. |];
                                           [| 0.; 0.5; 1.0; 0. |] |]))

let test_multi_stock_errors () =
  let expect source =
    with_temp_strategy source
      (fun path ->
        assert_failure (fun () ->
          let ast = Dsl.parse_file path in
          let stocks = Dsl.stocks_of ~filename:path ast in
          let assets =
            List.map
              (fun (alias, _, _) ->
                (alias, [| bar "2020-01-01" 1. 1.; bar "2020-01-02" 1. 1. |]))
              stocks
          in
          ignore (Dsl.compile_ast ast ~params:[] ~assets)))
  in
  (* mixed aliased and unaliased stocks *)
  expect "stock \"tw/A\" as a\nstock \"tw/B\"\na.target 1.0\n";
  (* two unaliased stocks *)
  expect "stock \"tw/A\"\nstock \"tw/B\"\ntarget 1.0\n";
  (* duplicate alias *)
  expect "stock \"tw/A\" as a\nstock \"tw/B\" as a\na.target 1.0\n";
  (* duplicate symbol *)
  expect "stock \"tw/A\" as a\nstock \"tw/A\" as b\na.target 1.0\nb.target 1.0\n";
  (* alias collides with a builtin *)
  expect "stock \"tw/A\" as sma\nsma.target 1.0\n";
  (* alias collides with a predefined series *)
  expect "stock \"tw/A\" as close\nclose.target 1.0\n";
  (* alias collides with a param *)
  expect "stock \"tw/A\" as n\nparam n = 5\nn.target 1.0\n";
  (* unknown alias in a statement *)
  expect "stock \"tw/A\" as a\nb.target 1.0\n";
  (* bare statement in an aliased file *)
  expect "stock \"tw/A\" as a\ntarget 1.0\n";
  (* bare series in an aliased file *)
  expect "stock \"tw/A\" as a\na.target close\n";
  (* bare atr in an aliased file *)
  expect "stock \"tw/A\" as a\na.target atr(3)\n";
  (* qualified non-atr builtin *)
  expect "stock \"tw/A\" as a\na.target a.sma(a.close, 3)\n";
  (* declared stock without statements *)
  expect "stock \"tw/A\" as a\nstock \"tw/B\" as b\na.target 1.0\n";
  (* alias qualification in an unaliased file *)
  expect "stock \"tw/A\"\na.target 1.0\n"
```

- [ ] **Step 2: Verify they fail**

Run: `opam exec -- dune build 2>&1 | head -10`
Expected: compile error - `Dsl.stocks_of` is unbound and `compile_ast` has no `~assets`.

- [ ] **Step 3: Implement multi-stock compilation**

In `lib/dsl.ml`:

1. Context carries per-qualifier bars:

```ocaml
type context = {
  bars_by : (string option * Data.bar array) list;
  length : int;
}
```

`eval_call` gains the qualifier and threads it to `atr`:

```ocaml
  | "atr", [period] ->
      let bars =
        match List.assoc_opt qualifier context.bars_by with
        | Some bars -> bars
        | None ->
            fail_expr expression
              (match qualifier with
               | None -> "atr requires a stock alias in aliased files"
               | Some q -> Printf.sprintf "unknown stock alias %s" q)
      in
      Series (Series.atr bars (expect_period expression period))
```

Every other builtin rejects a qualifier: in `eval`'s `Call` arm, when the qualifier is `Some q` and the name is not `"atr"`, fail with `Printf.sprintf "only atr takes a stock alias, not %s" name`. Pass the qualifier through `eval` -> `eval_call`.

2. `series_environment` gains an optional prefix:

```ocaml
let series_environment ?alias (bars : Data.bar array) =
  ...existing arrays...
  let key name =
    match alias with None -> name | Some a -> a ^ "." ^ name
  in
  [ key "open", Series open_;
    key "high", Series high;
    key "low", Series low;
    key "close", Series close;
    key "volume", Series volume ]
```

3. `stocks_of` replaces `stock_of` (keep the market/symbol split and validation of the current code as a local `split_spec` helper):

```ocaml
let stocks_of ~filename statements =
  let declared =
    List.filter_map
      (function Stock (spec, alias) -> Some (spec, alias) | _ -> None)
      statements
  in
  if declared = [] then
    failwith (Printf.sprintf
      "%s: add a stock statement, e.g. stock \"tw/00685L\"" filename);
  let aliased = List.exists (fun (_, alias) -> alias <> None) declared in
  if List.length declared > 1 && not aliased then
    failwith (Printf.sprintf
      "%s: multiple stocks require as aliases" filename);
  if aliased && List.exists (fun (_, alias) -> alias = None) declared then
    failwith (Printf.sprintf
      "%s: mix of aliased and unaliased stock statements" filename);
  let seen_alias = Hashtbl.create 4 in
  let seen_spec = Hashtbl.create 4 in
  List.map
    (fun (spec, alias) ->
      if Hashtbl.mem seen_spec spec then
        failwith (Printf.sprintf "%s: duplicate stock %s" filename spec);
      Hashtbl.replace seen_spec spec ();
      (match alias with
       | None -> ()
       | Some name ->
           if Hashtbl.mem seen_alias name then
             failwith (Printf.sprintf "%s: duplicate alias %s" filename name);
           Hashtbl.replace seen_alias name ();
           if builtin_arity name <> None then
             failwith (Printf.sprintf
               "%s: alias %s collides with a builtin" filename name);
           if List.mem name ["open"; "high"; "low"; "close"; "volume"] then
             failwith (Printf.sprintf
               "%s: alias %s collides with a series name" filename name);
           List.iter
             (function
               | Param (p, _) when p = name ->
                   failwith (Printf.sprintf
                     "%s: alias %s collides with a param" filename name)
               | Let (l, _) when l = name ->
                   failwith (Printf.sprintf
                     "%s: alias %s collides with a let" filename name)
               | _ -> ())
             statements);
      let market, symbol = split_spec ~filename spec in
      (alias, market, symbol))
    declared
```

4. `compile_ast` takes `~assets:(string option * Data.bar array) list`, builds the context (`bars_by = assets`) and the initial environment (`series_environment` per asset, concatenated; bare names exist only for the unaliased single asset), verifies every asset's bars share one length, and accumulates per-alias groups. Replace the fold's stock-scoped arms with lookups into a per-alias accumulator table:

```ocaml
  let module Group = struct
    type t = {
      mutable entries : (bool array * (Ast.expr * value) option) list;
      mutable exits : (bool array * (Ast.expr * value) option) list;
      mutable size : (Ast.expr * value) option;
      mutable targets : (Ast.expr * value) list;
      mutable cap : float option;
    }
    let make () =
      { entries = []; exits = []; size = None; targets = []; cap = None }
  end in
  let groups : (string option, Group.t) Hashtbl.t = Hashtbl.create 4 in
  let declared_aliases = List.map fst assets in
  let group alias =
    if not (List.mem alias declared_aliases) then
      (match alias with
       | Some name -> failwith (Printf.sprintf "unknown stock alias %s" name)
       | None -> failwith "statements must name a stock alias in aliased files");
    match Hashtbl.find_opt groups alias with
    | Some g -> g
    | None -> let g = Group.make () in Hashtbl.replace groups alias g; g
  in
```

The fold keeps its `Param`/`Let` arms; `Entry (alias, e, s)` evaluates the condition and inline size exactly as today and appends to `(group alias).entries`, and likewise for `Exit`, `Size` (at-most-one check per group), `Target`, `Cap` (at-most-one per group). Note the unaliased single-stock file flows through the same table under key `None`, so the all-or-nothing rule falls out of `declared_aliases`.

5. Factor the current style-resolution block (the `has_target` / `style_2` / legacy logic, lines 448-561) into `let compile_group context group = ... : float array` operating on one `Group.t`, unchanged logic and error messages. `compile_ast` finishes with:

```ocaml
  let strategy : Engine.strategy =
    { targets =
        Array.of_list
          (List.map
             (fun (alias, _) ->
               match Hashtbl.find_opt groups alias with
               | Some g -> compile_group context g
               | None ->
                   failwith
                     (match alias with
                      | Some name ->
                          Printf.sprintf "stock alias %s has no statements" name
                      | None -> "strategy has no statements"))
             assets) }
  in
  strategy
```

6. `compile source ~params bars` parses, calls `stocks_of`, and for a single unaliased stock calls `compile_ast ~assets:[ (None, bars) ]`; anything else fails with `Dsl.compile supports single unaliased stocks; use compile_ast`.

7. `stock_of` is deleted. `test/test_bt.ml:321` and `test/test_bt.ml:328` (in `test_stock_statement`) migrate to `stocks_of`: the single-stock assertion becomes `Dsl.stocks_of ~filename:path parsed = [ (None, "tw", "00685L") ]`, and the rejection cases keep failing (no stock; two unaliased stocks).

In `bin/bt.ml`:

- `strategy_input` becomes `{ name; stocks : (string option * string * string) list; ast; declarations; bars : Data.bar array list }` (bars in stock order).
- Input construction calls `Btlib.Dsl.stocks_of` and loads bars per stock. The `arrays` list for `common_dates` flattens every file's bars lists (plus the baseline), and `filter` maps over each file's list.
- The run per input becomes:

```ocaml
        let assets_for_compile =
          List.map2
            (fun (alias, _, _) bars -> (alias, bars))
            input.stocks input.bars
        in
        let strategy =
          Btlib.Dsl.compile_ast input.ast ~params ~assets:assets_for_compile
        in
        let labels =
          List.map
            (fun (_, market, symbol) -> market ^ "/" ^ symbol)
            input.stocks
        in
        let engine_assets =
          Array.of_list (List.map2 (fun label bars -> (label, bars)) labels input.bars)
        in
        let costs =
          Array.of_list
            (List.map
               (fun (_, market, symbol) ->
                 apply_cost_overrides
                   (Btlib.Engine.default_costs ~market ~symbol)
                   !fee_bps !tax_bps !slip_bps !min_fee)
               input.stocks)
        in
        let result =
          Btlib.Engine.run engine_assets strategy costs
            ~capital:!capital ~fill:!fill
        in
        let gross = Array.make (Array.length (snd engine_assets.(0))) 0. in
        Array.iter
          (fun target ->
            Array.iteri (fun t value -> gross.(t) <- gross.(t) +. value) target)
          strategy.targets;
        (input.name, String.concat "+" labels, gross, result)
```

- The duplicate-basename and unknown-parameter checks and the report calls stay as they are (`stocks` now maps name to the joined labels, `targets` to the gross arrays).

- [ ] **Step 4: Verify build and tests pass**

Run: `opam exec -- dune build && opam exec -- dune runtest`
Expected: build clean, tests print `ok` - including every existing single-stock test through the new `compile`/`compile_ast` path.

- [ ] **Step 5: Commit**

```bash
git add lib/dsl.ml bin/bt.ml test/test_bt.ml
git commit -m "feat: compile and run multi-stock strategies

Co-authored-by: ChatGPT <noreply@openai.com>"
```

---

### Task 4: Documentation and end-to-end smoke

**Files:**
- Modify: `docs/strategy.md` (styles, statements, grammar), `docs/cli.md` (trades.csv header), `CONTRIBUTING.md` (module table `lib/engine.ml` line)
- Create (local only, never committed): `/tmp/hedge_smoke.strat`

**Interfaces:**
- Consumes: everything from Tasks 1-3.

- [ ] **Step 1: Update the docs**

Read each file section immediately before editing; surgical edits only.

`docs/strategy.md`:
- Add a "Multi-stock strategies" section after "Strategy styles" documenting: `stock "m/sym" as alias`, the all-or-nothing alias rule, dotted statements (`bull.target`, `bear.entry when ... size ...`, `bear.exit when`, `bull.size`, `bear.cap`), dotted series (`alias.close`), `alias.atr(n)`, per-stock style grouping, file-global `param`/`let`, cross-asset expressions, calendar intersection, and the error rules from the spec's DSL section (translate the spec list; keep STE style).
- Update the BNF: `"stock" string [ "as" ident ]`, optional `[ident "."]` prefixes on entry/exit/size/target/cap, and the two dotted expr productions.
- Update the statements list: each stock-scoped statement notes its dotted form; note that trips are per stock with `net_ret = exit VWAP / entry VWAP - 1`, costs excluded.

`docs/cli.md`: in the outputs section, change the trades.csv description to the header `date,stock,price,from_exposure,to_exposure` and note one row per fill per stock.

`CONTRIBUTING.md`: update the `lib/engine.ml` module line to say portfolio engine (per-asset targets and costs).

- [ ] **Step 2: End-to-end smoke on real data**

```bash
cat > /tmp/hedge_smoke.strat <<'EOF'
stock "tw/00685L" as bull
stock "tw/0050" as base

let slope = sma(bull.close, 47) / lag(sma(bull.close, 47), 7) - 1
let falling = slope < -0.012

bull.target 1.0 * num(not falling)
base.target 0.5 * num(falling)
EOF
opam exec -- dune build && opam exec -- dune runtest
_build/default/bin/bt.exe run /tmp/hedge_smoke.strat --baseline tw/00685L \
  --data-dir data --out-dir /tmp/hedge-smoke --out-name hedge_smoke --no-plot
head -3 /tmp/hedge-smoke/hedge_smoke.trades.csv
```

Expected: tests print `ok`; the report prints one `hedge_smoke` column plus baseline with a date range starting 2017-03-30 (the 00685L/0050 intersection); the trades CSV header is `date,stock,price,from_exposure,to_exposure` and rows name both `tw/00685L` and `tw/0050`; a `warning: prices unadjusted for splits/reductions` line for 0050 is acceptable (its events cache may not exist).

- [ ] **Step 3: Commit**

```bash
git add docs/strategy.md docs/cli.md CONTRIBUTING.md
git commit -m "docs: multi-stock strategy language and portfolio outputs

Co-authored-by: ChatGPT <noreply@openai.com>"
```
