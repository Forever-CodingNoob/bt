type info = {
  simulation : bool;
  version : string;
}

type snapshot = {
  datetime : string;
  open_ : float;
  high : float;
  low : float;
  close : float;
  bid : float;
  ask : float;
  total_volume : float;
}

type position = {
  id : int;
  code : string;
  cond : string;
  lots : int;
  yd_lots : int;
  avg_price : float;
  last_price : float;
  loan_amount : float;
  interest : float;
}

type position_detail = {
  code : string;
  cond : string;
  date : string;
  lots : int;
}

type order_request = {
  exchange : string;
  code : string;
  action : string;
  lots : int;
  cond : string;
  custom_field : string;
}

type placed = {
  order_id : string;
  status : string;
}

type trade = {
  order_id : string;
  code : string;
  action : string;
  cond : string;
  status : string;
  order_lots : int;
  deal_lots : int;
  deal_price : float option;
  order_datetime : string;
}

type settlement = {
  date : string;
  amount : float;
  day : int;
}

let failf fmt = Printf.ksprintf failwith fmt

let base_url () =
  match Sys.getenv_opt "SHIOAJI_URL" with
  | Some value when String.trim value <> "" -> value
  | Some _ | None -> "http://localhost:8080"

let remove_if_exists path =
  try Sys.remove path with Sys_error _ -> ()

let with_temp suffix function_ =
  let path = Filename.temp_file "bt-shioaji-" suffix in
  Fun.protect ~finally:(fun () -> remove_if_exists path) (fun () -> function_ path)

let write_text path text =
  let output = open_out_bin path in
  Fun.protect
    ~finally:(fun () -> close_out output)
    (fun () -> output_string output text)

let read_text path =
  let input = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in input)
    (fun () -> really_input_string input (in_channel_length input))

let rec wait_for pid =
  try snd (Unix.waitpid [] pid) with
  | Unix.Unix_error (Unix.EINTR, _, _) -> wait_for pid

let run_capture program args =
  with_temp ".out" (fun output_path ->
    let output =
      Unix.openfile output_path [Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC] 0o600
    in
    let pid =
      Fun.protect
        ~finally:(fun () -> Unix.close output)
        (fun () ->
          Unix.create_process program (Array.of_list (program :: args))
            Unix.stdin output Unix.stderr)
    in
    let status = wait_for pid in
    status, read_text output_path)

let process_ok = function
  | Unix.WEXITED 0 -> true
  | Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _ -> false

let jq_output ?(args = []) label expression raw =
  with_temp ".json" (fun input_path ->
    let () = write_text input_path raw in
    match run_capture "/usr/bin/jq" (["-er"] @ args @ [expression; input_path]) with
    | status, output when process_ok status -> String.trim output
    | _ -> failf "invalid Shioaji %s response" label)

let jq_fields ?args label expression raw =
  match jq_output ?args label expression raw with
  | "" -> []
  | output -> String.split_on_char '\t' output

let jq_rows ?args label expression raw =
  match jq_output ?args label expression raw with
  | "" -> []
  | output ->
      List.map (String.split_on_char '\t') (String.split_on_char '\n' output)

let int_field label value =
  match int_of_string_opt value with
  | Some result -> result
  | None -> failf "invalid Shioaji %s value %S" label value

let nonnegative_int_field label value =
  match int_field label value with
  | result when result >= 0 -> result
  | _ -> failf "invalid Shioaji %s value %S" label value

let positive_int_field label value =
  match int_field label value with
  | result when result > 0 -> result
  | _ -> failf "invalid Shioaji %s value %S" label value

let float_field label value =
  match float_of_string_opt value with
  | Some result when Float.is_finite result -> result
  | Some _ | None -> failf "invalid Shioaji %s value %S" label value

let nonnegative_float_field label value =
  match float_field label value with
  | result when result >= 0. -> result
  | _ -> failf "invalid Shioaji %s value %S" label value

let positive_float_field label value =
  match float_field label value with
  | result when result > 0. -> result
  | _ -> failf "invalid Shioaji %s value %S" label value

