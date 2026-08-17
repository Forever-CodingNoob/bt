# Fill Modes and Fractional Sizing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rewrite the engine around a target-exposure array with two fill modes, and let strategies scale in and out through three DSL styles.

**Architecture:** The engine consumes one canonical form: `target.(t)` = desired exposure decided at close t. It trades the difference between held and target exposure, at the same close (`Close_same`, new default) or the next open (`Open_next`, old behavior). The DSL compiles three styles (target expression, partial orders, legacy entry/exit) to that array.

**Tech Stack:** OCaml stdlib + unix, dune, ocamllex/ocamlyacc. No new dependencies.

**Spec:** `docs/specs/fill-mode-and-sizing.md` (committed). Read it first.

## Global Constraints

- OCaml stdlib and `unix` only. No opam package dependencies.
- List recursion must be tail-recursive; series math uses `Array` index loops.
- Numeric series are `float array`; warmup is `Float.nan`; NaN comparisons give `false`.
- One space on each side of `=`; no alignment padding; no emojis.
- Do not touch `lib/data.ml`, `lib/series.ml` (except nothing), fetch, cache, or plot code.
- Do NOT run `git commit`. Stage files and report; the coordinator commits after user confirmation (session rule).
- Do not run formatters or linters. `dune build --root .` and `dune test --root .` are the only project commands to run, and only where a step says so.
- `README.md` contains user-authored sections (Contributing, Acknowledgements). Edit README surgically; never rewrite the file.

---

### Task 1: Engine rewrite, legacy compile, CLI flag

**Files:**
- Modify: `lib/engine.ml` (full rewrite of types and `run`)
- Modify: `lib/dsl.ml` (replace the strategy assembly at the end of `compile`)
- Modify: `lib/metrics.ml` (trade stats read trips)
- Modify: `lib/report.ml` (fill log CSV, fill-mode line, footer from target)
- Modify: `bin/bt.ml` (`--fill` flag, benchmark target)
- Modify: `test/test_bt.ml` (port engine tests, add fill-mode tests)

**Interfaces:**
- Consumes: `Data.bar = { date; o; h; l; c; v }` (unchanged).
- Produces (later tasks rely on these exact names):
  - `Engine.strategy = { target : float array }`
  - `Engine.fill = Open_next | Close_same`
  - `Engine.fill_event = { date : string; price : float; from_e : float; to_e : float }`
  - `Engine.trip = { entry_date : string; exit_date : string; net_ret : float }`
  - `Engine.result = { equity_curve : (string * float) list; fills : fill_event list; trips : trip list }`
  - `Engine.run : Data.bar array -> strategy -> costs -> fill:fill -> result`
  - `Dsl.compile : string -> params:(string * float) list -> Data.bar array -> Engine.strategy` (unchanged signature)
  - `Report.print ~strategy ~benchmark ~target ~fill` (target replaces sizes; fill is `Engine.fill`)

- [ ] **Step 1: Rewrite `lib/engine.ml`**

Replace the whole file body after the `costs` type. Keep `default_costs` and `side_cost` deletion is fine (`side_cost` is absorbed):

