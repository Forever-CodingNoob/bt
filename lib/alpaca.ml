type mode = Paper | Live

type clock_t = {
  timestamp : string;
  is_open : bool;
  next_open : string;
  next_close : string;
}

type account_t = {
  equity : float;
  status : string;
  trading_blocked : bool;
  account_number : string;
}

type snapshot_t = {
  day_date : string;
  prev_day_date : string;
  day_open : float;
  day_high : float;
  day_low : float;
  latest : float;
  day_volume : float;
}

type order_t = {
  id : string;
  status : string;
  filled_avg_price : float option;
  filled_qty : float;
}

let failf fmt = Printf.ksprintf failwith fmt

let base_url = function
  | Paper -> "https://paper-api.alpaca.markets"
  | Live -> "https://api.alpaca.markets"

let data_url = "https://data.alpaca.markets"

let remove_if_exists path =
  try Sys.remove path with Sys_error _ -> ()

let with_temp suffix function_ =
  let path = Filename.temp_file "bt-alpaca-" suffix in
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

let jq_fields label expression raw =
  with_temp ".json" (fun input_path ->
    let () = write_text input_path raw in
    match run_capture "/usr/bin/jq" ["-er"; expression; input_path] with
    | status, output when process_ok status ->
        String.split_on_char '\t' (String.trim output)
    | _ -> failf "invalid Alpaca %s response" label)

let float_field label value =
  try float_of_string value with Failure _ ->
    failf "invalid Alpaca %s value %S" label value

let bool_field label value =
  try bool_of_string value with Invalid_argument _ ->
    failf "invalid Alpaca %s value %S" label value

let parse_clock raw =
  match
    jq_fields "clock"
      "[.timestamp, (.is_open | tostring), .next_open, .next_close] | @tsv"
      raw
  with
  | [timestamp; is_open; next_open; next_close] ->
      { timestamp;
        is_open = bool_field "clock is_open" is_open;
        next_open;
        next_close }
  | _ -> failwith "invalid Alpaca clock response"

let parse_account raw =
  match
    jq_fields "account"
      "[.equity, .status, (.trading_blocked | tostring), .account_number] | @tsv"
      raw
  with
  | [equity; status; trading_blocked; account_number] ->
      { equity = float_field "account equity" equity;
        status;
        trading_blocked = bool_field "account trading_blocked" trading_blocked;
        account_number }
  | _ -> failwith "invalid Alpaca account response"

let parse_position_qty ~http_code raw =
  match http_code with
  | 200 ->
      (match jq_fields "position" ".qty | tostring" raw with
       | [qty] -> float_field "position qty" qty
       | _ -> failwith "invalid Alpaca position response")
  | 404 -> 0.
  | code -> failf "Alpaca position request failed with HTTP %d" code

let parse_snapshot raw =
  match
    jq_fields "snapshot"
      "[.dailyBar.t[0:10], .prevDailyBar.t[0:10], .dailyBar.o, .dailyBar.h, .dailyBar.l, .latestTrade.p, .dailyBar.v] | @tsv"
      raw
  with
  | [day_date; prev_day_date; day_open; day_high; day_low; latest; day_volume] ->
      { day_date;
        prev_day_date;
        day_open = float_field "snapshot dailyBar.o" day_open;
        day_high = float_field "snapshot dailyBar.h" day_high;
        day_low = float_field "snapshot dailyBar.l" day_low;
        latest = float_field "snapshot latestTrade.p" latest;
        day_volume = float_field "snapshot dailyBar.v" day_volume }
  | _ -> failwith "invalid Alpaca snapshot response"

let parse_order raw =
  match
    jq_fields "order"
      "[.id, .status, (.filled_avg_price // \"\"), .filled_qty] | @tsv"
      raw
  with
  | [id; status; filled_avg_price; filled_qty] ->
      { id;
        status;
        filled_avg_price =
          (match filled_avg_price with
           | "" -> None
           | value -> Some (float_field "order filled_avg_price" value));
        filled_qty = float_field "order filled_qty" filled_qty }
  | _ -> failwith "invalid Alpaca order response"

