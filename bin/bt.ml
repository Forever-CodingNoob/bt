let usage =
  "usage:\n\
   \  bt fetch [MARKET/SYMBOL] [--market tw|us] [--symbol SYM] [--from YYYY-MM-DD] [--to YYYY-MM-DD] [--data-dir DIR]\n\
   \           positional MARKET/SYMBOL is equivalent to --market and --symbol\n\
   \  bt fetch us/SYM --bars 1m [--data-dir DIR]\n\
   \  bt run STRAT... [--baseline M/SYM] [--from D] [--to D]\n\
   \         [-p name=value ...] [--fill open|close]\n\
   \         [--fee-bps F] [--tax-bps F] [--slip-bps F] [--min-fee F]\n\
   \         [--per-share-fee F] [--per-share-cap F]\n\
   \         [--dividend-tax PCT] [--financing-rate PCT] [--maintenance-ratio PCT] [--financing-ratio PCT]\n\
   \         [--loan-term-months N]\n\
   \         --capital TWD [--data-dir DIR] [--out-dir DIR] [--out-name NAME] [--no-plot]\n\
   \  bt daytrade STRAT... [--baseline us/SYM] [--fill open|close] [--leverage N]\n\
   \              [--from D] [--to D] [-p name=value] --capital USD\n\
   \              [--fee-bps F] [--tax-bps F] [--slip-bps F] [--per-share-fee F] [--per-share-cap F]\n\
   \              [--data-dir DIR] [--out-dir DIR] [--out-name NAME] [--no-plot]\n\
   \  bt target STRAT [--live] [--equity TWD] [--data-dir DIR] [--provisional-close PRICE]\n\
   \  bt live STRAT [--live] [--equity TWD] [--data-dir DIR]"

let help =
  usage ^
  "\n\ncommands:\n\
   \  fetch     Download market data from FinMind into the local cache.\n\
   \  run       Run strategies with cached data and compare them with a baseline.\n\
   \  daytrade  Run US strategies on cached regular-session minute bars.\n\
   \  target    Print one live decision without submitting an order.\n\
   \  live      Run the close-scheduled Alpaca trading daemon.\n\n\
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
  (match !market with
   | "tw" | "us" -> ()
   | _ -> usage_error "fetch: --market must be tw or us");
  if !symbol = "" then usage_error "fetch: --symbol is required";
  Data.fetch ~market:!market ~symbol:!symbol ~from_:!from_ ~to_:!to_
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

let apply_cost_overrides defaults fee_bps tax_bps slip_bps min_fee
    per_share_fee per_share_cap : Engine.costs =
  { fee_bps =
      (match fee_bps with Some value -> value | None -> defaults.Engine.fee_bps);
    tax_bps =
      (match tax_bps with Some value -> value | None -> defaults.Engine.tax_bps);
    slip_bps =
      (match slip_bps with Some value -> value | None -> defaults.Engine.slip_bps);
    min_fee =
      (match min_fee with Some value -> value | None -> defaults.Engine.min_fee);
    per_share_sell_fee =
      (match per_share_fee with
       | Some value -> value
       | None -> defaults.Engine.per_share_sell_fee);
    per_share_sell_cap =
      (match per_share_cap with
       | Some value -> value
       | None -> defaults.Engine.per_share_sell_cap) }

let load_asset ~market ~symbol ~from_ ~to_ ~data_dir =
  let cache_path =
    Filename.concat
      (Filename.concat (Filename.concat data_dir market) symbol)
      (symbol ^ ".csv")
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
  Data.load_asset ~market ~symbol ~from_ ~to_ ~data_dir

type strategy_input = {
  name : string;
  stocks : (string option * string * string) list;
  ast : Ast.file;
  declarations : (string * float) list;
  assets : Data.loaded_asset list;
}

let strategy_name path =
  Filename.remove_extension (Filename.basename path)

