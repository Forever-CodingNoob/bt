# E1-Based Fill Planning Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `trade` and `apply_fills` with an E1-based fill planner that solves for post-cost equity before modifying any state, eliminating order dependence and the four reviewed bugs.

**Architecture:** `apply_fills` becomes: (1) iterative E1 solve using the existing `charge` function, (2) frozen fill plan with per-asset final values, trade deltas, costs, and buy/sell classification, (3) sell pass executing the plan, (4) solvency check, (5) buy pass with joint loan allocation from the plan's confirmed shortfall, (6) post-fill bookkeeping. `trade` is removed; its fill-event recording and VWAP bookkeeping are inlined into the execution loops.

**Tech Stack:** OCaml (stdlib + Unix), dune, single test binary `test/test_bt.ml`.

**Spec:** `docs/specs/e1-fill-planning.md`

## Global Constraints

- Verification: `opam exec -- dune build && opam exec -- dune runtest` from the repo root.
- Zero-cost tests produce identical results (E1 = E0 when all costs are zero).
- Costed tests change because trade sizes are `t_i * E1 - v_i` instead of the old sequential `desired * equity_after - v_i`. Each changed expectation must include a step-by-step derivation comment computing E1 and the final equity from the E1 formula. If a zero-cost test's expectation changes, STOP and report.
- Code style: two-space indent, one space on each side of `=`.
- Commit trailer: `Co-authored-by: ChatGPT <noreply@openai.com>` after one blank line.
- After unit tests pass, also build `bt-test6.exe` (`cp _build/default/bin/bt.exe bt-test6.exe`) and run the channel_ladder smoke: `./bt-test6.exe run /sandbox/research/strategies/channel_ladder.strat --baseline tw/00685L --data-dir data --out-dir /tmp/e1-smoke --out-name e1_smoke --no-plot 2>&1 | tail -8`. Record the margin line in the report.

---

### Task 1: E1 fill planner with tests

**Files:**
- Modify: `lib/engine.ml` (replace `trade` and `apply_fills`)
- Test: `test/test_bt.ml` (new tests + re-derived costed expectations)

- [ ] **Step 1: Write the new tests**

Add to `test/test_bt.ml` and register in the runner. These test the properties the old code violated:

