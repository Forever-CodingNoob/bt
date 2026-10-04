type mode = Alpaca.mode = Paper | Live

type leg = {
  code : string;
  exchange : string;
  action : string;
  cond : string;
  lot : Shioaji.lot;
  quantity : int;
}


type action =
  | Order of {
      side : [`Buy | `Sell];
      qty : float;
      id : string;
    }
  | Skip of string
  | Orders of leg list


type asset_decision = {
  symbol : string;
  provisional : Data.bar;
  target : float;
  held : float;
  action : action;
}

type decision = {
  fetched_through : string;
  equity : float;
  cash : float;
  debit : float;
  assets : asset_decision array;
  legs : leg list;
}

type tw_execution = {
  trades : Shioaji.trade list;
  remaining : leg list;
  stop_reason : string option;
}

let provisional_bar (snapshot : Alpaca.snapshot_t) : Data.bar =
  { date = snapshot.day_date;
    o = snapshot.day_open;
    h = snapshot.day_high;
    l = snapshot.day_low;
    c = snapshot.latest;
    v = snapshot.day_volume }

let override_snapshot ~session_date ~prev_day_date ~price : Alpaca.snapshot_t =
  { day_date = session_date;
    prev_day_date;
    day_open = price;
    day_high = price;
    day_low = price;
    latest = price;
    day_volume = 0. }

let cache_is_fresh ~last_cached ~prev_trading_day =
  last_cached = prev_trading_day

let snapshot_session ~session_date ~provisional_date =
  if provisional_date = session_date then
    `Proceed
  else
    `Skip
      (Printf.sprintf
         "stale snapshot session: provisional %s does not match clock session \
          %s"
         provisional_date session_date)


let client_order_id ~symbol ~date =
  Printf.sprintf "bt-%s-%s" symbol date

let us_plan_state ~cash ~held ~prices ~ratio ~previous_targets =
  let count = Array.length held in
  let () = if Array.length prices <> count || Array.length previous_targets <> count then
    invalid_arg "US plan arrays differ in length" in
  let () = if not (Float.is_finite ratio) || ratio <= 0. then
    failwith "US financing ratio is not positive" in
  let values = Array.mapi (fun i shares -> shares *. prices.(i)) held in
  let total = Array.fold_left ( +. ) 0. values in
  let debit = Float.max 0. (-. cash) in
  let loans = Array.map (fun value ->
    if total = 0. then debit /. float_of_int count
    else debit *. (value /. total)) values in
  let margin_values = Array.mapi (fun i value ->
    Float.min value (loans.(i) /. ratio)) values in
  let cash = Float.max cash 0. in
  { Engine.equity = cash +. total -. debit; cash;
    cash_values = Array.mapi (fun i value -> value -. margin_values.(i)) values;
    margin_values; loans; interests = Array.make count 0.;
    tail_interests = Array.make count 0.; debt = 0.; receivables = 0.;
    previous_targets }