let common_dates = function
  | [] -> []
  | first :: rest ->
      let initial =
        Array.to_list
          (Array.map
             (fun (bar : Data.bar) -> bar.date)
             first)
        |> List.sort_uniq String.compare
      in
      List.fold_left
        (fun common bars ->
          let present = Hashtbl.create (Array.length bars) in
          Array.iter
            (fun (bar : Data.bar) ->
              Hashtbl.replace present bar.date ())
            bars;
          List.filter (fun date -> Hashtbl.mem present date) common)
        initial rest

let baseline_strategy length : Engine.strategy =
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
  let per_share_fee = ref None in
  let per_share_cap = ref None in
  let dividend_tax = ref 0. in
  let financing_rate = ref None in
  let maintenance_ratio = ref None in
  let financing_ratio = ref None in
  let loan_term_months = ref 18 in
  let data_dir = ref "data" in
  let out_dir = ref "out" in
  let out_name = ref None in
  let no_plot = ref false in
  let fill = ref Engine.Close_same in
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
           | "open" -> fill := Engine.Open_next
           | "close" -> fill := Engine.Close_same
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
      ("--per-share-fee",
       Arg.Float (fun value -> per_share_fee := Some value),
       "FINRA TAF per-share sell fee in dollars");
      ("--per-share-cap",
       Arg.Float (fun value -> per_share_cap := Some value),
       "FINRA TAF per-order cap in dollars");
      ("--dividend-tax",
       Arg.Set_float dividend_tax,
       "dividend tax percent (default 0)");
      ("--financing-rate",
       Arg.Float (fun value -> financing_rate := Some value),
       "annual financing rate percent (default: market profile)");
      ("--maintenance-ratio",
       Arg.Float (fun value -> maintenance_ratio := Some value),
       "maintenance ratio percent (default: market profile)");
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
  let capital =
    match !capital with
    | Some value when Float.is_finite value && value > 0. -> value
    | Some _ -> usage_error "run: --capital must be a positive finite number"
    | None -> usage_error "run: --capital is required"
  in
  if !loan_term_months < 0 then
    usage_error "run: --loan-term-months must be 0 or greater";
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
  let parsed =
    List.map2
      (fun path name ->
        let ast = Dsl.parse_file path in
        let () =
          if List.exists (function Ast.Bars _ -> true | _ -> false) ast then
            failwith "day trading strategies run under bt daytrade"
        in
        let stocks = Dsl.stocks_of ~filename:path ast in
        (name, ast, stocks, Dsl.declared_params_ast ast))
      strategy_files names
  in
  let all_markets =
    List.concat_map
      (fun (_, _, stocks, _) ->
        List.map (fun (_, market, _) -> market) stocks)
      parsed
  in
  let all_markets =
    match !baseline with
    | None -> all_markets
    | Some (market, _) -> market :: all_markets
  in
  let market =
    match all_markets with
    | [] -> usage_error "run: no stocks declared"
    | first :: rest ->
        if List.for_all (( = ) first) rest then first
        else usage_error "run: all stocks must share one market"
  in
  let profile = Engine.profile_of_market market in
  let financing_rate =
    match !financing_rate with
    | Some v -> v
    | None -> profile.Engine.default_financing_rate
  in
  let maintenance_override =
    match !maintenance_ratio with
    | Some v -> Some (v /. 100.)
    | None -> None
  in
  let loaded_cache = Hashtbl.create 8 in
  let load_cached ~market ~symbol =
    let key = (market, symbol) in
    match Hashtbl.find_opt loaded_cache key with
    | Some asset -> asset
    | None ->
        let asset =
          load_asset ~market ~symbol
            ~from_:!from_ ~to_:!to_ ~data_dir:!data_dir
        in
        let () = Hashtbl.replace loaded_cache key asset in
        asset
  in
  let inputs =
    List.map
      (fun (name, ast, stocks, declarations) ->
        let assets =
          List.map
            (fun (_, market, symbol) -> load_cached ~market ~symbol)
            stocks
        in
        { name; stocks; ast; declarations; assets })
      parsed
  in
  let baseline_asset =
    match !baseline with
    | None -> None
    | Some (market, symbol) ->
        Some
          (market, symbol,
           load_cached ~market ~symbol)
  in
  let arrays =
    List.concat_map
      (fun input ->
        List.map
          (fun asset -> asset.Data.signal)
          input.assets)
      inputs
  in
  let arrays =
    match baseline_asset with
    | None -> arrays
    | Some (_, _, asset) -> arrays @ [asset.Data.signal]
  in
  let dates = common_dates arrays in
  if List.length dates < 2 then
    failwith "strats have fewer than 2 common trading dates";
  let keep = Hashtbl.create (List.length dates) in
  List.iter (fun date -> Hashtbl.replace keep date ()) dates;
  let filter bars =
    Data.filter_dates ~keep:(fun date -> Hashtbl.mem keep date) bars
  in
  let filter_asset (asset : Data.loaded_asset) =
    { asset with
      money = filter asset.money;
      signal = filter asset.signal }
  in
  let inputs =
    List.map
      (fun input ->
        { input with assets = List.map filter_asset input.assets })
      inputs
  in
  let baseline_asset =
    match baseline_asset with
    | None -> None
    | Some (market, symbol, asset) ->
        Some (market, symbol, filter_asset asset)
  in
  List.iter
    (fun (name, _) ->
      if not
          (List.exists
             (fun input -> List.mem_assoc name input.declarations)
             inputs)
      then failwith (Printf.sprintf "unknown parameter %s" name))
    !parameters;
  let ratio_for market symbol =
    match !financing_ratio with
    | Some percent -> percent /. 100.
    | None -> Data.financing_ratio ~market ~data_dir:!data_dir ~symbol
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
            (fun (alias, _, _) asset ->
              alias, asset.Data.signal)
            input.stocks input.assets
        in
        let strategy =
          Dsl.compile_ast input.ast ~params ~assets:assets_for_compile
        in
        let labels = Dsl.labels_of_stocks input.stocks in
        let engine_assets =
          Array.of_list
            (List.map2
               (fun label asset -> label, asset.Data.money)
               labels input.assets)
        in
        let dividends =
          Array.of_list
            (List.map
               (fun asset -> asset.Data.dividends)
               input.assets)
        in
        let costs =
          Array.of_list
            (List.map
               (fun (_, market, symbol) ->
                 apply_cost_overrides
                   (Engine.default_costs ~market ~symbol)
                   !fee_bps !tax_bps !slip_bps !min_fee
                   !per_share_fee !per_share_cap)
               input.stocks)
        in
        let ratios =
          Array.of_list
            (List.map (fun (_, market, symbol) -> ratio_for market symbol) input.stocks)
        in
        let margin_config : Engine.margin =
          { financing_rate = financing_rate /. 100.;
            maintenance_override;
            ratios;
            loan_term_months =
              if List.exists
                   (fun (_, market, _) ->
                     match market with "tw" -> true | _ -> false)
                   input.stocks
              then configured_loan_term
              else None }
        in
        let result =
          Engine.run ~dividends
            ~dividend_tax:(!dividend_tax /. 100.)
            engine_assets strategy costs
            ~profile ~margin:margin_config ~capital ~fill:!fill
        in
        (input.name, String.concat "+" labels, result))
      inputs
  in
  let baseline_result =
    match baseline_asset with
    | None -> None
    | Some (market, symbol, asset) ->
        let bars = asset.Data.money in
        let defaults = Engine.default_costs ~market ~symbol in
        let costs =
          apply_cost_overrides defaults !fee_bps !tax_bps !slip_bps !min_fee
            !per_share_fee !per_share_cap
        in
        let margin_config : Engine.margin =
          { financing_rate = financing_rate /. 100.;
            maintenance_override;
            ratios = [| ratio_for market symbol |];
            loan_term_months =
              (match market with
               | "tw" -> configured_loan_term
               | _ -> None) }
        in
        Some
          (Engine.run ~dividends:[| asset.Data.dividends |]
             ~dividend_tax:(!dividend_tax /. 100.)
             [| (market ^ "/" ^ symbol, bars) |]
             (baseline_strategy (Array.length bars)) [| costs |]
             ~profile ~margin:margin_config
             ~capital ~fill:!fill)
  in
  let columns =
    List.map (fun (name, _, result) -> name, result) runs
  in
  let stocks =
    List.map (fun (name, stock, _) -> name, stock) runs
  in
  let output_stem = Report.stem ~names ~out_name:!out_name in
  Report.print_many
    ~columns ~baseline:baseline_result ~fill:!fill ~stocks
    ~financing_rate;
  Report.write_outputs
    ~out_dir:!out_dir ~stem:output_stem
    ~columns ~baseline:baseline_result;
  if not !no_plot then
    Report.write_png ~out_dir:!out_dir ~stem:output_stem

