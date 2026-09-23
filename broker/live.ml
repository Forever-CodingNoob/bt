type mode = Alpaca.mode = Paper | Live

type leg = {
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


type decision = {
  fetched_through : string;
  provisional : Data.bar;
  target : float;
  equity : float;
  held : float;
  action : action;
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

let desired_shares ~target ~equity ~price =
  target *. equity /. price

let order_delta ~desired ~held =
  desired -. held

let below_threshold ~side ~delta ~price =
  match side with
  | `Buy -> abs_float (delta *. price) < 1.
  | `Sell -> false

let client_order_id ~symbol ~date =
  Printf.sprintf "bt-%s-%s" symbol date

let decide_action ~symbol ~date ~target ~equity ~price ~held =
  let delta = order_delta ~desired:(desired_shares ~target ~equity ~price) ~held in
  let side, shares =
    if delta > 0. then (`Buy, delta) else (`Sell, Float.min (-. delta) held)
  in
  let qty = float_of_string (Alpaca.qty_string shares) in
  if qty = 0. || below_threshold ~side ~delta:qty ~price then
    Skip "below $1 minimum order value"
  else
    Order { side; qty; id = client_order_id ~symbol ~date }

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


let unquote value =
  let length = String.length value in
  if length >= 2 && value.[0] = '"' && value.[length - 1] = '"' then
    String.sub value 1 (length - 2)
  else
    value

let exchange_of_symbol ~data_dir symbol =
  let path =
    Filename.concat (Filename.concat data_dir "tw") "stockinfo.csv"
  in
  let input = open_in path in
  Fun.protect
    ~finally:(fun () -> close_in input)
    (fun () ->
      let () =
        match input_line input with
        | _ -> ()
        | exception End_of_file -> failwith "empty TW stockinfo cache"
      in
      let rec read_best best =
        match input_line input with
        | line ->
            let best =
              match String.split_on_char ',' line with
              | [stock_id; kind; date] when unquote stock_id = symbol ->
                  let row = unquote date, unquote kind in
                  (match best with
                   | Some (previous, _) when previous >= fst row -> best
                   | _ -> Some row)
              | _ -> best
            in
            read_best best
        | exception End_of_file -> best
      in
      match read_best None with
      | Some (_, "twse") -> "TSE"
      | Some (_, "tpex") -> "OTC"
      | Some (_, kind) ->
          failwith
            (Printf.sprintf "unsupported TW exchange type %S for %s" kind symbol)
      | None ->
          failwith
            (Printf.sprintf "TW stockinfo has no exchange for %s" symbol))

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


let legs_of_plan ~price (plan : Engine.fill_plan) =
  let () =
    if not (Float.is_finite price) || price <= 0. then
      failwith "TW planning price must be finite and positive"
  in
  let item =
    match plan.planned_assets with
    | [| item |] -> item
    | _ -> failwith "live trading requires exactly one planned asset"
  in
  (* Live.decide plans in absolute TWD, so its value/share capital is 1. *)
  let leg ~odd action cond value =
    let shares =
      int_of_float (Engine.shares_of_value ~capital:1. ~price value)
    in
    let common =
      if shares / 1000 > 0 then
        [{ action; cond; lot = Shioaji.Common; quantity = shares / 1000 }]
      else []
    in
    let remainder = shares mod 1000 in
    if odd && remainder > 0 then
      common @ [{ action; cond; lot = Shioaji.IntradayOdd;
                  quantity = remainder }]
    else common
  in
  leg ~odd:false "Sell" "MarginTrading" item.plan_sell_margin
  @ leg ~odd:true "Sell" "Cash" item.plan_sell_cash
  @ leg ~odd:false "Sell" "Cash" item.plan_refinance_cash
  @ leg ~odd:false "Buy" "MarginTrading" item.plan_refinance_cash
  @ leg ~odd:false "Sell" "MarginTrading" item.plan_refinance_margin
  @ leg ~odd:false "Buy" "MarginTrading" item.plan_refinance_margin
  @ leg ~odd:true "Buy" "Cash" item.plan_buy_cash
  @ leg ~odd:false "Buy" "MarginTrading" item.plan_buy_margin

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
  let submit_at = close - (10 * 60) in
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


let maturity_rollover_legs ~session_date ~symbol details =
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
        [{ action = "Sell"; cond = "MarginTrading"; lot = Shioaji.Common;
           quantity = detail.lots };
         { action = "Buy"; cond = "MarginTrading"; lot = Shioaji.Common;
           quantity = detail.lots }]
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


let position_totals symbol price positions =
  let () =
    if not (Float.is_finite price) || price <= 0. then
      failwith "TW planning price must be finite and positive"
  in
  List.fold_left
    (fun (cash_shares, margin_shares, loans, interests)
         (position : Shioaji.position) ->
      let active =
        position.shares <> 0 || position.loan_amount <> 0.
        || position.interest <> 0.
      in
      let () =
        if position.shares < 0
           || not (Float.is_finite position.loan_amount)
           || position.loan_amount < 0.
           || not (Float.is_finite position.interest)
           || position.interest < 0.
        then
          failwith "TW position contains invalid account values"
      in
      if position.code <> symbol then
        if active then
          failwith
            (Printf.sprintf "TW account holds unsupported symbol %s"
               position.code)
        else
          cash_shares, margin_shares, loans, interests
      else
        match position.cond with
        | "Cash" ->
            cash_shares +. float_of_int position.shares,
            margin_shares, loans, interests
        | "MarginTrading" ->
            cash_shares,
            margin_shares +. float_of_int position.shares,
            loans +. position.loan_amount,
            interests +. position.interest
        | cond when active ->
            failwith
              (Printf.sprintf "TW account holds unsupported inventory %s" cond)
        | _ -> cash_shares, margin_shares, loans, interests)
    (0., 0., 0., 0.) positions
  |> fun (cash_shares, margin_shares, loans, interests) ->
     cash_shares, margin_shares, cash_shares *. price,
     margin_shares *. price, loans, interests

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

let decide ?provisional_close ?previous_session ?equity ?tw_balance
    ?tw_settlements ?tw_positions ?tw_position_details ?tw_snapshot mode
    ~session_date ~strat_path ~data_dir =
  let ast = Dsl.parse_file strat_path in
  match Dsl.stocks_of ~filename:strat_path ast with
  | [alias, "us", symbol] ->
      let snapshot =
        match provisional_close with
        | None -> Alpaca.snapshot symbol
        | Some price ->
            let cache_path =
              Filename.concat
                (Filename.concat (Filename.concat data_dir "us") symbol)
                (symbol ^ ".csv")
            in
            let prev_day_date =
              match Data.last_cached_date cache_path with
              | Some date -> date
              | None ->
                  failwith
                    (Printf.sprintf
                       "%s has no cached rows; run bt fetch us/%s"
                       cache_path symbol)
            in
            override_snapshot ~session_date ~prev_day_date ~price
      in
      let () =
        Data.fetch ~market:"us" ~symbol ~from_:None
          ~to_:snapshot.prev_day_date ~data_dir
      in
      let asset =
        Data.load_asset ~market:"us" ~symbol ~from_:None
          ~to_:(Some snapshot.prev_day_date) ~data_dir
      in
      let last = Array.length asset.signal - 1 in
      let fetched_through = asset.signal.(last).date in
      let () =
        if not
            (cache_is_fresh ~last_cached:fetched_through
               ~prev_trading_day:snapshot.prev_day_date)
        then
          failwith
            (Printf.sprintf "stale cache: fetched through %s, expected %s"
               fetched_through snapshot.prev_day_date)
      in
      let provisional = provisional_bar snapshot in
      let () =
        match snapshot_session ~session_date
                ~provisional_date:provisional.date with
        | `Proceed -> ()
        | `Skip reason -> failwith reason
      in
      let bars = Array.append asset.signal [| provisional |] in
      let strategy =
        Dsl.compile_ast ast ~params:[] ~assets:[alias, bars]
      in
      let target =
        match strategy.Engine.targets with
        | [| targets |] when Array.length targets > 0 ->
            let raw = targets.(Array.length targets - 1) in
            let profile = Engine.profile_of_market "us" in
            let effective, _ =
              Engine.effective_targets
                ~financing_ratios:[| profile.default_financing_ratio |]
                [| raw |]
            in
            effective.(0)
        | _ -> failwith "live trading requires exactly one stock target"
      in
      let account = Alpaca.account mode in
      let equity = account.equity in
      let held = Alpaca.position_qty mode symbol in
      let action =
        decide_action ~symbol ~date:provisional.date ~target ~equity
          ~price:provisional.c ~held
      in
      { fetched_through; provisional; target; equity; held; action }
  | [alias, "tw", symbol] ->
      let () = validate_date "session" session_date in
      let () =
        match mode, equity with
        | Paper, Some value when Float.is_finite value && value > 0. -> ()
        | Paper, Some _ ->
            failwith "simulation equity must be finite and positive"
        | Paper, None -> failwith "simulation mode requires --equity"
        | Live, Some _ -> failwith "--equity is not allowed in production"
        | Live, None -> ()
      in
      let fetch_required = Option.is_none previous_session in
      let previous_session =
        match previous_session with
        | Some date -> date
        | None -> Data.previous_trading_day ~before:session_date
      in
      let () = validate_date "previous session" previous_session in
      let () =
        if previous_session >= session_date then
          failwith
            (Printf.sprintf
               "previous TW trading session %s is not before %s"
               previous_session session_date)
      in
      let snapshot =
        match provisional_close, tw_snapshot with
        | Some price, _ ->
            { Shioaji.datetime = session_date ^ "T13:20:00+08:00";
              open_ = price; high = price; low = price; close = price;
              bid = price; ask = price; total_volume = 0. }
        | None, Some snapshot -> snapshot
        | None, None ->
            let exchange = exchange_of_symbol ~data_dir symbol in
            Shioaji.snapshot ~exchange ~code:symbol
      in
      let () =
        if fetch_required then
          let () =
            Data.fetch ~market:"tw" ~symbol ~from_:None
              ~to_:previous_session ~data_dir
          in
          Data.fetch_tw_adjustments ~symbol ~to_:session_date ~data_dir
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
            (Printf.sprintf
               "stale TW cache: fetched through %s, expected %s"
               fetched_through previous_session)
      in
      let provisional = tw_provisional_bar snapshot in
      let () =
        match snapshot_session ~session_date
                ~provisional_date:provisional.date with
        | `Proceed -> ()
        | `Skip reason -> failwith reason
      in
      let bars = Array.append asset.signal [| provisional |] in
      let strategy = Dsl.compile_ast ast ~params:[] ~assets:[alias, bars] in
      let financing_ratio =
        Data.financing_ratio ~market:"tw" ~data_dir ~symbol
      in
      let effective_target raw =
        let effective, _ =
          Engine.effective_targets
            ~financing_ratios:[| financing_ratio |] [| raw |]
        in
        effective.(0)
      in
      let target, previous_target =
        match strategy.Engine.targets with
        | [| targets |] when Array.length targets > 0 ->
            let last = Array.length targets - 1 in
            let target = effective_target targets.(last) in
            let previous =
              if last = 0 then 0. else effective_target targets.(last - 1)
            in
            target, previous
        | _ -> failwith "live trading requires exactly one stock target"
      in
      let positions =
        match tw_positions with
        | Some positions -> positions
        | None -> Shioaji.positions ()
      in
      let position_details =
        match tw_position_details, tw_positions with
        | Some details, _ -> details
        | None, Some _ -> []
        | None, None -> fetch_position_details symbol positions
      in
      let cash_shares, margin_shares, cash_value, margin_value,
          loans, interests =
        position_totals symbol provisional.c positions
      in
      let held = cash_shares +. margin_shares in
      let cash, equity =
        match mode, equity with
        | Paper, Some equity ->
            equity -. cash_value -. margin_value +. loans +. interests,
            equity
        | Live, None ->
            let balance =
              match tw_balance with
              | Some balance -> balance
              | None -> Shioaji.balance ()
            in
            let settlements =
              match tw_settlements with
              | Some settlements -> settlements
              | None -> Shioaji.settlements ()
            in
            let cash = tw_production_cash ~balance ~settlements in
            cash, equity_of ~cash ~positions
        | Paper, None | Live, Some _ -> assert false
      in
      let () =
        if not (Float.is_finite cash) then
          failwith "TW inferred cash balance is not finite"
      in
      let costs = tw_live_debit_costs symbol in
      let plan =
        Engine.plan_fills ~costs:[| costs |] ~capital:1.
          ~profile:(Engine.profile_of_market "tw")
          ~financing_ratios:[| financing_ratio |]
          ~state:
            { Engine.equity; cash; cash_values = [| cash_value |];
              margin_values = [| margin_value |]; loans = [| loans |];
              interests = [| interests |]; tail_interests = [| 0. |];
              debt = 0.; receivables = 0.;
              previous_targets = [| previous_target |] }
          ~prices:[| provisional.c |] ~targets:[| target |] ~force:false
      in
      let action =
        Orders
          (maturity_rollover_legs ~session_date ~symbol position_details
           @ legs_of_plan ~price:provisional.c plan)
      in
      { fetched_through; provisional; target; equity; held; action }
  | [_, _, _] -> failwith "live trading supports us and tw only"
  | _ -> failwith "live trading requires exactly one stock"

let printable_ascii value =
  String.map
    (fun character ->
      if character >= ' ' && character <= '~' then character else '?')
    value

let log format =
  Printf.ksprintf
    (fun line ->
      print_endline (printable_ascii line);
      flush stdout)
    format

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

let log_decision (decision : decision) =
  log
    "date=%s fetched-through=%s provisional-close=%.10g target=%.10g \
     equity=%.10g held=%.10g order=%s fill=pending"
    decision.provisional.date decision.fetched_through decision.provisional.c
    decision.target decision.equity decision.held
    (order_description decision.action)

let log_fill date client_order_id = function
  | None ->
      log "date=%s client-order-id=%s fill-status=missing fill-price=- filled-qty=0"
        date client_order_id
  | Some (order : Alpaca.order_t) ->
      let price =
        match order.filled_avg_price with
        | Some value -> Printf.sprintf "%.10g" value
        | None -> "-"
      in
      log
        "date=%s client-order-id=%s fill-status=%s fill-price=%s \
         filled-qty=%.10g"
        date client_order_id order.status price order.filled_qty

let terminal_order_status = function
  | "filled" | "canceled" | "expired" | "rejected" | "stopped" -> true
  | _ -> false

let rec poll_fill mode date client_order_id deadline =
  let order = Alpaca.order_by_client_id mode client_order_id in
  match order with
  | Some order when terminal_order_status order.status ->
      log_fill date client_order_id (Some order)
  | _ when Unix.gettimeofday () >= deadline ->
      log_fill date client_order_id order
  | _ ->
      Unix.sleepf 15.;
      poll_fill mode date client_order_id deadline

let finish_order mode next_close date client_order_id
    (order : Alpaca.order_t) =
  if terminal_order_status order.status then
    log_fill date client_order_id (Some order)
  else begin
    sleep_until next_close;
    poll_fill mode date client_order_id
      (float_of_int (rfc3339_seconds next_close + (5 * 60)))
  end

let execute_decision ?(order_by_client_id = Alpaca.order_by_client_id)
    ?(clock = Alpaca.clock) ?(submit_market = Alpaca.submit_market) mode
    symbol next_close decision =
  log_decision decision;
  match decision.action with
  | Skip _ -> ()
  | Order { side; qty; id } ->
      let order =
        match order_by_client_id mode id with
        | Some order -> Some order
        | None ->
            let clock = clock mode in
            if clock.is_open
               && next_actions ~now:clock.timestamp ~next_close = `Decide
            then
              Some (submit_market mode ~symbol ~qty ~side ~client_order_id:id)
            else begin
              log "date=%s error=submit cutoff passed order=skip"
                decision.provisional.date;
              None
            end
      in
      (match order with
       | None -> ()
       | Some order ->
           (match order.status with
            | "rejected" -> failwith "Alpaca rejected the order"
            | _ ->
                finish_order mode next_close decision.provisional.date id
                  order))
  | Orders _ -> failwith "TW order legs require Shioaji"

let run_us mode ~strat_path ~data_dir =
  let ast = Dsl.parse_file strat_path in
  let symbol =
    match Dsl.stocks_of ~filename:strat_path ast with
    | [_, "us", symbol] -> symbol
    | [_, "tw", _] | [_, _, _] ->
        failwith "live trading supports us only"
    | _ -> failwith "live trading requires exactly one stock"
  in
  let account = Alpaca.account mode in
  let () =
    match startup_ok account with
    | Ok () -> ()
    | Error reason -> failwith reason
  in
  log "startup mode=%s account=%s equity=%.10g" (mode_name mode)
    account.account_number account.equity;
  let rec cycle () =
    match Alpaca.clock mode with
    | exception error ->
        log "date=unknown error=%s order=skip"
          (Printexc.to_string error);
        let rec resume_next_session () =
          Unix.sleepf 60.;
          match Alpaca.clock mode with
          | exception _ -> resume_next_session ()
          | recovered ->
              sleep_until recovered.next_open;
              cycle ()
        in
        resume_next_session ()
    | clock ->
        if not clock.is_open then begin
          sleep_until clock.next_open;
          cycle ()
        end else
          match next_actions ~now:clock.timestamp ~next_close:clock.next_close with
          | `Sleep_until timestamp ->
              sleep_until timestamp;
              cycle ()
          | `Post_close ->
              sleep_until clock.next_open;
              cycle ()
          | (`Decide | `Cutoff_passed as phase) ->
              let date = timestamp_date clock.timestamp in
              let id = client_order_id ~symbol ~date in
              (match
                 let existing_order =
                   Alpaca.order_by_client_id mode id
                 in
                 match existing_order with
                 | Some order ->
                     log "date=%s order=existing:%s fill=pending" date id;
                     finish_order mode clock.next_close date id order;
                     sleep_until clock.next_open
                 | None when phase = `Cutoff_passed ->
                     log "date=%s error=submit cutoff passed order=skip" date;
                     sleep_until clock.next_open
                 | None ->
                     (match
                        decide mode ~session_date:date ~strat_path ~data_dir
                      with
                      | decision ->
                          (match
                             execute_decision mode symbol clock.next_close
                               decision
                           with
                           | () -> sleep_until clock.next_open
                           | exception error ->
                               log "date=%s error=%s order=skip"
                                 decision.provisional.date
                                 (Printexc.to_string error);
                               sleep_until clock.next_open)
                      | exception error ->
                          log "date=%s error=%s order=skip" date
                            (Printexc.to_string error);
                          sleep_until clock.next_open)
               with
               | () -> ()
               | exception error ->
                   log "date=%s error=%s order=skip" date
                     (Printexc.to_string error);
                   sleep_until clock.next_open);
              cycle ()
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
  let snapshot = Shioaji.snapshot ~exchange ~code:symbol in
  let snapshot_date = tw_snapshot_date snapshot in
  let () =
    if snapshot_date <> date then
      failwith
        (Printf.sprintf "snapshot session %s is not trading date %s"
           snapshot_date date)
  in
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
  log
    "date=%s order-id=%s action=%s cond=%s lot=%s fill-status=%s \
     deal-quantity=%d fill-price=%s"
    date trade.order_id trade.action trade.cond (lot_name trade.lot)
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

let execute_tw_legs ?(log_odd = fun message -> log "%s" message)
    ~mode ~bid ~ask ~now ~sleep ~place_order ~orders_today ~exchange ~code
    ~date ~price ~financing_ratio ~costs ~cash ~positions legs =
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
    position_totals code price positions
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
        let dependent =
          match previous with
          | Some ((predecessor : leg), _) ->
              predecessor.action = "Sell"
              && leg.action = "Buy" && leg.cond = "MarginTrading"
              && predecessor.quantity = leg.quantity
              && predecessor.lot = leg.lot
          | None -> false
        in
        let full_predecessor =
          match previous with
          | Some (_, filled) -> filled
          | None -> true
        in
        if dependent && not full_predecessor then
          stop
            (Printf.sprintf "dependent %s %s %d needs complete sell fill"
               leg.action leg.cond leg.quantity) (leg :: rest)
        else if leg.lot = Shioaji.IntradayOdd && mode = Paper then
          let () = log_odd "submitted=skip:odd-lot-unsupported-in-simulation" in
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
            let () = log_odd "submitted=skip:odd-lot-quote-unavailable" in
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
            if dependent && available <> leg.quantity then
              stop
                (Printf.sprintf "dependent %s %s %d is not fully funded"
                   leg.action leg.cond leg.quantity) (leg :: rest)
            else if available = 0 then
              stop
                (Printf.sprintf "insufficient confirmed cash for %s %s %d"
                   leg.action leg.cond leg.quantity) (leg :: rest)
            else if not (open_window ()) then
              stop
                (Printf.sprintf "submission window closed before %s %s %d"
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
                    match
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
                        let () =
                          log_odd "submitted=skip:odd-lot-rejected"
                        in
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
                          log_odd
                            (Printf.sprintf
                               "submitted=intraday-odd-rod-pending quantity=%d"
                               available)
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
let run_tw mode ~equity ~symbol ~strat_path ~data_dir =
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
                    let () =
                      log
                        "date=%s fetched-through=%s provisional-close=- \
                         target=- equity=%.10g cash-shares=- margin-shares=- loan=- \
                         planned-legs=none submitted=skip:existing-orders"
                        date previous_session startup_equity
                    in
                    let () = sleep_taipei ~days:0 ~hour:13 ~minute:30 in
                    cycle prepared (Some date)
                | [] ->
                    let snapshot =
                      Shioaji.snapshot ~exchange ~code:symbol
                    in
                    let positions = Shioaji.positions () in
                    let position_details =
                      fetch_position_details symbol positions
                    in
                    let tw_balance, tw_settlements, production_cash =
                      match mode, equity with
                      | Paper, Some _ -> None, None, None
                      | Live, None ->
                          let balance = Shioaji.balance () in
                          let settlements = Shioaji.settlements () in
                          Some balance, Some settlements,
                          Some (tw_production_cash ~balance ~settlements)
                      | Paper, None | Live, Some _ -> assert false
                    in
                    let decision =
                      decide ~previous_session ?equity ?tw_balance
                        ?tw_settlements ~tw_positions:positions
                        ~tw_position_details:position_details
                        ~tw_snapshot:snapshot mode ~session_date:date
                        ~strat_path ~data_dir
                    in
                    let cash_shares, margin_shares, cash_value, margin_value,
                        loans, interests =
                      position_totals symbol decision.provisional.c positions
                    in
                    let cash =
                      match mode, equity, production_cash with
                      | Paper, Some equity, None ->
                          equity -. cash_value -. margin_value +. loans
                          +. interests
                      | Live, None, Some cash -> cash
                      | _ -> assert false
                    in
                    let outcome, legs =
                      match decision.action with
                      | Orders [] -> "skip:no-order-legs", []
                      | Orders legs ->
                          let execution =
                            execute_tw_legs ~mode ~bid:snapshot.bid
                              ~ask:snapshot.ask ~now:taipei_now
                              ~sleep:Unix.sleepf
                              ~place_order:Shioaji.place_order
                              ~orders_today:Shioaji.orders_today ~exchange
                              ~code:symbol ~date
                              ~price:decision.provisional.c ~financing_ratio
                              ~costs ~cash ~positions legs
                          in
                          let () =
                            List.iter (log_tw_trade date) execution.trades
                          in
                          let outcome =
                            match execution.stop_reason with
                            | None -> "complete"
                            | Some reason ->
                                Printf.sprintf "stop:%s remaining:%s" reason
                                  (tw_legs_description execution.remaining)
                          in
                          outcome, legs
                      | Order _ | Skip _ ->
                          failwith "TW decision returned an Alpaca action"
                    in
                    let () =
                      log
                        "date=%s fetched-through=%s provisional-close=%.10g \
                         target=%.10g equity=%.10g cash-shares=%.10g \
                         margin-shares=%.10g loan=%.10g planned-legs=%s \
                         submitted=%s"
                        date decision.fetched_through decision.provisional.c
                        decision.target decision.equity
                        cash_shares margin_shares loans
                        (tw_legs_description legs) outcome
                    in
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

let run ?equity mode ~strat_path ~data_dir =
  let ast = Dsl.parse_file strat_path in
  match Dsl.stocks_of ~filename:strat_path ast with
  | [_, "us", _] -> run_us mode ~strat_path ~data_dir
  | [_, "tw", symbol] ->
      run_tw mode ~equity ~symbol ~strat_path ~data_dir
  | [_, _, _] -> failwith "live trading supports us and tw only"
  | _ -> failwith "live trading requires exactly one stock"
