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

let desired_shares ~target ~equity ~price =
  int_of_float (target *. equity /. price)

let order_delta ~desired ~held =
  desired - int_of_float (Float.round held)

let below_threshold ~delta ~price =
  abs_float (float_of_int delta *. price) < 1.

let client_order_id ~symbol ~date =
  Printf.sprintf "bt-%s-%s" symbol date

let decide mode ~strat_path ~data_dir =
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
      let bars = Array.append asset.signal [| provisional |] in
      let strategy =
        Dsl.compile_ast ast ~params:[] ~assets:[alias, bars]
      in
      let target =
        match strategy.Engine.targets with
        | [| targets |] when Array.length targets > 0 ->
            targets.(Array.length targets - 1)
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