let daytrade argv =
  let strategy_files = ref [] in
  let from_ = ref None in
  let to_ = ref None in
  let baseline = ref None in
  let parameters = ref [] in
  let capital = ref None in
  let leverage = ref 1. in
  let fee_bps = ref None in
  let tax_bps = ref None in
  let slip_bps = ref None in
  let per_share_fee = ref None in
  let per_share_cap = ref None in
  let data_dir = ref "data" in
  let out_dir = ref "out" in
  let out_name = ref None in
  let no_plot = ref false in
  let fill = ref Engine.Open_next in
  let rec options =
    [ "--from", Arg.String (fun value -> from_ := Some value), "start date";
      "--to", Arg.String (fun value -> to_ := Some value), "end date";
      "--baseline", Arg.String (fun value ->
        baseline := Some (parse_market_symbol "baseline" value)), "baseline us/SYM";
      "--fill", Arg.String (function
        | "open" -> fill := Engine.Open_next
        | "close" -> fill := Engine.Close_same
        | _ -> raise (Arg.Bad "--fill must be open or close")), "fill mode (default open)";
      "--leverage", Arg.Set_float leverage, "previous-close buying-power multiplier (default 1)";
      "--capital", Arg.Float (fun value -> capital := Some value), "starting value in USD";
      "-p", Arg.String (parse_parameter parameters), "parameter override name=value";
      "--fee-bps", Arg.Float (fun value -> fee_bps := Some value), "fee basis points";
      "--tax-bps", Arg.Float (fun value -> tax_bps := Some value), "tax basis points";
      "--slip-bps", Arg.Float (fun value -> slip_bps := Some value), "slippage basis points";
      "--per-share-fee", Arg.Float (fun value -> per_share_fee := Some value), "TAF per-share sell fee";
      "--per-share-cap", Arg.Float (fun value -> per_share_cap := Some value), "TAF per-order cap";
      "--data-dir", Arg.Set_string data_dir, "cache directory";
      "--out-dir", Arg.Set_string out_dir, "output directory";
      "--out-name", Arg.String (fun value -> out_name := Some value), "equity output stem";
      "--no-plot", Arg.Set no_plot, "skip equity graph";
      "-h", Arg.Unit (fun () -> raise (Arg.Help (Arg.usage_string options usage))), "show help" ] in
  let () =
    try Arg.parse_argv argv options (fun value -> strategy_files := value :: !strategy_files) usage with
    | Arg.Bad message -> let () = prerr_string message in exit 2
    | Arg.Help message -> let () = print_string message in exit 0 in
  let files = List.rev !strategy_files in
  let () = if files = [] then usage_error "daytrade: at least one STRAT file is required" in
  let capital =
    match !capital with
    | Some value when Float.is_finite value && value > 0. -> value
    | Some _ -> usage_error "daytrade: --capital must be a positive finite number"
    | None -> usage_error "daytrade: --capital is required"
  in
  let () = if not (Float.is_finite !leverage) || !leverage <= 0. then
    usage_error "daytrade: --leverage must be a positive finite number" in
  let names = List.map strategy_name files in
  let seen = Hashtbl.create (List.length names) in
  let () = List.iter (fun name ->
    let () = if Hashtbl.mem seen name then
      usage_error (Printf.sprintf "daytrade: duplicate strat basename %S" name) in
    Hashtbl.replace seen name ()) names in
  let () = if !baseline <> None && List.mem "baseline" names then
    usage_error "daytrade: strat basename \"baseline\" conflicts with --baseline" in
  let parsed = List.map2 (fun path name ->
    let ast = Dsl.parse_file path in
    let minutes = match Dsl.timeframe ast with
      | None -> failwith "bt daytrade requires a bars declaration"
      | Some minutes -> minutes in
    let symbol = match Dsl.stocks_of ~filename:path ast with
      | [None, market, symbol] ->
          (match market with
           | "us" -> symbol
           | _ -> failwith "day trading supports us only")
      | _ -> failwith "day trading strategies declare exactly one stock" in
    name, ast, minutes, symbol, Dsl.declared_params_ast ast) files names in
  let () = List.iter (fun (name, _) ->
    if not (List.exists (fun (_, _, _, _, declarations) -> List.mem_assoc name declarations) parsed)
    then failwith ("unknown parameter " ^ name)) !parameters in
  let () = match !baseline with
    | None | Some ("us", _) -> ()
    | Some _ -> failwith "day trading supports us only" in
  let sessions = Data.read_calendar ~data_dir:!data_dir in
  let () = if Array.length sessions = 0 then
    failwith "no cached sessions; run bt fetch us/SYM --bars 1m" in
  let calendar = Hashtbl.create (Array.length sessions) in
  let () = Array.iter (fun (session : Data.session) ->
    Hashtbl.replace calendar session.date session) sessions in
  let session_date time = String.sub time 0 10 in
  let inputs = List.map (fun (name, ast, minutes, symbol, declarations) ->
    let bars = Data.read_minute_bars ~data_dir:!data_dir ~symbol ~from_:!from_ ~to_:!to_ in
    let bars = Data.filter_dates ~keep:(fun time ->
      match Hashtbl.find_opt calendar (session_date time) with
      | None -> false
      | Some session ->
          let clock = String.sub time 11 5 in
          clock >= session.Data.open_ && clock < session.close) bars in
    let bars = Data.resample ~minutes ~sessions bars in
    name, ast, symbol, declarations, bars) parsed in
  let baseline_asset = Option.map (fun (_, symbol) ->
    symbol, load_asset ~market:"us" ~symbol ~from_:!from_ ~to_:!to_ ~data_dir:!data_dir) !baseline in
  let arrays = List.map (fun (_, _, _, _, bars) ->
    Array.map (fun (bar : Data.bar) -> { bar with date = session_date bar.date }) bars) inputs in
  let arrays = match baseline_asset with
    | None -> arrays
    | Some (_, asset) -> arrays @ [asset.Data.money] in
  let dates = common_dates arrays in
  let () = if List.length dates < 2 then
    failwith "strats have fewer than 2 common trading dates" in
  let keep = Hashtbl.create (List.length dates) in
  let () = List.iter (fun date -> Hashtbl.replace keep date ()) dates in
  let keep_date date = Hashtbl.mem keep date in
  let sessions = Array.of_list (List.filter (fun (session : Data.session) ->
    keep_date session.date) (Array.to_list sessions)) in
  let costs symbol = apply_cost_overrides (Engine.default_costs ~market:"us" ~symbol)
    !fee_bps !tax_bps !slip_bps None !per_share_fee !per_share_cap in
  let clock_minutes time =
    int_of_string (String.sub time 0 2) * 60 + int_of_string (String.sub time 3 2) in
  let columns = List.map (fun (name, ast, symbol, declarations, bars) ->
    let bars = Data.filter_dates ~keep:(fun time -> keep_date (session_date time)) bars in
    let since_open = Array.make (Array.length bars) 0. in
    let to_close = Array.make (Array.length bars) 0. in
    let () = Array.iteri (fun index (bar : Data.bar) ->
      let session = Hashtbl.find calendar (session_date bar.date) in
      let time = clock_minutes (String.sub bar.date 11 5) in
      let () = since_open.(index) <- float_of_int (time - clock_minutes session.Data.open_) in
      to_close.(index) <- float_of_int (clock_minutes session.close - time)) bars in
    let params = List.filter (fun (name, _) -> List.mem_assoc name declarations) !parameters in
    let strategy = Dsl.compile_ast ~extra:["since_open", since_open; "to_close", to_close]
      ast ~params ~assets:[None, bars] in
    let config : Intraday.config =
      { fill = !fill; leverage = !leverage; costs = costs symbol;
        capital } in
    name, "us/" ^ symbol,
    Intraday.run config ~sessions ~bars ~targets:strategy.Engine.targets.(0) ~initial_equity:1.) inputs in
  let baseline_result = Option.map (fun (symbol, asset) ->
    let bars = Data.filter_dates ~keep:keep_date asset.Data.money in
    let profile = Engine.profile_of_market "us" in
    let margin : Engine.margin =
      { financing_rate = profile.default_financing_rate /. 100.;
        maintenance_override = None; ratios = [|profile.default_financing_ratio|];
        loan_term_months = None } in
    Engine.run ~dividends:[|asset.Data.dividends|]
      [|"us/" ^ symbol, bars|] (baseline_strategy (Array.length bars)) [|costs symbol|]
      ~profile ~margin ~capital ~fill:!fill) baseline_asset in
  let stem = Report.stem ~names ~out_name:!out_name in
  let () = Report.print_intraday ~columns ~baseline:baseline_result ~fill:!fill in
  let () = Report.write_intraday_outputs ~out_dir:!out_dir ~stem ~columns ~baseline:baseline_result in
  if not !no_plot then Report.write_png ~out_dir:!out_dir ~stem