let date_field label value =
  let digit offset =
    match value.[offset] with
    | '0' .. '9' -> true
    | _ -> false
  in
  let valid_shape =
    String.length value = 10
    && digit 0 && digit 1 && digit 2 && digit 3
    && value.[4] = '-'
    && digit 5 && digit 6
    && value.[7] = '-'
    && digit 8 && digit 9
  in
  match valid_shape with
  | false -> failf "invalid Shioaji %s value %S" label value
  | true ->
      let year = int_of_string (String.sub value 0 4) in
      let month = int_of_string (String.sub value 5 2) in
      let day = int_of_string (String.sub value 8 2) in
      let leap =
        year mod 400 = 0 || (year mod 4 = 0 && year mod 100 <> 0)
      in
      let days =
        match month with
        | 1 | 3 | 5 | 7 | 8 | 10 | 12 -> 31
        | 4 | 6 | 9 | 11 -> 30
        | 2 when leap -> 29
        | 2 -> 28
        | _ -> 0
      in
      match year > 0 && day > 0 && day <= days with
      | true -> value
      | false -> failf "invalid Shioaji %s value %S" label value

let bool_field label value =
  try bool_of_string value with Invalid_argument _ ->
    failf "invalid Shioaji %s value %S" label value

let parse_info raw =
  match
    jq_fields "info" "[(.simulation | tostring), .version] | @tsv" raw
  with
  | [simulation; version] ->
      { simulation = bool_field "info simulation" simulation; version }
  | _ -> failwith "invalid Shioaji info response"

let parse_snapshot raw =
  match
    jq_fields "snapshot"
      "if length == 1 then [.[0].datetime, (.[0].open | tostring), (.[0].high | tostring), (.[0].low | tostring), (.[0].close | tostring), (.[0].buy_price | tostring), (.[0].sell_price | tostring), (.[0].total_volume | tostring)] | @tsv else error(\"expected one snapshot\") end"
      raw
  with
  | [datetime; open_; high; low; close; bid; ask; total_volume] ->
      { datetime;
        open_ = nonnegative_float_field "snapshot open" open_;
        high = nonnegative_float_field "snapshot high" high;
        low = nonnegative_float_field "snapshot low" low;
        close = nonnegative_float_field "snapshot close" close;
        bid = nonnegative_float_field "snapshot buy_price" bid;
        ask = nonnegative_float_field "snapshot sell_price" ask;
        total_volume =
          nonnegative_float_field "snapshot total_volume" total_volume }
  | _ -> failwith "invalid Shioaji snapshot response"

let parse_position = function
  | [id; code; cond; lots; yd_lots; avg_price; last_price; loan_amount;
     interest] ->
      { id = nonnegative_int_field "position id" id;
        code;
        cond;
        lots = nonnegative_int_field "position quantity" lots;
        yd_lots = nonnegative_int_field "position yd_quantity" yd_lots;
        avg_price = nonnegative_float_field "position price" avg_price;
        last_price =
          nonnegative_float_field "position last_price" last_price;
        loan_amount =
          nonnegative_float_field "position margin_purchase_amount" loan_amount;
        interest = nonnegative_float_field "position interest" interest }
  | _ -> failwith "invalid Shioaji positions response"

let parse_positions raw =
  jq_rows "positions"
    "if type == \"array\" then map([(.id | tostring), .code, .cond, (.quantity | tostring), (.yd_quantity | tostring), (.price | tostring), (.last_price | tostring), (.margin_purchase_amount | tostring), (.interest | tostring)] | @tsv) | join(\"\\n\") else error(\"expected positions array\") end"
    raw
  |> List.map parse_position

let parse_position_detail = function
  | [code; cond; date; lots] ->
      { code;
        cond;
        date = date_field "position detail date" date;
        lots = nonnegative_int_field "position detail quantity" lots }
  | _ -> failwith "invalid Shioaji position_detail response"

let parse_position_details raw =
  jq_rows "position_detail"
    "if type == \"array\" then map(if ((.code | type) == \"string\" and (.cond | type) == \"string\" and (.date | type) == \"string\" and (.quantity | type) == \"number\") then [.code, .cond, .date, (.quantity | tostring)] | @tsv else error(\"invalid stock position detail fields\") end) | join(\"\\n\") else error(\"expected stock position detail array\") end"
    raw
  |> List.map parse_position_detail

let parse_balance raw =
  match
    jq_fields "balance"
      "if .errmsg == \"\" then [\"ok\", (.acc_balance | tostring)] else [\"error\", .errmsg] end | @tsv"
      raw
  with
  | ["ok"; acc_balance] -> float_field "balance acc_balance" acc_balance
  | ["error"; message] -> failwith message
  | _ -> failwith "invalid Shioaji balance response"

