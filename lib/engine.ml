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
  refinances : int;
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

type planned_asset = {
  plan_changed : bool;
  plan_final_value : float;
  plan_trade : float;
  plan_from_e : float;
  plan_to_e : float;
  plan_trade_cost : float;
  plan_sell_margin : float;
  plan_sell_cash : float;
  plan_repayment : float;
  plan_interest_settled : float;
  plan_buy_cash : float;
  plan_buy_margin : float;
  plan_down_payment : float;
  plan_refinance_cash : float;
  plan_refinance_margin : float;
  plan_refinance_margin_repayment : float;
  plan_refinance_margin_interest : float;
  plan_refinance_e : float;
  plan_refinance_cash_sell_cost : float;
  plan_refinance_cash_buy_cost : float;
  plan_refinance_margin_sell_cost : float;
  plan_refinance_margin_buy_cost : float;
}

type fill_plan = {
  planned_assets : planned_asset array;
  planned_total_cost : float;
  planned_refinances : bool;
  planned_funding_clamp : bool;
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
  let sum values = Array.fold_left ( +. ) 0. values in
  let cash = ref 1. in
  let cash_values = Array.make asset_count 0. in
  let margin_values = Array.make asset_count 0. in
  let loans = Array.make asset_count 0. in
  let interests = Array.make asset_count 0. in
  let debt = ref 0. in
  let prev_eff = Array.make asset_count 0. in
  let pending_liquidation = ref false in
  let bankrupt = ref false in
  let min_maintenance = ref None in
  let margin_call_dates = ref [] in
  let refinances = ref 0 in
  let clamps = ref 0 in
  let entry_dates = Array.make asset_count "" in
  let buy_value = Array.make asset_count 0. in
  let buy_exposure = Array.make asset_count 0. in
  let sell_value = Array.make asset_count 0. in
  let sell_exposure = Array.make asset_count 0. in
  let fills = ref [] in
  let trips = ref [] in
  let equity_curve = ref [] in
  let total_value index =
    cash_values.(index) +. margin_values.(index)
  in
  let total_assets () =
    let total = ref 0. in
    for index = 0 to asset_count - 1 do
      total := !total +. total_value index
    done;
    !total
  in
  let total_liabilities () = sum loans +. sum interests +. !debt in
  let has_inventory () =
    Array.exists (fun value -> value > 0.) cash_values
    || Array.exists (fun value -> value > 0.) margin_values
  in
  let equity () =
    !cash +. total_assets () -. total_liabilities ()
  in
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
  let absolute_sell_cost index value =
    let costs = costs.(index) in
    let commission = value *. costs.fee_bps /. 10000. in
    let commission =
      match capital with
      | Some cap when costs.min_fee > 0. ->
          Float.max commission (costs.min_fee /. cap)
      | _ -> commission
    in
    commission
    +. value *. (costs.tax_bps +. costs.slip_bps) /. 10000.
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
  let settle_asset_liabilities index =
    let total = loans.(index) +. interests.(index) in
    if !cash > 0. && total > 0. then begin
      let payment = Float.min !cash total in
      let remaining = 1. -. payment /. total in
      cash := !cash -. payment;
      loans.(index) <- loans.(index) *. remaining;
      interests.(index) <- interests.(index) *. remaining
    end
  in
  let settle_all_liabilities () =
    let total = total_liabilities () in
    if !cash > 0. && total > 0. then begin
      let payment = Float.min !cash total in
      let remaining = 1. -. payment /. total in
      cash := !cash -. payment;
      Array.iteri
        (fun index loan -> loans.(index) <- loan *. remaining)
        loans;
      Array.iteri
        (fun index interest -> interests.(index) <- interest *. remaining)
        interests;
      debt := !debt *. remaining
    end
  in
  let sell_inventory ?(settle = true) index ~margin_only ~date ~price =
    let total_before = total_value index in
    let amount =
      if margin_only then margin_values.(index) else total_before
    in
    if amount > 0. then begin
      let equity_now = equity () in
      let open_exposure =
        buy_exposure.(index) -. sell_exposure.(index)
      in
      let sold_e =
        if equity_now > 0. then amount /. equity_now
        else if total_before > 0. && open_exposure > 0. then
          open_exposure *. amount /. total_before
        else 1.
      in
      let from_e =
        if equity_now > 0. then total_before /. equity_now
        else if open_exposure > 0. then open_exposure
        else sold_e
      in
      let to_e = Float.max 0. (from_e -. sold_e) in
      sell_value.(index) <-
        sell_value.(index) +. sold_e *. price;
      sell_exposure.(index) <-
        sell_exposure.(index) +. sold_e;
      let cost_fraction =
        if equity_now > 0. then
          Some (charge index ~equity_before:equity_now ~delta:(-. sold_e))
        else None
      in
      let cost_value =
        match cost_fraction with
        | Some fraction -> fraction *. equity_now
        | None -> absolute_sell_cost index amount
      in
      let cash_only =
        not margin_only
        && sum margin_values = 0.
        && total_liabilities () = 0.
      in
      if cash_only && equity_now > 0. then begin
        let fraction =
          match cost_fraction with
          | Some value -> value
          | None -> assert false
        in
        let equity_after = equity_now *. (1. -. fraction) in
        cash_values.(index) <- 0.;
        let cash_after = equity_after -. total_assets () in
        if cash_after < 0. then begin
          debt := !debt -. cash_after;
          cash := 0.
        end
        else cash := cash_after
      end
      else begin
        if margin_only then
          margin_values.(index) <- 0.
        else begin
          cash_values.(index) <- 0.;
          margin_values.(index) <- 0.
        end;
        cash := !cash +. amount -. cost_value;
        if !cash < 0. then begin
          debt := !debt -. !cash;
          cash := 0.
        end;
        if settle then settle_asset_liabilities index
      end;
      record_fill index ~date ~price ~from_e ~to_e;
      if total_value index = 0. then close_trip index ~date
    end
  in
  let track_maintenance () =
    let total_loan = sum loans in
    if total_loan > 0. then begin
      let ratio = sum margin_values /. total_loan in
      (match !min_maintenance with
       | None -> min_maintenance := Some ratio
       | Some best -> if ratio < best then min_maintenance := Some ratio);
      Some ratio
    end
    else None
  in
  let record_call date =
    match !margin_call_dates with
    | latest :: _ when latest = date -> ()
    | _ -> margin_call_dates := date :: !margin_call_dates
  in
  let bankrupt_all ~date price_at =
    ignore (track_maintenance ());
    record_call date;
    for index = 0 to asset_count - 1 do
      sell_inventory index ~margin_only:false ~date ~price:(price_at index)
    done;
    settle_all_liabilities ();
    bankrupt := true;
    pending_liquidation := false
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
      let factor = now index /. before index in
      if cash_values.(index) <> 0. then
        cash_values.(index) <- cash_values.(index) *. factor;
      if margin_values.(index) <> 0. then
        margin_values.(index) <- margin_values.(index) *. factor
    done
  in
  let accrue_interest ~date ~prev_date =
    let days = day_number date - day_number prev_date in
    for index = 0 to asset_count - 1 do
      if loans.(index) > 0. then
        interests.(index) <-
          interests.(index)
          +. loans.(index) *. margin.financing_rate
             *. float_of_int days /. 365.
    done
  in
  let apply_fills ~date ~eff ~clamped price_at =
    let e0 = equity () in
    if e0 > 0. then begin
      let tolerance = 1e-15 *. abs_float e0 in
      let compute_plan buy_scale e1 =
        let equity_basis = abs_float e1 in
        let changed =
          Array.init asset_count
            (fun index -> eff.(index) <> prev_eff.(index))
        in
        let scaled_buys = Array.make asset_count false in
        let final_values = Array.make asset_count 0. in
        let trades = Array.make asset_count 0. in
        let from_es = Array.make asset_count 0. in
        let to_es = Array.make asset_count 0. in
        let trade_costs = Array.make asset_count 0. in
        let sell_margins = Array.make asset_count 0. in
        let sell_cashes = Array.make asset_count 0. in
        let repayments = Array.make asset_count 0. in
        let interest_settled = Array.make asset_count 0. in
        let post_cash_values = Array.copy cash_values in
        let post_margin_values = Array.copy margin_values in
        let post_loans = Array.copy loans in
        let post_interests = Array.copy interests in
        for index = 0 to asset_count - 1 do
          let current = total_value index in
          let final_value =
            if changed.(index) then eff.(index) *. e1 else current
          in
          let trade = final_value -. current in
          let from_e = current /. e0 in
          final_values.(index) <- final_value;
          trades.(index) <- trade;
          from_es.(index) <- from_e;
          to_es.(index) <-
            if changed.(index) then eff.(index) else from_e;
          if changed.(index) && trade < 0. then begin
            let amount = -. trade in
            let sell_margin =
              Float.min amount margin_values.(index)
            in
            let sell_cash = amount -. sell_margin in
            let fraction =
              if margin_values.(index) > 0. then
                sell_margin /. margin_values.(index)
              else 0.
            in
            let repayment = loans.(index) *. fraction in
            let settled = interests.(index) *. fraction in
            sell_margins.(index) <- sell_margin;
            sell_cashes.(index) <- sell_cash;
            repayments.(index) <- repayment;
            interest_settled.(index) <- settled;
            post_cash_values.(index) <-
              cash_values.(index) -. sell_cash;
            post_margin_values.(index) <-
              margin_values.(index) -. sell_margin;
            post_loans.(index) <- loans.(index) -. repayment;
            post_interests.(index) <- interests.(index) -. settled
          end
        done;
        let has_requested_buy =
          Array.exists (fun trade -> trade > 0.) trades
        in
        if buy_scale < 1. then
          for index = 0 to asset_count - 1 do
            if changed.(index) && trades.(index) > 0. then begin
              let current = total_value index in
              trades.(index) <- trades.(index) *. buy_scale;
              final_values.(index) <- current +. trades.(index);
              to_es.(index) <- final_values.(index) /. equity_basis;
              scaled_buys.(index) <- true
            end
          done;
        let post_assets = sum post_cash_values +. sum post_margin_values in
        let post_liabilities = sum post_loans +. sum post_interests in
        let available = e1 -. post_assets +. post_liabilities in
        let cash_refinance_capacities = Array.make asset_count 0. in
        let margin_refinance_rates = Array.make asset_count 0. in
        let margin_refinance_capacities = Array.make asset_count 0. in
        let refinance_capacity = ref 0. in
        for index = 0 to asset_count - 1 do
          let ratio = margin.ratios.(index) in
          let cash_capacity =
            Float.max 0. (post_cash_values.(index) *. ratio)
          in
          let margin_rate =
            if post_margin_values.(index) > 0. then
              Float.max 0.
                (ratio
                 -. (post_loans.(index) +. post_interests.(index))
                    /. post_margin_values.(index))
            else 0.
          in
          let margin_capacity =
            post_margin_values.(index) *. margin_rate
          in
          cash_refinance_capacities.(index) <- cash_capacity;
          margin_refinance_rates.(index) <- margin_rate;
          margin_refinance_capacities.(index) <- margin_capacity;
          refinance_capacity :=
            !refinance_capacity +. cash_capacity +. margin_capacity
        done;
        let minimum_for index buy =
          let ratio = margin.ratios.(index) in
          if ratio <= 0. then buy else (1. -. ratio) *. buy
        in
        let minimum_total () =
          let total = ref 0. in
          for index = 0 to asset_count - 1 do
            if changed.(index) && trades.(index) > 0. then
              total := !total +. minimum_for index trades.(index)
          done;
          !total
        in
        let requested_minimum = minimum_total () in
        let capacity_clamp =
          requested_minimum > 0.
          && requested_minimum -. available
             > !refinance_capacity +. tolerance
        in
        let funding_clamp =
          capacity_clamp || (buy_scale < 1. && has_requested_buy)
        in
        if capacity_clamp && requested_minimum > 0. then begin
          let fundable =
            Float.max 0. (available +. !refinance_capacity)
          in
          let scale = Float.min 1. (fundable /. requested_minimum) in
          for index = 0 to asset_count - 1 do
            if changed.(index) && trades.(index) > 0. then begin
              let current = total_value index in
              trades.(index) <- trades.(index) *. scale;
              final_values.(index) <- current +. trades.(index);
              to_es.(index) <- final_values.(index) /. equity_basis;
              scaled_buys.(index) <- true
            end
          done
        end;
        let total_cost = ref 0. in
        for index = 0 to asset_count - 1 do
          if changed.(index) && trades.(index) <> 0. then begin
            let current = total_value index in
            let delta_e =
              if scaled_buys.(index) then
                to_es.(index) -. current /. equity_basis
              else eff.(index) -. current /. equity_basis
            in
            let cost =
              charge index ~equity_before:equity_basis ~delta:delta_e
              *. equity_basis
            in
            trade_costs.(index) <- cost;
            total_cost := !total_cost +. cost
          end
        done;
        let minimums = Array.make asset_count 0. in
        let buy_total = ref 0. in
        let minimum_total = ref 0. in
        for index = 0 to asset_count - 1 do
          if changed.(index) && trades.(index) > 0. then begin
            let buy = trades.(index) in
            let minimum = minimum_for index buy in
            buy_total := !buy_total +. buy;
            minimums.(index) <- minimum;
            minimum_total := !minimum_total +. minimum
          end
        done;
        let shortage =
          let value = !minimum_total -. available in
          if value > tolerance then value else 0.
        in
        let shortage = Float.min shortage !refinance_capacity in
        let allocations = Array.make asset_count 0. in
        if !buy_total > 0. && shortage = 0.
           && available >= !buy_total
        then
          for index = 0 to asset_count - 1 do
            if changed.(index) && trades.(index) > 0. then
              allocations.(index) <-
                margin.ratios.(index) *. trades.(index)
          done;
        if !buy_total > 0. && shortage = 0.
           && available < !buy_total
        then begin
          let total_capacity = ref 0. in
          let active = Array.make asset_count false in
          for index = 0 to asset_count - 1 do
            if changed.(index) && trades.(index) > 0. then begin
              let capacity =
                Float.max 0.
                  (margin.ratios.(index) *. trades.(index))
              in
              total_capacity := !total_capacity +. capacity;
              active.(index) <- capacity > tolerance
            end
          done;
          let surplus =
            Float.min !total_capacity
              (Float.max 0. (available -. !minimum_total))
          in
          let remaining = ref surplus in
          for _ = 1 to asset_count do
            if !remaining > tolerance then begin
              let weight = ref 0. in
              for index = 0 to asset_count - 1 do
                if active.(index) then
                  weight := !weight +. trades.(index)
              done;
              if !weight > 0. then begin
                let capped = Array.make asset_count false in
                let any_capped = ref false in
                for index = 0 to asset_count - 1 do
                  if active.(index) then begin
                    let capacity =
                      margin.ratios.(index) *. trades.(index)
                      -. allocations.(index)
                    in
                    let proposed =
                      !remaining *. trades.(index) /. !weight
                    in
                    if proposed >= capacity then begin
                      capped.(index) <- true;
                      any_capped := true
                    end
                  end
                done;
                if !any_capped then
                  for index = 0 to asset_count - 1 do
                    if capped.(index) then begin
                      let capacity =
                        margin.ratios.(index) *. trades.(index)
                        -. allocations.(index)
                      in
                      allocations.(index) <-
                        allocations.(index) +. capacity;
                      remaining := !remaining -. capacity;
                      active.(index) <- false
                    end
                  done
                else begin
                  for index = 0 to asset_count - 1 do
                    if active.(index) then
                      allocations.(index) <-
                        allocations.(index)
                        +. !remaining *. trades.(index) /. !weight
                  done;
                  remaining := 0.
                end
              end
            end
          done
        end;
        let buy_cashes = Array.make asset_count 0. in
        let buy_margins = Array.make asset_count 0. in
        let down_payments = Array.make asset_count 0. in
        for index = 0 to asset_count - 1 do
          if changed.(index) && trades.(index) > 0. then begin
            let buy = trades.(index) in
            let ratio = margin.ratios.(index) in
            let cash_buy =
              if ratio <= 0. then buy
              else Float.min buy (allocations.(index) /. ratio)
            in
            buy_cashes.(index) <- cash_buy;
            buy_margins.(index) <- buy -. cash_buy;
            down_payments.(index) <-
              minimums.(index) +. allocations.(index)
          end
        done;
        let cash_refinance_values = Array.make asset_count 0. in
        let margin_refinance_values = Array.make asset_count 0. in
        let margin_refinance_repayments = Array.make asset_count 0. in
        let margin_refinance_interests = Array.make asset_count 0. in
        let refinance_es = Array.make asset_count 0. in
        let cash_refinance_sell_costs = Array.make asset_count 0. in
        let cash_refinance_buy_costs = Array.make asset_count 0. in
        let margin_refinance_sell_costs = Array.make asset_count 0. in
        let margin_refinance_buy_costs = Array.make asset_count 0. in
        if shortage > 0. && !refinance_capacity > 0. then
          for index = 0 to asset_count - 1 do
            let ratio = margin.ratios.(index) in
            let refinance_e =
              (post_cash_values.(index) +. post_margin_values.(index))
              /. equity_basis
            in
            let cash_capacity = cash_refinance_capacities.(index) in
            if cash_capacity > 0. then begin
              let allocated =
                shortage *. cash_capacity /. !refinance_capacity
              in
              let value =
                Float.min post_cash_values.(index) (allocated /. ratio)
              in
              let sell_cost =
                charge index ~equity_before:equity_basis
                  ~delta:(-. value /. equity_basis)
                *. equity_basis
              in
              let buy_cost =
                charge index ~equity_before:equity_basis
                  ~delta:(value /. equity_basis)
                *. equity_basis
              in
              cash_refinance_values.(index) <- value;
              cash_refinance_sell_costs.(index) <- sell_cost;
              cash_refinance_buy_costs.(index) <- buy_cost;
              refinance_es.(index) <- refinance_e;
              total_cost := !total_cost +. sell_cost +. buy_cost
            end;
            let margin_capacity =
              margin_refinance_capacities.(index)
            in
            if margin_capacity > 0. then begin
              let allocated =
                shortage *. margin_capacity /. !refinance_capacity
              in
              let value =
                Float.min post_margin_values.(index)
                  (allocated /. margin_refinance_rates.(index))
              in
              let fraction = value /. post_margin_values.(index) in
              let repayment = post_loans.(index) *. fraction in
              let settled = post_interests.(index) *. fraction in
              let sell_cost =
                charge index ~equity_before:equity_basis
                  ~delta:(-. value /. equity_basis)
                *. equity_basis
              in
              let buy_cost =
                charge index ~equity_before:equity_basis
                  ~delta:(value /. equity_basis)
                *. equity_basis
              in
              margin_refinance_values.(index) <- value;
              margin_refinance_repayments.(index) <- repayment;
              margin_refinance_interests.(index) <- settled;
              margin_refinance_sell_costs.(index) <- sell_cost;
              margin_refinance_buy_costs.(index) <- buy_cost;
              refinance_es.(index) <- refinance_e;
              total_cost := !total_cost +. sell_cost +. buy_cost
            end
          done;
        { planned_assets =
            Array.init asset_count
              (fun index ->
                { plan_changed = changed.(index);
                  plan_final_value = final_values.(index);
                  plan_trade = trades.(index);
                  plan_from_e = from_es.(index);
                  plan_to_e = to_es.(index);
                  plan_trade_cost = trade_costs.(index);
                  plan_sell_margin = sell_margins.(index);
                  plan_sell_cash = sell_cashes.(index);
                  plan_repayment = repayments.(index);
                  plan_interest_settled = interest_settled.(index);
                  plan_buy_cash = buy_cashes.(index);
                  plan_buy_margin = buy_margins.(index);
                  plan_down_payment = down_payments.(index);
                  plan_refinance_cash =
                    cash_refinance_values.(index);
                  plan_refinance_margin =
                    margin_refinance_values.(index);
                  plan_refinance_margin_repayment =
                    margin_refinance_repayments.(index);
                  plan_refinance_margin_interest =
                    margin_refinance_interests.(index);
                  plan_refinance_e = refinance_es.(index);
                  plan_refinance_cash_sell_cost =
                    cash_refinance_sell_costs.(index);
                  plan_refinance_cash_buy_cost =
                    cash_refinance_buy_costs.(index);
                  plan_refinance_margin_sell_cost =
                    margin_refinance_sell_costs.(index);
                  plan_refinance_margin_buy_cost =
                    margin_refinance_buy_costs.(index) });
          planned_total_cost = !total_cost;
          planned_refinances = shortage > 0.;
          planned_funding_clamp = funding_clamp }
      in
      let projected_cash plan =
        let projected = ref !cash in
        Array.iter
          (fun item ->
            if item.plan_changed && item.plan_trade < 0. then
              projected :=
                !projected -. item.plan_trade -. item.plan_repayment
                -. item.plan_interest_settled -. item.plan_trade_cost)
          plan.planned_assets;
        projected := Float.max 0. !projected;
        Array.iteri
          (fun index item ->
            projected :=
              !projected
              +. margin.ratios.(index) *. item.plan_refinance_cash
              -. item.plan_refinance_cash_sell_cost
              -. item.plan_refinance_cash_buy_cost
              +. margin.ratios.(index) *. item.plan_refinance_margin
              -. item.plan_refinance_margin_repayment
              -. item.plan_refinance_margin_interest
              -. item.plan_refinance_margin_sell_cost
              -. item.plan_refinance_margin_buy_cost;
            if item.plan_changed && item.plan_trade > 0. then
              projected :=
                !projected -. item.plan_down_payment
                -. item.plan_trade_cost)
          plan.planned_assets;
        !projected
      in
      let solve buy_scale =
        let e1 = ref e0 in
        let converged = ref false in
        let iteration = ref 0 in
        while not !converged && !iteration < 20 do
          incr iteration;
          let previous = !e1 in
          let plan = compute_plan buy_scale previous in
          let next = e0 -. plan.planned_total_cost in
          if next <= 0. then converged := true
          else begin
            e1 := next;
            if abs_float (!e1 -. previous) <= tolerance then
              converged := true
          end
        done;
        compute_plan buy_scale !e1
      in
      let requested_plan = solve 1. in
      let plan =
        if projected_cash requested_plan >= -. tolerance then requested_plan
        else begin
          let low = ref 0. in
          let high = ref 1. in
          let best = ref (solve 0.) in
          for _ = 1 to 60 do
            let scale = (!low +. !high) /. 2. in
            let candidate = solve scale in
            if projected_cash candidate >= -. tolerance then begin
              low := scale;
              best := candidate
            end
            else high := scale
          done;
          !best
        end
      in
      if clamped || plan.planned_funding_clamp then incr clamps;
      for index = 0 to asset_count - 1 do
        let item = plan.planned_assets.(index) in
        if item.plan_changed && item.plan_trade < 0. then begin
          let old_total = total_value index in
          if old_total > 0. && item.plan_from_e = 0. then
            start_trip index ~date;
          let exposure =
            abs_float (item.plan_to_e -. item.plan_from_e)
          in
          sell_value.(index) <-
            sell_value.(index) +. exposure *. price_at index;
          sell_exposure.(index) <-
            sell_exposure.(index) +. exposure;
          cash_values.(index) <-
            cash_values.(index) -. item.plan_sell_cash;
          margin_values.(index) <-
            margin_values.(index) -. item.plan_sell_margin;
          if item.plan_final_value = 0. then begin
            cash_values.(index) <- 0.;
            margin_values.(index) <- 0.
          end;
          loans.(index) <- loans.(index) -. item.plan_repayment;
          interests.(index) <-
            interests.(index) -. item.plan_interest_settled;
          cash :=
            !cash -. item.plan_trade -. item.plan_repayment
            -. item.plan_interest_settled -. item.plan_trade_cost;
          record_fill index ~date ~price:(price_at index)
            ~from_e:item.plan_from_e ~to_e:item.plan_to_e;
          if item.plan_final_value = 0. then close_trip index ~date
        end
      done;
      if !cash < 0. then begin
        let deficit = -. !cash in
        let settlement = ref 0. in
        Array.iter
          (fun item ->
            if item.plan_changed && item.plan_trade < 0. then
              settlement :=
                !settlement +. item.plan_repayment
                +. item.plan_interest_settled)
          plan.planned_assets;
        let restored = Float.min deficit !settlement in
        if restored > 0. then begin
          let unpaid_fraction = restored /. !settlement in
          Array.iteri
            (fun index item ->
              if item.plan_changed && item.plan_trade < 0. then begin
                loans.(index) <-
                  loans.(index)
                  +. item.plan_repayment *. unpaid_fraction;
                interests.(index) <-
                  interests.(index)
                  +. item.plan_interest_settled *. unpaid_fraction
              end)
            plan.planned_assets
        end;
        debt := !debt +. deficit -. restored;
        cash := 0.
      end;
      if equity () <= 0. then begin
        if has_inventory () then bankrupt_all ~date price_at
        else begin
          bankrupt := true;
          pending_liquidation := false
        end
      end;
      if not !bankrupt then begin
        if plan.planned_refinances then incr refinances;
        for index = 0 to asset_count - 1 do
          let item = plan.planned_assets.(index) in
          if item.plan_refinance_cash > 0. then begin
            cash_values.(index) <-
              cash_values.(index) -. item.plan_refinance_cash;
            cash :=
              !cash +. item.plan_refinance_cash
              -. item.plan_refinance_cash_sell_cost;
            record_fill index ~date ~price:(price_at index)
              ~from_e:item.plan_refinance_e
              ~to_e:item.plan_refinance_e;
            margin_values.(index) <-
              margin_values.(index) +. item.plan_refinance_cash;
            loans.(index) <-
              loans.(index)
              +. item.plan_refinance_cash *. margin.ratios.(index);
            cash :=
              !cash
              -. (1. -. margin.ratios.(index))
                 *. item.plan_refinance_cash
              -. item.plan_refinance_cash_buy_cost;
            record_fill index ~date ~price:(price_at index)
              ~from_e:item.plan_refinance_e
              ~to_e:item.plan_refinance_e
          end;
          if item.plan_refinance_margin > 0. then begin
            margin_values.(index) <-
              margin_values.(index) -. item.plan_refinance_margin;
            loans.(index) <-
              loans.(index) -. item.plan_refinance_margin_repayment;
            interests.(index) <-
              interests.(index) -. item.plan_refinance_margin_interest;
            cash :=
              !cash +. item.plan_refinance_margin
              -. item.plan_refinance_margin_repayment
              -. item.plan_refinance_margin_interest
              -. item.plan_refinance_margin_sell_cost;
            record_fill index ~date ~price:(price_at index)
              ~from_e:item.plan_refinance_e
              ~to_e:item.plan_refinance_e;
            margin_values.(index) <-
              margin_values.(index) +. item.plan_refinance_margin;
            loans.(index) <-
              loans.(index)
              +. item.plan_refinance_margin *. margin.ratios.(index);
            cash :=
              !cash
              -. (1. -. margin.ratios.(index))
                 *. item.plan_refinance_margin
              -. item.plan_refinance_margin_buy_cost;
            record_fill index ~date ~price:(price_at index)
              ~from_e:item.plan_refinance_e
              ~to_e:item.plan_refinance_e
          end
        done;
        for index = 0 to asset_count - 1 do
          let item = plan.planned_assets.(index) in
          if item.plan_changed && item.plan_trade > 0. then begin
            if item.plan_from_e = 0. then start_trip index ~date;
            let exposure = item.plan_to_e -. item.plan_from_e in
            buy_value.(index) <-
              buy_value.(index) +. exposure *. price_at index;
            buy_exposure.(index) <-
              buy_exposure.(index) +. exposure;
            cash_values.(index) <-
              cash_values.(index) +. item.plan_buy_cash;
            margin_values.(index) <-
              margin_values.(index) +. item.plan_buy_margin;
            loans.(index) <-
              loans.(index)
              +. item.plan_buy_margin *. margin.ratios.(index);
            cash :=
              !cash -. item.plan_down_payment -. item.plan_trade_cost;
            record_fill index ~date ~price:(price_at index)
              ~from_e:item.plan_from_e ~to_e:item.plan_to_e
          end
        done;
        if !cash < 0. then begin
          if -. !cash > tolerance then debt := !debt -. !cash;
          cash := 0.
        end;
        if equity () <= 0. then begin
          if has_inventory () then bankrupt_all ~date price_at
          else begin
            bankrupt := true;
            pending_liquidation := false
          end
        end
      end
    end;
    Array.blit eff 0 prev_eff 0 asset_count
  in
  let guard_solvency ~date price_at =
    if not !bankrupt && equity () <= 0. then
      if has_inventory () then bankrupt_all ~date price_at
      else begin
        bankrupt := true;
        pending_liquidation := false
      end
  in
  let liquidate ~date price_at =
    for index = 0 to asset_count - 1 do
      sell_inventory ~settle:false index ~margin_only:true
        ~date ~price:(price_at index)
    done;
    settle_all_liabilities ();
    if equity () <= 0. then begin
      for index = 0 to asset_count - 1 do
        sell_inventory index ~margin_only:false ~date ~price:(price_at index)
      done;
      settle_all_liabilities ();
      bankrupt := true;
      pending_liquidation := false
    end
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
    if not !bankrupt then
      guard_solvency ~date (fun i -> close_at i t);
    if not !bankrupt then
      (match track_maintenance () with
       | Some ratio when ratio < margin.maintenance_ratio ->
           record_call date;
           pending_liquidation := true
       | _ -> ());
    if !cash < -1e-9 then
      invalid_arg "Engine.run: negative cash invariant";
    equity_curve := (date, equity ()) :: !equity_curve
  done;
  let last = length - 1 in
  let closed_any = ref false in
  for index = 0 to asset_count - 1 do
    if total_value index > 0. then begin
      closed_any := true;
      sell_inventory index ~margin_only:false
        ~date:(snd assets.(index)).(last).Data.date
        ~price:(close_at index last)
    end
  done;
  settle_all_liabilities ();
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
        refinances = !refinances;
        clamps = !clamps } }
