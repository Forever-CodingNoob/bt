open Btlib

let assert_close ?(tolerance = 1e-9) expected actual =
  if Float.is_nan expected then assert (Float.is_nan actual)
  else assert (abs_float (expected -. actual) < tolerance)

let assert_float_array expected actual =
  assert (Array.length expected = Array.length actual);
  for i = 0 to Array.length expected - 1 do
    assert_close expected.(i) actual.(i)
  done

let assert_failure function_ =
  let failed =
    try
      function_ ();
      false
    with Failure _ -> true
  in
  assert failed

let with_temp_strategy contents function_ =
  let path = Filename.temp_file "bt-test-" ".strat" in
  Fun.protect
    ~finally:(fun () -> try Sys.remove path with Sys_error _ -> ())
    (fun () ->
      let output = open_out path in
      Fun.protect
        ~finally:(fun () -> close_out output)
        (fun () -> output_string output contents);
      function_ path)

let rec locate = function
  | [] -> failwith "test fixture not found"
  | path :: rest -> if Sys.file_exists path then path else locate rest

let sma_strategy_path () =
  locate ["examples/sma_cross.strat"; "../examples/sma_cross.strat"]

let bb_strategy_path () =
  locate ["examples/bb_macd.strat"; "../examples/bb_macd.strat"]

let buy_hold_strategy_path () =
  locate ["examples/00685L_bh.strat"; "../examples/00685L_bh.strat"]

let fixture_path () =
  locate ["test/fixtures/synthetic.csv"; "fixtures/synthetic.csv"]

let bar date o c : Data.bar =
  { date; o; h = max o c +. 1.; l = min o c -. 1.; c; v = 1000. }

let sample_bars =
  [| bar "2020-01-01" 100. 100.;
     bar "2020-01-02" 100. 110.;
     bar "2020-01-03" 120. 126.;
     bar "2020-01-04" 126. 138.6;
     bar "2020-01-05" 138.6 145.53 |]

let test_filter_dates () =
  let filtered =
    Data.filter_dates
      ~keep:(fun date -> date = "2020-01-02" || date = "2020-01-04")
      sample_bars
  in
  assert
    (Array.map (fun (bar : Data.bar) -> bar.date) filtered =
     [| "2020-01-02"; "2020-01-04" |])

let fill_bars =
  [| bar "2020-01-01" 100. 100.;
     bar "2020-01-02" 102. 104.;
     bar "2020-01-03" 106. 108.;
     bar "2020-01-06" 110. 112.;
     bar "2020-01-07" 114. 116. |]

let zero_costs : Engine.costs =
  { fee_bps = 0.; tax_bps = 0.; slip_bps = 0.; min_fee = 0. }

let rec scalar_value = function
  | Ast.Num number -> number
  | Ast.Unop ("-", expression) -> -. scalar_value expression
  | Ast.Binop ("+", left, right) -> scalar_value left +. scalar_value right
  | Ast.Binop ("-", left, right) -> scalar_value left -. scalar_value right
  | Ast.Binop ("*", left, right) -> scalar_value left *. scalar_value right
  | Ast.Binop ("/", left, right) -> scalar_value left /. scalar_value right
  | _ -> failwith "not a scalar arithmetic expression"

let test_parser () =
  ignore (Dsl.parse_file (sma_strategy_path ()));
  ignore (Dsl.parse_file (bb_strategy_path ()));
  ignore (Dsl.parse_file (buy_hold_strategy_path ()));
  with_temp_strategy "exit when close < 0\n" (fun path ->
    assert_failure (fun () -> ignore (Dsl.compile path ~params:[] sample_bars)));
  with_temp_strategy
    "entry when foo(close) > 0\nexit when close < 0\n"
    (fun path ->
      assert_failure (fun () -> ignore (Dsl.compile path ~params:[] sample_bars)));
  with_temp_strategy "let result = 1 + 2 * 3\n" (fun path ->
    match Dsl.parse_file path with
    | [Ast.Let ("result", expression)] -> assert_close 7. (scalar_value expression)
    | _ -> assert false)

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

let test_indicators () =
  let source = [|1.; 2.; 3.; 4.; 5.|] in
  assert_float_array
    [|Float.nan; Float.nan; 2.; 3.; 4.|]
    (Series.sma source 3);
  assert_close (sqrt 2.) (Series.stddev source 5).(4);
  let average = Series.sma source 3 in
  let exponential = Series.ema source 3 in
  assert_close average.(2) exponential.(2);
  assert_float_array
    [|Float.nan; Float.nan; 1.; 2.; 3.|]
    (Series.lag source 2);
  let increasing = Series.rsi [|1.; 2.; 3.; 4.; 5.; 6.|] 3 in
  for i = 3 to Array.length increasing - 1 do
    assert_close 100. increasing.(i)
  done;
  let alternating = Series.rsi [|0.; 1.; 0.; 1.; 0.|] 4 in
  assert_close 50. alternating.(4);
  assert (Series.cross_above [|1.; 3.|] [|2.; 2.|] = [|false; true|]);
  let width = 2. in
  let upper = Series.bb_upper source 3 width in
  let lower = Series.bb_lower source 3 width in
  let deviation = Series.stddev source 3 in
  for i = 0 to Array.length source - 1 do
    if Float.is_nan deviation.(i) then begin
      assert (Float.is_nan upper.(i));
      assert (Float.is_nan lower.(i))
    end
    else
      assert_close (2. *. width *. deviation.(i)) (upper.(i) -. lower.(i))
  done;
  let macd_source = Array.init 60 (fun i -> float_of_int i +. sin (float_of_int i)) in
  let line = Series.macd macd_source 3 5 in
  let signal = Series.macd_signal macd_source 3 5 2 in
  let histogram = Series.macd_hist macd_source 3 5 2 in
  for i = 0 to Array.length macd_source - 1 do
    let expected = line.(i) -. signal.(i) in
    assert_close expected histogram.(i)
  done