let parse_settlement = function
  | [date; amount; day] ->
      let day = nonnegative_int_field "settlement T" day in
      (match day <= 2 with
       | true ->
           { date = date_field "settlement date" date;
             amount = float_field "settlement amount" amount;
             day }
       | false -> failf "invalid Shioaji settlement T value %d" day)
  | _ -> failwith "invalid Shioaji settlements response"

let parse_settlements raw =
  jq_rows "settlements"
    "if type == \"array\" then map(if ((.date | type) == \"string\" and (.amount | type) == \"number\" and (.T | type) == \"number\") then [.date, (.amount | tostring), (.T | tostring)] | @tsv else error(\"invalid settlement fields\") end) | join(\"\\n\") else error(\"expected settlement array\") end"
    raw
  |> List.map parse_settlement

let parse_placed raw =
  match jq_fields "place_order" "[.order.id, .status.status] | @tsv" raw with
  | [order_id; status] -> { order_id; status }
  | _ -> failwith "invalid Shioaji place_order response"

let parse_deal (notional, quantity) value =
  match String.split_on_char ',' value with
  | [price; lots] ->
      let price = positive_float_field "trade deal price" price in
      let lots = positive_int_field "trade deal quantity" lots in
      let next_notional = notional +. (price *. float_of_int lots) in
      (match Float.is_finite next_notional && lots <= max_int - quantity with
       | true -> next_notional, quantity + lots
       | false -> failwith "invalid Shioaji trade deal value")
  | _ -> failwith "invalid Shioaji trades response"

let deal_fields value =
  match value with
  | "" -> None, 0
  | _ ->
      let notional, quantity =
        List.fold_left parse_deal (0., 0) (String.split_on_char ';' value)
      in
      let price = notional /. float_of_int quantity in
      match Float.is_finite price with
      | true -> Some price, quantity
      | false -> failwith "invalid Shioaji trade deal value"

let parse_trade = function
  | [order_id; code; action; cond; status; order_lots; deal_lots;
     deals; order_datetime] ->
      let order_lots =
        nonnegative_int_field "trade order_quantity" order_lots
      in
      let deal_lots = nonnegative_int_field "trade deal_quantity" deal_lots in
      let deal_price, confirmed_lots = deal_fields deals in
      (match deal_lots <= order_lots && confirmed_lots = deal_lots with
       | true ->
           { order_id;
             code;
             action;
             cond;
             status;
             order_lots;
             deal_lots;
             deal_price;
             order_datetime }
       | false -> failwith "invalid Shioaji trade quantities")
  | _ -> failwith "invalid Shioaji trades response"

let parse_orders_today ~code ~today raw =
  jq_rows
    ~args:["--arg"; "code"; code; "--arg"; "today"; today]
    "trades"
    "def order_time: if (.status.order_datetime | type) == \"string\" then .status.order_datetime elif (.status.order_ts | type) == \"number\" then ((.status.order_ts | floor) + 28800 | strftime(\"%Y-%m-%dT%H:%M:%S\")) + \"+08:00\" else error(\"invalid trade timestamp\") end; map(select(.contract.code == $code and (order_time | startswith($today)))) | map(if ((.status.order_quantity | type) == \"number\" and (.status.deal_quantity | type) == \"number\" and (.status.deals | type) == \"array\" and all(.status.deals[]; (.price | type) == \"number\" and (.quantity | type) == \"number\")) then [.order.id, .contract.code, .order.action, .order.order_cond, .status.status, (.status.order_quantity | tostring), (.status.deal_quantity | tostring), (.status.deals | map([(.price | tostring), (.quantity | tostring)] | join(\",\")) | join(\";\")), order_time] | @tsv else error(\"invalid trade fields\") end) | join(\"\\n\")"
    raw
  |> List.map parse_trade

let jq_object label args expression =
  match run_capture "/usr/bin/jq" (["-nc"] @ args @ [expression]) with
  | status, output when process_ok status -> String.trim output
  | _ -> failf "jq failed while building Shioaji %s request" label

let require_env name =
  match Sys.getenv_opt name with
  | Some value when String.trim value <> "" -> value
  | _ -> failf "export %s=\"your_shioaji_key\"" name

