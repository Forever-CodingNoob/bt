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
  | Var (None, name) -> name
  | Var (Some qualifier, name) -> qualifier ^ "." ^ name
  | Call (qualifier, name, arguments) ->
      let rendered = List.rev (List.rev_map string_of_expr arguments) in
      let callee =
        match qualifier with
        | None -> name
        | Some q -> q ^ "." ^ name
      in
      Printf.sprintf "%s(%s)" callee (String.concat ", " rendered)
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

let cross_operand context expression = function
  | Scalar number -> Array.make context.length number
  | Series series -> series
  | Bools _ -> fail_expr expression "cross expects numbers or numeric series"

let nan_min left right =
  if Float.is_nan left || Float.is_nan right then Float.nan
  else if left < right then left else right

let nan_max left right =
  if Float.is_nan left || Float.is_nan right then Float.nan
  else if left > right then left else right

let builtin_arity = function
  | "sma" | "ema" | "rsi" | "stddev" | "highest" | "lowest" | "lag"
  | "bb_mid" | "cross_above" | "cross_below" | "max" | "min" | "hold" ->
      Some 2
  | "atr" | "abs" | "num" -> Some 1
  | "bb_upper" | "bb_lower" | "macd" -> Some 3
  | "macd_signal" | "macd_hist" -> Some 4
  | _ -> None

let rec eval context environment expression =
  match expression with
  | Num number -> Scalar number
  | Var (qualifier, name) ->
      let key =
        match qualifier with None -> name | Some q -> q ^ "." ^ name
      in
      begin
        match List.assoc_opt key environment with
        | Some value -> value
        | None ->
            fail_expr expression (Printf.sprintf "unknown identifier %s" key)
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
  | Call (Some qualifier, _, _) ->
      fail_expr expression
        (Printf.sprintf "unknown stock alias %s" qualifier)
  | Call (None, name, arguments) ->
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
  | "num", [value] ->
      (match value with
       | Bools flags ->
           let out = Array.make (Array.length flags) 0. in
           for i = 0 to Array.length flags - 1 do
             if flags.(i) then out.(i) <- 1.
           done;
           Series out
       | _ -> fail_expr expression "num expects a boolean series")
  | "hold", [set; reset] ->
      (match set, reset with
       | Bools set, Bools reset ->
           check_bool_lengths expression set reset;
           let out = Array.make (Array.length set) false in
           let state = ref false in
           for i = 0 to Array.length set - 1 do
             if reset.(i) then state := false
             else if set.(i) then state := true;
             out.(i) <- !state
           done;
           Bools out
       | _ -> fail_expr expression "hold expects two boolean series")
  | "cross_above", [left; right] ->
      Bools (Series.cross_above
               (cross_operand context expression left)
               (cross_operand context expression right))
  | "cross_below", [left; right] ->
      Bools (Series.cross_below
               (cross_operand context expression left)
               (cross_operand context expression right))
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

let declared_params_ast statements =
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