let us_plan_action ~rebalance ~symbols ~date ~(account : Alpaca.account_t)
    ~position_symbols ~held ~prices ~targets ~previous_targets =
  let count = Array.length symbols in
  let () = if Array.length held <> count || Array.length prices <> count
    || Array.length targets <> count || Array.length previous_targets <> count then
    invalid_arg "US plan arrays differ in length" in
  let profile = Engine.profile_of_market "us" in
  let ratio = profile.default_financing_ratio in
  let state = us_plan_state ~cash:account.cash ~held ~prices ~ratio ~previous_targets in
  let rec held_value index value =
    if index = Array.length held then value
    else held_value (index + 1) (value +. held.(index) *. prices.(index)) in
  let value = held_value 0 0. in
  let () = if not (Float.is_finite account.cash) then
    failwith "US account cash is not finite" in
  let () = if account.short_market_value <> 0. || Array.exists (fun h -> h < 0.) held then
    failwith "US account holds a short position" in
  let () = List.iter (fun symbol ->
    if not (Array.exists (( = ) symbol) symbols) then
      failwith ("US account holds unsupported symbol " ^ symbol)) position_symbols in
  let () =
    (* ponytail: 1% tolerance for broker marks versus provisional prices;
       retain alongside the positions-list check for valuation consistency. *)
    if not (Float.is_finite account.long_market_value)
      || abs_float (account.long_market_value -. value) > 0.01 *. account.long_market_value
    then failwith "US account holds other symbols" in
  let () = if not (Float.is_finite state.equity) || state.equity <= 0. then
    failwith "US account equity is not positive" in
  if not rebalance && targets = previous_targets then
    state, Array.make (Array.length symbols) (Skip "target unchanged")
  else
    let plan = Engine.plan_fills
      ~costs:(Array.map (fun symbol -> Engine.default_costs ~market:"us" ~symbol) symbols)
      ~capital:1. ~profile ~financing_ratios:(Array.make (Array.length symbols) ratio)
      ~state ~prices ~targets ~force:rebalance in
    let actions = Array.mapi (fun i (item : Engine.planned_asset) ->
      if not rebalance && targets.(i) = previous_targets.(i) then Skip "target unchanged"
      else
        let net = item.plan_buy_cash +. item.plan_buy_margin
          -. item.plan_sell_cash -. item.plan_sell_margin in
        if net = 0. then Skip "no trade planned"
        else
          let price = prices.(i) in
          let side, shares =
            if net > 0. then `Buy, net /. price
            else `Sell, (if item.plan_final_value = 0. then held.(i)
              else Float.min (-. net /. price) held.(i)) in
          let qty = float_of_string (Alpaca.qty_string shares) in
          if qty = 0. || (side = `Buy && qty *. price < 1.) then
            Skip "below $1 minimum order value"
          else Order { side; qty; id = client_order_id ~symbol:symbols.(i) ~date })
      plan.planned_assets in
    state, actions

let int_field value offset length =
  int_of_string (String.sub value offset length)

let timezone_start value =
  let rec find offset =
    if offset >= String.length value then
      failwith (Printf.sprintf "invalid RFC3339 timestamp: %s" value)
    else
      match value.[offset] with
      | 'Z' | '+' | '-' -> offset
      | _ -> find (offset + 1)
  in
  find 19

let timezone_offset value start =
  match value.[start] with
  | 'Z' -> 0
  | ('+' | '-') as sign ->
      let seconds =
        (int_field value (start + 1) 2 * 60
         + int_field value (start + 4) 2)
        * 60
      in
      if sign = '+' then seconds else -seconds
  | _ -> assert false

let days_from_civil year month day =
  let year = if month <= 2 then year - 1 else year in
  let era = year / 400 in
  let year_of_era = year - (era * 400) in
  let month_prime = month + (if month > 2 then -3 else 9) in
  let day_of_year = ((153 * month_prime + 2) / 5) + day - 1 in
  let day_of_era =
    (year_of_era * 365) + (year_of_era / 4) - (year_of_era / 100)
    + day_of_year
  in
  (era * 146097) + day_of_era - 719468

let rfc3339_seconds value =
  if String.length value < 20 then
    failwith (Printf.sprintf "invalid RFC3339 timestamp: %s" value);
  let days =
    days_from_civil (int_field value 0 4) (int_field value 5 2)
      (int_field value 8 2)
  in
  let local =
    (days * 86400)
    + (int_field value 11 2 * 3600)
    + (int_field value 14 2 * 60)
    + int_field value 17 2
  in
  let start = timezone_start value in
  local - timezone_offset value start

let shift_rfc3339 value seconds =
  let start = timezone_start value in
  let offset = timezone_offset value start in
  let shifted =
    Unix.gmtime (float_of_int (rfc3339_seconds value + seconds + offset))
  in
  Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02d%s"
    (shifted.tm_year + 1900) (shifted.tm_mon + 1) shifted.tm_mday
    shifted.tm_hour shifted.tm_min shifted.tm_sec
    (String.sub value start (String.length value - start))


let exchange_of_symbol ~data_dir symbol =
  match Data.stockinfo_kind ~data_dir ~symbol with
  | Some "twse" -> "TSE"
  | Some "tpex" -> "OTC"
  | Some kind ->
      failwith
        (Printf.sprintf "unsupported TW exchange type %S for %s" kind symbol)
  | None ->
      failwith
        (Printf.sprintf "TW stockinfo has no exchange for %s" symbol)
  | exception End_of_file -> failwith "empty TW stockinfo cache"

let tw_settlement_amount day settlements =
  match
    List.filter
      (fun (settlement : Shioaji.settlement) -> settlement.day = day)
      settlements
  with
  | [settlement] -> settlement.amount
  | [] ->
      failwith (Printf.sprintf "TW settlements missing T+%d row" day)
  | _ ->
      failwith (Printf.sprintf "TW settlements contain duplicate T+%d rows" day)

let tw_production_cash ~balance ~settlements =
  let () =
    if not (Float.is_finite balance) then
      failwith "TW account balance is not finite"
  in
  let () =
    List.iter
      (fun (settlement : Shioaji.settlement) ->
        if not (Float.is_finite settlement.amount) then
          failwith "TW settlement amount is not finite"
        else if settlement.day < 0 || settlement.day > 2 then
          failwith
            (Printf.sprintf "TW settlements contain unexpected T+%d row"
               settlement.day))
      settlements
  in
  let () = ignore (tw_settlement_amount 0 settlements) in
  let cash =
    balance +. tw_settlement_amount 1 settlements
    +. tw_settlement_amount 2 settlements
  in
  if Float.is_finite cash then cash
  else failwith "TW spendable cash is not finite"

let equity_of ~cash ~positions =
  let () =
    if not (Float.is_finite cash) then
      failwith "TW spendable cash is not finite"
  in
  let equity =
    List.fold_left
      (fun equity (position : Shioaji.position) ->
        let () =
          if position.shares < 0
             || not (Float.is_finite position.last_price)
             || not (Float.is_finite position.loan_amount)
             || not (Float.is_finite position.interest)
          then
            failwith "TW position contains invalid account values"
        in
        equity
        +. (float_of_int position.shares *. position.last_price)
        -. position.loan_amount -. position.interest)
      cash positions
  in
  if Float.is_finite equity then equity
  else failwith "TW account equity is not finite"


let legs_of_plan ~codes ~exchanges ~prices (plan : Engine.fill_plan) =
  let count = Array.length plan.planned_assets in
  let () =
    if Array.length codes <> count || Array.length exchanges <> count
       || Array.length prices <> count then
      failwith "TW leg inputs do not match planned assets"
  in
  (* Live.decide plans in absolute TWD, so its value/share capital is 1. *)
  let leg i ~odd action cond value =
    let price = prices.(i) in
    let () = if not (Float.is_finite price) || price <= 0. then
      failwith "TW planning price must be finite and positive" in
    let shares = int_of_float (Engine.shares_of_value ~capital:1. ~price value) in
    let make lot quantity =
      { code = codes.(i); exchange = exchanges.(i); action; cond; lot; quantity } in
    let common = if shares / 1000 > 0 then
      [make Shioaji.Common (shares / 1000)] else [] in
    let remainder = shares mod 1000 in
    if odd && remainder > 0 then common @ [make Shioaji.IntradayOdd remainder]
    else common
  in
  let group function_ =
    Array.to_list (Array.mapi function_ plan.planned_assets) |> List.concat in
  group (fun i (a : Engine.planned_asset) ->
    leg i ~odd:false "Sell" "MarginTrading" a.plan_sell_margin)
  @ group (fun i (a : Engine.planned_asset) ->
    leg i ~odd:true "Sell" "Cash" a.plan_sell_cash)
  @ group (fun i (a : Engine.planned_asset) ->
    leg i ~odd:false "Sell" "Cash" a.plan_refinance_cash
    @ leg i ~odd:false "Buy" "MarginTrading" a.plan_refinance_cash
    @ leg i ~odd:false "Sell" "MarginTrading" a.plan_refinance_margin
    @ leg i ~odd:false "Buy" "MarginTrading" a.plan_refinance_margin)
  @ group (fun i (a : Engine.planned_asset) ->
    leg i ~odd:true "Buy" "Cash" a.plan_buy_cash)
  @ group (fun i (a : Engine.planned_asset) ->
    leg i ~odd:false "Buy" "MarginTrading" a.plan_buy_margin)

let taipei_phase ~now =
  let local =
    Unix.gmtime (float_of_int (rfc3339_seconds now + (8 * 60 * 60)))
  in
  let seconds = (local.tm_hour * 60 + local.tm_min) * 60 + local.tm_sec in
  if local.tm_wday = 0 || local.tm_wday = 6 then
    `Weekend
  else if seconds < (13 * 60 + 5) * 60 then
    `Before_fetch
  else if seconds < (13 * 60 + 20) * 60 then
    `Fetch
  else if seconds < (13 * 60 + 25) * 60 then
    `Decide
  else
    `After_close

let next_actions ~now ~next_close =
  let now = rfc3339_seconds now in
  let close = rfc3339_seconds next_close in
  let decide_at = close - (15 * 60) in
  let submit_at = close - (2 * 60) in
  if now < decide_at then
    `Sleep_until (shift_rfc3339 next_close (-15 * 60))
  else if now < submit_at then
    `Decide
  else if now < close then
    `Cutoff_passed
  else
    `Post_close

let startup_ok (account : Alpaca.account_t) =
  match account.status, account.trading_blocked with
  | "ACTIVE", false -> Ok ()
  | "ACTIVE", true -> Error "account trading is blocked"
  | status, _ -> Error (Printf.sprintf "account status is %s" status)

let tw_server_mode_ok mode (info : Shioaji.info) =
  match mode, info.simulation with
  | Paper, true | Live, false -> Ok ()
  | Paper, false ->
      Error "--live is required for a production Shioaji server"
  | Live, true ->
      Error "--live requires a production Shioaji server"

let tw_startup_ok mode ~equity info =
  match mode, equity with
  | Paper, Some value when not (Float.is_finite value) || value <= 0. ->
      Error "simulation equity must be finite and positive"
  | Paper, None -> Error "simulation mode requires --equity"
  | Live, Some _ -> Error "--equity is not allowed in production"
  | Paper, Some _ | Live, None -> tw_server_mode_ok mode info

let date_prefix timestamp =
  let () =
    if String.length timestamp < 10 then
      failwith (Printf.sprintf "invalid RFC3339 timestamp: %s" timestamp)
  in
  String.sub timestamp 0 10

let validate_date label date =
  let valid =
    try
      String.length date = 10
      && date_prefix (shift_rfc3339 (date ^ "T00:00:00+08:00") 0) = date
    with Failure _ | Invalid_argument _ -> false
  in
  if not valid then failwith (Printf.sprintf "invalid %s date %S" label date)


let maturity_rollover_legs ~session_date ~symbol ~exchange details =
  let () = validate_date "session" session_date in
  (* TW lots mature at the first session on or after 18 clamped
     calendar months. *)
  List.concat_map
    (fun (detail : Shioaji.position_detail) ->
      let () = validate_date "position origination" detail.date in
      if detail.code = symbol && detail.cond = "MarginTrading"
         && detail.lots > 0
         && session_date >= Engine.add_months_clamped detail.date 18
      then
        [{ code = symbol; exchange; action = "Sell"; cond = "MarginTrading";
           lot = Shioaji.Common; quantity = detail.lots };
         { code = symbol; exchange; action = "Buy"; cond = "MarginTrading";
           lot = Shioaji.Common; quantity = detail.lots }]
      else [])
    details

let digit character = character >= '0' && character <= '9'

let rec digits value index stop =
  index = stop
  || digit value.[index] && digits value (index + 1) stop

let shioaji_timestamp_seconds value =
  let invalid () =
    failwith (Printf.sprintf "invalid TW snapshot timestamp %S" value)
  in
  let length = String.length value in
  let () =
    if length < 19
       || value.[4] <> '-' || value.[7] <> '-' || value.[10] <> 'T'
       || value.[13] <> ':' || value.[16] <> ':'
       || not (digits value 0 4) || not (digits value 5 7)
       || not (digits value 8 10) || not (digits value 11 13)
       || not (digits value 14 16) || not (digits value 17 19)
    then
      invalid ()
  in
  let date = String.sub value 0 10 in
  let () = validate_date "TW snapshot" date in
  let hour = int_field value 11 2 in
  let minute = int_field value 14 2 in
  let second = int_field value 17 2 in
  let () =
    if hour > 23 || minute > 59 || second > 59 then invalid ()
  in
  let zone_start =
    if length > 19 && value.[19] = '.' then
      let rec fraction_end index =
        if index < length && digit value.[index] then
          fraction_end (index + 1)
        else
          index
      in
      let index = fraction_end 20 in
      if index = 20 || index - 20 > 9 then invalid () else index
    else
      19
  in
  let zone =
    if zone_start = length then
      "+08:00"
    else if zone_start + 1 = length && value.[zone_start] = 'Z' then
      "Z"
    else if zone_start + 6 = length
            && (value.[zone_start] = '+' || value.[zone_start] = '-')
            && value.[zone_start + 3] = ':'
            && digits value (zone_start + 1) (zone_start + 3)
            && digits value (zone_start + 4) (zone_start + 6)
    then
      let offset_hour = int_field value (zone_start + 1) 2 in
      let offset_minute = int_field value (zone_start + 4) 2 in
      if offset_hour <= 23 && offset_minute <= 59 then
        String.sub value zone_start 6
      else
        invalid ()
    else
      invalid ()
  in
  rfc3339_seconds (String.sub value 0 19 ^ zone)

let tw_snapshot_date (snapshot : Shioaji.snapshot) =
  let () = ignore (shioaji_timestamp_seconds snapshot.datetime) in
  String.sub snapshot.datetime 0 10

let tw_provisional_bar (snapshot : Shioaji.snapshot) : Data.bar =
  let () =
    if not (Float.is_finite snapshot.open_) || snapshot.open_ <= 0.
       || not (Float.is_finite snapshot.high) || snapshot.high <= 0.
       || not (Float.is_finite snapshot.low) || snapshot.low <= 0.
       || snapshot.low > snapshot.high
       || snapshot.open_ < snapshot.low || snapshot.open_ > snapshot.high
       || not (Float.is_finite snapshot.total_volume)
       || snapshot.total_volume < 0.
    then
      failwith "TW snapshot has invalid OHLCV values"
  in
  let close =
    if Float.is_finite snapshot.close && snapshot.close > 0. then
      snapshot.close
    else if Float.is_finite snapshot.bid && snapshot.bid > 0.
            && Float.is_finite snapshot.ask && snapshot.ask > 0.
            && snapshot.bid <= snapshot.ask
    then
      (snapshot.bid +. snapshot.ask) /. 2.
    else
      failwith "TW snapshot has no usable near-close price"
  in
  let () =
    if close < snapshot.low || close > snapshot.high then
      failwith "TW snapshot price is outside its session range"
  in
  { date = tw_snapshot_date snapshot;
    o = snapshot.open_;
    h = snapshot.high;
    l = snapshot.low;
    c = close;
    v = snapshot.total_volume }


let position_totals ~symbols ~prices positions =
  let () =
    if Array.length symbols <> Array.length prices then
      failwith "TW position inputs do not match symbols"
  in
  (* ponytail: quadratic duplicate scan avoids allocation for small portfolios;
     use a symbol set if large portfolios make this material. *)
  let () = Array.iteri (fun i symbol ->
    let rec check j =
      if j < i then
        if symbols.(j) = symbol then
          failwith ("live trading needs distinct symbols: " ^ symbol)
        else check (j + 1)
    in
    check 0) symbols in
  let () = Array.iter (fun price ->
    if not (Float.is_finite price) || price <= 0. then
      failwith "TW planning price must be finite and positive") prices in
  let () = List.iter (fun (p : Shioaji.position) ->
    let active = p.shares <> 0 || p.loan_amount <> 0. || p.interest <> 0. in
    let () = if p.shares < 0 || not (Float.is_finite p.loan_amount)
      || p.loan_amount < 0. || not (Float.is_finite p.interest) || p.interest < 0.
      then failwith "TW position contains invalid account values" in
    let () = if active && not (Array.exists (( = ) p.code) symbols) then
      failwith ("TW account holds unsupported symbol " ^ p.code) in
    if active && p.cond <> "Cash" && p.cond <> "MarginTrading" then
      failwith ("TW account holds unsupported inventory " ^ p.cond)) positions in
  Array.mapi (fun i symbol ->
    let cs, ms, loans, interests = List.fold_left
      (fun (cs, ms, loans, interests) (p : Shioaji.position) ->
        if p.code <> symbol then cs, ms, loans, interests
        else match p.cond with
          | "Cash" -> cs +. float_of_int p.shares, ms, loans, interests
          | "MarginTrading" -> cs, ms +. float_of_int p.shares,
              loans +. p.loan_amount, interests +. p.interest
          | _ -> cs, ms, loans, interests)
      (0., 0., 0., 0.) positions in
    cs, ms, cs *. prices.(i), ms *. prices.(i), loans, interests) symbols

let fetch_position_details ?(position_details = Shioaji.position_details)
    symbol positions =
  List.concat_map
    (fun (position : Shioaji.position) ->
      if position.code = symbol && position.cond = "MarginTrading"
         && position.shares > 0
      then
        let details = position_details ~detail_id:position.id in
        let () =
          ignore
            (List.fold_left
               (fun available (detail : Shioaji.position_detail) ->
                 if detail.code = position.code
                    && detail.cond = "MarginTrading"
                 then
                   if detail.lots > available then
                     failwith
                       ("TW position_detail quantity exceeds held margin shares for "
                        ^ position.code)
                   else available - detail.lots
                 else available)
               (position.shares / 1000) details)
        in
        details
      else [])
    positions

(* SinoPac rebates the promotional discount later; settlement debits 14.25 bps. *)
let tw_live_debit_costs symbol =
  { (Engine.default_costs ~market:"tw" ~symbol) with fee_bps = 14.25 }

let strategy_market stocks =
  match stocks with
  | [] -> failwith "live trading needs one market"
  | (_, market, _) :: rest ->
      let () = if not (List.for_all (fun (_, other, _) -> other = market) rest)
        then failwith "live trading needs one market" in
      let seen = Hashtbl.create (List.length stocks) in
      let () = List.iter (fun (_, _, symbol) ->
        if Hashtbl.mem seen symbol then
          failwith ("live trading needs distinct symbols: " ^ symbol);
        Hashtbl.add seen symbol ()) stocks in
      market

let align_history ~symbols arrays =
  let dates bars = Array.to_list (Array.map (fun (b : Data.bar) -> b.date) bars) in
  let union = List.concat_map dates arrays |> List.sort_uniq String.compare in
  let recent = List.rev union |> List.to_seq |> Seq.take 5 |> List.of_seq in
  let () = List.iteri (fun i bars ->
    let present = Hashtbl.create (Array.length bars) in
    let () = Array.iter (fun (b : Data.bar) -> Hashtbl.replace present b.date ()) bars in
    if List.exists (fun date -> not (Hashtbl.mem present date)) recent then
      failwith ("history gap in " ^ symbols.(i) ^ " within the last 5 sessions")) arrays in
  let common = Data.common_dates arrays in
  let fetched_through = match List.rev common with
    | date :: _ -> date
    | [] -> failwith "live history has no common trading dates" in
  let keep = Hashtbl.create (List.length common) in
  let () = List.iter (fun date -> Hashtbl.replace keep date ()) common in
  fetched_through, List.map
    (Data.filter_dates ~keep:(fun date -> Hashtbl.mem keep date)) arrays

let decision_targets ast stocks arrays provisional ratios =
  let index = ref 0 in
  let assets = List.map2 (fun (alias, _, _) bars ->
    let provisional_bar = provisional.(!index) in
    let () = incr index in
    alias, Array.append bars [|provisional_bar|]) stocks arrays in
  let strategy = Dsl.compile_ast ast ~params:[] ~assets in
  let length = Array.length strategy.Engine.targets.(0) in
  let row i = Array.map (fun targets -> targets.(i)) strategy.targets in
  let effective i = fst (Engine.effective_targets ~financing_ratios:ratios (row i)) in
  effective (length - 1),
  (if length = 1 then Array.make (List.length stocks) 0. else effective (length - 2))

let decide ?provisional_close ?previous_session ?equity ?tw_balance
    ?tw_settlements ?tw_positions ?tw_position_details ?tw_snapshots mode
    ~session_date ~strat_path ~data_dir =
  let ast = Dsl.parse_file strat_path in
  let rebalance = Option.value (Dsl.rebalance_of ~filename:strat_path ast) ~default:false in
  let stocks = Dsl.stocks_of ~filename:strat_path ast in
  let market = strategy_market stocks in
  let symbols = Array.of_list (List.map (fun (_, _, s) -> s) stocks) in
  let () = if provisional_close <> None && Array.length symbols <> 1 then
    failwith "--provisional-close needs a one-stock strategy" in
  let check_session (bar : Data.bar) =
    match snapshot_session ~session_date ~provisional_date:bar.date with
    | `Proceed -> ()
    | `Skip reason -> failwith reason in
  match market with
  | "us" ->
      let loaded = Array.map (fun symbol ->
        let snapshot = match provisional_close with
          | None -> Alpaca.snapshot symbol
          | Some price ->
              let path = Filename.concat
                (Filename.concat (Filename.concat data_dir "us") symbol) (symbol ^ ".csv") in
              let prev_day_date = match Data.last_cached_date path with
                | Some date -> date
                | None -> failwith (Printf.sprintf
                    "%s has no cached rows; run bt fetch us/%s" path symbol) in
              override_snapshot ~session_date ~prev_day_date ~price in
        let () = Data.fetch ~market:"us" ~symbol ~from_:None
          ~to_:snapshot.prev_day_date ~data_dir in
        let asset = Data.load_asset ~market:"us" ~symbol ~from_:None
          ~to_:(Some snapshot.prev_day_date) ~data_dir in
        let through = asset.signal.(Array.length asset.signal - 1).date in
        let () = if not (cache_is_fresh ~last_cached:through
          ~prev_trading_day:snapshot.prev_day_date) then
          failwith (Printf.sprintf "stale cache: fetched through %s, expected %s"
            through snapshot.prev_day_date) in
        asset.signal, provisional_bar snapshot) symbols in
      let fetched_through, arrays = align_history ~symbols
        (Array.to_list (Array.map fst loaded)) in
      let provisional = Array.map snd loaded in
      let () = Array.iter check_session provisional in
      let ratios = Array.make (Array.length symbols)
        (Engine.profile_of_market "us").default_financing_ratio in
      let targets, previous_targets =
        decision_targets ast stocks arrays provisional ratios in
      let account = Alpaca.account mode in
      let held = Array.map (Alpaca.position_qty mode) symbols in
      let position_symbols = Alpaca.positions mode in
      let prices = Array.map (fun (b : Data.bar) -> b.c) provisional in
      let state, actions = us_plan_action ~rebalance ~symbols ~date:session_date
        ~account ~position_symbols ~held ~prices ~targets ~previous_targets in
      { fetched_through; equity = state.equity; cash = state.cash;
        debit = Array.fold_left ( +. ) 0. state.loans; legs = [];
        assets = Array.mapi (fun i symbol ->
          { symbol; provisional = provisional.(i); target = targets.(i);
            held = held.(i); action = actions.(i) }) symbols }
  | "tw" ->
      let () = validate_date "session" session_date in
      let () = match mode, equity with
        | Paper, Some v when Float.is_finite v && v > 0. -> ()
        | Paper, Some _ -> failwith "simulation equity must be finite and positive"
        | Paper, None -> failwith "simulation mode requires --equity"
        | Live, Some _ -> failwith "--equity is not allowed in production"
        | Live, None -> () in
      let fetch_required = Option.is_none previous_session in
      let previous_session = match previous_session with
        | Some date -> date
        | None -> Data.previous_trading_day ~before:session_date in
      let () = validate_date "previous session" previous_session in
      let () = if previous_session >= session_date then failwith
        (Printf.sprintf "previous TW trading session %s is not before %s"
          previous_session session_date) in
      let exchanges = Array.map (exchange_of_symbol ~data_dir) symbols in
      let snapshots = match provisional_close, tw_snapshots with
        | Some price, _ ->
            [|{ Shioaji.datetime = session_date ^ "T13:20:00+08:00";
                open_ = price; high = price; low = price; close = price;
                bid = price; ask = price; total_volume = 0. }|]
        | None, Some snapshots -> snapshots
        | None, None -> Shioaji.snapshot ~contracts:
            (Array.mapi (fun i code -> exchanges.(i), code) symbols) in
      let () = if Array.length snapshots <> Array.length symbols then
        failwith "invalid Shioaji snapshot response" in
      let arrays = Array.map (fun symbol ->
        let () = if fetch_required then
          let () = Data.fetch ~market:"tw" ~symbol ~from_:None ~to_:previous_session ~data_dir in
          Data.fetch_tw_adjustments ~symbol ~to_:session_date ~data_dir in
        let asset = Data.load_asset ~market:"tw" ~symbol ~from_:None
          ~to_:(Some previous_session) ~data_dir in
        let through = match Array.length asset.signal with
          | 0 -> failwith "TW cache has no previous trading session"
          | n -> asset.signal.(n - 1).date in
        let () = if through <> previous_session then
          failwith (Printf.sprintf "stale TW cache: fetched through %s, expected %s"
            through previous_session) in
        asset.signal) symbols |> Array.to_list in
      let fetched_through, arrays = align_history ~symbols arrays in
      let provisional = Array.map tw_provisional_bar snapshots in
      let () = Array.iter check_session provisional in
      let prices = Array.map (fun (b : Data.bar) -> b.c) provisional in
      let ratios = Array.map
        (fun symbol -> Data.financing_ratio ~market:"tw" ~data_dir ~symbol) symbols in
      let targets, previous_targets =
        decision_targets ast stocks arrays provisional ratios in
      let positions = match tw_positions with
        | Some positions -> positions | None -> Shioaji.positions () in
      let details = match tw_position_details, tw_positions with
        | Some details, _ -> details
        | None, Some _ -> []
        | None, None -> Array.to_list symbols
            |> List.concat_map (fun symbol -> fetch_position_details symbol positions) in
      let totals = position_totals ~symbols ~prices positions in
      let cash_values = Array.map (fun (_, _, cv, _, _, _) -> cv) totals in
      let margin_values = Array.map (fun (_, _, _, mv, _, _) -> mv) totals in
      let loans = Array.map (fun (_, _, _, _, l, _) -> l) totals in
      let interests = Array.map (fun (_, _, _, _, _, i) -> i) totals in
      let sum values = Array.fold_left ( +. ) 0. values in
      let cv = sum cash_values and mv = sum margin_values in
      let loan = sum loans and interest = sum interests in
      let cash, equity = match mode, equity with
        | Paper, Some equity -> equity -. cv -. mv +. loan +. interest, equity
        | Live, None ->
            let balance = match tw_balance with Some b -> b | None -> Shioaji.balance () in
            let settlements = match tw_settlements with
              | Some s -> s | None -> Shioaji.settlements () in
            let cash = tw_production_cash ~balance ~settlements in
            cash, cash +. cv +. mv -. loan -. interest
        | Paper, None | Live, Some _ -> assert false in
      let () = if not (Float.is_finite cash) then
        failwith "TW inferred cash balance is not finite" in
      let () = if not (Float.is_finite equity) || equity <= 0. then
        failwith "TW account equity is not positive" in
      let state : Engine.plan_state =
        { equity; cash; cash_values; margin_values; loans; interests;
          tail_interests = Array.make (Array.length symbols) 0.;
          debt = 0.; receivables = 0.; previous_targets } in
      let plan = Engine.plan_fills ~costs:(Array.map tw_live_debit_costs symbols)
        ~capital:1. ~profile:(Engine.profile_of_market "tw")
        ~financing_ratios:ratios ~state ~prices ~targets ~force:rebalance in
      let rollover = Array.to_list (Array.mapi (fun i symbol ->
        maturity_rollover_legs ~session_date ~symbol ~exchange:exchanges.(i) details) symbols)
        |> List.concat in
      let legs = rollover @ legs_of_plan ~codes:symbols ~exchanges ~prices plan in
      { fetched_through; equity; cash; debit = loan; legs;
        assets = Array.mapi (fun i symbol ->
          let cs, ms, _, _, _, _ = totals.(i) in
          { symbol; provisional = provisional.(i); target = targets.(i);
            held = cs +. ms;
            action = Orders (List.filter (fun (l : leg) -> l.code = symbol) legs) }) symbols }
  | _ -> failwith "live trading supports us and tw only"

let printable_ascii value =
  String.map
    (fun character ->
      if character >= ' ' && character <= '~' then character else '?')
    value

let log format =
  Printf.ksprintf
    (fun line ->
      let utc = Unix.gmtime (Unix.gettimeofday ()) in
      Printf.printf "%04d-%02d-%02dT%02d:%02d:%02dZ %s\n"
        (utc.tm_year + 1900) (utc.tm_mon + 1) utc.tm_mday
        utc.tm_hour utc.tm_min utc.tm_sec (printable_ascii line);
      flush stdout)
    format
let log_rebalance_warning strat_path = function
  | Some _ -> ()
  | None ->
      log "warning: %s does not declare rebalance; trading only when the target changes"
        strat_path


let mode_name = function
  | Paper -> "paper"
  | Live -> "live"

let sleep_until timestamp =
  let delay =
    float_of_int (rfc3339_seconds timestamp) -. Unix.gettimeofday ()
  in
  if delay > 0. then Unix.sleepf delay

let timestamp_date = date_prefix

let lot_name = function
  | Shioaji.Common -> "Common"
  | Shioaji.IntradayOdd -> "IntradayOdd"

let order_description = function
  | Skip reason -> Printf.sprintf "skip:%s" reason
  | Order { side; qty; id } ->
      let side =
        match side with
        | `Buy -> "buy"
        | `Sell -> "sell"
      in
      Printf.sprintf "%s:%s:%s" side (Alpaca.qty_string qty) id
  | Orders legs ->
      legs
      |> List.map
           (fun (leg : leg) ->
             Printf.sprintf "%s:%s:%s:%d" leg.action leg.cond
               (lot_name leg.lot) leg.quantity)
      |> String.concat ","

let log_decision date (decision : decision) =
  if Array.for_all (fun (a : asset_decision) ->
    a.action = Skip "target unchanged") decision.assets then
    log "date=%s fetched-through=%s equity=%.10g cash=%.10g debit=%.10g order=skip:target unchanged"
      date decision.fetched_through decision.equity decision.cash decision.debit
  else
    let () = log "date=%s fetched-through=%s equity=%.10g cash=%.10g debit=%.10g"
      date decision.fetched_through decision.equity decision.cash decision.debit in
    Array.iter (fun (a : asset_decision) ->
      log "date=%s symbol=%s provisional-close=%.10g target=%.10g held=%.10g order=%s fill=pending"
        date a.symbol a.provisional.c a.target a.held (order_description a.action))
      decision.assets

let log_fill date symbol client_order_id = function
  | None ->
      log "date=%s symbol=%s client-order-id=%s fill-status=missing fill-price=- filled-qty=0"
        date symbol client_order_id
  | Some (order : Alpaca.order_t) ->
      let price =
        match order.filled_avg_price with
        | Some value -> Printf.sprintf "%.10g" value
        | None -> "-"
      in
      log
        "date=%s symbol=%s client-order-id=%s fill-status=%s fill-price=%s \
         filled-qty=%.10g"
        date symbol client_order_id order.status price order.filled_qty

let terminal_order_status = function
  | "filled" | "canceled" | "expired" | "rejected" | "stopped" -> true
  | _ -> false

let rec poll_fill mode date symbol client_order_id deadline =
  let order = Alpaca.order_by_client_id mode client_order_id in
  match order with
  | Some order when terminal_order_status order.status ->
      log_fill date symbol client_order_id (Some order)
  | _ when Unix.gettimeofday () >= deadline ->
      log_fill date symbol client_order_id order
  | _ ->
      let () = Unix.sleepf 15. in
      poll_fill mode date symbol client_order_id deadline

let finish_order mode next_close date symbol client_order_id
    (order : Alpaca.order_t) =
  if terminal_order_status order.status then
    log_fill date symbol client_order_id (Some order)
  else
    let () = sleep_until next_close in
    poll_fill mode date symbol client_order_id
      (float_of_int (rfc3339_seconds next_close + (5 * 60)))

let execute_decision ?(existing = []) ?(sleep = Unix.sleepf) ?finish
    ?(order_by_client_id = Alpaca.order_by_client_id)
    ?(clock = Alpaca.clock) ?(submit_market = Alpaca.submit_market)
    mode date next_close (decision : decision) =
  let finish = match finish with
    | Some finish -> finish
    | None -> fun next_close date symbol order ->
        finish_order mode next_close date symbol (client_order_id ~symbol ~date) order in
  let error_text = function
    | Failure message -> message
    | error -> Printexc.to_string error in
  let posted = ref false in
  let stopped = ref false in
  let placed = ref existing in
  let finish_all () = List.iter (fun (symbol, order) ->
    try finish next_close date symbol order with error ->
      (try log "date=%s symbol=%s error=%s order=skip"
        date symbol (Printexc.to_string error) with _ -> ())) (List.rev !placed) in
  let orders = Array.to_list decision.assets
    |> List.filter (fun (a : asset_decision) ->
      not (List.mem_assoc a.symbol existing))
    |> List.filter_map (fun (a : asset_decision) -> match a.action with
      | Order { side; qty; id } -> Some (a.symbol, side, qty, id)
      | Skip _ -> None
      | Orders _ -> failwith "TW order legs require Shioaji") in
  let execute () =
    (* Complete every dedupe lookup before logging or submitting. *)
    let pending = List.filter (fun (symbol, _, _, id) ->
      match order_by_client_id mode id with
      | None -> true
      | Some order ->
          let () = placed := (symbol, order) :: !placed in
          let () = log "date=%s symbol=%s order=existing:%s fill=pending" date symbol id in
          false) orders in
    let preflight () =
      let c = clock mode in
      if not c.is_open || next_actions ~now:c.timestamp ~next_close <> `Decide
      then failwith "submit cutoff passed" in
    let restarting_sell = List.exists
      (fun (_, (o : Alpaca.order_t)) -> o.side = "sell") !placed in
    let pending_sell = List.exists (fun (_, side, _, _) -> side = `Sell) pending in
    let () = if pending <> [] && (not restarting_sell || pending_sell) then preflight () in
    let () = log_decision date decision in
    let submit (symbol, side, qty, id) =
      let () = preflight () in
      let () = posted := true in
      match submit_market mode ~symbol ~qty ~side ~client_order_id:id with
      | order ->
          let () = placed := (symbol, order) :: !placed in
          if order.status = "rejected" then
            failwith (if side = `Sell then "sell " ^ symbol ^ " rejected"
              else "Alpaca rejected the order")
      | exception error ->
          failwith (if side = `Sell then "sell " ^ symbol ^ " uncertain"
            else "order submission uncertain: " ^ Printexc.to_string error) in
    let sell_failure = ref None in
    let submit_checked ((symbol, side, _, _) as request) =
      match submit request with
      | () -> ()
      | exception error ->
          if not !posted then raise error
          else
            let () = (try log "date=%s symbol=%s error=%s order=skip"
              date symbol (error_text error) with _ -> ()) in
            if side = `Sell && !sell_failure = None then
              sell_failure := Some error in
    let sells, buys = List.partition (fun (_, side, _, _) -> side = `Sell) pending in
    let has_sell = sells <> [] || List.exists
      (fun (_, (o : Alpaca.order_t)) -> o.side = "sell") !placed in
    let () = List.iter submit_checked sells in
    let () = match !sell_failure with
      | None -> ()
      | Some error -> raise error in
    if not has_sell || buys = [] then List.iter submit_checked buys
    else
      let rec wait_sells () =
        let stop = ref None in
        let open_sell = ref None in
        let () = placed := List.map (fun (symbol, (order : Alpaca.order_t)) ->
          if order.side <> "sell" then symbol, order
          else
            let current =
              match order_by_client_id mode (client_order_id ~symbol ~date) with
              | None -> order
              | Some current -> current
              | exception _ -> failwith ("sell " ^ symbol ^ " uncertain") in
            let () = if current.status <> "filled" then
              if terminal_order_status current.status then
                (if !stop = None then stop := Some ("sell " ^ symbol ^ " " ^ current.status))
              else if !open_sell = None then open_sell := Some symbol in
            symbol, current) !placed in
        match !stop, !open_sell with
        | Some reason, _ -> let () = stopped := true in failwith reason
        | None, None -> ()
        | None, Some symbol ->
            let c = clock mode in
            if not c.is_open || next_actions ~now:c.timestamp ~next_close <> `Decide then
              let () = stopped := true in
              failwith ("sell " ^ symbol ^ " open at cutoff")
            else let () = sleep 15. in wait_sells () in
      let () = wait_sells () in
      List.iter submit_checked buys in
  match execute () with
  | () -> (try finish_all () with _ -> ())
  | exception error when !posted || !stopped ->
      let () = (try log "date=%s error=%s order=skip" date (error_text error) with _ -> ()) in
      (try finish_all () with _ -> ())
  | exception Failure message when message = "submit cutoff passed" ->
      let () = (try log "date=%s error=submit cutoff passed order=skip" date with _ -> ()) in
      (try finish_all () with _ -> ())
  | exception error -> raise error

let retry_clock ~clock ~sleep ~dispatch =
  let rec loop () =
    sleep 60.;
    match clock () with
    | exception _ -> loop ()
    | recovered -> dispatch recovered
  in
  loop ()

let us_step ~symbols ~lookup ~decide ~execute ~finish ~sleep_until ~retry
    ~continue (clock : Alpaca.clock_t) =
  if not clock.is_open then
    let () = sleep_until clock.next_open in continue ()
  else match next_actions ~now:clock.timestamp ~next_close:clock.next_close with
  | `Sleep_until timestamp -> let () = sleep_until timestamp in continue ()
  | `Post_close -> let () = sleep_until clock.next_open in continue ()
  | (`Decide | `Cutoff_passed as phase) ->
      let date = timestamp_date clock.timestamp in
      let existing = ref [] in
      let end_day () = let () = sleep_until clock.next_open in continue () in
      let reconcile () = List.iter (fun (symbol, order) ->
        try finish clock date (client_order_id ~symbol ~date) order with error ->
          (try log "date=%s symbol=%s error=%s order=skip"
            date symbol (Printexc.to_string error) with _ -> ())) (List.rev !existing) in
      match
        let () = Array.iter (fun symbol ->
          let id = client_order_id ~symbol ~date in
          match lookup id with
          | None -> ()
          | Some order ->
              let () = existing := (symbol, order) :: !existing in
              log "date=%s symbol=%s order=existing:%s fill=pending" date symbol id) symbols in
        let () = if phase = `Cutoff_passed
          && List.length !existing <> Array.length symbols then
          log "date=%s error=submit cutoff passed order=skip" date in
        if List.length !existing = Array.length symbols || phase = `Cutoff_passed then
          let () = reconcile () in `End
        else
          let decision = decide date in
          let decision = { decision with assets = Array.map (fun (a : asset_decision) ->
            if List.mem_assoc a.symbol !existing then { a with action = Skip "existing order" }
            else a) decision.assets } in
          let () = execute (List.rev !existing) clock decision in
          `End
      with
      | `End -> end_day ()
      | exception error ->
          if phase = `Cutoff_passed then
            let () = (try log "date=%s error=%s order=skip" date
              (Printexc.to_string error) with _ -> ()) in
            let () = reconcile () in
            end_day ()
          else
            let () = log "date=%s error=%s order=retry" date (Printexc.to_string error) in
            retry ()

let run_us mode ~symbols ~strat_path ~data_dir ~rebalance_choice =
  let account = Alpaca.account mode in
  let () =
    match startup_ok account with
    | Ok () -> ()
    | Error reason -> failwith reason
  in
  log "startup mode=%s account=%s equity=%.10g" (mode_name mode)
    account.account_number account.equity;
  let () = log_rebalance_warning strat_path rebalance_choice in
  let rec cycle () =
    match Alpaca.clock mode with
    | exception error ->
        log "date=unknown error=%s order=retry"
          (Printexc.to_string error);
        retry_clock ~clock:(fun () -> Alpaca.clock mode) ~sleep:Unix.sleepf
          ~dispatch:step
    | clock -> step clock
  and step clock =
    us_step ~symbols ~lookup:(Alpaca.order_by_client_id mode)
      ~decide:(fun date -> decide mode ~session_date:date ~strat_path ~data_dir)
      ~execute:(fun existing clock decision ->
        execute_decision ~existing mode (timestamp_date clock.timestamp)
          clock.next_close decision)
      ~finish:(fun clock date id order ->
        let symbol = Array.find_opt (fun symbol ->
          client_order_id ~symbol ~date = id) symbols |> Option.get in
        finish_order mode clock.next_close date symbol id order)
      ~sleep_until
      ~retry:(fun () ->
        retry_clock ~clock:(fun () -> Alpaca.clock mode) ~sleep:Unix.sleepf ~dispatch:step)
      ~continue:cycle clock
  in
  cycle ()

let taipei_now () =
  let local = Unix.gmtime (Unix.gettimeofday () +. (8. *. 60. *. 60.)) in
  Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02d+08:00"
    (local.tm_year + 1900) (local.tm_mon + 1) local.tm_mday
    local.tm_hour local.tm_min local.tm_sec

let sleep_taipei ~days ~hour ~minute =
  let now = Unix.gettimeofday () in
  let local = now +. (8. *. 60. *. 60.) in
  let local_midnight = floor (local /. 86400.) *. 86400. in
  let target =
    local_midnight +. float_of_int (days * 86400 + hour * 3600 + minute * 60)
    -. (8. *. 60. *. 60.)
  in
  let delay = target -. now in
  if delay > 0. then Unix.sleepf delay

let prepare_tw ~exchange ~symbol ~date ~data_dir =
  let snapshots = Shioaji.snapshot ~contracts:[|exchange, symbol|] in
  let () = Array.iter (fun snapshot ->
    let snapshot_date = tw_snapshot_date snapshot in
    if snapshot_date <> date then failwith
      (Printf.sprintf "snapshot session %s is not trading date %s" snapshot_date date))
    snapshots in
  let previous_session = Data.previous_trading_day ~before:date in
  let () =
    Data.fetch ~market:"tw" ~symbol ~from_:None ~to_:previous_session
      ~data_dir
  in
  let () =
    Data.fetch_tw_adjustments ~symbol ~to_:date ~data_dir
  in
  let asset =
    Data.load_asset ~market:"tw" ~symbol ~from_:None
      ~to_:(Some previous_session) ~data_dir
  in
  let fetched_through =
    match Array.length asset.signal with
    | 0 -> failwith "TW cache has no previous trading session"
    | length -> asset.signal.(length - 1).date
  in
  let () =
    if fetched_through <> previous_session then
      failwith
        (Printf.sprintf "stale TW cache: fetched through %s, expected %s"
           fetched_through previous_session)
  in
  previous_session

let tw_legs_description legs =
  match order_description (Orders legs) with
  | "" -> "none"
  | description -> description

let error_text = function
  | Failure message -> message
  | error -> Printexc.to_string error


let log_tw_trade date (trade : Shioaji.trade) =
  let price =
    match trade.deal_price with
    | Some price -> Printf.sprintf "%.10g" price
    | None -> "-"
  in
  log "date=%s code=%s order-id=%s action=%s cond=%s lot=%s fill-status=%s deal-quantity=%d fill-price=%s"
    date trade.code trade.order_id trade.action trade.cond (lot_name trade.lot)
    trade.status trade.deal_quantity price

let tw_order_cost (costs : Engine.costs) ~action ~price ~shares =
  let value = float_of_int shares *. price in
  let commission =
    Float.max (value *. costs.fee_bps /. 10000.) costs.min_fee
  in
  let bps =
    match action with
    | "Buy" -> costs.slip_bps
    | "Sell" -> costs.tax_bps +. costs.slip_bps
    | _ -> failwith (Printf.sprintf "unsupported TW order action %s" action)
  in
  commission +. (value *. bps /. 10000.)
  +. (if action = "Sell" && costs.per_share_sell_fee > 0. then
        Engine.taf_dollars costs ~shares:(float_of_int shares)
      else 0.)

let execute_tw_legs ~mode ~bid ~ask ~now ~sleep ~place_order ~orders_today
    ~exchange ~code
    ~date ~price ~financing_ratio ~costs ~cash ~positions legs =
  let () =
    if List.exists (fun (leg : leg) ->
      leg.code <> code || leg.exchange <> exchange) legs then
      failwith "TW leg code does not match executor code"
  in
  let () = validate_date "order" date in
  let () =
    if not (Float.is_finite price) || price <= 0. then
      failwith "TW execution price must be finite and positive"
  in
  let () =
    if not (Float.is_finite financing_ratio)
       || financing_ratio < 0. || financing_ratio > 1.
    then
      failwith "TW financing ratio must be between zero and one"
  in
  let () =
    if not (Float.is_finite cash) then
      failwith "TW execution cash is not finite"
  in
  let cash_shares, margin_shares, _, _, loans, interests =
    (position_totals ~symbols:[|code|] ~prices:[|price|] positions).(0)
  in
  let cash_shares = int_of_float cash_shares in
  let margin_lots = int_of_float (margin_shares /. 1000.) in
  let () =
    if margin_lots = 0 && (loans <> 0. || interests <> 0.) then
      failwith "TW margin liabilities have no margin inventory"
  in
  let open_window () =
    let timestamp = now () in
    timestamp_date timestamp = date && taipei_phase ~now:timestamp = `Decide
  in
  let submission_window () =
    let timestamp = now () in
    let local =
      Unix.gmtime (float_of_int (rfc3339_seconds timestamp + (8 * 60 * 60)))
    in
    timestamp_date timestamp = date
    && taipei_phase ~now:timestamp = `Decide
    && (local.tm_hour * 60 + local.tm_min) * 60 + local.tm_sec
       < (13 * 60 + 24) * 60 + 30
  in
  let leg_shares (leg : leg) quantity =
    match leg.lot with
    | Shioaji.Common -> quantity * 1000
    | Shioaji.IntradayOdd -> quantity
  in
  let cash_required (leg : leg) quantity execution_price =
    let shares = leg_shares leg quantity in
    let notional = float_of_int shares *. execution_price in
    let cost =
      tw_order_cost costs ~action:"Buy" ~price:execution_price ~shares
    in
    match leg.cond with
    | "Cash" -> notional +. cost
    | "MarginTrading" ->
        ((1. -. financing_ratio) *. notional) +. cost
    | cond -> failwith (Printf.sprintf "unsupported TW buy condition %s" cond)
  in
  let affordable_quantity leg available maximum execution_price =
    let rec search low high =
      if low >= high then low
      else
        let middle = low + ((high - low + 1) / 2) in
        if cash_required leg middle execution_price <= available then
          search middle high
        else
          search low (middle - 1)
    in
    search 0 maximum
  in
  let trade_cash_effect ~margin_lots ~loans ~interests
      (leg : leg) (trade : Shioaji.trade) =
    let execution_price =
      match trade.deal_price with
      | Some value when Float.is_finite value && value > 0. -> value
      | Some _ | None -> failwith "filled TW order has no valid deal price"
    in
    let shares = leg_shares leg trade.deal_quantity in
    let notional = float_of_int shares *. execution_price in
    let cost =
      tw_order_cost costs ~action:leg.action ~price:execution_price ~shares
    in
    match leg.action, leg.cond with
    | "Sell", "Cash" -> notional -. cost, loans, interests
    | "Sell", "MarginTrading" ->
        let () =
          if margin_lots <= 0 then
            failwith "TW margin sell has no margin inventory"
        in
        let fraction =
          float_of_int trade.deal_quantity /. float_of_int margin_lots
        in
        let repayment = loans *. fraction in
        let interest = interests *. fraction in
        notional -. repayment -. interest -. cost,
        loans -. repayment, interests -. interest
    | "Buy", "Cash" ->
        -. cash_required leg trade.deal_quantity execution_price,
        loans, interests
    | "Buy", "MarginTrading" ->
        -. cash_required leg trade.deal_quantity execution_price,
        loans +. (financing_ratio *. notional), interests
    | action, _ ->
        failwith (Printf.sprintf "unsupported TW order action %s" action)
  in
  let status_matches (leg : leg) (trade : Shioaji.trade) =
    trade.code = code && trade.action = leg.action && trade.cond = leg.cond
    && trade.lot = leg.lot
  in
  let poll leg order_id =
    let rec loop remaining =
      if not (open_window ()) then
        Error
          (Printf.sprintf "order %s status unconfirmed at cutoff" order_id,
           None)
      else
        match
          try Ok (orders_today ~code ~today:date)
          with error ->
            Error
              (Printf.sprintf "order %s status unavailable: %s" order_id
                 (error_text error))
        with
        | Error reason -> Error (reason, None)
        | Ok trades ->
            (match List.filter
                     (fun (trade : Shioaji.trade) -> trade.order_id = order_id)
                     trades with
             | [] ->
                 Error
                   (Printf.sprintf "order %s has no status" order_id, None)
             | _ :: _ :: _ ->
                 Error
                   (Printf.sprintf "order %s has ambiguous status" order_id,
                    None)
             | [trade] when not (status_matches leg trade) ->
                 Error
                   (Printf.sprintf "order %s status does not match request"
                      order_id, Some trade)
             | [trade] ->
                 match trade.status with
                 | "Filled"
                   when trade.deal_quantity = leg.quantity
                        && trade.order_quantity = leg.quantity ->
                     (match trade.deal_price with
                      | Some value when Float.is_finite value && value > 0. ->
                          Ok trade
                      | Some _ | None ->
                          Error
                            (Printf.sprintf
                               "order %s filled without a valid price"
                               order_id, Some trade))
                 | "Filled" | "PartFilled" ->
                     Error
                       (Printf.sprintf "order %s partially filled %d of %d"
                          order_id trade.deal_quantity leg.quantity,
                        Some trade)
                 | "Failed" | "Inactive" | "Cancelled" | "Rejected" ->
                     Error
                       (Printf.sprintf "order %s %s" order_id
                          (String.lowercase_ascii trade.status),
                        Some trade)
                 | "PendingSubmit" | "PreSubmitted" | "Submitted" ->
                     if trade.deal_quantity <> 0 then
                       Error
                         (Printf.sprintf
                            "order %s has unconfirmed partial exposure"
                            order_id, Some trade)
                     else if trade.order_quantity <> 0
                             && trade.order_quantity <> leg.quantity
                     then
                       Error
                         (Printf.sprintf
                            "order %s status quantity does not match request"
                            order_id, Some trade)
                     else if remaining = 1 then
                       Error
                         (Printf.sprintf "order %s status timed out" order_id,
                          Some trade)
                     else
                       let () = sleep 1. in
                       loop (remaining - 1)
                 | status ->
                     Error
                       (Printf.sprintf "order %s has unsupported status %s"
                          order_id status, Some trade))
    in
    loop 5
  in
  let custom_field = "bt" ^ String.sub date 5 2 ^ String.sub date 8 2 in
  let rec submit cash cash_shares margin_lots loans interests previous trades =
    function
    | [] -> { trades = List.rev trades; remaining = []; stop_reason = None }
    | (leg : leg) :: rest ->
        let stop reason remaining =
          { trades = List.rev trades; remaining; stop_reason = Some reason }
        in
        let continue cash cash_shares margin_lots loans interests previous
            trades =
          submit cash cash_shares margin_lots loans interests previous trades
            rest
        in
        let dependency_filled =
          match previous with
          | Some ((predecessor : leg), filled)
            when predecessor.action = "Sell"
                 && leg.action = "Buy" && leg.cond = "MarginTrading"
                 && predecessor.quantity = leg.quantity
                 && predecessor.lot = leg.lot ->
              Some filled
          | _ -> None
        in
        if dependency_filled = Some false then
          stop
            (Printf.sprintf "dependent %s %s %d needs complete sell fill"
               leg.action leg.cond leg.quantity) (leg :: rest)
        else if leg.lot = Shioaji.IntradayOdd && mode = Paper then
          let () = log "submitted=skip:odd-lot-unsupported-in-simulation" in
          continue cash cash_shares margin_lots loans interests None trades
        else
          let quote =
            match leg.lot, leg.action with
            | Shioaji.Common, _ -> price
            | Shioaji.IntradayOdd, "Buy" -> ask
            | Shioaji.IntradayOdd, "Sell" -> bid
            | _, action ->
                failwith (Printf.sprintf "unsupported TW order action %s" action)
          in
          if not (Float.is_finite quote) || quote <= 0. then
            let () = log "submitted=skip:odd-lot-quote-unavailable" in
            continue cash cash_shares margin_lots loans interests None trades
          else
            let available =
              match leg.action with
              | "Buy" ->
                  affordable_quantity leg (Float.max 0. cash) leg.quantity quote
              | "Sell" -> leg.quantity
              | action ->
                  failwith (Printf.sprintf "unsupported TW order action %s" action)
            in
            if Option.is_some dependency_filled && available <> leg.quantity then
              stop
                (Printf.sprintf "dependent %s %s %d is not fully funded"
                   leg.action leg.cond leg.quantity) (leg :: rest)
            else if available = 0 then
              stop
                (Printf.sprintf "insufficient confirmed cash for %s %s %d"
                   leg.action leg.cond leg.quantity) (leg :: rest)
            else
              let submitted = { leg with quantity = available } in
              let shares = leg_shares submitted available in
              let inventory_ok =
                match submitted.action, submitted.cond, submitted.lot with
                | "Sell", "Cash", _ -> shares <= cash_shares
                | "Sell", "MarginTrading", Shioaji.Common ->
                    available <= margin_lots
                | "Buy", ("Cash" | "MarginTrading"), _ -> true
                | _, cond, _ ->
                    failwith
                      (Printf.sprintf "unsupported TW order condition %s" cond)
              in
              if not inventory_ok then
                stop
                  (Printf.sprintf "insufficient %s inventory for %d shares"
                     submitted.cond shares) (leg :: rest)
              else
                let guarded =
                  match submitted.lot with
                  | Shioaji.Common -> Ok ()
                  | Shioaji.IntradayOdd ->
                      (match
                         try Ok (orders_today ~code ~today:date)
                         with error -> Error (error_text error)
                       with
                       | Error reason ->
                           Error ("odd-lot trade history unavailable: " ^ reason)
                       | Ok history ->
                           if List.exists
                                (fun (trade : Shioaji.trade) ->
                                  trade.lot = Shioaji.IntradayOdd
                                  && trade.action <> submitted.action
                                  && trade.deal_quantity > 0)
                                history
                           then Error "opposite-direction odd-lot fill today"
                           else Ok ())
                in
                match guarded with
                | Error reason -> stop reason (leg :: rest)
                | Ok () ->
                    let request : Shioaji.order_request =
                      { exchange; code; action = submitted.action;
                        lot = submitted.lot; quantity = submitted.quantity;
                        price = (if submitted.lot = Shioaji.Common then 0. else quote);
                        cond = submitted.cond; custom_field }
                    in
                    if not (submission_window ()) then
                      stop
                        (Printf.sprintf "submission window closed before %s %s %d"
                           leg.action leg.cond leg.quantity) (leg :: rest)
                    else match
                      try Ok (place_order request)
                      with error ->
                        Error
                          (Printf.sprintf "order submission uncertain: %s"
                             (error_text error))
                    with
                    | Error reason -> stop reason rest
                    | Ok placed
                      when submitted.lot = Shioaji.IntradayOdd
                           && List.mem placed.status
                                ["Failed"; "Inactive"; "Cancelled"; "Rejected"] ->
                        let () = log "submitted=skip:odd-lot-rejected" in
                        continue cash cash_shares margin_lots loans interests
                          None trades
                    | Ok (placed : Shioaji.placed) when placed.order_id = "" ->
                        stop "order submission returned no order id" rest
                    | Ok _ when submitted.lot = Shioaji.IntradayOdd ->
                        (* test_tw_odd_sell_never_precedes_buy: no later buy spends ROD sale proceeds. *)
                        let cash =
                          if submitted.action = "Buy" then
                            cash -. cash_required submitted available quote
                          else cash
                        in
                        let cash_shares =
                          if submitted.action = "Sell" then
                            cash_shares - shares
                          else cash_shares
                        in
                        let () =
                          log "submitted=intraday-odd-rod-pending quantity=%d"
                            available
                        in
                        if available <> leg.quantity then
                          stop
                            (Printf.sprintf
                               "capped %s %s from %d to %d funded shares"
                               leg.action leg.cond leg.quantity available)
                            ({ leg with quantity = leg.quantity - available }
                             :: rest)
                        else
                          continue cash cash_shares margin_lots loans interests
                            None trades
                    | Ok placed ->
                        (match poll submitted placed.order_id with
                         | Error (reason, observed) ->
                             let trades =
                               match observed with
                               | None -> trades
                               | Some trade -> trade :: trades
                             in
                             let rejected =
                               match observed with
                               | Some trade ->
                                   trade.deal_quantity = 0
                                   && List.mem trade.status
                                        ["Failed"; "Inactive"; "Cancelled";
                                         "Rejected"]
                               | None -> false
                             in
                             if rejected then
                               continue cash cash_shares margin_lots loans
                                 interests (Some (submitted, false)) trades
                             else
                               { trades = List.rev trades; remaining = rest;
                                 stop_reason = Some reason }
                         | Ok trade ->
                             let cash_effect, loans, interests =
                               trade_cash_effect ~margin_lots ~loans ~interests
                                 submitted trade
                             in
                             let cash = cash +. cash_effect in
                             let cash_shares, margin_lots =
                               match submitted.action, submitted.cond with
                               | "Sell", "Cash" ->
                                   cash_shares - shares, margin_lots
                               | "Sell", "MarginTrading" ->
                                   cash_shares, margin_lots - available
                               | "Buy", "Cash" ->
                                   cash_shares + shares, margin_lots
                               | "Buy", "MarginTrading" ->
                                   cash_shares, margin_lots + available
                               | _ -> assert false
                             in
                             let residual =
                               if available = leg.quantity then rest
                               else { leg with
                                      quantity = leg.quantity - available }
                                    :: rest
                             in
                             if cash < -. 1e-9 then
                               { trades = List.rev (trade :: trades);
                                 remaining = residual;
                                 stop_reason =
                                   Some
                                     (Printf.sprintf
                                        "confirmed fill exceeded cash budget by %.10g"
                                        (-. cash)) }
                             else if available <> leg.quantity then
                               { trades = List.rev (trade :: trades);
                                 remaining = residual;
                                 stop_reason =
                                   Some
                                     (Printf.sprintf
                                        "capped %s %s from %d to %d funded lots"
                                        leg.action leg.cond leg.quantity
                                        available) }
                             else
                               continue cash cash_shares margin_lots loans
                                 interests (Some (submitted, true))
                                 (trade :: trades))
  in
  submit cash cash_shares margin_lots loans interests None [] legs
let run_tw mode ~equity ~symbol ~strat_path ~data_dir ~rebalance_choice =
  let info = Shioaji.info () in
  let () =
    match tw_startup_ok mode ~equity info with
    | Ok () -> ()
    | Error reason -> failwith reason
  in
  let startup_equity =
    match mode, equity with
    | Paper, Some equity ->
        let () =
          log
            "startup mode=simulation broker=shioaji account=default \
             equity-source=override equity=%.10g"
            equity
        in
        equity
    | Live, None ->
        let balance = Shioaji.balance () in
        let settlements = Shioaji.settlements () in
        let positions = Shioaji.positions () in
        let cash = tw_production_cash ~balance ~settlements in
        let equity = equity_of ~cash ~positions in
        let () =
          log
            "startup mode=production broker=shioaji account=default \
             equity-source=broker acc-balance=%.10g t0=%.10g t1=%.10g \
             t2=%.10g cash=%.10g equity=%.10g"
            balance (tw_settlement_amount 0 settlements)
            (tw_settlement_amount 1 settlements)
            (tw_settlement_amount 2 settlements) cash equity
        in
        equity
    | Paper, None | Live, Some _ -> assert false
  in
  let () = log_rebalance_warning strat_path rebalance_choice in
  let exchange = exchange_of_symbol ~data_dir symbol in
  let costs = tw_live_debit_costs symbol in
  let financing_ratio =
    Data.financing_ratio ~market:"tw" ~data_dir ~symbol
  in
  let rec cycle prepared submitted =
    let now = taipei_now () in
    let date = timestamp_date now in
    try
      match taipei_phase ~now with
      | `Weekend ->
          let weekday =
            (Unix.gmtime (Unix.gettimeofday () +. (8. *. 60. *. 60.))).tm_wday
          in
          let days = if weekday = 6 then 2 else 1 in
          let () = sleep_taipei ~days ~hour:13 ~minute:0 in
          cycle None None
      | `Before_fetch ->
          let () = sleep_taipei ~days:0 ~hour:13 ~minute:5 in
          cycle prepared submitted
      | `Fetch ->
          let prepared =
            match prepared with
            | Some (prepared_date, _) when prepared_date = date -> prepared
            | Some _ | None ->
                Some
                  (date,
                   prepare_tw ~exchange ~symbol ~date ~data_dir)
          in
          let () = sleep_taipei ~days:0 ~hour:13 ~minute:20 in
          cycle prepared submitted
      | `Decide ->
          (match submitted with
           | Some submitted when submitted = date ->
               let () = sleep_taipei ~days:0 ~hour:13 ~minute:30 in
               cycle prepared (Some submitted)
           | Some _ | None ->
               let () =
                 match tw_server_mode_ok mode (Shioaji.info ()) with
                 | Ok () -> ()
                 | Error reason ->
                     failwith
                       ("Shioaji server mode changed after startup: " ^ reason)
               in
               let prepared =
                 match prepared with
                 | Some (prepared_date, _) when prepared_date = date ->
                     prepared
                 | Some _ | None ->
                     Some
                       (date,
                        prepare_tw ~exchange ~symbol ~date ~data_dir)
               in
               let previous_session =
                 match prepared with
                 | Some (_, previous_session) -> previous_session
                 | None -> assert false
               in
               let existing = Shioaji.orders_today ~code:symbol ~today:date in
               (match existing with
                | _ :: _ ->
                    let () = log
                      "date=%s fetched-through=%s equity=%.10g cash=- debit=- submitted=skip:existing-orders"
                      date previous_session startup_equity in
                    let () = log
                      "date=%s symbol=%s provisional-close=- target=- cash-shares=- margin-shares=- loan=- planned-legs=none"
                      date symbol in
                    let () = sleep_taipei ~days:0 ~hour:13 ~minute:30 in
                    cycle prepared (Some date)
                | [] ->
                    let snapshot =
                      (Shioaji.snapshot ~contracts:[|exchange, symbol|]).(0)
                    in
                    let positions = Shioaji.positions () in
                    let position_details =
                      fetch_position_details symbol positions
                    in
                    let tw_balance, tw_settlements =
                      match mode, equity with
                      | Paper, Some _ -> None, None
                      | Live, None ->
                          let balance = Shioaji.balance () in
                          let settlements = Shioaji.settlements () in
                          Some balance, Some settlements
                      | Paper, None | Live, Some _ -> assert false
                    in
                    let decision =
                      decide ~previous_session ?equity ?tw_balance
                        ?tw_settlements ~tw_positions:positions
                        ~tw_position_details:position_details
                        ~tw_snapshots:[|snapshot|] mode ~session_date:date
                        ~strat_path ~data_dir
                    in
                    let asset = decision.assets.(0) in
                    let cash_shares, margin_shares, _, _, loans, _ =
                      (position_totals ~symbols:[|symbol|]
                        ~prices:[|asset.provisional.c|] positions).(0) in
                    let cash = decision.cash in
                    let outcome, legs =
                      match decision.legs with
                      | [] -> "skip:no-order-legs", []
                      | legs ->
                          let execution = execute_tw_legs ~mode ~bid:snapshot.bid
                            ~ask:snapshot.ask ~now:taipei_now ~sleep:Unix.sleepf
                            ~place_order:Shioaji.place_order ~orders_today:Shioaji.orders_today
                            ~exchange ~code:symbol ~date ~price:asset.provisional.c
                            ~financing_ratio ~costs ~cash ~positions legs in
                          let () = List.iter (log_tw_trade date) execution.trades in
                          let outcome = match execution.stop_reason with
                            | None -> "complete"
                            | Some reason -> Printf.sprintf "stop:%s remaining:%s" reason
                                (tw_legs_description execution.remaining) in
                          outcome, legs in
                    let () = log
                      "date=%s fetched-through=%s equity=%.10g cash=%.10g debit=%.10g submitted=%s"
                      date decision.fetched_through decision.equity decision.cash
                      decision.debit outcome in
                    let () = log
                      "date=%s symbol=%s provisional-close=%.10g target=%.10g cash-shares=%.10g margin-shares=%.10g loan=%.10g planned-legs=%s"
                      date symbol asset.provisional.c asset.target cash_shares margin_shares
                      loans (tw_legs_description legs) in
                    let () = sleep_taipei ~days:0 ~hour:13 ~minute:30 in
                    cycle prepared (Some date)))
      | `After_close ->
          let () = sleep_taipei ~days:0 ~hour:13 ~minute:30 in
          let trades = Shioaji.orders_today ~code:symbol ~today:date in
          let () =
            match trades with
            | [] -> log "date=%s fill-status=none" date
            | _ -> List.iter (log_tw_trade date) trades
          in
          let () = sleep_taipei ~days:1 ~hour:13 ~minute:5 in
          cycle None None
    with error ->
      let () =
        log "date=%s error=%s order=skip" date (error_text error)
      in
      let () = sleep_taipei ~days:1 ~hour:13 ~minute:5 in
      cycle None None
  in
  cycle None None