let print_decision provisional_close (decision : Live.decision) =
  let () =
    match provisional_close with
    | None -> ()
    | Some price -> Printf.printf "provisional: override %.10g\n" price
  in
  let bar = decision.provisional in
  Printf.printf "fetched-through: %s\n" decision.fetched_through;
  Printf.printf "provisional-date: %s\n" bar.date;
  Printf.printf "provisional-open: %.10g\n" bar.o;
  Printf.printf "provisional-high: %.10g\n" bar.h;
  Printf.printf "provisional-low: %.10g\n" bar.l;
  Printf.printf "provisional-close: %.10g\n" bar.c;
  Printf.printf "provisional-volume: %.10g\n" bar.v;
  Printf.printf "target: %.10g\n" decision.target;
  Printf.printf "equity: %.10g\n" decision.equity;
  Printf.printf "held: %.10g\n" decision.held;
  match decision.action with
  | Live.Order { side; qty; id } ->
      let side =
        match side with
        | `Buy -> "buy"
        | `Sell -> "sell"
      in
      Printf.printf "action: order\n";
      Printf.printf "side: %s\n" side;
      Printf.printf "quantity: %d\n" qty;
      Printf.printf "client-order-id: %s\n" id
  | Live.Skip reason ->
      Printf.printf "action: skip\n";
      Printf.printf "reason: %s\n" reason
  | Live.Orders legs ->
      let () = Printf.printf "action: orders\n" in
      List.iter
        (fun (leg : Live.leg) ->
          Printf.printf "leg: %s %s %d\n" leg.action leg.cond leg.lots)
        legs

