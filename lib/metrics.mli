(** Summary performance metrics for a backtest result. *)
type t = {
  total_return : float;
  cagr : float;
  sharpe : float;
  max_dd : float;
  calmar : float option;
  n_trades : int;
  win_rate : float option;
}

(** Calculate summary metrics from an engine result. *)
val of_result : Engine.result -> t
