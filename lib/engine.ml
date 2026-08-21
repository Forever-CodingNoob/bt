type strategy = { targets : float array array }

type costs = {
  fee_bps : float;
  tax_bps : float;
  slip_bps : float;
  min_fee : float;
}

type fill = Open_next | Close_same

type fill_event = {
  date : string;
  stock : string;
  price : float;
  from_e : float;
  to_e : float;
}

type margin = {
  financing_rate : float;
  maintenance_ratio : float;
  ratios : float array;
}

type margin_stats = {
  min_maintenance : float option;
  margin_call_dates : string list;
  clamps : int;
}

type trip = {
  entry_date : string;
  exit_date : string;
  net_ret : float;
}

type result = {
  equity_curve : (string * float) list;
  fills : fill_event list;
  trips : trip list;
  margin_stats : margin_stats;
}

let default_costs ~market ~symbol =
  match String.lowercase_ascii market with
  | "us" -> { fee_bps = 0.; tax_bps = 0.; slip_bps = 0.; min_fee = 0. }
  | "tw" ->
      let is_etf =
        String.length symbol >= 2 && symbol.[0] = '0' && symbol.[1] = '0'
      in
      { fee_bps = 3.99;
        tax_bps = if is_etf then 10. else 30.;
        slip_bps = 0.;
        min_fee = 20. }
  | _ -> invalid_arg "Engine.default_costs: market must be tw or us"

(* NaN means flat; short exposure is out of scope *)
let clamp_target value =
  if Float.is_nan value || value < 0. then 0. else value

let day_number date =
  let year = int_of_string (String.sub date 0 4) in
  let month = int_of_string (String.sub date 5 2) in
  let day = int_of_string (String.sub date 8 2) in
  let a = (14 - month) / 12 in
  let y = year + 4800 - a in
  let m = month + (12 * a) - 3 in
  day + (((153 * m) + 2) / 5) + (365 * y) + (y / 4) - (y / 100) + (y / 400)