```ocaml
type strategy = { target : float array }

type costs = {
  fee_bps : float;
  tax_bps : float;
  slip_bps : float;
}

type fill = Open_next | Close_same

type fill_event = {
  date : string;
  price : float;
  from_e : float;
  to_e : float;
}

type trip = {
  entry_date : string;
  exit_date : string;
  net_ret : float;
}

type result = {
  equity_curve : (string * float) list;
  fills : fill_event list;
  trips : trip list;
}

let default_costs ~market ~symbol =
  (* copy the current body from lib/engine.ml verbatim: the market match
     with TW fee 14.25, ETF/stock tax split, and the invalid_arg case *)
  <current body, unchanged>

(* NaN means flat; short exposure is out of scope *)
let clamp_target value =
  if Float.is_nan value || value < 0. then 0. else value

let run (bars : Data.bar array) (strategy : strategy) (costs : costs) ~fill =
  let length = Array.length bars in
  if Array.length strategy.target <> length then
    invalid_arg "Engine.run: target length mismatch";
  let equity = ref 1. in
  let exposure = ref 0. in
  let entry_equity = ref 1. in
  let entry_date = ref "" in
  let fills = ref [] in
  let trips = ref [] in
  let equity_curve = ref [] in
  let trade ~date ~price ~desired =
    let delta = desired -. !exposure in
    if delta <> 0. then begin
      if !exposure = 0. then begin
        entry_equity := !equity;
        entry_date := date
      end;
      let bps =
        if delta > 0. then costs.fee_bps +. costs.slip_bps
        else costs.fee_bps +. costs.tax_bps +. costs.slip_bps
      in
      equity := !equity *. (1. -. abs_float delta *. bps /. 10000.);
      fills := { date; price; from_e = !exposure; to_e = desired } :: !fills;
      exposure := desired;
      if desired = 0. then
        trips :=
          { entry_date = !entry_date; exit_date = date;
            net_ret = !equity /. !entry_equity -. 1. } :: !trips
    end
  in
  for t = 0 to length - 1 do
    let bar = bars.(t) in
    (match fill with
     | Close_same ->
         if t > 0 then
           equity :=
             !equity *.
             (1. +. !exposure *. (bar.Data.c /. bars.(t - 1).Data.c -. 1.));
         trade ~date:bar.Data.date ~price:bar.Data.c
           ~desired:(clamp_target strategy.target.(t))
     | Open_next ->
         if t > 0 then begin
           let desired = clamp_target strategy.target.(t - 1) in
           if desired <> !exposure then begin
             (* two-leg day: accrue to the open, fill, accrue to the close *)
             equity :=
               !equity *.
               (1. +. !exposure *. (bar.Data.o /. bars.(t - 1).Data.c -. 1.));
             trade ~date:bar.Data.date ~price:bar.Data.o ~desired;
             equity :=
               !equity *.
               (1. +. !exposure *. (bar.Data.c /. bar.Data.o -. 1.))
           end
           else
             equity :=
               !equity *.
               (1. +. !exposure *. (bar.Data.c /. bars.(t - 1).Data.c -. 1.))
         end);
    equity_curve := (bar.Data.date, !equity) :: !equity_curve
  done;
  if !exposure > 0. then begin
    let last = bars.(length - 1) in
    let bps = costs.fee_bps +. costs.tax_bps +. costs.slip_bps in
    equity := !equity *. (1. -. !exposure *. bps /. 10000.);
    fills :=
      { date = last.Data.date; price = last.Data.c;
        from_e = !exposure; to_e = 0. } :: !fills;
    trips :=
      { entry_date = !entry_date; exit_date = last.Data.date;
        net_ret = !equity /. !entry_equity -. 1. } :: !trips;
    (match !equity_curve with
     | _ :: rest -> equity_curve := (last.Data.date, !equity) :: rest
     | [] -> ())
  end;
  { equity_curve = List.rev !equity_curve;
    fills = List.rev !fills;
    trips = List.rev !trips }
```

Notes for the implementer:
- The `Open_next` no-fill day uses the close-to-close formula on purpose: it is bit-identical to the old engine, which the golden test depends on.
- `trade` with `delta = 0.` does nothing, so calling it every bar in `Close_same` is safe.

- [ ] **Step 2: Replace the strategy assembly in `lib/dsl.ml`**

In `compile`, the fold over statements stays as is (it collects `entry`, `exit_`, and `size` values). Replace everything from `let size = ...` to the end of the function with a legacy state walk that emits the target array:

