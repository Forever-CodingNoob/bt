(** Choose an output stem from strategy names or an explicit override. *)
val stem : names:string list -> out_name:string option -> string

(** Print a comparative metrics table and run summary. *)
val print_many :
  columns:(string * Engine.result) list ->
  baseline:Engine.result option ->
  fill:Engine.fill ->
  stocks:(string * string) list ->
  financing_rate:float ->
  unit

(** Write equity and trade CSV artifacts for completed runs. *)
val write_outputs :
  out_dir:string ->
  stem:string ->
  columns:(string * Engine.result) list ->
  baseline:Engine.result option ->
  unit

(** Render an equity CSV to PNG when the plotting script is available. *)
val write_png : out_dir:string -> stem:string -> unit