let run (assets : (string * Data.bar array) array) (strategy : strategy)
    (costs : costs array) ~(margin : margin)
    ~capital:(capital : float option) ~fill =
  let asset_count = Array.length assets in
  if asset_count = 0 then invalid_arg "Engine.run: no assets";
  if Array.length strategy.targets <> asset_count then
    invalid_arg "Engine.run: targets/assets mismatch";
  if Array.length costs <> asset_count then
    invalid_arg "Engine.run: costs/assets mismatch";
  if Array.length margin.ratios <> asset_count then
    invalid_arg "Engine.run: margin ratios/assets mismatch";
  let length = Array.length (snd assets.(0)) in
  Array.iter
    (fun (_, bars) ->
      if Array.length bars <> length then
        invalid_arg "Engine.run: bar length mismatch")
    assets;
  Array.iter
    (fun target ->
      if Array.length target <> length then
        invalid_arg "Engine.run: target length mismatch")
    strategy.targets;
  let cash = ref 1. in
  let values = Array.make asset_count 0. in
  let loans = Array.make asset_count 0. in
  let prev_eff = Array.make asset_count 0. in
  let pending_liquidation = ref false in
  let bankrupt = ref false in
  let min_maintenance = ref None in
  let margin_call_dates = ref [] in
  let clamps = ref 0 in
  let entry_dates = Array.make asset_count "" in
  let buy_value = Array.make asset_count 0. in
  let buy_exposure = Array.make asset_count 0. in
  let sell_value = Array.make asset_count 0. in
  let sell_exposure = Array.make asset_count 0. in
  let fills = ref [] in
  let trips = ref [] in
  let equity_curve = ref [] in
  let charge index ~equity_before ~delta =
    let costs = costs.(index) in
    let amount = abs_float delta in
    let commission = amount *. costs.fee_bps /. 10000. in
    let commission =
      match capital with
      | Some value when costs.min_fee > 0. ->
          Float.max commission (costs.min_fee /. (equity_before *. value))
      | _ -> commission
    in
    let non_commission_bps =
      if delta > 0. then costs.slip_bps else costs.tax_bps +. costs.slip_bps
    in
    commission +. amount *. non_commission_bps /. 10000.
  in
  let equity () =
    !cash +. Array.fold_left ( +. ) 0. values
  in
  let record_fill index ~date ~price ~from_e ~to_e =
    fills :=
      { date; stock = fst assets.(index); price;
        from_e; to_e } :: !fills
  in
  let start_trip index ~date =
    entry_dates.(index) <- date;
    buy_value.(index) <- 0.;
    buy_exposure.(index) <- 0.;
    sell_value.(index) <- 0.;
    sell_exposure.(index) <- 0.
  in
  let close_trip index ~date =
    let entry_price = buy_value.(index) /. buy_exposure.(index) in
    let exit_price = sell_value.(index) /. sell_exposure.(index) in
    trips :=
      { entry_date = entry_dates.(index); exit_date = date;
        net_ret = exit_price /. entry_price -. 1. } :: !trips
  in
  let sell_out index ~date ~price =
    loans.(index) <- 0.;
    if values.(index) > 0. then begin
      let equity_now = equity () in
      let weight =
        if equity_now > 0. then values.(index) /. equity_now
        else buy_exposure.(index) -. sell_exposure.(index)
      in
      let weight = if weight <= 0. then 1. else weight in
      sell_value.(index) <- sell_value.(index) +. weight *. price;
      sell_exposure.(index) <- sell_exposure.(index) +. weight;
      if equity_now > 0. then begin
        let fraction =
          charge index ~equity_before:equity_now ~delta:(-. weight)
        in
        let equity_after = equity_now *. (1. -. fraction) in
        values.(index) <- 0.;
        cash := equity_after -. Array.fold_left ( +. ) 0. values
      end
      else begin
        let asset_costs = costs.(index) in
        let commission =
          values.(index) *. asset_costs.fee_bps /. 10000.
        in
        let commission =
          match capital with
          | Some cap when asset_costs.min_fee > 0. ->
              Float.max commission (asset_costs.min_fee /. cap)
          | _ -> commission
        in
        let cost_value =
          commission
          +. values.(index)
             *. (asset_costs.tax_bps +. asset_costs.slip_bps) /. 10000.
        in
        cash := !cash +. values.(index) -. cost_value;
        values.(index) <- 0.
      end;
      fills :=
        { date; stock = fst assets.(index); price;
          from_e = weight; to_e = 0. } :: !fills;
      let entry_price = buy_value.(index) /. buy_exposure.(index) in
      let exit_price = sell_value.(index) /. sell_exposure.(index) in
      trips :=
        { entry_date = entry_dates.(index); exit_date = date;
          net_ret = exit_price /. entry_price -. 1. } :: !trips
    end
  in
  let effective t =
    let raw =
      Array.init asset_count
        (fun index -> clamp_target strategy.targets.(index).(t))
    in
    let need = ref 0. in
    Array.iteri
      (fun index value ->
        need := !need +. (value *. (1. -. margin.ratios.(index))))
      raw;
    (* ponytail: E1-based sizing absorbs costs before allocation, so
       sequential fills cannot overshoot; this comment is historical *)
    let scale = if !need > 1. then 1. /. !need else 1. in
    (Array.map (fun value -> value *. scale) raw, scale < 1.)
  in
  let differs eff =
    let changed = ref false in
    Array.iteri
      (fun index value ->
        if value <> prev_eff.(index) then changed := true)
      eff;
    !changed
  in
  let close_at index t = (snd assets.(index)).(t).Data.c in
  let open_at index t = (snd assets.(index)).(t).Data.o in
  let scale_values now before =
    for index = 0 to asset_count - 1 do
      if values.(index) <> 0. then
        values.(index) <-
          values.(index) *. (now index /. before index)
    done
  in
  let accrue_interest ~date ~prev_date =
    let total_loan = Array.fold_left ( +. ) 0. loans in
    if total_loan > 0. then begin
      let days = day_number date - day_number prev_date in
      cash :=
        !cash
        -. (total_loan *. margin.financing_rate *. float_of_int days /. 365.)
    end
  in
  let apply_fills ~date ~eff ~clamped price_at =
    if clamped then incr clamps;
    let e0 = equity () in
    if e0 <= 0. then () else begin
      (* E1 iterative solve *)
      let e1 = ref e0 in
      for _ = 1 to 5 do
        let total_cost = ref 0. in
        for index = 0 to asset_count - 1 do
          if eff.(index) <> prev_eff.(index) then begin
            let final_v = eff.(index) *. !e1 in
            let trade = final_v -. values.(index) in
            if trade <> 0. then begin
              let equity_basis = abs_float !e1 in
              let from_e = values.(index) /. equity_basis in
              let delta = eff.(index) -. from_e in
              total_cost :=
                !total_cost
                +. (charge index ~equity_before:equity_basis ~delta)
                   *. equity_basis
            end
          end
        done;
        e1 := e0 -. !total_cost
      done;
      let e1 = !e1 in
      let equity_basis = abs_float e1 in
      (* build the frozen plan *)
      let plan =
        Array.init asset_count (fun index ->
          let changed = eff.(index) <> prev_eff.(index) in
          let final_v =
            if changed then eff.(index) *. e1 else values.(index)
          in
          let trade = final_v -. values.(index) in
          let from_e = values.(index) /. e0 in
          let to_e = if changed then eff.(index) *. e1 /. e0 else from_e in
          let cost =
            if not changed || trade = 0. then 0.
            else begin
              let delta_e =
                eff.(index) -. values.(index) /. equity_basis
              in
              (charge index ~equity_before:equity_basis ~delta:delta_e)
              *. equity_basis
            end
          in
          (changed, final_v, trade, from_e, to_e, cost))
      in
      (* sell pass *)
      for index = 0 to asset_count - 1 do
        let changed, final_v, trade, from_e, to_e, cost = plan.(index) in
        if changed && final_v = 0. then loans.(index) <- 0.;
        if changed && trade < 0. then begin
          let old_v = values.(index) in
          if old_v > 0. && from_e = 0. then start_trip index ~date;
          sell_value.(index) <-
            sell_value.(index) +. abs_float (to_e -. from_e) *. (price_at index);
          sell_exposure.(index) <-
            sell_exposure.(index) +. abs_float (to_e -. from_e);
          values.(index) <- final_v;
          if final_v = 0. then loans.(index) <- 0.
          else if old_v > 0. then
            loans.(index) <- loans.(index) *. final_v /. old_v;
          cash := !cash +. (old_v -. final_v) -. cost;
          record_fill index ~date ~price:(price_at index) ~from_e ~to_e;
          if final_v = 0. then close_trip index ~date
        end
      done;
      (* solvency check after sells *)
      if equity () <= 0. && Array.exists (fun v -> v > 0.) values then begin
        let total_loan = Array.fold_left ( +. ) 0. loans in
        if total_loan > 0. then begin
          let ratio = Array.fold_left ( +. ) 0. values /. total_loan in
          (match !min_maintenance with
           | None -> min_maintenance := Some ratio
           | Some best -> if ratio < best then min_maintenance := Some ratio)
        end;
        margin_call_dates := date :: !margin_call_dates;
        for index = 0 to asset_count - 1 do
          sell_out index ~date ~price:(price_at index)
        done;
        bankrupt := true
      end;
      if not !bankrupt then begin
        (* buy pass with loan allocation *)
        let buying = Array.make asset_count false in
        for index = 0 to asset_count - 1 do
          let changed, _, trade, _, _, _ = plan.(index) in
          if changed && trade > 0. then buying.(index) <- true
        done;
        let final_total_value =
          Array.fold_left
            (fun total (_, final_v, _, _, _, _) -> total +. final_v)
            0. plan
        in
        let needed_total_loan = Float.max 0. (final_total_value -. e1) in
        let existing_total_loan = Array.fold_left ( +. ) 0. loans in
        let loan_delta_total = Float.max 0. (needed_total_loan -. existing_total_loan) in
        let total_capacity = ref 0. in
        for index = 0 to asset_count - 1 do
          if buying.(index) then begin
            let _, _, trade, _, _, _ = plan.(index) in
            total_capacity := !total_capacity +. trade *. margin.ratios.(index)
          end
        done;
        for index = 0 to asset_count - 1 do
          if buying.(index) then begin
            let _, final_v, trade, from_e, to_e, cost = plan.(index) in
            if from_e = 0. then start_trip index ~date;
            buy_value.(index) <-
              buy_value.(index) +. (to_e -. from_e) *. (price_at index);
            buy_exposure.(index) <-
              buy_exposure.(index) +. (to_e -. from_e);
            let loan_delta =
              if !total_capacity > 0. && loan_delta_total > 0. then
                loan_delta_total *. (trade *. margin.ratios.(index)) /. !total_capacity
              else 0.
            in
            loans.(index) <- loans.(index) +. loan_delta;
            values.(index) <- final_v;
            cash := !cash -. trade -. cost;
            record_fill index ~date ~price:(price_at index) ~from_e ~to_e
          end
        done
      end
    end;
    Array.blit eff 0 prev_eff 0 asset_count;
    if equity () <= 0.
       && not (Array.exists (fun v -> v > 0.) values)
    then bankrupt := true
  in
  let guard_solvency ~date price_at =
    if not !bankrupt
       && equity () <= 0.
       && Array.exists (fun value -> value > 0.) values
    then begin
      let total_loan = Array.fold_left ( +. ) 0. loans in
      if total_loan > 0. then begin
        let ratio =
          Array.fold_left ( +. ) 0. values /. total_loan
        in
        (match !min_maintenance with
         | None -> min_maintenance := Some ratio
         | Some best -> if ratio < best then min_maintenance := Some ratio)
      end;
      margin_call_dates := date :: !margin_call_dates;
      for index = 0 to asset_count - 1 do
        sell_out index ~date ~price:(price_at index)
      done;
      bankrupt := true;
      pending_liquidation := false
    end
  in
  let liquidate ~date price_at =
    for index = 0 to asset_count - 1 do
      sell_out index ~date ~price:(price_at index)
    done;
    if equity () <= 0. then bankrupt := true
  in
  for t = 0 to length - 1 do
    let date = (snd assets.(0)).(t).Data.date in
    if not !bankrupt then begin
      if t > 0 then
        accrue_interest ~date
          ~prev_date:((snd assets.(0)).(t - 1).Data.date);
      (match fill with
       | Close_same ->
           if t > 0 && !pending_liquidation then begin
             scale_values (fun i -> open_at i t)
               (fun i -> close_at i (t - 1));
             liquidate ~date (fun i -> open_at i t);
             pending_liquidation := false;
             scale_values (fun i -> close_at i t) (fun i -> open_at i t)
           end
           else if t > 0 then
             scale_values (fun i -> close_at i t)
               (fun i -> close_at i (t - 1));
           guard_solvency ~date (fun i -> close_at i t);
           if not !bankrupt then begin
             let eff, clamped = effective t in
             if differs eff then
               apply_fills ~date ~eff ~clamped (fun i -> close_at i t)
           end
       | Open_next ->
           if t > 0 then begin
             let eff, clamped = effective (t - 1) in
             let scheduled = differs eff in
             scale_values (fun i -> open_at i t)
               (fun i -> close_at i (t - 1));
             if !pending_liquidation then begin
               liquidate ~date (fun i -> open_at i t);
               pending_liquidation := false
             end;
             guard_solvency ~date (fun i -> open_at i t);
             if not !bankrupt && scheduled then
               apply_fills ~date ~eff ~clamped (fun i -> open_at i t);
             scale_values (fun i -> close_at i t) (fun i -> open_at i t)
           end)
    end;
    let total_loan = Array.fold_left ( +. ) 0. loans in
    if not !bankrupt && total_loan > 0. then begin
      let ratio =
        Array.fold_left ( +. ) 0. values /. total_loan
      in
      (match !min_maintenance with
       | None -> min_maintenance := Some ratio
       | Some best -> if ratio < best then min_maintenance := Some ratio);
      if ratio < margin.maintenance_ratio then begin
        margin_call_dates := date :: !margin_call_dates;
        pending_liquidation := true
      end
    end;
    equity_curve := (date, equity ()) :: !equity_curve
  done;
  let last = length - 1 in
  let closed_any = ref false in
  for index = 0 to asset_count - 1 do
    if values.(index) > 0. then begin
      closed_any := true;
      sell_out index ~date:(snd assets.(index)).(last).Data.date
        ~price:(close_at index last)
    end
  done;
  if !closed_any then
    (match !equity_curve with
     | _ :: rest ->
         equity_curve :=
           ((snd assets.(0)).(last).Data.date, equity ()) :: rest
     | [] -> ());
  { equity_curve = List.rev !equity_curve;
    fills = List.rev !fills;
    trips = List.rev !trips;
    margin_stats =
      { min_maintenance = !min_maintenance;
        margin_call_dates = List.rev !margin_call_dates;
        clamps = !clamps } }
