open Ast

type value =
  | Scalar of float
  | Series of float array
  | Bools of bool array

type context = {
  bars : Data.bar array;
  length : int;
}

let parse_file filename =
  let channel =
    try open_in filename
    with Sys_error message -> failwith message
  in
  let lexbuf = Lexing.from_channel channel in
  let position = lexbuf.lex_curr_p in
  lexbuf.lex_curr_p <- { position with pos_fname = filename };
  try
    let parsed = Parser.file Lexer.token lexbuf in
    close_in_noerr channel;
    parsed
  with
  | Parsing.Parse_error ->
      let line = lexbuf.lex_curr_p.pos_lnum in
      close_in_noerr channel;
      failwith (Printf.sprintf "%s:%d: parse error" filename line)
  | Failure message ->
      let line = lexbuf.lex_curr_p.pos_lnum in
      close_in_noerr channel;
      failwith (Printf.sprintf "%s:%d: %s" filename line message)
  | exception_ ->
      close_in_noerr channel;
      raise exception_

let rec string_of_expr = function
  | Num number -> Printf.sprintf "%g" number
  | Var name -> name
  | Call (name, arguments) ->
      let rendered = List.rev (List.rev_map string_of_expr arguments) in
      Printf.sprintf "%s(%s)" name (String.concat ", " rendered)
  | Unop (operator, expression) ->
      Printf.sprintf "(%s %s)" operator (string_of_expr expression)
  | Binop (operator, left, right) ->
      Printf.sprintf "(%s %s %s)"
        (string_of_expr left) operator (string_of_expr right)

let fail_expr expression message =
  failwith (Printf.sprintf "%s: %s" (string_of_expr expression) message)

let check_float_lengths expression left right =
  if Array.length left <> Array.length right then
    fail_expr expression "series length mismatch"

let check_bool_lengths expression left right =
  if Array.length left <> Array.length right then
    fail_expr expression "boolean series length mismatch"

let map_float function_ source =
  let length = Array.length source in
  let out = Array.make length Float.nan in
  for i = 0 to length - 1 do
    out.(i) <- function_ source.(i)
  done;
  out

let numeric_unary expression function_ = function
  | Scalar number -> Scalar (function_ number)
  | Series series -> Series (map_float function_ series)
  | Bools _ -> fail_expr expression "expected a number or numeric series"

let numeric_binary expression function_ left right =
  match left, right with
  | Scalar a, Scalar b -> Scalar (function_ a b)
  | Scalar a, Series b ->
      let length = Array.length b in
      let out = Array.make length Float.nan in
      for i = 0 to length - 1 do
        out.(i) <- function_ a b.(i)
      done;
      Series out
  | Series a, Scalar b ->
      let length = Array.length a in
      let out = Array.make length Float.nan in
      for i = 0 to length - 1 do
        out.(i) <- function_ a.(i) b
      done;
      Series out
  | Series a, Series b ->
      check_float_lengths expression a b;
      let length = Array.length a in
      let out = Array.make length Float.nan in
      for i = 0 to length - 1 do
        out.(i) <- function_ a.(i) b.(i)
      done;
      Series out
  | Bools _, _ | _, Bools _ ->
      fail_expr expression "arithmetic expects numbers or numeric series"

let compare_number predicate left right =
  not (Float.is_nan left || Float.is_nan right) && predicate left right

let comparison length expression predicate left right =
  match left, right with
  | Scalar a, Scalar b -> Bools (Array.make length (compare_number predicate a b))
  | Scalar a, Series b ->
      let out = Array.make (Array.length b) false in
      for i = 0 to Array.length b - 1 do
        out.(i) <- compare_number predicate a b.(i)
      done;
      Bools out
  | Series a, Scalar b ->
      let out = Array.make (Array.length a) false in
      for i = 0 to Array.length a - 1 do
        out.(i) <- compare_number predicate a.(i) b
      done;
      Bools out
  | Series a, Series b ->
      check_float_lengths expression a b;
      let out = Array.make (Array.length a) false in
      for i = 0 to Array.length a - 1 do
        out.(i) <- compare_number predicate a.(i) b.(i)
      done;
      Bools out
  | Bools _, _ | _, Bools _ ->
      fail_expr expression "comparison expects numbers or numeric series"

let logical_binary expression predicate left right =
  match left, right with
  | Bools a, Bools b ->
      check_bool_lengths expression a b;
      let out = Array.make (Array.length a) false in
      for i = 0 to Array.length a - 1 do
        out.(i) <- predicate a.(i) b.(i)
      done;
      Bools out
  | _ -> fail_expr expression "and/or expect boolean series"

let logical_not expression = function
  | Bools source ->
      let out = Array.make (Array.length source) false in
      for i = 0 to Array.length source - 1 do
        out.(i) <- not source.(i)
      done;
      Bools out
  | _ -> fail_expr expression "not expects a boolean series"

