type strategy = { target : float array }

type costs = {
  fee_bps : float;
  tax_bps : float;
  slip_bps : float;
}

type fill = Open_next | Close_same

type fill_event = {
  date : string;
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
  | "us" -> { fee_bps = 0.; tax_bps = 0.; slip_bps = 0. }
  | "tw" ->
      let is_etf =
        String.length symbol >= 2 && symbol.[0] = '0' && symbol.[1] = '0'
      in
      { fee_bps = 14.25;
        tax_bps = if is_etf then 10. else 30.;
        slip_bps = 0. }
  | _ -> invalid_arg "Engine.default_costs: market must be tw or us"

(* NaN means flat; short exposure is out of scope *)
let clamp_target value =
  if Float.is_nan value || value < 0. then 0. else value

let run (bars : Data.bar array) (strategy : strategy) (costs : costs) ~fill =
  let length = Array.length bars in
  if Array.length strategy.target <> length then
    invalid_arg "Engine.run: target length mismatch";
  let equity = ref 1. in
  let exposure = ref 0. in
  let entry_equity = ref 1. in
  let entry_date = ref "" in
  let fills = ref [] in
  let trips = ref [] in
  let equity_curve = ref [] in
  let trade ~date ~price ~desired =
    let delta = desired -. !exposure in
    if delta <> 0. then begin
      if !exposure = 0. then begin
        entry_equity := !equity;
        entry_date := date
      end;
      let bps =
        if delta > 0. then costs.fee_bps +. costs.slip_bps
        else costs.fee_bps +. costs.tax_bps +. costs.slip_bps
      in
      equity := !equity *. (1. -. abs_float delta *. bps /. 10000.);
      fills := { date; price; from_e = !exposure; to_e = desired } :: !fills;
      exposure := desired;
      if desired = 0. then
        trips :=
          { entry_date = !entry_date; exit_date = date;
            net_ret = !equity /. !entry_equity -. 1. } :: !trips
    end
  in
  for t = 0 to length - 1 do
    let bar = bars.(t) in
    (match fill with
     | Close_same ->
         if t > 0 then
           equity :=
             !equity *.
             (1. +. !exposure *. (bar.Data.c /. bars.(t - 1).Data.c -. 1.));
         trade ~date:bar.Data.date ~price:bar.Data.c
           ~desired:(clamp_target strategy.target.(t))
     | Open_next ->
         if t > 0 then begin
           let desired = clamp_target strategy.target.(t - 1) in
           if desired <> !exposure then begin
             (* two-leg day: accrue to the open, fill, accrue to the close *)
             equity :=
               !equity *.
               (1. +. !exposure *. (bar.Data.o /. bars.(t - 1).Data.c -. 1.));
             trade ~date:bar.Data.date ~price:bar.Data.o ~desired;
             equity :=
               !equity *.
               (1. +. !exposure *. (bar.Data.c /. bar.Data.o -. 1.))
           end
           else
             equity :=
               !equity *.
               (1. +. !exposure *. (bar.Data.c /. bars.(t - 1).Data.c -. 1.))
         end);
    equity_curve := (bar.Data.date, !equity) :: !equity_curve
  done;
  if !exposure > 0. then begin
    let last = bars.(length - 1) in
    let bps = costs.fee_bps +. costs.tax_bps +. costs.slip_bps in
    equity := !equity *. (1. -. !exposure *. bps /. 10000.);
    fills :=
      { date = last.Data.date; price = last.Data.c;
        from_e = !exposure; to_e = 0. } :: !fills;
    trips :=
      { entry_date = !entry_date; exit_date = last.Data.date;
        net_ret = !equity /. !entry_equity -. 1. } :: !trips;
    (match !equity_curve with
     | _ :: rest -> equity_curve := (last.Data.date, !equity) :: rest
     | [] -> ())
  end;
  { equity_curve = List.rev !equity_curve;
    fills = List.rev !fills;
    trips = List.rev !trips }