```ocaml
let test_e1_order_independence () =
  (* Two assets, sub-max leverage, both declaration orders.
     Targets A=0.9 B=0.3 (T=1.2), ratio 0.6, 100 bps fee.
     E1 must be identical regardless of order. *)
  let flat price =
    [| bar "2020-01-01" price price; bar "2020-01-02" price price |]
  in
  let costs : Engine.costs =
    { fee_bps = 100.; tax_bps = 0.; slip_bps = 0.; min_fee = 0. }
  in
  let margin : Engine.margin =
    { financing_rate = 0.; maintenance_ratio = 0.; ratios = [| 0.6; 0.6 |] }
  in
  let strategy_ab : Engine.strategy =
    { targets = [| [| 0.9; 0.9 |]; [| 0.3; 0.3 |] |] }
  in
  let result_ab =
    Engine.run [| ("tw/A", flat 100.); ("tw/B", flat 50.) |] strategy_ab
      [| costs; costs |] ~margin ~capital:None ~fill:Engine.Close_same
  in
  let strategy_ba : Engine.strategy =
    { targets = [| [| 0.3; 0.3 |]; [| 0.9; 0.9 |] |] }
  in
  let result_ba =
    Engine.run [| ("tw/B", flat 50.); ("tw/A", flat 100.) |] strategy_ba
      [| costs; costs |] ~margin:margin ~capital:None ~fill:Engine.Close_same
  in
  assert_close ~tolerance:1e-15
    (final_equity result_ab) (final_equity result_ba);
  (match result_ab.margin_stats.Engine.min_maintenance,
         result_ba.margin_stats.Engine.min_maintenance with
   | Some a, Some b -> assert_close ~tolerance:1e-15 a b
   | _ -> assert false)

let test_e1_scale_in () =
  (* Targets [1.5; 2.0; 2.0], ratio 0.6, zero cost.
     Bar 0: shortfall = 1.5 - 1.0 = 0.5, loan = 0.5.
     Bar 1: scale-in from 1.5 to 2.0; shortfall is the NEW borrowing
     needed for this fill, not the total outstanding. *)
  let bars =
    [| bar "2020-01-01" 100. 100.;
       bar "2020-01-02" 100. 100.;
       bar "2020-01-03" 100. 100. |]
  in
  let margin : Engine.margin =
    { financing_rate = 0.; maintenance_ratio = 0.; ratios = [| 0.6 |] }
  in
  let result =
    Engine.run [| ("tw/TEST", bars) |]
      { Engine.targets = [| [| 1.5; 2.0; 2.0 |] |] }
      [| zero_costs |] ~margin ~capital:None ~fill:Engine.Close_same
  in
  (* Bar 0: E1=1, v=1.5, cash=-0.5, loan=0.5.
     Bar 1: E1=1, trade=0.5 (buy), shortfall = 0.5 - (-0.5) = 1.0?
     No: cash is -0.5 from prior bar, total buy = 0.5.
     shortfall = max(0, 0.5 - (-0.5)) = 1.0, capacity = 0.5*0.6 = 0.3.
     But shortfall > capacity violates the invariant...
     Actually: cash_available after sells = -0.5 (no sells on this bar).
     total_buy = 2.0*1.0 - 1.5 = 0.5 (the value increase).
     shortfall = max(0, 0.5 - (-0.5)) = 1.0.
     The initial-margin cap should have prevented this...
     effective at t=1: target 2.0, need = 2.0*0.4 = 0.8 < 1, no clamp.
     But the shortfall exceeds capacity. This means the shortfall formula
     must account for existing loans being repaid through the total
     cash position. The spec says shortfall = max(0, total_buy - cash).
     With cash = -0.5, shortfall = 1.0, but only 0.5 of new value needs
     financing. The existing -0.5 cash IS the prior loan.

     The correct approach: the E1 solve handles this naturally. After the
     solve, final_value = 2.0 * E1 = 2.0, trade = 0.5 (buy). The buy
     pass sees cash_after_sells = -0.5 (no sells), shortfall = 0.5-(-0.5)
     = 1.0. But this shortfall includes the pre-existing deficit. The
     NEW loan delta should only be for the new borrowing: 0.5 * 0.6 = 0.3.
     Total loan after: 0.5 + 0.3 = 0.8.

     Hmm, this is the same double-counting bug. The shortfall formula
     doesn't work when cash is already negative.

     The fix: shortfall = max(0, total_buy + total_cost - cash_freed_by_sells).
     cash_freed_by_sells is only the sell proceeds, NOT the pre-existing cash.
     Or: new_cash_needed = sum(buy costs + buy values) - sell_proceeds.
     loan_delta_total = max(0, new_cash_needed).

     Actually, the E1 solve already determines the final cash:
     cash_after = E1 * (1 - T). At T=2.0: cash_after = -E1.
     The total loan at the end should cover the deficit:
     total_loan = max(0, -cash_after) = E1.
     But the existing loan from bar 0 is 0.5. So the new loan delta
     is E1 - 0.5 = 0.5. That's the incremental borrowing.

     The correct shortfall for loan allocation is:
     needed_total_loan = max(0, -(E1 * (1 - T)))
     loan_delta = needed_total_loan - sum(existing_loans)
     Distribute loan_delta across buying assets by capacity.

     At bar 1: needed = E1 = 1.0. existing = 0.5. delta = 0.5.
     capacity = 0.5 * 0.6 = 0.3. loan_allocated = 0.5 * 0.3/0.3 = 0.5.
     Wait, that gives 0.5 not 0.3. The capacity formula gives the
     proportion, not the amount. If only one buy: loan_delta = 0.5.
     loan = 0.5 + 0.5 = 1.0.
     Maintenance = 2.0 / 1.0 = 2.0. *)
  assert_close ~tolerance:1e-12 1.0 (final_equity result);
  (* total loan should be 1.0 (not the double-counted 1.5 from the
     old code, and not the 0.8 from a capacity-weighted formula).
     The correct amount: E1*(T-1) = 1.0. *)
  (match result.margin_stats.Engine.min_maintenance with
   | Some ratio -> assert_close ~tolerance:1e-12 2.0 ratio
   | None -> assert false)

let test_e1_drift_reversal () =
  (* Target drops 2.0 -> 1.8 while price doubles: drifted exposure is
     2.0/3.0 = 0.667, so the fill to 1.8 is an actual buy. *)
  let bars =
    [| bar "2020-01-01" 100. 100.;
       bar "2020-01-02" 200. 200. |]
  in
  let margin : Engine.margin =
    { financing_rate = 0.; maintenance_ratio = 0.; ratios = [| 0.6 |] }
  in
  let result =
    Engine.run [| ("tw/TEST", bars) |]
      { Engine.targets = [| [| 2.0; 1.8 |] |] }
      [| zero_costs |] ~margin ~capital:None ~fill:Engine.Close_same
  in
  (* Bar 0: buy 2.0, E1=1, v=2.0, cash=-1.0, loan=1.0.
     Bar 1: price doubles. v drifts to 4.0, cash=-1.0, equity=3.0.
     E1 = 3.0 (zero cost). final_v = 1.8*3.0 = 5.4. trade = 1.4 (buy!).
     cash_after = 3.0*(1-1.8) = -2.4.
     needed_loan = 2.4, existing = 1.0, delta = 1.4.
     loan = 2.4. maintenance = 5.4/2.4 = 2.25.
     Final force-close: sell 5.4, loan->0. equity = 5.4-2.4 = 3.0. *)
  assert_close ~tolerance:1e-12 3.0 (final_equity result);
  assert (List.length result.fills = 4)

let test_e1_sell_then_buy () =
  (* Sell asset A, buy asset B on the same bar.
     Sell proceeds fund the buy before loan allocation. *)
  let bars_a =
    [| bar "2020-01-01" 100. 100.;
       bar "2020-01-02" 100. 100. |]
  in
  let bars_b =
    [| bar "2020-01-01" 50. 50.;
       bar "2020-01-02" 50. 50. |]
  in
  let margin : Engine.margin =
    { financing_rate = 0.; maintenance_ratio = 0.; ratios = [| 0.6; 0.6 |] }
  in
  let strategy : Engine.strategy =
    { targets = [| [| 1.5; 0. |]; [| 0.; 1.0 |] |] }
  in
  let result =
    Engine.run [| ("tw/A", bars_a); ("tw/B", bars_b) |] strategy
      [| zero_costs; zero_costs |] ~margin ~capital:None
      ~fill:Engine.Close_same
  in
  (* Bar 0: buy A at 1.5, loan = 0.5.
     Bar 1: sell A to 0 (cash goes +0.5 from proceeds, loan -> 0),
     buy B at 1.0. cash_after_sells = 0.5 + 1.0 = 1.5?
     No: E1 solve. T=1.0, E1=1.0 (zero cost). final_A=0, final_B=1.0.
     cash_after = 1.0*(1-1.0) = 0. No loan. *)
  assert_close ~tolerance:1e-12 1.0 (final_equity result);
  assert (result.margin_stats.Engine.margin_call_dates = [])
```

