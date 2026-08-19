type expr =
  | Num of float
  | Var of string option * string          (* qualifier, name *)
  | Call of string option * string * expr list
  | Unop of string * expr
  | Binop of string * expr * expr

type stmt =
  | Param of string * float
  | Let of string * expr
  | Entry of string option * expr * expr option  (* alias, condition, inline size *)
  | Exit of string option * expr * expr option
  | Size of string option * expr
  | Target of string option * expr
  | Cap of string option * float
  | Stock of string * string option               (* "market/symbol", alias *)

type file = stmt list
