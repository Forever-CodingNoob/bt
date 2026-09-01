let usage =
  "usage:\n\
   \  bt fetch [MARKET/SYMBOL] [--market tw|us] [--symbol SYM] [--from YYYY-MM-DD] [--to YYYY-MM-DD] [--data-dir DIR]\n\
   \           positional MARKET/SYMBOL is equivalent to --market and --symbol\n\
   \  bt run STRAT... [--baseline M/SYM] [--from D] [--to D]\n\
   \         [-p name=value ...] [--fill open|close]\n\
   \         [--fee-bps F] [--tax-bps F] [--slip-bps F] [--min-fee F]\n\
   \         [--financing-rate PCT] [--maintenance-ratio PCT] [--financing-ratio PCT]\n\
   \         [--loan-term-months N]\n\
   \         [--capital TWD] [--data-dir DIR] [--out-dir DIR] [--out-name NAME] [--no-plot]"

let help =
  usage ^
  "\n\ncommands:\n\
   \  fetch  Download market data from FinMind into the local cache.\n\
   \  run    Run strategies with cached data and compare them with a baseline.\n\n\
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

let parse_market_symbol label value =
  match String.index_opt value '/' with
  | Some index when index > 0 && index < String.length value - 1 ->
      (String.sub value 0 index,
       String.sub value (index + 1) (String.length value - index - 1))
  | _ ->
      raise (Arg.Bad
        (Printf.sprintf "invalid %s %S; expected MARKET/SYMBOL" label value))

