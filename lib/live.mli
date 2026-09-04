(** Alpaca account mode used for live decisions. *)
type mode = Alpaca.mode = Paper | Live

(** A whole-share order or the reason no order is needed. *)
type action =
  | Order of {
      side : [`Buy | `Sell];
      qty : int;
      id : string;
    }
  | Skip of string

(** Inputs and result of one live decision cycle before submission. *)
type decision = {
  fetched_through : string;
  provisional : Data.bar;
  target : float;
  equity : float;
  held : float;
  action : action;
}

(** Build today's provisional OHLCV bar from an Alpaca snapshot. *)
val provisional_bar : Alpaca.snapshot_t -> Data.bar

(** Whether the cache ends at the previous trading session. *)
val cache_is_fresh : last_cached:string -> prev_trading_day:string -> bool

(** Convert target exposure to whole shares, truncating toward zero. *)
val desired_shares : target:float -> equity:float -> price:float -> int

(** Difference between desired shares and the rounded held quantity. *)
val order_delta : desired:int -> held:float -> int

(** Whether an order's absolute notional is below one dollar. *)
val below_threshold : delta:int -> price:float -> bool

(** Build the deterministic daily Alpaca client order identifier. *)
val client_order_id : symbol:string -> date:string -> string

(** Compute one live decision without submitting an order. *)
val decide : mode -> strat_path:string -> data_dir:string -> decision