let final_equity (result : Engine.result) =
  match result.equity_curve with
  | [] -> failwith "empty equity curve"
  | first :: rest ->
      snd (List.fold_left (fun _ point -> point) first rest)

(* computed by independent python simulation of the spec *)
let engine_zero_expected = 1.2127499999999998
let engine_fee_expected = 1.188616275
let golden_expected = 1.7291207425596153

let no_margin count : Engine.margin =
  { financing_rate = 0.; maintenance_ratio = 0.;
    ratios = Array.make count 1. }

let run_single bars target costs ~capital ~fill =
  Engine.run [| ("tw/TEST", bars) |] { Engine.targets = [| target |] }
    [| costs |] ~margin:(no_margin 1) ~capital ~fill

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

let test_engine_bankruptcy () =
  (* buy 2.5 at 100: v = 2.5, cash = -1.5. At 50, v = 1.25,
     equity = -0.25, and maintenance = 1.25 / 1.5, so the next-open
     liquidation repays 1.25 and freezes the bankrupt account at -0.25. *)
  let bars =
    [| bar "2020-01-01" 100. 100.;
       bar "2020-01-02" 50. 50.;
       bar "2020-01-03" 50. 60. |]
  in
  let margin : Engine.margin =
    { financing_rate = 0.; maintenance_ratio = 1.3; ratios = [| 0.6 |] }
  in
  let result =
    Engine.run [| ("tw/TEST", bars) |]
      { Engine.targets = [| [| 2.5; 2.5; 2.5 |] |] }
      [| zero_costs |] ~margin ~capital:None ~fill:Engine.Close_same
  in
  let last = final_equity result in
  assert (not (Float.is_nan last));
  assert_close ~tolerance:1e-12 (-0.25) last;
  assert (List.length result.fills = 2);
  assert (result.margin_stats.Engine.margin_calls = 1);
  (match result.margin_stats.Engine.min_maintenance with
   | Some ratio -> assert_close ~tolerance:1e-12 (1.25 /. 1.5) ratio
   | None -> assert false);
  (match result.trips with
   | [trip] -> assert_close ~tolerance:1e-12 (-0.5) trip.net_ret
   | _ -> assert false)

