(** Per-asset target exposure series for a strategy. *)
type strategy = { targets : float array array }

(** Transaction-cost parameters for one asset. *)
type costs = {
  fee_bps : float;
  tax_bps : float;
  slip_bps : float;
  min_fee : float;
}

(** Price used to execute scheduled exposure changes. *)
type fill = Open_next | Close_same

(** One executed exposure change. *)
type fill_event = {
  date : string;
  stock : string;
  price : float;
  from_e : float;
  to_e : float;
}

(** Portfolio margin configuration. [loan_term_months] is the TW
    calendar-month term; US assets always remain open-ended. *)
type margin = {
  financing_rate : float;
  maintenance_ratio : float;
  ratios : float array;
  loan_term_months : int option;
}

(** Margin diagnostics collected during a run. *)
type margin_stats = {
  min_maintenance : float option;
  margin_call_dates : string list;
  clamps : int;
  refinances : int;
}

(** One completed entry-to-exit trade. *)
type trip = {
  entry_date : string;
  exit_date : string;
  net_ret : float;
}

(** Complete outputs and diagnostics from a backtest. *)
type result = {
  equity_curve : (string * float) list;
  fills : fill_event list;
  trips : trip list;
  margin_stats : margin_stats;
}

(** TW collateral-over-loan or US equity-over-required maintenance. *)
type maintenance_model =
  | Collateral_over_loan
  | Equity_over_required

(** Per-market simulation constants. *)
type market_profile = {
  interest_day_count : float;
  settlement_lag : int;
  maintenance : maintenance_model;
  default_financing_rate : float;
}

(** Return the market profile. Fails on unknown markets. *)
val profile_of_market : string -> market_profile

(** Return the default transaction costs for a market and symbol. *)
val default_costs : market:string -> symbol:string -> costs

(** Run a synchronized multi-asset backtest. [dividends] defaults to
    no events. [dividend_tax] is the fraction withheld at creation. *)
val run :
  ?dividends:Data.dividend array array ->
  ?dividend_tax:float ->
  (string * Data.bar array) array ->
  strategy ->
  costs array ->
  profile:market_profile ->
  margin:margin ->
  capital:float option ->
  fill:fill ->
  result
