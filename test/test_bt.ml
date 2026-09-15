
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
  { fee_bps = 0.; tax_bps = 0.; slip_bps = 0.; min_fee = 0.;
    per_share_sell_fee = 0.; per_share_sell_cap = 0. }

let test_default_costs () =
  let tax_bps symbol =
    (Engine.default_costs ~market:"tw" ~symbol).tax_bps
  in
  (* The ordinary bond-ETF exemption runs from 2017-01-01 through 2026-12-31. *)
  assert (tax_bps "00679B" = 0.);
  assert (tax_bps "020000" = 10.);
  assert (tax_bps "0050" = 10.);
  assert (tax_bps "2330" = 30.)

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

(* The zero-cost and golden anchors come from independent simulation. *)
let engine_zero_expected = 1.2127499999999998
let engine_fee_expected =
  (* Entry at open 120: each pass applies E1 = E0 - 0.01 * E1.
     The fifth E1 sizes the position; the sixth cost result is the
     post-fill equity. The force-close fee is 1% of the drifted value. *)
  let fee = 0.01 in
  let entry_e0 = 1. in
  let e1_1 = entry_e0 -. fee *. entry_e0 in
  let e1_2 = entry_e0 -. fee *. e1_1 in
  let e1_3 = entry_e0 -. fee *. e1_2 in
  let e1_4 = entry_e0 -. fee *. e1_3 in
  let entry_e1 = entry_e0 -. fee *. e1_4 in
  let entry_cost = fee *. entry_e1 in
  let entry_equity = entry_e0 -. entry_cost in
  let entry_cash = entry_equity -. entry_e1 in
  let exit_value =
    entry_e1 *. (126. /. 120.) *. (138.6 /. 126.) *. (145.53 /. 138.6)
  in
  let exit_cost = fee *. exit_value in
  entry_cash +. exit_value -. exit_cost
let golden_expected = 1.7291207425596153

let no_margin count : Engine.margin =
  { financing_rate = 0.; maintenance_override = Some 0.;
    ratios = Array.make count 1.; loan_term_months = None }

let tw_profile = Engine.profile_of_market "tw"
let us_profile = Engine.profile_of_market "us"


let run_single bars target costs ~capital ~fill =
  Engine.run ~profile:tw_profile [| ("tw/TEST", bars) |]
    { Engine.targets = [| target |] }
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

let test_inventory_split () =
  let bars =
    [| bar "2020-01-01" 100. 100.;
       bar "2020-01-02" 100. 100. |]
  in
  let margin : Engine.margin =
    { financing_rate = 0.; maintenance_override = Some 0.; ratios = [| 0.6 |];
      loan_term_months = None }
  in
  let result =
    Engine.run ~profile:tw_profile [| ("tw/TEST", bars) |]
      { Engine.targets = [| [| 2.; 2. |] |] }
      [| zero_costs |] ~margin ~capital:None ~fill:Engine.Close_same
  in
  (* E = 1, B = 2. Cash-funded x = (1 - 0.4 * 2) / 0.6 = 1/3;
     margin-funded m = 2 - 1/3 = 5/3; loan = 0.6 * 5/3 = 1.
     Maintenance = m / loan = 5/3. The force-close returns equity 1. *)
  assert_close ~tolerance:1e-12 1. (final_equity result);
  assert (result.margin_stats.Engine.refinances = 0);
  (match result.margin_stats.Engine.min_maintenance with
   | Some ratio -> assert_close ~tolerance:1e-12 (5. /. 3.) ratio
   | None -> assert false)

let test_maintenance_at_entry () =
  let bars =
    [| bar "2020-01-01" 100. 100.;
       bar "2020-01-02" 100. 100. |]
  in
  let margin : Engine.margin =
    { financing_rate = 0.; maintenance_override = Some 0.; ratios = [| 0.6 |];
      loan_term_months = None }
  in
  (* At 1.2x: x = 13/15, m = 1/3, loan = 0.2.
     At 2.0x: x = 1/3, m = 5/3, loan = 1.
     At 2.5x: x = 0, m = 2.5, loan = 1.5.
     Every entry therefore has maintenance m / loan = 5/3. *)
  List.iter
    (fun target ->
      let result =
        Engine.run ~profile:tw_profile [| ("tw/TEST", bars) |]
          { Engine.targets = [| [| target; target |] |] }
          [| zero_costs |] ~margin ~capital:None ~fill:Engine.Close_same
      in
      assert_close ~tolerance:1e-12 1. (final_equity result);
      (match result.margin_stats.Engine.min_maintenance with
       | Some ratio -> assert_close ~tolerance:1e-12 (5. /. 3.) ratio
       | None -> assert false))
    [1.2; 2.; 2.5]

let test_interest_liability () =
  let bars =
    [| bar "2020-01-03" 100. 100.;
       bar "2020-01-06" 100. 100.;
       bar "2020-01-07" 100. 100. |]
  in
  let margin : Engine.margin =
    { financing_rate = 0.0635; maintenance_override = Some 1.3;
      ratios = [| 0.6 |]; loan_term_months = None }
  in
  let result =
    Engine.run ~profile:tw_profile [| ("tw/TEST", bars) |]
      { Engine.targets = [| [| 2.; 2.; 2. |] |] }
      [| zero_costs |] ~margin ~capital:None ~fill:Engine.Close_same
  in
  (* The 2x split has cv = 1/3, mv = 5/3, and loan = 1. Its T+2
     settlement start is the final Tuesday bar. Monday is before that
     start. Tuesday's force-close tail is capped at the same final bar,
     so both accrued and tail day counts are zero and equity stays 1. *)
  (match result.equity_curve with
   | [_; (_, monday); (_, final)] ->
       assert_close ~tolerance:1e-12 1. monday;
       assert_close ~tolerance:1e-12 1. final
   | _ -> assert false);
  assert (result.margin_stats.Engine.margin_call_dates = []);
  assert (result.margin_stats.Engine.refinances = 0);
  (match result.margin_stats.Engine.min_maintenance with
   | Some ratio -> assert_close ~tolerance:1e-12 (5. /. 3.) ratio
   | None -> assert false)

let test_engine_initial_margin_clamp () =
  (* Requested 3x has need = 3 * 0.4 = 1.2, so it scales to 2.5x.
     That boundary entry is all margin: mv = 2.5, loan = 1.5,
     cash = 0, and maintenance = 2.5 / 1.5 = 5/3. *)
  let bars =
    [| bar "2020-01-01" 100. 100.;
       bar "2020-01-02" 100. 100. |]
  in
  let margin : Engine.margin =
    { financing_rate = 0.; maintenance_override = Some 0.; ratios = [| 0.6 |];
      loan_term_months = None }
  in
  let result =
    Engine.run ~profile:tw_profile [| ("tw/TEST", bars) |]
      { Engine.targets = [| [| 3.; 3. |] |] }
      [| zero_costs |] ~margin ~capital:None ~fill:Engine.Close_same
  in
  assert (result.margin_stats.Engine.clamps = 1);
  assert (result.margin_stats.Engine.margin_call_dates = []);
  (match result.fills with
   | first :: _ -> assert_close ~tolerance:1e-12 2.5 first.Engine.to_e
   | [] -> assert false);
  assert_close ~tolerance:1e-12 1. (final_equity result);
  (match result.margin_stats.Engine.min_maintenance with
   | Some ratio -> assert_close ~tolerance:1e-12 (5. /. 3.) ratio
   | None -> assert false)

let test_cap_reachable () =
  let bars =
    [| bar "2020-01-01" 100. 100.;
       bar "2020-01-02" 100. 100. |]
  in
  let margin : Engine.margin =
    { financing_rate = 0.; maintenance_override = Some 0.; ratios = [| 0.6 |];
      loan_term_months = None }
  in
  let result =
    Engine.run ~profile:tw_profile [| ("tw/TEST", bars) |]
      { Engine.targets = [| [| 2.5; 2.5 |] |] }
      [| zero_costs |] ~margin ~capital:None ~fill:Engine.Close_same
  in
  (* At the cap, x = max (0, (1 - 0.4 * 2.5) / 0.6) = 0.
     The full 2.5 position is margin inventory, its down payment is 1,
     and its loan is 1.5. Maintenance is 2.5 / 1.5 = 5/3. *)
  assert (result.margin_stats.Engine.clamps = 0);
  assert_close ~tolerance:1e-12 1. (final_equity result);
  (match result.margin_stats.Engine.min_maintenance with
   | Some ratio -> assert_close ~tolerance:1e-12 (5. /. 3.) ratio
   | None -> assert false)

let test_funding_clamp_covers_fixed_refinance_costs () =
  let bars =
    [| bar "2020-01-01" 100. 100.;
       bar "2020-01-02" 1. 1.;
       bar "2020-01-03" 1. 1. |]
  in
  let costs : Engine.costs =
    { fee_bps = 0.; tax_bps = 0.; slip_bps = 0.; min_fee = 50.;
      per_share_sell_fee = 0.; per_share_sell_cap = 0. }
  in
  let margin : Engine.margin =
    { financing_rate = 0.; maintenance_override = Some 0.; ratios = [| 0.6 |];
      loan_term_months = None }
  in
  let result =
    Engine.run ~profile:tw_profile [| ("tw/TEST", bars) |]
      { Engine.targets = [| [| 1.; 2.5; 2.5 |] |] }
      [| costs |] ~margin ~capital:(Some 10000.) ~fill:Engine.Close_same
  in
  (* Entry fee 0.005 leaves cash inventory 0.995. After the 99% loss,
     refinancing all 0.00995 would free only 0.00597 before two 0.005
     minimum fees, so no scale-in is fundable. The buy scales to zero,
     counts one clamp, and creates no refinance legs. Final close pays
     one 0.005 fee: 0.00995 - 0.005 = 0.00495. *)
  assert_close ~tolerance:1e-12 0.00495 (final_equity result);
  assert (result.margin_stats.Engine.clamps = 1);
  assert (result.margin_stats.Engine.refinances = 0);
  assert (List.length result.fills = 2)

let test_engine_mixed_ratio_clamp () =
  (* Need = 1.5 * 0.4 + 1.0 * 0.5 = 1.1, so k = 1/1.1.
     The clamped buys are 15/11 and 10/11. Their minimum down payments
     are 6/11 and 5/11, exactly all available cash, so both are margin
     inventory. Loans are 9/11 and 5/11; maintenance = (25/11) /
     (14/11) = 25/14. *)
  let flat price =
    [| bar "2020-01-01" price price; bar "2020-01-02" price price |]
  in
  let margin : Engine.margin =
    { financing_rate = 0.; maintenance_override = Some 0.;
      ratios = [| 0.6; 0.5 |]; loan_term_months = None }
  in
  let result =
    Engine.run ~profile:tw_profile [| ("tw/A", flat 100.); ("tw/B", flat 50.) |]
      { Engine.targets = [| [| 1.5; 1.5 |]; [| 1.; 1. |] |] }
      [| zero_costs; zero_costs |] ~margin ~capital:None
      ~fill:Engine.Close_same
  in
  assert (result.margin_stats.Engine.clamps = 1);
  assert (result.margin_stats.Engine.margin_call_dates = []);
  (match result.fills with
   | a :: b :: _ ->
       assert_close ~tolerance:1e-12 (1.5 /. 1.1) a.Engine.to_e;
       assert_close ~tolerance:1e-12 (1. /. 1.1) b.Engine.to_e
   | _ -> assert false);
  (match result.margin_stats.Engine.min_maintenance with
   | Some ratio -> assert_close ~tolerance:1e-12 (25. /. 14.) ratio
   | None -> assert false)

let test_forced_repayment_is_proportional () =
  let bars =
    [| bar "2020-01-01" 100. 100.;
       bar "2020-01-02" 55. 55.;
       bar "2020-01-02" 55. 55.;
       bar "2020-01-03" 55. 55. |]
  in
  let margin : Engine.margin =
    { financing_rate = 18.25; maintenance_override = Some 1.3;
      ratios = [| 0.6 |]; loan_term_months = None }
  in
  let result =
    Engine.run ~profile:tw_profile [| ("tw/TEST", bars) |]
      { Engine.targets = [| [| 2.; 2.; 2.; 2. |] |] }
      [| zero_costs |] ~margin ~capital:None ~fill:Engine.Close_same
  in
  (* At price 55, cv = 11/60 and mv = 11/12. The call repayment's
     T+2 start is its Jan 2 bar and its capped T+2 stop is Jan 3, so
     one day adds 1 * (18.25/365) = 1/20 interest. Sale proceeds
     11/12 settle 55/63 of total liabilities 21/20. The remaining
     2/15 becomes unsecured debt when the full margin exit clears its
     lots. No loan remains to accrue, so equity is 11/60 - 2/15 = 1/20. *)
  assert_close ~tolerance:1e-12 (1. /. 20.) (final_equity result)

let test_call_liquidates_margin_only () =
  let bars =
    [| bar "2020-01-01" 100. 100.;
       bar "2020-01-02" 75. 75.;
       bar "2020-01-03" 75. 75. |]
  in
  let margin : Engine.margin =
    { financing_rate = 0.; maintenance_override = Some 1.3; ratios = [| 0.6 |];
      loan_term_months = None }
  in
  let result =
    Engine.run ~profile:tw_profile [| ("tw/TEST", bars) |]
      { Engine.targets = [| [| 2.; 2.; 2. |] |] }
      [| zero_costs |] ~margin ~capital:None ~fill:Engine.Close_same
  in
  (* Entry has cv = 1/3, mv = 5/3, loan = 1. At 75, cv = 1/4 and
     mv = 5/4, so maintenance = 1.25 < 1.3 and equity = 0.5.
     The next-open call sells only mv, repays 1, and leaves cv = 0.25;
     its free final close preserves equity 0.5. *)
  assert_close ~tolerance:1e-12 0.5 (final_equity result);
  assert (List.length result.fills = 3);
  assert
    (result.margin_stats.Engine.margin_call_dates = ["2020-01-02"]);
  (match result.margin_stats.Engine.min_maintenance with
   | Some ratio -> assert_close ~tolerance:1e-12 1.25 ratio
   | None -> assert false)

let test_insolvent_call_sells_all_at_open () =
  let bars =
    [| bar "2020-01-01" 100. 100.;
       bar "2020-01-02" 75. 75.;
       bar "2020-01-03" 50. 50.;
       bar "2020-01-06" 50. 50. |]
  in
  let margin : Engine.margin =
    { financing_rate = 0.; maintenance_override = Some 1.3; ratios = [| 0.6 |];
      loan_term_months = None }
  in
  let result =
    Engine.run ~profile:tw_profile [| ("tw/TEST", bars) |]
      { Engine.targets = [| [| 2.; 2.; 2.; 2. |] |] }
      [| zero_costs |] ~margin ~capital:None ~fill:Engine.Close_same
  in
  (* The 75 close schedules a call. At the next open 50, cv = 1/6,
     mv = 5/6, loan = 1, and equity = 0. The call first sells mv;
     insolvency then sells cv at that same open and freezes. Nothing
     may remain for a later force-close. *)
  assert_close ~tolerance:1e-12 0. (final_equity result);
  assert
    (result.margin_stats.Engine.margin_call_dates = ["2020-01-02"]);
  (match result.fills with
   | [_; margin_sale; cash_sale] ->
       assert (margin_sale.Engine.date = "2020-01-03");
       assert (cash_sale.Engine.date = "2020-01-03")
   | _ -> assert false)

let test_engine_margin_call () =
  (* The 2.5x entry is all margin: mv = 2.5, loan = 1.5, cash = 0.
     Falling closes take maintenance from 5/3 to 2/1.5 and then
     1.9/1.5 = 1.2667, which schedules the margin-only liquidation. *)
  let bars =
    [| bar "2020-01-01" 100. 100.;
       bar "2020-01-02" 80. 80.;
       bar "2020-01-03" 76. 76.;
       bar "2020-01-06" 76. 90.;
       bar "2020-01-07" 90. 90. |]
  in
  let margin : Engine.margin =
    { financing_rate = 0.; maintenance_override = Some 1.3; ratios = [| 0.6 |];
      loan_term_months = None }
  in
  let result =
    Engine.run ~profile:tw_profile [| ("tw/TEST", bars) |]
      { Engine.targets = [| [| 2.5; 2.5; 2.5; 2.5; 1.0 |] |] }
      [| zero_costs |] ~margin ~capital:None ~fill:Engine.Close_same
  in
  (* At 76, equity is 1.9 - 1.5 = 0.4. The next-open liquidation
     sells all 1.9 of margin inventory and repays the 1.5 loan. The
     unchanged 2.5 target does not re-enter. On the last bar it changes
     to 1.0, so cash 0.4 buys 0.4 at 90 and the free final close returns
     the same equity. *)
  assert_close ~tolerance:1e-12 0.4 (final_equity result);
  assert (List.length result.fills = 4);
  assert
    (result.margin_stats.Engine.margin_call_dates = ["2020-01-03"]);
  (match result.margin_stats.Engine.min_maintenance with
   | Some ratio -> assert_close ~tolerance:1e-12 (1.9 /. 1.5) ratio
   | None -> assert false);
  (match result.trips with
   | [first; second] ->
       assert_close ~tolerance:1e-12 (76. /. 100. -. 1.) first.net_ret;
       assert_close ~tolerance:1e-12 0. second.net_ret
   | _ -> assert false)

let test_engine_bankruptcy () =
  (* The 2.5x entry is mv = 2.5, loan = 1.5, cash = 0. At 50,
     mv = 1.25, equity = -0.25, and maintenance = 1.25/1.5.
     Bankruptcy sells the inventory, pays 1.25 of the loan, leaves
     the 0.25 residual liability, and freezes at equity -0.25. *)
  let bars =
    [| bar "2020-01-01" 100. 100.;
       bar "2020-01-02" 50. 50.;
       bar "2020-01-03" 50. 60. |]
  in
  let margin : Engine.margin =
    { financing_rate = 0.; maintenance_override = Some 1.3; ratios = [| 0.6 |];
      loan_term_months = None }
  in
  let result =
    Engine.run ~profile:tw_profile [| ("tw/TEST", bars) |]
      { Engine.targets = [| [| 2.5; 2.5; 2.5 |] |] }
      [| zero_costs |] ~margin ~capital:None ~fill:Engine.Close_same
  in
  let last = final_equity result in
  assert (not (Float.is_nan last));
  assert_close ~tolerance:1e-12 (-0.25) last;
  assert (List.length result.fills = 2);
  assert
    (result.margin_stats.Engine.margin_call_dates = ["2020-01-02"]);
  (match result.margin_stats.Engine.min_maintenance with
   | Some ratio -> assert_close ~tolerance:1e-12 (1.25 /. 1.5) ratio
   | None -> assert false);
  (match result.trips with
   | [trip] -> assert_close ~tolerance:1e-12 (-0.5) trip.net_ret
   | _ -> assert false)

let test_open_next_bankruptcy_freezes_at_close () =
  let bars =
    [| bar "2020-01-01" 100. 100.;
       bar "2020-01-02" 100. 40.;
       bar "2020-01-03" 100. 100. |]
  in
  let margin : Engine.margin =
    { financing_rate = 0.; maintenance_override = Some 0.; ratios = [| 0.6 |];
      loan_term_months = None }
  in
  let result =
    Engine.run ~profile:tw_profile [| ("tw/TEST", bars) |]
      { Engine.targets = [| [| 2.5; 2.5; 2.5 |] |] }
      [| zero_costs |] ~margin ~capital:None ~fill:Engine.Open_next
  in
  (* The 2.5x entry fills at the second-bar open with mv = 2.5 and
     loan = 1.5. Its 40 close marks mv to 1.0 and equity to -0.5.
     The close-price guard sells mv for 1.0, leaves debt 0.5, and
     freezes before the next 100 open can resurrect the account. *)
  assert_float_array [| 1.; -0.5; -0.5 |]
    (Array.of_list (List.map snd result.equity_curve));
  assert (List.length result.fills = 2)

let test_engine_insolvent_gap () =
  (* Entry at 2x gives cv = 1/3, mv = 5/3, loan = 1, and cash = 0.
     At 50, cv = 1/6 and mv = 5/6, so equity is exactly 0 and
     maintenance is (5/6) / 1 = 5/6. The solvency guard sells both
     inventories, whose proceeds repay the loan exactly, then freezes. *)
  let bars =
    [| bar "2020-01-01" 100. 100.;
       bar "2020-01-02" 50. 50. |]
  in
  let margin : Engine.margin =
    { financing_rate = 0.; maintenance_override = Some 1.3; ratios = [| 0.6 |];
      loan_term_months = None }
  in
  let result =
    Engine.run ~profile:tw_profile [| ("tw/TEST", bars) |]
      { Engine.targets = [| [| 2.; 0. |] |] }
      [| zero_costs |] ~margin ~capital:None ~fill:Engine.Close_same
  in
  let last = final_equity result in
  assert (not (Float.is_nan last));
  assert_close ~tolerance:1e-12 0. last;
  assert (List.length result.fills = 2);
  assert
    (result.margin_stats.Engine.margin_call_dates = ["2020-01-02"]);
  (match result.margin_stats.Engine.min_maintenance with
   | Some ratio -> assert_close ~tolerance:1e-12 (5. /. 6.) ratio
   | None -> assert false);
  (match result.trips with
   | [trip] -> assert_close ~tolerance:1e-12 (-0.5) trip.net_ret
   | _ -> assert false)

let test_engine_insolvent_min_fee () =
  let bars =
    [| bar "2020-01-01" 100. 100.;
       bar "2020-01-02" 50. 50. |]
  in
  let costs : Engine.costs =
    { fee_bps = 3.99; tax_bps = 0.; slip_bps = 0.; min_fee = 20.;
      per_share_sell_fee = 0.; per_share_sell_cap = 0. }
  in
  let margin : Engine.margin =
    { financing_rate = 0.; maintenance_override = Some 1.3; ratios = [| 0.6 |];
      loan_term_months = None }
  in
  let result =
    Engine.run ~profile:tw_profile [| ("tw/TEST", bars) |]
      { Engine.targets = [| [| 2.; 0. |] |] }
      [| costs |] ~margin ~capital:(Some 10000.) ~fill:Engine.Close_same
  in
  (* Entry fee 0.002 gives E1 = 0.998. The 2x split is cv = E1/3,
     mv = 5*E1/3, loan = E1, cash = 0. At 50, total value and loan
     both equal E1, so equity is 0 and maintenance is (5*E1/6)/E1
     = 5/6. Liquidation costs another 0.002; proceeds pay all but
     0.002 of the loan, leaving that residual liability and cash 0. *)
  let entry_fee = 20. /. 10000. in
  let entry_e1 = 1. -. entry_fee in
  let entry_value = 2. *. entry_e1 in
  let loan = entry_e1 in
  let exit_value = entry_value /. 2. in
  let exit_margin = 5. *. entry_e1 /. 6. in
  let exit_fee =
    Float.max (exit_value *. 3.99 /. 10000.) (20. /. 10000.)
  in
  let residual_loan = loan -. (exit_value -. exit_fee) in
  let last = final_equity result in
  assert (not (Float.is_nan last));
  assert_close ~tolerance:1e-12 (-. residual_loan) last;
  assert
    (result.margin_stats.Engine.margin_call_dates = ["2020-01-02"]);
  (match result.margin_stats.Engine.min_maintenance with
   | Some ratio ->
       assert_close ~tolerance:1e-12 (exit_margin /. loan) ratio
   | None -> assert false)

let test_engine_exit_fee_bankruptcy () =
  let bars =
    [| bar "2020-01-01" 100. 100.;
       bar "2020-01-02" 50.05 50.05;
       bar "2020-01-03" 50.05 50.05 |]
  in
  let costs : Engine.costs =
    { fee_bps = 3.99; tax_bps = 0.; slip_bps = 0.; min_fee = 20.;
      per_share_sell_fee = 0.; per_share_sell_cap = 0. }
  in
  let margin : Engine.margin =
    { financing_rate = 0.; maintenance_override = Some 0.; ratios = [| 0.6 |];
      loan_term_months = None }
  in
  let result =
    Engine.run ~profile:tw_profile [| ("tw/TEST", bars) |]
      { Engine.targets = [| [| 2.; 0.; 1. |] |] }
      [| costs |] ~margin ~capital:(Some 10000.) ~fill:Engine.Close_same
  in
  (* Entry E1 = 0.998 gives cv = E1/3, mv = 5*E1/3, loan = E1,
     and cash = 0. At 50.05, total value is 2*E1*0.5005 and pre-fill
     equity is 0.000998. The 0.002 exit fee exceeds all remaining
     equity by 0.001002; cash stays 0, account debt carries the
     deficit, and the next target is never sized. *)
  let entry_fee = 20. /. 10000. in
  let entry_e1 = 1. -. entry_fee in
  let loan = entry_e1 in
  let exit_value = 2. *. entry_e1 *. 0.5005 in
  let exit_fee =
    Float.max (exit_value *. 3.99 /. 10000.) (20. /. 10000.)
  in
  let residual_debt = loan -. (exit_value -. exit_fee) in
  assert_close ~tolerance:1e-12
    (-. residual_debt) (final_equity result);
  assert (List.length result.fills = 2);
  assert (result.margin_stats.Engine.clamps = 0)

let test_engine_zero_value_exit_preserves_liability () =
  let cash_asset =
    [| bar "2020-01-01" 100. 100.;
       bar "2020-01-02" 200. 200.;
       bar "2020-01-03" 200. 200. |]
  in
  let financed_asset =
    [| bar "2020-01-01" 100. 100.;
       bar "2020-01-02" 0. 0.;
       bar "2020-01-03" 0. 0. |]
  in
  let margin : Engine.margin =
    { financing_rate = 0.365; maintenance_override = Some 0.;
      ratios = [| 0.6; 0.6 |]; loan_term_months = None }
  in
  let result =
    Engine.run ~profile:tw_profile
      [| ("tw/CASH", cash_asset); ("tw/MARGIN", financed_asset) |]
      { Engine.targets =
          [| [| 1.; 1.; 1. |]; [| 1.5; 0.; 0. |] |] }
      [| zero_costs; zero_costs |] ~margin ~capital:None
      ~fill:Engine.Close_same
  in
  (* The 2.5 gross entry is exactly at the cap, so both assets are
     margin inventory: values 1 and 1.5, loans 0.6 and 0.9, cash 0.
     On day 2 the first value doubles and the second becomes worthless.
     A zero-value target change has no proceeds, so the 0.9 loan
     survives until final settlement. Both bar-0 loans start interest
     at T+2 on the final day; the final repayment is capped there too,
     so interest is zero. Price PnL is -0.5 and final equity is 0.5.
     Maintenance falls from 2.5/1.5 to 2/1.5 = 4/3. *)
  assert_close ~tolerance:1e-12 0.5 (final_equity result);
  assert (result.margin_stats.Engine.refinances = 0);
  (match result.margin_stats.Engine.min_maintenance with
   | Some ratio -> assert_close ~tolerance:1e-12 (4. /. 3.) ratio
   | None -> assert false)

let dividend ex_date cash_per_share pay_date : Data.dividend =
  { ex_date; cash_per_share; pay_date }

let run_with_dividends ~stock bars target costs margin dividends dividend_tax =
  let market = String.sub stock 0 (String.index stock '/') in
  let profile = Engine.profile_of_market market in
  Engine.run ~dividends:[| dividends |] ~dividend_tax ~profile
    [| (stock, bars) |] { Engine.targets = [| target |] }
    [| costs |] ~margin ~capital:None ~fill:Engine.Close_same

let test_tw_dividend_receivable () =
  let bars =
    [| bar "2020-01-01" 100. 100.;
       bar "2020-01-02" 90. 90.;
       bar "2020-01-03" 90. 90.;
       bar "2020-01-04" 90. 90. |]
  in
  let margin : Engine.margin =
    { financing_rate = 0.; maintenance_override = Some 0.; ratios = [| 0.6 |];
      loan_term_months = None }
  in
  let result =
    run_with_dividends ~stock:"tw/TEST" bars
      [| 2.; 2.; 2.; 2. |] zero_costs margin
      [| dividend "2020-01-02" 10. "2020-02-01" |] 0.
  in
  (* Entry has cash inventory 1/3, margin inventory 5/3, and loan 1.
     The 10% ex-date drop makes them 3/10 and 3/2. Their 1/50 shares
     book a 1/5 receivable, so equity remains 3/10 + 3/2 - 1 + 1/5
     = 1 on every bar, including the final force-close. *)
  assert_float_array [| 1.; 1.; 1.; 1. |]
    (Array.of_list (List.map snd result.equity_curve));
  (* Receivables are not collateral: maintenance falls from 5/3 at
     entry to (3/2) / 1 = 3/2 between the ex-date and pay date. *)
  match result.margin_stats.Engine.min_maintenance with
  | Some ratio -> assert_close ~tolerance:1e-12 (3. /. 2.) ratio
  | None -> assert false

let test_tw_dividend_paydown_interest () =
  let bars =
    [| bar "2020-01-01" 100. 100.;
       bar "2020-01-02" 100. 100.;
       bar "2020-01-03" 100. 100.;
       bar "2020-01-04" 100. 100.;
       bar "2020-01-05" 100. 100. |]
  in
  let margin : Engine.margin =
    { financing_rate = 3.65; maintenance_override = Some 0.; ratios = [| 0.6 |];
      loan_term_months = None }
  in
  let result =
    run_with_dividends ~stock:"tw/TEST" bars
      [| 2.; 2.; 2.; 4. /. 3.; 4. /. 3. |] zero_costs margin
      [| dividend "2020-01-02" 25.5 "2020-01-04" |] 0.
  in
  (* The 2x entry has cash shares 1/300 and margin shares 1/60.
     The dividend creates 17/200 cash and 17/40 margin receivables.
     One interest day makes the lot due 101/100 on the pay date, so
     the 17/40 payment leaves fraction 117/202 of both its principal
     and 1/100 accrued interest. One later day adds principal/100.
     Target 4/3 exactly matches inventory 2 / equity 3/2 at payment. *)
  let remaining = 117. /. 202. in
  let expected =
    17. /. 200. +. 2.
    -. remaining -. (remaining /. 100.) -. (remaining /. 100.)
  in
  assert_close ~tolerance:1e-12 expected (final_equity result)

let test_tw_dividend_pure_paydown_preserves_drift () =
  let bars =
    [| bar "2020-01-01" 100. 100.;
       bar "2020-01-02" 100. 100.;
       bar "2020-01-03" 120. 120.;
       bar "2020-01-04" 120. 120. |]
  in
  let margin : Engine.margin =
    { financing_rate = 0.; maintenance_override = Some 0.; ratios = [| 0.6 |];
      loan_term_months = None }
  in
  let result =
    run_with_dividends ~stock:"tw/TEST" bars
      [| 2.5; 2.5; 2.5; 2.5 |] zero_costs margin
      [| dividend "2020-01-02" 20. "2020-01-03" |] 0.
  in
  (* Entry owns 1/40 margin-funded share. Its 20-per-share dividend is
     1/2, below the 3/2 loan, so payment reduces the loan to 1 and puts
     no cash in the planner. The pay date therefore records no fill. *)
  assert
    (not
       (List.exists
          (fun fill -> fill.Engine.date = "2020-01-03")
          result.fills));
  (* The price drift raises inventory from 5/2 to 3. With the loan now
     1, final equity is 3 - 1 = 2. *)
  assert_close ~tolerance:1e-12 2. (final_equity result);
  (* With no pay-date rebalance, the final close starts from the drifted
     exposure 3 / 2 rather than the requested 5 / 2. *)
  match result.fills with
  | [_entry; close] ->
      assert_close ~tolerance:1e-12 (3. /. 2.) close.Engine.from_e
  | _ -> assert false

