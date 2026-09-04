# Order-Independent Loan Allocation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Loan allocation must not depend on asset declaration order. Sells net into cash first; buys then share the shortfall in proportion to each asset's financing capacity.

**Architecture:** `apply_fills` becomes a two-pass operation: sell pass (unchanged per-trade mechanics), then buy pass with a jointly computed loan allocation. The per-trade `cash < 0` loan decision is removed from `trade`; instead, `apply_fills` computes the loan for each buying asset after all buys are sized.

**Tech Stack:** OCaml (stdlib + Unix), dune, single test binary `test/test_bt.ml`.

**Spec:** `docs/specs/order-independent-loan-allocation.md`

## Global Constraints

- Verification command: `opam exec -- dune build && opam exec -- dune runtest` from the repo root.
- Single-asset fills must produce identical results to the current engine.
- Buy-and-hold at target 1.0 must keep loan = 0 and cash = 0.
- Code style: two-space indent, one space on each side of `=`.
- Commit trailer: `Co-authored-by: ChatGPT <noreply@openai.com>` after one blank line.
- All tests live in `test/test_bt.ml`.

---

### Task 1: Two-pass fill with joint loan allocation

**Files:**
- Modify: `lib/engine.ml` (`trade`, `apply_fills`)
- Test: `test/test_bt.ml`

**Interfaces:**
- `trade` loses the loan-assignment logic (lines 155-163); it becomes a pure position-sizing and bookkeeping function. A new optional argument `~loan_delta:float` (default 0.) lets the caller pass the pre-computed loan change.
- `apply_fills` splits into sells then buys, computes the joint loan allocation for the buy group, and passes each buy's loan delta to `trade`.

- [ ] **Step 1: Write the failing tests**

Append to `test/test_bt.ml` and register in the runner:

```ocaml
let test_loan_order_independence () =
  (* Two assets, same portfolio, opposite declaration orders.
     Cash 1.0, buy A = 0.75, buy B = 0.25. Both ratio 0.6.
     shortfall = 1.0 - 1.0 = 0 at target 1.0 total... need leverage.
     Use targets A = 0.9, B = 0.3 (total 1.2, shortfall 0.2).
     capacity_A = 0.9 * 0.6 = 0.54, capacity_B = 0.3 * 0.6 = 0.18,
     total_capacity = 0.72.
     loan_A = 0.2 * 0.54 / 0.72 = 0.15,
     loan_B = 0.2 * 0.18 / 0.72 = 0.05. *)
  let flat price =
    [| bar "2020-01-01" price price; bar "2020-01-02" price price |]
  in
  let margin : Engine.margin =
    { financing_rate = 0.; maintenance_ratio = 0.; ratios = [| 0.6; 0.6 |] }
  in
  let strategy : Engine.strategy =
    { targets = [| [| 0.9; 0.9 |]; [| 0.3; 0.3 |] |] }
  in
  let result_ab =
    Engine.run [| ("tw/A", flat 100.); ("tw/B", flat 50.) |] strategy
      [| zero_costs; zero_costs |] ~margin ~capital:None
      ~fill:Engine.Close_same
  in
  let strategy_ba : Engine.strategy =
    { targets = [| [| 0.3; 0.3 |]; [| 0.9; 0.9 |] |] }
  in
  let margin_ba : Engine.margin =
    { financing_rate = 0.; maintenance_ratio = 0.; ratios = [| 0.6; 0.6 |] }
  in
  let result_ba =
    Engine.run [| ("tw/B", flat 50.); ("tw/A", flat 100.) |] strategy_ba
      [| zero_costs; zero_costs |] ~margin:margin_ba ~capital:None
      ~fill:Engine.Close_same
  in
  assert_close ~tolerance:1e-12
    (final_equity result_ab) (final_equity result_ba);
  (* check the exact loan values via maintenance:
     total position = 1.2, total loan = 0.2,
     maintenance = 1.2 / 0.2 = 6.0 *)
  (match result_ab.margin_stats.Engine.min_maintenance with
   | Some ratio -> assert_close ~tolerance:1e-12 6.0 ratio
   | None -> assert false);
  (match result_ba.margin_stats.Engine.min_maintenance with
   | Some ratio -> assert_close ~tolerance:1e-12 6.0 ratio
   | None -> assert false)

let test_loan_sell_then_buy () =
  (* On the same bar: sell asset A (repaying its loan), buy asset B.
     The sell proceeds should fund the buy before creating a loan. *)
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
  (* bar 0: buy A at 1.5 (needs margin). bar 1: sell A to 0, buy B at 1.0.
     The 1.5 sell proceeds should leave cash = 1.5 after A exits;
     buying B at 1.0 costs 1.0, cash stays 0.5 -> no shortfall -> no loan. *)
  let strategy : Engine.strategy =
    { targets = [| [| 1.5; 0. |]; [| 0.; 1.0 |] |] }
  in
  let result =
    Engine.run [| ("tw/A", bars_a); ("tw/B", bars_b) |] strategy
      [| zero_costs; zero_costs |] ~margin ~capital:None
      ~fill:Engine.Close_same
  in
  (* After bar 1: A is flat (loan 0), B at 1.0 with no loan because
     the sell proceeds funded it. Maintenance should be None on bar 1
     (no loans exist). But bar 0 had a loan, so min_maintenance is set. *)
  assert_close ~tolerance:1e-12 1.0 (final_equity result);
  assert (result.margin_stats.Engine.margin_call_dates = [])
```