let test_engine_insolvent_gap () =
  (* buy 2.0 at 100: v = 2, cash = -1. At 50, v = 1 and equity is
     exactly 0, so the close-price solvency guard sells at 50, repays the
     loan, and skips the target-0 fill with nothing left to hold. *)
  let bars =
    [| bar "2020-01-01" 100. 100.;
       bar "2020-01-02" 50. 50. |]
  in
  let margin : Engine.margin =
    { financing_rate = 0.; maintenance_ratio = 1.3; ratios = [| 0.6 |] }
  in
  let result =
    Engine.run [| ("tw/TEST", bars) |]
      { Engine.targets = [| [| 2.; 0. |] |] }
      [| zero_costs |] ~margin ~capital:None ~fill:Engine.Close_same
  in
  let last = final_equity result in
  assert (not (Float.is_nan last));
  assert_close ~tolerance:1e-12 0. last;
  assert (List.length result.fills = 2);
  assert (result.margin_stats.Engine.margin_calls = 1);
  (match result.margin_stats.Engine.min_maintenance with
   | Some ratio -> assert_close ~tolerance:1e-12 1. ratio
   | None -> assert false);
  (match result.trips with
   | [trip] -> assert_close ~tolerance:1e-12 (-0.5) trip.net_ret
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

let test_engine () =
  let target = [|0.; 1.; 1.; 1.; 1.|] in
  let zero_result =
    run_single sample_bars target zero_costs ~capital:None ~fill:Engine.Open_next
  in
  assert_close ~tolerance:1e-12 engine_zero_expected (final_equity zero_result);
  let fee_costs : Engine.costs =
    { fee_bps = 100.; tax_bps = 0.; slip_bps = 0.; min_fee = 0. }
  in
  let fee_result =
    run_single sample_bars target fee_costs ~capital:None ~fill:Engine.Open_next
  in
  assert_close ~tolerance:1e-12 engine_fee_expected (final_equity fee_result)

let test_engine_close () =
  let target = [|0.; 1.; 1.; 0.; 0.|] in
  let result =
    run_single fill_bars target zero_costs ~capital:None ~fill:Engine.Close_same
  in
  (* buy at close 104, accrue 108/104 and 112/108, sell at close 112 *)
  assert_close ~tolerance:1e-12 (112. /. 104.) (final_equity result);
  assert (List.length result.fills = 2);
  assert (List.length result.trips = 1);
  let trip = List.hd result.trips in
  assert (trip.Engine.entry_date = "2020-01-02");
  assert (trip.Engine.exit_date = "2020-01-06");
  (* NaN target means flat: same run with a NaN leading bar *)
  let with_nan = [|Float.nan; 1.; 1.; 0.; 0.|] in
  let result_nan =
    run_single fill_bars with_nan zero_costs ~capital:None ~fill:Engine.Close_same
  in
  assert_close ~tolerance:1e-12
    (final_equity result) (final_equity result_nan)

let test_engine_close_costs () =
  let target = [|0.; 1.; 1.; 0.; 0.|] in
  let costs : Engine.costs =
    { fee_bps = 100.; tax_bps = 0.; slip_bps = 0.; min_fee = 0. }
  in
  let result =
    run_single fill_bars target costs ~capital:None ~fill:Engine.Close_same
  in
  (* 1% haircut on each side of the round trip *)
  assert_close ~tolerance:1e-12
    (0.99 *. 0.99 *. 112. /. 104.) (final_equity result)

let test_engine_min_fee () =
  let target = [| 0.; 1.; 1.; 0.; 0. |] in
  let costs : Engine.costs =
    { fee_bps = 3.99; tax_bps = 0.; slip_bps = 0.; min_fee = 20. }
  in
  let result =
    run_single fill_bars target costs
      ~capital:(Some 10000.) ~fill:Engine.Close_same
  in
  let e1 = (1. -. 0.002) *. 112. /. 104. in
  let sell_commission =
    Float.max
      (1.0 *. 3.99 /. 10000.)
      (20. /. (e1 *. 10000.))
  in
  let expected = e1 *. (1. -. sell_commission) in
  assert_close ~tolerance:1e-12 expected (final_equity result)

let test_engine_min_fee_without_capital () =
  let target = [| 0.; 1.; 1.; 0.; 0. |] in
  let costs : Engine.costs =
    { fee_bps = 3.99; tax_bps = 0.; slip_bps = 0.; min_fee = 20. }
  in
  let result =
    run_single fill_bars target costs ~capital:None ~fill:Engine.Close_same
  in
  let expected =
    (1. -. 3.99 /. 10000.) *. (112. /. 104.)
    *. (1. -. 3.99 /. 10000.)
  in
  assert_close ~tolerance:1e-12 expected (final_equity result)

let test_engine_partial () =
  let target = [|0.; 0.5; 1.; 0.5; 0.|] in
  let result =
    run_single fill_bars target zero_costs ~capital:None ~fill:Engine.Close_same
  in
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
  let target = [|0.; 0.5; 1.; 0.5; 0.|] in
  let costs : Engine.costs =
    { fee_bps = 100.; tax_bps = 0.; slip_bps = 0.; min_fee = 0. }
  in
  let result =
    run_single fill_bars target costs ~capital:None ~fill:Engine.Close_same
  in
  (* Value and cash drift separately. Fees use the drifted exposure delta:
     buy the remaining cash at 108, sell 0.5 at 112, then close the
     drifted position at 116. *)
  let v1 = 0.5 *. (1. -. 0.005) in
  let c1 = (1. -. 0.005) -. v1 in
  let v2 = v1 *. (108. /. 104.) in
  let e2 = c1 +. v2 in
  let e2' = e2 -. 0.01 *. (e2 -. v2) in
  let e3 = e2' *. (112. /. 108.) in
  let e3' = e3 *. (1. -. 0.005) in
  let v4 = 0.5 *. e3' *. (116. /. 112.) in
  let e4 = 0.5 *. e3' +. v4 in
  let expected = e4 -. 0.01 *. v4 in
  assert_close ~tolerance:1e-12 expected (final_equity result)

let test_engine_partial_open () =
  (* Fills occur at the next opens 106, 110, and 114. The 0.5 position
     drifts from open 106 through close 108 to open 110; continuous
     compounding between fills replaces the per-leg daily reset. *)
  let target = [|0.; 0.5; 1.; 0.5; 0.|] in
  let result =
    run_single fill_bars target zero_costs ~capital:None ~fill:Engine.Open_next
  in
  let expected =
    (0.5 +. 0.5 *. (110. /. 106.))
    *. (114. /. 110.)
    *. (0.5 +. 0.5 *. (116. /. 114.))
  in
  assert_close ~tolerance:1e-12 expected (final_equity result);
  assert (List.length result.fills = 4);
  assert (List.length result.trips = 1)

let test_engine_partial_open_costs () =
  let target = [| 0.; 0.5; 1.; 0.5; 0. |] in
  let costs : Engine.costs =
    { fee_bps = 100.; tax_bps = 0.; slip_bps = 0.; min_fee = 0. }
  in
  let result =
    run_single fill_bars target costs ~capital:None ~fill:Engine.Open_next
  in
  (* The half position bought at 106 drifts through the 108 close and 110
     open. Every fee uses the drifted exposure delta: buy the remaining
     cash, sell 0.5 at 114, then close the drifted position at 116. *)
  let c1 = (1. -. 0.005) -. 0.5 *. (1. -. 0.005) in
  let v1 = 0.5 *. (1. -. 0.005) *. (108. /. 106.) in
  let v2 = v1 *. (110. /. 108.) in
  let e2 = c1 +. v2 in
  let e2' = e2 -. 0.01 *. (e2 -. v2) in
  let e3 = e2' *. (114. /. 110.) in
  let e3' = e3 *. (1. -. 0.005) in
  let v4 = 0.5 *. e3' *. (116. /. 114.) in
  let e4 = 0.5 *. e3' +. v4 in
  let expected = e4 -. 0.01 *. v4 in
  assert_close ~tolerance:1e-12 expected (final_equity result)

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
      [| zero_costs; zero_costs |] ~margin:(no_margin 2)
      ~capital:None ~fill:Engine.Close_same
  in
  (* after day 2, cash = 0.08, A = 0.55, and B = 0.42; on day 3,
     A drifts to 0.605 and B to 0.504 before both close for free *)
  assert_close ~tolerance:1e-12
    (0.08 +. 0.5 *. 1.1 *. (121. /. 110.)
     +. 0.4 *. 1.05 *. (54. /. 45.))
    (final_equity result);
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

let test_engine_portfolio_costs () =
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
  let a_costs : Engine.costs =
    { fee_bps = 100.; tax_bps = 0.; slip_bps = 0.; min_fee = 0. }
  in
  let b_costs : Engine.costs =
    { fee_bps = 0.; tax_bps = 100.; slip_bps = 0.; min_fee = 0. }
  in
  let result =
    Engine.run [| ("tw/A", a); ("tw/B", b) |]
      { Engine.targets =
          [| [| 0.5; 0.5; 0. |]; [| 0.; 0.4; 0. |] |] }
      [| a_costs; b_costs |] ~margin:(no_margin 2)
      ~capital:None ~fill:Engine.Close_same
  in
  (* A's buy costs 0.5%; B's buy is free; each final sell costs 1%
     of that position's drifted value. *)
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
  assert_close ~tolerance:1e-12 expected (final_equity result)

let test_engine_portfolio_min_fee () =
  let a =
    [| bar "2020-01-01" 100. 100.;
       bar "2020-01-02" 100. 100. |]
  in
  let b =
    [| bar "2020-01-01" 50. 50.;
       bar "2020-01-02" 50. 50. |]
  in
  let costs : Engine.costs =
    { fee_bps = 3.99; tax_bps = 0.; slip_bps = 0.; min_fee = 20. }
  in
  let result =
    Engine.run [| ("tw/A", a); ("tw/B", b) |]
      { Engine.targets =
          [| [| 0.5; 0. |]; [| 0.5; 0. |] |] }
      [| costs; costs |] ~margin:(no_margin 2)
      ~capital:(Some 10000.) ~fill:Engine.Close_same
  in
  let after_a_buy = 1. -. 0.002 in
  let after_b_buy =
    after_a_buy *. (1. -. 20. /. (after_a_buy *. 10000.))
  in
  let after_a_sell =
    after_b_buy *. (1. -. 20. /. (after_b_buy *. 10000.))
  in
  let expected =
    after_a_sell *. (1. -. 20. /. (after_a_sell *. 10000.))
  in
  assert_close ~tolerance:1e-12 expected (final_equity result)

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
      [| zero_costs; zero_costs |] ~margin:(no_margin 2)
      ~capital:None ~fill:Engine.Open_next
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
  (* The first half drifts to weight 11/21 at 110, so reaching target 1
     buys only the remaining weight 10/21. *)
  let entry_price =
    (0.5 *. 100. +. (10. /. 21.) *. 110.) /. (0.5 +. 10. /. 21.)
  in
  (match result.trips with
   | [trip] ->
       assert_close ~tolerance:1e-12
         (126. /. entry_price -. 1.) trip.net_ret
   | _ -> assert false)

let test_engine_vwap_multi_exit () =
  let bars =
    [| bar "2020-01-01" 100. 100.;
       bar "2020-01-02" 110. 110.;
       bar "2020-01-03" 126. 126. |]
  in
  let result =
    run_single bars [| 1.0; 0.5; 0.0 |] zero_costs
      ~capital:None ~fill:Engine.Close_same
  in
  (* After selling to 0.5 at 110, the position drifts to weight 126/236
     before the final sale at 126. *)
  let w = 126. /. 236. in
  let exit_price = (0.5 *. 110. +. w *. 126.) /. (0.5 +. w) in
  match result.trips with
  | [trip] ->
      assert_close ~tolerance:1e-12
        (exit_price /. 100. -. 1.) trip.net_ret
  | _ -> assert false

let dsl_bars =
  (* closes 100 105 110 100 90; open = previous close *)
  [| bar "2020-01-01" 100. 100.;
     bar "2020-01-02" 100. 105.;
     bar "2020-01-03" 105. 110.;
     bar "2020-01-06" 110. 100.;
     bar "2020-01-07" 100. 90. |]

let test_stock_statement () =
  with_temp_strategy
    "stock \"tw/00685L\"\ntarget 1.0\n"
    (fun path ->
      let parsed = Dsl.parse_file path in
      assert
        (Dsl.stocks_of ~filename:path parsed =
         [ (None, "tw", "00685L") ]);
      (* stock is ignored by compilation *)
      let strategy = Dsl.compile path ~params:[] dsl_bars in
      assert (Array.length strategy.Engine.targets.(0) = Array.length dsl_bars));
  let rejects source =
    with_temp_strategy source (fun path ->
      assert_failure (fun () ->
        ignore (Dsl.stocks_of ~filename:path (Dsl.parse_file path))))
  in
  rejects "target 1.0\n";
  rejects "stock \"tw/1\"\nstock \"tw/2\"\ntarget 1.0\n";
  rejects "stock \"jp/7203\"\ntarget 1.0\n";
  rejects "stock \"tw00685L\"\ntarget 1.0\n";
  rejects "stock \"tw/0050/extra\"\ntarget 1.0\n"

let test_target_style () =
  with_temp_strategy
    "target num(hold(cross_above(close, 104.0), cross_below(close, 104.0)))\n"
    (fun path ->
      let strategy = Dsl.compile path ~params:[] dsl_bars in
      assert (strategy.Engine.targets.(0) = [| 0.; 1.; 1.; 0.; 0. |]);
      let result =
        Engine.run [| ("tw/TEST", dsl_bars) |] strategy [| zero_costs |]
          ~margin:(no_margin 1) ~capital:None ~fill:Engine.Close_same
      in
      (* buy close 105, accrue 110/105 then 100/110, sell close 100 *)
      assert_close ~tolerance:1e-12 (100. /. 105.) (final_equity result);
      assert (List.length result.trips = 1);
      assert ((List.hd result.trips).Engine.net_ret < 0.))

let test_hold_tie_break () =
  with_temp_strategy
    "target num(hold(close > 50.0, close > 0.0))\n"
    (fun path ->
      let strategy = Dsl.compile path ~params:[] dsl_bars in
      assert (strategy.Engine.targets.(0) = [| 0.; 0.; 0.; 0.; 0. |]))

let test_order_style () =
  with_temp_strategy
    ("cap 1.0\n\
      entry when cross_above(close, 104.0) size 0.5\n\
      entry when cross_above(close, 108.0) size 0.5\n\
      exit when cross_below(close, 104.0) size 1.0\n")
    (fun path ->
      let strategy = Dsl.compile path ~params:[] dsl_bars in
      assert (strategy.Engine.targets.(0) = [| 0.; 0.5; 1.; 0.; 0. |]))

let test_style_errors () =
  let rejects source =
    with_temp_strategy source (fun path ->
      assert_failure (fun () -> ignore (Dsl.compile path ~params:[] dsl_bars)))
  in
  rejects "target 1.0\nentry when close > 0.0\nexit when close < 0.0\n";
  rejects "target 1.0\ntarget 0.5\n";
  rejects "target 1.0\ncap 1.0\n";
  rejects "target 1.0\nsize 1.0\n";
  rejects "entry when close > 0.0 size 0.5\nsize 1.0\n";
  rejects "exit when close < 0.0 size 0.5\n"

let load_fixture path =
  let input = open_in path in
  Fun.protect
    ~finally:(fun () -> close_in input)
    (fun () ->
      assert (input_line input = "date,open,high,low,close,volume");
      let rec loop reversed =
        match input_line input with
        | line ->
            begin
              match String.split_on_char ',' line with
              | [date; o; h; l; c; v] ->
                  let item : Data.bar =
                    { date;
                      o = float_of_string o;
                      h = float_of_string h;
                      l = float_of_string l;
                      c = float_of_string c;
                      v = float_of_string v }
                  in
                  loop (item :: reversed)
              | _ -> failwith "malformed fixture row"
            end
        | exception End_of_file -> Array.of_list (List.rev reversed)
      in
      loop [])

let test_golden () =
  let bars = load_fixture (fixture_path ()) in
  assert (Array.length bars = 300);
  let strategy =
    Dsl.compile (sma_strategy_path ()) ~params:["fast", 5.; "slow", 20.] bars
  in
  let costs : Engine.costs =
    { fee_bps = 0.; tax_bps = 0.; slip_bps = 0.; min_fee = 0. }
  in
  let result =
    Engine.run [| ("tw/TEST", bars) |] strategy [| costs |]
      ~margin:(no_margin 1) ~capital:None ~fill:Engine.Open_next
  in
  assert (List.length result.trips = 4);
  assert (List.length result.fills = 8);
  let first = List.hd result.trips in
  assert (first.entry_date = "2020-04-01");
  assert (first.exit_date = "2020-05-26");
  begin
    match result.fills with
    | entry_fill :: exit_fill :: _ ->
        assert_close 95.06670608432421 entry_fill.Engine.price;
        assert_close 112.60606577730466 exit_fill.Engine.price;
        assert_close
          (exit_fill.Engine.price /. entry_fill.Engine.price -. 1.)
          first.net_ret
    | _ -> assert false
  end;
  assert_close golden_expected (final_equity result)

let test_report_stem () =
  assert (Report.stem ~names:["a"; "b"] ~out_name:None = "a_vs_b");
  assert (Report.stem ~names:["a"] ~out_name:(Some "x") = "x")

let test_multi_strat_fixture () =
  let sma_source =
    {|stock "tw/FIXTURE"
param fast = 50
param slow = 200
entry when cross_above(sma(close, fast), sma(close, slow))
exit  when cross_below(sma(close, fast), sma(close, slow))
|}
  in
  let buy_hold_source =
    {|stock "tw/FIXTURE"
target 1.0
|}
  in
  with_temp_strategy sma_source (fun sma_path ->
    with_temp_strategy buy_hold_source (fun buy_hold_path ->
      let bars = load_fixture (fixture_path ()) in
      let declarations =
        Dsl.declared_params_ast (Dsl.parse_file sma_path)
      in
      assert (declarations = ["fast", 50.; "slow", 200.]);
      let sma =
        Dsl.compile sma_path ~params:["fast", 5.; "slow", 20.] bars
      in
      let buy_hold = Dsl.compile buy_hold_path ~params:[] bars in
      let sma_result =
        Engine.run [| ("tw/TEST", bars) |] sma [| zero_costs |]
          ~margin:(no_margin 1) ~capital:None ~fill:Engine.Open_next
      in
      let buy_hold_result =
        Engine.run [| ("tw/TEST", bars) |] buy_hold [| zero_costs |]
          ~margin:(no_margin 1) ~capital:None ~fill:Engine.Close_same
      in
      let last = Array.length bars - 1 in
      assert_close golden_expected (final_equity sma_result);
      assert_close
        (bars.(last).Data.c /. bars.(0).Data.c)
        (final_equity buy_hold_result)))

let test_baseline_output_header () =
  let out_dir = Filename.temp_file "bt-test-report-" "" in
  Sys.remove out_dir;
  Unix.mkdir out_dir 0o700;
  Fun.protect
    ~finally:(fun () ->
      Array.iter
        (fun name -> Sys.remove (Filename.concat out_dir name))
        (Sys.readdir out_dir);
      Unix.rmdir out_dir)
    (fun () ->
      let result : Engine.result =
        { equity_curve = ["2020-01-01", 1.; "2020-01-02", 1.1];
          fills = [];
          trips = [];
          margin_stats =
            { min_maintenance = None; margin_calls = 0; clamps = 0 } }
      in
      Report.write_outputs
        ~out_dir ~stem:"pair" ~columns:["a", result]
        ~baseline:(Some result);
      let input = open_in (Filename.concat out_dir "pair.csv") in
      let header =
        Fun.protect
          ~finally:(fun () -> close_in input)
          (fun () -> input_line input)
      in
      assert (header = "date,a,baseline");
      assert (not (Sys.file_exists
        (Filename.concat out_dir "baseline.trades.csv"))))

let test_prepend_rows () =
  let cache = Filename.temp_file "bt-test-cache" ".csv" in
  let rows = Filename.temp_file "bt-test-rows" ".csv" in
  let write path text =
    let out = open_out path in
    output_string out text;
    close_out out
  in
  write cache "date,open,high,low,close,volume\n2020-01-03,2.,3.,3.,3.,1\n2020-01-04,3.,4.,4.,4.,1\n";
  write rows "2020-01-01,1.,1.,1.,1.,1\n2020-01-02,1.,2.,2.,2.,1\n2020-01-03,9.,9.,9.,9.,9\n";
  Data.prepend_rows ~header:"date,open,high,low,close,volume"
    ~rows_path:rows ~cache_path:cache ~before:"2020-01-03";
  let bars = Data.read_bars ~market:"tw" cache in
  Sys.remove rows;
  (* the 2020-01-03 row from the fetch is dropped: cache wins at the seam *)
  assert (Array.length bars = 4);
  assert (bars.(0).Data.date = "2020-01-01");
  assert (bars.(2).Data.date = "2020-01-03");
  assert (bars.(2).Data.c = 3.);
  let data_dir = Filename.temp_file "bt-test-data-" "" in
  Sys.remove data_dir;
  Unix.mkdir data_dir 0o700;
  let tw_dir = Filename.concat data_dir "tw" in
  Unix.mkdir tw_dir 0o700;
  let symbol = "SEAM" in
  let stock_path = Filename.concat tw_dir (symbol ^ ".csv") in
  let dividend_path = Filename.concat tw_dir (symbol ^ ".div.csv") in
  Fun.protect
    ~finally:(fun () ->
      (try Sys.remove cache with Sys_error _ -> ());
      (try Sys.remove stock_path with Sys_error _ -> ());
      (try Sys.remove dividend_path with Sys_error _ -> ());
      Unix.rmdir tw_dir;
      Unix.rmdir data_dir)
    (fun () ->
      Sys.rename cache stock_path;
      write dividend_path "date,factor\n2020-01-04,0.5\n";
      let adjusted =
        Data.load ~market:"tw" ~symbol ~from_:None ~to_:None ~data_dir
      in
      assert (adjusted.(0).Data.date = "2020-01-01");
      assert_close (1. *. 0.5) adjusted.(0).Data.c;
      assert (adjusted.(3).Data.date = "2020-01-04");
      assert_close 4. adjusted.(3).Data.c)

let test_head_probe_gate () =
  assert
    (not (Data.should_probe_head ~from_:None
       ~first_cached:"2008-01-01"));
  assert
    (Data.should_probe_head ~from_:(Some "1994-10-01")
       ~first_cached:"2008-01-01");
  assert
    (not (Data.should_probe_head ~from_:(Some "2010-01-01")
       ~first_cached:"2008-01-01"))

let contains text fragment =
  let text_length = String.length text in
  let fragment_length = String.length fragment in
  let rec search index =
    if index + fragment_length > text_length then false
    else if String.sub text index fragment_length = fragment then true
    else search (index + 1)
  in
  search 0

let test_plot_script () =
  let path = locate ["scripts/plot.py"; "../scripts/plot.py"] in
  let input = open_in_bin path in
  let contents =
    Fun.protect
      ~finally:(fun () -> close_in input)
      (fun () -> really_input_string input (in_channel_length input))
  in
  assert (contains contents "matplotlib.use(\"Agg\")");
  assert (contains contents "fig.savefig");
  let out_dir = Filename.temp_file "bt-test-plot-" "" in
  Sys.remove out_dir;
  Unix.mkdir out_dir 0o700;
  Fun.protect
    ~finally:(fun () ->
      Array.iter
        (fun name -> Sys.remove (Filename.concat out_dir name))
        (Sys.readdir out_dir);
      Unix.rmdir out_dir)
    (fun () ->
      let csv_path = Filename.concat out_dir "equity.csv" in
      let output = open_out csv_path in
      Fun.protect
        ~finally:(fun () -> close_out output)
        (fun () ->
          output_string output
            "date,strategy\n2020-01-01,1.0\n2020-01-02,1.1\n");
      Report.write_png ~out_dir ~stem:"equity";
      assert (not (Sys.file_exists (Filename.concat out_dir "plot.py"))))


let read_file path =
  let input = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in input)
    (fun () -> really_input_string input (in_channel_length input))

let test_multi_stock_cli () =
  let root = Filename.temp_file "bt-test-multi-" "" in
  Sys.remove root;
  Unix.mkdir root 0o700;
  let tw_dir = Filename.concat root "tw" in
  let out_dir = Filename.concat root "out" in
  let remove_flat_dir path =
    if Sys.file_exists path then begin
      Array.iter
        (fun name -> Sys.remove (Filename.concat path name))
        (Sys.readdir path);
      Unix.rmdir path
    end
  in
  Fun.protect
    ~finally:(fun () ->
      remove_flat_dir out_dir;
      remove_flat_dir tw_dir;
      Array.iter
        (fun name -> Sys.remove (Filename.concat root name))
        (Sys.readdir root);
      Unix.rmdir root)
    (fun () ->
      Unix.mkdir tw_dir 0o700;
      let write path contents =
        let output = open_out path in
        Fun.protect
          ~finally:(fun () -> close_out output)
          (fun () -> output_string output contents)
      in
      write (Filename.concat tw_dir "AA.csv")
        "date,open,high,low,close,volume\n\
         2020-01-01,100,101,99,100,1000\n\
         2020-01-02,110,111,109,110,1000\n\
         2020-01-03,121,122,120,121,1000\n\
         2020-01-06,130,131,129,130,1000\n";
      write (Filename.concat tw_dir "BB.csv")
        "date,open,high,low,close,volume\n\
         2020-01-01,50,51,49,50,1000\n\
         2020-01-02,55,56,54,55,1000\n\
         2020-01-03,66,67,65,66,1000\n";
      let strategy_path = Filename.concat root "mm.strat" in
      write strategy_path
        "stock \"tw/AA\" as a\n\
         stock \"tw/BB\" as b\n\
         a.target 1.0\n\
         b.target 0.5\n";
      let stdout_path = Filename.concat root "stdout.txt" in
      let binary =
        locate ["_build/default/bin/bt.exe"; "../bin/bt.exe"]
      in
      let command =
        String.concat " "
          [ Filename.quote binary;
            "run";
            Filename.quote strategy_path;
            "--data-dir";
            Filename.quote root;
            "--out-dir";
            Filename.quote out_dir;
            "--out-name";
            "mm";
            "--no-plot";
            "--fee-bps";
            "0";
            "--tax-bps";
            "0";
            "--slip-bps";
            "0";
            "--min-fee";
            "0";
            ">";
            Filename.quote stdout_path;
            "2>&1" ]
      in
      assert (Sys.command command = 0);
      let read_lines path =
        let input = open_in path in
        Fun.protect
          ~finally:(fun () -> close_in input)
          (fun () ->
            let rec loop reversed =
              match input_line input with
              | line -> loop (line :: reversed)
              | exception End_of_file -> List.rev reversed
            in
            loop [])
      in
      let curve_path = Filename.concat out_dir "mm.csv" in
      (match read_lines curve_path with
       | [header; _; _; last] ->
           assert (header = "date,mm");
           begin
             match String.split_on_char ',' last with
             | ["2020-01-03"; equity] ->
                 (* day 2 equity = 1.15; day 3: A = 1.21, B = 0.66,
                    cash = -0.5, so equity = 1.37 with financing off *)
                 assert_close ~tolerance:1e-9 1.37 (float_of_string equity)
             | _ -> assert false
           end
       | _ -> assert false);
      let trades =
        read_file (Filename.concat out_dir "mm.trades.csv")
      in
      match String.split_on_char '\n' trades with
      | header :: rows ->
          assert
            (header = "date,stock,price,from_exposure,to_exposure");
          let body = String.concat "\n" rows in
          assert (contains body "tw/AA");
          assert (contains body "tw/BB")
      | [] -> assert false)

let test_event_transform () =
  assert (
    Data.event_sources =
    [
      ("TaiwanStockSplitPrice", "before_price", "after_price");
      ("TaiwanStockCapitalReductionReferencePrice",
       "ClosingPriceonTheLastTradingDay", "PostReductionReferencePrice");
      ("TaiwanStockParValueChange", "before_close", "after_ref_close");
    ]);
  List.iter
    (fun (_dataset, before, after) ->
      let json =
        Printf.sprintf
          {|{"msg":"success","status":200,"data":[
             {"date":"2026-07-07","stock_id":"00685L","%s":306,"%s":12.75},
             {"date":"2026-07-08","stock_id":"9999","%s":100,"%s":50},
             {"date":"2026-07-09","stock_id":"00685L","%s":0,"%s":1},
             {"date":"2026-07-10","stock_id":"00685L","%s":null,"%s":1}]}|}
          before after before after before after before after
      in
      with_temp_strategy json (fun json_path ->
        with_temp_strategy "" (fun rows_path ->
          Data.transform_json ~args:["--arg"; "sym"; "00685L"]
            ~expression:(Data.event_expression ~before ~after)
            ~json_path ~rows_path;
          match
            String.split_on_char '\n' (String.trim (read_file rows_path))
          with
          | [row] ->
              (match String.split_on_char ',' row with
               | [date; factor] ->
                   assert (date = "\"2026-07-07\"");
                   assert_close (12.75 /. 306.) (float_of_string factor)
               | _ -> assert false)
          | _ -> assert false)))
    Data.event_sources;
  assert (List.length Data.event_sources = 3)

let test_back_adjust_events () =
  let bars =
    [| bar "2026-06-30" 300. 306.;
       bar "2026-07-07" 13.09 12.23 |]
  in
  Data.back_adjust bars [| ("2026-07-07", 12.75 /. 306.) |];
  assert_close 12.75 bars.(0).c;
  assert_close 12.23 bars.(1).c;
  let reduction =
    [| bar "2020-01-01" 100. 100.;
       bar "2020-01-02" 90. 90. |]
  in
  Data.back_adjust reduction [| ("2020-01-02", 0.9) |];
  assert_close 90. reduction.(0).c;
  let combined =
    [| bar "2020-01-01" 100. 100.;
       bar "2020-01-02" 45. 45. |]
  in
  Data.back_adjust combined [| ("2020-01-02", 0.9); ("2020-01-02", 0.5) |];
  assert_close 45. combined.(0).c

let test_load_events () =
  let root = Filename.temp_file "bt-test-data-" "" in
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
      let write path contents =
        let output = open_out path in
        Fun.protect
          ~finally:(fun () -> close_out output)
          (fun () -> output_string output contents)
      in
      write (Filename.concat tw "SPLIT.csv")
        "date,open,high,low,close,volume\n\
         2026-06-29,300,307,299,306,1000\n\
         2026-06-30,306,307,299,306,1000\n\
         2026-07-07,13.09,13.2,12.0,12.23,1000\n";
      write (Filename.concat tw "SPLIT.events.csv")
        "date,factor\n2026-07-07,0.041666666666666664\n";
      let bars =
        Data.load ~market:"tw" ~symbol:"SPLIT" ~from_:None ~to_:None
          ~data_dir:root
      in
      assert (Array.length bars = 3);
      assert_close 12.75 bars.(0).Data.c;
      assert_close 12.75 bars.(1).Data.c;
      assert_close 12.23 bars.(2).Data.c)

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
  (* alias collides with a let *)
  expect "stock \"tw/A\" as n\nlet n = 5\nn.target 1.0\n";
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

