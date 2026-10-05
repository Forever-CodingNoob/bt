(** Alpaca account mode used for live decisions. *)
type mode = Alpaca.mode = Paper | Live

(** One TW stock order, with quantity in lots or shares according to [lot]. *)
type leg = {
  code : string;
  exchange : string;
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
type asset_decision = {
  symbol : string;
  provisional : Data.bar;
  target : float;
  held : float;
  action : action;
}

type decision = {
  fetched_through : string;
  equity : float;
  cash : float;
  debit : float;
  assets : asset_decision array;
  legs : leg list;
}

(** Per-code quote and contract inputs for TW execution. *)
type tw_execution_asset = {
  code : string;
  exchange : string;
  bid : float;
  ask : float;
  price : float;
  financing_ratio : float;
  costs : Engine.costs;
}

(** TW submission result. [remaining] was never posted; [trades] holds
    observed Common statuses. Pending odd ROD orders reconcile after close. *)
type tw_execution = {
  trades : Shioaji.trade list;
  remaining : leg list;
  stop_reason : string option;
  cash : float;
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

(** Build the deterministic daily Alpaca client order identifier. *)
val client_order_id : symbol:string -> date:string -> string

(** Map Alpaca signed cash and holdings at provisional prices to engine
    margin lots with value-proportional debit; unposted interest stays zero.
    Raise [Failure] if [ratio] is non-finite or not positive.
    Raise [Invalid_argument] if the input arrays differ in length. *)
val us_plan_state :
  cash:float -> held:float array -> prices:float array -> ratio:float ->
  previous_targets:float array -> Engine.plan_state

(** Fail closed on unsupported US account states, then jointly plan Alpaca
    orders or skips without broker I/O; return the state used for the decision.
    Raise [Invalid_argument] if the input arrays differ in length. *)
val us_plan_action :
  rebalance:bool -> symbols:string array -> date:string ->
  account:Alpaca.account_t -> position_symbols:string list ->
  held:float array -> prices:float array ->
  targets:float array -> previous_targets:float array ->
  Engine.plan_state * action array


(** Resolve a TW symbol to Shioaji's [TSE] or [OTC] exchange name. *)
val exchange_of_symbol : data_dir:string -> string -> string

(** Require exactly one signed T+0, T+1, and T+2 settlement, then add only
    T+1 and T+2 to the broker balance. T+0 is already reflected in balance. *)
val tw_production_cash :
  balance:float -> settlements:Shioaji.settlement list -> float

(** Value cash and share-unit positions net of loans and interest. *)
val equity_of : cash:float -> positions:Shioaji.position list -> float

(** Convert an N-asset absolute-TWD plan to code-tagged Common and cash
    IntradayOdd orders in sell, refinance-pair, then buy groups.
    Assets follow declaration order within each group, lots before odd shares.
    Raise [Failure] if any input array length differs from the planned assets. *)
val legs_of_plan :
  codes:string array -> exchanges:string array -> prices:float array ->
  Engine.fill_plan -> leg list

(** Validate the strategy's TW position set and aggregate per symbol at its
    provisional price: cash shares, margin shares, cash value, margin value,
    loans, and interests. Foreign inactive rows are ignored.
    Raise [Failure] for mismatched array lengths or repeated symbols. *)
val position_totals :
  symbols:string array -> prices:float array -> Shioaji.position list ->
  (float * float * float * float * float * float) array

(** Return 18-calendar-month TW margin-lot sell/rebuy rollover pairs in
    broker detail order. *)
val maturity_rollover_legs :
  session_date:string ->
  symbol:string ->
  exchange:string ->
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

(** Ordinary Common sells/buys place then batch-poll; rollover/refinance
    pairs are sequential. Odd ROD sells are unpolled and provide no
    same-session cash. Every leg must match one declared execution asset.
    Result cash includes pending-buy reservations. *)
val execute_tw_legs :
  mode:mode -> assets:tw_execution_asset array ->
  now:(unit -> string) -> sleep:(float -> unit) ->
  place_order:(Shioaji.order_request -> Shioaji.placed) ->
  orders_today:(code:string -> today:string -> Shioaji.trade list) ->
  date:string -> cash:float -> positions:Shioaji.position list ->
  leg list -> tw_execution

val strategy_market : (string option * string * string) list -> string
val align_history :
  symbols:string array -> Data.bar array list -> string * Data.bar array list

(** Select the next daemon phase from RFC3339 clock timestamps. *)
val next_actions :
  now:string ->
  next_close:string ->
  [`Sleep_until of string | `Decide | `Cutoff_passed | `Post_close]

(** Log a US decision after its pre-submit checks succeed. Submit an order
    only while the market is open and before the cutoff 2 minutes before
    [next_close]. A failed or rejected order request is logged with
    [order=skip] and is not retried; after the cutoff, log
    [error=submit cutoff passed order=skip]. The broker calls default to
    [Alpaca]. *)
val execute_decision :
  ?existing:(string * Alpaca.order_t) list ->
  ?sleep:(float -> unit) ->
  ?finish:(string -> string -> string -> Alpaca.order_t -> unit) ->
  ?order_by_client_id:(mode -> string -> Alpaca.order_t option) ->
  ?clock:(mode -> Alpaca.clock_t) ->
  ?submit_market:
    (mode -> symbol:string -> qty:float -> side:[`Buy | `Sell] ->
     client_order_id:string -> Alpaca.order_t) ->
  mode -> string -> string -> decision -> unit

(** Advance one US daemon clock with injected broker and scheduling actions. *)
val us_step :
  symbols:string array ->
  lookup:(string -> Alpaca.order_t option) ->
  decide:(string -> decision) ->
  execute:((string * Alpaca.order_t) list -> Alpaca.clock_t -> decision -> unit) ->
  finish:(Alpaca.clock_t -> string -> string -> Alpaca.order_t -> unit) ->
  sleep_until:(string -> unit) -> retry:(unit -> unit) ->
  continue:(unit -> unit) -> Alpaca.clock_t -> unit

(** Extract the calendar date prefix from an RFC3339 timestamp. *)
val timestamp_date : string -> string

(** Reject inactive or trading-blocked Alpaca accounts before startup. *)
val startup_ok : Alpaca.account_t -> (unit, string) result

(** Require the current Shioaji server mode to match the CLI mode. *)
val tw_server_mode_ok : mode -> Shioaji.info -> (unit, string) result

(** Require CLI mode, equity source, and Shioaji server mode to agree. *)
val tw_startup_ok :
  mode -> equity:float option -> Shioaji.info -> (unit, string) result

(** Log each contract, reject suspended symbols, then check all cash and margin
    buy holds separately without sell offsets, rollover and refinance rebuys included.
    Common buys use the upper band (reference times 1.10 if absent); odd buys
    use the snapshot ask. Reject non-finite or non-positive buy prices and
    non-finite or negative hold sums or allowances with [Failure]. *)
val check_tw_budget :
  log:(string -> unit) -> symbols:string array ->
  snapshots:Shioaji.snapshot array -> contract_infos:Shioaji.contract_info array ->
  limits:Shioaji.trading_limits -> leg list -> unit

(** Compute one live decision without submitting an order. TW production
    checks contract suspensions and the complete buy budget before returning;
    Paper does not read contract info or limits. Audit logs default to stderr. *)
val decide :
  ?provisional_close:float ->
  ?previous_session:string ->
  ?equity:float ->
  ?tw_balance:float ->
  ?tw_settlements:Shioaji.settlement list ->
  ?tw_positions:Shioaji.position list ->
  ?tw_position_details:Shioaji.position_detail list ->
  ?tw_snapshots:Shioaji.snapshot array ->
  ?tw_contract_infos:Shioaji.contract_info array ->
  ?tw_trading_limits:Shioaji.trading_limits ->
  ?tw_log:(string -> unit) ->
  mode ->
  session_date:string ->
  strat_path:string ->
  data_dir:string ->
  decision

(** Retry the clock every 60 seconds, then dispatch the recovered clock once. *)
val retry_clock :
  clock:(unit -> Alpaca.clock_t) ->
  sleep:(float -> unit) ->
  dispatch:(Alpaca.clock_t -> unit) ->
  unit

(** Lock one market and daemon mode until the returned descriptor is closed. *)
val lock_daemon :
  directory:string -> market:string -> mode -> Unix.file_descr

(** Run the live trading daemon until the process is stopped. *)
val run :
  ?equity:float -> mode -> strat_path:string -> data_dir:string -> unit
