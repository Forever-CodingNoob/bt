(** One dated OHLCV market-data bar. *)
type bar = {
  date : string;
  o : float;
  h : float;
  l : float;
  c : float;
  v : float;
}

(** One dated cash dividend. *)
type dividend = {
  ex_date : string;
  cash_per_share : float;
  pay_date : string;
}

(** The execution, signal, and cash-event planes for one asset. *)
type loaded_asset = {
  money : bar array;
  signal : bar array;
  dividends : dividend array;
}


(** Create a directory and any missing parents. *)
val mkdir_p : string -> unit

(** Fetch and cache market data for a symbol and date range. *)
val fetch :
  market:string ->
  symbol:string ->
  from_:string option ->
  to_:string ->
  data_dir:string ->
  unit

(** Load both price planes and dated dividend cash events. *)
val load_asset :
  market:string ->
  symbol:string ->
  from_:string option ->
  to_:string option ->
  data_dir:string ->
  loaded_asset


(** Retain bars whose dates satisfy the supplied predicate. *)
val filter_dates : keep:(string -> bool) -> bar array -> bar array

(** Return the financing ratio for a symbol: US defaults to Reg T 50%,
    TW resolves from cached stockinfo or falls back to TWSE 60%. *)
val financing_ratio : market:string -> data_dir:string -> symbol:string -> float

(** Decide whether a cache needs an earlier-date probe. *)
val should_probe_head : from_:string option -> first_cached:string -> bool

(** Prepend fetched CSV rows before an existing cache seam. *)
val prepend_rows :
  header:string ->
  rows_path:string ->
  cache_path:string ->
  before:string ->
  unit

(** Append fetched CSV rows after an existing cache tail. *)
val append_rows :
  header:string ->
  rows_path:string ->
  cache_path:string ->
  after:string option ->
  unit

(** Read cached price bars (date,open,high,low,close,volume). *)
val read_bars : market:string -> string -> bar array

(** Read a cash-dividend cache, filling missing pay dates. *)
val read_cash_dividends : string -> dividend array

(** Derive TW cash dividends from raw bars and signal factors. *)
val derive_cash_dividends :
  bar array ->
  (string * float) array ->
  dividend array

(** Merge derived rows into a TW cash-dividend cache by ex-date. *)
val merge_cash_dividend_cache :
  dividend array ->
  cache_path:string ->
  unit

(** Snap a split factor to the nearest p/q with p,q at most 50 when within 1e-4. *)
val snap_split_factor : float -> float

(** Parse a Tiingo CSV response and write the four canonical cache files. *)
val write_tiingo_rows :
  csv_path:string ->
  prev_close:float option ->
  prices_path:string ->
  events_path:string ->
  cashdiv_path:string ->
  div_path:string ->
  unit


(** Back-adjust bars in place using dated multiplicative factors. *)
val back_adjust : bar array -> (string * float) array -> unit

(** FinMind event datasets and their before/after price fields. *)
val event_sources : (string * string * string * bool) list

(** Build the jq expression for a corporate-action event dataset. *)
val event_expression : before:string -> after:string -> string

(** Convert a FinMind JSON response into rows using jq. *)
val transform_json :
  args:string list ->
  expression:string ->
  json_path:string ->
  rows_path:string ->
  unit