```ocaml
  let size_at =
    match size with
    | None -> (fun _ -> 1.)
    | Some (_, Scalar number) -> (fun _ -> number)
    | Some (expression, Series series) ->
        if Array.length series <> context.length then
          fail_expr expression "size series length mismatch";
        (fun t -> series.(t))
    | Some (expression, Bools _) ->
        fail_expr expression "size must be a scalar or numeric series"
  in
  let clamp_legacy value =
    if Float.is_nan value || value <= 0. then 1. else value
  in
  let target = Array.make context.length 0. in
  let in_position = ref false in
  let held = ref 0. in
  for t = 0 to context.length - 1 do
    if !in_position then begin
      if exit_.(t) then in_position := false
      else target.(t) <- !held
    end
    else if entry.(t) then begin
      held := clamp_legacy (size_at t);
      in_position := true;
      target.(t) <- !held
    end
  done;
  let strategy : Engine.strategy = { target } in
  strategy
```

`entry` and `exit_` here are the bool arrays already produced by the fold. This walk reproduces the old engine exactly: entry only while flat, exit only while in position, exposure fixed at entry, size read at the entry bar.

- [ ] **Step 3: Adapt `lib/metrics.ml`**

`n_trades` and `win_rate` switch from `Engine.trade` to `Engine.trip`. The `trip` record keeps the `net_ret` field name, so the only changes are type annotations and `of_result`:

```ocaml
let of_result (result : Engine.result) =
  calculate result.equity_curve result.trips
```

Rename every `trades` parameter to `trips` in this file for honesty; the win predicate `net_ret > 0.` is unchanged.

- [ ] **Step 4: Adapt `lib/report.ml`**

- `write_trades_csv` becomes a fill log. Header and rows:

```ocaml
let write_trades_csv ~out_dir (fills : Engine.fill_event list) =
  (* same file plumbing as before, new content *)
  ... "date,price,from_exposure,to_exposure" ...
  List.iter
    (fun (fill : Engine.fill_event) ->
      Printf.fprintf output "%s,%.17g,%.17g,%.17g\n"
        fill.date fill.price fill.from_e fill.to_e)
    fills
```

- `print` takes `~target : float array` instead of `~sizes` and a new `~fill : Engine.fill`. The footer condition becomes max of the target array (ignore NaN). The date-range line gains the mode:

```ocaml
Printf.printf "Date range: %s to %s; fill: %s\n" first last
  (match fill with Engine.Close_same -> "close" | Engine.Open_next -> "open")
```

- Trade count line reads `List.length strategy.trips`.

- [ ] **Step 5: Adapt `bin/bt.ml`**

- Add the flag (default close):

```ocaml
let fill = ref Btlib.Engine.Close_same in
(* in the options list *)
("--fill",
 Arg.String
   (fun value ->
     match value with
     | "open" -> fill := Btlib.Engine.Open_next
     | "close" -> fill := Btlib.Engine.Close_same
     | _ -> raise (Arg.Bad "--fill must be open or close")),
 "fill mode: open or close (default close)");
```

- Benchmark: `let benchmark_strategy length : Btlib.Engine.strategy = { target = Array.make length 1. }`.
- Pass `~fill:!fill` to both `Engine.run` calls; pass `~target:strategy.target ~fill:!fill` to `Report.print`.

- [ ] **Step 6: Port and extend `test/test_bt.ml`**

Define shared bars for fill tests (open, close; h and l are irrelevant to the engine):