let request ?(method_ = "GET") ?body ?(auth = true) ~path () =
  let headers =
    match auth with
    | false -> "Content-Type: application/json\n"
    | true ->
        Printf.sprintf
          "Authorization: Bearer %s:%s\nContent-Type: application/json\n"
          (require_env "SJ_API_KEY") (require_env "SJ_SEC_KEY")
  in
  with_temp ".headers" (fun header_path ->
    let () = write_text header_path headers in
    with_temp ".response" (fun response_path ->
      let perform body_args =
        let status, http =
          run_capture "/usr/bin/curl"
            (["-sS"; "--max-time"; "60"; "-X"; method_;
              "-H"; "@" ^ header_path;
              "-o"; response_path; "-w"; "%{http_code}"]
             @ body_args @ [base_url () ^ path])
        in
        match process_ok status with
        | false -> failwith "curl failed while calling Shioaji"
        | true ->
            let http_code =
              try int_of_string (String.trim http) with Failure _ ->
                failf "invalid Shioaji HTTP status %S" (String.trim http)
            in
            read_text response_path, http_code
      in
      match body with
      | None -> perform []
      | Some contents ->
          with_temp ".body" (fun body_path ->
            let () = write_text body_path contents in
            perform ["--data-binary"; "@" ^ body_path])))

let expect_ok label parse (raw, http_code) =
  match http_code >= 200 && http_code < 300 with
  | true -> parse raw
  | false -> failf "Shioaji %s request failed with HTTP %d" label http_code

let info () =
  request ~auth:false ~path:"/api/v1/info" () |> expect_ok "info" parse_info

let snapshot ~exchange ~code =
  let body =
    jq_object "snapshot"
      ["--arg"; "exchange"; exchange; "--arg"; "code"; code]
      "{contracts:[{security_type:\"STK\",exchange:$exchange,code:$code}]}"
  in
  request ~method_:"POST" ~body ~path:"/api/v1/data/snapshots" ()
  |> expect_ok "snapshot" parse_snapshot

let positions () =
  let body =
    jq_object "positions" [] "{account_type:\"S\",unit:\"Common\"}"
  in
  request ~method_:"POST" ~body ~path:"/api/v1/portfolio/position_unit" ()
  |> expect_ok "positions" parse_positions

let position_details ~detail_id =
  let detail_id =
    match detail_id >= 0 with
    | true -> detail_id
    | false -> failf "invalid Shioaji position detail id %d" detail_id
  in
  let body =
    jq_object "position_detail"
      ["--argjson"; "detail_id"; string_of_int detail_id]
      "{account_type:\"S\",detail_id:$detail_id}"
  in
  request ~method_:"POST" ~body ~path:"/api/v1/portfolio/position_detail" ()
  |> expect_ok "position detail" parse_position_details

let balance () =
  let body = jq_object "balance" [] "{}" in
  request ~method_:"POST" ~body ~path:"/api/v1/portfolio/account_balance" ()
  |> expect_ok "balance" parse_balance

let settlements () =
  let body = jq_object "settlements" [] "{account_type:\"S\"}" in
  request ~method_:"POST" ~body ~path:"/api/v1/portfolio/settlements" ()
  |> expect_ok "settlements" parse_settlements

let place_order order =
  let lots =
    match order.lots > 0 with
    | true -> order.lots
    | false -> failf "invalid Shioaji order quantity %d" order.lots
  in
  let body =
    jq_object "place_order"
      ["--arg"; "exchange"; order.exchange;
       "--arg"; "code"; order.code;
       "--arg"; "action"; order.action;
       "--argjson"; "lots"; string_of_int lots;
       "--arg"; "cond"; order.cond;
       "--arg"; "custom_field"; order.custom_field]
      "{contract:{security_type:\"STK\",exchange:$exchange,code:$code},stock_order:{action:$action,price:0,quantity:$lots,price_type:\"MKT\",order_type:\"IOC\",order_lot:\"Common\",order_cond:$cond,custom_field:$custom_field}}"
  in
  request ~method_:"POST" ~body ~path:"/api/v1/order/place_order" ()
  |> expect_ok "order submission" parse_placed

let orders_today ~code ~today =
  let body = jq_object "trades" [] "{}" in
  request ~method_:"POST" ~body ~path:"/api/v1/order/trades" ()
  |> expect_ok "order status" (parse_orders_today ~code ~today)
