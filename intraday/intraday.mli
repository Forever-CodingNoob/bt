(** Intraday sizing uses exposure units; capital scales dollar-based costs. *)
type config = {
  fill : Engine.fill;
  leverage : float;
  costs : Engine.costs;
  capital : float;
}

(** Executed change, timestamped with the execution bar's left edge. *)
type fill = {
  time : string;
  price : float;
  from_exposure : float;
  to_exposure : float;
}

(** One equity point per calendar session containing regular-hours bars.
    Trades are flat-to-flat round trips; wins have positive net cash P&L. *)
type result = {
  session_dates : string array;
  equity : float array;
  fills : fill list;
  trades : int;
  wins : int;
  flat_forced : int;
}

(** Run chronological resampled bars against a chronological calendar.
    Targets correspond one-to-one to bars. NaN is flat; negative decisions fail.
    Changed targets use post-cost equity, capped by previous-close buying
    power. Unchanged targets drift without rebalancing or liquidation.
    Last-bar decisions are ignored and positions close at that bar's close.
    Empty calendar sessions are omitted. Initial equity is in exposure units,
    with dollar value [initial_equity * capital]. *)
val run :
  config -> sessions:Data.session array -> bars:Data.bar array ->
  targets:float array -> initial_equity:float -> result
