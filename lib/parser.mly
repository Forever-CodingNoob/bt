%{
open Ast
%}

%token PARAM LET ENTRY EXIT SIZE WHEN AND OR NOT
%token NEWLINE TARGET CAP STOCK
%token ASSIGN EQEQ NEQ LE GE LT GT PLUS MINUS STAR SLASH
%token LPAREN RPAREN COMMA
%token DOT AS
%token <string> IDENT STRING
%token <float> NUMBER
%token EOF UMINUS

%left OR
%left AND
%nonassoc NOT
%nonassoc LT LE GT GE EQEQ NEQ
%left PLUS MINUS
%left STAR SLASH
%nonassoc UMINUS

%start file
%type <Ast.file> file

%%

file:
  lines EOF { List.rev $1 }
| lines stmt EOF { List.rev ($2 :: $1) }
;

lines:
  /* empty */ { [] }
| lines NEWLINE { $1 }
| lines stmt NEWLINE { $2 :: $1 }
;

stmt:
  PARAM IDENT ASSIGN NUMBER { Param ($2, $4) }
| LET IDENT ASSIGN expr { Let ($2, $4) }
| ENTRY WHEN expr { Entry (None, $3, None) }
| ENTRY WHEN expr SIZE expr { Entry (None, $3, Some $5) }
| IDENT DOT ENTRY WHEN expr { Entry (Some $1, $5, None) }
| IDENT DOT ENTRY WHEN expr SIZE expr { Entry (Some $1, $5, Some $7) }
| EXIT WHEN expr { Exit (None, $3, None) }
| EXIT WHEN expr SIZE expr { Exit (None, $3, Some $5) }
| IDENT DOT EXIT WHEN expr { Exit (Some $1, $5, None) }
| IDENT DOT EXIT WHEN expr SIZE expr { Exit (Some $1, $5, Some $7) }
| SIZE expr { Size (None, $2) }
| IDENT DOT SIZE expr { Size (Some $1, $4) }
| TARGET expr { Target (None, $2) }
| IDENT DOT TARGET expr { Target (Some $1, $4) }
| CAP NUMBER { Cap (None, $2) }
| IDENT DOT CAP NUMBER { Cap (Some $1, $4) }
| STOCK STRING { Stock ($2, None) }
| STOCK STRING AS IDENT { Stock ($2, Some $4) }
;

expr:
  NUMBER { Num $1 }
| IDENT { Var (None, $1) }
| IDENT DOT IDENT { Var (Some $1, $3) }
| IDENT LPAREN arg_list RPAREN { Call (None, $1, $3) }
| IDENT DOT IDENT LPAREN arg_list RPAREN { Call (Some $1, $3, $5) }
| LPAREN expr RPAREN { $2 }
| MINUS expr %prec UMINUS { Unop ("-", $2) }
| NOT expr { Unop ("not", $2) }
| expr PLUS expr { Binop ("+", $1, $3) }
| expr MINUS expr { Binop ("-", $1, $3) }
| expr STAR expr { Binop ("*", $1, $3) }
| expr SLASH expr { Binop ("/", $1, $3) }
| expr LT expr { Binop ("<", $1, $3) }
| expr LE expr { Binop ("<=", $1, $3) }
| expr GT expr { Binop (">", $1, $3) }
| expr GE expr { Binop (">=", $1, $3) }
| expr EQEQ expr { Binop ("==", $1, $3) }
| expr NEQ expr { Binop ("!=", $1, $3) }
| expr AND expr { Binop ("and", $1, $3) }
| expr OR expr { Binop ("or", $1, $3) }
;

arg_list:
  /* empty */ { [] }
| nonempty_arg_list { List.rev $1 }
;

nonempty_arg_list:
  expr { [$1] }
| nonempty_arg_list COMMA expr { $3 :: $1 }
;