let expect_series expression = function
  | Series series -> series
  | _ -> fail_expr expression "expected a numeric series"

let expect_scalar expression = function
  | Scalar number -> number
  | _ -> fail_expr expression "expected a scalar"

let expect_period expression value =
  let number = expect_scalar expression value in
  match classify_float number with
  | FP_nan | FP_infinite -> fail_expr expression "period must be finite"
  | FP_normal | FP_subnormal | FP_zero ->
      if number < 1. || number > float_of_int max_int then
        fail_expr expression "period must be at least 1";
      int_of_float number

let nan_min left right =
  if Float.is_nan left || Float.is_nan right then Float.nan
  else if left < right then left else right

let nan_max left right =
  if Float.is_nan left || Float.is_nan right then Float.nan
  else if left > right then left else right

let builtin_arity = function
  | "sma" | "ema" | "rsi" | "stddev" | "highest" | "lowest" | "lag"
  | "bb_mid" | "cross_above" | "cross_below" | "max" | "min" -> Some 2
  | "atr" | "abs" -> Some 1
  | "bb_upper" | "bb_lower" | "macd" -> Some 3
  | "macd_signal" | "macd_hist" -> Some 4
  | _ -> None

let rec eval context environment expression =
  match expression with
  | Num number -> Scalar number
  | Var name ->
      begin
        match List.assoc_opt name environment with
        | Some value -> value
        | None -> fail_expr expression (Printf.sprintf "unknown identifier %s" name)
      end
  | Unop ("-", operand) ->
      numeric_unary expression (fun number -> -.number)
        (eval context environment operand)
  | Unop ("not", operand) ->
      logical_not expression (eval context environment operand)
  | Unop (operator, _) ->
      fail_expr expression (Printf.sprintf "unknown unary operator %s" operator)
  | Binop (operator, left_expression, right_expression) ->
      let left = eval context environment left_expression in
      let right = eval context environment right_expression in
      begin
        match operator with
        | "+" -> numeric_binary expression ( +. ) left right
        | "-" -> numeric_binary expression ( -. ) left right
        | "*" -> numeric_binary expression ( *. ) left right
        | "/" -> numeric_binary expression ( /. ) left right
        | "<" -> comparison context.length expression ( < ) left right
        | "<=" -> comparison context.length expression ( <= ) left right
        | ">" -> comparison context.length expression ( > ) left right
        | ">=" -> comparison context.length expression ( >= ) left right
        | "==" -> comparison context.length expression ( = ) left right
        | "!=" -> comparison context.length expression ( <> ) left right
        | "and" -> logical_binary expression ( && ) left right
        | "or" -> logical_binary expression ( || ) left right
        | _ -> fail_expr expression (Printf.sprintf "unknown operator %s" operator)
      end
  | Call (name, arguments) ->
      begin
        match builtin_arity name with
        | None -> fail_expr expression (Printf.sprintf "unknown builtin %s" name)
        | Some arity ->
            if List.length arguments <> arity then
              fail_expr expression
                (Printf.sprintf "%s expects %d argument(s)" name arity);
            let values = eval_arguments context environment [] arguments in
            eval_call context expression name values
      end

and eval_arguments context environment reversed = function
  | [] -> List.rev reversed
  | expression :: rest ->
      let value = eval context environment expression in
      eval_arguments context environment (value :: reversed) rest

and eval_call context expression name arguments =
  match name, arguments with
  | "sma", [series; period] ->
      Series (Series.sma (expect_series expression series)
                (expect_period expression period))
  | "ema", [series; period] ->
      Series (Series.ema (expect_series expression series)
                (expect_period expression period))
  | "rsi", [series; period] ->
      Series (Series.rsi (expect_series expression series)
                (expect_period expression period))
  | "stddev", [series; period] ->
      Series (Series.stddev (expect_series expression series)
                (expect_period expression period))
  | "highest", [series; period] ->
      Series (Series.highest (expect_series expression series)
                (expect_period expression period))
  | "lowest", [series; period] ->
      Series (Series.lowest (expect_series expression series)
                (expect_period expression period))
  | "lag", [series; period] ->
      Series (Series.lag (expect_series expression series)
                (expect_period expression period))
  | "atr", [period] ->
      Series (Series.atr context.bars (expect_period expression period))
  | "abs", [number] -> numeric_unary expression abs_float number
  | "max", [left; right] -> numeric_binary expression nan_max left right
  | "min", [left; right] -> numeric_binary expression nan_min left right
  | "cross_above", [left; right] ->
      Bools (Series.cross_above (expect_series expression left)
               (expect_series expression right))
  | "cross_below", [left; right] ->
      Bools (Series.cross_below (expect_series expression left)
               (expect_series expression right))
  | "bb_upper", [series; period; width] ->
      Series (Series.bb_upper (expect_series expression series)
                (expect_period expression period)
                (expect_scalar expression width))
  | "bb_mid", [series; period] ->
      Series (Series.bb_mid (expect_series expression series)
                (expect_period expression period))
  | "bb_lower", [series; period; width] ->
      Series (Series.bb_lower (expect_series expression series)
                (expect_period expression period)
                (expect_scalar expression width))
  | "macd", [series; fast; slow] ->
      Series (Series.macd (expect_series expression series)
                (expect_period expression fast)
                (expect_period expression slow))
  | "macd_signal", [series; fast; slow; signal] ->
      Series (Series.macd_signal (expect_series expression series)
                (expect_period expression fast)
                (expect_period expression slow)
                (expect_period expression signal))
  | "macd_hist", [series; fast; slow; signal] ->
      Series (Series.macd_hist (expect_series expression series)
                (expect_period expression fast)
                (expect_period expression slow)
                (expect_period expression signal))
  | _ -> fail_expr expression "invalid builtin argument types"