let live_command_args command extra_options argv =
  let strat_path = ref None in
  let use_live = ref false in
  let data_dir = ref "data" in
  let equity = ref None in
  let rec options () =
    [ ("--live", Arg.Set use_live, "use the selected broker in production");
      ("--equity",
       Arg.Float
         (fun value ->
           if Float.is_finite value && value > 0. then
             equity := Some value
           else
             raise (Arg.Bad "--equity must be a positive float")),
       "simulation account equity in TWD");
      ("--data-dir", Arg.Set_string data_dir, "cache directory");
      ("-h",
       Arg.Unit
         (fun () -> raise (Arg.Help (Arg.usage_string (options ()) usage))),
       "show this help") ] @ extra_options
  in
  let options = options () in
  let anonymous value =
    match !strat_path with
    | None -> strat_path := Some value
    | Some _ ->
        raise
          (Arg.Bad
             (Printf.sprintf
                "unexpected argument %S; expected one STRAT file" value))
  in
  (try Arg.parse_argv argv options anonymous usage with
   | Arg.Bad message ->
       prerr_string message;
       exit 2
   | Arg.Help message ->
       print_string message;
       exit 0);
  let strat_path =
    match !strat_path with
    | Some path -> path
    | None ->
        usage_error (Printf.sprintf "%s: one STRAT file is required" command)
  in
  let ast = Dsl.parse_file strat_path in
  let () =
    if List.exists (function Ast.Bars _ -> true | _ -> false) ast then
      failwith "day trading strategies run under bt daytrade"
  in
  let market =
    match Dsl.stocks_of ~filename:strat_path ast with
    | [_, market, _] -> market
    | _ ->
        usage_error
          (Printf.sprintf
             "%s: strategy must declare exactly one stock" command)
  in
  let mode = if !use_live then Live.Live else Live.Paper in
  match market with
  | "us" ->
      (match !equity with
       | None -> strat_path, market, mode, None, !data_dir
       | Some _ -> usage_error "--equity is only available for tw")
  | "tw" ->
      (match mode, !equity with
       | Live.Paper, None -> usage_error "simulation mode requires --equity"
       | Live.Live, Some _ ->
           usage_error "--equity is not allowed in production"
       | Live.Paper, Some _ | Live.Live, None ->
           strat_path, market, mode, !equity, !data_dir)
  | _ -> usage_error "live trading supports us and tw only"

