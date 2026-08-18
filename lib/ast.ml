type expr =
  | Num of float
  | Var of string
  | Call of string * expr list
  | Unop of string * expr
  | Binop of string * expr * expr

type stmt =
  | Param of string * float
  | Let of string * expr
  | Entry of expr * expr option   (* condition, optional inline size *)
  | Exit of expr * expr option
  | Size of expr                  (* legacy standalone size *)
  | Target of expr
  | Cap of float
  | Stock of string

type file = stmt list
