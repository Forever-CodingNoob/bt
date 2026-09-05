type mode = Alpaca.mode = Paper | Live

type action =
  | Order of {
      side : [`Buy | `Sell];
      qty : int;
      id : string;
    }
  | Skip of string

type decision = {
  fetched_through : string;
  provisional : Data.bar;
  target : float;
  equity : float;
  held : float;
  action : action;
}

let provisional_bar (snapshot : Alpaca.snapshot_t) : Data.bar =
  { date = snapshot.day_date;
    o = snapshot.day_open;
    h = snapshot.day_high;
    l = snapshot.day_low;
    c = snapshot.latest;
    v = snapshot.day_volume }

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
  int_of_float (target *. equity /. price)

let order_delta ~desired ~held =
  desired - int_of_float (Float.round held)

let below_threshold ~delta ~price =
  abs_float (float_of_int delta *. price) < 1.

let client_order_id ~symbol ~date =
  Printf.sprintf "bt-%s-%s" symbol date

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
    `Submit_window
  else
    `Post_close

let can_submit_moc ~now ~next_close =
  match next_actions ~now ~next_close with
  | `Decide -> true
  | `Sleep_until _ | `Submit_window | `Post_close -> false

let startup_ok (account : Alpaca.account_t) =
  match account.status, account.trading_blocked with
  | "ACTIVE", false -> Ok ()
  | "ACTIVE", true -> Error "account trading is blocked"
  | status, _ -> Error (Printf.sprintf "account status is %s" status)

let decide mode ~session_date ~strat_path ~data_dir =
  let ast = Dsl.parse_file strat_path in
  match Dsl.stocks_of ~filename:strat_path ast with
  | [alias, "us", symbol] ->
      let snapshot = Alpaca.snapshot symbol in
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
      let desired = desired_shares ~target ~equity ~price:provisional.c in
      let delta = order_delta ~desired ~held in
      let action =
        if below_threshold ~delta ~price:provisional.c then
          Skip "below $1 minimum order value"
        else
          Order
            { side = (if delta > 0 then `Buy else `Sell);
              qty = abs delta;
              id = client_order_id ~symbol ~date:provisional.date }
      in
      { fetched_through; provisional; target; equity; held; action }
  | [_, "tw", _] | [_, _, _] ->
      failwith "live trading supports us only"
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

let timestamp_date timestamp =
  if String.length timestamp < 10 then
    failwith (Printf.sprintf "invalid RFC3339 timestamp: %s" timestamp);
  String.sub timestamp 0 10

let order_description = function
  | Skip reason -> Printf.sprintf "skip:%s" reason
  | Order { side; qty; id } ->
      let side =
        match side with
        | `Buy -> "buy"
        | `Sell -> "sell"
      in
      Printf.sprintf "%s:%d:%s" side qty id

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

let execute_decision mode symbol next_close decision =
  log_decision decision;
  match decision.action with
  | Skip _ -> ()
  | Order { side; qty; id } ->
      let order =
        match Alpaca.order_by_client_id mode id with
        | Some order -> Some order
        | None ->
            let clock = Alpaca.clock mode in
            if clock.is_open
               && can_submit_moc ~now:clock.timestamp ~next_close
            then
              Some
                (Alpaca.submit_moc mode ~symbol ~qty ~side
                   ~client_order_id:id)
            else begin
              log "date=%s error=missed MOC submission cutoff order=skip"
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

let run mode ~strat_path ~data_dir =
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
          | (`Decide | `Submit_window as phase) ->
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
                 | None ->
                     (match phase with
                      | `Submit_window ->
                          log
                            "date=%s error=missed MOC submission cutoff order=skip"
                            date;
                          sleep_until clock.next_open
                      | `Decide ->
                          (match
                             decide mode ~session_date:date ~strat_path ~data_dir
                           with
                           | decision ->
                               (match
                                  execute_decision mode symbol
                                    clock.next_close decision
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
                               sleep_until clock.next_open))
               with
               | () -> ()
               | exception error ->
                   log "date=%s error=%s order=skip" date
                     (Printexc.to_string error);
                   sleep_until clock.next_open);
              cycle ()
  in
  cycle ()
