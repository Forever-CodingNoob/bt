%{
open Ast
%}

%token PARAM LET ENTRY EXIT SIZE WHEN AND OR NOT
%token NEWLINE TARGET CAP STOCK
%token ASSIGN EQEQ NEQ LE GE LT GT PLUS MINUS STAR SLASH
%token LPAREN RPAREN COMMA
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
| ENTRY WHEN expr { Entry ($3, None) }
| ENTRY WHEN expr SIZE expr { Entry ($3, Some $5) }
| EXIT WHEN expr { Exit ($3, None) }
| EXIT WHEN expr SIZE expr { Exit ($3, Some $5) }
| SIZE expr { Size $2 }
| TARGET expr { Target $2 }
| CAP NUMBER { Cap $2 }
| STOCK STRING { Stock $2 }
;

expr:
  NUMBER { Num $1 }
| IDENT { Var $1 }
| IDENT LPAREN arg_list RPAREN { Call ($1, $3) }
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
