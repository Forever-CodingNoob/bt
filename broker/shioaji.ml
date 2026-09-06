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
  code : string;
  cond : string;
  lots : int;
  yd_lots : int;
  avg_price : float;
  last_price : float;
  loan_amount : float;
  interest : float;
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
  try int_of_string value with Failure _ ->
    failf "invalid Shioaji %s value %S" label value

let float_field label value =
  try float_of_string value with Failure _ ->
    failf "invalid Shioaji %s value %S" label value

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
        open_ = float_field "snapshot open" open_;
        high = float_field "snapshot high" high;
        low = float_field "snapshot low" low;
        close = float_field "snapshot close" close;
        bid = float_field "snapshot buy_price" bid;
        ask = float_field "snapshot sell_price" ask;
        total_volume = float_field "snapshot total_volume" total_volume }
  | _ -> failwith "invalid Shioaji snapshot response"

let parse_position = function
  | [code; cond; lots; yd_lots; avg_price; last_price; loan_amount; interest] ->
      { code;
        cond;
        lots = int_field "position quantity" lots;
        yd_lots = int_field "position yd_quantity" yd_lots;
        avg_price = float_field "position price" avg_price;
        last_price = float_field "position last_price" last_price;
        loan_amount = float_field "position margin_purchase_amount" loan_amount;
        interest = float_field "position interest" interest }
  | _ -> failwith "invalid Shioaji positions response"

let parse_positions raw =
  jq_rows "positions"
    "map([.code, .cond, (.quantity | tostring), (.yd_quantity | tostring), (.price | tostring), (.last_price | tostring), (.margin_purchase_amount | tostring), (.interest | tostring)] | @tsv) | join(\"\\n\")"
    raw
  |> List.map parse_position

let parse_balance raw =
  match
    jq_fields "balance"
      "if .errmsg == \"\" then [\"ok\", (.acc_balance | tostring)] else [\"error\", .errmsg] end | @tsv"
      raw
  with
  | ["ok"; acc_balance] -> float_field "balance acc_balance" acc_balance
  | ["error"; message] -> failwith message
  | _ -> failwith "invalid Shioaji balance response"

let parse_placed raw =
  match jq_fields "place_order" "[.order.id, .status.status] | @tsv" raw with
  | [order_id; status] -> { order_id; status }
  | _ -> failwith "invalid Shioaji place_order response"

let parse_trade = function
  | [order_id; code; action; cond; status; order_lots; deal_lots;
     deal_price; order_datetime] ->
      { order_id;
        code;
        action;
        cond;
        status;
        order_lots = int_field "trade order_quantity" order_lots;
        deal_lots = int_field "trade deal_quantity" deal_lots;
        deal_price =
          (match deal_price with
           | "NONE" -> None
           | value -> Some (float_field "trade deals[0].price" value));
        order_datetime }
  | _ -> failwith "invalid Shioaji update_status response"

let parse_orders_today ~code ~today raw =
  jq_rows
    ~args:["--arg"; "code"; code; "--arg"; "today"; today]
    "update_status"
    "map(select(.contract.code == $code and (.status.order_datetime | startswith($today)))) | map([.order.id, .contract.code, .order.action, .order.order_cond, .status.status, (.status.order_quantity | tostring), (.status.deal_quantity | tostring), (if (.status.deals | length) == 0 then \"NONE\" else (.status.deals[0].price | tostring) end), .status.order_datetime] | @tsv) | join(\"\\n\")"
    raw
  |> List.map parse_trade

let jq_object label args expression =
  match run_capture "/usr/bin/jq" (["-nc"] @ args @ [expression]) with
  | status, output when process_ok status -> String.trim output
  | _ -> failf "jq failed while building Shioaji %s request" label

let request ?(method_ = "GET") ?body ~path () =
  with_temp ".response" (fun response_path ->
    let perform body_args =
      let status, http =
        run_capture "/usr/bin/curl"
          (["-sS"; "--max-time"; "60"; "-X"; method_;
            "-H"; "Content-Type: application/json";
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
          perform ["--data-binary"; "@" ^ body_path]))

let expect_ok label parse (raw, http_code) =
  match http_code >= 200 && http_code < 300 with
  | true -> parse raw
  | false -> failf "Shioaji %s request failed with HTTP %d" label http_code

let info () =
  request ~path:"/api/v1/info" () |> expect_ok "info" parse_info

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

let balance () =
  let body = jq_object "balance" [] "{}" in
  request ~method_:"POST" ~body ~path:"/api/v1/portfolio/account_balance" ()
  |> expect_ok "balance" parse_balance

let place_order order =
  let body =
    jq_object "place_order"
      ["--arg"; "exchange"; order.exchange;
       "--arg"; "code"; order.code;
       "--arg"; "action"; order.action;
       "--argjson"; "lots"; string_of_int order.lots;
       "--arg"; "cond"; order.cond;
       "--arg"; "custom_field"; order.custom_field]
      "{contract:{security_type:\"STK\",exchange:$exchange,code:$code},stock_order:{action:$action,price:0,quantity:$lots,price_type:\"MKT\",order_type:\"ROD\",order_lot:\"Common\",order_cond:$cond,custom_field:$custom_field}}"
  in
  request ~method_:"POST" ~body ~path:"/api/v1/order/place_order" ()
  |> expect_ok "order submission" parse_placed

let orders_today ~code ~today =
  let body = jq_object "update_status" [] "{}" in
  request ~method_:"POST" ~body ~path:"/api/v1/order/update_status" ()
  |> expect_ok "order status" (parse_orders_today ~code ~today)