```ocaml
let fill_bars =
  [| bar "2020-01-01" 100. 100.;
     bar "2020-01-02" 102. 104.;
     bar "2020-01-03" 106. 108.;
     bar "2020-01-06" 110. 112.;
     bar "2020-01-07" 114. 116. |]

let zero_costs : Engine.costs = { fee_bps = 0.; tax_bps = 0.; slip_bps = 0. }

let test_engine_close () =
  let strategy : Engine.strategy = { target = [| 0.; 1.; 1.; 0.; 0. |] } in
  let result = Engine.run fill_bars strategy zero_costs ~fill:Engine.Close_same in
  (* buy at close 104, accrue 108/104 and 112/108, sell at close 112 *)
  assert_close ~tolerance:1e-12 (112. /. 104.) (final_equity result);
  assert (List.length result.fills = 2);
  assert (List.length result.trips = 1);
  let trip = List.hd result.trips in
  assert (trip.Engine.entry_date = "2020-01-02");
  assert (trip.Engine.exit_date = "2020-01-06");
  (* NaN target means flat: same run with a NaN leading bar *)
  let with_nan : Engine.strategy = { target = [| Float.nan; 1.; 1.; 0.; 0. |] } in
  let result_nan = Engine.run fill_bars with_nan zero_costs ~fill:Engine.Close_same in
  assert_close ~tolerance:1e-12 (final_equity result) (final_equity result_nan)

let test_engine_close_costs () =
  let strategy : Engine.strategy = { target = [| 0.; 1.; 1.; 0.; 0. |] } in
  let costs : Engine.costs = { fee_bps = 100.; tax_bps = 0.; slip_bps = 0. } in
  let result = Engine.run fill_bars strategy costs ~fill:Engine.Close_same in
  (* 1% haircut on each side of the round trip *)
  assert_close ~tolerance:1e-12 (0.99 *. 0.99 *. 112. /. 104.) (final_equity result)

let test_engine_partial () =
  let strategy : Engine.strategy = { target = [| 0.; 0.5; 1.; 0.5; 0. |] } in
  let result = Engine.run fill_bars strategy zero_costs ~fill:Engine.Close_same in
  let expected =
    (1. +. 0.5 *. (108. /. 104. -. 1.))
    *. (112. /. 108.)
    *. (1. +. 0.5 *. (116. /. 112. -. 1.))
  in
  assert_close ~tolerance:1e-12 expected (final_equity result);
  assert (List.length result.fills = 4);
  assert (List.length result.trips = 1);
  assert ((List.hd result.trips).Engine.net_ret > 0.)

let test_engine_partial_costs () =
  let strategy : Engine.strategy = { target = [| 0.; 0.5; 1.; 0.5; 0. |] } in
  let costs : Engine.costs = { fee_bps = 100.; tax_bps = 0.; slip_bps = 0. } in
  let result = Engine.run fill_bars strategy costs ~fill:Engine.Close_same in
  (* each 0.5-point fill costs 0.5 * 1% = 0.005, in engine order *)
  let expected =
    0.995
    *. (1. +. 0.5 *. (108. /. 104. -. 1.)) *. 0.995
    *. (112. /. 108.) *. 0.995
    *. (1. +. 0.5 *. (116. /. 112. -. 1.)) *. 0.995
  in
  assert_close ~tolerance:1e-12 expected (final_equity result)

let test_engine_partial_open () =
  (* same targets under Open_next: fills at the next opens 106, 110, 114;
     the 0.5 exposure left at the end is force-closed at the last close *)
  let strategy : Engine.strategy = { target = [| 0.; 0.5; 1.; 0.5; 0. |] } in
  let result = Engine.run fill_bars strategy zero_costs ~fill:Engine.Open_next in
  let expected =
    (1. +. 0.5 *. (108. /. 106. -. 1.))
    *. (1. +. 0.5 *. (110. /. 108. -. 1.)) *. (112. /. 110.)
    *. (114. /. 112.) *. (1. +. 0.5 *. (116. /. 114. -. 1.))
  in
  assert_close ~tolerance:1e-12 expected (final_equity result);
  assert (List.length result.fills = 4);
  assert (List.length result.trips = 1)
```

Port the existing frozen-literal tests to the new API (same sample bars, same literals; the old entry-at-bar-1 test becomes target `[| 0.; 1.; 1.; 1.; 1. |]` under `~fill:Engine.Open_next`, which is the identical trade). The golden test builds the strategy with `Dsl.compile` as today and runs with `~fill:Engine.Open_next`; `golden_expected` stays `1.7291207425596153`. Update `final_equity`, trade-stat helpers, and the test runner list.

- [ ] **Step 7: Build and test**

Run: `eval $(opam env) && dune build --root . && dune test --root . --force`
Expected: build clean, `ok`. The golden literal must pass unchanged; if it fails, the `Open_next` path deviates from the old engine — fix the engine, never the literal.