let compile_ast statements ~params bars =
  let declarations = declared_params_ast statements in
  validate_overrides declarations params;
  let context = { bars; length = Array.length bars } in
  let initial_environment = series_environment bars in
  let environment, entries, exits, size, targets, cap =
    List.fold_left
      (fun (environment, entries, exits, size, targets, cap) statement ->
        match statement with
        | Param (name, default) ->
            let value = overridden_value params name default in
            ((name, Scalar value) :: environment,
             entries, exits, size, targets, cap)
        | Let (name, expression) ->
            let value = eval context environment expression in
            ((name, value) :: environment, entries, exits, size, targets, cap)
        | Entry (None, expression, inline_size_expression) ->
            let signal =
              bool_signal "entry" expression
                (eval context environment expression)
            in
            let inline_size =
              match inline_size_expression with
              | None -> None
              | Some size_expression ->
                  Some (size_expression,
                        eval context environment size_expression)
            in
            (environment, (signal, inline_size) :: entries,
             exits, size, targets, cap)
        | Exit (None, expression, inline_size_expression) ->
            let signal =
              bool_signal "exit" expression
                (eval context environment expression)
            in
            let inline_size =
              match inline_size_expression with
              | None -> None
              | Some size_expression ->
                  Some (size_expression,
                        eval context environment size_expression)
            in
            (environment, entries, (signal, inline_size) :: exits,
             size, targets, cap)
        | Size (None, expression) ->
            begin
              match size with
              | Some _ -> failwith "strategy may contain at most one size statement"
              | None ->
                  let value = eval context environment expression in
                  (environment, entries, exits, Some (expression, value),
                   targets, cap)
            end
        | Target (None, expression) ->
            let value = eval context environment expression in
            (environment, entries, exits, size,
             (expression, value) :: targets, cap)
        | Cap (None, value) ->
            begin
              match cap with
              | Some _ -> failwith "strategy may contain at most one cap statement"
              | None ->
                  (environment, entries, exits, size, targets, Some value)
            end
        | Entry (Some alias, _, _)
        | Exit (Some alias, _, _)
        | Size (Some alias, _)
        | Target (Some alias, _)
        | Cap (Some alias, _) ->
            failwith (Printf.sprintf "unknown stock alias %s" alias)
        | Stock _ ->
            (environment, entries, exits, size, targets, cap))
      (initial_environment, [], [], None, [], None) statements
  in
  ignore environment;
  let has_target = targets <> [] in
  let has_inline =
    List.exists (fun (_, inline_size) -> inline_size <> None) entries
    || List.exists (fun (_, inline_size) -> inline_size <> None) exits
  in
  let style_2 =
    not has_target
    && (has_inline || cap <> None
        || List.length entries > 1 || List.length exits > 1)
  in
  let size_at = function
    | None -> (fun _ -> 1.)
    | Some (_, Scalar number) -> (fun _ -> number)
    | Some (expression, Series series) ->
        if Array.length series <> context.length then
          fail_expr expression "size series length mismatch";
        (fun t -> series.(t))
    | Some (expression, Bools _) ->
        fail_expr expression "size must be a scalar or numeric series"
  in
  let target =
    if has_target then begin
      if List.length targets > 1 then
        failwith "only one target statement is allowed";
      if entries <> [] || exits <> [] then
        failwith "target cannot be mixed with entry/exit statements";
      if cap <> None then failwith "cap is only valid with entry/exit sizes";
      if size <> None then
        failwith "size is only valid in legacy entry/exit style";
      let expression, value =
        match targets with
        | [(expression, value)] -> expression, value
        | _ -> assert false
      in
      match value with
      | Scalar number -> Array.make context.length number
      | Series series ->
          if Array.length series <> context.length then
            fail_expr expression "target series length mismatch";
          series
      | Bools _ -> fail_expr expression "target must be numeric"
    end
    else if style_2 then begin
      if size <> None then
        failwith "standalone size is only valid in the legacy entry/exit style";
      if entries = [] then failwith "at least one entry statement is required";
      let entry_signals =
        List.rev_map
          (fun (condition, inline_size) ->
            condition, size_at inline_size)
          entries
      in
      let exit_signals =
        List.rev_map
          (fun (condition, inline_size) ->
            condition, size_at inline_size)
          exits
      in
      let cap_value = match cap with None -> 1.0 | Some value -> value in
      let size_points value_at t =
        let value = value_at t in
        if Float.is_nan value then 0. else value
      in
      let target = Array.make context.length 0. in
      let exposure = ref 0. in
      for t = 0 to context.length - 1 do
        let delta = ref 0. in
        List.iter
          (fun (condition, points_at) ->
            if condition.(t) then
              delta := !delta +. size_points points_at t)
          entry_signals;
        List.iter
          (fun (condition, points_at) ->
            if condition.(t) then
              delta := !delta -. size_points points_at t)
          exit_signals;
        exposure :=
          Float.min cap_value (Float.max 0. (!exposure +. !delta));
        target.(t) <- !exposure
      done;
      target
    end
    else begin
      let entry =
        match entries with
        | [(signal, None)] -> signal
        | _ -> failwith "strategy must contain exactly one entry statement"
      in
      let exit_ =
        match exits with
        | [(signal, None)] -> signal
        | _ -> failwith "strategy must contain exactly one exit statement"
      in
      let size_at = size_at size in
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
      target
    end
  in
  let strategy : Engine.strategy = { target } in
  strategy

let compile source ~params bars =
  compile_ast (parse_file source) ~params bars

let stock_of ~filename statements =
  let stocks =
    List.fold_left
      (fun acc -> function Stock (s, _) -> s :: acc | _ -> acc) [] statements
  in
  match stocks with
  | [] ->
      failwith (Printf.sprintf
        "%s: add a stock statement, e.g. stock \"tw/00685L\"" filename)
  | _ :: _ :: _ ->
      failwith (Printf.sprintf
        "%s: multiple stocks per strat are not supported yet" filename)
  | [spec] ->
      (match String.index_opt spec '/' with
       | Some i when i > 0 && i < String.length spec - 1 &&
                     not (String.contains_from spec (i + 1) '/') ->
           let market = String.sub spec 0 i in
           let symbol =
             String.sub spec (i + 1) (String.length spec - i - 1)
           in
           if market <> "tw" && market <> "us" then
             failwith (Printf.sprintf
               "%s: market must be tw or us in stock \"%s\"" filename spec)
           else (market, symbol)
       | _ ->
           failwith (Printf.sprintf
             "%s: stock expects \"market/symbol\", got \"%s\"" filename spec))
