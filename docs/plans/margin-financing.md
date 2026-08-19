# Margin Financing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Positions drift between fills; borrowed cash pays 6.35%/yr financing; TW financing ratios cap initial margin; maintenance below 130% force-liquidates at the next open.

**Architecture:** The engine's state becomes cash plus per-asset position values (negative cash is the loan); exposure is derived and drifts. Fills fire only when the clamped target series changes value. A `margin` record (rate, maintenance, per-asset ratios) parameterizes the run; `result` gains margin statistics. `bt fetch` caches `TaiwanStockInfo` for TWSE/TPEX classification; three CLI flags configure the run; the report prints one margin line per strategy that borrowed.

**Tech Stack:** OCaml (stdlib + Unix), dune, single test binary `test/test_bt.ml`.

**Spec:** `docs/specs/margin-financing.md`

## Global Constraints

- Verification command for every task: `opam exec -- dune build && opam exec -- dune runtest` from the repo root.
- Exactness invariant: strategies whose targets are only 0 or 1 (and the baseline) produce byte-identical equity output. Only tests holding a fractional or leveraged target constant across two or more bars change, each with a derivation comment.
- Fill semantics: a fill fires only when the clamped effective target changes from the previous bar (plus a nonzero target on bar 0). Forced liquidation is the only other trade. After liquidation the account stays flat until the effective target next changes value.
- Fill mechanics per asset, in declaration order: `from_e = v_i / equity`; cost fraction = `|target - from_e| * rate_i` with the existing buy/sell split and min-fee floor; charge cash; then `v_i = target * post-cost-equity`, difference through cash.
- Interest: when cash < 0, before accrual on each bar t > 0, `cash -= (-cash) * rate * days / 365` with `days` = calendar-day gap between bar dates.
- Initial margin: at fill time scale all requested targets uniformly by `k = min(1, 1 / sum_i t_i * (1 - ratio_i))`; count `k < 1` once per fill bar. Scaled targets are the effective targets for later change detection.
- Maintenance: after the close of a bar with cash < 0, `sum v_i / (-cash)` below the maintenance ratio schedules full liquidation at the next bar's opens.
- Defaults: financing 6.35%/yr, maintenance 130%, ratios twse 0.6 / tpex 0.5, unknown 0.6 with a warning.
- Style: two-space indent, one space on each side of `=`. Commit trailer on every commit, after one blank line: `Co-authored-by: ChatGPT <noreply@openai.com>`. `data/` is gitignored.

---

### Task 1: Drift-accounting engine with margin mechanics

**Files:**
- Modify: `lib/engine.ml` (types and `run`), `bin/bt.ml` (temporary margin-off argument), `test/test_bt.ml`
- Test: `test/test_bt.ml`

**Interfaces:**
- Produces:

```ocaml
type margin = {
  financing_rate : float;      (* annual fraction, e.g. 0.0635 *)
  maintenance_ratio : float;   (* fraction, e.g. 1.3 *)
  ratios : float array;        (* per-asset financing ratio, e.g. 0.6 *)
}

type margin_stats = {
  min_maintenance : float option;  (* None when never borrowed *)
  margin_calls : int;
  clamps : int;
}
```

  `result` gains `margin_stats : margin_stats`. `run` gains `~margin:margin`. Tasks 2-4 consume these.

- [ ] **Step 1: Write the failing tests**

In `test/test_bt.ml`, change `run_single` to pass a margin-off record, add the helpers, and add six tests (register all in the runner):

```ocaml
let no_margin count : Engine.margin =
  { financing_rate = 0.; maintenance_ratio = 0.;
    ratios = Array.make count 1. }

let run_single bars target costs ~capital ~fill =
  Engine.run [| ("tw/TEST", bars) |] { Engine.targets = [| target |] }
    [| costs |] ~margin:(no_margin 1) ~capital ~fill
```