- [ ] **Step 8: Stage and report**

`git add -A` and report the diff summary. Do not commit.

---

### Task 2: DSL styles, new syntax, new builtins

**Files:**
- Modify: `lib/ast.ml` (Entry/Exit carry optional size; Target and Cap statements)
- Modify: `lib/lexer.mll` (NEWLINE token, `target` and `cap` keywords)
- Modify: `lib/parser.mly` (line-based statements, new productions)
- Modify: `lib/dsl.ml` (style detection, style walks, `hold`, `num`, cross broadcast)
- Modify: `test/test_bt.ml` (style, builtin, and error tests)

**Interfaces:**
- Consumes: `Engine.strategy = { target : float array }`, `Dsl.compile` signature from Task 1.
- Produces: DSL accepts three styles per the spec. New builtins `hold(set, reset)` and `num(b)`. `cross_above`/`cross_below` accept scalar arguments.

- [ ] **Step 1: Update `lib/ast.ml`**

```ocaml
type stmt =
  | Param of string * float
  | Let of string * expr
  | Entry of expr * expr option   (* condition, optional inline size *)
  | Exit of expr * expr option
  | Size of expr                  (* legacy standalone size *)
  | Target of expr
  | Cap of float
```

- [ ] **Step 2: Make the lexer line-based and add keywords**

In `lib/lexer.mll`: the `'\n'` rule becomes `{ Lexing.new_line lexbuf; NEWLINE }` (it no longer skips). Add `"target" -> TARGET` and `"cap" -> CAP` to the keyword function. `#` comments still stop before the newline, so a comment line still yields NEWLINE.

- [ ] **Step 3: Rework the grammar in `lib/parser.mly`**

Statements are one per line. This makes inline `size` unambiguous against the standalone `size` statement (the standalone form always follows a NEWLINE).

```
%token NEWLINE TARGET CAP

file:
  lines EOF        { List.rev $1 }
| lines stmt EOF   { List.rev ($2 :: $1) }
;

lines:
  /* empty */      { [] }
| lines NEWLINE    { $1 }
| lines stmt NEWLINE { $2 :: $1 }
;

stmt:
  PARAM IDENT ASSIGN NUMBER      { Param ($2, $4) }
| LET IDENT ASSIGN expr          { Let ($2, $4) }
| ENTRY WHEN expr                { Entry ($3, None) }
| ENTRY WHEN expr SIZE expr      { Entry ($3, Some $5) }
| EXIT WHEN expr                 { Exit ($3, None) }
| EXIT WHEN expr SIZE expr       { Exit ($3, Some $5) }
| SIZE expr                      { Size $2 }
| TARGET expr                    { Target $2 }
| CAP NUMBER                     { Cap $2 }
;
```

`expr` productions are unchanged. Treat any ocamlyacc shift/reduce conflict report as a bug to fix, not to ignore.

- [ ] **Step 4: Style detection and compilation in `lib/dsl.ml`**

Collect statement groups after evaluation of `param`/`let` bindings (the fold keeps its environment behavior; Entry/Exit conditions and inline sizes are evaluated in statement order as today). Then:

```ocaml
(* style selection, per spec *)
let has_target = targets <> [] in
let has_inline = List.exists (fun (_, s) -> s <> None) entries
              || List.exists (fun (_, s) -> s <> None) exits in
let style_2 = not has_target
              && (has_inline || cap <> None
                  || List.length entries > 1 || List.length exits > 1) in
if has_target then begin
  if List.length targets > 1 then failwith "only one target statement is allowed";
  if entries <> [] || exits <> [] then
    failwith "target cannot be mixed with entry/exit statements";
  if cap <> None then failwith "cap is only valid with entry/exit sizes";
  if size <> None then failwith "size is only valid in legacy entry/exit style";
  (* style 1: the "Style 1 target assembly" block below *)
  <style 1 target assembly>
end
else if style_2 then begin
  if size <> None then
    failwith "standalone size cannot be mixed with inline sizes";
  if entries = [] then failwith "at least one entry statement is required";
  (* the "Style 2 walk" block below *)
  <style 2 walk>
end
else
  (* style 3: exactly one entry and one exit required, else the existing
     errors; then the legacy state walk installed by Task 1 Step 2 *)
  <legacy walk from Task 1>
```

