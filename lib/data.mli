(** One dated OHLCV market-data bar. *)
type bar = {
  date : string;
  o : float;
  h : float;
  l : float;
  c : float;
  v : float;
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

(** Load, adjust, and date-filter cached market data. *)
val load :
  market:string ->
  symbol:string ->
  from_:string option ->
  to_:string option ->
  data_dir:string ->
  bar array

(** Retain bars whose dates satisfy the supplied predicate. *)
val filter_dates : keep:(string -> bool) -> bar array -> bar array

(** Return the latest cached financing ratio for a Taiwan symbol. *)
val financing_ratio : data_dir:string -> symbol:string -> float

(** Decide whether a cache needs an earlier-date probe. *)
val should_probe_head : from_:string option -> first_cached:string -> bool

(** Prepend fetched CSV rows before an existing cache seam. *)
val prepend_rows :
  header:string ->
  rows_path:string ->
  cache_path:string ->
  before:string ->
  unit

(** Read cached price bars for a normalized market name. *)
val read_bars : market:string -> string -> bar array

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