let lock_daemon ~directory ~market mode =
  let name =
    match market, mode with
    | "us", mode -> mode_name mode
    | "tw", Paper -> "simulation"
    | "tw", Live -> "production"
    | _ -> failwith "live trading supports us and tw only"
  in
  Data.mkdir_p directory;
  let path = Filename.concat directory ("live-" ^ market ^ "-" ^ name ^ ".lock") in
  let fd = Unix.openfile path [Unix.O_CREAT; Unix.O_RDWR; Unix.O_CLOEXEC] 0o600 in
  match Unix.lockf fd Unix.F_TLOCK 0 with
  | () -> fd
  | exception Unix.Unix_error ((Unix.EACCES | Unix.EAGAIN), _, _) ->
      Unix.close fd;
      failwith ("another bt live daemon holds " ^ path)
  | exception error ->
      Unix.close fd;
      raise error

let run ?equity mode ~strat_path ~data_dir =
  let ast = Dsl.parse_file strat_path in
  let rebalance_choice = Dsl.rebalance_of ~filename:strat_path ast in
  let directory =
    match Sys.getenv_opt "HOME" with
    | Some home when home <> "" -> Filename.concat home ".bt"
    | _ -> failwith "HOME must be set to run bt live"
  in
  let stocks = Dsl.stocks_of ~filename:strat_path ast in
  let market = strategy_market stocks in
  let symbols = Array.of_list (List.map (fun (_, _, s) -> s) stocks) in
  match market with
  | "us" ->
      let fd = lock_daemon ~directory ~market:"us" mode in
      Fun.protect ~finally:(fun () -> Unix.close fd)
        (fun () -> run_us mode ~symbols ~strat_path ~data_dir ~rebalance_choice)
  | "tw" ->
      let () = if Array.length symbols <> 1 then
        failwith "TW live trading needs one stock in this release" in
      let symbol = symbols.(0) in
      let fd = lock_daemon ~directory ~market:"tw" mode in
      Fun.protect ~finally:(fun () -> Unix.close fd)
        (fun () -> run_tw mode ~equity ~symbol ~strat_path ~data_dir ~rebalance_choice)
  | _ -> failwith "live trading supports us and tw only"