Style 1 target assembly:

```ocaml
let target =
  match value with
  | Scalar number -> Array.make context.length number
  | Series series ->
      if Array.length series <> context.length then
        fail_expr expression "target series length mismatch";
      series
  | Bools _ -> fail_expr expression "target must be numeric"
```

Style 2 walk (all sizes are exposure points; a size value is read at the firing bar; NaN contributes 0):

```ocaml
let cap_value = match cap with None -> 1.0 | Some value -> value in
let size_points value_at t =
  let v = value_at t in
  if Float.is_nan v then 0. else v
in
let target = Array.make context.length 0. in
let exposure = ref 0. in
for t = 0 to context.length - 1 do
  let delta = ref 0. in
  List.iter (fun (cond, points_at) ->
      if cond.(t) then delta := !delta +. size_points points_at t)
    entry_signals;
  List.iter (fun (cond, points_at) ->
      if cond.(t) then delta := !delta -. size_points points_at t)
    exit_signals;
  exposure := Float.min cap_value (Float.max 0. (!exposure +. !delta));
  target.(t) <- !exposure
done
```

`entry_signals`/`exit_signals` are lists of (bool array, size lookup) built from the evaluated statements. A missing inline size means the constant 1.0. An inline size expression must evaluate to a Scalar or Series (reject Bools with `fail_expr`); Series values are read per bar.

- [ ] **Step 5: New builtins and cross broadcast in `lib/dsl.ml`**

- `builtin_arity`: add `| "num" -> Some 1` and `| "hold" -> Some 2`.
- `eval_call` additions:

```ocaml
| "num", [value] ->
    (match value with
     | Bools flags ->
         let out = Array.make (Array.length flags) 0. in
         for i = 0 to Array.length flags - 1 do
           if flags.(i) then out.(i) <- 1.
         done;
         Series out
     | _ -> fail_expr expression "num expects a boolean series")
| "hold", [set; reset] ->
    (match set, reset with
     | Bools set, Bools reset ->
         check_bool_lengths expression set reset;
         let out = Array.make (Array.length set) false in
         let state = ref false in
         for i = 0 to Array.length set - 1 do
           if reset.(i) then state := false
           else if set.(i) then state := true;
           out.(i) <- !state
         done;
         Bools out
     | _ -> fail_expr expression "hold expects two boolean series")
```

Note the order inside the loop: reset wins on a tie, per spec.

- Cross broadcast: before calling `Series.cross_above`/`cross_below`, materialize a Scalar operand with `Array.make context.length number`; keep Series operands as is; reject Bools.

- [ ] **Step 6: Tests**

Add to `test/test_bt.ml` (uses `with_temp_strategy` and `assert_failure` helpers already present; write DSL sources with `\n` separators — the parser is now line-based):

