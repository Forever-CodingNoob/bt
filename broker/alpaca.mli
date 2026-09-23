(** Alpaca account mode. *)
type mode = Paper | Live

(** Alpaca market clock fields used by live scheduling. *)
type clock_t = {
  timestamp : string;
  is_open : bool;
  next_open : string;
  next_close : string;
}

(** Alpaca account fields used by live sizing and safety checks. *)
type account_t = {
  equity : float;
  status : string;
  trading_blocked : bool;
  account_number : string;
}

(** Alpaca snapshot fields used to build a provisional daily bar. *)
type snapshot_t = {
  day_date : string;
  prev_day_date : string;
  day_open : float;
  day_high : float;
  day_low : float;
  latest : float;
  day_volume : float;
}

(** Alpaca order fields used for idempotency and fill reporting. *)
type order_t = {
  id : string;
  status : string;
  filled_avg_price : float option;
  filled_qty : float;
}

(** Trading API root for the selected account mode. *)
val base_url : mode -> string

(** Parse a clock response. *)
val parse_clock : string -> clock_t

(** Parse an account response. *)
val parse_account : string -> account_t

(** Parse a position response, mapping HTTP 404 to zero quantity. *)
val parse_position_qty : http_code:int -> string -> float

(** Parse a stock snapshot response. *)
val parse_snapshot : string -> snapshot_t

(** Parse an order response. *)
val parse_order : string -> order_t

(** Fetch the current Alpaca market clock. *)
val clock : mode -> clock_t

(** Fetch the selected Alpaca account. *)
val account : mode -> account_t

(** Fetch the open position quantity for one symbol. *)
val position_qty : mode -> string -> float

(** Fetch an IEX stock snapshot. *)
val snapshot : string -> snapshot_t

(** Format a non-negative share quantity for Alpaca: truncated toward zero at
    Alpaca's 9-decimal qty precision, trailing zeros trimmed. A float that is
    the nearest double to a 9-decimal value formats as that value. Reject
    non-finite quantities and quantities at or above 2^22 shares, where these
    guarantees do not hold. *)
val qty_string : float -> string

(** Build the JSON body of a fractional market day order; [qty] is sent as
    [qty_string qty]. *)
val order_body :
  symbol:string ->
  qty:float ->
  side:[`Buy | `Sell] ->
  client_order_id:string ->
  string

(** Submit a fractional market order with [time_in_force: day]. *)
val submit_market :
  mode ->
  symbol:string ->
  qty:float ->
  side:[`Buy | `Sell] ->
  client_order_id:string ->
  order_t

(** Find an order by its client-supplied identifier. *)
val order_by_client_id : mode -> string -> order_t option

(** Parse regular-session calendar rows from an Alpaca response. *)
val parse_calendar : string -> Data.session list

(** Parse one bars page and its next token, converting UTC timestamps to ET and
    keeping only calendar sessions' inclusive opens and exclusive closes. *)
val parse_bars :
  sessions:Data.session array -> string -> Data.bar list * string option

(** Fetch the exchange calendar from the selected trading host. *)
val calendar : mode -> start:string -> end_:string -> Data.session list

(** Fetch all SIP minute-bar pages, filtering against the supplied calendar. *)
val bars :
  sessions:Data.session array ->
  symbol:string -> start:string -> end_:string -> Data.bar list
