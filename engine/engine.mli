(** Per-asset target exposure series for a strategy. *)
type strategy = { targets : float array array }

(** Transaction-cost parameters for one asset. *)
type costs = {
  fee_bps : float;
  tax_bps : float;
  slip_bps : float;
  min_fee : float;
  per_share_sell_fee : float;
  per_share_sell_cap : float;
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
  maintenance_override : float option;
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

(** One asset's frozen sell, refinancing, and buy legs, in account-value units. *)
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

(** Frozen portfolio fill plan before atomic execution. *)
type fill_plan = {
  planned_assets : planned_asset array;
  planned_total_cost : float;
  planned_refinances : bool;
  planned_funding_clamp : bool;
}

(** Explicit account and inventory inputs to the pure fill planner. *)
type plan_state = {
  equity : float;
  cash : float;
  cash_values : float array;
  margin_values : float array;
  loans : float array;
  interests : float array;
  tail_interests : float array;
  debt : float;
  receivables : float;
  previous_targets : float array;
}

(** TW collateral-over-loan or US equity-over-required maintenance. *)
type maintenance_model =
  | Collateral_over_loan
  | Equity_over_required

(** Per-market simulation constants and tradable share quanta. *)
type market_profile = {
  interest_day_count : float;
  settlement_lag : int;
  maintenance : maintenance_model;
  default_financing_rate : float;
  default_financing_ratio : float;
  cash_share_quantum : float;
  (** Minimum cash share increment; zero preserves fractional shares. *)
  margin_share_quantum : float;
  (** Minimum margin share increment; zero preserves fractional shares. *)
}

(** Return the market profile. Fails on unknown markets. *)
val profile_of_market : string -> market_profile

(** Return the default transaction costs for a market and symbol. *)
val default_costs : market:string -> symbol:string -> costs

(** Rounded, floored and optionally capped dollar FINRA sell fee. *)
val taf_dollars : costs -> shares:float -> float

(** Add calendar months to a [YYYY-MM-DD] date, clamping the day to the
    target month's final day. *)
val add_months_clamped : string -> int -> string

(** Fill cost as a fraction of pre-fill equity; capital scales dollar fees.
    capital must be finite and strictly positive. *)
val charge :
  costs array -> float -> int ->
  equity_before:float -> delta:float -> price:float -> float

(** Sell cost in equity units, including capital-scaled dollar fees.
    capital must be finite and strictly positive. *)
val absolute_sell_cost :
  costs array -> float -> int -> price:float -> float -> float

(** Recover the funded whole-share count represented by a value. *)
val shares_of_value : capital:float -> price:float -> float -> float

(** Clamp invalid targets and rescale a bar's portfolio to its funding cap. *)
val effective_targets :
  financing_ratios:float array -> float array -> float array * bool

(** Return the exact pure per-bar fill plan used by [run]; capital must be
    finite and strictly positive. *)
val plan_fills :
  costs:costs array ->
  capital:float ->
  profile:market_profile ->
  financing_ratios:float array ->
  state:plan_state ->
  prices:float array ->
  targets:float array ->
  force:bool ->
  fill_plan

(** Run a synchronized multi-asset backtest. [dividends] defaults to
    no events. [dividend_tax] is the fraction withheld at creation.
    capital must be finite and strictly positive. *)
val run :
  ?dividends:Data.dividend array array ->
  ?dividend_tax:float ->
  (string * Data.bar array) array ->
  strategy ->
  costs array ->
  profile:market_profile ->
  margin:margin ->
  capital:float ->
  fill:fill ->
  result
