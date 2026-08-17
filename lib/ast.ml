type expr =
  | Num of float
  | Var of string
  | Call of string * expr list
  | Unop of string * expr
  | Binop of string * expr * expr

type stmt =
  | Param of string * float
  | Let of string * expr
  | Entry of expr
  | Exit of expr
  | Size of expr

type file = stmt list
