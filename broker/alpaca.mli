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
  cash : float;
  long_market_value : float;
  short_market_value : float;
  initial_margin : float;
  shorting_enabled : bool;
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
  side : string;
  filled_avg_price : float option;
  filled_qty : float;
}

(** One row of an order listing: the client identifier and submission time
    that anchor an overnight series, with the order fields. *)
type listed_t = {
  client_order_id : string;
  submitted_at : string;
  qty : float;
  order : order_t;
}

(** Alpaca asset flags that gate a short sale. *)
type asset_t = {
  shortable : bool;
  easy_to_borrow : bool;
}

(** Trading API root for the selected account mode. *)
val base_url : mode -> string

(** Parse a clock response. *)
val parse_clock : string -> clock_t

(** Parse an account response. *)
val parse_account : string -> account_t

(** Parse a position response, mapping HTTP 404 to zero quantity. *)
val parse_position_qty : http_code:int -> string -> float

(** Parse open position symbols, retaining response order. *)
val parse_positions : string -> string list

(** Parse a stock snapshot response. *)
val parse_snapshot : string -> snapshot_t

(** Parse an order response. *)
val parse_order : string -> order_t

(** Parse an order listing in response order; a null client id reads as
    ["-"]. *)
val parse_orders : string -> listed_t list

(** Parse an asset response. *)
val parse_asset : string -> asset_t

(** Map a cancel response: 204 canceled and 422 not cancelable both succeed,
    since neither proves a final state; any other code fails. *)
val parse_cancel : http_code:int -> unit

(** Fetch the current Alpaca market clock. *)
val clock : mode -> clock_t

(** Fetch the selected Alpaca account. *)
val account : mode -> account_t

(** Fetch all open position symbols from the selected account. *)
val positions : mode -> string list

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

(** Request cancellation of an order by its Alpaca id ([DELETE /v2/orders/ID]);
    see [parse_cancel] for the accepted responses. *)
val cancel_order : mode -> string -> unit

(** Find an order by its Alpaca id; 404 is [None]. *)
val order_by_id : mode -> string -> order_t option

(** Build the listing path of one symbol's open orders, whatever their
    client ids: 500 rows, newest first, before the exclusive [until] when
    given. *)
val open_orders_path : symbol:string -> until:string option -> string

(** List every open order of one symbol, newest first, paging with [until]
    set to the last row's [submitted_at] until a page is shorter than 500
    rows. [page] fetches one path and defaults to the trading API. *)
val open_orders : ?page:(string -> listed_t list) -> mode -> string -> listed_t list

(** Fetch the shortability flags of one symbol. *)
val asset : mode -> string -> asset_t

(** Build the listing path: all statuses, 500 rows, newest first, submitted
    after [after] (and before the exclusive [until] when given), on the
    comma-joined [symbols]. *)
val orders_path :
  symbols:string list -> after:string -> until:string option -> string

(** List every order on [symbols] submitted after [after], newest first,
    paging with [until] set to the last row's [submitted_at] until a page is
    shorter than 500 rows. [page] fetches one path and defaults to the
    trading API. *)
val list_orders :
  ?page:(string -> listed_t list) ->
  mode -> symbols:string list -> after:string -> listed_t list

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
