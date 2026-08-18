let usage =
  "usage:\n\
   \  bt fetch [MARKET/SYMBOL] [--market tw|us] [--symbol SYM] [--from YYYY-MM-DD] [--to YYYY-MM-DD] [--data-dir DIR]\n\
   \           positional MARKET/SYMBOL is equivalent to --market and --symbol\n\
   \  bt run STRAT_FILE --market tw|us --symbol SYM [--from D] [--to D]\n\
   \         [--benchmark SYM] [--benchmark-market tw|us] [-p name=value ...]\n\
   \         [--fill open|close] [--fee-bps F] [--tax-bps F] [--slip-bps F]\n\
   \         [--data-dir DIR] [--out-dir DIR] [--no-plot]"

let help =
  usage ^
  "\n\ncommands:\n\
   \  fetch  Download market data from FinMind into the local cache.\n\
   \  run    Run a strategy with cached data and compare it with a benchmark.\n\n\
   Fetch requires FINMIND_TOKEN.\n\
   Full reference: docs/cli.md"

let usage_error message =
  if message <> "" then prerr_endline message;
  prerr_endline usage;
  exit 2

let today () =
  let time = Unix.localtime (Unix.time ()) in
  Printf.sprintf "%04d-%02d-%02d"
    (time.Unix.tm_year + 1900) (time.Unix.tm_mon + 1) time.Unix.tm_mday

let fetch argv =
  let market = ref "" in
  let symbol = ref "" in
  let from_ = ref "1994-10-01" in
  let to_ = ref (today ()) in
  let data_dir = ref "data" in
  let rec options =
    [ ("--market", Arg.Set_string market, "tw or us");
      ("--symbol", Arg.Set_string symbol, "FinMind symbol");
      ("--from", Arg.Set_string from_, "start date (YYYY-MM-DD)");
      ("--to", Arg.Set_string to_, "end date (YYYY-MM-DD)");
      ("--data-dir", Arg.Set_string data_dir, "cache directory");
      ("-h",
       Arg.Unit
         (fun () -> raise (Arg.Help (Arg.usage_string options usage))),
       "show this help") ]
  in
  let has_positional = ref false in
  let anonymous value =
    if !has_positional then
      raise (Arg.Bad (Printf.sprintf "unexpected argument %S; expected one positional MARKET/SYMBOL" value));
    match String.index_opt value '/' with
    | Some index when index > 0 && index < String.length value - 1 ->
        has_positional := true;
        market := String.sub value 0 index;
        symbol := String.sub value (index + 1) (String.length value - index - 1)
    | _ ->
        raise (Arg.Bad
          (Printf.sprintf "invalid fetch argument %S; expected MARKET/SYMBOL" value))
  in
  (try Arg.parse_argv argv options anonymous usage with
   | Arg.Bad message ->
       prerr_string message;
       exit 2
   | Arg.Help message ->
       print_string message;
       exit 0);
  if !market = "" then usage_error "fetch: --market is required";
  if !market <> "tw" && !market <> "us" then
    usage_error "fetch: --market must be tw or us";
  if !symbol = "" then usage_error "fetch: --symbol is required";
  Btlib.Data.fetch ~market:!market ~symbol:!symbol ~from_:!from_ ~to_:!to_
    ~data_dir:!data_dir

let parse_parameter parameters value =
  match String.index_opt value '=' with
  | Some index when index > 0 && index < String.length value - 1 ->
      let name = String.sub value 0 index in
      let raw_value =
        String.sub value (index + 1) (String.length value - index - 1)
      in
      let number =
        try float_of_string raw_value with Failure _ ->
          raise (Arg.Bad (Printf.sprintf "invalid parameter %S; expected name=value" value))
      in
      parameters := (name, number) :: !parameters
  | _ ->
      raise (Arg.Bad (Printf.sprintf "invalid parameter %S; expected name=value" value))

