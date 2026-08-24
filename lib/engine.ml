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
  let () =
    if asset_count = 0 then invalid_arg "Engine.run: no assets"
  in
  let () =
    if Array.length strategy.targets <> asset_count then
      invalid_arg "Engine.run: targets/assets mismatch"
  in
  let () =
    if Array.length costs <> asset_count then
      invalid_arg "Engine.run: costs/assets mismatch"
  in
  let () =
    if Array.length margin.ratios <> asset_count then
      invalid_arg "Engine.run: margin ratios/assets mismatch"
  in
  let length = Array.length (snd assets.(0)) in
  let () =
    Array.iter
      (fun (_, bars) ->
        if Array.length bars <> length then
          invalid_arg "Engine.run: bar length mismatch")
      assets
  in
  let () =
    Array.iter
      (fun target ->
        if Array.length target <> length then
          invalid_arg "Engine.run: target length mismatch")
      strategy.targets
  in
  let rec iter_assets_from index f =
    if index < asset_count then
      let () = f index in
      iter_assets_from (index + 1) f
  in
  let iter_assets f = iter_assets_from 0 f in
  let rec fold_assets_from index f accumulator =
    if index = asset_count then accumulator
    else fold_assets_from (index + 1) f (f accumulator index)
  in
  let fold_assets f initial = fold_assets_from 0 f initial in
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
    fold_assets (fun total index -> total +. total_value index) 0.
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
    let () = entry_dates.(index) <- date in
    let () = buy_value.(index) <- 0. in
    let () = buy_exposure.(index) <- 0. in
    let () = sell_value.(index) <- 0. in
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
    if !cash > 0. && total > 0. then
      let payment = Float.min !cash total in
      let remaining = 1. -. payment /. total in
      let () = cash := !cash -. payment in
      let () = loans.(index) <- loans.(index) *. remaining in
      interests.(index) <- interests.(index) *. remaining
  in
  let settle_all_liabilities () =
    let total = total_liabilities () in
    if !cash > 0. && total > 0. then
      let payment = Float.min !cash total in
      let remaining = 1. -. payment /. total in
      let () = cash := !cash -. payment in
      let () =
        Array.iteri
          (fun index loan -> loans.(index) <- loan *. remaining)
          loans
      in
      let () =
        Array.iteri
          (fun index interest -> interests.(index) <- interest *. remaining)
          interests
      in
      debt := !debt *. remaining
  in
  let sell_inventory ?(settle = true) index ~margin_only ~date ~price =
    let total_before = total_value index in
    let amount =
      if margin_only then margin_values.(index) else total_before
    in
    if amount > 0. then
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
      let () =
        sell_value.(index) <-
          sell_value.(index) +. sold_e *. price
      in
      let () =
        sell_exposure.(index) <-
          sell_exposure.(index) +. sold_e
      in
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
      let () =
        if cash_only && equity_now > 0. then
          let fraction =
            match cost_fraction with
            | Some value -> value
            | None -> assert false
          in
          let equity_after = equity_now *. (1. -. fraction) in
          let () = cash_values.(index) <- 0. in
          let cash_after = equity_after -. total_assets () in
          if cash_after < 0. then
            let () = debt := !debt -. cash_after in
            cash := 0.
          else cash := cash_after
        else
          let () =
            if margin_only then margin_values.(index) <- 0.
            else
              let () = cash_values.(index) <- 0. in
              margin_values.(index) <- 0.
          in
          let () = cash := !cash +. amount -. cost_value in
          let () =
            if !cash < 0. then
              let () = debt := !debt -. !cash in
              cash := 0.
          in
          if settle then settle_asset_liabilities index
      in
      let () = record_fill index ~date ~price ~from_e ~to_e in
      if total_value index = 0. then close_trip index ~date
  in
  let track_maintenance () =
    let total_loan = sum loans in
    if total_loan > 0. then
      let ratio = sum margin_values /. total_loan in
      let () =
        match !min_maintenance with
        | None -> min_maintenance := Some ratio
        | Some best -> if ratio < best then min_maintenance := Some ratio
      in
      Some ratio
    else None
  in
  let record_call date =
    match !margin_call_dates with
    | latest :: _ when latest = date -> ()
    | _ -> margin_call_dates := date :: !margin_call_dates
  in
  let bankrupt_all ~date price_at =
    let () = ignore (track_maintenance ()) in
    let () = record_call date in
    let () =
      iter_assets (fun index ->
        sell_inventory index ~margin_only:false ~date ~price:(price_at index))
    in
    let () = settle_all_liabilities () in
    let () = bankrupt := true in
    pending_liquidation := false
  in
  let effective t =
    let raw =
      Array.init asset_count
        (fun index -> clamp_target strategy.targets.(index).(t))
    in
    let need =
      fold_assets
        (fun need index ->
          need +. (raw.(index) *. (1. -. margin.ratios.(index))))
        0.
    in
    let scale = if need > 1. then 1. /. need else 1. in
    Array.map (fun value -> value *. scale) raw, scale < 1.
  in
  let differs eff =
    fold_assets
      (fun changed index ->
        let differs = eff.(index) <> prev_eff.(index) in
        changed || differs)
      false
  in
  let close_at index t = (snd assets.(index)).(t).Data.c in
  let open_at index t = (snd assets.(index)).(t).Data.o in
  let scale_values now before =
    iter_assets (fun index ->
      let factor = now index /. before index in
      let () =
        if cash_values.(index) <> 0. then
          cash_values.(index) <- cash_values.(index) *. factor
      in
      if margin_values.(index) <> 0. then
        margin_values.(index) <- margin_values.(index) *. factor)
  in
  let accrue_interest ~date ~prev_date =
    let days = day_number date - day_number prev_date in
    iter_assets (fun index ->
      if loans.(index) > 0. then
        interests.(index) <-
          interests.(index)
          +. loans.(index) *. margin.financing_rate
             *. float_of_int days /. 365.)
  in
  let apply_fills ~date ~eff ~clamped price_at =
    let e0 = equity () in
    let () =
      if e0 > 0. then
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
        let () =
          iter_assets (fun index ->
            let current = total_value index in
            let final_value =
              if changed.(index) then eff.(index) *. e1 else current
            in
            let trade = final_value -. current in
            let from_e = current /. e0 in
            let () = final_values.(index) <- final_value in
            let () = trades.(index) <- trade in
            let () = from_es.(index) <- from_e in
            let () =
              to_es.(index) <-
                if changed.(index) then eff.(index) else from_e
            in
            if changed.(index) && trade < 0. then
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
              let () = sell_margins.(index) <- sell_margin in
              let () = sell_cashes.(index) <- sell_cash in
              let () = repayments.(index) <- repayment in
              let () = interest_settled.(index) <- settled in
              let () =
                post_cash_values.(index) <-
                  cash_values.(index) -. sell_cash
              in
              let () =
                post_margin_values.(index) <-
                  margin_values.(index) -. sell_margin
              in
              let () = post_loans.(index) <- loans.(index) -. repayment in
              post_interests.(index) <- interests.(index) -. settled)
        in
        let has_requested_buy =
          Array.exists (fun trade -> trade > 0.) trades
        in
        let () =
          if buy_scale < 1. then
            iter_assets (fun index ->
              if changed.(index) && trades.(index) > 0. then
                let current = total_value index in
                let () = trades.(index) <- trades.(index) *. buy_scale in
                let () =
                  final_values.(index) <- current +. trades.(index)
                in
                let () =
                  to_es.(index) <- final_values.(index) /. equity_basis
                in
                scaled_buys.(index) <- true)
        in
        let post_assets = sum post_cash_values +. sum post_margin_values in
        let post_liabilities = sum post_loans +. sum post_interests in
        let available = e1 -. post_assets +. post_liabilities +. !debt in
        let cash_refinance_capacities = Array.make asset_count 0. in
        let margin_refinance_rates = Array.make asset_count 0. in
        let margin_refinance_capacities = Array.make asset_count 0. in
        let refinance_capacity =
          fold_assets
            (fun total index ->
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
              let () =
                cash_refinance_capacities.(index) <- cash_capacity
              in
              let () = margin_refinance_rates.(index) <- margin_rate in
              let () =
                margin_refinance_capacities.(index) <- margin_capacity
              in
              total +. cash_capacity +. margin_capacity)
            0.
        in
        let minimum_for index buy =
          let ratio = margin.ratios.(index) in
          if ratio <= 0. then buy else (1. -. ratio) *. buy
        in
        let minimum_total () =
          fold_assets
            (fun total index ->
              if changed.(index) && trades.(index) > 0. then
                total +. minimum_for index trades.(index)
              else total)
            0.
        in
        let requested_minimum = minimum_total () in
        let capacity_clamp =
          requested_minimum > 0.
          && requested_minimum -. available
             > refinance_capacity +. tolerance
        in
        let funding_clamp =
          capacity_clamp || (buy_scale < 1. && has_requested_buy)
        in
        let () =
          if capacity_clamp && requested_minimum > 0. then
            let fundable =
              Float.max 0. (available +. refinance_capacity)
            in
            let scale = Float.min 1. (fundable /. requested_minimum) in
            iter_assets (fun index ->
              if changed.(index) && trades.(index) > 0. then
                let current = total_value index in
                let () = trades.(index) <- trades.(index) *. scale in
                let () =
                  final_values.(index) <- current +. trades.(index)
                in
                let () =
                  to_es.(index) <- final_values.(index) /. equity_basis
                in
                scaled_buys.(index) <- true)
        in
        let total_cost =
          fold_assets
            (fun total_cost index ->
              if changed.(index) && trades.(index) <> 0. then
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
                let () = trade_costs.(index) <- cost in
                total_cost +. cost
              else total_cost)
            0.
        in
        let minimums = Array.make asset_count 0. in
        let buy_total, minimum_total =
          fold_assets
            (fun (buy_total, minimum_total) index ->
              if changed.(index) && trades.(index) > 0. then
                let buy = trades.(index) in
                let minimum = minimum_for index buy in
                let buy_total = buy_total +. buy in
                let () = minimums.(index) <- minimum in
                let minimum_total = minimum_total +. minimum in
                buy_total, minimum_total
              else buy_total, minimum_total)
            (0., 0.)
        in
        let shortage =
          let value = minimum_total -. available in
          if buy_total > 0. && value > tolerance then value else 0.
        in
        let shortage = Float.min shortage refinance_capacity in
        let allocations = Array.make asset_count 0. in
        let () =
          if buy_total > 0. && shortage = 0.
             && available >= buy_total
          then
            iter_assets (fun index ->
              if changed.(index) && trades.(index) > 0. then
                allocations.(index) <-
                  margin.ratios.(index) *. trades.(index))
        in
        let () =
          if buy_total > 0. && shortage = 0.
             && available < buy_total
          then
            let active = Array.make asset_count false in
            let total_capacity =
              fold_assets
                (fun total_capacity index ->
                  if changed.(index) && trades.(index) > 0. then
                    let capacity =
                      Float.max 0.
                        (margin.ratios.(index) *. trades.(index))
                    in
                    let total_capacity = total_capacity +. capacity in
                    let () = active.(index) <- capacity > tolerance in
                    total_capacity
                  else total_capacity)
                0.
            in
            let surplus =
              Float.min total_capacity
                (Float.max 0. (available -. minimum_total))
            in
            let rec distribute remaining remaining_rounds =
              if remaining_rounds > 0 && remaining > tolerance then
                let weight =
                  fold_assets
                    (fun weight index ->
                      if active.(index) then weight +. trades.(index)
                      else weight)
                    0.
                in
                if weight > 0. then
                  let capped = Array.make asset_count false in
                  let any_capped =
                    fold_assets
                      (fun any_capped index ->
                        if active.(index) then
                          let capacity =
                            margin.ratios.(index) *. trades.(index)
                            -. allocations.(index)
                          in
                          let proposed =
                            remaining *. trades.(index) /. weight
                          in
                          if proposed >= capacity then
                            let () = capped.(index) <- true in
                            true
                          else any_capped
                        else any_capped)
                      false
                  in
                  if any_capped then
                    let remaining =
                      fold_assets
                        (fun remaining index ->
                          if capped.(index) then
                            let capacity =
                              margin.ratios.(index) *. trades.(index)
                              -. allocations.(index)
                            in
                            let () =
                              allocations.(index) <-
                                allocations.(index) +. capacity
                            in
                            let remaining = remaining -. capacity in
                            let () = active.(index) <- false in
                            remaining
                          else remaining)
                        remaining
                    in
                    distribute remaining (remaining_rounds - 1)
                  else
                    let () =
                      iter_assets (fun index ->
                        if active.(index) then
                          allocations.(index) <-
                            allocations.(index)
                            +. remaining *. trades.(index) /. weight)
                    in
                    distribute 0. (remaining_rounds - 1)
                else distribute remaining (remaining_rounds - 1)
            in
            distribute surplus asset_count
        in
        let buy_cashes = Array.make asset_count 0. in
        let buy_margins = Array.make asset_count 0. in
        let down_payments = Array.make asset_count 0. in
        let () =
          iter_assets (fun index ->
            if changed.(index) && trades.(index) > 0. then
              let buy = trades.(index) in
              let ratio = margin.ratios.(index) in
              let cash_buy =
                if ratio <= 0. then buy
                else Float.min buy (allocations.(index) /. ratio)
              in
              let () = buy_cashes.(index) <- cash_buy in
              let () = buy_margins.(index) <- buy -. cash_buy in
              down_payments.(index) <-
                minimums.(index) +. allocations.(index))
        in
        let cash_refinance_values = Array.make asset_count 0. in
        let margin_refinance_values = Array.make asset_count 0. in
        let margin_refinance_repayments = Array.make asset_count 0. in
        let margin_refinance_interests = Array.make asset_count 0. in
        let refinance_es = Array.make asset_count 0. in
        let cash_refinance_sell_costs = Array.make asset_count 0. in
        let cash_refinance_buy_costs = Array.make asset_count 0. in
        let margin_refinance_sell_costs = Array.make asset_count 0. in
        let margin_refinance_buy_costs = Array.make asset_count 0. in
        let total_cost =
          if shortage > 0. && refinance_capacity > 0. then
            fold_assets
              (fun total_cost index ->
                let ratio = margin.ratios.(index) in
                let refinance_e =
                  (post_cash_values.(index) +. post_margin_values.(index))
                  /. equity_basis
                in
                let cash_capacity = cash_refinance_capacities.(index) in
                let total_cost =
                  if cash_capacity > 0. then
                    let allocated =
                      shortage *. cash_capacity /. refinance_capacity
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
                    let () = cash_refinance_values.(index) <- value in
                    let () =
                      cash_refinance_sell_costs.(index) <- sell_cost
                    in
                    let () =
                      cash_refinance_buy_costs.(index) <- buy_cost
                    in
                    let () = refinance_es.(index) <- refinance_e in
                    total_cost +. sell_cost +. buy_cost
                  else total_cost
                in
                let margin_capacity =
                  margin_refinance_capacities.(index)
                in
                if margin_capacity > 0. then
                  let allocated =
                    shortage *. margin_capacity /. refinance_capacity
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
                  let () = margin_refinance_values.(index) <- value in
                  let () =
                    margin_refinance_repayments.(index) <- repayment
                  in
                  let () = margin_refinance_interests.(index) <- settled in
                  let () =
                    margin_refinance_sell_costs.(index) <- sell_cost
                  in
                  let () =
                    margin_refinance_buy_costs.(index) <- buy_cost
                  in
                  let () = refinance_es.(index) <- refinance_e in
                  total_cost +. sell_cost +. buy_cost
                else total_cost)
              total_cost
          else total_cost
        in
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
          planned_total_cost = total_cost;
          planned_refinances = shortage > 0.;
          planned_funding_clamp = funding_clamp }
      in
      let projected_cash plan =
        let projected =
          Array.fold_left
            (fun projected item ->
              if item.plan_changed && item.plan_trade < 0. then
                projected -. item.plan_trade -. item.plan_repayment
                -. item.plan_interest_settled -. item.plan_trade_cost
              else projected)
            !cash plan.planned_assets
        in
        let projected = Float.max 0. projected in
        fold_assets
          (fun projected index ->
            let item = plan.planned_assets.(index) in
            let projected =
              projected
              +. margin.ratios.(index) *. item.plan_refinance_cash
              -. item.plan_refinance_cash_sell_cost
              -. item.plan_refinance_cash_buy_cost
              +. margin.ratios.(index) *. item.plan_refinance_margin
              -. item.plan_refinance_margin_repayment
              -. item.plan_refinance_margin_interest
              -. item.plan_refinance_margin_sell_cost
              -. item.plan_refinance_margin_buy_cost
            in
            if item.plan_changed && item.plan_trade > 0. then
              projected -. item.plan_down_payment -. item.plan_trade_cost
            else projected)
          projected
      in
      let solve buy_scale =
        let rec iterate remaining e1 =
          if remaining = 0 then e1
          else
            let previous = e1 in
            let plan = compute_plan buy_scale previous in
            let next = e0 -. plan.planned_total_cost in
            if next <= 0. then e1
            else if abs_float (next -. previous) <= tolerance then next
            else iterate (remaining - 1) next
        in
        compute_plan buy_scale (iterate 20 e0)
      in
      let requested_plan = solve 1. in
      let plan =
        if projected_cash requested_plan >= -. tolerance then requested_plan
        else
          let rec search remaining low high best =
            if remaining = 0 then best
            else
              let scale = (low +. high) /. 2. in
              let candidate = solve scale in
              if projected_cash candidate >= -. tolerance then
                search (remaining - 1) scale high candidate
              else search (remaining - 1) low scale best
          in
          search 60 0. 1. (solve 0.)
      in
      let () =
        if clamped || plan.planned_funding_clamp then incr clamps
      in
      let () =
        iter_assets (fun index ->
          let item = plan.planned_assets.(index) in
          if item.plan_changed && item.plan_trade < 0. then
            let old_total = total_value index in
            let () =
              if old_total > 0. && item.plan_from_e = 0. then
                start_trip index ~date
            in
            let exposure =
              abs_float (item.plan_to_e -. item.plan_from_e)
            in
            let () =
              sell_value.(index) <-
                sell_value.(index) +. exposure *. price_at index
            in
            let () =
              sell_exposure.(index) <-
                sell_exposure.(index) +. exposure
            in
            let () =
              cash_values.(index) <-
                cash_values.(index) -. item.plan_sell_cash
            in
            let () =
              margin_values.(index) <-
                margin_values.(index) -. item.plan_sell_margin
            in
            let () =
              if item.plan_final_value = 0. then
                let () = cash_values.(index) <- 0. in
                margin_values.(index) <- 0.
            in
            let () =
              loans.(index) <- loans.(index) -. item.plan_repayment
            in
            let () =
              interests.(index) <-
                interests.(index) -. item.plan_interest_settled
            in
            let () =
              cash :=
                !cash -. item.plan_trade -. item.plan_repayment
                -. item.plan_interest_settled -. item.plan_trade_cost
            in
            let () =
              record_fill index ~date ~price:(price_at index)
                ~from_e:item.plan_from_e ~to_e:item.plan_to_e
            in
            if item.plan_final_value = 0. then close_trip index ~date)
      in
      if not !bankrupt then
        let () =
          if plan.planned_refinances then incr refinances
        in
        let () =
          iter_assets (fun index ->
            let item = plan.planned_assets.(index) in
            let () =
              if item.plan_refinance_cash > 0. then
                let () =
                  cash_values.(index) <-
                    cash_values.(index) -. item.plan_refinance_cash
                in
                let () =
                  cash :=
                    !cash +. item.plan_refinance_cash
                    -. item.plan_refinance_cash_sell_cost
                in
                let () =
                  record_fill index ~date ~price:(price_at index)
                    ~from_e:item.plan_refinance_e
                    ~to_e:item.plan_refinance_e
                in
                let () =
                  margin_values.(index) <-
                    margin_values.(index) +. item.plan_refinance_cash
                in
                let () =
                  loans.(index) <-
                    loans.(index)
                    +. item.plan_refinance_cash *. margin.ratios.(index)
                in
                let () =
                  cash :=
                    !cash
                    -. (1. -. margin.ratios.(index))
                       *. item.plan_refinance_cash
                    -. item.plan_refinance_cash_buy_cost
                in
                record_fill index ~date ~price:(price_at index)
                  ~from_e:item.plan_refinance_e
                  ~to_e:item.plan_refinance_e
            in
            if item.plan_refinance_margin > 0. then
              let () =
                margin_values.(index) <-
                  margin_values.(index) -. item.plan_refinance_margin
              in
              let () =
                loans.(index) <-
                  loans.(index) -. item.plan_refinance_margin_repayment
              in
              let () =
                interests.(index) <-
                  interests.(index) -. item.plan_refinance_margin_interest
              in
              let () =
                cash :=
                  !cash +. item.plan_refinance_margin
                  -. item.plan_refinance_margin_repayment
                  -. item.plan_refinance_margin_interest
                  -. item.plan_refinance_margin_sell_cost
              in
              let () =
                record_fill index ~date ~price:(price_at index)
                  ~from_e:item.plan_refinance_e
                  ~to_e:item.plan_refinance_e
              in
              let () =
                margin_values.(index) <-
                  margin_values.(index) +. item.plan_refinance_margin
              in
              let () =
                loans.(index) <-
                  loans.(index)
                  +. item.plan_refinance_margin *. margin.ratios.(index)
              in
              let () =
                cash :=
                  !cash
                  -. (1. -. margin.ratios.(index))
                     *. item.plan_refinance_margin
                  -. item.plan_refinance_margin_buy_cost
              in
              record_fill index ~date ~price:(price_at index)
                ~from_e:item.plan_refinance_e
                ~to_e:item.plan_refinance_e)
        in
        let () =
          iter_assets (fun index ->
            let item = plan.planned_assets.(index) in
            if item.plan_changed && item.plan_trade > 0. then
              let () =
                if item.plan_from_e = 0. then start_trip index ~date
              in
              let exposure = item.plan_to_e -. item.plan_from_e in
              let () =
                buy_value.(index) <-
                  buy_value.(index) +. exposure *. price_at index
              in
              let () =
                buy_exposure.(index) <-
                  buy_exposure.(index) +. exposure
              in
              let () =
                cash_values.(index) <-
                  cash_values.(index) +. item.plan_buy_cash
              in
              let () =
                margin_values.(index) <-
                  margin_values.(index) +. item.plan_buy_margin
              in
              let () =
                loans.(index) <-
                  loans.(index)
                  +. item.plan_buy_margin *. margin.ratios.(index)
              in
              let () =
                cash :=
                  !cash -. item.plan_down_payment -. item.plan_trade_cost
              in
              record_fill index ~date ~price:(price_at index)
                ~from_e:item.plan_from_e ~to_e:item.plan_to_e)
        in
        let () =
          if !cash < 0. then
            let deficit = -. !cash in
            let settlement =
              fold_assets
                (fun settlement index ->
                  let item = plan.planned_assets.(index) in
                  if item.plan_changed && item.plan_trade < 0. then
                    settlement +. item.plan_repayment
                    +. item.plan_interest_settled
                  else settlement)
                0.
            in
            let restored = Float.min deficit settlement in
            let () =
              if restored > 0. then
                let unpaid_fraction = restored /. settlement in
                iter_assets (fun index ->
                  let item = plan.planned_assets.(index) in
                  if item.plan_changed && item.plan_trade < 0. then
                    let () =
                      loans.(index) <-
                        loans.(index)
                        +. item.plan_repayment *. unpaid_fraction
                    in
                    interests.(index) <-
                      interests.(index)
                      +. item.plan_interest_settled *. unpaid_fraction)
            in
            let () = debt := !debt +. deficit -. restored in
            cash := 0.
        in
        if equity () <= 0. then
          if has_inventory () then bankrupt_all ~date price_at
          else
            let () = bankrupt := true in
            pending_liquidation := false
    in
    Array.blit eff 0 prev_eff 0 asset_count
  in
  let guard_solvency ~date price_at =
    if not !bankrupt && equity () <= 0. then
      if has_inventory () then bankrupt_all ~date price_at
      else
        let () = bankrupt := true in
        pending_liquidation := false
  in
  let liquidate ~date price_at =
    let () =
      iter_assets (fun index ->
        sell_inventory ~settle:false index ~margin_only:true
          ~date ~price:(price_at index))
    in
    let () = settle_all_liabilities () in
    if equity () <= 0. then
      let () =
        iter_assets (fun index ->
          sell_inventory index ~margin_only:false
            ~date ~price:(price_at index))
      in
      let () = settle_all_liabilities () in
      let () = bankrupt := true in
      pending_liquidation := false
  in
  let rec walk_bars t =
    if t = length then ()
    else
      let date = (snd assets.(0)).(t).Data.date in
      let () =
        if not !bankrupt then
          let () =
            if t > 0 then
              accrue_interest ~date
                ~prev_date:((snd assets.(0)).(t - 1).Data.date)
          in
          match fill with
          | Close_same ->
              let () =
                if t > 0 && !pending_liquidation then
                  let () =
                    scale_values (fun i -> open_at i t)
                      (fun i -> close_at i (t - 1))
                  in
                  let () = liquidate ~date (fun i -> open_at i t) in
                  let () = pending_liquidation := false in
                  scale_values
                    (fun i -> close_at i t) (fun i -> open_at i t)
                else if t > 0 then
                  scale_values (fun i -> close_at i t)
                    (fun i -> close_at i (t - 1))
              in
              let () =
                guard_solvency ~date (fun i -> close_at i t)
              in
              if not !bankrupt then
                let eff, clamped = effective t in
                if differs eff then
                  apply_fills ~date ~eff ~clamped
                    (fun i -> close_at i t)
          | Open_next ->
              if t > 0 then
                let eff, clamped = effective (t - 1) in
                let scheduled = differs eff in
                let () =
                  scale_values (fun i -> open_at i t)
                    (fun i -> close_at i (t - 1))
                in
                let () =
                  if !pending_liquidation then
                    let () = liquidate ~date (fun i -> open_at i t) in
                    pending_liquidation := false
                in
                let () =
                  guard_solvency ~date (fun i -> open_at i t)
                in
                let () =
                  if not !bankrupt && scheduled then
                    apply_fills ~date ~eff ~clamped
                      (fun i -> open_at i t)
                in
                scale_values
                  (fun i -> close_at i t) (fun i -> open_at i t)
      in
      let () =
        if not !bankrupt then
          guard_solvency ~date (fun i -> close_at i t)
      in
      let () =
        if not !bankrupt then
          match track_maintenance () with
          | Some ratio when ratio < margin.maintenance_ratio ->
              let () = record_call date in
              pending_liquidation := true
          | _ -> ()
      in
      let () =
        if !cash < -1e-9 then
          invalid_arg "Engine.run: negative cash invariant"
      in
      let () = equity_curve := (date, equity ()) :: !equity_curve in
      walk_bars (t + 1)
  in
  let () = walk_bars 0 in
  let last = length - 1 in
  let closed_any =
    fold_assets
      (fun closed_any index ->
        if total_value index > 0. then
          let () =
            sell_inventory index ~margin_only:false
              ~date:(snd assets.(index)).(last).Data.date
              ~price:(close_at index last)
          in
          true
        else closed_any)
      false
  in
  let () = settle_all_liabilities () in
  let () =
    if closed_any then
      match !equity_curve with
      | _ :: rest ->
          equity_curve :=
            ((snd assets.(0)).(last).Data.date, equity ()) :: rest
      | [] -> ()
  in
  { equity_curve = List.rev !equity_curve;
    fills = List.rev !fills;
    trips = List.rev !trips;
    margin_stats =
      { min_maintenance = !min_maintenance;
        margin_call_dates = List.rev !margin_call_dates;
        refinances = !refinances;
        clamps = !clamps } }