```ocaml
let test_engine_drift () =
  (* constant 0.5 target: one fill, position drifts, no daily reset *)
  let bars =
    [| bar "2020-01-01" 100. 100.;
       bar "2020-01-02" 105. 110.;
       bar "2020-01-03" 115. 121. |]
  in
  let result =
    run_single bars [| 0.5; 0.5; 0.5 |] zero_costs
      ~capital:None ~fill:Engine.Close_same
  in
  (* v = 0.5 -> 0.55 -> 0.605; cash 0.5; equity 1.105 (reset would give
     1.05 * 1.05 = 1.1025) *)
  assert_close ~tolerance:1e-12 (0.5 +. 0.5 *. 1.1 *. (121. /. 110.))
    (final_equity result);
  (* one entry fill plus the final force-close *)
  assert (List.length result.fills = 2);
  (match result.trips with
   | [trip] -> assert_close ~tolerance:1e-12 (121. /. 100. -. 1.) trip.net_ret
   | _ -> assert false)

let test_engine_interest () =
  (* 2x held over a weekend: 3 calendar days accrue, then 1 day *)
  let bars =
    [| bar "2020-01-03" 100. 100.;
       bar "2020-01-06" 100. 100.;
       bar "2020-01-07" 100. 100. |]
  in
  let margin : Engine.margin =
    { financing_rate = 0.0635; maintenance_ratio = 1.3;
      ratios = [| 0.6 |] }
  in
  let result =
    Engine.run [| ("tw/TEST", bars) |]
      { Engine.targets = [| [| 2.; 2.; 2. |] |] }
      [| zero_costs |] ~margin ~capital:None ~fill:Engine.Close_same
  in
  let expected =
    2. -. (1. +. 0.0635 *. 3. /. 365.) *. (1. +. 0.0635 /. 365.)
  in
  assert_close ~tolerance:1e-12 expected (final_equity result)

let test_engine_initial_margin_clamp () =
  (* requested 3x on a 60% ratio scales to 2.5x once *)
  let bars =
    [| bar "2020-01-01" 100. 100.;
       bar "2020-01-02" 100. 100. |]
  in
  let margin : Engine.margin =
    { financing_rate = 0.; maintenance_ratio = 0.; ratios = [| 0.6 |] }
  in
  let result =
    Engine.run [| ("tw/TEST", bars) |]
      { Engine.targets = [| [| 3.; 3. |] |] }
      [| zero_costs |] ~margin ~capital:None ~fill:Engine.Close_same
  in
  assert (result.margin_stats.Engine.clamps = 1);
  (match result.fills with
   | first :: _ -> assert_close ~tolerance:1e-12 2.5 first.Engine.to_e
   | [] -> assert false);
  assert_close ~tolerance:1e-12 1. (final_equity result)

let test_engine_mixed_ratio_clamp () =
  (* need = 1.5 * 0.4 + 1.0 * 0.5 = 1.1 -> k = 1 / 1.1 *)
  let flat price =
    [| bar "2020-01-01" price price; bar "2020-01-02" price price |]
  in
  let margin : Engine.margin =
    { financing_rate = 0.; maintenance_ratio = 0.; ratios = [| 0.6; 0.5 |] }
  in
  let result =
    Engine.run [| ("tw/A", flat 100.); ("tw/B", flat 50.) |]
      { Engine.targets = [| [| 1.5; 1.5 |]; [| 1.; 1. |] |] }
      [| zero_costs; zero_costs |] ~margin ~capital:None
      ~fill:Engine.Close_same
  in
  assert (result.margin_stats.Engine.clamps = 1);
  (match result.fills with
   | a :: b :: _ ->
       assert_close ~tolerance:1e-12 (1.5 /. 1.1) a.Engine.to_e;
       assert_close ~tolerance:1e-12 (1. /. 1.1) b.Engine.to_e
   | _ -> assert false)

let test_engine_margin_call () =
  (* 2.5x, falling closes: maintenance 133.3% -> 126.7% -> call,
     full liquidation at the next open, flat under the unchanged
     target, re-entry when the target changes value *)
  let bars =
    [| bar "2020-01-01" 100. 100.;
       bar "2020-01-02" 80. 80.;
       bar "2020-01-03" 76. 76.;
       bar "2020-01-06" 76. 90.;
       bar "2020-01-07" 90. 90. |]
  in
  let margin : Engine.margin =
    { financing_rate = 0.; maintenance_ratio = 1.3; ratios = [| 0.6 |] }
  in
  let result =
    Engine.run [| ("tw/TEST", bars) |]
      { Engine.targets = [| [| 2.5; 2.5; 2.5; 2.5; 1.0 |] |] }
      [| zero_costs |] ~margin ~capital:None ~fill:Engine.Close_same
  in
  (* v: 2.5 -> 2.0 (equity 0.5) -> 1.9 (equity 0.4, maint 1.2667 < 1.3);
     liquidation at open 76 repays the 1.5 loan: equity 0.4; the target
     stays 2.5 on the liquidation bar (no re-entry), then changes to 1.0
     on the last bar: re-entry fill at close 90, then the final force
     close sells it back at 90 (zero cost, zero return). *)
  assert_close ~tolerance:1e-12 0.4 (final_equity result);
  assert (List.length result.fills = 4);
  assert (result.margin_stats.Engine.margin_calls = 1);
  (match result.margin_stats.Engine.min_maintenance with
   | Some ratio -> assert_close ~tolerance:1e-12 (1.9 /. 1.5) ratio
   | None -> assert false);
  (match result.trips with
   | [first; second] ->
       assert_close ~tolerance:1e-12 (76. /. 100. -. 1.) first.net_ret;
       assert_close ~tolerance:1e-12 0. second.net_ret
   | _ -> assert false)

let test_engine_buyhold_costs () =
  (* all-in with fees: cash stays exactly 0, so the equity path equals
     the old engine's formula bit for bit *)
  let bars =
    [| bar "2020-01-01" 100. 100.; bar "2020-01-02" 100. 110. |]
  in
  let costs : Engine.costs =
    { fee_bps = 100.; tax_bps = 0.; slip_bps = 0.; min_fee = 0. }
  in
  let result =
    run_single bars [| 1.; 1. |] costs ~capital:None ~fill:Engine.Close_same
  in
  assert_close ~tolerance:1e-15
    ((1. -. 0.01) *. 1.1 *. (1. -. 0.01)) (final_equity result)

let test_engine_no_borrow_stats () =
  let bars =
    [| bar "2020-01-01" 100. 100.; bar "2020-01-02" 100. 110. |]
  in
  let result =
    run_single bars [| 1.; 1. |] zero_costs
      ~capital:None ~fill:Engine.Close_same
  in
  assert (result.margin_stats.Engine.min_maintenance = None);
  assert (result.margin_stats.Engine.margin_calls = 0);
  assert (result.margin_stats.Engine.clamps = 0)
```

