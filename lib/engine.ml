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

type trip = {
  entry_date : string;
  exit_date : string;
  net_ret : float;
}

type result = {
  equity_curve : (string * float) list;
  fills : fill_event list;
  trips : trip list;
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

let run (assets : (string * Data.bar array) array) (strategy : strategy)
    (costs : costs array) ~capital:(capital : float option) ~fill =
  let asset_count = Array.length assets in
  if asset_count = 0 then invalid_arg "Engine.run: no assets";
  if Array.length strategy.targets <> asset_count then
    invalid_arg "Engine.run: targets/assets mismatch";
  if Array.length costs <> asset_count then
    invalid_arg "Engine.run: costs/assets mismatch";
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
  let equity = ref 1. in
  let exposures = Array.make asset_count 0. in
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
  let trade index ~date ~price ~desired =
    let exposure = exposures.(index) in
    let delta = desired -. exposure in
    if delta <> 0. then begin
      if exposure = 0. then begin
        entry_dates.(index) <- date;
        buy_value.(index) <- 0.;
        buy_exposure.(index) <- 0.;
        sell_value.(index) <- 0.;
        sell_exposure.(index) <- 0.
      end;
      if delta > 0. then begin
        buy_value.(index) <- buy_value.(index) +. delta *. price;
        buy_exposure.(index) <- buy_exposure.(index) +. delta
      end
      else begin
        sell_value.(index) <- sell_value.(index) -. delta *. price;
        sell_exposure.(index) <- sell_exposure.(index) -. delta
      end;
      let equity_before = !equity in
      equity := equity_before *. (1. -. charge index ~equity_before ~delta);
      fills :=
        { date; stock = fst assets.(index); price;
          from_e = exposure; to_e = desired } :: !fills;
      exposures.(index) <- desired;
      if desired = 0. then begin
        let entry_price = buy_value.(index) /. buy_exposure.(index) in
        let exit_price = sell_value.(index) /. sell_exposure.(index) in
        trips :=
          { entry_date = entry_dates.(index); exit_date = date;
            net_ret = exit_price /. entry_price -. 1. } :: !trips
      end
    end
  in
  let close_at index t = (snd assets.(index)).(t).Data.c in
  let open_at index t = (snd assets.(index)).(t).Data.o in
  let joint now before =
    let sum = ref 0. in
    for index = 0 to asset_count - 1 do
      if exposures.(index) <> 0. then
        sum :=
          !sum +. exposures.(index) *. (now index /. before index -. 1.)
    done;
    !sum
  in
  for t = 0 to length - 1 do
    let date = (snd assets.(0)).(t).Data.date in
    (match fill with
     | Close_same ->
         if t > 0 then
           equity :=
             !equity
             *. (1. +. joint (fun i -> close_at i t)
                         (fun i -> close_at i (t - 1)));
         for index = 0 to asset_count - 1 do
           trade index ~date ~price:(close_at index t)
             ~desired:(clamp_target strategy.targets.(index).(t))
         done
     | Open_next ->
         if t > 0 then begin
           let changed = ref false in
           for index = 0 to asset_count - 1 do
             if clamp_target strategy.targets.(index).(t - 1)
                <> exposures.(index)
             then changed := true
           done;
           if !changed then begin
             equity :=
               !equity
               *. (1. +. joint (fun i -> open_at i t)
                           (fun i -> close_at i (t - 1)));
             for index = 0 to asset_count - 1 do
               trade index ~date ~price:(open_at index t)
                 ~desired:(clamp_target strategy.targets.(index).(t - 1))
             done;
             equity :=
               !equity
               *. (1. +. joint (fun i -> close_at i t)
                           (fun i -> open_at i t))
           end
           else
             equity :=
               !equity
               *. (1. +. joint (fun i -> close_at i t)
                           (fun i -> close_at i (t - 1)))
         end);
    equity_curve := (date, !equity) :: !equity_curve
  done;
  let last = length - 1 in
  let closed_any = ref false in
  for index = 0 to asset_count - 1 do
    if exposures.(index) > 0. then begin
      closed_any := true;
      trade index ~date:(snd assets.(index)).(last).Data.date
        ~price:(close_at index last) ~desired:0.
    end
  done;
  if !closed_any then
    (match !equity_curve with
     | _ :: rest ->
         equity_curve :=
           ((snd assets.(0)).(last).Data.date, !equity) :: rest
     | [] -> ());
  { equity_curve = List.rev !equity_curve;
    fills = List.rev !fills;
    trips = List.rev !trips }