let () =
  test_parser ();
  test_parser_aliases ();
  test_filter_dates ();
  test_stock_statement ();
  test_multi_stock_compile ();
  test_multi_stock_errors ();
  test_indicators ();
  test_target_style ();
  test_hold_tie_break ();
  test_order_style ();
  test_style_errors ();
  test_engine_drift ();
  test_engine_interest ();
  test_engine_initial_margin_clamp ();
  test_engine_mixed_ratio_clamp ();
  test_engine_margin_call ();
  test_engine_bankruptcy ();
  test_engine_insolvent_gap ();
  test_engine_buyhold_costs ();
  test_engine_no_borrow_stats ();
  test_engine ();
  test_engine_close ();
  test_engine_close_costs ();
  test_engine_min_fee ();
  test_engine_min_fee_without_capital ();
  test_engine_partial ();
  test_engine_partial_costs ();
  test_engine_partial_open ();
  test_engine_partial_open_costs ();
  test_engine_portfolio_close ();
  test_engine_portfolio_costs ();
  test_engine_portfolio_min_fee ();
  test_engine_portfolio_open ();
  test_engine_vwap_trip ();
  test_engine_vwap_multi_exit ();
  test_golden ();
  test_report_stem ();
  test_multi_strat_fixture ();
  test_baseline_output_header ();
  test_multi_stock_cli ();
  test_prepend_rows ();
  test_head_probe_gate ();
  test_plot_script ();
  test_back_adjust_events ();
  test_load_events ();
  test_financing_ratio ();
  test_event_transform ();
  print_endline "ok"