Note: the scale-in test's derivation comment reveals that the loan allocation's shortfall formula must use `needed_total_loan - existing_loans` as the delta, not `total_buy - cash`. This is the key insight the E1 spec implies but does not state explicitly: the final cash is `E1*(1-T)`, so the needed total loan is `max(0, -E1*(1-T)) = max(0, E1*(T-1))`, and the incremental loan delta is `needed - sum(existing)`.

- [ ] **Step 2: Verify they fail**

Run: `opam exec -- dune build && opam exec -- dune runtest 2>&1 | tail -5`
Expected: at least one new test fails (the old apply_fills doesn't handle these cases correctly).

- [ ] **Step 3: Implement the E1 fill planner**

Replace `trade` (lines 128-171) and `apply_fills` (lines 261-321) in `lib/engine.ml` with:

```ocaml
  let record_fill index ~date ~price ~from_e ~to_e =
    fills :=
      { date; stock = fst assets.(index); price;
        from_e; to_e } :: !fills
  in
  let start_trip index ~date =
    entry_dates.(index) <- date;
    buy_value.(index) <- 0.;
    buy_exposure.(index) <- 0.;
    sell_value.(index) <- 0.;
    sell_exposure.(index) <- 0.
  in
  let close_trip index ~date =
    let entry_price = buy_value.(index) /. buy_exposure.(index) in
    let exit_price = sell_value.(index) /. sell_exposure.(index) in
    trips :=
      { entry_date = entry_dates.(index); exit_date = date;
        net_ret = exit_price /. entry_price -. 1. } :: !trips
  in
  let apply_fills ~date ~eff ~clamped price_at =
    if clamped then incr clamps;
    let e0 = equity () in
    if e0 <= 0. then () else begin
      (* E1 iterative solve *)
      let e1 = ref e0 in
      for _ = 1 to 5 do
        let total_cost = ref 0. in
        for index = 0 to asset_count - 1 do
          let final_v = eff.(index) *. !e1 in
          let trade = final_v -. values.(index) in
          if trade <> 0. then begin
            let from_e = values.(index) /. !e1 in
            let delta = eff.(index) -. from_e in
            total_cost := !total_cost +. (charge index ~equity_before:!e1 ~delta) *. !e1
          end
        done;
        e1 := e0 -. !total_cost
      done;
      let e1 = !e1 in
      (* build the frozen plan *)
      let plan =
        Array.init asset_count (fun index ->
          let final_v = eff.(index) *. e1 in
          let trade = final_v -. values.(index) in
          let from_e = values.(index) /. e0 in
          let to_e = eff.(index) *. e1 /. e0 in
          let cost =
            if trade = 0. then 0.
            else begin
              let delta_e = eff.(index) -. values.(index) /. e1 in
              (charge index ~equity_before:e1 ~delta:delta_e) *. e1
            end
          in
          (final_v, trade, from_e, to_e, cost))
      in
      (* sell pass *)
      for index = 0 to asset_count - 1 do
        let final_v, trade, from_e, to_e, cost = plan.(index) in
        if trade < 0. then begin
          let old_v = values.(index) in
          if old_v > 0. && from_e = 0. then start_trip index ~date;
          sell_value.(index) <-
            sell_value.(index) +. abs_float (to_e -. from_e) *. (price_at index);
          sell_exposure.(index) <-
            sell_exposure.(index) +. abs_float (to_e -. from_e);
          values.(index) <- final_v;
          if final_v = 0. then loans.(index) <- 0.
          else if old_v > 0. then
            loans.(index) <- loans.(index) *. final_v /. old_v;
          cash := !cash +. (old_v -. final_v) -. cost;
          record_fill index ~date ~price:(price_at index) ~from_e ~to_e;
          if final_v = 0. then close_trip index ~date
        end
      done;
      (* solvency check after sells *)
      if equity () <= 0. && Array.exists (fun v -> v > 0.) values then begin
        let total_loan = Array.fold_left ( +. ) 0. loans in
        if total_loan > 0. then begin
          let ratio = Array.fold_left ( +. ) 0. values /. total_loan in
          (match !min_maintenance with
           | None -> min_maintenance := Some ratio
           | Some best -> if ratio < best then min_maintenance := Some ratio)
        end;
        margin_call_dates := date :: !margin_call_dates;
        for index = 0 to asset_count - 1 do
          sell_out index ~date ~price:(price_at index)
        done;
        bankrupt := true
      end;
      if not !bankrupt then begin
        (* buy pass with loan allocation *)
        let total_buy_value = ref 0. in
        let buying = Array.make asset_count false in
        for index = 0 to asset_count - 1 do
          let _, trade, _, _, _ = plan.(index) in
          if trade > 0. then begin
            buying.(index) <- true;
            total_buy_value := !total_buy_value +. trade
          end
        done;
        let needed_total_loan = Float.max 0. (e1 *. (Array.fold_left ( +. ) 0. eff -. 1.)) in
        let existing_total_loan = Array.fold_left ( +. ) 0. loans in
        let loan_delta_total = Float.max 0. (needed_total_loan -. existing_total_loan) in
        let total_capacity = ref 0. in
        for index = 0 to asset_count - 1 do
          if buying.(index) then begin
            let _, trade, _, _, _ = plan.(index) in
            total_capacity := !total_capacity +. trade *. margin.ratios.(index)
          end
        done;
        for index = 0 to asset_count - 1 do
          if buying.(index) then begin
            let final_v, trade, from_e, to_e, cost = plan.(index) in
            let old_v = values.(index) in
            if from_e = 0. then start_trip index ~date;
            buy_value.(index) <-
              buy_value.(index) +. (to_e -. from_e) *. (price_at index);
            buy_exposure.(index) <-
              buy_exposure.(index) +. (to_e -. from_e);
            let loan_delta =
              if !total_capacity > 0. && loan_delta_total > 0. then
                loan_delta_total *. (trade *. margin.ratios.(index)) /. !total_capacity
              else 0.
            in
            loans.(index) <- loans.(index) +. loan_delta;
            values.(index) <- final_v;
            cash := !cash -. trade -. cost;
            record_fill index ~date ~price:(price_at index) ~from_e ~to_e
          end
        done
      end
    end;
    Array.blit eff 0 prev_eff 0 asset_count;
    if equity () <= 0.
       && not (Array.exists (fun v -> v > 0.) values)
    then bankrupt := true
  in
```

Remove the old `trade` function entirely (lines 128-171).

Update the ponytail comment on the `effective` function (line 230-231) to:
```
    (* ponytail: E1-based sizing absorbs costs before allocation, so
       sequential fills cannot overshoot; this comment is historical *)
```

**Re-deriving costed test expectations.** The E1 solve changes how costs affect position sizes. For every costed test (listed below), the implementer must:
1. Compute E1 from the iterative formula: `E1 = E0 - sum(cost_i)` where `cost_i = |t_i * E1 - v_i| * rate_i`.
2. Compute `final_value_i = t_i * E1`.
3. Compute `final_equity = E1` (by construction).
4. Write the derivation as a let-chain comment in the test.
5. If the derivation matches the old expected value, leave it unchanged. If it differs, update with the new value.

Costed tests to check (and update if changed):
- `test_engine_close_costs`
- `test_engine_min_fee`
- `test_engine_min_fee_without_capital`
- `test_engine_partial_costs`
- `test_engine_partial_open_costs`
- `test_engine_portfolio_costs`
- `test_engine_portfolio_min_fee`
- `test_engine_buyhold_costs`
- `test_engine_insolvent_min_fee`
- `test_engine_exit_fee_bankruptcy`
- `test_engine_zero_value_exit_clears_loan`

Zero-cost tests must NOT change their expectations. If any zero-cost test fails, STOP and report.

- [ ] **Step 4: Verify build and tests pass**

Run: `opam exec -- dune build && opam exec -- dune runtest`
Expected: build clean, tests print `ok`.

- [ ] **Step 5: Smoke test**

```bash
cp _build/default/bin/bt.exe bt-test6.exe
./bt-test6.exe run /sandbox/research/strategies/channel_ladder.strat \
  --baseline tw/00685L --data-dir data --out-dir /tmp/e1-smoke \
  --out-name e1_smoke --no-plot 2>&1 | tail -8
```

Record the margin line and CAGR in the report.

- [ ] **Step 6: Commit**

```bash
git add lib/engine.ml test/test_bt.ml
git commit -m "feat: E1-based fill planning for order-independent margin allocation

Co-authored-by: ChatGPT <noreply@openai.com>"
```