```ocaml
let dsl_bars =
  (* closes 100 105 110 100 90; open = previous close *)
  [| bar "2020-01-01" 100. 100.;
     bar "2020-01-02" 100. 105.;
     bar "2020-01-03" 105. 110.;
     bar "2020-01-06" 110. 100.;
     bar "2020-01-07" 100. 90. |]

let test_target_style () =
  with_temp_strategy
    "target num(hold(cross_above(close, 104.0), cross_below(close, 104.0)))\n"
    (fun path ->
      let strategy = Dsl.compile path ~params:[] dsl_bars in
      assert (strategy.Engine.target = [| 0.; 1.; 1.; 0.; 0. |]);
      let result = Engine.run dsl_bars strategy zero_costs ~fill:Engine.Close_same in
      (* buy close 105, accrue 110/105 then 100/110, sell close 100 *)
      assert_close ~tolerance:1e-12 (100. /. 105.) (final_equity result);
      assert (List.length result.trips = 1);
      assert ((List.hd result.trips).Engine.net_ret < 0.))

let test_order_style () =
  with_temp_strategy
    ("cap 1.0\n\
      entry when cross_above(close, 104.0) size 0.5\n\
      entry when cross_above(close, 108.0) size 0.5\n\
      exit when cross_below(close, 104.0) size 1.0\n")
    (fun path ->
      let strategy = Dsl.compile path ~params:[] dsl_bars in
      assert (strategy.Engine.target = [| 0.; 0.5; 1.; 0.; 0. |]))

let test_style_errors () =
  let rejects source =
    with_temp_strategy source (fun path ->
      assert_failure (fun () -> ignore (Dsl.compile path ~params:[] dsl_bars)))
  in
  rejects "target 1.0\nentry when close > 0.0\nexit when close < 0.0\n";
  rejects "target 1.0\ntarget 0.5\n";
  rejects "target 1.0\ncap 1.0\n";
  rejects "entry when close > 0.0 size 0.5\nsize 1.0\n";
  rejects "exit when close < 0.0 size 0.5\n"
```

The legacy examples (`sma_cross.strat`, `bb_macd.strat`) must still parse and compile; the existing parser tests cover this. Register the new tests in the runner.

- [ ] **Step 7: Build and test**

Run: `eval $(opam env) && dune build --root . && dune test --root . --force`
Expected: build clean (zero ocamlyacc conflicts), `ok`, golden literal untouched.

- [ ] **Step 8: Stage and report**

`git add -A` and report. Do not commit.

---

### Task 3: Documentation and end-to-end verification

**Files:**
- Modify: `README.md` (surgical: engine section, DSL section additions, CLI grammar line)
- Modify: `CONTRIBUTING.md` (fixed contract update)

**Interfaces:**
- Consumes: the shipped behavior of Tasks 1-2.
- Produces: docs that match the spec; verified binary.

- [ ] **Step 1: Update `README.md` surgically**

Read the file first; it contains user-authored sections that must survive.
- CLI block: add `[--fill open|close]` to the `bt run` line and a bullet: "`--fill` selects the fill point: `close` fills at the decision close (default), `open` fills at the next open."
- "How the engine trades": replace the first bullet with the two-mode description; add: "A strategy states a target exposure per bar; the engine trades the difference and charges costs on the traded fraction."
- DSL section: add the three styles with a short example each (copy from `docs/specs/fill-mode-and-sizing.md`), the `hold`/`num` builtin entries under "Signal helpers", the cross scalar-broadcast note, and one sentence: "Statements are one per line."
- Data/outputs: `trades.csv` header is now `date,price,from_exposure,to_exposure`; the report prints the fill mode.

- [ ] **Step 2: Update `CONTRIBUTING.md`**

In "Fixed contracts", replace the `Engine.strategy` line with `Engine.strategy` = `{ target : float array }` and note the two fill modes. In "How to add an indicator" nothing changes.

- [ ] **Step 3: End-to-end verification (coordinator or executor with cached data; no network)**

```sh
eval $(opam env) && dune build --root . && dune test --root . --force
./_build/default/bin/bt.exe run examples/bb_macd.strat --market tw --symbol 0050 --benchmark 00685L --no-plot
./_build/default/bin/bt.exe run examples/bb_macd.strat --market tw --symbol 0050 --benchmark 00685L --fill open --no-plot
printf 'target 1.0\n' > /tmp/always.strat
./_build/default/bin/bt.exe run /tmp/always.strat --market tw --symbol 00685L --benchmark 00685L --no-plot
```

Expected:
- Both bb_macd runs print the table with `fill: close` / `fill: open` on the date-range line.
- The always-in target run matches the benchmark column exactly on every metric (self-consistency in close mode).
- `out/trades.csv` has the `date,price,from_exposure,to_exposure` header.

- [ ] **Step 4: Stage and report**

`git add -A` and report. Do not commit.