let apply_cost_overrides defaults fee_bps tax_bps slip_bps :
    Btlib.Engine.costs =
  { fee_bps =
      (match fee_bps with Some value -> value | None -> defaults.Btlib.Engine.fee_bps);
    tax_bps =
      (match tax_bps with Some value -> value | None -> defaults.Btlib.Engine.tax_bps);
    slip_bps =
      (match slip_bps with Some value -> value | None -> defaults.Btlib.Engine.slip_bps) }

let load_bars ~market ~symbol ~from_ ~to_ ~data_dir =
  let cache_path =
    Filename.concat (Filename.concat data_dir market) (symbol ^ ".csv")
  in
  if not (Sys.file_exists cache_path) then begin
    let command = Buffer.create 96 in
    Printf.bprintf command "bt fetch --market %s --symbol %s" market symbol;
    (match from_ with
     | None -> ()
     | Some date -> Printf.bprintf command " --from %s" date);
    (match to_ with
     | None -> ()
     | Some date -> Printf.bprintf command " --to %s" date);
    Printf.bprintf command " --data-dir %s" data_dir;
    failwith
      (Printf.sprintf "%s not found; run %s" cache_path (Buffer.contents command))
  end;
  Btlib.Data.load ~market ~symbol ~from_ ~to_ ~data_dir

let overlap_bars
    (strategy_bars : Btlib.Data.bar array)
    (benchmark_bars : Btlib.Data.bar array) =
  let strategy_index = ref 0 in
  let benchmark_index = ref 0 in
  let first = ref None in
  let last = ref None in
  let common_dates = ref 0 in
  while strategy_index.contents < Array.length strategy_bars &&
        benchmark_index.contents < Array.length benchmark_bars do
    let strategy_date = strategy_bars.(!strategy_index).date in
    let benchmark_date = benchmark_bars.(!benchmark_index).date in
    let order = String.compare strategy_date benchmark_date in
    if order < 0 then incr strategy_index
    else if order > 0 then incr benchmark_index
    else begin
      if !first = None then first := Some strategy_date;
      last := Some strategy_date;
      incr common_dates;
      incr strategy_index;
      incr benchmark_index
    end
  done;
  match !first, !last with
  | Some first, Some last when !common_dates >= 2 ->
      let from_ = Some first in
      let to_ = Some last in
      (Btlib.Data.filter_range ~from_ ~to_ strategy_bars,
       Btlib.Data.filter_range ~from_ ~to_ benchmark_bars)
  | _ ->
      failwith "strategy and benchmark have fewer than 2 common dates"

let benchmark_strategy length : Btlib.Engine.strategy =
  { target = Array.make length 1. }