let taipei_date () =
  let local = Unix.gmtime (Unix.gettimeofday () +. (8. *. 60. *. 60.)) in
  Printf.sprintf "%04d-%02d-%02d"
    (local.tm_year + 1900) (local.tm_mon + 1) local.tm_mday

let target argv =
  let provisional_close = ref None in
  let extra_options =
    [ ("--provisional-close",
       Arg.Float
         (fun price ->
           if Float.is_finite price && price > 0. then
             provisional_close := Some price
           else
             raise
               (Arg.Bad
                  "--provisional-close must be a positive float")),
       "override the provisional close with a positive price") ]
  in
  let strat_path, market, mode, equity, data_dir =
    live_command_args "target" extra_options argv
  in
  let decision =
    match market with
    | "us" ->
        let clock = Alpaca.clock mode in
        Live.decide ?provisional_close:!provisional_close mode
          ~session_date:(Live.timestamp_date clock.timestamp)
          ~strat_path ~data_dir
    | "tw" ->
        let info = Shioaji.info () in
        let () =
          match Live.tw_startup_ok mode ~equity info with
          | Ok () -> ()
          | Error reason -> failwith reason
        in
        Live.decide ?provisional_close:!provisional_close ?equity mode
          ~session_date:(taipei_date ()) ~strat_path ~data_dir
    | _ -> assert false
  in
  print_decision !provisional_close decision

