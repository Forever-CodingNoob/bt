type strategy = {
  entry : bool array;
  exit_ : bool array;
  size : float array;
}

type costs = {
  fee_bps : float;
  tax_bps : float;
  slip_bps : float;
}

type trade = {
  entry_date : string;
  entry_px : float;
  exit_date : string;
  exit_px : float;
  net_ret : float;
}

type result = {
  equity_curve : (string * float) list;
  trades : trade list;
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

let side_cost exposure bps = exposure *. bps /. 10000.

let run (bars : Data.bar array) (strategy : strategy) (costs : costs) =
  let length = Array.length bars in
  if Array.length strategy.entry <> length ||
     Array.length strategy.exit_ <> length ||
     Array.length strategy.size <> length then
    invalid_arg "Engine.run: strategy length mismatch";
  let equity = ref 1. in
  let in_position = ref false in
  let exposure = ref 1. in
  let entry_date = ref "" in
  let entry_price = ref 0. in
  let entry_equity = ref 1. in
  let equity_curve = ref [] in
  let trades = ref [] in
  for t = 0 to length - 1 do
    let bar = bars.(t) in
    if t > 0 then begin
      let previous = bars.(t - 1) in
      if !in_position then begin
        if strategy.exit_.(t - 1) then begin
          equity :=
            !equity *.
            (1. +. !exposure *. (bar.Data.o /. previous.Data.c -. 1.));
          equity :=
            !equity *.
            (1. -. side_cost !exposure
                      (costs.fee_bps +. costs.tax_bps +. costs.slip_bps));
          trades :=
            { entry_date = !entry_date;
              entry_px = !entry_price;
              exit_date = bar.Data.date;
              exit_px = bar.Data.o;
              net_ret = !equity /. !entry_equity -. 1. } :: !trades;
          in_position := false
        end
        else
          equity :=
            !equity *.
            (1. +. !exposure *. (bar.Data.c /. previous.Data.c -. 1.))
      end
      else if strategy.entry.(t - 1) then begin
        let requested = strategy.size.(t - 1) in
        exposure :=
          if Float.is_nan requested || requested <= 0. then 1. else requested;
        entry_date := bar.Data.date;
        entry_price := bar.Data.o;
        entry_equity := !equity;
        equity :=
          !equity *.
          (1. -. side_cost !exposure (costs.fee_bps +. costs.slip_bps));
        equity :=
          !equity *. (1. +. !exposure *. (bar.Data.c /. bar.Data.o -. 1.));
        in_position := true
      end
    end;
    equity_curve := (bar.Data.date, !equity) :: !equity_curve
  done;
  if !in_position then begin
    equity :=
      !equity *.
      (1. -. side_cost !exposure
                (costs.fee_bps +. costs.tax_bps +. costs.slip_bps));
    let final_bar = bars.(length - 1) in
    begin
      match !equity_curve with
      | _ :: rest ->
          equity_curve := (final_bar.Data.date, !equity) :: rest
      | [] -> ()
    end;
    trades :=
      { entry_date = !entry_date;
        entry_px = !entry_price;
        exit_date = final_bar.Data.date;
        exit_px = final_bar.Data.c;
        net_ret = !equity /. !entry_equity -. 1. } :: !trades
  end;
  { equity_curve = List.rev !equity_curve;
    trades = List.rev !trades }