let fetch argv =
  let market = ref "" in
  let symbol = ref "" in
  let from_ = ref None in
  let to_ = ref (today ()) in
  let data_dir = ref "data" in
  let rec options =
    [ ("--market", Arg.Set_string market, "tw or us");
      ("--symbol", Arg.Set_string symbol, "FinMind symbol");
      ("--from", Arg.String (fun value -> from_ := Some value), "start date; give an explicit date to backfill an existing cache (default 1994-10-01 for new caches)");
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
    let parsed_market, parsed_symbol =
      parse_market_symbol "fetch argument" value
    in
    has_positional := true;
    market := parsed_market;
    symbol := parsed_symbol
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

let apply_cost_overrides defaults fee_bps tax_bps slip_bps min_fee :
    Btlib.Engine.costs =
  { fee_bps =
      (match fee_bps with Some value -> value | None -> defaults.Btlib.Engine.fee_bps);
    tax_bps =
      (match tax_bps with Some value -> value | None -> defaults.Btlib.Engine.tax_bps);
    slip_bps =
      (match slip_bps with Some value -> value | None -> defaults.Btlib.Engine.slip_bps);
    min_fee =
      (match min_fee with Some value -> value | None -> defaults.Btlib.Engine.min_fee) }

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

type strategy_input = {
  name : string;
  stocks : (string option * string * string) list;
  ast : Btlib.Ast.file;
  declarations : (string * float) list;
  bars : Btlib.Data.bar array list;
}

let strategy_name path =
  Filename.remove_extension (Filename.basename path)

let common_dates = function
  | [] -> []
  | first :: rest ->
      let initial =
        Array.to_list
          (Array.map
             (fun (bar : Btlib.Data.bar) -> bar.date)
             first)
        |> List.sort_uniq String.compare
      in
      List.fold_left
        (fun common bars ->
          let present = Hashtbl.create (Array.length bars) in
          Array.iter
            (fun (bar : Btlib.Data.bar) ->
              Hashtbl.replace present bar.date ())
            bars;
          List.filter (fun date -> Hashtbl.mem present date) common)
        initial rest

let baseline_strategy length : Btlib.Engine.strategy =
  { targets = [| Array.make length 1. |] }

let run argv =
  let strategy_files = ref [] in
  let from_ = ref None in
  let to_ = ref None in
  let baseline = ref None in
  let parameters = ref [] in
  let capital = ref None in
  let fee_bps = ref None in
  let tax_bps = ref None in
  let slip_bps = ref None in
  let min_fee = ref None in
  let financing_rate = ref 6.35 in
  let maintenance_ratio = ref 130. in
  let financing_ratio = ref None in
  let loan_term_months = ref 18 in
  let data_dir = ref "data" in
  let out_dir = ref "out" in
  let out_name = ref None in
  let no_plot = ref false in
  let fill = ref Btlib.Engine.Close_same in
  let rec options =
    [ ("--from", Arg.String (fun value -> from_ := Some value), "start date");
      ("--to", Arg.String (fun value -> to_ := Some value), "end date");
      ("--baseline",
       Arg.String
         (fun value ->
           baseline := Some (parse_market_symbol "baseline" value)),
       "baseline market/symbol");
      ("--fill",
       Arg.String
         (fun value ->
           match value with
           | "open" -> fill := Btlib.Engine.Open_next
           | "close" -> fill := Btlib.Engine.Close_same
           | _ -> raise (Arg.Bad "--fill must be open or close")),
       "fill mode: open or close (default close)");
      ("--capital",
       Arg.Float (fun value -> capital := Some value),
       "portfolio starting value in TWD; enables the per-order minimum fee");
      ("-p", Arg.String (parse_parameter parameters), "parameter override name=value");
      ("--fee-bps", Arg.Float (fun value -> fee_bps := Some value), "fee basis points");
      ("--tax-bps", Arg.Float (fun value -> tax_bps := Some value), "tax basis points");
      ("--slip-bps", Arg.Float (fun value -> slip_bps := Some value), "slippage basis points");
      ("--min-fee", Arg.Float (fun value -> min_fee := Some value),
       "minimum fee per order in TWD");
      ("--financing-rate",
       Arg.Float (fun value -> financing_rate := value),
       "annual financing rate percent");
      ("--maintenance-ratio",
       Arg.Float (fun value -> maintenance_ratio := value),
       "maintenance ratio percent");
      ("--financing-ratio",
       Arg.Float (fun value -> financing_ratio := Some value),
       "uniform financing ratio percent");
      ("--loan-term-months",
       Arg.Set_int loan_term_months,
       "TW margin-loan term in months; 0 disables (default 18)");
      ("--data-dir", Arg.Set_string data_dir, "cache directory");
      ("--out-dir", Arg.Set_string out_dir, "output directory");
      ("--out-name", Arg.String (fun value -> out_name := Some value), "output stem");
      ("--no-plot", Arg.Set no_plot, "skip equity graph");
      ("-h",
       Arg.Unit
         (fun () -> raise (Arg.Help (Arg.usage_string options usage))),
       "show this help") ]
  in
  let anonymous value = strategy_files := value :: !strategy_files in
  (try Arg.parse_argv argv options anonymous usage with
   | Arg.Bad message ->
       prerr_string message;
       exit 2
   | Arg.Help message ->
       print_string message;
       exit 0);
  let strategy_files = List.rev !strategy_files in
  if strategy_files = [] then usage_error "run: at least one STRAT file is required";
  if !loan_term_months < 0 then
    usage_error "run: --loan-term-months must be 0 or greater";
  (match !baseline with
   | Some (market, _) when market <> "tw" && market <> "us" ->
       usage_error "run: --baseline market must be tw or us"
   | _ -> ());
  let names = List.map strategy_name strategy_files in
  let seen = Hashtbl.create (List.length names) in
  List.iter
    (fun name ->
      if Hashtbl.mem seen name then
        usage_error (Printf.sprintf "run: duplicate strat basename %S" name);
      Hashtbl.replace seen name ())
    names;
  if !baseline <> None && List.exists (( = ) "baseline") names then
    usage_error "run: strat basename \"baseline\" conflicts with --baseline";
  let inputs =
    List.map2
      (fun path name ->
        let ast = Btlib.Dsl.parse_file path in
        let stocks = Btlib.Dsl.stocks_of ~filename:path ast in
        let bars =
          List.map
            (fun (_, market, symbol) ->
              load_bars ~market ~symbol
                ~from_:!from_ ~to_:!to_ ~data_dir:!data_dir)
            stocks
        in
        { name;
          stocks;
          ast;
          declarations = Btlib.Dsl.declared_params_ast ast;
          bars })
      strategy_files names
  in
  let baseline_bars =
    match !baseline with
    | None -> None
    | Some (market, symbol) ->
        Some
          (market, symbol,
           load_bars ~market ~symbol
             ~from_:!from_ ~to_:!to_ ~data_dir:!data_dir)
  in
  let arrays = List.concat_map (fun input -> input.bars) inputs in
  let arrays =
    match baseline_bars with
    | None -> arrays
    | Some (_, _, bars) -> arrays @ [bars]
  in
  let dates = common_dates arrays in
  if List.length dates < 2 then
    failwith "strats have fewer than 2 common trading dates";
  let keep = Hashtbl.create (List.length dates) in
  List.iter (fun date -> Hashtbl.replace keep date ()) dates;
  let filter bars =
    Btlib.Data.filter_dates ~keep:(fun date -> Hashtbl.mem keep date) bars
  in
  let inputs =
    List.map
      (fun input -> { input with bars = List.map filter input.bars })
      inputs
  in
  let baseline_bars =
    match baseline_bars with
    | None -> None
    | Some (market, symbol, bars) -> Some (market, symbol, filter bars)
  in
  List.iter
    (fun (name, _) ->
      if not
          (List.exists
             (fun input -> List.mem_assoc name input.declarations)
             inputs)
      then failwith (Printf.sprintf "unknown parameter %s" name))
    !parameters;
  let ratio_for symbol =
    match !financing_ratio with
    | Some percent -> percent /. 100.
    | None -> Btlib.Data.financing_ratio ~data_dir:!data_dir ~symbol
  in
  let configured_loan_term =
    if !loan_term_months = 0 then None else Some !loan_term_months
  in
  let runs =
    List.map
      (fun input ->
        let params =
          List.filter
            (fun (name, _) -> List.mem_assoc name input.declarations)
            !parameters
        in
        let assets_for_compile =
          List.map2
            (fun (alias, _, _) bars -> alias, bars)
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
          Array.of_list
            (List.map2 (fun label bars -> label, bars) labels input.bars)
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
        let ratios =
          Array.of_list
            (List.map (fun (_, _, symbol) -> ratio_for symbol) input.stocks)
        in
        let margin_config : Btlib.Engine.margin =
          { financing_rate = !financing_rate /. 100.;
            maintenance_ratio = !maintenance_ratio /. 100.;
            ratios;
            loan_term_months =
              if List.exists
                   (fun (_, market, _) -> market = "tw")
                   input.stocks
              then configured_loan_term
              else None }
        in
        let result =
          Btlib.Engine.run engine_assets strategy costs
            ~margin:margin_config ~capital:!capital ~fill:!fill
        in
        (input.name, String.concat "+" labels, result))
      inputs
  in
  let baseline_result =
    match baseline_bars with
    | None -> None
    | Some (market, symbol, bars) ->
        let defaults = Btlib.Engine.default_costs ~market ~symbol in
        let costs =
          apply_cost_overrides defaults !fee_bps !tax_bps !slip_bps !min_fee
        in
        let margin_config : Btlib.Engine.margin =
          { financing_rate = !financing_rate /. 100.;
            maintenance_ratio = !maintenance_ratio /. 100.;
            ratios = [| ratio_for symbol |];
            loan_term_months =
              if market = "tw" then configured_loan_term else None }
        in
        Some
          (Btlib.Engine.run [| (market ^ "/" ^ symbol, bars) |]
             (baseline_strategy (Array.length bars)) [| costs |]
             ~margin:margin_config
             ~capital:!capital ~fill:!fill)
  in
  let columns =
    List.map (fun (name, _, result) -> name, result) runs
  in
  let stocks =
    List.map (fun (name, stock, _) -> name, stock) runs
  in
  let output_stem = Btlib.Report.stem ~names ~out_name:!out_name in
  Btlib.Report.print_many
    ~columns ~baseline:baseline_result ~fill:!fill ~stocks
    ~financing_rate:!financing_rate;
  Btlib.Report.write_outputs
    ~out_dir:!out_dir ~stem:output_stem
    ~columns ~baseline:baseline_result;
  if not !no_plot then
    Btlib.Report.write_png ~out_dir:!out_dir ~stem:output_stem

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
