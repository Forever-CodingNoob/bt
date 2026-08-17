type t = {
  total_return : float;
  cagr : float;
  sharpe : float;
  max_dd : float;
  calmar : float option;
  n_trades : int;
  win_rate : float option;
}

let last_equity = function
  | [] -> 1.
  | first :: rest ->
      snd (List.fold_left (fun _ point -> point) first rest)

let total_return equity_curve = last_equity equity_curve -. 1.

let leap_year year =
  year mod 400 = 0 || (year mod 4 = 0 && year mod 100 <> 0)

let days_in_month year = function
  | 1 | 3 | 5 | 7 | 8 | 10 | 12 -> 31
  | 4 | 6 | 9 | 11 -> 30
  | 2 -> if leap_year year then 29 else 28
  | _ -> 0

let epoch_days value =
  let invalid () = invalid_arg (Printf.sprintf "invalid date %S" value) in
  if String.length value <> 10 || value.[4] <> '-' || value.[7] <> '-' then
    invalid ();
  let year, month, day =
    try
      (int_of_string (String.sub value 0 4),
       int_of_string (String.sub value 5 2),
       int_of_string (String.sub value 8 2))
    with Failure _ -> invalid ()
  in
  if year < 1 || month < 1 || month > 12 || day < 1 ||
     day > days_in_month year month then
    invalid ();
  let month_offsets = [|0; 31; 59; 90; 120; 151; 181; 212; 243; 273; 304; 334|] in
  let previous_year = year - 1 in
  365 * previous_year + previous_year / 4 - previous_year / 100 +
  previous_year / 400 + month_offsets.(month - 1) + day - 1 +
  (if month > 2 && leap_year year then 1 else 0)

let curve_endpoints = function
  | [] -> None
  | first :: rest ->
      Some (first, List.fold_left (fun _ point -> point) first rest)

let cagr equity_curve =
  match curve_endpoints equity_curve with
  | None -> 0.
  | Some ((first_date, _), (last_date, ending)) ->
      let days = epoch_days last_date - epoch_days first_date in
      if days <= 0 then 0.
      else ending ** (365.25 /. float_of_int days) -. 1.

let daily_returns equity_curve =
  let values = Array.of_list equity_curve in
  let length = Array.length values in
  let returns = Array.make (max 0 (length - 1)) 0. in
  for i = 1 to length - 1 do
    returns.(i - 1) <- snd values.(i) /. snd values.(i - 1) -. 1.
  done;
  returns

let sharpe_from_returns returns =
  let length = Array.length returns in
  if length < 2 then 0.
  else begin
    let sum = ref 0. in
    for i = 0 to length - 1 do
      sum := !sum +. returns.(i)
    done;
    let mean = !sum /. float_of_int length in
    let squared = ref 0. in
    for i = 0 to length - 1 do
      let difference = returns.(i) -. mean in
      squared := !squared +. difference *. difference
    done;
    let standard_deviation = sqrt (!squared /. float_of_int (length - 1)) in
    if standard_deviation = 0. then 0.
    else mean /. standard_deviation *. sqrt 252.
  end

let sharpe equity_curve = sharpe_from_returns (daily_returns equity_curve)

let max_dd = function
  | [] -> 0.
  | (_, first_equity) :: rest ->
      snd
        (List.fold_left
           (fun (running_max, worst) (_, equity) ->
             let running_max = max running_max equity in
             let drawdown = 1. -. equity /. running_max in
             running_max, max worst drawdown)
           (first_equity, 0.) rest)

let calmar equity_curve =
  let drawdown = max_dd equity_curve in
  if drawdown = 0. then None else Some (cagr equity_curve /. drawdown)

let n_trades trips = List.length trips

let win_rate trips =
  match trips with
  | [] -> None
  | _ ->
      let winners =
        List.fold_left
          (fun count (trip : Engine.trip) ->
            if trip.net_ret > 0. then count + 1 else count)
          0 trips
      in
      Some (float_of_int winners /. float_of_int (List.length trips))

let calculate equity_curve trips =
  { total_return = total_return equity_curve;
    cagr = cagr equity_curve;
    sharpe = sharpe equity_curve;
    max_dd = max_dd equity_curve;
    calmar = calmar equity_curve;
    n_trades = n_trades trips;
    win_rate = win_rate trips }

let of_result (result : Engine.result) =
  calculate result.equity_curve result.trips
