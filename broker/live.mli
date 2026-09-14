(** Alpaca account mode used for live decisions. *)
type mode = Alpaca.mode = Paper | Live

(** One Shioaji Common-lot order leg. *)
type leg = {
  action : string;
  cond : string;
  lots : int;
}


(** A whole-share order or the reason no order is needed. *)
type action =
  | Order of {
      side : [`Buy | `Sell];
      qty : int;
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

(** Result of submitting a TW plan sequentially. [remaining] was never posted;
    [trades] contains the final observed status for every posted leg. *)
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

(** Convert target exposure to whole shares, truncating toward zero. *)
val desired_shares : target:float -> equity:float -> price:float -> int

(** Difference between desired shares and the rounded held quantity. *)
val order_delta : desired:int -> held:float -> int

(** Whether an order's absolute notional is below one dollar. *)
val below_threshold : delta:int -> price:float -> bool

(** Build the deterministic daily Alpaca client order identifier. *)
val client_order_id : symbol:string -> date:string -> string

(** Size a decision and return its order or minimum-value skip. *)
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

(** Value cash and Common-lot positions net of broker loans and interest. *)
val equity_of : balance:float -> positions:Shioaji.position list -> float

(** Convert a one-asset value-denominated plan to board-lot order legs,
    retaining each cash and margin refinance sell-and-rebuy pair. *)
val legs_of_plan : price:float -> Engine.fill_plan -> leg list

(** Return 18-calendar-month TW margin-lot sell/rebuy rollover pairs in
    broker detail order. *)
val maturity_rollover_legs :
  session_date:string ->
  symbol:string ->
  Shioaji.position_detail list ->
  leg list

(** Select the TW daemon phase from an RFC3339 instant in Taipei time. *)
val taipei_phase :
  now:string ->
  [`Weekend | `Before_fetch | `Fetch | `Decide | `After_close]

(** Submit TW legs in order with a fresh time check and fill confirmation
    before each successor. Buy quantities are capped to confirmed cash while
    margin principal and interest follow confirmed inventory changes. *)
val execute_tw_legs :
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
  [`Sleep_until of string | `Decide | `Submit_window | `Post_close]

(** Whether an MOC may still be submitted for this session. *)
val can_submit_moc : now:string -> next_close:string -> bool

(** Extract the calendar date prefix from an RFC3339 timestamp. *)
val timestamp_date : string -> string

(** Reject inactive or trading-blocked Alpaca accounts before startup. *)
val startup_ok : Alpaca.account_t -> (unit, string) result

(** Require CLI mode, equity source, and Shioaji server mode to agree. *)
val tw_startup_ok :
  mode -> equity:float option -> Shioaji.info -> (unit, string) result

(** Compute one live decision without submitting an order. *)
val decide :
  ?provisional_close:float ->
  ?previous_session:string ->
  ?equity:float ->
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