let test_tw_dividend_excess_spill () =
  let bars =
    [| bar "2020-01-01" 100. 100.;
       bar "2020-01-02" 100. 100.;
       bar "2020-01-03" 100. 100.;
       bar "2020-01-04" 100. 100. |]
  in
  let margin : Engine.margin =
    { financing_rate = 0.; maintenance_override = Some 0.; ratios = [| 0.6 |];
      loan_term_months = None }
  in
  let result =
    run_with_dividends ~stock:"tw/TEST" bars
      [| 2.5; 2.5; 2.5; 2.5 |] zero_costs margin
      [| dividend "2020-01-02" 100. "2020-01-03" |] 0.
  in
  (* The 2.5x entry is all margin inventory with 1.5 debt and 1/40
     shares. Its 5/2 dividend clears the 3/2 loan and spills 1 to
     cash. Flat prices and zero costs preserve equity 1 + 5/2 = 7/2
     through the pay-date re-fill and final close. *)
  assert_close ~tolerance:1e-12 (7. /. 2.) (final_equity result);
  (* The 5/2 margin receipt exceeds the 3/2 loan by 1. That spill
     reaches cash, so the planner must record a pay-date re-fill. *)
  assert
    (List.exists
       (fun fill -> fill.Engine.date = "2020-01-03")
       result.fills)

let test_us_dividend_refill_cost () =
  let bars =
    [| bar "2020-01-01" 100. 100.;
       bar "2020-01-02" 100. 100.;
       bar "2020-01-03" 100. 100. |]
  in
  let costs : Engine.costs =
    { fee_bps = 100.; tax_bps = 0.; slip_bps = 0.; min_fee = 0.;
      per_share_sell_fee = 0.; per_share_sell_cap = 0. }
  in
  let result =
    run_with_dividends ~stock:"us/TEST" bars
      [| 1.; 1.; 1. |] costs (no_margin 1)
      [| dividend "2020-01-02" 10. "2020-01-02" |] 0.
  in
  (* Entry inventory is 1/1.01. The ex-date cash credit is 1/10 of
     it. Re-fill equity x solves x = 110/101 - 0.01(x - 100/101),
     hence x = 11100/10201. The final 1% sale leaves 10989/10201. *)
  assert_close ~tolerance:1e-12 (10989. /. 10201.)
    (final_equity result);
  (* One entry, one dividend-triggered re-fill, and one final close. *)
  assert (List.length result.fills = 3)

let test_dividend_tax () =
  let bars =
    [| bar "2020-01-01" 100. 100.;
       bar "2020-01-02" 100. 100.;
       bar "2020-01-03" 100. 100. |]
  in
  let result =
    run_with_dividends ~stock:"us/TEST" bars
      [| 1.; 1.; 1. |] zero_costs (no_margin 1)
      [| dividend "2020-01-02" 10. "2020-01-02" |] 0.25
  in
  (* One share-equivalent position receives 0.1 gross. A 25% tax
     leaves 0.075, so zero-cost re-fill and close end at 1.075. *)
  assert_close ~tolerance:1e-12 1.075 (final_equity result)

let test_frozen_dividend_reduces_debt () =
  let bars =
    [| bar "2020-01-01" 100. 100.;
       bar "2020-01-02" 40. 40.;
       bar "2020-01-03" 40. 40.;
       bar "2020-01-04" 40. 40. |]
  in
  let margin : Engine.margin =
    { financing_rate = 0.; maintenance_override = Some 0.; ratios = [| 0.6 |];
      loan_term_months = None }
  in
  let result =
    run_with_dividends ~stock:"tw/TEST" bars
      [| 2.5; 2.5; 2.5; 2.5 |] zero_costs margin
      [| dividend "2020-01-02" 10. "2020-01-03" |] 0.
  in
  (* The ex-date value is 1 against a 1.5 loan. Its 1/40 shares book
     1/4, so liquidation freezes at 1 + 1/4 - 3/2 = -1/4. On pay
     date the receivable removes 1/4 of residual debt; the asset and
     liability fall together, so frozen equity stays -1/4 thereafter. *)
  assert_float_array [| 1.; -0.25; -0.25; -0.25 |]
    (Array.of_list (List.map snd result.equity_curve));
  (* Bankruptcy performs the entry and liquidation only; it never
     re-enters when the frozen receivable converts. *)
  assert (List.length result.fills = 2)

let test_no_dividend_events_identity () =
  let bars =
    [| bar "2020-01-01" 100. 100.;
       bar "2020-01-02" 105. 110.;
       bar "2020-01-03" 115. 121. |]
  in
  let target = [| 0.5; 0.5; 0.5 |] in
  let without_events =
    Engine.run ~profile:tw_profile ~dividend_tax:0.
      [| ("tw/TEST", bars) |] { Engine.targets = [| target |] }
      [| zero_costs |] ~margin:(no_margin 1) ~capital:None
      ~fill:Engine.Close_same
  in
  let with_empty_events =
    Engine.run ~profile:tw_profile ~dividends:[| [||] |] ~dividend_tax:0.
      [| ("tw/TEST", bars) |] { Engine.targets = [| target |] }
      [| zero_costs |] ~margin:(no_margin 1) ~capital:None
      ~fill:Engine.Close_same
  in
  (* Empty dividend input executes the identical floating-point path,
     so every dated equity value must be structurally equal. *)
  assert (with_empty_events.equity_curve = without_events.equity_curve)

let test_receivable_not_duplicated_on_force_close () =
  let bars =
    [| bar "2020-01-01" 100. 100.;
       bar "2020-01-02" 90. 90. |]
  in
  let result =
    run_with_dividends ~stock:"tw/TEST" bars [| 1.; 1. |]
      zero_costs (no_margin 1)
      [| dividend "2020-01-02" 10. "2020-02-01" |] 0.
  in
  (* The ex-date position is worth 0.9 and owns 1/100 share, so its
     unpaid receivable is 0.1. Final force-close converts only the
     0.9 inventory to cash; cash plus receivable must remain 1.0. *)
  assert_close ~tolerance:1e-12 1. (final_equity result)

let test_receivable_not_available_to_planner () =
  let bars =
    [| bar "2020-01-01" 100. 100.;
       bar "2020-01-02" 100. 100.;
       bar "2020-01-03" 100. 100. |]
  in
  let result =
    run_with_dividends ~stock:"tw/TEST" bars
      [| 0.96; 1.; 1. |] zero_costs (no_margin 1)
      [| dividend "2020-01-02" 6.25 "2020-02-01" |] 0.
  in
  (* Entry leaves 0.04 cash. Its 0.0096 shares book a 0.06
     receivable, raising equity to 1.06. Gross target 1 may not
     borrow, so only the real 0.04 cash is invested. Inventory
     reaches 1.00, or exposure 1/1.06 = 50/53; the receivable must
     not masquerade as the missing 0.06 cash allocation. *)
  match result.fills with
  | _entry :: refill :: _ ->
      assert_close ~tolerance:1e-12 (50. /. 53.) refill.Engine.to_e
  | _ -> assert false

let test_unlevered_dividend_refill_cash_clamp () =
  (* Normalize the first loan-producing 0050 bar to a 100 entry:
     equity 2.6776256532099918, cash 0.06010600669768993, requested
     buy 0.060082033966137427, and a 6.94e-18 margin residual. *)
  let pay_price = 261.85640368512605 in
  let cash_per_share = 6.012998899436231 in
  let bars =
    [| bar "2020-01-01" 100. 100.;
       bar "2020-01-02" pay_price pay_price;
       bar "2020-01-03" pay_price pay_price;
       bar "2020-01-04" pay_price pay_price |]
  in
  let costs : Engine.costs =
    { fee_bps = 3.99; tax_bps = 0.; slip_bps = 0.; min_fee = 0.;
      per_share_sell_fee = 0.; per_share_sell_cap = 0. }
  in
  let margin : Engine.margin =
    { financing_rate = 0.; maintenance_override = Some 0.; ratios = [| 0.6 |];
      loan_term_months = None }
  in
  let result =
    run_with_dividends ~stock:"tw/TEST" bars
      [| 1.; 1.; 1.; 1. |] costs margin
      [| dividend "2020-01-02" cash_per_share "2020-01-03" |] 0.
  in
  let fee = 3.99 /. 10000. in
  let entry = 1. /. (1. +. fee) in
  let dividend_cash = entry /. 100. *. cash_per_share in
  let inventory = entry /. 100. *. pay_price in
  let refill = dividend_cash /. (1. +. fee) in
  (* Entry owns entry/100 shares. At the pay price, inventory is
     entry*pay_price/100 and the dividend is
     entry*cash_per_share/100. The pay-date buy plus its fee must
     equal that cash, so buy = dividend/(1+f). The final sale leaves
     (inventory + buy)(1-f), with no refinance-leg fees. *)
  assert_close ~tolerance:1e-12
    ((inventory +. refill) *. (1. -. fee))
    (final_equity result);
  (* Requested gross exposure is exactly 1, so the fee-sized funding
     gap is a normal cash sizing clamp: it creates no refinance and
     does not increment the margin clamp statistic. *)
  assert (result.margin_stats.Engine.refinances = 0);
  assert (result.margin_stats.Engine.clamps = 0);
  (* With no loan at any point, maintenance is never defined. *)
  assert (result.margin_stats.Engine.min_maintenance = None);
  (* Before the pay-date fill, inventory plus the receivable is total
     equity. Cash-sized re-fill reaches exposure 1, then final-close
     is third. *)
  match result.fills with
  | [_entry; pay_refill; _close] ->
      assert_close ~tolerance:1e-12
        (inventory /. (inventory +. dividend_cash))
        pay_refill.Engine.from_e;
      assert_close ~tolerance:1e-12 1. pay_refill.Engine.to_e
  | _ -> assert false

let test_intersected_ex_date () =
  let bars =
    [| bar "2020-01-01" 100. 100.;
       bar "2020-01-03" 90. 90.;
       bar "2020-01-04" 90. 90. |]
  in
  let result =
    run_with_dividends ~stock:"tw/TEST" bars
      [| 1.; 1.; 1. |] zero_costs (no_margin 1)
      [| dividend "2020-01-02" 10. "2020-01-02" |] 0.
  in
  (* The omitted Jan 2 bar lies between retained Jan 1 and Jan 3.
     The Jan 3 inventory still represents 1/100 share, so booking
     and immediately settling 0.1 restores the 0.9 inventory to
     equity 1 and triggers one re-fill before the final close. *)
  assert_close ~tolerance:1e-12 1. (final_equity result);
  (* Entry, intersected-date re-fill, and final force-close. *)
  assert (List.length result.fills = 3);
  let before_range =
    run_with_dividends ~stock:"tw/TEST" bars
      [| 1.; 1.; 1. |] zero_costs (no_margin 1)
      [| dividend "2019-12-31" 10. "2019-12-31" |] 0.
  in
  (* An event before the first retained bar has no pre-run holdings.
     It is discarded, so only the 100-to-90 price return remains. *)
  assert_close ~tolerance:1e-12 0.9 (final_equity before_range)


let test_engine_buyhold_costs () =
  (* Entry solves E1 = E0 - fee * E1, so E1 = E0 / (1 + fee).
     The last close force-closes the position. *)
  let bars =
    [| bar "2020-01-01" 100. 100.; bar "2020-01-02" 100. 110. |]
  in
  let costs : Engine.costs =
    { fee_bps = 100.; tax_bps = 0.; slip_bps = 0.; min_fee = 0.;
      per_share_sell_fee = 0.; per_share_sell_cap = 0. }
  in
  let result =
    run_single bars [| 1.; 1. |] costs ~capital:None ~fill:Engine.Close_same
  in
  let fee = 0.01 in
  let entry_e0 = 1. in
  let entry_e1 = entry_e0 /. (1. +. fee) in
  let entry_cost = fee *. entry_e1 in
  let entry_equity = entry_e0 -. entry_cost in
  let entry_cash = entry_equity -. entry_e1 in
  let exit_value = entry_e1 *. 1.1 in
  let exit_cost = fee *. exit_value in
  let expected = entry_cash +. exit_value -. exit_cost in
  assert_close ~tolerance:1e-15 expected (final_equity result)

let test_exact_cash_funding () =
  let flat price =
    [| bar "2020-01-01" price price;
       bar "2020-01-02" price price |]
  in
  let margin : Engine.margin =
    { financing_rate = 0.; maintenance_override = Some 0.;
      ratios = [| 0.6; 0.6 |]; loan_term_months = None }
  in
  let result =
    Engine.run ~profile:tw_profile [| ("tw/A", flat 100.); ("tw/B", flat 50.) |]
      { Engine.targets = [| [| 0.01; 0.01 |]; [| 0.04; 0.04 |] |] }
      [| zero_costs; zero_costs |] ~margin ~capital:None
      ~fill:Engine.Close_same
  in
  (* Available cash exceeds both buys. Assigning each full financing
     capacity directly must leave exact cash inventory and no ulp loan. *)
  assert_close ~tolerance:1e-15 1. (final_equity result);
  assert (result.margin_stats.Engine.min_maintenance = None);
  assert (result.margin_stats.Engine.refinances = 0)

let test_engine_no_borrow_stats () =
  let bars =
    [| bar "2020-01-01" 100. 100.; bar "2020-01-02" 100. 110. |]
  in
  let result =
    run_single bars [| 1.; 1. |] zero_costs
      ~capital:None ~fill:Engine.Close_same
  in
  assert (result.margin_stats.Engine.min_maintenance = None);
  assert (result.margin_stats.Engine.margin_call_dates = []);
  assert (result.margin_stats.Engine.refinances = 0);
  assert (result.margin_stats.Engine.clamps = 0)

let test_engine () =
  let target = [|0.; 1.; 1.; 1.; 1.|] in
  let zero_result =
    run_single sample_bars target zero_costs ~capital:None ~fill:Engine.Open_next
  in
  assert_close ~tolerance:1e-12 engine_zero_expected (final_equity zero_result);
  let fee_costs : Engine.costs =
    { fee_bps = 100.; tax_bps = 0.; slip_bps = 0.; min_fee = 0.;
      per_share_sell_fee = 0.; per_share_sell_cap = 0. }
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
    { fee_bps = 100.; tax_bps = 0.; slip_bps = 0.; min_fee = 0.;
      per_share_sell_fee = 0.; per_share_sell_cap = 0. }
  in
  let result =
    run_single fill_bars target costs ~capital:None ~fill:Engine.Close_same
  in
  (match result.fills with
   | entry :: _ ->
       assert_close ~tolerance:1e-12 1. entry.Engine.to_e
   | [] -> assert false);
  (* Entry solves E1 = 1 - fee * E1. The position then drifts to
     112/104 of its entry value, and liquidation costs 1% of that value. *)
  let fee = 0.01 in
  let entry_e0 = 1. in
  let entry_e1 = entry_e0 /. (1. +. fee) in
  let entry_value = entry_e1 in
  let entry_cash = entry_e1 -. entry_value in
  let exit_value = entry_value *. (112. /. 104.) in
  let exit_cost = fee *. exit_value in
  let expected = entry_cash +. exit_value -. exit_cost in
  assert_close ~tolerance:1e-12 expected (final_equity result)

let test_engine_min_fee () =
  let target = [| 0.; 1.; 1.; 0.; 0. |] in
  let costs : Engine.costs =
    { fee_bps = 3.99; tax_bps = 0.; slip_bps = 0.; min_fee = 20.;
      per_share_sell_fee = 0.; per_share_sell_cap = 0. }
  in
  let result =
    run_single fill_bars target costs
      ~capital:(Some 10000.) ~fill:Engine.Close_same
  in
  (* The 0.002 minimum fee dominates on both sides. Entry therefore
     solves E1 = E0 - 0.002 in one pass; the exit subtracts another
     fixed 0.002 from the drifted value. *)
  let entry_e0 = 1. in
  let entry_fee = 20. /. 10000. in
  let entry_e1 = entry_e0 -. entry_fee in
  let entry_value = entry_e1 in
  let entry_cash = entry_e1 -. entry_value in
  let exit_value = entry_value *. (112. /. 104.) in
  let exit_fee =
    Float.max (exit_value *. 3.99 /. 10000.) (20. /. 10000.)
  in
  let expected = entry_cash +. exit_value -. exit_fee in
  assert_close ~tolerance:1e-12 expected (final_equity result)

let test_engine_min_fee_without_capital () =
  let target = [| 0.; 1.; 1.; 0.; 0. |] in
  let costs : Engine.costs =
    { fee_bps = 3.99; tax_bps = 0.; slip_bps = 0.; min_fee = 20.;
      per_share_sell_fee = 0.; per_share_sell_cap = 0. }
  in
  let result =
    run_single fill_bars target costs ~capital:None ~fill:Engine.Close_same
  in
  (* Without capital, no minimum applies. Entry solves
     E1 = E0 - fee * E1; exit costs fee * drifted_value. *)
  let fee = 3.99 /. 10000. in
  let entry_e0 = 1. in
  let entry_e1 = entry_e0 /. (1. +. fee) in
  let entry_value = entry_e1 in
  let entry_cash = entry_e1 -. entry_value in
  let exit_value = entry_value *. (112. /. 104.) in
  let exit_cost = fee *. exit_value in
  let expected = entry_cash +. exit_value -. exit_cost in
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
    { fee_bps = 100.; tax_bps = 0.; slip_bps = 0.; min_fee = 0.;
      per_share_sell_fee = 0.; per_share_sell_cap = 0. }
  in
  let result =
    run_single fill_bars target costs ~capital:None ~fill:Engine.Close_same
  in
  (* Entry: E1 = 1 - fee * (0.5 * E1).
     Scale-in: E1 = E0 - fee * (E1 - old_value).
     Scale-out: E1 = E0 - fee * (old_value - 0.5 * E1).
     Final exit subtracts fee * drifted_value. *)
  let fee = 0.01 in
  let entry_e1 = 1. /. (1. +. 0.5 *. fee) in
  let entry_value = 0.5 *. entry_e1 in
  let entry_cash = entry_e1 -. entry_value in
  let scale_value_before = entry_value *. (108. /. 104.) in
  let scale_e0 = entry_cash +. scale_value_before in
  let scale_e1 =
    (scale_e0 +. fee *. scale_value_before) /. (1. +. fee)
  in
  let trim_value_before = scale_e1 *. (112. /. 108.) in
  let trim_e0 = trim_value_before in
  let trim_e1 =
    (trim_e0 -. fee *. trim_value_before) /. (1. -. 0.5 *. fee)
  in
  let trim_value = 0.5 *. trim_e1 in
  let trim_cash = trim_e1 -. trim_value in
  let exit_value = trim_value *. (116. /. 112.) in
  let exit_e0 = trim_cash +. exit_value in
  let expected = exit_e0 -. fee *. exit_value in
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
    { fee_bps = 100.; tax_bps = 0.; slip_bps = 0.; min_fee = 0.;
      per_share_sell_fee = 0.; per_share_sell_cap = 0. }
  in
  let result =
    run_single fill_bars target costs ~capital:None ~fill:Engine.Open_next
  in
  (* The same E1 equations apply at opens 106, 110, and 114.
     The position drifts between fill opens; the last close force-closes. *)
  let fee = 0.01 in
  let entry_e1 = 1. /. (1. +. 0.5 *. fee) in
  let entry_cash = 0.5 *. entry_e1 in
  let scale_value_before = 0.5 *. entry_e1 *. (110. /. 106.) in
  let scale_e0 = entry_cash +. scale_value_before in
  let scale_e1 =
    (scale_e0 +. fee *. scale_value_before) /. (1. +. fee)
  in
  let trim_value_before = scale_e1 *. (114. /. 110.) in
  let trim_e0 = trim_value_before in
  let trim_e1 =
    (trim_e0 -. fee *. trim_value_before) /. (1. -. 0.5 *. fee)
  in
  let trim_value = 0.5 *. trim_e1 in
  let trim_cash = trim_e1 -. trim_value in
  let exit_value = trim_value *. (116. /. 114.) in
  let exit_e0 = trim_cash +. exit_value in
  let expected = exit_e0 -. fee *. exit_value in
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
    Engine.run ~profile:tw_profile [| ("tw/A", a); ("tw/B", b) |] strategy
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
    { fee_bps = 100.; tax_bps = 0.; slip_bps = 0.; min_fee = 0.;
      per_share_sell_fee = 0.; per_share_sell_cap = 0. }
  in
  let b_costs : Engine.costs =
    { fee_bps = 0.; tax_bps = 100.; slip_bps = 0.; min_fee = 0.;
      per_share_sell_fee = 0.; per_share_sell_cap = 0. }
  in
  let result =
    Engine.run ~profile:tw_profile [| ("tw/A", a); ("tw/B", b) |]
      { Engine.targets =
          [| [| 0.5; 0.5; 0. |]; [| 0.; 0.4; 0. |] |] }
      [| a_costs; b_costs |] ~margin:(no_margin 2)
      ~capital:None ~fill:Engine.Close_same
  in
  (* A entry solves E1 = 1 - fee * (0.5 * E1). On day 2 only
     B's target changes, so drifted A is not rebalanced; B's buy is free
     and equals 0.4 * E1. Both day-3 exits cost 1% of drifted value. *)
  let fee = 0.01 in
  let entry_e1 = 1. /. (1. +. 0.5 *. fee) in
  let a_entry_value = 0.5 *. entry_e1 in
  let entry_cash = entry_e1 -. a_entry_value in
  let a_day_two_value = a_entry_value *. 1.1 in
  let b_entry_e0 = entry_cash +. a_day_two_value in
  let b_entry_e1 = b_entry_e0 in
  let b_day_two_value = 0.4 *. b_entry_e1 in
  let day_two_cash =
    b_entry_e1 -. a_day_two_value -. b_day_two_value
  in
  let a_exit_value = a_day_two_value *. (121. /. 110.) in
  let b_exit_value = b_day_two_value *. (54. /. 45.) in
  let exit_e0 = day_two_cash +. a_exit_value +. b_exit_value in
  let expected =
    exit_e0 -. fee *. a_exit_value -. fee *. b_exit_value
  in
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
    { fee_bps = 3.99; tax_bps = 0.; slip_bps = 0.; min_fee = 20.;
      per_share_sell_fee = 0.; per_share_sell_cap = 0. }
  in
  let result =
    Engine.run ~profile:tw_profile [| ("tw/A", a); ("tw/B", b) |]
      { Engine.targets =
          [| [| 0.5; 0. |]; [| 0.5; 0. |] |] }
      [| costs; costs |] ~margin:(no_margin 2)
      ~capital:(Some 10000.) ~fill:Engine.Close_same
  in
  (* Two fixed 0.002 entry fees give E1 = 1 - 0.004. Each target is
     0.5 * E1, so cash is zero. Two fixed exit fees give final
     equity E1 - 0.004. *)
  let fee = 20. /. 10000. in
  let entry_e0 = 1. in
  let entry_e1 = entry_e0 -. fee -. fee in
  let a_value = 0.5 *. entry_e1 in
  let b_value = 0.5 *. entry_e1 in
  let entry_cash = entry_e1 -. a_value -. b_value in
  let exit_e0 = entry_cash +. a_value +. b_value in
  let expected = exit_e0 -. fee -. fee in
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
    Engine.run ~profile:tw_profile [| ("tw/A", a); ("tw/B", b) |] strategy
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
        Engine.run ~profile:tw_profile [| ("tw/TEST", dsl_bars) |] strategy [| zero_costs |]
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
    { fee_bps = 0.; tax_bps = 0.; slip_bps = 0.; min_fee = 0.;
      per_share_sell_fee = 0.; per_share_sell_cap = 0. }
  in
  let result =
    Engine.run ~profile:tw_profile [| ("tw/TEST", bars) |] strategy [| costs |]
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
        Engine.run ~profile:tw_profile [| ("tw/TEST", bars) |] sma [| zero_costs |]
          ~margin:(no_margin 1) ~capital:None ~fill:Engine.Open_next
      in
      let buy_hold_result =
        Engine.run ~profile:tw_profile [| ("tw/TEST", bars) |] buy_hold [| zero_costs |]
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
            { min_maintenance = None; margin_call_dates = [];
              refinances = 0; clamps = 0 } }
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

let rec remove_tree path =
  if Sys.is_directory path then begin
    Array.iter
      (fun name -> remove_tree (Filename.concat path name))
      (Sys.readdir path);
    Unix.rmdir path
  end else
    Sys.remove path
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
  let sym_dir = Filename.concat tw_dir symbol in
  Unix.mkdir sym_dir 0o700;
  let stock_path = Filename.concat sym_dir (symbol ^ ".csv") in
  let dividend_path = Filename.concat sym_dir (symbol ^ ".div.csv") in
  Fun.protect
    ~finally:(fun () ->
      (try Sys.remove cache with Sys_error _ -> ());
      remove_tree data_dir)
    (fun () ->
      Sys.rename cache stock_path;
      write dividend_path "date,factor\n2020-01-04,0.5\n";
      let adjusted =
        (Data.load_asset ~market:"tw" ~symbol ~from_:None ~to_:None
           ~data_dir).Data.signal
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

let alpaca_fixture name =
  read_file
    (locate
       [Filename.concat "test/fixtures/alpaca" name;
        Filename.concat "fixtures/alpaca" name])

let test_dividend_tax_cli () =
  let root = Filename.temp_file "bt-test-dividend-tax-" "" in
  let () = Sys.remove root in
  let () = Unix.mkdir root 0o700 in
  let tw_dir = Filename.concat root "tw" in
  let out_dir = Filename.concat root "out" in
  Fun.protect
    ~finally:(fun () -> remove_tree root)
    (fun () ->
      let () = Unix.mkdir tw_dir 0o700 in
      let aa_dir = Filename.concat tw_dir "AA" in
      let () = Unix.mkdir aa_dir 0o700 in
      let write path contents =
        let output = open_out path in
        Fun.protect
          ~finally:(fun () -> close_out output)
          (fun () -> output_string output contents)
      in
      let () =
        write (Filename.concat aa_dir "AA.csv")
          "date,open,high,low,close,volume\n\
           2020-01-01,100,100,100,100,1000\n\
           2020-01-02,90,90,90,90,1000\n\
           2020-01-03,90,90,90,90,1000\n"
      in
      let () =
        write (Filename.concat aa_dir "AA.div.csv")
          "date,factor\n2020-01-02,0.9\n"
      in
      let () =
        write (Filename.concat aa_dir "AA.events.csv") "date,factor\n"
      in
      let () =
        write (Filename.concat aa_dir "AA.cashdiv.csv")
          "ex_date,cash_per_share,pay_date\n\
           2020-01-02,10,2020-01-02\n"
      in
      let strategy_path = Filename.concat root "tax.strat" in
      let () =
        write strategy_path "stock \"tw/AA\"\ntarget 1.0\n"
      in
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
            "tax";
            "--no-plot";
            "--dividend-tax";
            "25";
            "--financing-rate";
            "0";
            "--financing-ratio";
            "0";
            "--loan-term-months";
            "0";
            "--fee-bps";
            "0";
            "--tax-bps";
            "0";
            "--slip-bps";
            "0";
            "--min-fee";
            "0";
            ">/dev/null";
            "2>&1" ]
      in
      (* The CLI must accept the valid 25% tax flag and finish the run. *)
      assert (Sys.command command = 0);
      let rows =
        read_file (Filename.concat out_dir "tax.csv")
        |> String.split_on_char '\n'
      in
      (* The 100 to 90 ex-date drop loses 0.1. A 25%-taxed 0.1
         dividend restores 0.075, so the final CSV equity is 0.975. *)
      match rows with
      | [_; _; _; final; ""] ->
          begin
            match String.split_on_char ',' final with
            | ["2020-01-03"; value] ->
                assert_close ~tolerance:1e-12 0.975
                  (float_of_string value)
            | _ -> assert false
          end
      | _ -> assert false)


let test_multi_stock_cli () =
  let root = Filename.temp_file "bt-test-multi-" "" in
  Sys.remove root;
  Unix.mkdir root 0o700;
  let tw_dir = Filename.concat root "tw" in
  let out_dir = Filename.concat root "out" in
  Fun.protect
    ~finally:(fun () -> remove_tree root)
    (fun () ->
      Unix.mkdir tw_dir 0o700;
      let aa_dir = Filename.concat tw_dir "AA" in
      Unix.mkdir aa_dir 0o700;
      let bb_dir = Filename.concat tw_dir "BB" in
      Unix.mkdir bb_dir 0o700;
      let write path contents =
        let output = open_out path in
        Fun.protect
          ~finally:(fun () -> close_out output)
          (fun () -> output_string output contents)
      in
      write (Filename.concat aa_dir "AA.csv")
        "date,open,high,low,close,volume\n\
         2020-01-01,100,101,99,100,1000\n\
         2020-01-02,110,111,109,110,1000\n\
         2020-01-03,121,122,120,121,1000\n\
         2020-01-06,130,131,129,130,1000\n";
      write (Filename.concat bb_dir "BB.csv")
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
            "--financing-rate";
            "0";
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
                 (* Entry gross 1.5 has cash 0 and loan 0.5. Day 2
                    assets are 1.1 + 0.55, so equity is 1.15. Day 3
                    assets are 1.21 + 0.66, so equity is 1.37. *)
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

let test_margin_cli () =
  let root = Filename.temp_file "bt-test-margin-" "" in
  Sys.remove root;
  Unix.mkdir root 0o700;
  let tw_dir = Filename.concat root "tw" in
  let out_dir = Filename.concat root "out" in
  Fun.protect
    ~finally:(fun () -> remove_tree root)
    (fun () ->
      Unix.mkdir tw_dir 0o700;
      let aa_dir = Filename.concat tw_dir "AA" in
      Unix.mkdir aa_dir 0o700;
      let bb_dir = Filename.concat tw_dir "BB" in
      Unix.mkdir bb_dir 0o700;
      let write path contents =
        let output = open_out path in
        Fun.protect
          ~finally:(fun () -> close_out output)
          (fun () -> output_string output contents)
      in
      write (Filename.concat aa_dir "AA.csv")
        "date,open,high,low,close,volume\n\
         2020-01-01,100,101,99,100,1000\n\
         2020-01-02,110,111,109,110,1000\n\
         2020-01-03,121,122,120,121,1000\n\
         2020-01-06,130,131,129,130,1000\n";
      write (Filename.concat bb_dir "BB.csv")
        "date,open,high,low,close,volume\n\
         2020-01-01,50,51,49,50,1000\n\
         2020-01-02,55,56,54,55,1000\n\
         2020-01-03,66,67,65,66,1000\n";
      let strategy_path = Filename.concat root "margin.strat" in
      write strategy_path
        "stock \"tw/AA\" as a\n\
         stock \"tw/BB\" as b\n\
         a.target 2.0\n\
         b.target 0.0\n";
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
            "margin";
            "--no-plot";
            "--fee-bps";
            "0";
            "--tax-bps";
            "0";
            "--slip-bps";
            "0";
            "--min-fee";
            "0";
            "--financing-ratio";
            "40";
            ">";
            Filename.quote stdout_path;
            "2>&1" ]
      in
      assert (Sys.command command = 0);
      let stdout = read_file stdout_path in
      assert
        (contains stdout
           "margin: margin - financing 6.35%/yr, min maintenance 250.00%, margin calls 0, refinances 0, clamps 1");
      assert (not (contains stdout "daily-reset")))

