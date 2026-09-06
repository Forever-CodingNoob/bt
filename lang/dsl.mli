(** Parse a strategy source file into its abstract syntax tree. *)
val parse_file : string -> Ast.file

(** Return the declared bar duration in minutes, or [None] for daily strategies.
    A second declaration fails with [duplicate bars declaration]. *)
val timeframe : Ast.file -> int option

(** Extract declared parameter names and defaults in source order. *)
val declared_params_ast : Ast.stmt list -> (string * float) list

(** Resolve stock declarations into aliases, markets, and symbols. *)
val stocks_of :
  filename:string -> Ast.stmt list -> (string option * string * string) list

(** Build engine labels from [stocks_of] output.  When the same
    (market, symbol) pair appears under multiple aliases the label
    gains a [#alias] suffix; otherwise the label is [market/symbol]. *)
val labels_of_stocks : (string option * string * string) list -> string list

(** Compile a parsed strategy against its aliased asset data.
    [extra] injects predefined numeric series of the same length as the assets.
    Session series [since_open] and [to_close] require injection by bt daytrade. *)
val compile_ast :
  ?extra:(string * float array) list ->
  Ast.stmt list ->
  params:(string * float) list ->
  assets:(string option * Data.bar array) list ->
  Engine.strategy

(** Parse and compile a single-asset strategy source file, with optional
    predefined series as in [compile_ast]. *)
val compile :
  ?extra:(string * float array) list ->
  string -> params:(string * float) list -> Data.bar array -> Engine.strategy
