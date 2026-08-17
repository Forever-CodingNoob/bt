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

let test_engine () =
  let strategy : Engine.strategy =
    { entry = [|false; true; false; false; false|];
      exit_ = Array.make 5 false;
      size = Array.make 5 1. }
  in
  let zero_costs : Engine.costs =
    { fee_bps = 0.; tax_bps = 0.; slip_bps = 0. }
  in
  let zero_result = Engine.run sample_bars strategy zero_costs in
  assert_close ~tolerance:1e-12 engine_zero_expected (final_equity zero_result);
  let fee_costs : Engine.costs =
    { fee_bps = 100.; tax_bps = 0.; slip_bps = 0. }
  in
  let fee_result = Engine.run sample_bars strategy fee_costs in
  assert_close ~tolerance:1e-12 engine_fee_expected (final_equity fee_result)

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
    { fee_bps = 0.; tax_bps = 0.; slip_bps = 0. }
  in
  let result = Engine.run bars strategy costs in
  assert (List.length result.trades = 4);
  let first = List.hd result.trades in
  assert (first.entry_date = "2020-04-01");
  assert_close 95.06670608432421 first.entry_px;
  assert (first.exit_date = "2020-05-26");
  assert_close 112.60606577730466 first.exit_px;
  assert_close (first.exit_px /. first.entry_px -. 1.) first.net_ret;
  assert_close golden_expected (final_equity result)

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
  assert (contains Report.plot_script "matplotlib.use(\"Agg\")");
  assert (contains Report.plot_script "fig.savefig")

let test_detect_splits () =
  (* 25:1 split between the second and third bar; normal moves elsewhere *)
  let bars =
    [| bar "2020-01-01" 100. 101.;
       bar "2020-01-02" 101. 102.;
       bar "2020-01-03" 4.1 4.2;
       bar "2020-01-06" 4.2 4.3 |]
  in
  match Data.detect_splits bars with
  | [| (date, factor) |] ->
      assert (date = "2020-01-03");
      assert_close (4.1 /. 102.) factor
  | _ -> assert false

let () =
  test_parser ();
  test_indicators ();
  test_engine ();
  test_golden ();
  test_plot_script ();
  test_detect_splits ();
  print_endline "ok"