let series_environment (bars : Data.bar array) =
  let length = Array.length bars in
  let open_ = Array.make length Float.nan in
  let high = Array.make length Float.nan in
  let low = Array.make length Float.nan in
  let close = Array.make length Float.nan in
  let volume = Array.make length Float.nan in
  for i = 0 to length - 1 do
    let bar = bars.(i) in
    open_.(i) <- bar.Data.o;
    high.(i) <- bar.Data.h;
    low.(i) <- bar.Data.l;
    close.(i) <- bar.Data.c;
    volume.(i) <- bar.Data.v
  done;
  [ "open", Series open_;
    "high", Series high;
    "low", Series low;
    "close", Series close;
    "volume", Series volume ]

let declared_params statements =
  let reversed =
    List.fold_left
      (fun declarations -> function
        | Param (name, default) -> (name, default) :: declarations
        | _ -> declarations)
      [] statements
  in
  List.rev reversed

let validate_overrides declarations overrides =
  List.iter
    (fun (name, _) ->
      let declared =
        List.fold_left
          (fun found (declared_name, _) -> found || name = declared_name)
          false declarations
      in
      if not declared then
        failwith (Printf.sprintf "unknown parameter %s" name))
    overrides

let overridden_value overrides name default =
  match List.assoc_opt name overrides with
  | Some value -> value
  | None -> default

let bool_signal kind expression = function
  | Bools signal -> signal
  | _ -> fail_expr expression (Printf.sprintf "%s must be a boolean series" kind)

let compile source ~params bars =
  let statements = parse_file source in
  let declarations = declared_params statements in
  validate_overrides declarations params;
  let context = { bars; length = Array.length bars } in
  let initial_environment = series_environment bars in
  let environment, entry, exit_, size =
    List.fold_left
      (fun (environment, entry, exit_, size) statement ->
        match statement with
        | Param (name, default) ->
            let value = overridden_value params name default in
            (name, Scalar value) :: environment, entry, exit_, size
        | Let (name, expression) ->
            let value = eval context environment expression in
            (name, value) :: environment, entry, exit_, size
        | Entry expression ->
            begin
              match entry with
              | Some _ -> failwith "strategy must contain exactly one entry statement"
              | None ->
                  let signal = bool_signal "entry" expression
                      (eval context environment expression) in
                  environment, Some signal, exit_, size
            end
        | Exit expression ->
            begin
              match exit_ with
              | Some _ -> failwith "strategy must contain exactly one exit statement"
              | None ->
                  let signal = bool_signal "exit" expression
                      (eval context environment expression) in
                  environment, entry, Some signal, size
            end
        | Size expression ->
            begin
              match size with
              | Some _ -> failwith "strategy may contain at most one size statement"
              | None ->
                  let value = eval context environment expression in
                  environment, entry, exit_, Some (expression, value)
            end)
      (initial_environment, None, None, None) statements
  in
  ignore environment;
  let entry =
    match entry with
    | Some signal -> signal
    | None -> failwith "strategy must contain exactly one entry statement"
  in
  let exit_ =
    match exit_ with
    | Some signal -> signal
    | None -> failwith "strategy must contain exactly one exit statement"
  in
  let size_at =
    match size with
    | None -> (fun _ -> 1.)
    | Some (_, Scalar number) -> (fun _ -> number)
    | Some (expression, Series series) ->
        if Array.length series <> context.length then
          fail_expr expression "size series length mismatch";
        (fun t -> series.(t))
    | Some (expression, Bools _) ->
        fail_expr expression "size must be a scalar or numeric series"
  in
  let clamp_legacy value =
    if Float.is_nan value || value <= 0. then 1. else value
  in
  let target = Array.make context.length 0. in
  let in_position = ref false in
  let held = ref 0. in
  for t = 0 to context.length - 1 do
    if !in_position then begin
      if exit_.(t) then in_position := false
      else target.(t) <- !held
    end
    else if entry.(t) then begin
      held := clamp_legacy (size_at t);
      in_position := true;
      target.(t) <- !held
    end
  done;
  let strategy : Engine.strategy = { target } in
  strategy