let test_event_transform () =
  assert (
    Data.event_sources =
    [
      ("TaiwanStockSplitPrice", "before_price", "after_price", true);
      ("TaiwanStockCapitalReductionReferencePrice",
       "ClosingPriceonTheLastTradingDay", "PostReductionReferencePrice", true);
      ("TaiwanStockParValueChange", "before_close", "after_ref_close", false);
    ]);
  List.iter
    (fun (_dataset, before, after, _use_data_id) ->
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
let test_cash_dividend_parse () =
  with_temp_strategy
    "ex_date,cash_per_share,pay_date\n\
     2025-11-15,2.5,2025-12-20\n\
     2025-12-31,1.25,\n"
    (fun path ->
      let dividends = Data.read_cash_dividends path in
      (* The two nonzero fixture rows each produce one cash event. *)
      assert (Array.length dividends = 2);
      (* A source pay date is preserved verbatim. *)
      assert (dividends.(0).Data.pay_date = "2025-12-20");
      (* One calendar month after 2025-12-31 is 2026-01-31. *)
      assert (dividends.(1).Data.pay_date = "2026-01-31"))

let test_cash_dividend_fallback_derivation () =
  let bars =
    [| bar "2025-12-30" 100. 100.;
       bar "2025-12-31" 90. 90. |]
  in
  let dividends =
    Data.derive_cash_dividends bars [| "2025-12-31", 0.9 |]
  in
  (* One factor row has one previous raw close, so it yields one event. *)
  assert (Array.length dividends = 1);
  (* The factor date is the cash ex-date. *)
  assert (dividends.(0).Data.ex_date = "2025-12-31");
  (* (1 - 0.9) * the previous raw close of 100 = 10 per share. *)
  assert_close 10. dividends.(0).Data.cash_per_share;
  (* The derived cache has no pay date, so the loader adds one month. *)
  assert (dividends.(0).Data.pay_date = "2026-01-31");
  with_temp_strategy
    "ex_date,cash_per_share,pay_date\n2020-01-02,3,2020-02-03\n"
    (fun cache_path ->
      Data.merge_cash_dividend_cache dividends ~cache_path;
      let merged = Data.read_cash_dividends cache_path in
      (* A partial factor derivation retains the older cached event. *)
      assert (Array.length merged = 2);
      (* The retained direct-source row keeps its original pay date. *)
      assert (merged.(0).Data.pay_date = "2020-02-03");
      (* The newly derived row is added after the retained history. *)
      assert (merged.(1).Data.ex_date = "2025-12-31"))


let with_temp_market market function_ =
  let root = Filename.temp_file "bt-test-dividend-" "" in
  Sys.remove root;
  Unix.mkdir root 0o700;
  let directory = Filename.concat root market in
  Unix.mkdir directory 0o700;
  Fun.protect
    ~finally:(fun () -> remove_tree root)
    (fun () -> function_ root directory)

let test_tiingo_snap () =
  (* 7:1 split: Tiingo emits 7.000007000007001; snap to 7, event = 1/7. *)
  assert_close 7. (Data.snap_split_factor 7.000007000007001);
  (* Exact ratios pass through untouched. *)
  assert_close 4. (Data.snap_split_factor 4.);
  assert_close 0.5 (Data.snap_split_factor 0.5);
  (* 3:2 split. *)
  assert_close 1.5 (Data.snap_split_factor 1.5000015);
  (* Irrational value outside any p/q <= 50 at 1e-4: verbatim. *)
  assert_close 3.14159 (Data.snap_split_factor 3.14159)

let test_tiingo_token_required () =
  (* Missing or empty TIINGO_TOKEN must raise Failure, not silently succeed. *)
  let saved = Sys.getenv_opt "TIINGO_TOKEN" in
  let () = Unix.putenv "TIINGO_TOKEN" "" in
  let () =
    Fun.protect
      ~finally:(fun () ->
        match saved with
        | Some v -> Unix.putenv "TIINGO_TOKEN" v
        | None -> Unix.putenv "TIINGO_TOKEN" "")
      (fun () ->
        assert_failure (fun () ->
          Data.fetch ~market:"us" ~symbol:"SPY" ~from_:None
            ~to_:"2026-01-01" ~data_dir:"/tmp"))
  in
  ()

let test_tw_adjustment_refresh_horizon () =
  with_temp_market "tw" (fun data_dir tw_dir ->
    let symbol_dir = Filename.concat tw_dir "2330" in
    let () = Unix.mkdir symbol_dir 0o700 in
    let write name contents =
      let output = open_out (Filename.concat symbol_dir name) in
      Fun.protect
        ~finally:(fun () -> close_out output)
        (fun () -> output_string output contents)
    in
    let () =
      write "2330.csv"
        "date,open,high,low,close,volume\n\
         2026-05-21,100,100,100,100,1000\n\
         2026-05-22,100,100,100,100,1000\n"
    in
    let () = write "2330.div.csv" "date,factor\n" in
    let () =
      write "2330.events.csv" "date,factor\n2026-05-26,0.5\n"
    in
    let () =
      write "2330.cashdiv.csv" "ex_date,cash_per_share,pay_date\n"
    in
    let asset =
      Data.load_asset ~market:"tw" ~symbol:"2330" ~from_:None
        ~to_:(Some "2026-05-22") ~data_dir
    in
    (* A current-session action must adjust the previous-session signal plane. *)
    assert_close 50. asset.Data.signal.(1).c)

let test_tw_adjustment_refresh_failure () =
  with_temp_market "tw" (fun data_dir tw_dir ->
    let symbol_dir = Filename.concat tw_dir "2330" in
    let () = Unix.mkdir symbol_dir 0o700 in
    let price_cache = Filename.concat symbol_dir "2330.csv" in
    let output = open_out price_cache in
    let () =
      Fun.protect
        ~finally:(fun () -> close_out output)
        (fun () ->
          output_string output
            "date,open,high,low,close,volume\n\
             2026-05-26,100,100,100,100,1000\n")
    in
    match Unix.fork () with
    | 0 ->
        (try
          let () = Unix.putenv "FINMIND_TOKEN" "x" in
          let () =
            Unix.putenv "https_proxy" "http://127.0.0.1:1"
          in
          let () = Unix.putenv "NO_PROXY" "" in
          let failure =
            try
              let () =
                Data.fetch_tw_adjustments ~symbol:"2330" ~to_:"2026-05-26"
                  ~data_dir
              in
              None
            with Failure message -> Some message
          in
          (* The legacy factor source is the first failed adjustment dataset. *)
          let () =
            assert
              (failure =
               Some "TaiwanStockDividendResult adjustment refresh failed")
          in
          (* Historical fetch keeps its existing best-effort warning contract. *)
          let () =
            Data.fetch ~market:"tw" ~symbol:"2330" ~from_:None
              ~to_:"2026-05-26" ~data_dir
          in
          Unix._exit 0
        with _ -> Unix._exit 1)
    | child ->
        let _, status = Unix.waitpid [] child in
        (* The child isolates all three environment changes from later tests. *)
        assert (status = Unix.WEXITED 0))


let test_tiingo_transform () =
  (* Build a small Tiingo CSV fixture: a split, a dividend, and a normal row. *)
  let csv =
    "date,close,high,low,open,volume,adjClose,adjHigh,adjLow,adjOpen,adjVolume,divCash,splitFactor\n\
     2020-08-27,503.43,507.73,501.06,506.09,3477380,503.43,507.73,501.06,506.09,3477380,0,1\n\
     2020-08-28,499.3,501.56,498.52,500.74,2635860,499.3,501.56,498.52,500.74,2635860,0,1\n\
     2020-08-31,129.04,131.0,126.0,127.58,14170170,129.04,131.0,126.0,127.58,14170170,0,4.000004000004\n\
     2020-09-01,134.18,134.8,130.53,132.76,7432100,134.18,134.8,130.53,132.76,7432100,0,1\n\
     2024-03-15,172.62,173.05,170.06,171.17,5088850,172.62,173.05,170.06,171.17,5088850,1.594937,1\n\
     2024-03-18,173.72,175.1,171.96,175.1,3506210,173.72,175.1,171.96,175.1,3506210,0,1\n"
  in
  with_temp_strategy csv (fun csv_path ->
    with_temp_strategy "" (fun prices_path ->
      with_temp_strategy "" (fun events_path ->
        with_temp_strategy "" (fun cashdiv_path ->
          with_temp_strategy "" (fun div_path ->
            Data.write_tiingo_rows ~csv_path ~prev_close:None
              ~prices_path ~events_path ~cashdiv_path ~div_path;
            (* All four output files must be non-empty or at least exist. *)
            assert (Sys.file_exists prices_path);
            assert (Sys.file_exists events_path);
            assert (Sys.file_exists cashdiv_path);
            assert (Sys.file_exists div_path);
            (* Prices: six rows, each with exactly 6 comma-separated fields. *)
            let price_lines =
              List.filter (fun l -> l <> "")
                (String.split_on_char '\n' (read_file prices_path))
            in
            assert (List.length price_lines = 6);
            List.iter (fun line ->
              let fields = String.split_on_char ',' line in
              (* Exactly date,open,high,low,close,volume = 6 fields. *)
              assert (List.length fields = 6))
              price_lines;
            (* First price row: date reordered to date,open,high,low,close,vol.
               Tiingo columns: date=2020-08-27, close=503.43, high=507.73,
               low=501.06, open=506.09, volume=3477380.
               Expected: 2020-08-27,506.09,507.73,501.06,503.43,3477380 *)
            (match String.split_on_char ',' (List.hd price_lines) with
             | [d; o; h; l; c; v] ->
                 assert (d = "2020-08-27");
                 assert_close 506.09 (float_of_string o);
                 assert_close 503.43 (float_of_string c);
                 assert_close 507.73 (float_of_string h);
                 assert_close 501.06 (float_of_string l);
                 assert_close 3477380. (float_of_string v)
             | _ -> assert false);
            (* Events: the 4:1 split produces one event factor = 1/4 = 0.25. *)
            let events = read_file events_path in
            assert (contains events "2020-08-31");
            let factor =
              match String.split_on_char ',' (String.trim events) with
              | [_; f] -> float_of_string f
              | _ -> failwith "expected one event row"
            in
            (* 4.000004000004 snaps to 4; 1/4 = 0.25. *)
            assert_close 0.25 factor;
            (* CashDiv: the 2024-03-15 row has divCash = 1.594937. *)
            let cashdiv = read_file cashdiv_path in
            assert (contains cashdiv "2024-03-15");
            assert (contains cashdiv "1.594937");
            (* Div factor: (prev_close - divCash) / prev_close.
               prev row is 2020-09-01 close 134.18.
               (134.18 - 1.594937) / 134.18 *)
            let div = read_file div_path in
            assert (contains div "2024-03-15");
            let div_factor =
              match String.split_on_char ',' (String.trim div) with
              | [_; f] -> float_of_string f
              | _ -> failwith "expected one div row"
            in
            assert_close ((134.18 -. 1.594937) /. 134.18) div_factor)))))

let test_tiingo_append_seam () =
  (* Verify that appending to an existing US cache produces 6-field rows
     and the seam between old and new data is contiguous. *)
  with_temp_market "us" (fun root us ->
    let sym = Filename.concat us "TEST" in
    Unix.mkdir sym 0o700;
    let write name contents =
      let output = open_out (Filename.concat sym name) in
      Fun.protect
        ~finally:(fun () -> close_out output)
        (fun () -> output_string output contents)
    in
    (* Seed a cache truncated to two bars. *)
    write "TEST.csv"
      "date,open,high,low,close,volume\n\
       2024-01-02,100,101,99,100.5,1000\n\
       2024-01-03,101,102,100,101.5,2000\n";
    write "TEST.events.csv" "date,factor\n";
    write "TEST.cashdiv.csv" "ex_date,cash_per_share,pay_date\n";
    write "TEST.div.csv" "date,factor\n";
    (* Build a Tiingo CSV fragment for two NEW rows (after the cache). *)
    let csv =
      "date,close,high,low,open,volume,adjClose,adjHigh,adjLow,adjOpen,adjVolume,divCash,splitFactor\n\
       2024-01-04,103,104,102,102.5,3000,103,104,102,102.5,3000,0,1\n\
       2024-01-05,104,105,103,103.5,4000,104,105,103,103.5,4000,0.5,1\n"
    in
    with_temp_strategy csv (fun csv_path ->
      with_temp_strategy "" (fun pp ->
        with_temp_strategy "" (fun ep ->
          with_temp_strategy "" (fun cp ->
            with_temp_strategy "" (fun dp ->
              Data.write_tiingo_rows ~csv_path
                ~prev_close:(Some 101.5)
                ~prices_path:pp ~events_path:ep
                ~cashdiv_path:cp ~div_path:dp;
              (* Append the new price rows. *)
              Data.append_rows ~header:"date,open,high,low,close,volume"
                ~rows_path:pp
                ~cache_path:(Filename.concat sym "TEST.csv")
                ~after:(Some "2024-01-03");
              (* Append cashdiv. *)
              Data.append_rows ~header:"ex_date,cash_per_share,pay_date"
                ~rows_path:cp
                ~cache_path:(Filename.concat sym "TEST.cashdiv.csv")
                ~after:(Some "2024-01-03");
              (* Append div. *)
              Data.append_rows ~header:"date,factor"
                ~rows_path:dp
                ~cache_path:(Filename.concat sym "TEST.div.csv")
                ~after:(Some "2024-01-03"))))));
    (* Read the merged cache and verify row shape. *)
    let lines =
      List.filter (fun l -> l <> "")
        (String.split_on_char '\n'
           (read_file (Filename.concat sym "TEST.csv")))
    in
    (* Header + 2 old + 2 new = 5 lines. *)
    assert (List.length lines = 5);
    (* Every data row has exactly 6 fields. *)
    List.iter (fun line ->
      if line <> "date,open,high,low,close,volume" then
        assert (List.length (String.split_on_char ',' line) = 6))
      lines;
    (* The seam: last old row is 2024-01-03, first new row is 2024-01-04. *)
    let dates = List.map (fun l ->
      match String.split_on_char ',' l with d :: _ -> d | [] -> "")
      (List.tl lines)
    in
    assert (dates = ["2024-01-02"; "2024-01-03"; "2024-01-04"; "2024-01-05"]);
    (* Cashdiv: 0.5 dividend on 2024-01-05 appended.
       Div factor: (101.5 - 0.5) / 101.5 from prev_close 101.5. *)
    let loaded =
      Data.load_asset ~market:"us" ~symbol:"TEST" ~from_:None ~to_:None
        ~data_dir:root
    in
    assert (Array.length loaded.Data.dividends = 1);
    assert (loaded.Data.dividends.(0).Data.ex_date = "2024-01-05");
    assert_close 0.5 loaded.Data.dividends.(0).Data.cash_per_share)

let test_two_price_planes () =
  with_temp_market "tw" (fun root tw ->
    let sym = Filename.concat tw "CASH" in
    Unix.mkdir sym 0o700;
    let write name contents =
      let output = open_out (Filename.concat sym name) in
      Fun.protect
        ~finally:(fun () -> close_out output)
        (fun () -> output_string output contents)
    in
    let () =
      write "CASH.csv"
        "date,open,high,low,close,volume\n\
         2025-12-28,400,400,400,400,250\n\
         2025-12-29,200,200,200,200,500\n\
         2025-12-30,100,100,100,100,1000\n\
         2025-12-31,90,90,90,90,1100\n"
    in
    let () =
      write "CASH.div.csv"
        "date,factor\n2025-12-30,0.5\n2025-12-31,0.9\n"
    in
    let () =
      write "CASH.events.csv" "date,factor\n2025-12-29,0.5\n"
    in
    let () =
      write "CASH.cashdiv.csv"
        "ex_date,cash_per_share,pay_date\n2025-12-31,10,2026-01-31\n"
    in
    let loaded =
      Data.load_asset ~market:"tw" ~symbol:"CASH" ~from_:None ~to_:None
        ~data_dir:root
    in
    let expected_signal : Data.bar array =
      [| { date = "2025-12-28"; o = 90.; h = 90.; l = 90.; c = 90.;
           v = 1000. };
         { date = "2025-12-29"; o = 90.; h = 90.; l = 90.; c = 90.;
           v = 1000. };
         { date = "2025-12-30"; o = 90.; h = 90.; l = 90.; c = 90.;
           v = 1000. };
         { date = "2025-12-31"; o = 90.; h = 90.; l = 90.; c = 90.;
           v = 1100. } |]
    in
    (* Signal prices stay byte-identical; both 0.5 share factors restate
       250 volume to 1000, and the later stock factor restates 500 to 1000. *)
    assert
      (Marshal.to_bytes loaded.Data.signal [Marshal.No_sharing] =
       Marshal.to_bytes expected_signal [Marshal.No_sharing]);
    (* Event and stock-dividend factors leave pre-event money at 100. *)
    assert_close 100. loaded.Data.money.(0).Data.c;
    (* The event and stock factors restate 250 / (0.5 * 0.5) to 1000. *)
    assert_close 1000. loaded.Data.money.(0).Data.v;
    (* Both planes use the same post-event volume basis of 1000 shares. *)
    assert_close 1000. loaded.Data.signal.(0).Data.v;
    (* Removing only the cash factor leaves the stock factor in money. *)
    assert_close 100. loaded.Data.money.(2).Data.c;
    (* The ex-date raw close falls from adjusted 100 to money price 90. *)
    assert_close 90. loaded.Data.money.(3).Data.c)
let test_dividend_cash_split_restatement () =
  with_temp_market "tw" (fun root tw ->
    let direct_dir = Filename.concat tw "DIRECT" in
    Unix.mkdir direct_dir 0o700;
    let fallback_dir = Filename.concat tw "FALLBACK" in
    Unix.mkdir fallback_dir 0o700;
    let write_to dir name contents =
      let output = open_out (Filename.concat dir name) in
      Fun.protect
        ~finally:(fun () -> close_out output)
        (fun () -> output_string output contents)
    in
    let prices =
      "date,open,high,low,close,volume\n\
       2025-01-01,100,100,100,100,1000\n\
       2025-01-02,90,90,90,90,1000\n\
       2025-01-03,22.5,22.5,22.5,22.5,4000\n\
       2025-01-04,21.5,21.5,21.5,21.5,4000\n"
    in
    let factors =
      [| "2025-01-02", 0.9;
         "2025-01-04", 21.5 /. 22.5 |]
    in
    let factor_csv =
      "date,factor\n\
       2025-01-02,0.9\n\
       2025-01-04,0.9555555555555556\n"
    in
    let events = "date,factor\n2025-01-03,0.25\n" in
    let () = write_to direct_dir "DIRECT.csv" prices in
    let () = write_to direct_dir "DIRECT.div.csv" factor_csv in
    let () = write_to direct_dir "DIRECT.events.csv" events in
    let () =
      write_to direct_dir "DIRECT.cashdiv.csv"
        "ex_date,cash_per_share,pay_date\n\
         2025-01-02,10,2025-02-02\n\
         2025-01-04,1,2025-02-04\n"
    in
    let direct =
      Data.load_asset ~market:"tw" ~symbol:"DIRECT" ~from_:None ~to_:None
        ~data_dir:root
    in
    (* Both direct-source cash rows survive the loader. *)
    assert (Array.length direct.Data.dividends = 2);
    (* The later 1:4 event restates pre-split cash: 10 * 0.25 = 2.5. *)
    assert_close 2.5 direct.Data.dividends.(0).Data.cash_per_share;
    (* No share-count event follows the second dividend, so 1 stays 1. *)
    assert_close 1. direct.Data.dividends.(1).Data.cash_per_share;
    let () = write_to fallback_dir "FALLBACK.csv" prices in
    let () = write_to fallback_dir "FALLBACK.div.csv" factor_csv in
    let () = write_to fallback_dir "FALLBACK.events.csv" events in
    let derived =
      Data.derive_cash_dividends
        (Data.read_bars ~market:"tw" (Filename.concat fallback_dir "FALLBACK.csv"))
        factors
    in
    let () =
      Data.merge_cash_dividend_cache derived
        ~cache_path:(Filename.concat fallback_dir "FALLBACK.cashdiv.csv")
    in
    let fallback =
      Data.load_asset ~market:"tw" ~symbol:"FALLBACK" ~from_:None ~to_:None
        ~data_dir:root
    in
    (* The factor fallback derives both historical-basis cash rows. *)
    assert (Array.length fallback.Data.dividends = 2);
    (* The loader also restates fallback cash: 10 * 0.25 = 2.5. *)
    assert_close 2.5 fallback.Data.dividends.(0).Data.cash_per_share;
    (* The post-split fallback amount is (1 - 21.5/22.5) * 22.5 = 1. *)
    assert_close 1. fallback.Data.dividends.(1).Data.cash_per_share)


let test_cash_restatement_through_stock_dividend () =
  with_temp_market "tw" (fun root tw ->
    let sym = Filename.concat tw "CASH_STOCK" in
    Unix.mkdir sym 0o700;
    let write name contents =
      let output = open_out (Filename.concat sym name) in
      Fun.protect
        ~finally:(fun () -> close_out output)
        (fun () -> output_string output contents)
    in
    write "CASH_STOCK.csv"
      "date,open,high,low,close,volume\n\
       2025-01-01,100,100,100,100,100\n\
       2025-01-02,90,90,90,90,100\n\
       2025-01-03,45,45,45,45,200\n";
    write "CASH_STOCK.div.csv"
      "date,factor\n2025-01-02,0.9\n2025-01-03,0.5\n";
    write "CASH_STOCK.events.csv" "date,factor\n";
    write "CASH_STOCK.cashdiv.csv"
      "ex_date,cash_per_share,pay_date\n2025-01-02,10,2025-02-02\n";
    let loaded =
      Data.load_asset ~market:"tw" ~symbol:"CASH_STOCK" ~from_:None
        ~to_:None ~data_dir:root
    in
    (* The one direct cash row produces one loaded dividend. *)
    assert (Array.length loaded.Data.dividends = 1);
    (* The later 1:2 stock dividend restates 10 old-basis cash to 5. *)
    assert_close 5. loaded.Data.dividends.(0).Data.cash_per_share)

let test_same_day_unit_factor_restates_cash () =
  with_temp_market "tw" (fun root tw ->
    let sym = Filename.concat tw "SAME_DAY" in
    Unix.mkdir sym 0o700;
    let write name contents =
      let output = open_out (Filename.concat sym name) in
      Fun.protect
        ~finally:(fun () -> close_out output)
        (fun () -> output_string output contents)
    in
    write "SAME_DAY.csv"
      "date,open,high,low,close,volume\n\
       2025-01-01,200,200,200,200,100\n\
       2025-01-02,95,95,95,95,200\n";
    write "SAME_DAY.div.csv" "date,factor\n2025-01-02,0.95\n";
    write "SAME_DAY.events.csv" "date,factor\n2025-01-02,0.5\n";
    write "SAME_DAY.cashdiv.csv"
      "ex_date,cash_per_share,pay_date\n2025-01-02,10,2025-02-02\n";
    let loaded =
      Data.load_asset ~market:"tw" ~symbol:"SAME_DAY" ~from_:None
        ~to_:None ~data_dir:root
    in
    (* The one direct cash row produces one loaded dividend. *)
    assert (Array.length loaded.Data.dividends = 1);
    (* The same-date 1:2 unit factor converts 10 old-basis cash to 5. *)
    assert_close 5. loaded.Data.dividends.(0).Data.cash_per_share)

let test_us_loader_parity () =
  (* Build a US cache in the canonical four-file layout and verify the
     unified loader produces the expected two-plane result. *)
  with_temp_market "us" (fun root us ->
    let sym = Filename.concat us "TEST" in
    Unix.mkdir sym 0o700;
    let write name contents =
      let output = open_out (Filename.concat sym name) in
      Fun.protect
        ~finally:(fun () -> close_out output)
        (fun () -> output_string output contents)
    in
    (* Raw prices: a 2:1 split on 2025-01-03, a $2 dividend on 2025-01-05. *)
    write "TEST.csv"
      "date,open,high,low,close,volume\n\
       2025-01-01,100,100,100,100,1000\n\
       2025-01-02,102,102,102,102,1000\n\
       2025-01-03,50,50,50,50,2000\n\
       2025-01-04,51,51,51,51,2000\n\
       2025-01-05,49,49,49,49,2000\n";
    (* Event: 2:1 split, factor = 0.5 (post/pre ratio). *)
    write "TEST.events.csv" "date,factor\n2025-01-03,0.5\n";
    (* Cash dividend of $2 on 2025-01-05. *)
    write "TEST.cashdiv.csv" "ex_date,cash_per_share,pay_date\n2025-01-05,2,\n";
    (* Div factor: (prev_close - divCash) / prev_close = (51 - 2) / 51. *)
    write "TEST.div.csv"
      (Printf.sprintf "date,factor\n2025-01-05,%.17g\n" (49. /. 51.));
    let loaded =
      Data.load_asset ~market:"us" ~symbol:"TEST" ~from_:None ~to_:None
        ~data_dir:root
    in
    assert (Array.length loaded.Data.signal = 5);
    assert (Array.length loaded.Data.money = 5);
    (* Signal plane: raw * div * events back-adjusted.
       signal_factors = div ++ events = [(2025-01-03,0.5); (2025-01-05, 49/51)].
       Cumulative factor at bar 0 (before both): 0.5 * 49/51.
       Bar 0 signal close = 100 * 0.5 * 49/51. *)
    assert_close (100. *. 0.5 *. (49. /. 51.)) loaded.Data.signal.(0).Data.c;
    (* Bar 4 (after both factors): factor = 1.0, raw close = 49. *)
    assert_close 49. loaded.Data.signal.(4).Data.c;
    (* Money plane: raw * events only (no div factor).
       money_factors = stock_dividend_factors ++ events.
       Since the div.csv factor (49/51) is cash, money_dividend_factors
       decomposes it as cash; the stock component equals full/cash = 1.
       So money_factors = [(2025-01-03, 0.5)].
       Bar 0 money close = 100 * 0.5 = 50. *)
    assert_close 50. loaded.Data.money.(0).Data.c;
    (* Bar 4: no money factor after the split, raw close = 49. *)
    assert_close 49. loaded.Data.money.(4).Data.c;
    (* Volume restated by inverse event factor: bar 0 = 1000 / 0.5 = 2000. *)
    assert_close 2000. loaded.Data.money.(0).Data.v;
    assert_close 2000. loaded.Data.signal.(0).Data.v;
    (* US pay-date rule: pay_date = ex_date. *)
    assert (Array.length loaded.Data.dividends = 1);
    assert (loaded.Data.dividends.(0).Data.ex_date = "2025-01-05");
    assert (loaded.Data.dividends.(0).Data.pay_date = "2025-01-05");
    (* The 0.5 split on 2025-01-03 precedes the 2025-01-05 dividend;
       restatement applies only to events on or after the ex-date,
       so cash_per_share stays at the raw 2. *)
    assert_close 2. loaded.Data.dividends.(0).Data.cash_per_share)

let test_fallback_preserves_direct_overlap () =
  let derived =
    Data.derive_cash_dividends
      [| bar "2025-12-30" 100. 100.;
         bar "2025-12-31" 90. 90. |]
      [| "2025-12-31", 0.9 |]
  in
  with_temp_strategy
    "ex_date,cash_per_share,pay_date\n2025-12-31,7,2026-01-15\n"
    (fun cache_path ->
      Data.merge_cash_dividend_cache derived ~cache_path;
      let merged = Data.read_cash_dividends cache_path in
      (* One shared ex-date collapses to the authoritative cached row. *)
      assert (Array.length merged = 1);
      (* The direct-source amount 7 wins over the derived amount 10. *)
      assert_close 7. merged.(0).Data.cash_per_share;
      (* The direct-source pay date survives the overlapping fallback. *)
      assert (merged.(0).Data.pay_date = "2026-01-15"))

let test_stock_dividend_restates_volume () =
  with_temp_market "tw" (fun root tw ->
    let sym = Filename.concat tw "STOCK_VOLUME" in
    Unix.mkdir sym 0o700;
    let write name contents =
      let output = open_out (Filename.concat sym name) in
      Fun.protect
        ~finally:(fun () -> close_out output)
        (fun () -> output_string output contents)
    in
    write "STOCK_VOLUME.csv"
      "date,open,high,low,close,volume\n\
       2025-01-01,100,100,100,100,100\n\
       2025-01-02,50,50,50,50,200\n";
    write "STOCK_VOLUME.div.csv" "date,factor\n2025-01-02,0.5\n";
    write "STOCK_VOLUME.events.csv" "date,factor\n";
    write "STOCK_VOLUME.cashdiv.csv"
      "ex_date,cash_per_share,pay_date\n";
    let loaded =
      Data.load_asset ~market:"tw" ~symbol:"STOCK_VOLUME" ~from_:None
        ~to_:None ~data_dir:root
    in
    (* The inverse 0.5 stock factor restates earlier money volume to 200. *)
    assert_close 200. loaded.Data.money.(0).Data.v;
    (* The same factor puts signal volume on the same 200-share basis. *)
    assert_close 200. loaded.Data.signal.(0).Data.v)

let test_load_adjustments () =
  let root = Filename.temp_file "bt-test-data-" "" in
  Sys.remove root;
  Unix.mkdir root 0o700;
  let tw = Filename.concat root "tw" in
  Unix.mkdir tw 0o700;
  Fun.protect
    ~finally:(fun () -> remove_tree root)
    (fun () ->
      let write dir name contents =
        let output = open_out (Filename.concat dir name) in
        Fun.protect
          ~finally:(fun () -> close_out output)
          (fun () -> output_string output contents)
      in
      let mixed_dir = Filename.concat tw "MIXED" in
      Unix.mkdir mixed_dir 0o700;
      write mixed_dir "MIXED.csv"
        "date,open,high,low,close,volume\n\
         2025-06-17,400,400,400,400,100\n\
         2025-06-18,100,100,100,100,500\n\
         2025-07-20,100,100,100,100,600\n\
         2025-07-21,98,98,98,98,700\n";
      write mixed_dir "MIXED.div.csv"
        "date,factor\n2025-07-21,0.98\n";
      write mixed_dir "MIXED.cashdiv.csv"
        "ex_date,cash_per_share,pay_date\n\
         2025-07-21,2,2025-08-21\n";
      write mixed_dir "MIXED.events.csv"
        "date,factor\n2025-06-18,0.25\n";
      let mixed =
        (Data.load_asset ~market:"tw" ~symbol:"MIXED" ~from_:None
           ~to_:None ~data_dir:root).Data.signal
      in
      (* Before both events, 400 * 0.25 * 0.98 = 98. *)
      assert_close 98. mixed.(0).Data.c;
      (* The split date is adjusted only by the later dividend: 100 * 0.98 = 98. *)
      assert_close 98. mixed.(1).Data.c;
      (* Between the split and dividend, only the later 0.98 factor applies. *)
      assert_close 98. mixed.(2).Data.c;
      (* Strict-before excludes the dividend date, so its raw close stays 98. *)
      assert_close 98. mixed.(3).Data.c;
      (* Before the 1:4 split, 100 * (1 / 0.25) = 400 shares. *)
      assert_close 400. mixed.(0).Data.v;
      (* Strict-before excludes the split date, so its raw volume stays 500. *)
      assert_close 500. mixed.(1).Data.v;
      (* No later share-count event applies, so raw volume 600 stays 600. *)
      assert_close 600. mixed.(2).Data.v;
      (* A dividend does not restate volume, so raw volume 700 stays 700. *)
      assert_close 700. mixed.(3).Data.v;
      let div_dir = Filename.concat tw "DIV" in
      Unix.mkdir div_dir 0o700;
      write div_dir "DIV.csv"
        "date,open,high,low,close,volume\n\
         2020-01-01,100,100,100,100,111\n\
         2020-01-02,90,90,90,90,222\n";
      write div_dir "DIV.div.csv"
        "date,factor\n2020-01-02,0.9\n";
      write div_dir "DIV.cashdiv.csv"
        "ex_date,cash_per_share,pay_date\n\
         2020-01-02,10,2020-02-02\n";
      write div_dir "DIV.events.csv" "date,factor\n";
      let dividend =
        (Data.load_asset ~market:"tw" ~symbol:"DIV" ~from_:None
           ~to_:None ~data_dir:root).Data.signal
      in
      (* Before the dividend, 100 * 0.9 = 90. *)
      assert_close 90. dividend.(0).Data.c;
      (* Dividend adjustment never changes the raw pre-date volume of 111. *)
      assert_close 111. dividend.(0).Data.v;
      (* Strict-before excludes the dividend date, leaving raw volume 222. *)
      assert_close 222. dividend.(1).Data.v;
      let split_dir = Filename.concat tw "SPLIT" in
      Unix.mkdir split_dir 0o700;
      write split_dir "SPLIT.csv"
        "date,open,high,low,close,volume\n\
         2026-06-29,100,100,100,100,10\n\
         2026-06-30,50,50,50,50,20\n\
         2026-07-01,55,55,55,55,30\n";
      write split_dir "SPLIT.div.csv" "date,factor\n";
      write split_dir "SPLIT.events.csv"
        "date,factor\n2026-06-30,0.5\n";
      let split =
        (Data.load_asset ~market:"tw" ~symbol:"SPLIT" ~from_:None
           ~to_:None ~data_dir:root).Data.signal
      in
      (* Before the 1:2 split, 100 * 0.5 = 50. *)
      assert_close 50. split.(0).Data.c;
      (* The inverse split factor restates 10 / 0.5 = 20 shares. *)
      assert_close 20. split.(0).Data.v;
      (* Strict-before excludes the split date, leaving raw volume 20. *)
      assert_close 20. split.(1).Data.v;
      (* After the split, no event factor applies and raw volume stays 30. *)
      assert_close 30. split.(2).Data.v)

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
      assert (Data.financing_ratio ~market:"tw" ~data_dir:root ~symbol:"00685L" = 0.6);
      (* The FSC's 60% TPEX maximum took effect on 2014-11-10. *)
      assert (Data.financing_ratio ~market:"tw" ~data_dir:root ~symbol:"5483" = 0.6);
      (* the row with the latest date wins *)
      assert (Data.financing_ratio ~market:"tw" ~data_dir:root ~symbol:"8069" = 0.6);
      (* unknown TW symbol warns and defaults to TWSE 60% *)
      assert (Data.financing_ratio ~market:"tw" ~data_dir:root ~symbol:"9999" = 0.6);
      (* US symbols default to Reg T 50% without a warning *)
      assert (Data.financing_ratio ~market:"us" ~data_dir:root ~symbol:"SPY" = 0.5))

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


let test_duplicate_symbol_aliases () =
  (* Two aliases pointing at the same market/symbol. Pre-3333b01
     stocks_of rejected this with seen_spec; the test must fail
     if that rejection is reintroduced. *)
  let shared_bars =
    [| bar "2020-01-01" 100. 100.;
       bar "2020-01-02" 100. 100.;
       bar "2020-01-03" 100. 100. |]
  in
  with_temp_strategy
    "stock \"tw/0050\" as bull\n\
     stock \"tw/0050\" as bear\n\
     bull.target 0.6\n\
     bear.target 0.4\n"
    (fun path ->
      let ast = Dsl.parse_file path in
      (* stocks_of returns both entries with the same spec *)
      (match Dsl.stocks_of ~filename:path ast with
       | [ (Some "bull", "tw", "0050"); (Some "bear", "tw", "0050") ] -> ()
       | _ -> assert false);
      let strategy =
        Dsl.compile_ast ast ~params:[]
          ~assets:[ (Some "bull", shared_bars); (Some "bear", shared_bars) ]
      in
      (* Per-leg targets: bull constant 0.6, bear constant 0.4. *)
      assert (strategy.Engine.targets = [| [| 0.6; 0.6; 0.6 |];
                                           [| 0.4; 0.4; 0.4 |] |]);
      (* Engine.run with a US dividend on the second bar so the credit
         lands immediately into cash.  Flat price 100, zero costs,
         no margin.  Each leg holds value proportional to its target:
         bull 0.6 and bear 0.4.  A $10 dividend on 1 share at $100
         credits (value / price) * cash_per_share per leg.

         At entry (bar 0, close-same fill): E1 = 1 (zero costs).
         Bull value = 0.6, bear value = 0.4, cash = 0.
         Bar 1 ex-date: bull credit = 0.6/100 * 10 = 0.06,
         bear credit = 0.4/100 * 10 = 0.04; sum = 0.10.
         A single stock at target 1.0 would credit 1.0/100 * 10 = 0.10.
         Final equity on bar 2 = 1.0 + 0.10 = 1.10. *)
      let dividends =
        [| [| dividend "2020-01-02" 10. "2020-01-02" |];
           [| dividend "2020-01-02" 10. "2020-01-02" |] |]
      in
      let result =
        Engine.run ~dividends ~dividend_tax:0. ~profile:us_profile
          [| ("us/BULL", shared_bars); ("us/BEAR", shared_bars) |]
          strategy [| zero_costs; zero_costs |]
          ~margin:(no_margin 2) ~capital:None ~fill:Engine.Close_same
      in
      assert_close ~tolerance:1e-12 1.10 (final_equity result))

let test_e1_order_independence () =
  (* Targets A = 0.9 and B = 0.3 cost 0.012*E1, so
     E1 = 1/(1.012) in either declaration order. Minimum down payment
     is 0.48*E1; the 0.52*E1 surplus makes cash inventory 13*E1/15
     and margin inventory E1/3 with loan E1/5. Maintenance is 5/3. *)
  let flat price =
    [| bar "2020-01-01" price price; bar "2020-01-02" price price |]
  in
  let costs : Engine.costs =
    { fee_bps = 100.; tax_bps = 0.; slip_bps = 0.; min_fee = 0.;
      per_share_sell_fee = 0.; per_share_sell_cap = 0. }
  in
  let margin : Engine.margin =
    { financing_rate = 0.; maintenance_override = Some 0.;
      ratios = [| 0.6; 0.6 |]; loan_term_months = None }
  in
  let strategy_ab : Engine.strategy =
    { targets = [| [| 0.9; 0.9 |]; [| 0.3; 0.3 |] |] }
  in
  let result_ab =
    Engine.run ~profile:tw_profile [| ("tw/A", flat 100.); ("tw/B", flat 50.) |] strategy_ab
      [| costs; costs |] ~margin ~capital:None ~fill:Engine.Close_same
  in
  let strategy_ba : Engine.strategy =
    { targets = [| [| 0.3; 0.3 |]; [| 0.9; 0.9 |] |] }
  in
  let result_ba =
    Engine.run ~profile:tw_profile [| ("tw/B", flat 50.); ("tw/A", flat 100.) |] strategy_ba
      [| costs; costs |] ~margin:margin ~capital:None ~fill:Engine.Close_same
  in
  assert_close ~tolerance:1e-15
    (final_equity result_ab) (final_equity result_ba);
  (match result_ab.margin_stats.Engine.min_maintenance,
         result_ba.margin_stats.Engine.min_maintenance with
   | Some a, Some b ->
       assert_close ~tolerance:1e-15 a b;
       assert_close ~tolerance:1e-12 (5. /. 3.) a
   | _ -> assert false)

let test_sell_deficit_waits_for_refinancing () =
  let a =
    [| bar "2020-01-01" 100. 100.;
       bar "2020-01-02" 40. 40. |]
  in
  let b =
    [| bar "2020-01-01" 100. 100.;
       bar "2020-01-02" 200. 200. |]
  in
  let margin : Engine.margin =
    { financing_rate = 0.; maintenance_override = Some 0.;
      ratios = [| 0.6; 0.6 |]; loan_term_months = None }
  in
  let result =
    Engine.run ~profile:tw_profile [| ("tw/A", a); ("tw/B", b) |]
      { Engine.targets =
          [| [| 1.5; 0. |]; [| 0.5; 2. |] |] }
      [| zero_costs; zero_costs |] ~margin ~capital:None
      ~fill:Engine.Close_same
  in
  (* Bar 0 has A cv = 1/4, mv = 5/4, L = 3/4 and B cv = 1/12,
     mv = 5/12, L = 1/4. After A falls 60% and B doubles, equity is
     3/5. Selling A realizes 3/5 but repays 3/4, temporarily taking
     cash to -3/20. B's 1/5 buy needs a 2/25 down payment, so the
     frozen plan refinances 23/100 from B before buying. It ends with
     B cv = 2/35, mv = 8/7, L = 3/5 and cash 0. Bar-1 maintenance is
     (8/7)/(3/5) = 40/21, above the bar-0 minimum 5/3. Restoring the
     temporary sell deficit early would instead leave total L = 3/4,
     cash = 3/20, and lower maintenance to 32/21. *)
  assert_close ~tolerance:1e-12 0.6 (final_equity result);
  assert (result.margin_stats.Engine.refinances = 1);
  assert (result.margin_stats.Engine.clamps = 0);
  (match result.margin_stats.Engine.min_maintenance with
   | Some ratio -> assert_close ~tolerance:1e-12 (5. /. 3.) ratio
   | None -> assert false)

let test_sell_only_fee_does_not_refinance () =
  let flat =
    [| bar "2020-01-01" 100. 100.;
       bar "2020-01-02" 100. 100.;
       bar "2020-01-03" 100. 100. |]
  in
  let falling =
    [| bar "2020-01-01" 100. 100.;
       bar "2020-01-02" 0.1 0.1;
       bar "2020-01-03" 0.1 0.1 |]
  in
  let costs : Engine.costs =
    { fee_bps = 0.; tax_bps = 0.; slip_bps = 0.; min_fee = 20.;
      per_share_sell_fee = 0.; per_share_sell_cap = 0. }
  in
  let margin : Engine.margin =
    { financing_rate = 0.; maintenance_override = Some 0.;
      ratios = [| 0.6; 0.6 |]; loan_term_months = None }
  in
  let result =
    Engine.run ~profile:tw_profile [| ("tw/A", flat); ("tw/B", falling) |]
      { Engine.targets =
          [| [| 0.5; 0.5; 0.5 |]; [| 0.5; 0.; 0. |] |] }
      [| costs; costs |] ~margin ~capital:(Some 10000.)
      ~fill:Engine.Close_same
  in
  (* Two 0.5 targets pay 0.002 each on entry, leaving E1 = 0.996
     and cash inventories of 0.498 apiece. B falls to 0.1% of entry,
     so pre-fill equity is 0.498 + 0.000498 = 0.498498. Its 0.002
     exit fee leaves debt 0.001502 and equity 0.496498. A's target
     never changes, so no buy exists and its inventory stays untouched.
     There are only two entries, B's exit, and A's final close. That
     close costs 0.002, leaving 0.494498. *)
  assert_close ~tolerance:1e-12 0.494498 (final_equity result);
  assert (result.margin_stats.Engine.refinances = 0);
  assert (result.margin_stats.Engine.clamps = 0);
  assert (List.length result.fills = 4)

let test_residual_debt_does_not_force_refinance () =
  let fee_asset =
    [| bar "2020-01-01" 100. 100.;
       bar "2020-01-02" 0.1 0.1;
       bar "2020-01-03" 0.1 0.1 |]
  in
  let flat =
    [| bar "2020-01-01" 100. 100.;
       bar "2020-01-02" 100. 100.;
       bar "2020-01-03" 100. 100. |]
  in
  let fee_costs : Engine.costs =
    { fee_bps = 0.; tax_bps = 0.; slip_bps = 0.; min_fee = 20.;
      per_share_sell_fee = 0.; per_share_sell_cap = 0. }
  in
  let margin : Engine.margin =
    { financing_rate = 0.; maintenance_override = Some 0.;
      ratios = [| 0.6; 0.6; 0.6 |]; loan_term_months = None }
  in
  let result =
    Engine.run ~profile:tw_profile
      [| ("tw/A", fee_asset); ("tw/B", flat); ("tw/C", flat) |]
      { Engine.targets =
          [| [| 0.5; 0.; 0. |];
             [| 0.5; 0.5; 0.459 /. 0.497499 |];
             [| 0.; 0.; 0.1 /. 0.497499 |] |] }
      [| fee_costs; zero_costs; zero_costs |] ~margin
      ~capital:(Some 10000.) ~fill:Engine.Close_same
  in
  (* A's 0.002 entry fee gives E1 = 0.998 and cash inventories
     A = B = 0.499. A then falls to 0.000499 and exits for 0.000499
     less another 0.002 fee, leaving debt 0.001501 while B keeps the
     account solvent at equity 0.497499. On bar 2 B sells 0.04 to
     0.459 and C buys 0.1 with minimum down payment 0.04. Available
     cash is 0.497499 - 0.459 + 0.001501 debt = 0.04, exactly enough.
     Thus no refinance or clamp is needed. The seven fills are two
     entries, A's exit, B's sale, C's buy, and the two final closes;
     final equity remains 0.497499. *)
  assert (result.margin_stats.Engine.refinances = 0);
  assert (result.margin_stats.Engine.clamps = 0);
  assert (List.length result.fills = 7);
  assert_close ~tolerance:1e-12 0.497499 (final_equity result)

let test_refinance_scale_in () =
  let bars =
    [| bar "2020-01-01" 100. 100.;
       bar "2020-01-02" 100. 100.;
       bar "2020-01-03" 100. 100. |]
  in
  let margin : Engine.margin =
    { financing_rate = 0.; maintenance_override = Some 0.; ratios = [| 0.6 |];
      loan_term_months = None }
  in
  let result =
    Engine.run ~profile:tw_profile [| ("tw/TEST", bars) |]
      { Engine.targets = [| [| 1.5; 2.; 2. |] |] }
      [| zero_costs |] ~margin ~capital:None ~fill:Engine.Close_same
  in
  (* Bar 0: cv = 2/3, mv = 5/6, loan = 0.5, cash = 0.
     Bar 1 buys 0.5 with no cash. Its 0.2 down payment is the shortage,
     so refinancing F = 0.2 / 0.6 = 1/3 leaves cv = 1/3 and moves
     1/3 to mv. The 0.5 buy is all-margin, leaving mv = 5/3 and
     loan = 1. This equals direct 2x entry and maintenance is 5/3. *)
  assert_close ~tolerance:1e-12 1. (final_equity result);
  assert (result.margin_stats.Engine.refinances = 1);
  (match result.margin_stats.Engine.min_maintenance with
   | Some ratio -> assert_close ~tolerance:1e-12 (5. /. 3.) ratio
   | None -> assert false);
  (match result.fills with
   | [_; refinance_sell; refinance_buy; _; _] ->
       assert_close ~tolerance:1e-12
         refinance_sell.Engine.from_e refinance_sell.Engine.to_e;
       assert_close ~tolerance:1e-12
         refinance_buy.Engine.from_e refinance_buy.Engine.to_e
   | _ -> assert false)

let test_refinance_costs () =
  let bars =
    [| bar "2020-01-01" 100. 100.;
       bar "2020-01-02" 100. 100.;
       bar "2020-01-03" 100. 100. |]
  in
  let costs : Engine.costs =
    { fee_bps = 100.; tax_bps = 0.; slip_bps = 0.; min_fee = 0.;
      per_share_sell_fee = 0.; per_share_sell_cap = 0. }
  in
  let margin : Engine.margin =
    { financing_rate = 0.; maintenance_override = Some 0.; ratios = [| 0.6 |];
      loan_term_months = None }
  in
  let result =
    Engine.run ~profile:tw_profile [| ("tw/TEST", bars) |]
      { Engine.targets = [| [| 1.5; 2.; 2. |] |] }
      [| costs |] ~margin ~capital:None ~fill:Engine.Close_same
  in
  (* Entry solves E1 = 1 - 0.01*1.5*E1, so E1 = 200/203.
     On scale-in, let C be total bar-1 cost, E2 = E1-C, and
     B = 2*E2 - 1.5*E1 = 0.5*E1 - 2*C. Refinancing F must fund
     the down payment and costs: 0.6*F = 0.4*B + C. Since the
     normal buy and both refinance legs cost C = 0.01*B + 0.02*F,
     solving gives C = 7*E1/608, E2 = 601*E1/608,
     B = 145*E1/304, and F = 205*E1/608. The final 1% sell fee
     leaves 0.98*E2. *)
  let entry_equity = 200. /. 203. in
  let scale_in_equity = entry_equity *. 601. /. 608. in
  assert_close ~tolerance:1e-12
    (0.98 *. scale_in_equity) (final_equity result);
  assert (result.margin_stats.Engine.refinances = 1);
  assert (result.margin_stats.Engine.clamps = 0);
  assert (List.length result.fills = 5);
  (match result.margin_stats.Engine.min_maintenance with
   | Some ratio -> assert_close ~tolerance:1e-12 (5. /. 3.) ratio
   | None -> assert false)

let test_refinance_order_independence () =
  let flat price =
    [| bar "2020-01-01" price price;
       bar "2020-01-02" price price |]
  in
  let margin : Engine.margin =
    { financing_rate = 0.; maintenance_override = Some 0.;
      ratios = [| 0.6; 0.6 |]; loan_term_months = None }
  in
  let run assets targets =
    Engine.run ~profile:tw_profile assets { Engine.targets = targets }
      [| zero_costs; zero_costs |] ~margin ~capital:None
      ~fill:Engine.Close_same
  in
  let result_ab =
    run [| ("tw/A", flat 100.); ("tw/B", flat 50.) |]
      [| [| 0.5; 1. |]; [| 0.5; 0.5 |] |]
  in
  let result_ba =
    run [| ("tw/B", flat 50.); ("tw/A", flat 100.) |]
      [| [| 0.5; 0.5 |]; [| 0.5; 1. |] |]
  in
  (* Bar 0 is fully cash-funded: cv_A = cv_B = 0.5. Bar 1 buys 0.5
     of A all-margin, needing S = 0.2. Equal refinance weights give
     F_A = F_B = 0.1 / 0.6 = 1/6. Loans are 0.1, 0.1, and 0.3
     on A's new buy: total 0.5. Margin value is 5/6, so maintenance
     is 5/3 in either declaration order. *)
  assert_close ~tolerance:1e-15
    (final_equity result_ab) (final_equity result_ba);
  assert_close ~tolerance:1e-12 1. (final_equity result_ab);
  assert (result_ab.margin_stats.Engine.refinances = 1);
  assert (result_ba.margin_stats.Engine.refinances = 1);
  assert (result_ab.margin_stats.Engine.clamps = 0);
  assert (result_ba.margin_stats.Engine.clamps = 0);
  let refinance_stocks result =
    result.Engine.fills
    |> List.filter
         (fun fill -> fill.Engine.from_e = fill.Engine.to_e)
    |> List.map (fun fill -> fill.Engine.stock)
    |> List.sort String.compare
  in
  let expected_refinance_stocks =
    ["tw/A"; "tw/A"; "tw/B"; "tw/B"]
  in
  assert (refinance_stocks result_ab = expected_refinance_stocks);
  assert (refinance_stocks result_ba = expected_refinance_stocks);
  (match result_ab.margin_stats.Engine.min_maintenance,
         result_ba.margin_stats.Engine.min_maintenance with
   | Some a, Some b ->
       assert_close ~tolerance:1e-15 a b;
       assert_close ~tolerance:1e-12 (5. /. 3.) a
   | _ -> assert false)

let test_margin_refinance_with_interest () =
  let bars =
    [| bar "2020-01-03" 100. 100.;
       bar "2020-01-06" 200. 200.;
       bar "2020-01-07" 200. 200. |]
  in
  let margin : Engine.margin =
    { financing_rate = 0.0635; maintenance_override = Some 0.;
      ratios = [| 0.6 |]; loan_term_months = None }
  in
  let result =
    Engine.run ~profile:tw_profile [| ("tw/TEST", bars) |]
      { Engine.targets = [| [| 2.; 1.8; 1.8 |] |] }
      [| zero_costs |] ~margin ~capital:None ~fill:Engine.Close_same
  in
  (* Friday entry has cv = 1/3, mv = 5/3, and loan = 1. At Monday's
     doubled close these are 2/3, 10/3, and 1, so equity is 3.
     Buying 1.8 * 3 - 4 = 1.4 needs a 0.56 down payment. Cash
     refinance capacity is (2/3)(0.6) = 0.4 and margin capacity is
     (10/3)(0.6 - 1/(10/3)) = 1, so the buy is fully funded.
     The old loan's T+2 start and the final-bar cap are both Tuesday.
     Monday's refinance tail is therefore empty. The new Monday loans
     also have their start capped at Tuesday, so final equity stays 3. *)
  assert_close ~tolerance:1e-12 3. (final_equity result);
  assert (result.margin_stats.Engine.refinances = 1);
  assert (result.margin_stats.Engine.clamps = 0);
  assert (List.length result.fills = 7)

let test_e1_drift_reversal () =
  (* The target drops 2.0 -> 1.8 while price doubles, but drifted
     exposure is only 4/3, so reaching 1.8 still requires a buy. *)
  let bars =
    [| bar "2020-01-01" 100. 100.;
       bar "2020-01-02" 200. 200. |]
  in
  let margin : Engine.margin =
    { financing_rate = 0.; maintenance_override = Some 0.; ratios = [| 0.6 |];
      loan_term_months = None }
  in
  let result =
    Engine.run ~profile:tw_profile [| ("tw/TEST", bars) |]
      { Engine.targets = [| [| 2.0; 1.8 |] |] }
      [| zero_costs |] ~margin ~capital:None ~fill:Engine.Close_same
  in
  (* Bar 0: cv = 1/3, mv = 5/3, loan = 1, cash = 0. Price doubling
     gives cv = 2/3, mv = 10/3, equity = 3. The 1.8 target buys 1.4
     with minimum down payment S = 0.56. Cash-refinance capacity is
     (2/3)*0.6 = 0.4. Margin-refinance freed rate is
     0.6 - 1/(10/3) = 0.3, capacity 1.0. Pro-rata capacity allocation
     gives F_cash = (0.56*0.4/1.4)/0.6 = 4/15 and
     F_margin = (0.56*1/1.4)/0.3 = 4/3. After the all-margin buy,
     cv = 2/5, mv = 5, loan = 12/5, cash = 0, and equity = 3.
     Final maintenance is 25/12, so the run minimum remains the
     entry's 5/3. One bar refinances, with two paired inventory legs. *)
  assert_close ~tolerance:1e-12 3. (final_equity result);
  assert (result.margin_stats.Engine.refinances = 1);
  assert (result.margin_stats.Engine.clamps = 0);
  assert (List.length result.fills = 7);
  (match result.margin_stats.Engine.min_maintenance with
   | Some ratio -> assert_close ~tolerance:1e-12 (5. /. 3.) ratio
   | None -> assert false)

let test_e1_sell_then_buy () =
  (* Sell asset A, buy asset B on the same bar. The buyer is declared
     first so only an explicit sell pass can fund it before allocation. *)
  let bars_a =
    [| bar "2020-01-01" 100. 100.;
       bar "2020-01-02" 100. 100. |]
  in
  let bars_b =
    [| bar "2020-01-01" 50. 50.;
       bar "2020-01-02" 50. 50. |]
  in
  let margin : Engine.margin =
    { financing_rate = 0.; maintenance_override = Some 0.;
      ratios = [| 0.6; 0.6 |]; loan_term_months = None }
  in
  let strategy : Engine.strategy =
    { targets = [| [| 0.; 1.0 |]; [| 1.5; 0. |] |] }
  in
  let result =
    Engine.run ~profile:tw_profile [| ("tw/B", bars_b); ("tw/A", bars_a) |] strategy
      [| zero_costs; zero_costs |] ~margin ~capital:None
      ~fill:Engine.Close_same
  in
  (* Bar 0 A is cv = 2/3, mv = 5/6, loan = 0.5, cash = 0.
     Bar 1 sells all 1.5 of A margin-first, repays 0.5, and leaves
     cash 1.0. That exactly cash-funds B's 1.0 buy, so no loan or
     refinancing remains. *)
  assert_close ~tolerance:1e-12 1.0 (final_equity result);
  assert (result.margin_stats.Engine.margin_call_dates = []);
  (match result.fills with
   | _ :: sell :: buy :: _ ->
       assert (sell.Engine.stock = "tw/A");
       assert (buy.Engine.stock = "tw/B");
       assert (sell.Engine.date = buy.Engine.date)
   | _ -> assert false)

let test_loan_order_independence () =
  (* At targets A = 0.9 and B = 0.3, minimum down payment is 0.48.
     The 0.52 surplus is allocated 0.39/0.13. Cash slices are
     0.65 and 13/60; margin slices are 0.25 and 1/12; loans are
     0.15 and 0.05. Thus total margin inventory is 1/3, total loan
     is 0.2, and maintenance is 5/3 in either declaration order. *)
  let flat price =
    [| bar "2020-01-01" price price; bar "2020-01-02" price price |]
  in
  let margin : Engine.margin =
    { financing_rate = 0.; maintenance_override = Some 0.;
      ratios = [| 0.6; 0.6 |]; loan_term_months = None }
  in
  let strategy : Engine.strategy =
    { targets = [| [| 0.9; 0.9 |]; [| 0.3; 0.3 |] |] }
  in
  let result_ab =
    Engine.run ~profile:tw_profile [| ("tw/A", flat 100.); ("tw/B", flat 50.) |] strategy
      [| zero_costs; zero_costs |] ~margin ~capital:None
      ~fill:Engine.Close_same
  in
  let strategy_ba : Engine.strategy =
    { targets = [| [| 0.3; 0.3 |]; [| 0.9; 0.9 |] |] }
  in
  let margin_ba : Engine.margin =
    { financing_rate = 0.; maintenance_override = Some 0.;
      ratios = [| 0.6; 0.6 |]; loan_term_months = None }
  in
  let result_ba =
    Engine.run ~profile:tw_profile [| ("tw/B", flat 50.); ("tw/A", flat 100.) |] strategy_ba
      [| zero_costs; zero_costs |] ~margin:margin_ba ~capital:None
      ~fill:Engine.Close_same
  in
  assert_close ~tolerance:1e-12
    (final_equity result_ab) (final_equity result_ba);
  (match result_ab.margin_stats.Engine.min_maintenance with
   | Some ratio -> assert_close ~tolerance:1e-12 (5. /. 3.) ratio
   | None -> assert false);
  (match result_ba.margin_stats.Engine.min_maintenance with
   | Some ratio -> assert_close ~tolerance:1e-12 (5. /. 3.) ratio
   | None -> assert false)
let test_sell_settlement_order_independence () =
  let a =
    [| bar "2020-01-01" 100. 100.;
       bar "2020-01-02" 20. 20.;
       bar "2020-01-03" 20. 20. |]
  in
  let b =
    [| bar "2020-01-01" 100. 100.;
       bar "2020-01-02" 200. 200.;
       bar "2020-01-03" 200. 200. |]
  in
  let margin : Engine.margin =
    { financing_rate = 0.365; maintenance_override = Some 0.;
      ratios = [| 0.6; 0.6 |]; loan_term_months = None }
  in
  let run assets targets =
    Engine.run ~profile:tw_profile assets { Engine.targets = targets }
      [| zero_costs; zero_costs |] ~margin ~capital:None
      ~fill:Engine.Close_same
  in
  let result_ab =
    run [| ("tw/A", a); ("tw/B", b) |]
      [| [| 1.25; 0.; 0. |]; [| 1.25; 0.; 0. |] |]
  in
  let result_ba =
    run [| ("tw/B", b); ("tw/A", a) |]
      [| [| 1.25; 0.; 0. |]; [| 1.25; 0.; 0. |] |]
  in
  (* Entry is all margin with loans 0.75/0.75. Both bar-0 loans start
     interest at T+2 on the final Jan 3 bar. The Jan 2 repayments also
     stop at their capped T+2 final bar, so the interest interval is
     empty. Values become 0.25 and 2.5; selling both leaves
     2.75 - 1.5 = 1.25, independent of declaration order. *)
  assert_close ~tolerance:1e-12 1.25 (final_equity result_ab);
  assert_close ~tolerance:1e-12
    (final_equity result_ab) (final_equity result_ba)


let test_call_settlement_order_independence () =
  let falling =
    [| bar "2020-01-01" 100. 100.;
       bar "2020-01-02" 20. 20.;
       bar "2020-01-03" 20. 20.;
       bar "2020-01-04" 20. 20. |]
  in
  let rising =
    [| bar "2020-01-01" 100. 100.;
       bar "2020-01-02" 120. 120.;
       bar "2020-01-03" 120. 120.;
       bar "2020-01-04" 120. 120. |]
  in
  let margin : Engine.margin =
    { financing_rate = 0.365; maintenance_override = Some 1.3;
      ratios = [| 0.6; 0.6 |]; loan_term_months = None }
  in
  let run assets =
    Engine.run ~profile:tw_profile assets
      { Engine.targets =
          [| [| 1.25; 1.25; 1.25; 1.25 |];
             [| 1.25; 1.25; 1.25; 1.25 |] |] }
      [| zero_costs; zero_costs |] ~margin ~capital:None
      ~fill:Engine.Close_same
  in
  let result_ab =
    run [| ("tw/A", falling); ("tw/B", rising) |]
  in
  let result_ba =
    run [| ("tw/B", rising); ("tw/A", falling) |]
  in
  (* Both bar-0 entries have loans 0.75 and T+2 starts on Jan 3. The
     Jan 3 call repayment stops at its capped T+2 on Jan 4, so one
     calendar day costs 1.5 * 0.365 / 365 = 0.0015. Call proceeds
     are 0.25 + 1.5 = 1.75, leaving 1.75 - 1.5 - 0.0015 = 0.2485.
     No loan remains to accrue after the call. *)
  assert_close ~tolerance:1e-12 0.2485 (final_equity result_ab);
  assert_close ~tolerance:1e-12
    (final_equity result_ab) (final_equity result_ba)

let test_loan_sell_then_buy () =
  (* On the same bar, sell A margin-first and use its net proceeds
     to cash-fund B before considering any new margin purchase. *)
  let bars_a =
    [| bar "2020-01-01" 100. 100.;
       bar "2020-01-02" 100. 100. |]
  in
  let bars_b =
    [| bar "2020-01-01" 50. 50.;
       bar "2020-01-02" 50. 50. |]
  in
  let margin : Engine.margin =
    { financing_rate = 0.; maintenance_override = Some 0.;
      ratios = [| 0.6; 0.6 |]; loan_term_months = None }
  in
  (* Bar 0 A is cv = 2/3, mv = 5/6, loan = 0.5, cash = 0.
     Bar 1 sells 1.5, repays 0.5, and leaves cash 1.0, which exactly
     funds B's 1.0 buy. No loan remains after the switch. *)
  let strategy : Engine.strategy =
    { targets = [| [| 1.5; 0. |]; [| 0.; 1.0 |] |] }
  in
  let result =
    Engine.run ~profile:tw_profile [| ("tw/A", bars_a); ("tw/B", bars_b) |] strategy
      [| zero_costs; zero_costs |] ~margin ~capital:None
      ~fill:Engine.Close_same
  in
  (* Bar 0 maintenance is (5/6)/0.5 = 5/3. Bar 1 has only B's
     cash inventory, so no loan exists; the historical minimum stays. *)
  assert_close ~tolerance:1e-12 1. (final_equity result);
  assert (result.margin_stats.Engine.margin_call_dates = []);
  assert (result.margin_stats.Engine.refinances = 0);
  (match result.margin_stats.Engine.min_maintenance with
   | Some ratio -> assert_close ~tolerance:1e-12 (5. /. 3.) ratio
   | None -> assert false)


let test_interest_settlement_window () =
  let bars =
    [| bar "2020-01-06" 100. 100.;
       bar "2020-01-07" 100. 100.;
       bar "2020-01-08" 100. 100.;
       bar "2020-01-09" 100. 100.;
       bar "2020-01-10" 100. 100.;
       bar "2020-01-13" 100. 100. |]
  in
  let margin : Engine.margin =
    { financing_rate = 0.365; maintenance_override = Some 0.;
      ratios = [| 0.6 |]; loan_term_months = None }
  in
  let result =
    Engine.run ~profile:tw_profile [| ("tw/TEST", bars) |]
      { Engine.targets = [| [| 2.; 2.; 2.; 0.; 0.; 0. |] |] }
      [| zero_costs |] ~margin ~capital:None ~fill:Engine.Close_same
  in
  (* The bar-0 loan is 1. Its T+2 start is Wed 2020-01-08. The
     bar-3 repayment stops at T+2 on Mon 2020-01-13. Five calendar
     days accrue at 0.365 / 365 = 0.001 per day, so equity is 0.995. *)
  assert_close ~tolerance:1e-12 0.995 (final_equity result);
  assert (result.margin_stats.Engine.refinances = 0)

let test_margin_term_rollover () =
  let bars =
    [| bar "2020-08-31" 100. 100.;
       bar "2020-09-01" 100. 100.;
       bar "2020-09-02" 100. 100.;
       bar "2022-02-25" 100. 100.;
       bar "2022-02-28" 100. 100.;
       bar "2023-08-25" 100. 100. |]
  in
  let margin : Engine.margin =
    { financing_rate = 0.; maintenance_override = Some 0.;
      ratios = [| 0.6 |]; loan_term_months = Some 18 }
  in
  let result =
    Engine.run ~profile:tw_profile [| ("tw/TEST", bars) |]
      { Engine.targets = [| Array.make (Array.length bars) 2. |] }
      [| zero_costs |] ~margin ~capital:None ~fill:Engine.Close_same
  in
  (* The bar-0 2x entry is cv = 1/3, mv = 5/3, and loan = 1.
     Aug 31 + 18 months clamps to Feb 28. The free rollover sells
     mv = 5/3, repays 1, and uses the freed 2/3 as the new down
     payment. It restores mv = 5/3 and loan = 1, so equity stays 1.
     The reset loan matures on Aug 28, after the final Aug 25 bar. *)
  assert_close ~tolerance:1e-12 1. (final_equity result);
  assert (result.margin_stats.Engine.refinances = 1);
  (match result.fills with
   | [entry; roll_sell; roll_buy; close] ->
       assert (entry.Engine.date = "2020-08-31");
       assert (roll_sell.Engine.date = "2022-02-28");
       assert (roll_buy.Engine.date = "2022-02-28");
       assert (close.Engine.date = "2023-08-25");
       assert_close ~tolerance:1e-12 2. roll_sell.Engine.from_e;
       assert_close ~tolerance:1e-12 (1. /. 3.) roll_sell.Engine.to_e;
       assert_close ~tolerance:1e-12 (1. /. 3.) roll_buy.Engine.from_e;
       assert_close ~tolerance:1e-12 2. roll_buy.Engine.to_e
   | _ -> assert false)

let test_margin_term_underwater_partial () =
  let bars =
    [| bar "2020-08-31" 100. 100.;
       bar "2020-09-01" 100. 100.;
       bar "2020-09-02" 100. 100.;
       bar "2022-02-25" 100. 100.;
       bar "2022-02-28" 80. 80.;
       bar "2022-03-01" 80. 80. |]
  in
  let margin : Engine.margin =
    { financing_rate = 0.; maintenance_override = Some 0.;
      ratios = [| 0.6 |]; loan_term_months = Some 18 }
  in
  let result =
    Engine.run ~profile:tw_profile [| ("tw/TEST", bars) |]
      { Engine.targets = [| Array.make (Array.length bars) 1.5 |] }
      [| zero_costs |] ~margin ~capital:None ~fill:Engine.Close_same
  in
  (* Entry is cv = 2/3, mv = 5/6, loan = 1/2. At price 80 these
     become 8/15 and 2/3, so equity is 7/10. Selling the expired
     margin lot frees 2/3 - 1/2 = 1/6. A full margin rebuy needs
     (2/5)(2/3) = 4/15, hence only 5/8 is fundable. The engine
     rebuys (5/8)(2/3) = 5/12 with a 1/4 loan and sells 1/4
     outright. Final inventory is 8/15 + 5/12 = 19/20, so equity
     stays 19/20 - 1/4 = 7/10. *)
  assert_close ~tolerance:1e-12 (7. /. 10.) (final_equity result);
  assert (result.margin_stats.Engine.refinances = 1);
  (match result.fills with
   | [_; roll_sell; roll_buy; _] ->
       assert (roll_sell.Engine.date = "2022-02-28");
       assert (roll_buy.Engine.date = "2022-02-28");
       assert_close ~tolerance:1e-12 (12. /. 7.) roll_sell.Engine.from_e;
       assert_close ~tolerance:1e-12 (16. /. 21.) roll_sell.Engine.to_e;
       assert_close ~tolerance:1e-12 (16. /. 21.) roll_buy.Engine.from_e;
       assert_close ~tolerance:1e-12 (19. /. 14.) roll_buy.Engine.to_e
   | _ -> assert false);
  (* Before rollover, maintenance is (2/3) / (1/2) = 4/3. The
     partial rebuy resets it to (5/12) / (1/4) = 5/3. *)
  (match result.margin_stats.Engine.min_maintenance with
   | Some ratio -> assert_close ~tolerance:1e-12 (4. /. 3.) ratio
   | None -> assert false)

let test_margin_term_disabled () =
  let bars =
    [| bar "2020-08-31" 100. 100.;
       bar "2020-09-01" 100. 100.;
       bar "2020-09-02" 100. 100.;
       bar "2022-02-28" 100. 100.;
       bar "2023-08-28" 100. 100. |]
  in
  let run stock profile loan_term_months =
    let margin : Engine.margin =
      { financing_rate = 0.; maintenance_override = Some 0.;
        ratios = [| 0.6 |]; loan_term_months }
    in
    Engine.run ~profile [| (stock, bars) |]
      { Engine.targets = [| Array.make (Array.length bars) 2. |] }
      [| zero_costs |] ~margin ~capital:None ~fill:Engine.Close_same
  in
  let us = run "us/TEST" us_profile (Some 18) in
  let disabled = run "tw/TEST" tw_profile None in
  (* US ignores the configured 18-month term. None is the engine form
     of CLI term 0. Both flat holds therefore have only entry and
     force-close fills, no refinance, and unchanged equity 1. *)
  List.iter
    (fun result ->
      assert_close ~tolerance:1e-12 1. (final_equity result);
      assert (result.margin_stats.Engine.refinances = 0);
      assert (List.length result.fills = 2))
    [us; disabled]

let test_nested_cache_layout () =
  (* Per-symbol subdirectory: data/<market>/<SYMBOL>/<SYMBOL>.csv *)
  let root = Filename.temp_file "bt-test-nested-" "" in
  Sys.remove root;
  Unix.mkdir root 0o700;
  let tw = Filename.concat root "tw" in
  Unix.mkdir tw 0o700;
  let sym_dir = Filename.concat tw "NEST" in
  Unix.mkdir sym_dir 0o700;
  Fun.protect
    ~finally:(fun () ->
      Array.iter
        (fun name -> Sys.remove (Filename.concat sym_dir name))
        (Sys.readdir sym_dir);
      Unix.rmdir sym_dir;
      Unix.rmdir tw;
      Unix.rmdir root)
    (fun () ->
      let write name contents =
        let output = open_out (Filename.concat sym_dir name) in
        Fun.protect
          ~finally:(fun () -> close_out output)
          (fun () -> output_string output contents)
      in
      write "NEST.csv"
        "date,open,high,low,close,volume\n\
         2020-01-01,100,101,99,100,1000\n\
         2020-01-02,101,102,100,101,1100\n";
      write "NEST.div.csv" "date,factor\n";
      write "NEST.events.csv" "date,factor\n";
      write "NEST.cashdiv.csv" "ex_date,cash_per_share,pay_date\n";
      let loaded =
        Data.load_asset ~market:"tw" ~symbol:"NEST" ~from_:None
          ~to_:None ~data_dir:root
      in
      assert (Array.length loaded.Data.signal = 2);
      assert_close 100. loaded.Data.signal.(0).Data.c;
      assert_close 101. loaded.Data.signal.(1).Data.c)

let test_profile_of_market () =
  let tw = Engine.profile_of_market "tw" in
  assert (tw.Engine.interest_day_count = 365.);
  assert (tw.Engine.settlement_lag = 2);
  assert (tw.Engine.maintenance = Engine.Collateral_over_loan);
  assert (tw.Engine.default_financing_rate = 6.35);
  let us = Engine.profile_of_market "us" in
  assert (us.Engine.interest_day_count = 360.);
  assert (us.Engine.settlement_lag = 1);
  assert (us.Engine.maintenance = Engine.Equity_over_required);
  assert (us.Engine.default_financing_rate = 6.25);
  (try ignore (Engine.profile_of_market "xx"); assert false
   with Invalid_argument _ -> ())

let test_mixed_market_rejection () =
  (* Mixed-market runs are rejected regardless of leverage. *)
  let binary = locate ["_build/default/bin/bt.exe"; "../bin/bt.exe"] in
  let stderr_path = Filename.temp_file "bt-test-mix-" ".txt" in
  let run_args args =
    let command =
      String.concat " "
        (Filename.quote binary :: "run" ::
         List.map Filename.quote args
         @ [">/dev/null"; "2>" ^ Filename.quote stderr_path])
    in
    Sys.command command
  in
  Fun.protect
    ~finally:(fun () -> if Sys.file_exists stderr_path then Sys.remove stderr_path)
    (fun () ->
      (* Two strats from different markets. *)
      with_temp_strategy "stock \"tw/A\"\ntarget 1.0\n" (fun tw_path ->
        with_temp_strategy "stock \"us/B\"\ntarget 1.0\n" (fun us_path ->
          let code = run_args
            [tw_path; us_path; "--data-dir"; "nonexistent"; "--no-plot"] in
          assert (code = 2);
          assert (contains (read_file stderr_path) "all stocks must share one market")));
      (* TW strat with US baseline. *)
      with_temp_strategy "stock \"tw/A\"\ntarget 1.0\n" (fun tw_path ->
        let code = run_args
          [tw_path; "--baseline"; "us/SPY";
           "--data-dir"; "nonexistent"; "--no-plot"] in
        assert (code = 2);
        assert (contains (read_file stderr_path) "all stocks must share one market")))


let test_us_interest_day_count () =
  (* Same bars span Mon-Mon including a weekend.  TW (T+2, /365) and
     US (T+1, /360) must produce different equity.
     Rate 0.365: loan = 1.
     TW: settlement starts bar 2, accrues bars 3-5 = 5 calendar days.
       interest = 1 * 0.365 * 5 / 365 = 0.005, equity = 0.995.
     US: settlement starts bar 1, accrues bars 2-5 = 6 calendar days.
       interest = 1 * 0.365 * 6 / 360, equity = 1 - that. *)
  let bars =
    [| bar "2020-01-06" 100. 100.;
       bar "2020-01-07" 100. 100.;
       bar "2020-01-08" 100. 100.;
       bar "2020-01-09" 100. 100.;
       bar "2020-01-10" 100. 100.;
       bar "2020-01-13" 100. 100. |]
  in
  let margin : Engine.margin =
    { financing_rate = 0.365; maintenance_override = Some 0.;
      ratios = [| 0.6 |]; loan_term_months = None }
  in
  let tw_result =
    Engine.run ~profile:tw_profile [| ("tw/TEST", bars) |]
      { Engine.targets = [| Array.make 6 2. |] }
      [| zero_costs |] ~margin ~capital:None ~fill:Engine.Close_same
  in
  let us_result =
    Engine.run ~profile:us_profile [| ("us/TEST", bars) |]
      { Engine.targets = [| Array.make 6 2. |] }
      [| zero_costs |] ~margin ~capital:None ~fill:Engine.Close_same
  in
  assert_close ~tolerance:1e-12 0.995 (final_equity tw_result);
  let us_expected = 1. -. 0.365 *. 6. /. 360. in
  assert_close ~tolerance:1e-12 us_expected (final_equity us_result);
  (* The /360 convention gives a higher daily rate, so US equity is lower. *)
  assert (final_equity us_result < final_equity tw_result)

let test_us_default_costs () =
  (* US defaults: zero commission, SEC fee sells only, FINRA TAF. *)
  let us = Engine.default_costs ~market:"us" ~symbol:"SPY" in
  assert (us.Engine.fee_bps = 0.);
  assert (us.Engine.tax_bps = 0.206);
  assert (us.Engine.slip_bps = 0.);
  assert (us.Engine.min_fee = 0.);
  assert (us.Engine.per_share_sell_fee = 0.000195);
  assert (us.Engine.per_share_sell_cap = 9.79);
  (* TW: TAF fields are zero. *)
  let tw = Engine.default_costs ~market:"tw" ~symbol:"0050" in
  assert (tw.Engine.per_share_sell_fee = 0.);
  assert (tw.Engine.per_share_sell_cap = 0.)

let test_taf_per_share_charge () =
  (* Sell 1000 shares at $10.  TAF raw = 1000 * 0.000195 = $0.195.
     Rounded up to cent = $0.20.  Floor $0.01, cap $9.79 -> $0.20.
     As fraction of $10000 portfolio = 0.00002. *)
  let bars =
    [| bar "2020-01-01" 10. 10.; bar "2020-01-02" 10. 10. |]
  in
  let costs : Engine.costs =
    { fee_bps = 0.; tax_bps = 0.; slip_bps = 0.; min_fee = 0.;
      per_share_sell_fee = 0.000195; per_share_sell_cap = 9.79 }
  in
  let result =
    Engine.run ~profile:us_profile [| ("us/TEST", bars) |]
      { Engine.targets = [| [| 1.; 0. |] |] }
      [| costs |] ~margin:(no_margin 1) ~capital:(Some 10000.)
      ~fill:Engine.Close_same
  in
  (* Entry has no cost (buy, TAF is sells only).
     Exit: TAF $0.20 / $10000 = 0.00002.  equity = 1 - 0.00002 = 0.99998. *)
  assert_close ~tolerance:1e-12 0.99998 (final_equity result)

let test_taf_floor () =
  (* 1 share at $10000 -> TAF raw = 0.000195.  Round up = $0.01.
     Floor max(0.01, 0.01) = $0.01. *)
  let bars =
    [| bar "2020-01-01" 10000. 10000.;
       bar "2020-01-02" 10000. 10000. |]
  in
  let costs : Engine.costs =
    { fee_bps = 0.; tax_bps = 0.; slip_bps = 0.; min_fee = 0.;
      per_share_sell_fee = 0.000195; per_share_sell_cap = 9.79 }
  in
  let result =
    Engine.run ~profile:us_profile [| ("us/TEST", bars) |]
      { Engine.targets = [| [| 1.; 0. |] |] }
      [| costs |] ~margin:(no_margin 1) ~capital:(Some 10000.)
      ~fill:Engine.Close_same
  in
  (* Shares = 1 * 10000 / 10000 = 1. raw = 0.000195 -> round up = $0.01.
     Floor $0.01.  fraction = 0.01 / 10000 = 0.000001. *)
  assert_close ~tolerance:1e-12 (1. -. 0.01 /. 10000.) (final_equity result)

let test_taf_cap () =
  (* 100000 shares at $1 -> TAF raw = $19.50.  Cap $9.79. *)
  let bars =
    [| bar "2020-01-01" 1. 1.; bar "2020-01-02" 1. 1. |]
  in
  let costs : Engine.costs =
    { fee_bps = 0.; tax_bps = 0.; slip_bps = 0.; min_fee = 0.;
      per_share_sell_fee = 0.000195; per_share_sell_cap = 9.79 }
  in
  let result =
    Engine.run ~profile:us_profile [| ("us/TEST", bars) |]
      { Engine.targets = [| [| 1.; 0. |] |] }
      [| costs |] ~margin:(no_margin 1) ~capital:(Some 100000.)
      ~fill:Engine.Close_same
  in
  (* Shares = 100000 / 1 = 100000. raw = $19.50.  Cap $9.79.
     fraction = 9.79 / 100000 = 0.0000979. *)
  assert_close ~tolerance:1e-12 (1. -. 9.79 /. 100000.) (final_equity result)

let test_taf_inactive_without_capital () =
  (* Without --capital, TAF fields have no effect. *)
  let bars =
    [| bar "2020-01-01" 10. 10.; bar "2020-01-02" 10. 10. |]
  in
  let costs : Engine.costs =
    { fee_bps = 0.; tax_bps = 0.; slip_bps = 0.; min_fee = 0.;
      per_share_sell_fee = 0.000195; per_share_sell_cap = 9.79 }
  in
  let result =
    Engine.run ~profile:us_profile [| ("us/TEST", bars) |]
      { Engine.targets = [| [| 1.; 0. |] |] }
      [| costs |] ~margin:(no_margin 1) ~capital:None
      ~fill:Engine.Close_same
  in
  (* No capital -> no TAF.  Zero bps -> equity stays 1. *)
  assert_close ~tolerance:1e-12 1. (final_equity result)

let test_taf_zero_for_tw () =
  (* TW defaults have per_share_sell_fee = 0.  Even with capital, no TAF. *)
  let bars =
    [| bar "2020-01-01" 10. 10.; bar "2020-01-02" 10. 10. |]
  in
  let tw_costs =
    Engine.default_costs ~market:"tw" ~symbol:"0050"
  in
  let costs : Engine.costs =
    { tw_costs with fee_bps = 0.; tax_bps = 0.; min_fee = 0. }
  in
  let result =
    Engine.run ~profile:tw_profile [| ("tw/TEST", bars) |]
      { Engine.targets = [| [| 1.; 0. |] |] }
      [| costs |] ~margin:(no_margin 1) ~capital:(Some 10000.)
      ~fill:Engine.Close_same
  in
  assert_close ~tolerance:1e-12 1. (final_equity result)


let test_taf_zero_cap_means_uncapped () =
  (* --per-share-fee with cap = 0 (TW default) must be uncapped, not
     clamped to $0.01.  1000 shares at $0.000195 = $0.195 -> $0.20. *)
  let bars =
    [| bar "2020-01-01" 10. 10.; bar "2020-01-02" 10. 10. |]
  in
  let costs : Engine.costs =
    { fee_bps = 0.; tax_bps = 0.; slip_bps = 0.; min_fee = 0.;
      per_share_sell_fee = 0.000195; per_share_sell_cap = 0. }
  in
  let result =
    Engine.run ~profile:tw_profile [| ("tw/TEST", bars) |]
      { Engine.targets = [| [| 1.; 0. |] |] }
      [| costs |] ~margin:(no_margin 1) ~capital:(Some 10000.)
      ~fill:Engine.Close_same
  in
  (* Uncapped: TAF = $0.20.  fraction = 0.20 / 10000 = 0.00002. *)
  assert_close ~tolerance:1e-12 0.99998 (final_equity result)


let test_us_tiered_maintenance () =
  (* Band 1: price > $6, tier = 30%.
     Entry at $10, target 2.0, ratio 0.5 -> mv = 2.0, loan = 1.0, equity = 1.0.
     required = 0.3 * 2.0 = 0.6.  ratio = equity / required = 1.0 / 0.6 = 5/3.
     No breach. *)
  let check price expected_ratio =
    let bars = [| bar "2020-01-01" price price;
                  bar "2020-01-02" price price |] in
    let margin : Engine.margin =
      { financing_rate = 0.; maintenance_override = None;
        ratios = [| 0.5 |]; loan_term_months = None }
    in
    let result =
      Engine.run ~profile:us_profile [| ("us/TEST", bars) |]
        { Engine.targets = [| [| 2.; 1. |] |] }
        [| zero_costs |] ~margin ~capital:None ~fill:Engine.Close_same
    in
    (match result.margin_stats.Engine.min_maintenance with
     | Some ratio -> assert_close ~tolerance:1e-12 expected_ratio ratio
     | None -> assert false)
  in
  (* > $6: required = 0.3 * 2.0 = 0.6; equity/required = 5/3 *)
  check 10. (5. /. 3.);
  (* $2.50-$6: required = 0.5 * 2.0 = 1.0; equity/required = 1.0 *)
  check 4. 1.;
  (* < $2.50: required = 1.0 * 2.0 = 2.0; equity/required = 0.5
     This band triggers a breach (equity 1.0 < required 2.0).
     The min_maintenance is 0.5 regardless. *)
  check 2. 0.5

let test_us_maintenance_breach () =
  (* Entry at $10, target 2.0, ratio 0.5 -> mv = 2.0, loan = 1.0.
     Bar 1: price drops to $7.  mv = 1.4, loan = 1.0, equity = 0.4.
     required = 0.3 * 1.4 = 0.42.  equity 0.4 < 0.42 -> breach.
     Margin call scheduled on 2020-01-02. *)
  let bars =
    [| bar "2020-01-01" 10. 10.;
       bar "2020-01-02" 7. 7.;
       bar "2020-01-03" 7. 7. |]
  in
  let margin : Engine.margin =
    { financing_rate = 0.; maintenance_override = None;
      ratios = [| 0.5 |]; loan_term_months = None }
  in
  let result =
    Engine.run ~profile:us_profile [| ("us/TEST", bars) |]
      { Engine.targets = [| [| 2.; 2.; 0. |] |] }
      [| zero_costs |] ~margin ~capital:None ~fill:Engine.Close_same
  in
  assert (result.margin_stats.Engine.margin_call_dates = ["2020-01-02"]);
  (* min_maintenance = equity/required = 0.4/0.42 = 20/21 at bar-1 close *)
  (match result.margin_stats.Engine.min_maintenance with
   | Some ratio -> assert_close ~tolerance:1e-12 (20. /. 21.) ratio
   | None -> assert false);
  assert_close ~tolerance:1e-12 0.4 (final_equity result)

let test_us_minimum_cure () =
  (* Entry at $10, target 2.0, ratio 0.5 -> mv = 2.0, loan = 1.0.
     Bar 1: price $7.  mv = 1.4, equity = 0.4, required = 0.42.  Breach.
     Bar 2: cure at open $7.  Sell fraction f = 1/21 of margin:
       sell_amount = 1.4/21, repay loan 1.0/21.
       After: mv = 1.4*20/21, loan = 20/21, cash = 0.4/21.
       equity = 0.4, required = 0.3 * 1.4*20/21 = 0.4.  Exactly restored.
     Position survives partially (margin still > 0). *)
  let bars =
    [| bar "2020-01-01" 10. 10.;
       bar "2020-01-02" 7. 7.;
       bar "2020-01-03" 7. 7. |]
  in
  let margin : Engine.margin =
    { financing_rate = 0.; maintenance_override = None;
      ratios = [| 0.5 |]; loan_term_months = None }
  in
  let result =
    Engine.run ~profile:us_profile [| ("us/TEST", bars) |]
      { Engine.targets = [| [| 2.; 2.; 2. |] |] }
      [| zero_costs |] ~margin ~capital:None ~fill:Engine.Close_same
  in
  (* Position survives: margin inventory > 0 after cure, no bankruptcy *)
  assert (not (List.exists (fun (_, eq) -> eq <= 0.) result.equity_curve));
  (* Cure sells the minimum amount; equity = 0.4 at bar-2 close *)
  assert_close ~tolerance:1e-12 0.4 (final_equity result);
  (* Exactly one margin call *)
  assert (result.margin_stats.Engine.margin_call_dates = ["2020-01-02"])

let test_us_maintenance_flat_override () =
  (* Same price drop as breach test, but --maintenance-ratio 20 (= 0.2)
     overrides the tiered table.
     required = 0.2 * 1.4 = 0.28.  equity = 0.4 >= 0.28 -> no breach. *)
  let bars =
    [| bar "2020-01-01" 10. 10.;
       bar "2020-01-02" 7. 7.;
       bar "2020-01-03" 7. 7. |]
  in
  let margin : Engine.margin =
    { financing_rate = 0.; maintenance_override = Some 0.2;
      ratios = [| 0.5 |]; loan_term_months = None }
  in
  let result =
    Engine.run ~profile:us_profile [| ("us/TEST", bars) |]
      { Engine.targets = [| [| 2.; 2.; 0. |] |] }
      [| zero_costs |] ~margin ~capital:None ~fill:Engine.Close_same
  in
  (* No margin call with the low flat override *)
  assert (result.margin_stats.Engine.margin_call_dates = []);
  (* min_maintenance = equity / (flat_rate * total_value)
     At bar 1: equity = 0.4, required = 0.2 * 1.4 = 0.28,
     ratio = 0.4 / 0.28 = 10/7. *)
  (match result.margin_stats.Engine.min_maintenance with
   | Some ratio -> assert_close ~tolerance:1e-12 (10. /. 7.) ratio
   | None -> assert false)

let test_tw_maintenance_override_none () =
  (* TW with maintenance_override = None uses the default 130% threshold.
     Same fixture as test_engine_margin_call: mv = 2.5, loan = 1.5.
     At bar 2: price 76, mv = 1.9, ratio = 1.9/1.5 = 1.2667 < 1.3 -> call.
     This verifies TW default behavior is intact with the option type. *)
  let bars =
    [| bar "2020-01-01" 100. 100.;
       bar "2020-01-02" 80. 80.;
       bar "2020-01-03" 76. 76.;
       bar "2020-01-06" 76. 90.;
       bar "2020-01-07" 90. 90. |]
  in
  let margin : Engine.margin =
    { financing_rate = 0.; maintenance_override = None;
      ratios = [| 0.6 |]; loan_term_months = None }
  in
  let result =
    Engine.run ~profile:tw_profile [| ("tw/TEST", bars) |]
      { Engine.targets = [| [| 2.5; 2.5; 2.5; 2.5; 1.0 |] |] }
      [| zero_costs |] ~margin ~capital:None ~fill:Engine.Close_same
  in
  assert_close ~tolerance:1e-12 0.4 (final_equity result);
  assert (result.margin_stats.Engine.margin_call_dates = ["2020-01-03"]);
  (match result.margin_stats.Engine.min_maintenance with
   | Some ratio -> assert_close ~tolerance:1e-12 (1.9 /. 1.5) ratio
   | None -> assert false)


let test_us_cure_interest_single_charge () =
  (* Entry at $10, target 2.0, ratio 0.5 -> mv = 2.0, loan = 1.0.
     financing_rate 36%/yr (/360) so 0.001 per day per unit principal.
     Bar 0 (2020-01-02 Thu): entry, no interest (T+1 lag).
     Bar 1 (2020-01-03 Fri): price $7, mv = 1.4. No interest (bar 1,
       settlement_start 1, 1>1 false). equity = 0.4.
       required = 0.42. Breach.
     Bar 2 (2020-01-06 Mon): 3 calendar days of interest:
       1.0 * 0.36 * 3/360 = 0.003.  equity = 0.397.
       Cure at open. Tail = 1 day (Mon->Tue) = 0.001.
       The sold fraction's settlement includes the tail.  The surviving
       lots keep their original interest and accrue normally.
     Bar 3 (2020-01-07 Tue): accrue 1 day. target goes to 0, sell all.
     The interest for the tail window must be charged exactly once.
     With the correct single-charge, final equity is strictly higher
     than the double-charge. *)
  let bars =
    [| bar "2020-01-02" 10. 10.;
       bar "2020-01-03" 7. 7.;
       bar "2020-01-06" 7. 7.;
       bar "2020-01-07" 7. 7. |]
  in
  let margin : Engine.margin =
    { financing_rate = 0.36; maintenance_override = None;
      ratios = [| 0.5 |]; loan_term_months = None }
  in
  let result =
    Engine.run ~profile:us_profile [| ("us/TEST", bars) |]
      { Engine.targets = [| [| 2.; 2.; 2.; 0. |] |] }
      [| zero_costs |] ~margin ~capital:None ~fill:Engine.Close_same
  in
  (* Tail interest for the cured fraction (1 day, 0.001 per unit
     principal) must not inflate the surviving lots.  The expected
     equity is derived under a single charge of the tail window.
     With the double-charge bug, equity is ~0.001*(1-f) lower. *)
  assert_close ~tolerance:1e-12 0.396 (final_equity result)


let test_cure_shortfall_preserves_liability () =
  (* Two US assets, ratio 0.5.  B (index 0) drops from $100 to $40,
     making it underwater (loan 0.5 > margin 0.4).  A (index 1) stays
     flat.  Equity stays positive at 0.4.
     The engine puts everything into margin (no cash_values) because
     sum(targets)=2 > 1.  Maintenance breach at bar-1 close triggers
     minimum_cure at bar-2 open.  B is processed first (index 0).
     Derivation:
       pre-cure: equity = 0 + 1.4 - 1.0 = 0.4
       total_margin = 0.4 + 1.0 = 1.4
       required = 0.3*0.4 + 0.3*1.0 = 0.42,  deficit = 0.02
       relief = 0.42 / 1.4 = 0.3,  sell_total = 0.02/0.3 = 1/15
       fraction = (1/15)/1.4 = 1/21
       sell_B = 1/21 * 0.4 = 4/210,  owed_B = 0.5/21 = 5/210
       payment_B = min(4/210, 5/210) = 4/210
       shortfall = 1/210  (must be routed to debt)
     Final equity after force-close: 0.4.
     Without fix: 17/42 (overstated by 1/210). *)
  let bars_a =
    [| bar "2020-01-01" 100. 100.;
       bar "2020-01-02" 100. 100.;
       bar "2020-01-03" 100. 100. |]
  in
  let bars_b =
    [| bar "2020-01-01" 100. 100.;
       bar "2020-01-02" 40. 40.;
       bar "2020-01-03" 40. 40. |]
  in
  let margin : Engine.margin =
    { financing_rate = 0.; maintenance_override = None;
      ratios = [| 0.5; 0.5 |]; loan_term_months = None }
  in
  let result =
    Engine.run ~profile:us_profile
      [| ("us/B", bars_b); ("us/A", bars_a) |]
      { Engine.targets = [| [| 1.; 1.; 1. |]; [| 1.; 1.; 1. |] |] }
      [| zero_costs; zero_costs |] ~margin ~capital:None
      ~fill:Engine.Close_same
  in
  assert (result.margin_stats.Engine.margin_call_dates = ["2020-01-02"]);
  (* Equity conservation: unpaid cure liability preserved as debt *)
  assert_close ~tolerance:1e-12 0.4 (final_equity result)


let test_us_cure_tail_aware () =
  (* Entry $10, target 2.0, ratio 0.5 -> mv = 2.0, loan = 1.0.
     financing_rate 36% -> 0.001/day on 360-day basis.
     Bar 1 ($7): equity = 0.4, required = 0.42.  Breach.
     Bar 2 cure: 3 days interest (Fri->Mon) = 0.003, equity = 0.397.
       Deficit = 0.023.  Tail = 1 day (Mon->Tue) = 0.001.
       Relief must subtract the tail-interest drain (0.001/0.7 per
       dollar of margin sold) so the cure is boundary-exact:
         relief = (0.21 - 0.001) / 0.7 = 0.209/0.7
       Without: relief = 0.3, fraction undershoots, second call.
       With: fraction = 0.023 / (0.209/0.7) / 0.7 exactly meets the
       maintenance requirement.
     Bar 3: target 0, exit.  Final equity = 0.7 - 0.304 = 0.396
       (total interest = 4 days at 0.001; independent of cure fraction
       because the shortfall from the settled fraction is repaid from
       proceeds when the remaining margin sells on bar 3). *)
  let bars =
    [| bar "2020-01-02" 10. 10.;
       bar "2020-01-03" 7. 7.;
       bar "2020-01-06" 7. 7.;
       bar "2020-01-07" 7. 7. |]
  in
  let margin : Engine.margin =
    { financing_rate = 0.36; maintenance_override = None;
      ratios = [| 0.5 |]; loan_term_months = None }
  in
  let result =
    Engine.run ~profile:us_profile [| ("us/TEST", bars) |]
      { Engine.targets = [| [| 2.; 2.; 2.; 0. |] |] }
      [| zero_costs |] ~margin ~capital:None ~fill:Engine.Close_same
  in
  (* Tail-aware cure: boundary-exact relief, no second call *)
  assert (result.margin_stats.Engine.margin_call_dates = ["2020-01-03"]);
  assert_close ~tolerance:1e-12 0.396 (final_equity result)


let test_alias_qualified_labels () =
  (* Two aliases for the same (market, symbol) must produce distinct
     alias-qualified labels; a single declaration stays bare. *)
  let shared_bars =
    [| bar "2020-01-01" 100. 100.;
       bar "2020-01-02" 100. 110.;
       bar "2020-01-03" 110. 110. |]
  in
  (* Duplicate-symbol: labels must carry #alias *)
  with_temp_strategy
    "stock \"tw/00685L\" as core\n\
     stock \"tw/00685L\" as trade\n\
     core.target 0.6\n\
     trade.target 0.4\n"
    (fun path ->
      let ast = Dsl.parse_file path in
      let stocks = Dsl.stocks_of ~filename:path ast in
      let labels = Dsl.labels_of_stocks stocks in
      assert (labels = ["tw/00685L#core"; "tw/00685L#trade"]);
      (* Engine.run with qualified labels: fills carry them *)
      let strategy =
        Dsl.compile_ast ast ~params:[]
          ~assets:[(Some "core", shared_bars); (Some "trade", shared_bars)]
      in
      let result =
        Engine.run ~profile:tw_profile
          [| ("tw/00685L#core", shared_bars);
             ("tw/00685L#trade", shared_bars) |]
          strategy [| zero_costs; zero_costs |]
          ~margin:(no_margin 2) ~capital:None ~fill:Engine.Close_same
      in
      let fill_stocks =
        List.map (fun (f : Engine.fill_event) -> f.stock) result.fills
      in
      assert (List.mem "tw/00685L#core" fill_stocks);
      assert (List.mem "tw/00685L#trade" fill_stocks));
  (* Single declaration: label stays bare *)
  with_temp_strategy
    "stock \"tw/00685L\"\ntarget 0.6\n"
    (fun path ->
      let ast = Dsl.parse_file path in
      let stocks = Dsl.stocks_of ~filename:path ast in
      let labels = Dsl.labels_of_stocks stocks in
      assert (labels = ["tw/00685L"]));
  (* Distinct symbols with aliases: each symbol once -> bare labels *)
  with_temp_strategy
    "stock \"tw/0050\" as etf50\n\
     stock \"tw/00632R\" as inverse\n\
     etf50.target 0.6\n\
     inverse.target 0.4\n"
    (fun path ->
      let ast = Dsl.parse_file path in
      let stocks = Dsl.stocks_of ~filename:path ast in
      let labels = Dsl.labels_of_stocks stocks in
      assert (labels = ["tw/0050"; "tw/00632R"]))

let test_alpaca_base_urls () =
  assert
    (Alpaca.base_url Alpaca.Paper = "https://paper-api.alpaca.markets");
  assert (Alpaca.base_url Alpaca.Live = "https://api.alpaca.markets")

let test_alpaca_clock_parse () =
  let actual = Alpaca.parse_clock (alpaca_fixture "clock.json") in
  (* Each expected field is copied from the documented clock response. *)
  let expected : Alpaca.clock_t =
    { timestamp = "2025-06-24T14:15:22-04:00";
      is_open = true;
      next_open = "2025-06-25T09:30:00-04:00";
      next_close = "2025-06-24T16:00:00-04:00" }
  in
  assert (actual = expected)

let test_alpaca_account_parse () =
  let actual = Alpaca.parse_account (alpaca_fixture "account.json") in
  (* "103820.56" parses exactly to the expected decimal float. *)
  let expected : Alpaca.account_t =
    { equity = 103820.56;
      status = "ACTIVE";
      trading_blocked = false;
      account_number = "010203ABCD" }
  in
  assert (actual = expected)

let test_alpaca_position_parse () =
  (* The documented quantity string "5" parses to 5 whole shares. *)
  assert
    (Alpaca.parse_position_qty ~http_code:200
       (alpaca_fixture "position.json") = 5.);
  (* Alpaca uses HTTP 404 to represent no open position. *)
  assert (Alpaca.parse_position_qty ~http_code:404 "" = 0.)

let test_alpaca_order_parse () =
  let actual = Alpaca.parse_order (alpaca_fixture "order.json") in
  (* The unfilled example reports string quantity "0" and null fill price. *)
  let expected : Alpaca.order_t =
    { id = "7b08df51-c1ac-453c-99f9-323a5f075f0d";
      status = "accepted";
      filled_avg_price = None;
      filled_qty = 0. }
  in
  let () = assert (actual = expected) in
  let filled =
    Alpaca.parse_order
      {|{"id":"filled-id","status":"filled","filled_avg_price":"172.55","filled_qty":"2"}|}
  in
  (* Decimal fill strings "172.55" and "2" parse to the reported fill values. *)
  let filled_expected : Alpaca.order_t =
    { id = "filled-id";
      status = "filled";
      filled_avg_price = Some 172.55;
      filled_qty = 2. }
  in
  assert (filled = filled_expected)

let test_alpaca_snapshot_parse () =
  let actual = Alpaca.parse_snapshot (alpaca_fixture "snapshot.json") in
  (* Dates are the dailyBar and prevDailyBar timestamp prefixes.
     OHLCV comes from dailyBar; latest comes from latestTrade.p. *)
  let expected : Alpaca.snapshot_t =
    { day_date = "2022-08-16";
      prev_day_date = "2022-08-15";
      day_open = 172.62;
      day_high = 173.71;
      day_low = 171.6618;
      latest = 172.55;
      day_volume = 56457696. }
  in
  assert (actual = expected)

let test_engine_effective_targets () =
  let ratio =
    (Engine.profile_of_market "us").Engine.default_financing_ratio
  in
  let effective target =
    match
      Engine.effective_targets ~financing_ratios:[| ratio |] [| target |]
    with
    | [| value |], _ -> value
    | _ -> assert false
  in
  assert_close 0.5 ratio;
  assert_close 0. (effective (-1.));
  assert_close 0. (effective Float.nan);
  assert_close 2. (effective 2.5);
  assert_close 1.994 (effective 1.994)

let test_live_pure_decisions () =
  (* 1.994 * 10000 / 500 = 39.88, truncated toward zero to 39;
     the negative case truncates -39.88 toward zero to -39. *)
  assert (Live.desired_shares ~target:1.994 ~equity:10000. ~price:500. = 39);
  assert (Live.desired_shares ~target:(-1.994) ~equity:10000. ~price:500. = -39);
  (* Round 5.4 to 5 and 5.6 to 6 before subtracting from 39. *)
  assert (Live.order_delta ~desired:39 ~held:5.4 = 34);
  assert (Live.order_delta ~desired:39 ~held:5.6 = 33);
  (* One share at $0.99 is below $1 for either side; at $1 it is not. *)
  assert (Live.below_threshold ~delta:1 ~price:0.99);
  assert (Live.below_threshold ~delta:(-1) ~price:0.99);
  assert (not (Live.below_threshold ~delta:1 ~price:1.));
  (* The identifier is the fixed prefix, symbol, and session date. *)
  assert
    (Live.client_order_id ~symbol:"SPY" ~date:"2025-06-24"
     = "bt-SPY-2025-06-24");
  (* Matching the prior session is fresh; an older cache is stale. *)
  assert
    (Live.cache_is_fresh ~last_cached:"2025-06-23"
       ~prev_trading_day:"2025-06-23");
  assert
    (not
       (Live.cache_is_fresh ~last_cached:"2025-06-20"
          ~prev_trading_day:"2025-06-23"));
  assert
    (Live.snapshot_session ~session_date:"2025-06-24"
       ~provisional_date:"2025-06-23"
     = `Skip
         "stale snapshot session: provisional 2025-06-23 does not match clock \
          session 2025-06-24");
  assert
    (Live.snapshot_session ~session_date:"2025-06-24"
       ~provisional_date:"2025-06-24"
     = `Proceed);
  let snapshot : Alpaca.snapshot_t =
    { day_date = "2025-06-24";
      prev_day_date = "2025-06-23";
      day_open = 500.;
      day_high = 505.;
      day_low = 498.;
      latest = 503.;
      day_volume = 12345. }
  in
  let expected : Data.bar =
    (* Every bar field maps directly from the snapshot's current session. *)
    { date = "2025-06-24";
      o = 500.;
      h = 505.;
      l = 498.;
      c = 503.;
      v = 12345. }
  in
  assert (Live.provisional_bar snapshot = expected);
  let override =
    Live.override_snapshot ~session_date:"2025-06-24"
      ~prev_day_date:"2025-06-23" ~price:650.
  in
  let expected_override : Alpaca.snapshot_t =
    { day_date = "2025-06-24";
      prev_day_date = "2025-06-23";
      day_open = 650.;
      day_high = 650.;
      day_low = 650.;
      latest = 650.;
      day_volume = 0. }
  in
  assert (override = expected_override);
  assert
    (Live.snapshot_session ~session_date:"2025-06-24"
       ~provisional_date:override.day_date
     = `Proceed);
  (* 1.0 * $100000 / $650 = 153.846..., truncated to 153 shares. *)
  assert
    (Live.decide_action ~symbol:"SPY" ~date:override.day_date
       ~target:1. ~equity:100000. ~price:override.latest ~held:0.
     = Live.Order
         { side = `Buy;
           qty = 153;
           id = "bt-SPY-2025-06-24" })

let test_live_schedule () =
  let close = "2025-06-24T16:00:00-04:00" in
  assert
    (Live.can_submit_moc ~now:"2025-06-24T15:49:59-04:00"
       ~next_close:close);
  assert
    (not
       (Live.can_submit_moc ~now:"2025-06-24T15:50:00-04:00"
          ~next_close:close));
  assert
    (Live.next_actions ~now:"2025-06-24T15:44:59-04:00" ~next_close:close
     = `Sleep_until "2025-06-24T15:45:00-04:00");
  assert
    (Live.next_actions ~now:"2025-06-24T15:45:00-04:00" ~next_close:close
     = `Decide);
  assert
    (Live.next_actions ~now:"2025-06-24T15:49:59-04:00" ~next_close:close
     = `Decide);
  assert
    (Live.next_actions ~now:"2025-06-24T15:50:00-04:00" ~next_close:close
     = `Submit_window);
  assert
    (Live.next_actions ~now:"2025-06-24T16:00:00-04:00" ~next_close:close
     = `Post_close);
  let early_close = "2025-11-28T13:00:00-05:00" in
  assert
    (Live.next_actions ~now:"2025-11-28T12:44:00-05:00"
       ~next_close:early_close
     = `Sleep_until "2025-11-28T12:45:00-05:00");
  assert
    (Live.next_actions ~now:"2025-11-28T12:50:00-05:00"
       ~next_close:early_close
     = `Submit_window)

let test_live_startup_guard () =
  let account : Alpaca.account_t =
    { equity = 10000.;
      status = "ACTIVE";
      trading_blocked = false;
      account_number = "paper-account" }
  in
  assert (Live.startup_ok account = Ok ());
  assert
    (Live.startup_ok { account with status = "ACCOUNT_CLOSED" }
     = Error "account status is ACCOUNT_CLOSED");
  assert
    (Live.startup_ok { account with trading_blocked = true }
     = Error "account trading is blocked")

let test_live_commands_reject_tw () =
  let binary = locate ["_build/default/bin/bt.exe"; "../bin/bt.exe"] in
  let stderr_path = Filename.temp_file "bt-test-tw-equity-" ".txt" in
  Fun.protect
    ~finally:(fun () ->
      if Sys.file_exists stderr_path then Sys.remove stderr_path)
    (fun () ->
      with_temp_strategy "stock \"tw/00685L\"\ntarget 1.0\n" (fun path ->
        let command =
          String.concat " "
            [ Filename.quote binary;
              "target";
              Filename.quote path;
              ">/dev/null";
              "2>" ^ Filename.quote stderr_path ]
        in
        (* Omitting required TW simulation equity is a CLI usage error, exit 2. *)
        let () = assert (Sys.command command = 2) in
        match String.split_on_char '\n' (read_file stderr_path) with
        (* The first stderr line states the missing-equity contract verbatim. *)
        | first :: _ -> assert (first = "simulation mode requires --equity")
        | [] -> assert false))

let test_tw_live_rejects_production_equity () =
  let binary = locate ["_build/default/bin/bt.exe"; "../bin/bt.exe"] in
  let stderr_path = Filename.temp_file "bt-test-tw-live-equity-" ".txt" in
  Fun.protect
    ~finally:(fun () ->
      if Sys.file_exists stderr_path then Sys.remove stderr_path)
    (fun () ->
      with_temp_strategy "stock \"tw/00685L\"\ntarget 1.0\n" (fun path ->
        let command =
          String.concat " "
            [ Filename.quote binary;
              "target";
              Filename.quote path;
              "--live";
              "--equity";
              "1000000";
              ">/dev/null";
              "2>" ^ Filename.quote stderr_path ]
        in
        (* Supplying simulation equity with --live is a CLI usage error, exit 2. *)
        let () = assert (Sys.command command = 2) in
        match String.split_on_char '\n' (read_file stderr_path) with
        | first :: _ ->
            (* The first stderr line states the production-equity contract. *)
            assert (first = "--equity is not allowed in production")
        | [] -> assert false))

let test_target_rejects_invalid_provisional_close () =
  let binary = locate ["_build/default/bin/bt.exe"; "../bin/bt.exe"] in
  List.iter
    (fun price ->
      let stderr_path =
        Filename.temp_file "bt-test-provisional-close-" ".txt"
      in
      Fun.protect
        ~finally:(fun () ->
          if Sys.file_exists stderr_path then Sys.remove stderr_path)
        (fun () ->
          with_temp_strategy "stock \"us/SPY\"\ntarget 1.0\n" (fun path ->
            let command =
              String.concat " "
                [ Filename.quote binary;
                  "target";
                  Filename.quote path;
                  "--provisional-close";
                  Filename.quote price;
                  ">/dev/null";
                  "2>" ^ Filename.quote stderr_path ]
            in
            assert (Sys.command command = 2);
            let stderr = read_file stderr_path in
            assert
              (contains stderr
                 "target: --provisional-close must be a positive float");
            assert (not (contains stderr "target: target:")))))
    (* Zero, negatives, NaN, and infinity are not positive finite prices. *)
    ["0"; "-1"; "nan"; "inf"];
  let output_path = Filename.temp_file "bt-test-target-help-" ".txt" in
  Fun.protect
    ~finally:(fun () ->
      if Sys.file_exists output_path then Sys.remove output_path)
    (fun () ->
      let command =
        String.concat " "
          [ Filename.quote binary;
            "target";
            "--help";
            ">" ^ Filename.quote output_path ]
      in
      assert (Sys.command command = 0);
      assert (contains (read_file output_path) "--provisional-close"));
  (* The daemon parser rejects the target-only override before any API call. *)
  let stderr_path = Filename.temp_file "bt-test-live-override-" ".txt" in
  Fun.protect
    ~finally:(fun () ->
      if Sys.file_exists stderr_path then Sys.remove stderr_path)
    (fun () ->
      with_temp_strategy "stock \"us/SPY\"\ntarget 1.0\n" (fun path ->
        let command =
          String.concat " "
            [ Filename.quote binary;
              "live";
              Filename.quote path;
              "--provisional-close";
              "650";
              ">/dev/null";
              "2>" ^ Filename.quote stderr_path ]
        in
        assert (Sys.command command = 2);
        assert (contains (read_file stderr_path) "unknown option")))

let test_minute_data () =
  (* UTC year boundaries end Dec 31 at 23:59:59 and resume Jan 1 at 00:00:00.
     Regular ET sessions cannot cross them; the first and final bounds stay exact. *)
  let () = assert (Data.year_ranges
    ~start:"2023-12-29T15:59:00-05:00" ~end_:"2024-07-01T13:30:00Z" =
    ["2023-12-29T15:59:00-05:00", "2023-12-31T23:59:59Z";
     "2024-01-01T00:00:00Z", "2024-07-01T13:30:00Z"]) in
  (* US DST begins on March's second Sunday and ends on November's first. *)
  let () =
    List.iter (fun (date, offset) -> assert (Data.et_offset_minutes date = offset))
      ["2024-03-09", -300; "2024-03-10", -240;
       "2024-11-02", -240; "2024-11-03", -300]
  in
  let sessions : Data.session array =
    [| { date = "2024-01-02"; open_ = "09:30"; close = "16:00" };
       { date = "2024-11-29"; open_ = "09:30"; close = "13:00" } |]
  in
  let () = assert (Alpaca.parse_calendar (alpaca_fixture "calendar.json") = Array.to_list sessions) in
  let parse_sessions = Array.append sessions
    [| { Data.date = "2024-07-01"; open_ = "09:30"; close = "16:00" } |] in
  let parsed, token = Alpaca.parse_bars ~sessions:parse_sessions (alpaca_fixture "bars.json") in
  (* Winter: 14:30 UTC - 5h = 09:30 ET; summer: 13:30 UTC - 4h = 09:30 ET.
     Close is exclusive, holidays absent; early close retains 12:59, not 13:00. *)
  let () =
    assert (parsed =
      [{ Data.date = "2024-01-02T09:30"; o = 100.; h = 102.; l = 99.; c = 101.; v = 10. };
       { Data.date = "2024-07-01T09:30"; o = 150.; h = 152.; l = 149.; c = 151.; v = 20. };
       { Data.date = "2024-11-29T12:59"; o = 200.; h = 204.; l = 199.; c = 203.; v = 30. }])
  in
  (* Alpaca's null collection contains zero bars and has no next page. *)
  let () = assert (Alpaca.parse_bars ~sessions (alpaca_fixture "bars-empty.json") = ([], None)) in
  let () = assert (token = None) in
  let () = assert (Alpaca.parse_bars ~sessions {|{"bars":[],"next_page_token":"next"}|} = ([], Some "next")) in
  let () = assert_failure (fun () -> ignore (Alpaca.parse_bars ~sessions {|{"bars":[{"t":"bad"}]}|})) in
  with_temp_market "us" (fun data_dir _ ->
    let () = Data.write_calendar ~data_dir [sessions.(1); sessions.(0); sessions.(1)] in
    let () = assert (Data.read_calendar ~data_dir = sessions) in
    let corrected = { sessions.(1) with Data.close = "12:00" } in
    let () = Data.write_calendar ~data_dir [corrected] in
    (* Refresh replaces the matching date but retains the other session. *)
    let () = assert (Data.read_calendar ~data_dir = [|sessions.(0); corrected|]) in
    let () = Data.write_calendar ~data_dir [sessions.(1)] in
    let minute_dir = Filename.concat data_dir "us/SPY/1m" in
    let () = Data.mkdir_p minute_dir in
    let fixture =
      locate ["test/fixtures/minute/spy-2024-01-02.csv";
              "fixtures/minute/spy-2024-01-02.csv"]
    in
    let path = Filename.concat minute_dir "2024.csv" in
    let output = open_out path in
    let () = Fun.protect ~finally:(fun () -> close_out output)
      (fun () -> output_string output (read_file fixture)) in
    let bars = Data.read_minute_bars ~data_dir ~symbol:"SPY" ~from_:None ~to_:None in
    let () = assert (Array.length bars = 15) in
    let () = assert (Data.resample ~minutes:1 ~sessions bars == bars) in
    let resampled = Data.resample ~minutes:5 ~sessions bars in
    (* 09:30 bucket: O=100 H=106 L=99 C=105 V=1+2+3+4+5=15.
       09:35 bucket: O=105 H=111 L=104 C=110 V=6+7+8+9+10=40.
       09:40 partial: O=110 H=113 L=109 C=112 V=11+12=23.
       12:55 early-close bucket: O=200 H=204 L=198 C=203 V=10+20+30=60.
       Even with missing 12:55-56, its left edge stays anchored at 09:30. *)
    let () = assert (resampled =
      [| { Data.date = "2024-01-02T09:30"; o = 100.; h = 106.; l = 99.; c = 105.; v = 15. };
         { Data.date = "2024-01-02T09:35"; o = 105.; h = 111.; l = 104.; c = 110.; v = 40. };
         { Data.date = "2024-01-02T09:40"; o = 110.; h = 113.; l = 109.; c = 112.; v = 23. };
         { Data.date = "2024-11-29T12:55"; o = 200.; h = 204.; l = 198.; c = 203.; v = 60. } |]) in
    let () = assert_failure (fun () -> ignore (Data.resample ~minutes:0 ~sessions bars)) in
    let older = { bars.(0) with Data.date = "2023-12-29T15:59" } in
    let corrected = { bars.(0) with Data.c = 101.5 } in
    let () = Data.write_minute_bars ~data_dir ~symbol:"SPY" [corrected; older; corrected] in
    let all = Data.read_minute_bars ~data_dir ~symbol:"SPY" ~from_:None ~to_:None in
    (* One new year and one replacement: 15+1 rows, oldest first. *)
    let () = assert (Array.length all = 16 && all.(0) = older && all.(1) = corrected) in
    let () = assert (Data.read_minute_bars ~data_dir ~symbol:"SPY"
      ~from_:(Some "2024-01-02") ~to_:(Some "2024-01-02") =
      Array.sub all 1 12) in
    let () = assert (Data.read_minute_bars ~data_dir ~symbol:"SPY"
      ~from_:(Some "2024-01-02T09:31") ~to_:(Some "2024-01-02T09:32") =
      Array.sub all 2 2) in
    assert (Data.read_minute_bars ~data_dir ~symbol:"EMPTY" ~from_:None ~to_:None = [||]))

let test_bars_declaration () =
  let () =
    with_temp_strategy "bars 5m\n" (fun path ->
      let ast = Dsl.parse_file path in
      (* A five-minute declaration carries the integer 5, not a price expression. *)
      let () = assert (ast = [Ast.Bars 5]) in
      assert (Dsl.timeframe ast = Some 5))
  in
  let () =
    with_temp_strategy "target 1\n" (fun path ->
      (* No declaration means the daily timeframe remains implicit. *)
      assert (Dsl.timeframe (Dsl.parse_file path) = None))
  in
  let () =
    List.iter
      (fun source ->
        with_temp_strategy source (fun path ->
          match Dsl.parse_file path with
          | _ -> assert false
          | exception Failure message ->
              assert (contains message ": parse error")))
      ["bars 0m\n"; "bars 5\n"; "bars -5m\n"; "bars 1.5m\n";
       "bars 5h\n"; "bars 999999999999999999999999999999m\n"]
  in
  with_temp_strategy "bars 5m\nbars 1m\ntarget 1\n" (fun path ->
    let ast = Dsl.parse_file path in
    let rejects function_ =
      match function_ () with
      | _ -> assert false
      | exception Failure message ->
          assert (message = "duplicate bars declaration")
    in
    let () = rejects (fun () -> ignore (Dsl.timeframe ast)) in
    rejects (fun () ->
      ignore (Dsl.compile_ast ast ~params:[] ~assets:[None, sample_bars])))

let test_session_series () =
  let extra =
    ["since_open", [|0.; 5.; 10.; 15.; 20.|];
     "to_close", [|25.; 20.; 15.; 10.; 5.|]]
  in
  let () =
    with_temp_strategy
      "stock \"us/SPY\"\nbars 5m\ntarget num(since_open >= 5 and to_close > 10)\n"
      (fun path ->
        let ast = Dsl.parse_file path in
        let strategy =
          Dsl.compile_ast ~extra ast ~params:[] ~assets:[None, sample_bars]
        in
        (* Both gates hold only at elapsed minutes 5 and 10. *)
        let () = assert (strategy.Engine.targets = [|[|0.; 1.; 1.; 0.; 0.|]|]) in
        let compiled = Dsl.compile ~extra path ~params:[] sample_bars in
        assert (compiled.Engine.targets = strategy.Engine.targets))
  in
  let () =
    List.iter
      (fun name ->
        with_temp_strategy ("target " ^ name ^ "\n") (fun path ->
          match Dsl.compile path ~params:[] sample_bars with
          | _ -> assert false
          | exception Failure message ->
              assert (message =
                "since_open and to_close are available only under bt daytrade")))
      ["since_open"; "to_close"]
  in
  with_temp_strategy "target since_open\n" (fun path ->
    (* Five bars cannot consume a one-element injected series. *)
    match Dsl.compile ~extra:["since_open", [|0.|]] path ~params:[] sample_bars with
    | _ -> assert false
    | exception Invalid_argument _ -> ())

let test_bars_run_routing () =
  let binary = locate ["_build/default/bin/bt.exe"; "../bin/bt.exe"] in
  List.iter (fun command ->
    let stderr_path = Filename.temp_file "bt-test-bars-routing-" ".txt" in
    Fun.protect ~finally:(fun () -> Sys.remove stderr_path) (fun () ->
      with_temp_strategy "stock \"us/SPY\"\nbars 5m\ntarget 1\n" (fun path ->
        let invocation = String.concat " "
          [Filename.quote binary; command; Filename.quote path;
           ">/dev/null"; "2>" ^ Filename.quote stderr_path] in
        (* All daily entry points reject before cache reads or network calls. *)
        let () = assert (Sys.command invocation = 1) in
        assert (read_file stderr_path =
          "day trading strategies run under bt daytrade\n"))))
    ["run"; "target"; "live"]

let test_daytrade_cli () =
  let binary = locate ["_build/default/bin/bt.exe"; "../bin/bt.exe"] in
  with_temp_market "us" (fun root _ ->
    let stdout_path = Filename.concat root "stdout.txt" in
    let stderr_path = Filename.concat root "stderr.txt" in
    let invoke args =
      Sys.command (String.concat " "
        (Filename.quote binary :: "daytrade" :: List.map Filename.quote args @
         [">" ^ Filename.quote stdout_path; "2>" ^ Filename.quote stderr_path]))
    in
    let () =
      List.iter (fun (source, message) ->
        with_temp_strategy source (fun path ->
          (* These are run errors, not unknown-subcommand usage errors. *)
          let () = assert (invoke [path; "--no-plot"] = 1) in
          assert (read_file stderr_path = message ^ "\n")))
        ["stock \"us/SPY\"\ntarget 1\n", "bt daytrade requires a bars declaration";
         "stock \"tw/0050\"\nbars 5m\ntarget 1\n", "day trading supports us only";
         "stock \"us/SPY\" as a\nstock \"us/QQQ\" as b\nbars 5m\na.target 1\nb.target 0\n",
         "day trading strategies declare exactly one stock"]
    in
    let () =
      List.iter (fun flag ->
        (* Daily financing and dividend settings have no intraday consumer. *)
        let () = assert (invoke [flag; "1"] = 2) in
        assert (contains (read_file stderr_path) ("unknown option '" ^ flag ^ "'")))
        ["--financing-rate"; "--maintenance-ratio"; "--loan-term-months"; "--dividend-tax"]
    in
    let sessions : Data.session list =
      [{ date = "2024-11-27"; open_ = "09:30"; close = "16:00" };
       { date = "2024-11-29"; open_ = "09:30"; close = "13:00" };
       { date = "2024-12-02"; open_ = "09:30"; close = "16:00" }] in
    let () = Data.write_calendar ~data_dir:root sessions in
    let () = Data.write_minute_bars ~data_dir:root ~symbol:"SPY"
      [bar "2024-11-27T09:30" 100. 100.;
       bar "2024-11-27T15:55" 110. 120.;
       bar "2024-11-29T09:30" 200. 200.;
       bar "2024-11-29T12:55" 200. 180.] in
    with_temp_strategy
      "stock \"us/SPY\"\nbars 5m\nparam allocation = 1\ntarget allocation * num(since_open == 0 and to_close >= 210)\n"
      (fun path ->
        let name = Filename.remove_extension (Filename.basename path) in
        let args = [path; "--data-dir"; root; "--out-dir"; root;
          "--out-name"; "equity"; "--no-plot"; "--fee-bps"; "0";
          "--tax-bps"; "0"; "--slip-bps"; "0"; "-p"; "allocation=1"] in
        let () = assert (invoke args = 0) in
        let output = read_file stdout_path in
        (* Two sessions with data, two round trips, one gain, both forced flat. *)
        let () = List.iter (fun text -> assert (contains output text))
          ["sessions 2"; "trades 2"; "win rate 50.00%"; "flat-forced 2"; "fill: open"] in
        let fills = read_file (Filename.concat root (name ^ ".trades.csv"))
          |> String.split_on_char '\n' in
        let () = match fills with
          | header :: entry :: exit :: _ ->
              let () = assert (header = "time,stock,price,from_exposure,to_exposure") in
              (* Decision at 09:30 enters at the next available open 110,
                 then exits at that bar's close 120, never the decision close 100. *)
              let () = assert (entry = "2024-11-27T15:55,us/SPY,110,0,1") in
              assert (exit = "2024-11-27T15:55,us/SPY,120,1,0")
          | _ -> assert false in
        let rows = read_file (Filename.concat root "equity.csv")
          |> String.split_on_char '\n' |> List.filter (( <> ) "") in
        let () = match rows with
          | [_; first; second] ->
              (* 120/110, then a 10% loss: 12/11 and 54/55. No empty Dec 2 row. *)
              let value row = float_of_string (List.nth (String.split_on_char ',' row) 1) in
              let () = assert_close (12. /. 11.) (value first) in
              assert_close (54. /. 55.) (value second)
          | _ -> assert false in
        let () = assert (invoke (args @ ["--fill"; "close"]) = 0) in
        (* Same-close entry is 100, not the default's next-open 110. *)
        assert (contains (read_file (Filename.concat root (name ^ ".trades.csv")))
          "2024-11-27T09:30,us/SPY,100,0,1")))

let intraday_sessions : Data.session array =
  [| { date = "2024-11-27"; open_ = "09:30"; close = "16:00" };
     { date = "2024-11-29"; open_ = "09:30"; close = "13:00" } |]

let intraday_bars =
  [| bar "2024-11-27T09:30" 100. 100.;
     bar "2024-11-27T09:35" 110. 120.;
     bar "2024-11-27T09:40" 120. 120.;
     bar "2024-11-27T09:45" 120. 120.;
     bar "2024-11-27T15:55" 120. 120.;
     bar "2024-11-29T09:30" 200. 200.;
     bar "2024-11-29T09:35" 200. 180.;
     bar "2024-11-29T12:55" 180. 180. |]

let run_intraday ?(fill = Engine.Close_same) ?(leverage = 1.)
    ?(costs = zero_costs) ?capital ?(initial_equity = 1.)
    ?(sessions = intraday_sessions) ?(bars = intraday_bars) targets =
  Intraday.run { fill; leverage; costs; capital }
    ~sessions ~bars ~targets ~initial_equity

let test_intraday_latency () =
  let targets = [|1.; 0.; 0.; 0.; 0.; 0.; 0.; 0.|] in
  let same = run_intraday targets in
  let next = run_intraday ~fill:Engine.Open_next targets in
  (* Close buys at 100, sells at 120: 1.2. Next open buys at 110,
     sells at 120: 12/11. Difference is 6/55. No overnight gain. *)
  let () = assert_float_array [|1.2; 1.2|] same.equity in
  let () = assert_float_array [|12. /. 11.; 12. /. 11.|] next.equity in
  let () = assert_close (6. /. 55.) (same.equity.(0) -. next.equity.(0)) in
  let () = assert (same.session_dates = [|"2024-11-27"; "2024-11-29"|]) in
  match same.fills, next.fills with
  | [a; b], [c; d] ->
      let () = assert (a.time = "2024-11-27T09:30" && a.price = 100.) in
      let () = assert (b.time = "2024-11-27T09:35" && b.price = 120.) in
      let () = assert (c.time = "2024-11-27T09:35" && c.price = 110.) in
      assert (d.time = "2024-11-27T09:40" && d.price = 120.)
  | _ -> assert false

let test_intraday_last_decision () =
  List.iter (fun fill ->
    let result = run_intraday ~fill [|0.; 0.; 0.; 0.; 1.; 0.; 0.; 1.|] in
    (* Last decisions cannot enter either session or leak into the next. *)
    let () = assert (result.fills = [] && result.flat_forced = 0) in
    assert_float_array [|1.; 1.|] result.equity)
    [Engine.Close_same; Engine.Open_next]

let test_intraday_forced_flat () =
  List.iter (fun (fill, expected) ->
    let result = run_intraday ~fill [|1.; 1.; 1.; 1.; 0.; 1.; 1.; 0.|] in
    (* Entry 100 (close) or 110 (next open), exit 120; next session
       enters 200 and exits 180. Cash compounds, never the overnight gap. *)
    let () = assert_float_array expected result.equity in
    let () = assert (result.trades = 2 && result.wins = 1 && result.flat_forced = 2) in
    match result.fills with
    | [_; a; _; b] ->
        let () = assert (a.time = "2024-11-27T15:55" && a.price = 120.) in
        let () = assert (b.time = "2024-11-29T12:55" && b.price = 180.) in
        assert (a.to_exposure = 0. && b.to_exposure = 0.)
    | _ -> assert false)
    [Engine.Close_same, [|1.2; 1.08|];
     Engine.Open_next, [|12. /. 11.; 54. /. 55.|]]

let test_intraday_cap () =
  let result = run_intraday ~leverage:2. ~initial_equity:10.
    [|1.; 2.; 2.; 2.; 0.; 3.; 3.; 0.|] in
  (* First buy 10 at 100 grows to 12. Target 2 would buy value 24,
     but prior-close cap is 20: buy only 8 at 120, equity remains 12.
     Next session cap resets to 24. The 3 target caps at 2 and loses
     10% of 24, leaving 9.6. *)
  let () = assert_float_array [|12.; 9.6|] result.equity in
  match result.fills with
  | [_; capped; _; next; _] ->
      let () = assert_close (5. /. 3.) capped.to_exposure in
      assert_close 2. next.to_exposure
  | _ -> assert false

let test_intraday_drift () =
  let result = run_intraday ~leverage:2. [|2.; 2.; 2.; 2.; 0.; 0.; 0.; 0.|] in
  (* Borrow 1, buy value 2; a 20% gain makes value 2.4 and equity 1.4.
     Unchanged targets do not trim drift above yesterday's cap of 2. *)
  let () = assert_float_array [|1.4; 1.4|] result.equity in
  assert (List.length result.fills = 2)

let test_intraday_normalization () =
  let rejected =
    try
      let () = ignore (run_intraday [|0.; -0.5; 0.; 0.; 0.; 0.; 0.; 0.|]) in
      false
    with Failure message -> message = "short targets are reserved"
  in
  let () = assert rejected in
  let result = run_intraday [|1.; Float.nan; 0.; 0.; 0.; 0.; 0.; 0.|] in
  (* NaN becomes a zero target: exit at 120 instead of waiting for close. *)
  let () = assert_float_array [|1.2; 1.2|] result.equity in
  match result.fills with
  | [_; exit] -> assert (exit.time = "2024-11-27T09:35" && result.flat_forced = 0)
  | _ -> assert false

let test_intraday_costs () =
  let costs = { zero_costs with Engine.fee_bps = 100.; tax_bps = 200.; slip_bps = 100. } in
  let result = run_intraday ~costs [|1.; 1.; 1.; 1.; 0.; 0.; 0.; 0.|] in
  (* Entry costs 2%, so position = 1/1.02. It grows 20%, then forced
     sell pays 1% fee + 2% tax + 1% slip: 1.2 * .96 / 1.02 = 96/85. *)
  let () = assert_float_array [|96. /. 85.; 96. /. 85.|] result.equity in
  let () = assert (result.flat_forced = 1 && result.wins = 1) in
  let expensive = { zero_costs with Engine.fee_bps = 1000. } in
  let loss = run_intraday ~costs:expensive [|1.; 1.; 1.; 1.; 0.; 0.; 0.; 0.|] in
  (* Gross +20% is a net loss: 1.2 * .9 / 1.1 = 54/55. *)
  let () = assert_close (54. /. 55.) loss.equity.(0) in
  assert (loss.trades = 1 && loss.wins = 0)

let test_intraday_capital_costs () =
  let bars = Array.map (fun (b : Data.bar) -> { b with o = 100.; c = 100. }) intraday_bars in
  let costs = { zero_costs with Engine.min_fee = 2.;
    per_share_sell_fee = 0.03; per_share_sell_cap = 0.10 } in
  let result = run_intraday ~bars ~capital:1050. ~costs
    [|1.; 1.; 1.; 1.; 0.; 0.; 0.; 0.|] in
  (* Cash 1050 pays $2 entry, buys 10.48 fractional shares. Sell pays
     $2 minimum plus capped $0.10 TAF, leaving $1045.90. *)
  let () = assert_close (1045.9 /. 1050.) result.equity.(0) in
  let without = run_intraday ~bars ~costs [|1.; 1.; 1.; 1.; 0.; 0.; 0.; 0.|] in
  (* Without capital the dollar minimum and TAF are inactive. *)
  let () = assert_float_array [|1.; 1.|] without.equity in
  let uncapped = { costs with Engine.min_fee = 0.; per_share_sell_cap = 0. } in
  let small = run_intraday ~bars ~capital:1050. ~costs:uncapped
    [|0.1; 0.1; 0.1; 0.1; 0.; 0.; 0.; 0.|] in
  (* 1.05 shares * .03 = .0315 rounds UP to .04; zero cap is uncapped. *)
  assert_close (1049.96 /. 1050.) small.equity.(0)

let test_intraday_round_trips () =
  let result = run_intraday [|0.5; 1.; 0.5; 0.; 0.; 1.; 1.; 0.|] in
  (* Buy .005 shares at 100, scale in at 120, then reduce before exit.
     First round trip earns .1 (equity 1.1); second loses .11 -> .99.
     Scale-in/out fills do not create extra round trips. *)
  let () = assert_float_array [|1.1; 0.99|] result.equity in
  let () = assert (result.trades = 2 && result.wins = 1 && result.flat_forced = 1) in
  let flat_bars = Array.map (fun (b : Data.bar) -> { b with o = 100.; c = 100. }) intraday_bars in
  let repeated = run_intraday ~bars:flat_bars [|1.; 0.; 1.; 0.; 0.; 0.; 0.; 0.|] in
  (* Two distinct flat-to-flat trades, both exactly break-even, not wins. *)
  assert (repeated.trades = 2 && repeated.wins = 0 && repeated.flat_forced = 0)

let test_intraday_session_boundaries () =
  let sessions = Array.append intraday_sessions
    [|{ Data.date = "2024-12-02"; open_ = "09:30"; close = "16:00" }|] in
  let bars = [|bar "2024-11-27T15:55" 100. 120.;
               bar "2024-11-29T12:55" 200. 180.|] in
  List.iter (fun fill ->
    let result = run_intraday ~sessions ~bars ~fill [|1.; 1.|] in
    (* Single-bar sessions have only ignored decisions. Calendar-only
       Dec 2 has no data and therefore no fabricated equity observation. *)
    let () = assert_float_array [|1.; 1.|] result.equity in
    let () = assert (result.session_dates = [|"2024-11-27"; "2024-11-29"|]) in
    assert (result.fills = []))
    [Engine.Close_same; Engine.Open_next]


let test_engine_fill_planner () =
  let plan ~cash ~cash_value ~margin_value ~loan ~previous target =
    Engine.plan_fills ~costs:[| zero_costs |] ~capital:(Some 1000000.)
      ~financing_ratios:[| 0.6 |]
      ~state:
        { Engine.equity = 1000000.; cash;
          cash_values = [| cash_value |];
          margin_values = [| margin_value |];
          loans = [| loan |]; interests = [| 0. |];
          tail_interests = [| 0. |]; debt = 0.; receivables = 0.;
          previous_targets = [| previous |] }
      ~prices:[| 10. |] ~targets:[| target |] ~force:false
  in
  let entry =
    (plan ~cash:1000000. ~cash_value:0. ~margin_value:0.
       ~loan:0. ~previous:0. 1.).Engine.planned_assets.(0)
  in
  (* TWD 1,000,000 / TWD 10 = 100,000 cash shares. *)
  let () = assert_close 100000. (entry.Engine.plan_buy_cash /. 10.) in
  (* A 1x unlevered entry needs no margin purchase. *)
  let () = assert_close 0. entry.Engine.plan_buy_margin in
  let scale_in =
    (plan ~cash:0. ~cash_value:1000000. ~margin_value:0.
       ~loan:0. ~previous:1. 2.).Engine.planned_assets.(0)
  in
  (* The 2x target adds TWD 1,000,000 / TWD 10 = 100,000 margin shares. *)
  let () =
    assert_close 100000. (scale_in.Engine.plan_buy_margin /. 10.)
  in
  (* The 60% financing ratio borrows 0.6 * TWD 1,000,000 = TWD 600,000. *)
  let () =
    assert_close 600000. (0.6 *. scale_in.Engine.plan_buy_margin)
  in
  (* The down payment is 0.4 * TWD 1,000,000 = TWD 400,000. *)
  let () = assert_close 400000. scale_in.Engine.plan_down_payment in
  let exit =
    (plan ~cash:0. ~cash_value:(1000000. /. 3.)
       ~margin_value:(5000000. /. 3.) ~loan:1000000.
       ~previous:2. 0.).Engine.planned_assets.(0)
  in
  (* TWD 5/3m margin inventory / TWD 10 = 500,000/3 shares. *)
  let () =
    assert_close (500000. /. 3.) (exit.Engine.plan_sell_margin /. 10.)
  in
  (* TWD 1/3m cash inventory / TWD 10 = 100,000/3 shares. *)
  let () =
    assert_close (100000. /. 3.) (exit.Engine.plan_sell_cash /. 10.)
  in
  (* Selling all margin inventory repays the full TWD 1,000,000 loan. *)
  assert_close 1000000. exit.Engine.plan_repayment


let shioaji_fixture name =
  read_file
    (locate
       [Filename.concat "test/fixtures/shioaji" name;
        Filename.concat "fixtures/shioaji" name])

let test_shioaji_info_parse () =
  let actual = Shioaji.parse_info (shioaji_fixture "info.json") in
  (* Expected values are copied from the documented server info response. *)
  let expected : Shioaji.info =
    { simulation = false; version = "1.7.2" }
  in
  assert (actual = expected)

let test_shioaji_snapshot_parse () =
  let actual = Shioaji.parse_snapshot (shioaji_fixture "snapshot.json") in
  (* Expected values are copied from the documented 2330 snapshot row. *)
  let expected : Shioaji.snapshot =
    { datetime = "2026-05-18T14:30:00";
      open_ = 2225.;
      high = 2260.;
      low = 2215.;
      close = 2240.;
      bid = 2240.;
      ask = 2245.;
      total_volume = 25820. }
  in
  assert (actual = expected)

let test_shioaji_positions_parse () =
  let actual = Shioaji.parse_positions (shioaji_fixture "positions.json") in
  (* The first two rows are documented Common-lot cash positions. The third
     applies the same shape to three margin lots with TWD 120,000 borrowed. *)
  let expected : Shioaji.position list =
    [{ id = 0; code = "2890"; cond = "Cash"; lots = 1; yd_lots = 1;
       avg_price = 30.; last_price = 31.; loan_amount = 0.; interest = 0. };
     { id = 1; code = "2330"; cond = "Cash"; lots = 1; yd_lots = 1;
       avg_price = 2000.; last_price = 1980.; loan_amount = 0.; interest = 0. };
     { id = 2; code = "2330"; cond = "MarginTrading"; lots = 3; yd_lots = 2;
       avg_price = 1950.; last_price = 1980.; loan_amount = 120000.;
       interest = 35. }]
  in
  assert (actual = expected)

let test_shioaji_position_details_parse () =
  let actual =
    Shioaji.parse_position_details (shioaji_fixture "position_detail.json")
  in
  (* Each expected row copies code, condition, origination date, and quantity
     from the five position_detail fixture objects in file order. *)
  let expected : Shioaji.position_detail list =
    [{ code = "2330"; cond = "MarginTrading"; date = "2024-11-26";
       lots = 2 };
     { code = "2330"; cond = "MarginTrading"; date = "2024-11-27";
       lots = 3 };
     { code = "2330"; cond = "MarginTrading"; date = "2024-05-31";
       lots = 1 };
     { code = "2330"; cond = "Cash"; date = "2024-01-01"; lots = 4 };
     { code = "2890"; cond = "MarginTrading"; date = "2024-01-01";
       lots = 5 }]
  in
  assert (actual = expected)


let test_shioaji_balance_parse () =
  (* The balance fixture's acc_balance field is exactly TWD 100,000. *)
  let () =
    assert (Shioaji.parse_balance (shioaji_fixture "balance.json") = 100000.)
  in
  match Shioaji.parse_balance (shioaji_fixture "balance_error.json") with
  | _ -> assert false
  | exception Failure message ->
      (* The error fixture's errmsg field is returned verbatim. *)
      assert (message = "account balance unavailable in simulation")

let test_shioaji_placed_parse () =
  let actual = Shioaji.parse_placed (shioaji_fixture "place_order.json") in
  (* The documented initial response has not reached the exchange yet. *)
  let expected : Shioaji.placed =
    { order_id = "a647f23d"; status = "PendingSubmit" }
  in
  assert (actual = expected)

let test_shioaji_parser_rejections () =
  (* An object without both fields does not have the two-column info shape. *)
  let () =
    assert_failure (fun () -> ignore (Shioaji.parse_info {|{}|}))
  in
  (* "maybe" is not a JSON boolean string accepted by bool_of_string. *)
  let () =
    assert_failure (fun () ->
      ignore (Shioaji.parse_info {|{"simulation":"maybe","version":"1"}|}))
  in
  (* An empty array violates the exactly-one-snapshot response shape. *)
  let () =
    assert_failure (fun () -> ignore (Shioaji.parse_snapshot {|[]|}))
  in
  (* Snapshot prices are nonnegative; open = -1 violates that field contract. *)
  let () =
    assert_failure (fun () ->
      ignore
        (Shioaji.parse_snapshot
           {|[{"datetime":"2026-05-18T13:20:00","open":-1,"high":1,"low":1,"close":1,"buy_price":1,"sell_price":1,"total_volume":1}]|}))
  in
  (* A positions response must be an array, not an object. *)
  let () =
    assert_failure (fun () -> ignore (Shioaji.parse_positions {|{}|}))
  in
  (* Common-lot quantity must parse as a nonnegative integer. *)
  let () =
    assert_failure (fun () ->
      ignore
        (Shioaji.parse_positions
           {|[{"id":0,"code":"2330","cond":"Cash","quantity":"lots","yd_quantity":0,"price":1,"last_price":1,"margin_purchase_amount":0,"interest":0}]|}))
  in
  (* Negative Common-lot quantity violates the nonnegative position value. *)
  let () =
    assert_failure (fun () ->
      ignore
        (Shioaji.parse_positions
           {|[{"id":0,"code":"2330","cond":"Cash","quantity":-1,"yd_quantity":0,"price":1,"last_price":1,"margin_purchase_amount":0,"interest":0}]|}))
  in
  (* A position-detail response must be an array, not an object. *)
  let () =
    assert_failure (fun () -> ignore (Shioaji.parse_position_details {|{}|}))
  in
  (* The position-detail quantity field must have JSON number type. *)
  let () =
    assert_failure (fun () ->
      ignore
        (Shioaji.parse_position_details
           {|[{"code":"2330","cond":"MarginTrading","date":"2024-11-26","quantity":"2"}]|}))
  in
  (* February 30 is not a valid position origination date. *)
  let () =
    assert_failure (fun () ->
      ignore
        (Shioaji.parse_position_details
           {|[{"code":"2330","cond":"MarginTrading","date":"2024-02-30","quantity":2}]|}))
  in
  (* Negative Common-lot quantity violates the position-detail value. *)
  let () =
    assert_failure (fun () ->
      ignore
        (Shioaji.parse_position_details
           {|[{"code":"2330","cond":"MarginTrading","date":"2024-11-26","quantity":-1}]|}))
  in
  (* A submitted-order response must supply both order id and status. *)
  assert_failure (fun () -> ignore (Shioaji.parse_placed {|{}|}))

let test_shioaji_orders_today_parse () =
  let raw = shioaji_fixture "update_status.json" in
  let actual =
    Shioaji.parse_orders_today ~code:"2890" ~today:"2026-05-20" raw
  in
  (* The documented fill is two Common lots at TWD 27.1. *)
  let expected : Shioaji.trade list =
    [{ order_id = "a647f23d";
       code = "2890";
       action = "Buy";
       cond = "Cash";
       status = "Filled";
       order_lots = 2;
       deal_lots = 2;
       deal_price = Some 27.1;
       order_datetime = "2026-05-20T11:24:30+08:00" }]
  in
  let () = assert (actual = expected) in
  (* Filtering the 2026-05-20 fixture for 2026-05-21 leaves no rows. *)
  let () =
    assert
      (Shioaji.parse_orders_today ~code:"2890" ~today:"2026-05-21" raw = [])
  in
  (* Filtering the 2890 fixture for code 2330 leaves no rows. *)
  let () =
    assert
      (Shioaji.parse_orders_today ~code:"2330" ~today:"2026-05-20" raw = [])
  in
  let timestamp_raw = shioaji_fixture "trades_order_ts.json" in
  (* 1789104000.875 floors to 2026-09-11 05:20:00 UTC, which is
     2026-09-11 13:20:00 in Taipei. *)
  let expected_timestamp_trade : Shioaji.trade list =
    [{ order_id = "ts-only";
       code = "2890";
       action = "Buy";
       cond = "Cash";
       status = "Filled";
       order_lots = 2;
       deal_lots = 2;
       deal_price = Some 27.1;
       order_datetime = "2026-09-11T13:20:00+08:00" }]
  in
  let () =
    assert
      (Shioaji.parse_orders_today ~code:"2890" ~today:"2026-09-11"
         timestamp_raw
       = expected_timestamp_trade)
  in
  (* The timestamp fixture is dated 2026-09-11, so 2026-09-12 has no rows. *)
  assert
    (Shioaji.parse_orders_today ~code:"2890" ~today:"2026-09-12"
       timestamp_raw
     = [])


let test_tw_live_phase () =
  (* 13:04:59 is one second before the 13:05 preparation window. *)
  let () =
    assert
      (Live.taipei_phase ~now:"2026-05-22T13:04:59+08:00"
       = `Before_fetch)
  in
  (* The fetch phase includes its 13:05:00 lower bound. *)
  let () =
    assert
      (Live.taipei_phase ~now:"2026-05-22T13:05:00+08:00" = `Fetch)
  in
  (* 13:19:59 is one second before the 13:20 decision window. *)
  let () =
    assert
      (Live.taipei_phase ~now:"2026-05-22T13:19:59+08:00" = `Fetch)
  in
  (* The decision phase includes its 13:20:00 lower bound. *)
  let () =
    assert
      (Live.taipei_phase ~now:"2026-05-22T13:20:00+08:00" = `Decide)
  in
  (* 13:24:59 is one second before the 13:25 submission cutoff. *)
  let () =
    assert
      (Live.taipei_phase ~now:"2026-05-22T13:24:59+08:00" = `Decide)
  in
  (* The 13:25:00 cutoff starts the after-close phase. *)
  let () =
    assert
      (Live.taipei_phase ~now:"2026-05-22T13:25:00+08:00"
       = `After_close)
  in
  (* 13:30:00 remains after the 13:25 cutoff. *)
  let () =
    assert
      (Live.taipei_phase ~now:"2026-05-22T13:30:00+08:00"
       = `After_close)
  in
  (* Saturday 2026-05-23 is a weekend regardless of clock time. *)
  assert
    (Live.taipei_phase ~now:"2026-05-23T13:20:00+08:00" = `Weekend)


let test_tw_live_exchange () =
  with_temp_market "tw" (fun data_dir tw_dir ->
    let path = Filename.concat tw_dir "stockinfo.csv" in
    let output = open_out path in
    let () =
      Fun.protect
        ~finally:(fun () -> close_out output)
        (fun () ->
          output_string output
            "stock_id,type,date\n2330,twse,2026-01-01\n\
             6488,tpex,2026-01-01\n7777,emerging,2026-01-01\n")
    in
    (* The fixture maps 2330's twse field to Shioaji TSE. *)
    let () = assert (Live.exchange_of_symbol ~data_dir "2330" = "TSE") in
    (* The fixture maps 6488's tpex field to Shioaji OTC. *)
    let () = assert (Live.exchange_of_symbol ~data_dir "6488" = "OTC") in
    (* The emerging fixture field is not a supported exchange mapping. *)
    let () =
      assert_failure (fun () ->
        ignore (Live.exchange_of_symbol ~data_dir "7777"))
    in
    (* No fixture row supplies an exchange for symbol 9999. *)
    assert_failure (fun () ->
      ignore (Live.exchange_of_symbol ~data_dir "9999")))

let test_tw_live_equity () =
  let positions = Shioaji.parse_positions (shioaji_fixture "positions.json") in
  (* 100000 cash + 31000 + 1980000 + 5940000 inventory
     - 120000 loan - 35 interest = 7930965. *)
  assert_close 7930965. (Live.equity_of ~balance:100000. ~positions)

let test_tw_live_plan_legs () =
  let plan ~equity ~cash ~cash_value ~margin_value ~loan ~previous target =
    Engine.plan_fills ~costs:[| zero_costs |] ~capital:(Some equity)
      ~financing_ratios:[| 0.6 |]
      ~state:
        { Engine.equity; cash; cash_values = [| cash_value |];
          margin_values = [| margin_value |]; loans = [| loan |];
          interests = [| 0. |]; tail_interests = [| 0. |]; debt = 0.;
          receivables = 0.; previous_targets = [| previous |] }
      ~prices:[| 10. |] ~targets:[| target |] ~force:false
  in
  let entry =
    plan ~equity:1000000. ~cash:1000000. ~cash_value:0.
      ~margin_value:0. ~loan:0. ~previous:0. 1.
  in
  (* TWD 1,000,000 / TWD 10 / 1,000 = 100 Common cash lots. *)
  let () =
    assert
      (Live.legs_of_plan ~price:10. entry
       = [{ Live.action = "Buy"; cond = "Cash"; lots = 100 }])
  in
  let refinance =
    plan ~equity:1000000. ~cash:0. ~cash_value:1000000.
      ~margin_value:0. ~loan:0. ~previous:1. 2.
  in
  (* Refinancing TWD 2/3m floors to 66 lots; the TWD 1m margin buy is
     exactly 100 lots at TWD 10 per share. *)
  let () =
    assert
      (Live.legs_of_plan ~price:10. refinance
       = [{ Live.action = "Sell"; cond = "Cash"; lots = 66 };
          { Live.action = "Buy"; cond = "MarginTrading"; lots = 66 };
          { Live.action = "Buy"; cond = "MarginTrading"; lots = 100 }])
  in
  let mixed_refinance =
    plan ~equity:3000000. ~cash:0. ~cash_value:(2000000. /. 3.)
      ~margin_value:(10000000. /. 3.) ~loan:1000000.
      ~previous:2. 1.8
  in
  (* TWD 4/15m / 10 / 1,000 floors to 26 cash-refinance lots,
     TWD 4/3m floors to 133 margin-refinance lots, and TWD 1.4m
     buys 140 margin lots. *)
  let () =
    assert
      (Live.legs_of_plan ~price:10. mixed_refinance
       = [{ Live.action = "Sell"; cond = "Cash"; lots = 26 };
          { Live.action = "Buy"; cond = "MarginTrading"; lots = 26 };
          { Live.action = "Sell"; cond = "MarginTrading"; lots = 133 };
          { Live.action = "Buy"; cond = "MarginTrading"; lots = 133 };
          { Live.action = "Buy"; cond = "MarginTrading"; lots = 140 }])
  in
  let exit =
    plan ~equity:1000000. ~cash:0. ~cash_value:(1000000. /. 3.)
      ~margin_value:(5000000. /. 3.) ~loan:1000000. ~previous:2. 0.
  in
  (* TWD 5/3m and TWD 1/3m at TWD 10 floor to 166 margin lots and
     33 cash lots, respectively. *)
  let () =
    assert
      (Live.legs_of_plan ~price:10. exit
       = [{ Live.action = "Sell"; cond = "MarginTrading"; lots = 166 };
          { Live.action = "Sell"; cond = "Cash"; lots = 33 }])
  in
  let sub_lot =
    plan ~equity:9990. ~cash:9990. ~cash_value:0. ~margin_value:0.
      ~loan:0. ~previous:0. 1.
  in
  (* TWD 9,990 / TWD 10 = 999 shares, below one Common lot. *)
  assert (Live.legs_of_plan ~price:10. sub_lot = [])

let test_tw_live_startup_guard () =
  let simulation : Shioaji.info =
    { simulation = true; version = "test" }
  in
  let production = { simulation with Shioaji.simulation = false } in
  (* Paper mode, positive equity, and a simulation server agree. *)
  let () =
    assert
      (Live.tw_startup_ok Live.Paper ~equity:(Some 1000000.) simulation
       = Ok ())
  in
  (* Live mode without CLI equity agrees with a production server. *)
  let () =
    assert (Live.tw_startup_ok Live.Live ~equity:None production = Ok ())
  in
  (* Live mode cannot use a server whose simulation field is true. *)
  let () =
    assert
      (Live.tw_startup_ok Live.Live ~equity:None simulation
       = Error "--live requires a production Shioaji server")
  in
  (* Paper mode cannot use a server whose simulation field is false. *)
  let () =
    assert
      (Live.tw_startup_ok Live.Paper ~equity:(Some 1000000.) production
       = Error "--live is required for a production Shioaji server")
  in
  (* Paper mode has no sizing equity when the option is absent. *)
  let () =
    assert
      (Live.tw_startup_ok Live.Paper ~equity:None simulation
       = Error "simulation mode requires --equity")
  in
  (* Zero is not a finite positive simulation equity. *)
  let () =
    assert
      (Live.tw_startup_ok Live.Paper ~equity:(Some 0.) simulation
       = Error "simulation equity must be finite and positive")
  in
  (* Production derives equity from the account, so CLI equity is forbidden. *)
  assert
    (Live.tw_startup_ok Live.Live ~equity:(Some 1000000.) production
     = Error "--equity is not allowed in production")

let test_tw_maturity_rollover_legs () =
  let details =
    Shioaji.parse_position_details (shioaji_fixture "position_detail.json")
  in
  (* 2024-11-26 + 18 months = 2026-05-26 for 2 lots; 2024-05-31
     clamps to 2025-11-30 for 1 lot. Later, cash, and other-symbol rows
     are excluded, leaving the two sell/rebuy pairs in fixture order. *)
  let () =
    assert
      (Live.maturity_rollover_legs ~session_date:"2026-05-26"
         ~symbol:"2330" details
       = [{ Live.action = "Sell"; cond = "MarginTrading"; lots = 2 };
          { Live.action = "Buy"; cond = "MarginTrading"; lots = 2 };
          { Live.action = "Sell"; cond = "MarginTrading"; lots = 1 };
          { Live.action = "Buy"; cond = "MarginTrading"; lots = 1 }])
  in
  (* 2026-05-25 is one day before the 2026-05-26 maturity. *)
  assert
    (Live.maturity_rollover_legs ~session_date:"2026-05-25"
       ~symbol:"2330"
       [{ Shioaji.code = "2330"; cond = "MarginTrading";
          date = "2024-11-26"; lots = 2 }]
     = [])

let test_tw_live_decide_override () =
  with_temp_market "tw" (fun data_dir tw_dir ->
    let symbol_dir = Filename.concat tw_dir "2330" in
    let () = Unix.mkdir symbol_dir 0o700 in
    let write path contents =
      let output = open_out path in
      Fun.protect
        ~finally:(fun () -> close_out output)
        (fun () -> output_string output contents)
    in
    let () =
      write (Filename.concat tw_dir "stockinfo.csv")
        "stock_id,type,date\n2330,twse,2026-01-01\n"
    in
    let () =
      write (Filename.concat symbol_dir "2330.csv")
        "date,open,high,low,close,volume\n\
         2026-05-14,1870,1880,1860,1870,900\n\
         2026-05-15,1880,1890,1870,1880,900\n\
         2026-05-21,1950,1960,1940,1950,1100\n\
         2026-05-22,1980,1990,1970,1980,1200\n"
    in
    let () =
      write (Filename.concat symbol_dir "2330.div.csv") "date,factor\n"
    in
    let () =
      write (Filename.concat symbol_dir "2330.events.csv") "date,factor\n"
    in
    let () =
      write (Filename.concat symbol_dir "2330.cashdiv.csv")
        "ex_date,cash_per_share,pay_date\n"
    in
    with_temp_strategy "stock \"tw/2330\"\ntarget 1.0\n" (fun strat_path ->
      let all_positions =
        Shioaji.parse_positions (shioaji_fixture "positions.json")
      in
      let positions =
        List.filter
          (fun (position : Shioaji.position) -> position.code = "2330")
          all_positions
      in
      let position_details =
        Shioaji.parse_position_details
          (shioaji_fixture "position_detail.json")
      in
      let decision =
        Live.decide ~provisional_close:2000. ~previous_session:"2026-05-22"
          ~equity:20000000. ~tw_positions:positions
          ~tw_position_details:position_details Live.Paper
          ~session_date:"2026-05-26" ~strat_path ~data_dir
      in
      (* The injected previous session is the fixture cache's final date. *)
      let () = assert (decision.Live.fetched_through = "2026-05-22") in
      (* The explicit provisional close is TWD 2,000. *)
      let () = assert_close 2000. decision.Live.provisional.c in
      (* The strategy source declares target 1.0. *)
      let () = assert_close 1. decision.Live.target in
      (* The two 2330 fixture rows hold 1 cash lot + 3 margin lots = 4,000 shares. *)
      let () = assert_close 4000. decision.Live.held in
      (* The 2024-11-26 two-lot and 2024-05-31 one-lot rows are both
         mature on 2026-05-26, so their sell/rebuy pairs lead the plan. *)
      let () =
        match decision.Live.action with
        | Live.Orders
            ({ action = "Sell"; cond = "MarginTrading"; lots = 2 }
             :: { action = "Buy"; cond = "MarginTrading"; lots = 2 }
             :: { action = "Sell"; cond = "MarginTrading"; lots = 1 }
             :: { action = "Buy"; cond = "MarginTrading"; lots = 1 }
             :: _) -> ()
        | _ -> assert false
      in
      let fixture = Shioaji.parse_snapshot (shioaji_fixture "snapshot.json") in
      let fixture_decision =
        Live.decide ~previous_session:"2026-05-15" ~equity:20000000.
          ~tw_positions:positions ~tw_snapshot:fixture Live.Paper
          ~session_date:"2026-05-18" ~strat_path ~data_dir
      in
      (* The snapshot fixture's close field is TWD 2,240. *)
      let () = assert_close 2240. fixture_decision.Live.provisional.c in
      let snapshot : Shioaji.snapshot =
        { fixture with datetime = "2026-05-26T13:20:00";
          open_ = 2000.; high = 2002.; low = 1998.; close = 0.;
          bid = 1998.; ask = 2002. }
      in
      let midpoint =
        Live.decide ~previous_session:"2026-05-22" ~equity:20000000.
          ~tw_positions:positions ~tw_snapshot:snapshot Live.Paper
          ~session_date:"2026-05-26" ~strat_path ~data_dir
      in
      (* A zero close falls back to (TWD 1,998 + TWD 2,002) / 2 = TWD 2,000. *)
      let () = assert_close 2000. midpoint.Live.provisional.c in
      let decide_at datetime =
        Live.decide ~previous_session:"2026-05-22" ~equity:20000000.
          ~tw_positions:positions
          ~tw_snapshot:{ snapshot with datetime }
          Live.Paper ~session_date:"2026-05-26" ~strat_path ~data_dir
      in
      let fractional = decide_at "2026-05-26T13:20:00.671475" in
      (* 13:20:00.671475 floors to 13:20:00, retaining 2026-05-26. *)
      let () = assert (fractional = midpoint) in
      let offset = decide_at "2026-05-26T13:20:00+08:00" in
      let fractional_offset =
        decide_at "2026-05-26T13:20:00.5+08:00"
      in
      (* At +08:00, 13:20:00.5 floors to the unfractioned 13:20:00. *)
      let () = assert (fractional_offset = offset) in
      (* A decimal point without a fractional digit is malformed. *)
      let () =
        assert_failure (fun () ->
          ignore (decide_at "2026-05-26T13:20:00."))
      in
      (* Letters do not satisfy the one-to-nine fractional-digit contract. *)
      let () =
        assert_failure (fun () ->
          ignore (decide_at "2026-05-26T13:20:00.abc"))
      in
      (* Ten digits exceed the accepted fractional precision of nine digits. *)
      let () =
        assert_failure (fun () ->
          ignore (decide_at "2026-05-26T13:20:00.1234567890"))
      in
      (* Saturday 2026-05-23 cannot be the previous session for Tuesday. *)
      let () =
        assert_failure (fun () ->
          ignore
            (Live.decide ~provisional_close:2000.
               ~previous_session:"2026-05-23" ~equity:20000000.
               ~tw_positions:positions Live.Paper ~session_date:"2026-05-26"
               ~strat_path ~data_dir))
      in
      (* A 2026-05-22 snapshot does not match the 2026-05-26 session. *)
      let () =
        assert_failure (fun () ->
          ignore
            (Live.decide ~previous_session:"2026-05-22" ~equity:20000000.
               ~tw_positions:positions
               ~tw_snapshot:{ snapshot with datetime =
                 "2026-05-22T13:20:00" }
               Live.Paper ~session_date:"2026-05-26" ~strat_path ~data_dir))
      in
      (* Hour 25 is outside the valid 00-23 timestamp range. *)
      let () =
        assert_failure (fun () ->
          ignore
            (Live.decide ~previous_session:"2026-05-22" ~equity:20000000.
               ~tw_positions:positions
               ~tw_snapshot:{ snapshot with datetime =
                 "2026-05-26T25:20:00" }
               Live.Paper ~session_date:"2026-05-26" ~strat_path ~data_dir))
      in
      (* Zero close, bid, and ask provide no positive provisional price. *)
      let () =
        assert_failure (fun () ->
          ignore
            (Live.decide ~previous_session:"2026-05-22" ~equity:20000000.
               ~tw_positions:positions
               ~tw_snapshot:{ snapshot with close = 0.; bid = 0.; ask = 0. }
               Live.Paper ~session_date:"2026-05-26" ~strat_path ~data_dir))
      in
      (* An open of zero violates the positive OHLCV snapshot contract. *)
      let () =
        assert_failure (fun () ->
          ignore
            (Live.decide ~previous_session:"2026-05-22" ~equity:20000000.
               ~tw_positions:positions
               ~tw_snapshot:{ snapshot with open_ = 0. }
               Live.Paper ~session_date:"2026-05-26" ~strat_path ~data_dir))
      in
      (* TWD 2,003 is above the fixture session high of TWD 2,002. *)
      let () =
        assert_failure (fun () ->
          ignore
            (Live.decide ~previous_session:"2026-05-22" ~equity:20000000.
               ~tw_positions:positions
               ~tw_snapshot:{ snapshot with close = 2003. }
               Live.Paper ~session_date:"2026-05-26" ~strat_path ~data_dir))
      in
      (* NaN is not a finite positive simulation equity. *)
      let () =
        assert_failure (fun () ->
          ignore
            (Live.decide ~provisional_close:2000.
               ~previous_session:"2026-05-22" ~equity:Float.nan
               ~tw_positions:positions Live.Paper ~session_date:"2026-05-26"
               ~strat_path ~data_dir))
      in
      (* The 2890 fixture row is nonzero unrelated-symbol inventory. *)
      let () =
        assert_failure (fun () ->
          ignore
            (Live.decide ~provisional_close:2000.
               ~previous_session:"2026-05-22" ~equity:20000000.
               ~tw_positions:all_positions Live.Paper
               ~session_date:"2026-05-26" ~strat_path ~data_dir))
      in
      let unsupported =
        match positions with
        | first :: rest ->
            { first with Shioaji.cond = "ShortSelling" } :: rest
        | [] -> assert false
      in
      (* ShortSelling is outside the Cash and MarginTrading inventory contract. *)
      assert_failure (fun () ->
        ignore
          (Live.decide ~provisional_close:2000.
             ~previous_session:"2026-05-22" ~equity:20000000.
             ~tw_positions:unsupported Live.Paper
             ~session_date:"2026-05-26" ~strat_path ~data_dir))))

let tw_position cond lots : Shioaji.position =
  { id = 0; code = "2330"; cond; lots; yd_lots = lots; avg_price = 10.;
    last_price = 10.; loan_amount = 0.; interest = 0. }

let tw_trade id (leg : Live.leg) status deal_lots : Shioaji.trade =
  { order_id = id; code = "2330"; action = leg.action; cond = leg.cond;
    status; order_lots = leg.lots; deal_lots;
    deal_price = if deal_lots = 0 then None else Some 10.;
    order_datetime = "2026-05-22T13:20:00+08:00" }

let execute_tw_test ?(now = fun () -> "2026-05-22T13:20:00+08:00")
    ?(sleep = fun _ -> ())
    ?(place_order = fun _ ->
      { Shioaji.order_id = "1"; status = "PendingSubmit" })
    ?(orders_today = fun ~code:_ ~today:_ -> [])
    ?(costs = zero_costs) ~cash ~positions legs =
  Live.execute_tw_legs ~now ~sleep ~place_order ~orders_today
    ~exchange:"TSE" ~code:"2330" ~date:"2026-05-22" ~price:10.
    ~financing_ratio:0.6 ~costs ~cash ~positions legs

let scripted_placements entries =
  let entries = Queue.of_seq (List.to_seq entries) in
  fun (request : Shioaji.order_request) ->
    match Queue.take_opt entries with
    | None -> failwith "unexpected TW test order"
    | Some (order_id, (expected : Live.leg)) ->
        let () = assert (request.action = expected.action) in
        let () = assert (request.cond = expected.cond) in
        let () = assert (request.lots = expected.lots) in
        { Shioaji.order_id = order_id; status = "PendingSubmit" }

let test_tw_default_sell_has_no_per_share_fee () =
  let sell : Live.leg = { action = "Sell"; cond = "Cash"; lots = 1 } in
  let buy : Live.leg = { action = "Buy"; cond = "Cash"; lots = 1 } in
  let result =
    execute_tw_test
      ~place_order:(scripted_placements ["1", sell; "2", buy])
      ~orders_today:(fun ~code:_ ~today:_ ->
        [tw_trade "1" sell "Filled" 1; tw_trade "2" buy "Filled" 1])
      ~costs:(Engine.default_costs ~market:"tw" ~symbol:"2330")
      ~cash:70. ~positions:[tw_position "Cash" 1] [sell; buy]
  in
  (* Both scripted legs fill, so the execution records two trades. *)
  let () = assert (List.length result.Live.trades = 2) in
  (* TWD 70 + 10,000 sale - 20 commission - 30 tax exactly funds
     the TWD 10,000 repurchase plus its TWD 20 commission. *)
  let () = assert (result.Live.remaining = []) in
  (* Exact funding leaves no stop reason. *)
  assert (result.Live.stop_reason = None)

let test_tw_execution_stops_on_predecessor () =
  let sell : Live.leg = { action = "Sell"; cond = "Cash"; lots = 2 } in
  let buy : Live.leg =
    { action = "Buy"; cond = "MarginTrading"; lots = 2 }
  in
  let run status trades =
    let result =
      execute_tw_test
        ~place_order:(scripted_placements ["1", sell])
        ~orders_today:(fun ~code:_ ~today:_ -> trades)
        ~cash:0. ~positions:[tw_position "Cash" 2] [sell; buy]
    in
    (* A non-complete predecessor leaves the dependent buy unsubmitted. *)
    let () = assert (result.Live.remaining = [buy]) in
    (* The supplied status text is the exact executor stop reason. *)
    assert (result.Live.stop_reason = Some status)
  in
  (* One of two sold lots is a partial fill. *)
  let () =
    run "order 1 partially filled 1 of 2 lots"
      [tw_trade "1" sell "PartFilled" 1]
  in
  (* The broker status is explicitly Failed. *)
  let () = run "order 1 failed" [tw_trade "1" sell "Failed" 0] in
  (* An empty status response contains no order 1. *)
  let () = run "order 1 has no status" [] in
  (* A Buy status cannot confirm the requested Sell. *)
  run "order 1 status does not match request"
    [{ (tw_trade "1" sell "Filled" 2) with Shioaji.action = "Buy" }]

let test_tw_execution_times_out () =
  let buy : Live.leg = { action = "Buy"; cond = "Cash"; lots = 1 } in
  let sleeps = Queue.create () in
  let result =
    execute_tw_test
      ~sleep:(fun _ -> Queue.add () sleeps)
      ~place_order:(scripted_placements ["1", buy])
      ~orders_today:(fun ~code:_ ~today:_ ->
        [tw_trade "1" buy "Submitted" 0])
      ~cash:10000. ~positions:[] [buy]
  in
  (* Five status polls have four one-second sleeps between them. *)
  let () = assert (Queue.length sleeps = 4) in
  (* The posted leg has no successor, so no leg remains unsubmitted. *)
  let () = assert (result.Live.remaining = []) in
  (* Five unchanged Submitted statuses exhaust the poll budget. *)
  assert (result.Live.stop_reason = Some "order 1 status timed out")

let test_tw_execution_polls_zero_qty_pending () =
  let buy : Live.leg = { action = "Buy"; cond = "Cash"; lots = 1 } in
  let statuses =
    Queue.of_seq
      (List.to_seq
         [[{ (tw_trade "1" buy "PendingSubmit" 0) with
              Shioaji.order_lots = 0 }];
          [tw_trade "1" buy "Filled" 1]])
  in
  let sleeps = Queue.create () in
  let result =
    execute_tw_test
      ~sleep:(fun _ -> Queue.add () sleeps)
      ~place_order:(scripted_placements ["1", buy])
      ~orders_today:(fun ~code:_ ~today:_ -> Queue.take statuses)
      ~cash:10000. ~positions:[] [buy]
  in
  (* The two scripted status responses are both consumed. *)
  let () = assert (Queue.is_empty statuses) in
  (* One pending response before the fill causes exactly one sleep. *)
  let () = assert (Queue.length sleeps = 1) in
  (* The eventual complete fill leaves no unsubmitted leg. *)
  let () = assert (result.Live.remaining = []) in
  (* The eventual complete fill is successful. *)
  assert (result.Live.stop_reason = None)

let test_tw_execution_rechecks_cutoff () =
  let first : Live.leg = { action = "Buy"; cond = "Cash"; lots = 1 } in
  let second : Live.leg =
    { action = "Buy"; cond = "MarginTrading"; lots = 1 }
  in
  let times =
    Queue.of_seq
      (List.to_seq
         ["2026-05-22T13:20:00+08:00";
          "2026-05-22T13:20:00+08:00";
          "2026-05-22T13:25:00+08:00"])
  in
  let result =
    execute_tw_test ~now:(fun () -> Queue.take times)
      ~place_order:(scripted_placements ["1", first])
      ~orders_today:(fun ~code:_ ~today:_ ->
        [tw_trade "1" first "Filled" 1])
      ~cash:20000. ~positions:[] [first; second]
  in
  (* Submit, poll, and successor checks consume all three clock values. *)
  let () = assert (Queue.is_empty times) in
  (* The 13:25 successor check leaves the second leg unsubmitted. *)
  let () = assert (result.Live.remaining = [second]) in
  (* 13:25 is the exact submission-window cutoff. *)
  assert
    (result.Live.stop_reason =
     Some "submission window closed before Buy MarginTrading 1")

let test_tw_execution_advances_when_funded () =
  let sell : Live.leg = { action = "Sell"; cond = "Cash"; lots = 1 } in
  let refinance : Live.leg =
    { action = "Buy"; cond = "MarginTrading"; lots = 1 }
  in
  let ordinary : Live.leg =
    { action = "Buy"; cond = "MarginTrading"; lots = 1 }
  in
  let result =
    execute_tw_test
      ~place_order:
        (scripted_placements
           ["1", sell; "2", refinance; "3", ordinary])
      ~orders_today:(fun ~code:_ ~today:_ ->
        [tw_trade "1" sell "Filled" 1;
         tw_trade "2" refinance "Filled" 1;
         tw_trade "3" ordinary "Filled" 1])
      ~cash:0. ~positions:[tw_position "Cash" 1]
      [sell; refinance; ordinary]
  in
  (* Three funded legs produce three confirmed trades. *)
  let () = assert (List.length result.Live.trades = 3) in
  (* Every planned leg is submitted. *)
  let () = assert (result.Live.remaining = []) in
  (* Complete matching fills produce no stop. *)
  assert (result.Live.stop_reason = None)

let test_tw_execution_caps_rounded_funding () =
  let sell : Live.leg = { action = "Sell"; cond = "Cash"; lots = 1 } in
  let refinance : Live.leg =
    { action = "Buy"; cond = "MarginTrading"; lots = 1 }
  in
  let ordinary : Live.leg =
    { action = "Buy"; cond = "MarginTrading"; lots = 2 }
  in
  let capped = { ordinary with Live.lots = 1 } in
  let result =
    execute_tw_test
      ~place_order:
        (scripted_placements ["1", sell; "2", refinance; "3", capped])
      ~orders_today:(fun ~code:_ ~today:_ ->
        [tw_trade "1" sell "Filled" 1;
         tw_trade "2" refinance "Filled" 1;
         tw_trade "3" capped "Filled" 1])
      ~cash:0. ~positions:[tw_position "Cash" 1]
      [sell; refinance; ordinary]
  in
  (* The confirmed trade order_lots fields show requests of 1, 1, and 1. *)
  let () =
    assert
      (List.map (fun (trade : Shioaji.trade) -> trade.order_lots)
         result.Live.trades
       = [1; 1; 1])
  in
  (* The unfunded second ordinary lot remains. *)
  let () =
    assert
      (result.Live.remaining =
       [{ Live.action = "Buy"; cond = "MarginTrading"; lots = 1 }])
  in
  (* Two requested lots minus one funded lot gives the reported 2-to-1 cap. *)
  assert
    (result.Live.stop_reason =
     Some "capped Buy MarginTrading from 2 to 1 funded lots")

let test_tw_execution_tracks_refinanced_loan () =
  let cash_sell : Live.leg =
    { action = "Sell"; cond = "Cash"; lots = 1 }
  in
  let margin_buy : Live.leg =
    { action = "Buy"; cond = "MarginTrading"; lots = 1 }
  in
  let margin_sell : Live.leg =
    { action = "Sell"; cond = "MarginTrading"; lots = 1 }
  in
  let ordinary : Live.leg =
    { action = "Buy"; cond = "MarginTrading"; lots = 2 }
  in
  let capped = { ordinary with Live.lots = 1 } in
  let result =
    execute_tw_test
      ~place_order:
        (scripted_placements
           ["1", cash_sell; "2", margin_buy; "3", margin_sell;
            "4", margin_buy; "5", capped])
      ~orders_today:(fun ~code:_ ~today:_ ->
        [tw_trade "1" cash_sell "Filled" 1;
         tw_trade "2" margin_buy "Filled" 1;
         tw_trade "3" margin_sell "Filled" 1;
         tw_trade "4" margin_buy "Filled" 1;
         tw_trade "5" capped "Filled" 1])
      ~cash:0. ~positions:[tw_position "Cash" 1]
      [cash_sell; margin_buy; margin_sell; margin_buy; ordinary]
  in
  (* The confirmed order_lots fields show five one-lot requests. *)
  let () =
    assert
      (List.map (fun (trade : Shioaji.trade) -> trade.order_lots)
         result.Live.trades
       = [1; 1; 1; 1; 1])
  in
  (* Repaying the refinanced loan leaves only one ordinary lot funded. *)
  let () =
    assert
      (result.Live.remaining =
       [{ Live.action = "Buy"; cond = "MarginTrading"; lots = 1 }])
  in
  (* Two requested lots minus one funded lot gives the reported 2-to-1 cap. *)
  assert
    (result.Live.stop_reason =
     Some "capped Buy MarginTrading from 2 to 1 funded lots")

let test_tw_execution_remaining_stops () =
  let buy : Live.leg = { action = "Buy"; cond = "Cash"; lots = 1 } in
  let sell : Live.leg = { action = "Sell"; cond = "Cash"; lots = 2 } in
  let run ?(cash = 10000.) ?(positions = [])
      ?(place_order = scripted_placements ["1", buy]) statuses leg =
    execute_tw_test ~place_order
      ~orders_today:(fun ~code:_ ~today:_ -> statuses)
      ~cash ~positions [leg]
  in
  let filled = tw_trade "1" buy "Filled" 1 in
  (* Two rows with order id 1 are ambiguous, so no observed trade is chosen. *)
  let ambiguous = run [filled; filled] buy in
  let () =
    assert
      (ambiguous.Live.stop_reason = Some "order 1 has ambiguous status")
  in
  (* A Filled row with no weighted deal price cannot settle cash. *)
  let invalid_price = run [{ filled with Shioaji.deal_price = None }] buy in
  let () =
    assert
      (invalid_price.Live.stop_reason =
       Some "order 1 filled without a valid price")
  in
  (* One dealt lot under Submitted is unconfirmed partial exposure. *)
  let pending_partial = run [tw_trade "1" buy "Submitted" 1] buy in
  let () =
    assert
      (pending_partial.Live.stop_reason =
       Some "order 1 has unconfirmed partial exposure")
  in
  (* A two-lot status cannot confirm the one-lot request. *)
  let wrong_quantity =
    run
      [{ (tw_trade "1" buy "Submitted" 0) with Shioaji.order_lots = 2 }]
      buy
  in
  let () =
    assert
      (wrong_quantity.Live.stop_reason =
       Some "order 1 status quantity does not match request")
  in
  (* Mystery is outside the executor's documented broker status set. *)
  let unsupported = run [tw_trade "1" buy "Mystery" 0] buy in
  let () =
    assert
      (unsupported.Live.stop_reason =
       Some "order 1 has unsupported status Mystery")
  in
  (* A placement exception makes POST outcome uncertain and forbids retry. *)
  let uncertain =
    run ~place_order:(fun _ -> failwith "lost response") [] buy
  in
  let () =
    assert
      (uncertain.Live.stop_reason =
       Some "order submission uncertain: lost response")
  in
  (* An empty broker id cannot be polled safely. *)
  let no_id =
    run
      ~place_order:(fun _ ->
        { Shioaji.order_id = ""; status = "PendingSubmit" })
      [] buy
  in
  let () =
    assert
      (no_id.Live.stop_reason = Some "order submission returned no order id")
  in
  (* One cash lot cannot satisfy a two-lot sell request. *)
  let inventory =
    run ~cash:0. ~positions:[tw_position "Cash" 1]
      ~place_order:(fun _ -> assert false) [] sell
  in
  let () =
    assert
      (inventory.Live.stop_reason =
       Some "insufficient Cash inventory for 2 lots")
  in
  (* Zero cash funds zero lots of a TWD 10,000 cash buy. *)
  let cash =
    run ~cash:0. ~place_order:(fun _ -> assert false) [] buy
  in
  let () =
    assert
      (cash.Live.stop_reason =
       Some "insufficient confirmed cash for Buy Cash 1")
  in
  (* TWD 10,000 funds at the TWD 10 plan price, but a TWD 11 fill costs
     TWD 11,000 and overruns the confirmed budget by TWD 1,000. *)
  let overrun =
    run [{ filled with Shioaji.deal_price = Some 11. }] buy
  in
  assert
    (overrun.Live.stop_reason =
     Some "confirmed fill exceeded cash budget by 1000")


let test_tw_previous_session_calendar () =
  let raw =
    {|{"status":200,"data":[{"date":"2026-05-26"},{"date":"2026-05-22"},{"date":"2026-05-21"}]}|}
  in
  (* Before Tuesday 2026-05-26, the fixture's latest earlier row is
     Friday 2026-05-22 because Monday is absent. *)
  let () =
    assert
      (Data.parse_previous_trading_day ~before:"2026-05-26" raw
       = "2026-05-22")
  in
  (* An empty data array has no previous trading date. *)
  let () =
    assert_failure (fun () ->
      ignore
        (Data.parse_previous_trading_day ~before:"2026-05-26"
           {|{"status":200,"data":[]}|}))
  in
  (* API status 400 is not a successful calendar response. *)
  let () =
    assert_failure (fun () ->
      ignore
        (Data.parse_previous_trading_day ~before:"2026-05-26"
           {|{"status":400,"data":[{"date":"2026-05-22"}]}|}))
  in
  (* February 30 is not a valid Gregorian calendar row. *)
  let () =
    assert_failure (fun () ->
      ignore
        (Data.parse_previous_trading_day ~before:"2026-05-26"
           {|{"status":200,"data":[{"date":"2026-02-30"}]}|}))
  in
  (* A signed month does not match the YYYY-MM-DD digit shape. *)
  let () =
    assert_failure (fun () ->
      ignore
        (Data.parse_previous_trading_day ~before:"2026-05-26"
           {|{"status":200,"data":[{"date":"2026-+1-08"}]}|}))
  in
  (* The request bound itself must also have YYYY-MM-DD digit shape. *)
  assert_failure (fun () ->
    ignore (Data.parse_previous_trading_day ~before:"2026-+1-08" raw))

let test_shioaji_settlement_amounts () =
  let raw =
    {|[{"date":"2026-05-22","amount":0,"T":0},{"date":"2026-05-25","amount":-30000,"T":1},{"date":"2026-05-26","amount":50000,"T":2}]|}
  in
  let amounts =
    Shioaji.parse_settlements raw
    |> List.map (fun (item : Shioaji.settlement) -> item.day, item.amount)
  in
  (* The three fixture rows carry (T, amount) values (0, 0), (1, -30000),
     and (2, 50000) in that order. *)
  assert (amounts = [0, 0.; 1, -30000.; 2, 50000.])

let test_shioaji_weighted_fill_price () =
  let raw =
    {|[{"contract":{"code":"2890"},"order":{"id":"weighted","action":"Buy","order_cond":"Cash","quantity":3},"status":{"id":"weighted","status":"Filled","order_quantity":3,"deal_quantity":3,"order_datetime":"2026-05-22T13:20:00+08:00","deals":[{"price":27,"quantity":1},{"price":30,"quantity":2}]}}]|}
  in
  match Shioaji.parse_orders_today ~code:"2890" ~today:"2026-05-22" raw with
  | [trade] ->
      (* Fixture deal quantities 1 + 2 = 3 lots. *)
      let () = assert (trade.Shioaji.deal_lots = 3) in
      (* (TWD 27 * 1 + TWD 30 * 2) / 3 = TWD 29. *)
      assert (trade.Shioaji.deal_price = Some 29.)
  | _ -> assert false

let () =
  let () = test_daytrade_cli () in
  let () = test_intraday_latency () in
  let () = test_intraday_last_decision () in
  let () = test_intraday_forced_flat () in
  let () = test_intraday_cap () in
  let () = test_intraday_drift () in
  let () = test_intraday_normalization () in
  let () = test_intraday_costs () in
  let () = test_intraday_capital_costs () in
  let () = test_intraday_round_trips () in
  let () = test_intraday_session_boundaries () in
  let () = test_bars_declaration () in
  let () = test_session_series () in
  let () = test_bars_run_routing () in
  let () = test_minute_data () in
  test_alpaca_base_urls ();
  test_alpaca_clock_parse ();
  test_alpaca_account_parse ();
  test_alpaca_position_parse ();
  test_alpaca_order_parse ();
  test_alpaca_snapshot_parse ();
  test_engine_effective_targets ();
  test_live_pure_decisions ();
  test_live_schedule ();
  test_live_startup_guard ();
  test_live_commands_reject_tw ();
  let () = test_tw_live_rejects_production_equity () in
  test_target_rejects_invalid_provisional_close ();
  test_profile_of_market ();
  test_parser ();
  test_default_costs ();
  test_parser_aliases ();
  test_filter_dates ();
  test_stock_statement ();
  test_multi_stock_compile ();
  test_multi_stock_errors ();
  test_duplicate_symbol_aliases ();
  test_indicators ();
  test_alias_qualified_labels ();
  test_target_style ();
  test_hold_tie_break ();
  test_order_style ();
  test_style_errors ();
  test_engine_drift ();
  test_inventory_split ();
  test_maintenance_at_entry ();
  test_interest_liability ();
  test_forced_repayment_is_proportional ();
  test_interest_settlement_window ();
  test_margin_term_rollover ();
  test_margin_term_underwater_partial ();
  test_margin_term_disabled ();
  test_engine_initial_margin_clamp ();
  test_cap_reachable ();
  test_funding_clamp_covers_fixed_refinance_costs ();
  test_engine_mixed_ratio_clamp ();
  test_loan_order_independence ();
  test_sell_settlement_order_independence ();
  test_call_settlement_order_independence ();
  test_loan_sell_then_buy ();
  test_e1_order_independence ();
  test_refinance_scale_in ();
  test_sell_deficit_waits_for_refinancing ();
  test_sell_only_fee_does_not_refinance ();
  test_residual_debt_does_not_force_refinance ();
  test_refinance_costs ();
  test_refinance_order_independence ();
  test_margin_refinance_with_interest ();
  test_e1_drift_reversal ();
  test_e1_sell_then_buy ();
  test_call_liquidates_margin_only ();
  test_insolvent_call_sells_all_at_open ();
  test_engine_margin_call ();
  test_engine_bankruptcy ();
  test_open_next_bankruptcy_freezes_at_close ();
  test_engine_insolvent_gap ();
  test_engine_insolvent_min_fee ();
  test_engine_exit_fee_bankruptcy ();
  test_engine_zero_value_exit_preserves_liability ();
  test_tw_dividend_receivable ();
  test_tw_dividend_paydown_interest ();
  test_tw_dividend_pure_paydown_preserves_drift ();
  test_tw_dividend_excess_spill ();
  test_us_dividend_refill_cost ();
  test_dividend_tax ();
  test_dividend_tax_cli ();
  test_frozen_dividend_reduces_debt ();
  test_no_dividend_events_identity ();
  test_receivable_not_duplicated_on_force_close ();
  test_unlevered_dividend_refill_cash_clamp ();
  test_receivable_not_available_to_planner ();
  test_intersected_ex_date ();
  test_engine_buyhold_costs ();
  test_exact_cash_funding ();
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
  test_margin_cli ();
  test_prepend_rows ();
  test_head_probe_gate ();
  test_plot_script ();
  test_back_adjust_events ();
  test_cash_dividend_parse ();
  test_cash_dividend_fallback_derivation ();
  test_tiingo_snap ();
  test_tiingo_token_required ();
  test_tiingo_transform ();
  test_tiingo_append_seam ();
  test_two_price_planes ();
  test_dividend_cash_split_restatement ();
  test_cash_restatement_through_stock_dividend ();
  test_same_day_unit_factor_restates_cash ();
  test_us_loader_parity ();
  test_fallback_preserves_direct_overlap ();
  test_stock_dividend_restates_volume ();
  test_load_adjustments ();
  let () = test_tw_adjustment_refresh_horizon () in
  let () = test_tw_adjustment_refresh_failure () in
  test_financing_ratio ();
  test_nested_cache_layout ();
  test_event_transform ();
  test_mixed_market_rejection ();
  test_us_interest_day_count ();
  test_us_default_costs ();
  test_taf_per_share_charge ();
  test_taf_floor ();
  test_taf_cap ();
  test_taf_inactive_without_capital ();
  test_taf_zero_for_tw ();
  test_taf_zero_cap_means_uncapped ();
  test_us_tiered_maintenance ();
  test_us_maintenance_breach ();
  test_us_minimum_cure ();
  test_us_maintenance_flat_override ();
  test_tw_maintenance_override_none ();
  test_us_cure_interest_single_charge ();
  test_cure_shortfall_preserves_liability ();
  test_us_cure_tail_aware ();
  let () = test_engine_fill_planner () in
  let () = test_shioaji_info_parse () in
  let () = test_shioaji_snapshot_parse () in
  let () = test_shioaji_positions_parse () in
  let () = test_shioaji_position_details_parse () in
  let () = test_shioaji_balance_parse () in
  let () = test_shioaji_placed_parse () in
  let () = test_shioaji_parser_rejections () in
  let () = test_shioaji_orders_today_parse () in
  let () = test_tw_live_phase () in
  let () = test_tw_live_exchange () in
  let () = test_tw_live_equity () in
  let () = test_tw_live_plan_legs () in
  let () = test_tw_live_startup_guard () in
  let () = test_tw_maturity_rollover_legs () in
  let () = test_tw_live_decide_override () in
  let () = test_tw_execution_stops_on_predecessor () in
  let () = test_tw_execution_times_out () in
  let () = test_tw_default_sell_has_no_per_share_fee () in
  let () = test_tw_execution_polls_zero_qty_pending () in
  let () = test_tw_execution_rechecks_cutoff () in
  let () = test_tw_execution_advances_when_funded () in
  let () = test_tw_execution_caps_rounded_funding () in
  let () = test_tw_execution_tracks_refinanced_loan () in
  let () = test_tw_execution_remaining_stops () in
  let () = test_tw_previous_session_calendar () in
  let () = test_shioaji_settlement_amounts () in
  let () = test_shioaji_weighted_fill_price () in
  print_endline "ok"