let require_env name =
  match Sys.getenv_opt name with
  | Some value when String.trim value <> "" -> value
  | _ -> failf "export %s=\"your_api_token\"" name

let is_unreserved = function
  | 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '-' | '_' | '.' | '~' -> true
  | _ -> false

let url_encode value =
  let hex = "0123456789ABCDEF" in
  let buffer = Buffer.create (String.length value) in
  let () =
    String.iter
      (fun ch ->
        match is_unreserved ch with
        | true -> Buffer.add_char buffer ch
        | false ->
            let code = Char.code ch in
            let () = Buffer.add_char buffer '%' in
            let () = Buffer.add_char buffer hex.[code lsr 4] in
            Buffer.add_char buffer hex.[code land 0x0f])
      value
  in
  Buffer.contents buffer

let request ?(method_ = "GET") ?body ?root mode ~path =
  let key_id = require_env "APCA_API_KEY_ID" in
  let secret_key = require_env "APCA_API_SECRET_KEY" in
  let root = match root with Some value -> value | None -> base_url mode in
  with_temp ".headers" (fun header_path ->
    let () =
      write_text header_path
        (Printf.sprintf
           "APCA-API-KEY-ID: %s\nAPCA-API-SECRET-KEY: %s\nContent-Type: application/json\n"
           key_id secret_key)
    in
    with_temp ".response" (fun response_path ->
      let perform body_args =
        let status, http =
          run_capture "/usr/bin/curl"
            (["-sS"; "-X"; method_; "-H"; "@" ^ header_path;
              "-o"; response_path; "-w"; "%{http_code}"]
             @ body_args @ [root ^ path])
        in
        match process_ok status with
        | false -> failwith "curl failed while calling Alpaca"
        | true ->
            let http_code =
              try int_of_string (String.trim http) with Failure _ ->
                failf "invalid Alpaca HTTP status %S" (String.trim http)
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
  match http_code with
  | 200 -> parse raw
  | code -> failf "Alpaca %s request failed with HTTP %d" label code

let clock mode =
  request mode ~path:"/v2/clock" |> expect_ok "clock" parse_clock

let account mode =
  request mode ~path:"/v2/account" |> expect_ok "account" parse_account

let position_qty mode symbol =
  let raw, http_code =
    request mode ~path:("/v2/positions/" ^ url_encode symbol)
  in
  parse_position_qty ~http_code raw

let snapshot symbol =
  request ~root:data_url Paper
    ~path:("/v2/stocks/" ^ url_encode symbol ^ "/snapshot?feed=iex")
  |> expect_ok "snapshot" parse_snapshot

let order_body ~symbol ~qty ~side ~client_order_id =
  let side = match side with `Buy -> "buy" | `Sell -> "sell" in
  match
    run_capture "/usr/bin/jq"
      ["-nc";
       "--arg"; "symbol"; symbol;
       "--argjson"; "qty"; string_of_int qty;
       "--arg"; "side"; side;
       "--arg"; "client_order_id"; client_order_id;
       "{symbol:$symbol,qty:$qty,side:$side,type:\"market\",time_in_force:\"cls\",client_order_id:$client_order_id}"]
  with
  | status, body when process_ok status -> body
  | _ -> failwith "jq failed while building Alpaca order"

let submit_moc mode ~symbol ~qty ~side ~client_order_id =
  let () =
    match qty > 0 with
    | true -> ()
    | false -> invalid_arg "Alpaca.submit_moc: qty must be positive"
  in
  let body = order_body ~symbol ~qty ~side ~client_order_id in
  request ~method_:"POST" ~body mode ~path:"/v2/orders"
  |> expect_ok "order submission" parse_order

let order_by_client_id mode client_order_id =
  let raw, http_code =
    request mode
      ~path:("/v2/orders:by_client_order_id?client_order_id=" ^
             url_encode client_order_id)
  in
  match http_code with
  | 200 -> Some (parse_order raw)
  | 404 | 422 -> None
  | code -> failf "Alpaca order lookup failed with HTTP %d" code