let run argv =
  let strategy_file = ref None in
  let market = ref "" in
  let symbol = ref "" in
  let from_ = ref None in
  let to_ = ref None in
  let benchmark = ref "00685L" in
  let benchmark_market = ref "tw" in
  let parameters = ref [] in
  let fee_bps = ref None in
  let tax_bps = ref None in
  let slip_bps = ref None in
  let data_dir = ref "data" in
  let out_dir = ref "out" in
  let no_plot = ref false in
  let fill = ref Btlib.Engine.Close_same in
  let rec options =
    [ ("--market", Arg.Set_string market, "tw or us");
      ("--symbol", Arg.Set_string symbol, "strategy symbol");
      ("--from", Arg.String (fun value -> from_ := Some value), "start date");
      ("--to", Arg.String (fun value -> to_ := Some value), "end date");
      ("--benchmark", Arg.Set_string benchmark, "benchmark symbol (default 00685L)");
      ("--benchmark-market", Arg.Set_string benchmark_market, "benchmark market");
      ("--fill",
       Arg.String
         (fun value ->
           match value with
           | "open" -> fill := Btlib.Engine.Open_next
           | "close" -> fill := Btlib.Engine.Close_same
           | _ -> raise (Arg.Bad "--fill must be open or close")),
       "fill mode: open or close (default close)");
      ("-p", Arg.String (parse_parameter parameters), "parameter override name=value");
      ("--fee-bps", Arg.Float (fun value -> fee_bps := Some value), "fee basis points");
      ("--tax-bps", Arg.Float (fun value -> tax_bps := Some value), "tax basis points");
      ("--slip-bps", Arg.Float (fun value -> slip_bps := Some value), "slippage basis points");
      ("--data-dir", Arg.Set_string data_dir, "cache directory");
      ("--out-dir", Arg.Set_string out_dir, "output directory");
      ("--no-plot", Arg.Set no_plot, "skip equity graph");
      ("-h",
       Arg.Unit
         (fun () -> raise (Arg.Help (Arg.usage_string options usage))),
       "show this help") ]
  in
  let anonymous value =
    match !strategy_file with
    | None -> strategy_file := Some value
    | Some _ -> raise (Arg.Bad (Printf.sprintf "unexpected argument %S" value))
  in
  (try Arg.parse_argv argv options anonymous usage with
   | Arg.Bad message ->
       prerr_string message;
       exit 2
   | Arg.Help message ->
       print_string message;
       exit 0);
  let strategy_file =
    match !strategy_file with
    | Some path -> path
    | None -> usage_error "run: STRAT_FILE is required"
  in
  if !market = "" then usage_error "run: --market is required";
  if !market <> "tw" && !market <> "us" then
    usage_error "run: --market must be tw or us";
  if !symbol = "" then usage_error "run: --symbol is required";
  if !benchmark_market <> "tw" && !benchmark_market <> "us" then
    usage_error "run: --benchmark-market must be tw or us";
  if !benchmark = "" then usage_error "run: --benchmark must not be empty";
  let strategy_bars =
    load_bars ~market:!market ~symbol:!symbol
      ~from_:!from_ ~to_:!to_ ~data_dir:!data_dir
  in
  let strategy_first = strategy_bars.(0).date in
  let strategy_last = strategy_bars.(Array.length strategy_bars - 1).date in
  let benchmark_bars =
    load_bars ~market:!benchmark_market ~symbol:!benchmark
      ~from_:(Some strategy_first) ~to_:(Some strategy_last)
      ~data_dir:!data_dir
  in
  let strategy_bars, benchmark_bars =
    overlap_bars strategy_bars benchmark_bars
  in
  let strategy =
    Btlib.Dsl.compile strategy_file ~params:!parameters strategy_bars
  in
  let strategy_defaults =
    Btlib.Engine.default_costs ~market:!market ~symbol:!symbol
  in
  let benchmark_defaults =
    Btlib.Engine.default_costs
      ~market:!benchmark_market ~symbol:!benchmark
  in
  let strategy_costs =
    apply_cost_overrides strategy_defaults !fee_bps !tax_bps !slip_bps
  in
  let benchmark_costs =
    apply_cost_overrides benchmark_defaults !fee_bps !tax_bps !slip_bps
  in
  let strategy_result =
    Btlib.Engine.run strategy_bars strategy strategy_costs ~fill:!fill
  in
  let benchmark_result =
    Btlib.Engine.run benchmark_bars
      (benchmark_strategy (Array.length benchmark_bars)) benchmark_costs
      ~fill:!fill
  in
  Btlib.Report.print
    ~strategy:strategy_result ~benchmark:benchmark_result
    ~target:strategy.target ~fill:!fill;
  Btlib.Report.write_csvs
    ~out_dir:!out_dir ~strategy:strategy_result ~benchmark:benchmark_result;
  if not !no_plot then Btlib.Report.write_png ~out_dir:!out_dir

let dispatch () =
  if Array.length Sys.argv < 2 then begin
    prerr_endline help;
    exit 2
  end;
  match Sys.argv.(1) with
  | "--help" | "-h" | "help" -> print_endline help
  | "fetch" -> fetch (Array.sub Sys.argv 1 (Array.length Sys.argv - 1))
  | "run" -> run (Array.sub Sys.argv 1 (Array.length Sys.argv - 1))
  | command -> usage_error (Printf.sprintf "unknown subcommand %S" command)

let () =
  try dispatch () with
  | Failure message | Sys_error message ->
      prerr_endline message;
      exit 1
  | Unix.Unix_error (error, function_name, argument) ->
      let context = if argument = "" then function_name else function_name ^ " " ^ argument in
      prerr_endline (Printf.sprintf "%s: %s" context (Unix.error_message error));
      exit 1