let live argv =
  let strat_path, _, mode, equity, data_dir =
    live_command_args "live" [] argv
  in
  Live.run ?equity mode ~strat_path ~data_dir

let fetch_minute argv =
  let symbol = ref None in
  let resolution = ref "" in
  let data_dir = ref "data" in
  let options =
    ["--bars", Arg.Set_string resolution, "stored resolution (1m)";
     "--data-dir", Arg.Set_string data_dir, "cache directory"]
  in
  let anonymous value =
    match !symbol with
    | Some _ -> raise (Arg.Bad "fetch --bars expects one MARKET/SYMBOL")
    | None ->
        let market, value = parse_market_symbol "fetch argument" value in
        match market with
        | "us" -> symbol := Some value
        | _ -> raise (Arg.Bad "minute bars support us only")
  in
  let () =
    try Arg.parse_argv argv options anonymous "bt fetch us/SYM --bars 1m [--data-dir DIR]" with
    | Arg.Bad message -> let () = prerr_string message in exit 2
    | Arg.Help message -> let () = print_string message in exit 0
  in
  let () = if !resolution <> "1m" then usage_error "fetch --bars supports 1m only" in
  let symbol = match !symbol with
    | Some value -> value
    | None -> usage_error "fetch --bars expects one MARKET/SYMBOL"
  in
  let last_cached () =
    let directory = Filename.concat !data_dir ("us/" ^ symbol ^ "/1m") in
    let files = if Sys.file_exists directory then Sys.readdir directory else [||] in
    let newest = Array.fold_left (fun newest name ->
      if String.length name = 8 && Filename.check_suffix name ".csv" &&
         String.for_all (function '0' .. '9' -> true | _ -> false) (String.sub name 0 4)
      then max newest name else newest) "" files in
    match newest with
    | "" -> None
    | name ->
        match Data.last_cached_date (Filename.concat directory name) with
        | None | Some "time" -> None
        | Some time -> Some time
  in
  let start =
    match last_cached () with
    | None -> "2016-01-01"
    | Some time ->
        let offset = Data.et_offset_minutes (String.sub time 0 10) in
        Printf.sprintf "%s:00-%02d:00" time (-offset / 60)
  in
  let now = Unix.time () in
  let format tm = Printf.sprintf "%04d-%02d-%02d"
    (tm.Unix.tm_year + 1900) (tm.Unix.tm_mon + 1) tm.Unix.tm_mday in
  let tm = Unix.gmtime (now -. 960.) in
  let end_ = Printf.sprintf "%sT%02d:%02d:%02dZ" (format tm)
    tm.Unix.tm_hour tm.Unix.tm_min tm.Unix.tm_sec in
  try
    let calendar = Alpaca.calendar Alpaca.Paper ~start:"2016-01-01"
      ~end_:(format (Unix.gmtime now)) in
    let () = Data.write_calendar ~data_dir:!data_dir calendar in
    let sessions = Data.read_calendar ~data_dir:!data_dir in
    List.iter (fun (start, end_) ->
      let bars = Alpaca.bars ~sessions ~symbol ~start ~end_ in
      Data.write_minute_bars ~data_dir:!data_dir ~symbol bars)
      (Data.year_ranges ~start ~end_)
  with Failure message | Sys_error message ->
    match last_cached () with
    | None -> failwith message
    | Some _ -> Printf.eprintf "warning: %s; keeping cached minute bars for %s\n" message symbol

let dispatch () =
  if Array.length Sys.argv < 2 then begin
    prerr_endline help;
    exit 2
  end;
  match Sys.argv.(1) with
  | "--help" | "-h" | "help" -> print_endline help
  | "fetch" when Array.exists (( = ) "--bars") Sys.argv ->
      fetch_minute (Array.sub Sys.argv 1 (Array.length Sys.argv - 1))
  | "fetch" -> fetch (Array.sub Sys.argv 1 (Array.length Sys.argv - 1))
  | "run" -> run (Array.sub Sys.argv 1 (Array.length Sys.argv - 1))
  | "daytrade" -> daytrade (Array.sub Sys.argv 1 (Array.length Sys.argv - 1))
  | "target" -> target (Array.sub Sys.argv 1 (Array.length Sys.argv - 1))
  | "live" -> live (Array.sub Sys.argv 1 (Array.length Sys.argv - 1))
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