- [ ] **Step 2: Verify they fail**

Run: `opam exec -- dune build && opam exec -- dune runtest 2>&1 | tail -5`
Expected: `test_loan_order_independence` fails - the two runs give different maintenance ratios because of order-dependent loan allocation.

- [ ] **Step 3: Implement the two-pass fill**

In `lib/engine.ml`:

**a)** Remove the loan-assignment logic from `trade` (lines 155-163). Replace with: `trade` accepts an additional labeled argument `~loan_delta` (default 0.) and after sizing adds it: `loans.(index) <- loans.(index) +. loan_delta`. The sell repayment stays inside `trade` (the `new_value < old_value` branch): `loans.(index) <- loans.(index) *. new_value /. old_value`, and full-exit zeroes it. The `desired = 0.` guard at line 133 stays.

New `trade` signature and the changed section (replacing lines 128-174):

```ocaml
  let trade index ~date ~price ~desired ?(loan_delta = 0.) () =
    let equity_now = equity () in
    let old_value = values.(index) in
    let from_e = values.(index) /. equity_now in
    let delta = desired -. from_e in
    if desired = 0. then loans.(index) <- 0.;
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
      let equity_after = equity_now *. (1. -. cost) in
      let new_value = desired *. equity_after in
      values.(index) <- new_value;
      cash := equity_after -. Array.fold_left ( +. ) 0. values;
      if new_value = 0. then loans.(index) <- 0.
      else if new_value < old_value && old_value > 0. then
        loans.(index) <- loans.(index) *. new_value /. old_value
      else
        loans.(index) <- loans.(index) +. loan_delta;
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

Note: OCaml optional arguments before `()` - the call sites become `trade index ~date ~price ~desired ()` for sells (loan_delta defaults to 0.) and `trade index ~date ~price ~desired ~loan_delta ()` for buys.

**b)** Replace `apply_fills` (lines 265-275) with:

```ocaml
  let apply_fills ~date ~eff ~clamped price_at =
    if clamped then incr clamps;
    (* pass 1: sells *)
    for index = 0 to asset_count - 1 do
      if eff.(index) < prev_eff.(index) then
        trade index ~date ~price:(price_at index) ~desired:eff.(index) ()
    done;
    (* pass 2: buys with joint loan allocation *)
    let buys = ref [] in
    for index = asset_count - 1 downto 0 do
      if eff.(index) > prev_eff.(index) then
        buys := index :: !buys
    done;
    if !buys <> [] then begin
      (* compute each buy's value increase after costs *)
      let equity_before = equity () in
      let buy_values =
        List.map
          (fun index ->
            let from_e = values.(index) /. equity_before in
            let delta = eff.(index) -. from_e in
            let cost = charge index ~equity_before ~delta in
            let equity_after = equity_before *. (1. -. cost) in
            let new_value = eff.(index) *. equity_after in
            let increase = new_value -. values.(index) in
            (index, Float.max 0. increase))
          !buys
      in
      let total_buy =
        List.fold_left (fun acc (_, v) -> acc +. v) 0. buy_values
      in
      let cash_available = !cash in
      let shortfall = Float.max 0. (total_buy -. cash_available) in
      let loan_deltas =
        if shortfall <= 0. then
          List.map (fun (index, _) -> (index, 0.)) buy_values
        else begin
          let total_capacity =
            List.fold_left
              (fun acc (index, v) -> acc +. v *. margin.ratios.(index))
              0. buy_values
          in
          List.map
            (fun (index, v) ->
              let capacity = v *. margin.ratios.(index) in
              (index, shortfall *. capacity /. total_capacity))
            buy_values
        end
      in
      List.iter
        (fun (index, loan_delta) ->
          trade index ~date ~price:(price_at index)
            ~desired:eff.(index) ~loan_delta ())
        loan_deltas
    end;
    Array.blit eff 0 prev_eff 0 asset_count;
    if equity () <= 0.
       && not (Array.exists (fun value -> value > 0.) values)
    then bankrupt := true
  in
```

**c)** Update all other `trade` call sites to append `()`:
- `sell_out` does not call `trade`; no change.
- The `liquidate` helper calls `sell_out`; no change.
- Any direct `trade` call outside `apply_fills` (there should be none after sub-project B; verify by searching for `trade ` in the file).

**Important caveat on the buy-value estimation:** The `buy_values` computation above estimates each buy's value increase using the pre-buy equity. But `trade` calls are sequential and each one changes equity via costs. The estimate is close but not exact when costs are nonzero. The loan allocation uses these estimates only to set proportions; the actual position sizing still happens inside `trade` with the real sequential equity. The loan amounts will be slightly off from the ideal formula, but the key property - order-independence - holds because the proportion computation does not depend on execution order. Add a comment noting this approximation.

- [ ] **Step 4: Verify build and tests pass**

Run: `opam exec -- dune build && opam exec -- dune runtest`
Expected: build clean, tests print `ok`, including both new tests and all existing tests.

- [ ] **Step 5: Commit**

```bash
git add lib/engine.ml test/test_bt.ml
git commit -m "fix: allocate margin loans jointly across assets

Co-authored-by: ChatGPT <noreply@openai.com>"
```
