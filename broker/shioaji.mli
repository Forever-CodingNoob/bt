(** Shioaji server information used to guard live and simulation modes. *)
type info = {
  simulation : bool;
  version : string;
}

(** Shioaji stock snapshot fields used to build a provisional daily bar. *)
type snapshot = {
  datetime : string;
  open_ : float;
  high : float;
  low : float;
  close : float;
  bid : float;
  ask : float;
  total_volume : float;
}

(** One Common-lot stock inventory entry. *)
type position = {
  code : string;
  cond : string;
  lots : int;
  yd_lots : int;
  avg_price : float;
  last_price : float;
  loan_amount : float;
  interest : float;
}

(** Fields supplied for a Common-lot market order. *)
type order_request = {
  exchange : string;
  code : string;
  action : string;
  lots : int;
  cond : string;
  custom_field : string;
}

(** Initial identity and status returned for a submitted order. *)
type placed = {
  order_id : string;
  status : string;
}

(** Order and fill fields used for deduplication and fill reporting. *)
type trade = {
  order_id : string;
  code : string;
  action : string;
  cond : string;
  status : string;
  order_lots : int;
  deal_lots : int;
  deal_price : float option;
  order_datetime : string;
}

(** Shioaji REST root from [SHIOAJI_URL], defaulting to localhost port 8080. *)
val base_url : unit -> string

(** Parse a Shioaji server information response. *)
val parse_info : string -> info

(** Parse a one-element stock snapshot response. *)
val parse_snapshot : string -> snapshot

(** Parse Common-lot stock positions. *)
val parse_positions : string -> position list

(** Parse settlement cash, raising [Failure] with a non-empty broker error. *)
val parse_balance : string -> float

(** Parse the initial result of placing an order. *)
val parse_placed : string -> placed

(** Parse and retain today's trades for one stock code. *)
val parse_orders_today : code:string -> today:string -> string -> trade list

(** Fetch server mode and version information. *)
val info : unit -> info

(** Fetch one stock snapshot. *)
val snapshot : exchange:string -> code:string -> snapshot

(** Fetch Common-lot stock positions from the default account. *)
val positions : unit -> position list

(** Fetch settlement cash from the default stock account. *)
val balance : unit -> float

(** Submit a Common-lot market order through the default stock account. *)
val place_order : order_request -> placed

(** Refresh order status and return today's trades for one stock code. *)
val orders_today : code:string -> today:string -> trade list
