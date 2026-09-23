(** Alpaca account mode used for live decisions. *)
type mode = Alpaca.mode = Paper | Live

(** One TW stock order, with quantity in lots or shares according to [lot]. *)
type leg = {
  action : string;
  cond : string;
  lot : Shioaji.lot;
  quantity : int;
}


(** A fractional-share order or the reason no order is needed. *)
type action =
  | Order of {
      side : [`Buy | `Sell];
      qty : float;
      id : string;
    }
  | Skip of string
  | Orders of leg list

(** Inputs and result of one live decision cycle before submission. *)
type decision = {
  fetched_through : string;
  provisional : Data.bar;
  target : float;
  equity : float;
  held : float;
  action : action;
}

(** TW submission result. [remaining] was never posted; [trades] holds
    observed Common statuses. Pending odd ROD orders reconcile after close. *)
type tw_execution = {
  trades : Shioaji.trade list;
  remaining : leg list;
  stop_reason : string option;
}

(** Build today's provisional OHLCV bar from an Alpaca snapshot. *)
val provisional_bar : Alpaca.snapshot_t -> Data.bar

(** Build a local provisional snapshot at an explicit closing price. *)
val override_snapshot :
  session_date:string ->
  prev_day_date:string ->
  price:float ->
  Alpaca.snapshot_t

(** Whether the cache ends at the previous trading session. *)
val cache_is_fresh : last_cached:string -> prev_trading_day:string -> bool

(** Reject snapshots whose daily bar does not match the clock session. *)
val snapshot_session :
  session_date:string ->
  provisional_date:string ->
  [`Proceed | `Skip of string]

(** Convert target exposure to fractional shares. *)
val desired_shares : target:float -> equity:float -> price:float -> float

(** Difference between desired and held shares. *)
val order_delta : desired:float -> held:float -> float

(** Whether a buy's absolute notional is below one dollar; sells never are. *)
val below_threshold :
  side:[`Buy | `Sell] -> delta:float -> price:float -> bool

(** Build the deterministic daily Alpaca client order identifier. *)
val client_order_id : symbol:string -> date:string -> string

(** Size a decision and return its order or minimum-value skip. Quantities are
    truncated to Alpaca's 9 decimals; sells never exceed [held]. *)
val decide_action :
  symbol:string ->
  date:string ->
  target:float ->
  equity:float ->
  price:float ->
  held:float ->
  action


(** Resolve a TW symbol to Shioaji's [TSE] or [OTC] exchange name. *)
val exchange_of_symbol : data_dir:string -> string -> string

(** Require exactly one signed T+0, T+1, and T+2 settlement, then add only
    T+1 and T+2 to the broker balance. T+0 is already reflected in balance. *)
val tw_production_cash :
  balance:float -> settlements:Shioaji.settlement list -> float

(** Value cash and share-unit positions net of loans and interest. *)
val equity_of : cash:float -> positions:Shioaji.position list -> float

(** Convert a one-asset absolute-TWD plan to Common and cash IntradayOdd
    orders, preserving refinance sell-and-rebuy pairs. *)
val legs_of_plan : price:float -> Engine.fill_plan -> leg list

(** Return 18-calendar-month TW margin-lot sell/rebuy rollover pairs in
    broker detail order. *)
val maturity_rollover_legs :
  session_date:string ->
  symbol:string ->
  Shioaji.position_detail list ->
  leg list

(** Fetch each margin position's dated details and reject detail lots whose
    cumulative share count exceeds that position's Share-unit holding. *)
val fetch_position_details :
  ?position_details:(detail_id:int -> Shioaji.position_detail list) ->
  string -> Shioaji.position list -> Shioaji.position_detail list

(** Select the TW daemon phase from an RFC3339 instant in Taipei time. *)
val taipei_phase :
  now:string ->
  [`Weekend | `Before_fetch | `Fetch | `Decide | `After_close]

(** Submit TW legs in order. Common fills settle before the next leg;
    intraday-odd ROD orders reserve buy cash without waiting for final fills. *)
val execute_tw_legs :
  ?log_odd:(string -> unit) ->
  mode:mode ->
  bid:float ->
  ask:float ->
  now:(unit -> string) ->
  sleep:(float -> unit) ->
  place_order:(Shioaji.order_request -> Shioaji.placed) ->
  orders_today:(code:string -> today:string -> Shioaji.trade list) ->
  exchange:string ->
  code:string ->
  date:string ->
  price:float ->
  financing_ratio:float ->
  costs:Engine.costs ->
  cash:float ->
  positions:Shioaji.position list ->
  leg list ->
  tw_execution

(** Select the next daemon phase from RFC3339 clock timestamps. *)
val next_actions :
  now:string ->
  next_close:string ->
  [`Sleep_until of string | `Decide | `Cutoff_passed | `Post_close]

(** Log a US decision and, unless today's client order ID already exists,
    submit its market order only while the market is open and before the
    submit cutoff 10 minutes before [next_close]; otherwise log
    [error=submit cutoff passed order=skip]. The broker calls default to
    [Alpaca]. *)
val execute_decision :
  ?order_by_client_id:(mode -> string -> Alpaca.order_t option) ->
  ?clock:(mode -> Alpaca.clock_t) ->
  ?submit_market:
    (mode ->
     symbol:string ->
     qty:float ->
     side:[`Buy | `Sell] ->
     client_order_id:string ->
     Alpaca.order_t) ->
  mode -> string -> string -> decision -> unit

(** Extract the calendar date prefix from an RFC3339 timestamp. *)
val timestamp_date : string -> string

(** Reject inactive or trading-blocked Alpaca accounts before startup. *)
val startup_ok : Alpaca.account_t -> (unit, string) result

(** Require the current Shioaji server mode to match the CLI mode. *)
val tw_server_mode_ok : mode -> Shioaji.info -> (unit, string) result

(** Require CLI mode, equity source, and Shioaji server mode to agree. *)
val tw_startup_ok :
  mode -> equity:float option -> Shioaji.info -> (unit, string) result

(** Compute one live decision without submitting an order. *)
val decide :
  ?provisional_close:float ->
  ?previous_session:string ->
  ?equity:float ->
  ?tw_balance:float ->
  ?tw_settlements:Shioaji.settlement list ->
  ?tw_positions:Shioaji.position list ->
  ?tw_position_details:Shioaji.position_detail list ->
  ?tw_snapshot:Shioaji.snapshot ->
  mode ->
  session_date:string ->
  strat_path:string ->
  data_dir:string ->
  decision

(** Run the live trading daemon until the process is stopped. *)
val run :
  ?equity:float -> mode -> strat_path:string -> data_dir:string -> unit
