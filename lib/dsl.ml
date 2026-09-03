open Ast

type value =
  | Scalar of float
  | Series of float array
  | Bools of bool array

type context = {
  bars_by : (string option * Data.bar array) list;
  length : int;
}

let parse_file filename =
  let channel =
    try open_in filename
    with Sys_error message -> failwith message
  in
  let lexbuf = Lexing.from_channel channel in
  let position = lexbuf.lex_curr_p in
  let () = lexbuf.lex_curr_p <- { position with pos_fname = filename } in
  try
    let parsed = Parser.file Lexer.token lexbuf in
    let () = close_in_noerr channel in
    parsed
  with
  | Parsing.Parse_error ->
      let line = lexbuf.lex_curr_p.pos_lnum in
      let () = close_in_noerr channel in
      failwith (Printf.sprintf "%s:%d: parse error" filename line)
  | Failure message ->
      let line = lexbuf.lex_curr_p.pos_lnum in
      let () = close_in_noerr channel in
      failwith (Printf.sprintf "%s:%d: %s" filename line message)
  | exception_ ->
      let () = close_in_noerr channel in
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

let map_float function_ source = Array.map function_ source

let numeric_unary expression function_ = function
  | Scalar number -> Scalar (function_ number)
  | Series series -> Series (map_float function_ series)
  | Bools _ -> fail_expr expression "expected a number or numeric series"

let numeric_binary expression function_ left right =
  match left, right with
  | Scalar a, Scalar b -> Scalar (function_ a b)
  | Scalar a, Series b ->
      Series (Array.map (fun value -> function_ a value) b)
  | Series a, Scalar b ->
      Series (Array.map (fun value -> function_ value b) a)
  | Series a, Series b ->
      let () = check_float_lengths expression a b in
      Series (Array.map2 function_ a b)
  | Bools _, _ | _, Bools _ ->
      fail_expr expression "arithmetic expects numbers or numeric series"

let compare_number predicate left right =
  not (Float.is_nan left || Float.is_nan right) && predicate left right

let comparison length expression predicate left right =
  match left, right with
  | Scalar a, Scalar b -> Bools (Array.make length (compare_number predicate a b))
  | Scalar a, Series b ->
      Bools (Array.map (fun value -> compare_number predicate a value) b)
  | Series a, Scalar b ->
      Bools (Array.map (fun value -> compare_number predicate value b) a)
  | Series a, Series b ->
      let () = check_float_lengths expression a b in
      Bools (Array.map2 (compare_number predicate) a b)
  | Bools _, _ | _, Bools _ ->
      fail_expr expression "comparison expects numbers or numeric series"

let logical_binary expression predicate left right =
  match left, right with
  | Bools a, Bools b ->
      let () = check_bool_lengths expression a b in
      Bools (Array.map2 predicate a b)
  | _ -> fail_expr expression "and/or expect boolean series"

let logical_not expression = function
  | Bools source -> Bools (Array.map not source)
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
      let () =
        if number < 1. || number > float_of_int max_int then
          fail_expr expression "period must be at least 1"
      in
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
  | Call (qualifier, name, arguments) ->
      let () =
        match qualifier with
        | Some _ when name <> "atr" ->
            fail_expr expression
              (Printf.sprintf "only atr takes a stock alias, not %s" name)
        | _ -> ()
      in
      match builtin_arity name with
      | None -> fail_expr expression (Printf.sprintf "unknown builtin %s" name)
      | Some arity ->
          let () =
            if List.length arguments <> arity then
              fail_expr expression
                (Printf.sprintf "%s expects %d argument(s)" name arity)
          in
          let values = eval_arguments context environment [] arguments in
          eval_call context expression qualifier name values

and eval_arguments context environment reversed = function
  | [] -> List.rev reversed
  | expression :: rest ->
      let value = eval context environment expression in
      eval_arguments context environment (value :: reversed) rest

