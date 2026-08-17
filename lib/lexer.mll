{
open Parser

let keyword = function
  | "param" -> PARAM
  | "let" -> LET
  | "entry" -> ENTRY
  | "exit" -> EXIT
  | "size" -> SIZE
  | "when" -> WHEN
  | "and" -> AND
  | "or" -> OR
  | "not" -> NOT
  | name -> IDENT name
}

let digit = ['0'-'9']
let digits = digit+
let exponent = ['e' 'E'] ['+' '-']? digits
let number = (digits ('.' digit*)? | '.' digits) exponent?
let ident_start = ['A'-'Z' 'a'-'z' '_']
let ident_char = ['A'-'Z' 'a'-'z' '0'-'9' '_']

rule token = parse
  | [' ' '\t' '\r'] { token lexbuf }
  | '\n' { Lexing.new_line lexbuf; token lexbuf }
  | '#' [^ '\n']* { token lexbuf }
  | "==" { EQEQ }
  | "!=" { NEQ }
  | "<=" { LE }
  | ">=" { GE }
  | '=' { ASSIGN }
  | '<' { LT }
  | '>' { GT }
  | '+' { PLUS }
  | '-' { MINUS }
  | '*' { STAR }
  | '/' { SLASH }
  | '(' { LPAREN }
  | ')' { RPAREN }
  | ',' { COMMA }
  | number as value { NUMBER (float_of_string value) }
  | ident_start ident_char* as name { keyword name }
  | eof { EOF }
  | _ as character {
      failwith (Printf.sprintf "unexpected character %C" character)
    }