Drift-affected updates to existing tests (derivation comments required in the code):

- `test_engine_portfolio_close` holds A at 0.5 across two bars, so it drifts. New expectations: `final_equity = 0.08 +. 0.5 *. 1.1 *. (121. /. 110.) +. 0.4 *. 1.05 *. (54. /. 45.)` (cash 0.08 after B's fill on day 2; A's value 0.605; B's 0.504; day-3 sells are free). Fill count 4 and both trip returns (0.21 and 0.2) are unchanged.
- `test_engine_portfolio_costs` (same shape with fees): replace the expectation with the let-chain

```ocaml
  let v_a0 = 0.5 *. (1. -. 0.005) in
  let c0 = (1. -. 0.005) -. v_a0 in
  let v_a1 = v_a0 *. 1.1 in
  let equity1 = c0 +. v_a1 in
  let v_b1 = 0.4 *. equity1 in
  let c1 = c0 -. v_b1 in
  let v_a2 = v_a1 *. (121. /. 110.) in
  let v_b2 = v_b1 *. (54. /. 45.) in
  let equity2 = c1 +. v_a2 +. v_b2 in
  let expected = equity2 -. 0.01 *. v_a2 -. 0.01 *. v_b2 in
```

  (sell costs are 1% of each position's value; B's buy was free).
- `test_multi_stock_cli` holds b at 0.5 for three bars: the last equity value becomes 1.37 (`v_a = 1.21`, `v_b = 0.66`, cash `-0.5`, financing off in this task). Update the comment and expectation; day-2 equity stays 1.15.
- `test_baseline_output_header` constructs an `Engine.result` literal: add `margin_stats = { min_maintenance = None; margin_calls = 0; clamps = 0 }`.
- Every other existing test either uses targets in {0,1} or changes its target every bar (single-bar windows are algebraically identical under drift), so their values stay untouched. If any other expectation fails, stop and report — do not adjust values without a derivation.
- Direct `Engine.run` callsites from sub-project B's tests (`test_engine_portfolio_close`, `test_engine_portfolio_open`, `test_engine_portfolio_costs`, `test_engine_portfolio_min_fee`, and any other) gain `~margin:(no_margin <asset count>)`; golden and DSL tests already flow through `run_single` or get the same mechanical addition where they call `Engine.run` directly.

- [ ] **Step 2: Verify they fail**

Run: `opam exec -- dune build 2>&1 | head -10`
Expected: compile errors — `Engine.margin` is unbound and `run` lacks `~margin`.

- [ ] **Step 3: Implement the engine**

In `lib/engine.ml`, add the two records from Interfaces after `fill_event`, add `margin_stats` to `result`, and add:

```ocaml
let day_number date =
  let year = int_of_string (String.sub date 0 4) in
  let month = int_of_string (String.sub date 5 2) in
  let day = int_of_string (String.sub date 8 2) in
  let a = (14 - month) / 12 in
  let y = year + 4800 - a in
  let m = month + (12 * a) - 3 in
  day + (((153 * m) + 2) / 5) + (365 * y) + (y / 4) - (y / 100) + (y / 400)
```

Replace `run` with the drift version. Signature:

```ocaml
let run (assets : (string * Data.bar array) array) (strategy : strategy)
    (costs : costs array) ~(margin : margin)
    ~capital:(capital : float option) ~fill =
```

Validation as today plus `Array.length margin.ratios = asset_count`. State:

```ocaml
  let cash = ref 1. in
  let values = Array.make asset_count 0. in
  let prev_eff = Array.make asset_count 0. in
  let pending_liquidation = ref false in
  let min_maintenance = ref None in
  let margin_calls = ref 0 in
  let clamps = ref 0 in
```

Keep the trip/fill bookkeeping arrays and `charge` unchanged. The value-based trade (replacing the old `trade`):

```ocaml
  let equity () =
    !cash +. Array.fold_left ( +. ) 0. values
  in
  let trade index ~date ~price ~desired =
    let equity_now = equity () in
    let from_e = values.(index) /. equity_now in
    let delta = desired -. from_e in
    if delta <> 0. then begin
      if from_e = 0. then begin
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
      let cost = charge index ~equity_before:equity_now ~delta in
      cash := !cash -. (cost *. equity_now);
      let equity_after = equity_now *. (1. -. cost) in
      let new_value = desired *. equity_after in
      cash := !cash -. (new_value -. values.(index));
      values.(index) <- new_value;
      fills :=
        { date; stock = fst assets.(index); price;
          from_e; to_e = desired } :: !fills;
      if desired = 0. then begin
        let entry_price = buy_value.(index) /. buy_exposure.(index) in
        let exit_price = sell_value.(index) /. sell_exposure.(index) in
        trips :=
          { entry_date = entry_dates.(index); exit_date = date;
            net_ret = exit_price /. entry_price -. 1. } :: !trips
      end
    end
  in
```

Effective targets and change detection:

```ocaml
  let effective t =
    let raw =
      Array.init asset_count
        (fun index -> clamp_target strategy.targets.(index).(t))
    in
    let need = ref 0. in
    Array.iteri
      (fun index value ->
        need := !need +. (value *. (1. -. margin.ratios.(index))))
      raw;
    let scale = if !need > 1. then 1. /. !need else 1. in
    (Array.map (fun value -> value *. scale) raw, scale < 1.)
  in
  let differs eff =
    let changed = ref false in
    Array.iteri
      (fun index value ->
        if value <> prev_eff.(index) then changed := true)
      eff;
    !changed
  in
```

Accrual helpers (`close_at`/`open_at` stay):

```ocaml
  let scale_values now before =
    for index = 0 to asset_count - 1 do
      if values.(index) <> 0. then
        values.(index) <-
          values.(index) *. (now index /. before index)
    done
  in
  let accrue_interest ~date ~prev_date =
    if !cash < 0. then begin
      let days = day_number date - day_number prev_date in
      cash :=
        !cash
        +. (!cash *. margin.financing_rate *. float_of_int days /. 365.)
    end
  in
  let liquidate ~date price_at =
    for index = 0 to asset_count - 1 do
      if values.(index) > 0. then
        trade index ~date ~price:(price_at index) ~desired:0.
    done
  in
  let apply_fills ~date ~eff ~clamped price_at =
    if clamped then incr clamps;
    for index = 0 to asset_count - 1 do
      if eff.(index) <> prev_eff.(index) then
        trade index ~date ~price:(price_at index) ~desired:eff.(index)
    done;
    Array.blit eff 0 prev_eff 0 asset_count
  in
```

The per-bar loop:

```ocaml
  for t = 0 to length - 1 do
    let date = (snd assets.(0)).(t).Data.date in
    if t > 0 then
      accrue_interest ~date ~prev_date:((snd assets.(0)).(t - 1).Data.date);
    (match fill with
     | Close_same ->
         if t > 0 && !pending_liquidation then begin
           scale_values (fun i -> open_at i t) (fun i -> close_at i (t - 1));
           liquidate ~date (fun i -> open_at i t);
           pending_liquidation := false;
           scale_values (fun i -> close_at i t) (fun i -> open_at i t)
         end
         else if t > 0 then
           scale_values (fun i -> close_at i t) (fun i -> close_at i (t - 1));
         let eff, clamped = effective t in
         if differs eff then
           apply_fills ~date ~eff ~clamped (fun i -> close_at i t)
     | Open_next ->
         if t > 0 then begin
           let eff, clamped = effective (t - 1) in
           let scheduled = differs eff in
           if !pending_liquidation || scheduled then begin
             scale_values (fun i -> open_at i t)
               (fun i -> close_at i (t - 1));
             if !pending_liquidation then begin
               liquidate ~date (fun i -> open_at i t);
               pending_liquidation := false
             end;
             if scheduled then
               apply_fills ~date ~eff ~clamped (fun i -> open_at i t);
             scale_values (fun i -> close_at i t) (fun i -> open_at i t)
           end
           else
             scale_values (fun i -> close_at i t)
               (fun i -> close_at i (t - 1))
         end);
    if !cash < 0. then begin
      let ratio =
        Array.fold_left ( +. ) 0. values /. (-. !cash)
      in
      (match !min_maintenance with
       | None -> min_maintenance := Some ratio
       | Some best -> if ratio < best then min_maintenance := Some ratio);
      if ratio < margin.maintenance_ratio then begin
        incr margin_calls;
        pending_liquidation := true
      end
    end;
    equity_curve := (date, equity ()) :: !equity_curve
  done;
```

Final force-close: as today, but via `trade index ~desired:0.` over `values.(index) > 0.` at the last close, replacing the last curve point when anything closed. Result:

```ocaml
  { equity_curve = List.rev !equity_curve;
    fills = List.rev !fills;
    trips = List.rev !trips;
    margin_stats =
      { min_maintenance = !min_maintenance;
        margin_calls = !margin_calls;
        clamps = !clamps } }
```

Note the single-asset equivalences the tests rely on: with targets in {0,1}, `cash` is exactly 0 while invested, so accrual, costs, and trips reduce to the old engine bit-for-bit; a target that changes every bar has one-bar windows where `equity * (1 + e*r)` equals `cash + v*(1+r)`.

`bin/bt.ml` (temporary until Task 3): pass a margin-off argument at both run callsites:

```ocaml
  ~margin:{ Btlib.Engine.financing_rate = 0.; maintenance_ratio = 0.;
            ratios = Array.make (Array.length engine_assets) 1. }
```

(baseline: length 1). This keeps CLI behavior at drift-only while flags land in Task 3.

- [ ] **Step 4: Verify build and tests pass**

Run: `opam exec -- dune build && opam exec -- dune runtest`
Expected: build clean, tests print `ok`; only the four named tests changed expectations.

- [ ] **Step 5: Commit**

```bash
git add lib/engine.ml bin/bt.ml test/test_bt.ml
git commit -m "feat: drift accounting with financing, margin cap, and margin calls

Co-authored-by: ChatGPT <noreply@openai.com>"
```

---

### Task 2: TWSE/TPEX classification data

**Files:**
- Modify: `lib/data.ml` (fetch_stockinfo, financing_ratio), `test/test_bt.ml`

**Interfaces:**
- Produces: `Data.fetch_stockinfo ~token ~cache_path` (called from `Data.fetch` for tw) and `Data.financing_ratio ~data_dir ~symbol : float`. Task 3 consumes `financing_ratio`.

- [ ] **Step 1: Write the failing test**

```ocaml
let test_financing_ratio () =
  let root = Filename.temp_file "bt-test-info-" "" in
  Sys.remove root;
  Unix.mkdir root 0o700;
  let tw = Filename.concat root "tw" in
  Unix.mkdir tw 0o700;
  Fun.protect
    ~finally:(fun () ->
      Array.iter
        (fun name -> Sys.remove (Filename.concat tw name))
        (Sys.readdir tw);
      Unix.rmdir tw;
      Unix.rmdir root)
    (fun () ->
      let output = open_out (Filename.concat tw "stockinfo.csv") in
      Fun.protect
        ~finally:(fun () -> close_out output)
        (fun () ->
          output_string output
            "stock_id,type,date\n\
             00685L,\"twse\",\"2024-01-01\"\n\
             5483,\"tpex\",\"2024-01-01\"\n\
             8069,\"tpex\",\"2020-01-01\"\n\
             8069,\"twse\",\"2024-01-01\"\n");
      assert (Data.financing_ratio ~data_dir:root ~symbol:"00685L" = 0.6);
      assert (Data.financing_ratio ~data_dir:root ~symbol:"5483" = 0.5);
      (* the row with the latest date wins *)
      assert (Data.financing_ratio ~data_dir:root ~symbol:"8069" = 0.6);
      (* unknown symbol warns and defaults *)
      assert (Data.financing_ratio ~data_dir:root ~symbol:"9999" = 0.6))
```

Register it in the runner.

- [ ] **Step 2: Verify it fails**

Run: `opam exec -- dune build 2>&1 | head -5`
Expected: unbound `Data.financing_ratio`.

- [ ] **Step 3: Implement**

In `lib/data.ml`, after `fetch_events`:

```ocaml
let fetch_stockinfo ~token ~cache_path =
  with_temp ".json" (fun json_path ->
    let url =
      "https://api.finmindtrade.com/api/v4/data?dataset=TaiwanStockInfo"
    in
    let process_status, http_code = curl_get ~token ~url ~output:json_path in
    let keep reason =
      Printf.eprintf "warning: stockinfo fetch failed (%s); %s\n" reason
        (if Sys.file_exists cache_path then "keeping cached stock info"
         else "financing ratios will default to TWSE 60%")
    in
    if not (process_ok process_status) || http_code <> "200" then
      keep
        ("HTTP " ^
         (if http_code = "" || http_code = "000" then "unavailable"
          else http_code))
    else
      match check_api_response json_path with
      | `Error message -> keep message
      | `Ok ->
          with_temp ".rows" (fun rows_path ->
            transform_json ~args:[]
              ~expression:(
                ".data[] | select(.type == \"twse\" or .type == \"tpex\") " ^
                "| [.stock_id, .type, .date] | @csv")
              ~json_path ~rows_path;
            rewrite_rows ~header:"stock_id,type,date" ~rows_path ~cache_path))
```

Wire it into `fetch`'s tw branch after `fetch_events`, with
`~cache_path:(Filename.concat directory "stockinfo.csv")`.

The lookup (place after `read_dividends`; `unquote` already exists —
`rewrite_rows` unquotes only the first field, so `type` and `date` stay
quoted in the cache):

```ocaml
let financing_ratio ~data_dir ~symbol =
  let path =
    Filename.concat (Filename.concat data_dir "tw") "stockinfo.csv"
  in
  let fallback () =
    Printf.eprintf
      "warning: financing ratio unknown for %s; assuming TWSE 60%%\n" symbol;
    0.6
  in
  if not (Sys.file_exists path) then fallback ()
  else begin
    let input = open_in path in
    Fun.protect
      ~finally:(fun () -> close_in input)
      (fun () ->
        let best = ref None in
        (try
           ignore (input_line input);
           while true do
             match String.split_on_char ',' (input_line input) with
             | [stock_id; kind; date] when unquote stock_id = symbol ->
                 let date = unquote date in
                 (match !best with
                  | Some (previous, _) when String.compare previous date >= 0 ->
                      ()
                  | _ -> best := Some (date, unquote kind))
             | _ -> ()
           done
         with End_of_file -> ());
        match !best with
        | Some (_, "twse") -> 0.6
        | Some (_, "tpex") -> 0.5
        | _ -> fallback ())
  end
```

- [ ] **Step 4: Verify build and tests pass**

Run: `opam exec -- dune build && opam exec -- dune runtest`
Expected: tests print `ok`.

- [ ] **Step 5: Commit**

```bash
git add lib/data.ml test/test_bt.ml
git commit -m "feat: cache TaiwanStockInfo for financing ratios

Co-authored-by: ChatGPT <noreply@openai.com>"
```

---

### Task 3: CLI flags, classification wiring, margin report line

**Files:**
- Modify: `bin/bt.ml` (flags, margin construction), `lib/report.ml` (footer swap, margin line), `test/test_bt.ml` (CLI tests)

**Interfaces:**
- Consumes: Task 1 `margin`/`margin_stats`, Task 2 `financing_ratio`.
- Produces: flags `--financing-rate` (default 6.35), `--maintenance-ratio` (default 130), `--financing-ratio` (optional uniform override); `Report.print_many` loses `~targets`, gains `~financing_rate:float`.

- [ ] **Step 1: Write the failing tests**

Update `test_multi_stock_cli`: add `--financing-rate 0` to the command (expected last equity stays 1.37 — drift only). Add a leveraged variant test `test_margin_cli` right after it, reusing the same fixture-writing shape with a strat whose targets are `a.target 2.0` and no b position, command flags `--fee-bps 0 --tax-bps 0 --slip-bps 0 --min-fee 0 --financing-ratio 60` (financing rate left at its 6.35 default), and assertions: exit 0; stdout (captured to a file) contains `margin — financing 6.35%/yr` and `margin calls 0`; stdout does NOT contain `daily-reset`. Keep the temp-dir cleanup pattern.

- [ ] **Step 2: Verify they fail**

Run: `opam exec -- dune build && opam exec -- dune runtest 2>&1 | tail -3`
Expected: `test_multi_stock_cli` fails — `--financing-rate` is not a known flag (usage error, exit 2).

- [ ] **Step 3: Implement**

`bin/bt.ml`:

- Add refs `financing_rate = ref 6.35`, `maintenance_ratio = ref 130.`, `financing_ratio = ref None` and the three `Arg.Float` options (`--financing-ratio` sets `Some value`).
- Resolve each asset's ratio where costs are built:

```ocaml
        let ratio_for symbol =
          match !financing_ratio with
          | Some percent -> percent /. 100.
          | None -> Btlib.Data.financing_ratio ~data_dir:!data_dir ~symbol
        in
        let ratios =
          Array.of_list
            (List.map (fun (_, _, symbol) -> ratio_for symbol) input.stocks)
        in
        let margin_config : Btlib.Engine.margin =
          { financing_rate = !financing_rate /. 100.;
            maintenance_ratio = !maintenance_ratio /. 100.;
            ratios }
        in
```

  and pass `~margin:margin_config` (baseline: `ratios = [| ratio_for symbol |]`). Delete the Task-1 margin-off stopgap and the gross-target computation (the report no longer takes targets; pass the run tuple without it).
- `lib/report.ml`: `print_many` signature drops `~targets`, gains `~financing_rate`; delete `maximum_target` and the `Exposure above 1.0 uses daily-reset leverage.` footer. After the per-strategy trades line, for each column whose `result.Engine.margin_stats.min_maintenance` is `Some ratio`, print:

```ocaml
      Printf.printf
        "%s: margin — financing %.2f%%/yr, min maintenance %s, margin calls %d, clamps %d\n"
        name financing_rate (format_percent ratio)
        stats.Engine.margin_calls stats.Engine.clamps
```

- [ ] **Step 4: Verify build and tests pass**

Run: `opam exec -- dune build && opam exec -- dune runtest`
Expected: tests print `ok`, including both CLI tests.

- [ ] **Step 5: Commit**

```bash
git add bin/bt.ml lib/report.ml test/test_bt.ml
git commit -m "feat: margin CLI flags, ratio classification, report line

Co-authored-by: ChatGPT <noreply@openai.com>"
```

---

### Task 4: Documentation and real-data smoke

**Files:**
- Modify: `docs/strategy.md` (target drift semantics), `docs/cli.md` (flags, stockinfo cache, margin line), `README.md` (margin summary), `CONTRIBUTING.md` (engine module line)

**Interfaces:**
- Consumes: everything from Tasks 1-3.

- [ ] **Step 1: Update the docs**

Read each section immediately before editing; surgical edits only, STE prose.

- `docs/strategy.md`: in the target-exposure and statements sections, replace the daily-reset sentences ("A value above 1.0 applies daily-reset leverage.") with drift semantics: a fill happens when the target value changes; positions drift between fills; exposure above 1.0 borrows cash at the financing rate; TW financing ratios cap initial margin (TWSE 2.5x, TPEX 2.0x); maintenance below the threshold force-liquidates at the next open and the strategy stays flat until the target changes.
- `docs/cli.md`: document the three flags with defaults, the `data/tw/stockinfo.csv` cache in the fetch section, and the margin report line with its trigger (a loan existed).
- `README.md`: one short paragraph in the features/engine section describing margin financing defaults.
- `CONTRIBUTING.md`: extend the `lib/engine.ml` line with margin accounting.

- [ ] **Step 2: Real-data smoke**

```bash
opam exec -- dune build && opam exec -- dune runtest
_build/default/bin/bt.exe run /sandbox/research/strategies/channel_ladder.strat \
  --baseline tw/00685L --data-dir data --out-dir /tmp/margin-smoke \
  --out-name margin_smoke --no-plot
```

Expected: tests print `ok`. The run prints the metric table, then a `channel_ladder: margin — financing 6.35%/yr, ...` line (the tuned params hold targets near 2x, so a loan exists), and no `daily-reset` text. CAGR must land below the pre-margin close-fill value (56.70% was the free-leverage number) — record the new numbers in the report file for the controller.

- [ ] **Step 3: Commit**

```bash
git add docs/strategy.md docs/cli.md README.md CONTRIBUTING.md
git commit -m "docs: margin financing semantics and flags

Co-authored-by: ChatGPT <noreply@openai.com>"
```