and eval_call context expression qualifier name arguments =
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
      let bars =
        match List.assoc_opt qualifier context.bars_by with
        | Some bars -> bars
        | None ->
            fail_expr expression
              (match qualifier with
               | None -> "atr requires a stock alias in aliased files"
               | Some q -> Printf.sprintf "unknown stock alias %s" q)
      in
      Series (Series.atr bars (expect_period expression period))
  | "abs", [number] -> numeric_unary expression abs_float number
  | "max", [left; right] -> numeric_binary expression nan_max left right
  | "min", [left; right] -> numeric_binary expression nan_min left right
  | "num", [value] ->
      (match value with
       | Bools flags ->
           Series (Array.map (fun flag -> if flag then 1. else 0.) flags)
       | _ -> fail_expr expression "num expects a boolean series")
  | "hold", [set; reset] ->
      (match set, reset with
       | Bools set, Bools reset ->
           let () = check_bool_lengths expression set reset in
           let out = Array.make (Array.length set) false in
           let rec scan i state =
             if i = Array.length set then ()
             else
               let state =
                 if reset.(i) then false
                 else if set.(i) then true
                 else state
               in
               let () = out.(i) <- state in
               scan (i + 1) state
           in
           let () = scan 0 false in
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

let series_environment ?alias (bars : Data.bar array) =
  let open_ = Array.map (fun bar -> bar.Data.o) bars in
  let high = Array.map (fun bar -> bar.Data.h) bars in
  let low = Array.map (fun bar -> bar.Data.l) bars in
  let close = Array.map (fun bar -> bar.Data.c) bars in
  let volume = Array.map (fun bar -> bar.Data.v) bars in
  let key name =
    match alias with None -> name | Some a -> a ^ "." ^ name
  in
  [ key "open", Series open_;
    key "high", Series high;
    key "low", Series low;
    key "close", Series close;
    key "volume", Series volume ]

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

let split_spec ~filename spec =
  match String.index_opt spec '/' with
  | Some i when i > 0 && i < String.length spec - 1 &&
                not (String.contains_from spec (i + 1) '/') ->
      let market = String.sub spec 0 i in
      let symbol =
        String.sub spec (i + 1) (String.length spec - i - 1)
      in
      (match market with
       | "tw" | "us" -> market, symbol
       | _ ->
           failwith (Printf.sprintf
             "%s: market must be tw or us in stock \"%s\"" filename spec))
  | _ ->
      failwith (Printf.sprintf
        "%s: stock expects \"market/symbol\", got \"%s\"" filename spec)

let stocks_of ~filename statements =
  let declared =
    List.filter_map
      (function Stock (spec, alias) -> Some (spec, alias) | _ -> None)
      statements
  in
  let () =
    if declared = [] then
      failwith (Printf.sprintf
        "%s: add a stock statement, e.g. stock \"tw/00685L\"" filename)
  in
  let aliased = List.exists (fun (_, alias) -> alias <> None) declared in
  let () =
    if List.length declared > 1 && not aliased then
      failwith (Printf.sprintf
        "%s: multiple stocks require as aliases" filename)
  in
  let () =
    if aliased && List.exists (fun (_, alias) -> alias = None) declared then
      failwith (Printf.sprintf
        "%s: mix of aliased and unaliased stock statements" filename)
  in
  let seen_alias = Hashtbl.create 4 in
  List.map
    (fun (spec, alias) ->
      let () =
        match alias with
        | None -> ()
        | Some name ->
            let () =
              if Hashtbl.mem seen_alias name then
                failwith (Printf.sprintf "%s: duplicate alias %s" filename name)
            in
            let () = Hashtbl.replace seen_alias name () in
            let () =
              if builtin_arity name <> None then
                failwith (Printf.sprintf
                  "%s: alias %s collides with a builtin" filename name)
            in
            let () =
              if List.mem name ["open"; "high"; "low"; "close"; "volume"] then
                failwith (Printf.sprintf
                  "%s: alias %s collides with a series name" filename name)
            in
            List.iter
              (function
                | Param (p, _) when p = name ->
                    failwith (Printf.sprintf
                      "%s: alias %s collides with a param" filename name)
                | Let (l, _) when l = name ->
                    failwith (Printf.sprintf
                      "%s: alias %s collides with a let" filename name)
                | _ -> ())
              statements
      in
      let market, symbol = split_spec ~filename spec in
      alias, market, symbol)
    declared

let compile_ast statements ~params ~assets =
  let declarations = declared_params_ast statements in
  let () = validate_overrides declarations params in
  let length =
    match assets with
    | [] -> invalid_arg "Dsl.compile_ast: no assets"
    | (_, first) :: rest ->
        let length = Array.length first in
        let () =
          List.iter
            (fun (_, bars) ->
              if Array.length bars <> length then
                invalid_arg "Dsl.compile_ast: bar length mismatch")
            rest
        in
        length
  in
  let context = { bars_by = assets; length } in
  let initial_environment =
    List.concat_map
      (fun (alias, bars) -> series_environment ?alias bars)
      assets
  in
  let module Group = struct
    type t = {
      mutable entries : (bool array * (Ast.expr * value) option) list;
      mutable exits : (bool array * (Ast.expr * value) option) list;
      mutable size : (Ast.expr * value) option;
      mutable targets : (Ast.expr * value) list;
      mutable cap : float option;
    }

    let make () =
      { entries = []; exits = []; size = None; targets = []; cap = None }
  end in
  let groups : (string option, Group.t) Hashtbl.t = Hashtbl.create 4 in
  let declared_aliases = List.map fst assets in
  let group alias =
    let () =
      if not (List.mem alias declared_aliases) then
        match alias with
        | Some name -> failwith (Printf.sprintf "unknown stock alias %s" name)
        | None -> failwith "statements must name a stock alias in aliased files"
    in
    match Hashtbl.find_opt groups alias with
    | Some g -> g
    | None ->
        let g = Group.make () in
        let () = Hashtbl.replace groups alias g in
        g
  in
  let environment =
    List.fold_left
      (fun environment statement ->
        match statement with
        | Param (name, default) ->
            let value = overridden_value params name default in
            (name, Scalar value) :: environment
        | Let (name, expression) ->
            let value = eval context environment expression in
            (name, value) :: environment
        | Entry (alias, expression, inline_size_expression) ->
            let g = group alias in
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
            let () = g.entries <- (signal, inline_size) :: g.entries in
            environment
        | Exit (alias, expression, inline_size_expression) ->
            let g = group alias in
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
            let () = g.exits <- (signal, inline_size) :: g.exits in
            environment
        | Size (alias, expression) ->
            let g = group alias in
            (match g.size with
             | Some _ -> failwith "strategy may contain at most one size statement"
             | None ->
                 let value = eval context environment expression in
                 let () = g.size <- Some (expression, value) in
                 environment)
        | Target (alias, expression) ->
            let g = group alias in
            let value = eval context environment expression in
            let () = g.targets <- (expression, value) :: g.targets in
            environment
        | Cap (alias, value) ->
            let g = group alias in
            (match g.cap with
             | Some _ -> failwith "strategy may contain at most one cap statement"
             | None ->
                 let () = g.cap <- Some value in
                 environment)
        | Stock _ -> environment)
      initial_environment statements
  in
  let () = ignore environment in
  let compile_group context (group : Group.t) =
    let entries = group.entries in
    let exits = group.exits in
    let size = group.size in
    let targets = group.targets in
    let cap = group.cap in
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
          let () =
            if Array.length series <> context.length then
              fail_expr expression "size series length mismatch"
          in
          (fun t -> series.(t))
      | Some (expression, Bools _) ->
          fail_expr expression "size must be a scalar or numeric series"
    in
    if has_target then
      let () =
        if List.length targets > 1 then
          failwith "only one target statement is allowed"
      in
      let () =
        if entries <> [] || exits <> [] then
          failwith "target cannot be mixed with entry/exit statements"
      in
      let () =
        if cap <> None then failwith "cap is only valid with entry/exit sizes"
      in
      let () =
        if size <> None then
          failwith "size is only valid in legacy entry/exit style"
      in
      let expression, value =
        match targets with
        | [(expression, value)] -> expression, value
        | _ -> assert false
      in
      match value with
      | Scalar number -> Array.make context.length number
      | Series series ->
          let () =
            if Array.length series <> context.length then
              fail_expr expression "target series length mismatch"
          in
          series
      | Bools _ -> fail_expr expression "target must be numeric"
    else if style_2 then
      let () =
        if size <> None then
          failwith "standalone size is only valid in the legacy entry/exit style"
      in
      let () =
        if entries = [] then failwith "at least one entry statement is required"
      in
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
      let rec scan t exposure =
        if t = context.length then ()
        else
          let delta =
            List.fold_left
              (fun delta (condition, points_at) ->
                if condition.(t) then delta +. size_points points_at t
                else delta)
              0. entry_signals
          in
          let delta =
            List.fold_left
              (fun delta (condition, points_at) ->
                if condition.(t) then delta -. size_points points_at t
                else delta)
              delta exit_signals
          in
          let exposure =
            Float.min cap_value (Float.max 0. (exposure +. delta))
          in
          let () = target.(t) <- exposure in
          scan (t + 1) exposure
      in
      let () = scan 0 0. in
      target
    else
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
      let rec scan t in_position held =
        if t = context.length then ()
        else if in_position then
          if exit_.(t) then scan (t + 1) false held
          else
            let () = target.(t) <- held in
            scan (t + 1) true held
        else if entry.(t) then
          let held = clamp_legacy (size_at t) in
          let () = target.(t) <- held in
          scan (t + 1) true held
        else scan (t + 1) false held
      in
      let () = scan 0 false 0. in
      target
  in
  let strategy : Engine.strategy =
    { targets =
        Array.of_list
          (List.map
             (fun (alias, _) ->
               match Hashtbl.find_opt groups alias with
               | Some g -> compile_group context g
               | None ->
                   failwith
                     (match alias with
                      | Some name ->
                          Printf.sprintf "stock alias %s has no statements" name
                      | None -> "strategy has no statements"))
             assets) }
  in
  strategy

let compile source ~params bars =
  let ast = parse_file source in
  if not (List.exists (function Stock _ -> true | _ -> false) ast) then
    compile_ast ast ~params ~assets:[ (None, bars) ]
  else
    match stocks_of ~filename:source ast with
    | [ (None, _, _) ] ->
        compile_ast ast ~params ~assets:[ (None, bars) ]
    | _ ->
        failwith "Dsl.compile supports single unaliased stocks; use compile_ast"
