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
  loan_term_months : int option;
}

type margin_lot = {
  origination_index : int;
  mutable principal : float;
  mutable interest : float;
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

type receivable = {
  receivable_pay_date : string;
  receivable_cash : float;
  receivable_margin : float;
}


let default_costs ~market ~symbol =
  match String.lowercase_ascii market with
  | "us" -> { fee_bps = 0.; tax_bps = 0.; slip_bps = 0.; min_fee = 0. }
  | "tw" ->
      let length = String.length symbol in
      let starts_with_zero second =
        length >= 2 && symbol.[0] = '0' && symbol.[1] = second
      in
      let is_etf = starts_with_zero '0' in
      let tax_bps =
        (* The 2017-01-01 through 2026-12-31 temporary exemption covers ordinary bond ETFs; leveraged/inverse L/R classes remain taxed. *)
        if is_etf && symbol.[length - 1] = 'B' then 0.
        else if is_etf || starts_with_zero '2' then 10.
        else 30.
      in
      { fee_bps = 3.99;
        tax_bps;
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

let days_in_month year = function
  | 2 ->
      if year mod 400 = 0 || (year mod 4 = 0 && year mod 100 <> 0)
      then 29
      else 28
  | 4 | 6 | 9 | 11 -> 30
  | _ -> 31

let add_months_clamped date months =
  let year = int_of_string (String.sub date 0 4) in
  let month = int_of_string (String.sub date 5 2) in
  let day = int_of_string (String.sub date 8 2) in
  let absolute_month = (year * 12) + month - 1 + months in
  let target_year = absolute_month / 12 in
  let target_month = absolute_month mod 12 + 1 in
  let target_day = min day (days_in_month target_year target_month) in
  Printf.sprintf "%04d-%02d-%02d" target_year target_month target_day

let run ?dividends ?(dividend_tax = 0.)
    (assets : (string * Data.bar array) array) (strategy : strategy)
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
  let dividends =
    match dividends with
    | None -> Array.make asset_count [||]
    | Some events ->
        let () =
          if Array.length events <> asset_count then
            invalid_arg "Engine.run: dividends/assets mismatch"
        in
        events
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
  let margin_lots = Array.make asset_count [] in
  let dividend_indices = Array.make asset_count 0 in
  let receivables = Array.make asset_count [] in
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
  let last_index = length - 1 in
  let date_at index bar_index =
    (snd assets.(index)).(bar_index).Data.date
  in
  let loan_at index =
    List.fold_left
      (fun total lot -> total +. lot.principal)
      0. margin_lots.(index)
  in
  let interest_at index =
    List.fold_left
      (fun total lot -> total +. lot.interest)
      0. margin_lots.(index)
  in
  let total_loans () =
    fold_assets (fun total index -> total +. loan_at index) 0.
  in
  let total_interests () =
    fold_assets (fun total index -> total +. interest_at index) 0.
  in
  let scale_lots index remaining =
    if remaining <= 0. then margin_lots.(index) <- []
    else
      List.iter
        (fun lot ->
          lot.principal <- lot.principal *. remaining;
          lot.interest <- lot.interest *. remaining)
        margin_lots.(index)
  in
  let add_lot index ~bar_index principal =
    if principal > 0. then
      margin_lots.(index) <-
        { origination_index = bar_index; principal; interest = 0. }
        :: margin_lots.(index)
  in
  let settlement_start_index lot =
    Int.min last_index (lot.origination_index + 2)
  in
  let tail_interest_for_lot index bar_index lot =
    let start_index =
      Int.max bar_index (settlement_start_index lot)
    in
    let stop_index = Int.min last_index (bar_index + 2) in
    if stop_index > start_index then
      let days =
        day_number (date_at index stop_index)
        - day_number (date_at index start_index)
      in
      lot.principal *. margin.financing_rate
      *. float_of_int days /. 365.
    else 0.
  in
  let tail_interest_at index bar_index =
    List.fold_left
      (fun total lot ->
        total +. tail_interest_for_lot index bar_index lot)
      0. margin_lots.(index)
  in
  let capitalize_tail_interest index bar_index =
    List.iter
      (fun lot ->
        lot.interest <-
          lot.interest +. tail_interest_for_lot index bar_index lot)
      margin_lots.(index)
  in
  let total_value index =
    cash_values.(index) +. margin_values.(index)
  in
  let total_assets () =
    fold_assets (fun total index -> total +. total_value index) 0.
  in
  let total_liabilities () =
    total_loans () +. total_interests () +. !debt
  in
  let has_inventory () =
    Array.exists (fun value -> value > 0.) cash_values
    || Array.exists (fun value -> value > 0.) margin_values
  in
  let total_receivables () =
    fold_assets
      (fun total index ->
        List.fold_left
          (fun total receivable ->
            total +. receivable.receivable_cash
            +. receivable.receivable_margin)
          total receivables.(index))
      0.
  in
  let equity () =
    !cash +. total_assets () -. total_liabilities ()
    +. total_receivables ()
  in
  let is_us index =
    let stock = fst assets.(index) in
    String.length stock >= 3
    && stock.[0] = 'u' && stock.[1] = 's' && stock.[2] = '/'
  in
  let settle_debt_from_cash () =
    if !cash > 0. && !debt > 0. then
      let payment = Float.min !cash !debt in
      let () = cash := !cash -. payment in
      debt := !debt -. payment
  in
  let repay_margin_receivable index amount =
    let due = loan_at index +. interest_at index in
    if due > 0. then
      let payment = Float.min amount due in
      let remaining = 1. -. payment /. due in
      let () = scale_lots index remaining in
      cash := !cash +. amount -. payment
    else cash := !cash +. amount
  in
  let process_dividends ~previous_date ~date price_at =
    let landed = ref false in
    let () =
      iter_assets (fun index ->
        let events = dividends.(index) in
        let book_event event =
          let price = price_at index in
          let net_per_share =
            event.Data.cash_per_share *. (1. -. dividend_tax)
          in
          let cash_amount =
            if price > 0. then
              cash_values.(index) /. price *. net_per_share
            else 0.
          in
          let margin_amount =
            if price > 0. then
              margin_values.(index) /. price *. net_per_share
            else 0.
          in
          let total = cash_amount +. margin_amount in
          if total > 0. then
            if is_us index then
              let () = cash := !cash +. total in
              landed := true
            else
              receivables.(index) <-
                { receivable_pay_date = event.Data.pay_date;
                  receivable_cash = cash_amount;
                  receivable_margin = margin_amount }
                :: receivables.(index)
        in
        let rec book event_index =
          if event_index = Array.length events then event_index
          else
            let event = events.(event_index) in
            if String.compare event.Data.ex_date date > 0 then event_index
            else
              let () =
                match previous_date with
                | Some previous
                  when String.compare event.Data.ex_date previous > 0 ->
                    book_event event
                | None | Some _ -> ()
              in
              book (event_index + 1)
        in
        let () =
          dividend_indices.(index) <- book dividend_indices.(index)
        in
        let rec settle kept = function
          | [] -> List.rev kept
          | receivable :: rest ->
              if
                String.compare date receivable.receivable_pay_date >= 0
              then
                let amount =
                  receivable.receivable_cash
                  +. receivable.receivable_margin
                in
                let () =
                  if amount > 0. then landed := true
                in
                let () =
                  cash := !cash +. receivable.receivable_cash
                in
                let () =
                  repay_margin_receivable index
                    receivable.receivable_margin
                in
                settle kept rest
              else settle (receivable :: kept) rest
        in
        receivables.(index) <- settle [] receivables.(index))
    in
    let () =
      if !landed then settle_debt_from_cash ()
    in
    !landed
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
    let total = loan_at index +. interest_at index in
    let () =
      if !cash > 0. && total > 0. then
        let payment = Float.min !cash total in
        let remaining = 1. -. payment /. total in
        let () = cash := !cash -. payment in
        scale_lots index remaining
    in
    if margin_values.(index) = 0. then
      let residual = loan_at index +. interest_at index in
      if residual > 0. then
        let () = debt := !debt +. residual in
        margin_lots.(index) <- []
  in
  let settle_all_liabilities () =
    let total = total_liabilities () in
    let () =
      if !cash > 0. && total > 0. then
        let payment = Float.min !cash total in
        let remaining = 1. -. payment /. total in
        let () = cash := !cash -. payment in
        let () =
          iter_assets (fun index -> scale_lots index remaining)
        in
        debt := !debt *. remaining
    in
    iter_assets (fun index ->
      if margin_values.(index) = 0. then
        let residual = loan_at index +. interest_at index in
        if residual > 0. then
          let () = debt := !debt +. residual in
          margin_lots.(index) <- [])
  in
  let sell_inventory ?(settle = true) index ~margin_only ~bar_index
      ~date ~price =
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
          let cash_after =
            equity_after -. total_assets () -. total_receivables ()
          in
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
          if settle then
            let () = capitalize_tail_interest index bar_index in
            settle_asset_liabilities index
      in
      let () = record_fill index ~date ~price ~from_e ~to_e in
      if total_value index = 0. then close_trip index ~date
  in
  let track_maintenance () =
    let total_loan = total_loans () in
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
  let rollover_matured ~bar_index ~date price_at =
    match margin.loan_term_months with
    | None -> ()
    | Some months ->
        let e0 = equity () in
        if months > 0 && e0 > 0. then
          let roll_values = Array.make asset_count 0. in
          let roll_dues = Array.make asset_count 0. in
          let remaining_lots = Array.copy margin_lots in
          let has_rollover = ref false in
          let () =
            iter_assets (fun index ->
              let stock = fst assets.(index) in
              if String.length stock >= 3
                 && stock.[0] = 't' && stock.[1] = 'w' && stock.[2] = '/'
              then
                let matured_reversed, live_reversed =
                  List.fold_left
                    (fun (matured, live) lot ->
                      let origination_date =
                        date_at index lot.origination_index
                      in
                      let maturity =
                        add_months_clamped origination_date months
                      in
                      if String.compare date maturity >= 0 then
                        lot :: matured, live
                      else matured, lot :: live)
                    ([], []) margin_lots.(index)
                in
                match matured_reversed with
                | [] -> ()
                | _ ->
                    let matured = List.rev matured_reversed in
                    let total_loan = loan_at index in
                    let matured_principal =
                      List.fold_left
                        (fun total lot -> total +. lot.principal)
                        0. matured
                    in
                    let value =
                      if total_loan > 0. then
                        margin_values.(index)
                        *. matured_principal /. total_loan
                      else 0.
                    in
                    let due =
                      List.fold_left
                        (fun total lot ->
                          total +. lot.principal +. lot.interest
                          +. tail_interest_for_lot index bar_index lot)
                        0. matured
                    in
                    let () = has_rollover := true in
                    let () = roll_values.(index) <- value in
                    let () = roll_dues.(index) <- due in
                    remaining_lots.(index) <- List.rev live_reversed)
          in
          if !has_rollover then
            let () = ignore (track_maintenance ()) in
            let sell_costs =
              Array.init asset_count
                (fun index ->
                  let value = roll_values.(index) in
                  if value > 0. then
                    charge index ~equity_before:e0
                      ~delta:(-. value /. e0) *. e0
                  else 0.)
            in
            let cash_after_sales =
              fold_assets
                (fun available index ->
                  available +. roll_values.(index)
                  -. sell_costs.(index) -. roll_dues.(index))
                !cash
            in
            let rebuy_cash scale =
              fold_assets
                (fun required index ->
                  let buy = roll_values.(index) *. scale in
                  if buy > 0. then
                    let buy_cost =
                      charge index ~equity_before:e0
                        ~delta:(buy /. e0) *. e0
                    in
                    required
                    +. (1. -. margin.ratios.(index)) *. buy
                    +. buy_cost
                  else required)
                0.
            in
            let scale =
              if cash_after_sales <= 0. then 0.
              else if rebuy_cash 1. <= cash_after_sales then 1.
              else
                let rec search remaining low high =
                  if remaining = 0 then low
                  else
                    let candidate = (low +. high) /. 2. in
                    if rebuy_cash candidate <= cash_after_sales then
                      search (remaining - 1) candidate high
                    else search (remaining - 1) low candidate
                in
                search 60 0. 1.
            in
            let from_es =
              Array.init asset_count
                (fun index -> total_value index /. e0)
            in
            let sell_to_es =
              Array.init asset_count
                (fun index ->
                  (total_value index -. roll_values.(index)) /. e0)
            in
            let () =
              iter_assets (fun index ->
                let value = roll_values.(index) in
                let () =
                  margin_values.(index) <-
                    Float.max 0. (margin_values.(index) -. value)
                in
                let () = margin_lots.(index) <- remaining_lots.(index) in
                if value > 0. then
                  record_fill index ~date ~price:(price_at index)
                    ~from_e:from_es.(index) ~to_e:sell_to_es.(index))
            in
            let () =
              if cash_after_sales < 0. then
                let () = debt := !debt -. cash_after_sales in
                cash := 0.
              else cash := cash_after_sales
            in
            let () =
              if cash_after_sales >= 0. then
                iter_assets (fun index ->
                  let buy = roll_values.(index) *. scale in
                  if buy > 0. then
                    let buy_cost =
                      charge index ~equity_before:e0
                        ~delta:(buy /. e0) *. e0
                    in
                    let () =
                      cash :=
                        !cash
                        -. (1. -. margin.ratios.(index)) *. buy
                        -. buy_cost
                    in
                    let () =
                      margin_values.(index) <-
                        margin_values.(index) +. buy
                    in
                    let () =
                      add_lot index ~bar_index
                        (buy *. margin.ratios.(index))
                    in
                    record_fill index ~date ~price:(price_at index)
                      ~from_e:sell_to_es.(index)
                      ~to_e:
                        ((total_value index) /. e0))
            in
            let () =
              if !cash < 0. then
                let () = debt := !debt -. !cash in
                cash := 0.
            in
            incr refinances
  in
  let record_call date =
    match !margin_call_dates with
    | latest :: _ when latest = date -> ()
    | _ -> margin_call_dates := date :: !margin_call_dates
  in
  let bankrupt_all ~bar_index ~date price_at =
    let () = ignore (track_maintenance ()) in
    let () = record_call date in
    let () =
      iter_assets (fun index ->
        sell_inventory index ~margin_only:false ~bar_index
          ~date ~price:(price_at index))
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
  let accrue_interest ~bar_index ~date ~prev_date =
    let days = day_number date - day_number prev_date in
    iter_assets (fun index ->
      List.iter
        (fun lot ->
          if bar_index > settlement_start_index lot then
            lot.interest <-
              lot.interest
              +. lot.principal *. margin.financing_rate
                 *. float_of_int days /. 365.)
        margin_lots.(index))
  in
  let apply_fills ~bar_index ~date ~eff ~clamped ~force price_at =
    let e0 = equity () in
    let current_loans = Array.init asset_count loan_at in
    let current_interests = Array.init asset_count interest_at in
    let current_tails =
      Array.init asset_count
        (fun index -> tail_interest_at index bar_index)
    in
    let () =
      if e0 > 0. then
      let tolerance = 1e-15 *. abs_float e0 in
      let compute_plan buy_scale e1 =
        let equity_basis = abs_float e1 in
        let changed =
          Array.init asset_count
            (fun index -> force || eff.(index) <> prev_eff.(index))
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
        let interest_tails = Array.make asset_count 0. in
        let post_cash_values = Array.copy cash_values in
        let post_margin_values = Array.copy margin_values in
        let post_loans = Array.copy current_loans in
        let post_interests = Array.copy current_interests in
        let post_tails = Array.copy current_tails in
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
              let repayment = current_loans.(index) *. fraction in
              let accrued =
                current_interests.(index) *. fraction
              in
              let tail = current_tails.(index) *. fraction in
              let settled = accrued +. tail in
              let () = sell_margins.(index) <- sell_margin in
              let () = sell_cashes.(index) <- sell_cash in
              let () = repayments.(index) <- repayment in
              let () = interest_settled.(index) <- settled in
              let () = interest_tails.(index) <- tail in
              let () =
                post_cash_values.(index) <-
                  cash_values.(index) -. sell_cash
              in
              let () =
                post_margin_values.(index) <-
                  margin_values.(index) -. sell_margin
              in
              let () =
                post_loans.(index) <-
                  current_loans.(index) -. repayment
              in
              let () =
                post_interests.(index) <-
                  current_interests.(index) -. accrued
              in
              post_tails.(index) <- current_tails.(index) -. tail)
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
        let available =
          e1 -. post_assets +. post_liabilities +. !debt
          -. total_receivables ()
        in
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
                     -. (post_loans.(index) +. post_interests.(index)
                         +. post_tails.(index))
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
            (sum interest_tails)
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
                  let accrued = post_interests.(index) *. fraction in
                  let tail = post_tails.(index) *. fraction in
                  let settled = accrued +. tail in
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
                  total_cost +. sell_cost +. buy_cost +. tail
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
              if item.plan_repayment > 0. then
                let current_loan = loan_at index in
                let remaining =
                  if item.plan_repayment >= current_loan then 0.
                  else 1. -. item.plan_repayment /. current_loan
                in
                scale_lots index remaining
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
                  add_lot index ~bar_index
                    (item.plan_refinance_cash *. margin.ratios.(index))
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
                if item.plan_refinance_margin_repayment > 0. then
                  let current_loan = loan_at index in
                  let remaining =
                    if item.plan_refinance_margin_repayment >= current_loan
                    then 0.
                    else
                      1.
                      -. item.plan_refinance_margin_repayment /. current_loan
                  in
                  scale_lots index remaining
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
                add_lot index ~bar_index
                  (item.plan_refinance_margin *. margin.ratios.(index))
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
                add_lot index ~bar_index
                  (item.plan_buy_margin *. margin.ratios.(index))
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
            let () = debt := !debt +. deficit in
            cash := 0.
        in
        if equity () <= 0. then
          if has_inventory () then
            bankrupt_all ~bar_index ~date price_at
          else
            let () = bankrupt := true in
            pending_liquidation := false
    in
    Array.blit eff 0 prev_eff 0 asset_count
  in
  let guard_solvency ~bar_index ~date price_at =
    if not !bankrupt && equity () <= 0. then
      if has_inventory () then bankrupt_all ~bar_index ~date price_at
      else
        let () = bankrupt := true in
        pending_liquidation := false
  in
  let liquidate ~bar_index ~date price_at =
    let () =
      iter_assets (fun index ->
        let () = capitalize_tail_interest index bar_index in
        sell_inventory ~settle:false index ~margin_only:true ~bar_index
          ~date ~price:(price_at index))
    in
    let () = settle_all_liabilities () in
    if equity () <= 0. then
      let () =
        iter_assets (fun index ->
          sell_inventory index ~margin_only:false ~bar_index
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
      let previous_date =
        if t = 0 then None
        else Some ((snd assets.(0)).(t - 1).Data.date)
      in
      let () =
        if !bankrupt then
          ignore
            (process_dividends ~previous_date ~date
               (fun i -> close_at i t))
        else
          let () =
            if t > 0 then
              accrue_interest ~bar_index:t ~date
                ~prev_date:((snd assets.(0)).(t - 1).Data.date)
          in
          match fill with
          | Close_same ->
              let cash_landed =
                if t > 0 && !pending_liquidation then
                  let () =
                    scale_values (fun i -> open_at i t)
                      (fun i -> close_at i (t - 1))
                  in
                  let cash_landed =
                    process_dividends ~previous_date ~date
                      (fun i -> open_at i t)
                  in
                  let () =
                    liquidate ~bar_index:t ~date (fun i -> open_at i t)
                  in
                  let () = pending_liquidation := false in
                  let () =
                    scale_values
                      (fun i -> close_at i t) (fun i -> open_at i t)
                  in
                  cash_landed
                else
                  let () =
                    if t > 0 then
                      scale_values (fun i -> close_at i t)
                        (fun i -> close_at i (t - 1))
                  in
                  process_dividends ~previous_date ~date
                    (fun i -> close_at i t)
              in
              let () =
                guard_solvency ~bar_index:t ~date (fun i -> close_at i t)
              in
              if not !bankrupt then
                let eff, clamped = effective t in
                let () =
                  if cash_landed || differs eff then
                    apply_fills ~bar_index:t ~date ~eff ~clamped
                      ~force:cash_landed (fun i -> close_at i t)
                in
                if not !bankrupt then
                  rollover_matured ~bar_index:t ~date
                    (fun i -> close_at i t)
          | Open_next ->
              if t > 0 then
                let eff, clamped = effective (t - 1) in
                let scheduled = differs eff in
                let () =
                  scale_values (fun i -> open_at i t)
                    (fun i -> close_at i (t - 1))
                in
                let cash_landed =
                  process_dividends ~previous_date ~date
                    (fun i -> open_at i t)
                in
                let () =
                  if !pending_liquidation then
                    let () =
                      liquidate ~bar_index:t ~date (fun i -> open_at i t)
                    in
                    pending_liquidation := false
                in
                let () =
                  guard_solvency ~bar_index:t ~date
                    (fun i -> open_at i t)
                in
                let () =
                  if not !bankrupt && (cash_landed || scheduled) then
                    apply_fills ~bar_index:t ~date ~eff ~clamped
                      ~force:cash_landed (fun i -> open_at i t)
                in
                let () =
                  if not !bankrupt then
                    rollover_matured ~bar_index:t ~date
                      (fun i -> open_at i t)
                in
                let () =
                  if not !bankrupt then
                    guard_solvency ~bar_index:t ~date
                      (fun i -> open_at i t)
                in
                scale_values
                  (fun i -> close_at i t) (fun i -> open_at i t)
      in
      let () =
        if not !bankrupt then
          guard_solvency ~bar_index:t ~date (fun i -> close_at i t)
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
  let closed_any =
    fold_assets
      (fun closed_any index ->
        if total_value index > 0. then
          let () =
            sell_inventory index ~margin_only:false ~bar_index:last_index
              ~date:(snd assets.(index)).(last_index).Data.date
              ~price:(close_at index last_index)
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
            ((snd assets.(0)).(last_index).Data.date, equity ()) :: rest
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
