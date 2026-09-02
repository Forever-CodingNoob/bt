type bar = {
  date : string;
  o : float;
  h : float;
  l : float;
  c : float;
  v : float;
}
type dividend = {
  ex_date : string;
  cash_per_share : float;
  pay_date : string;
}

type loaded_asset = {
  money : bar array;
  signal : bar array;
  dividends : dividend array;
}


let failf fmt = Printf.ksprintf failwith fmt

let market_name market =
  match String.lowercase_ascii market with
  | "tw" -> "tw"
  | "us" -> "us"
  | _ -> failf "invalid market %S (expected tw or us)" market

let check_symbol symbol =
  if symbol = "" || symbol = "." || symbol = ".." then
    failwith "symbol must not be empty"
  else if
    String.exists
      (fun ch -> ch = '/' || ch = '\\' || ch = '\000')
      symbol
  then failf "invalid symbol %S" symbol

let leap_year year =
  year mod 400 = 0 || (year mod 4 = 0 && year mod 100 <> 0)

let days_in_month year month =
  match month with
  | 1 | 3 | 5 | 7 | 8 | 10 | 12 -> 31
  | 4 | 6 | 9 | 11 -> 30
  | 2 -> if leap_year year then 29 else 28
  | _ -> 0

let parse_date label value =
  try
    let () =
      if String.length value <> 10 || value.[4] <> '-' || value.[7] <> '-' then
        raise Exit
    in
    let year = int_of_string (String.sub value 0 4) in
    let month = int_of_string (String.sub value 5 2) in
    let day = int_of_string (String.sub value 8 2) in
    let () =
      if year < 1 || month < 1 || month > 12 || day < 1 ||
         day > days_in_month year month then
        raise Exit
    in
    year, month, day
  with Failure _ | Exit ->
    failf "invalid %s date %S (expected YYYY-MM-DD)" label value

let next_date value =
  let year, month, day = parse_date "cached" value in
  let last_day = days_in_month year month in
  if day < last_day then
    Printf.sprintf "%04d-%02d-%02d" year month (day + 1)
  else if month < 12 then
    Printf.sprintf "%04d-%02d-01" year (month + 1)
  else
    Printf.sprintf "%04d-01-01" (year + 1)

let previous_date value =
  let year, month, day = parse_date "cached" value in
  if day > 1 then
    Printf.sprintf "%04d-%02d-%02d" year month (day - 1)
  else if month > 1 then
    let previous_month = month - 1 in
    Printf.sprintf "%04d-%02d-%02d" year previous_month
      (days_in_month year previous_month)
  else
    Printf.sprintf "%04d-12-31" (year - 1)
let add_one_month value =
  let year, month, day = parse_date "cash dividend" value in
  let next_year, next_month =
    if month = 12 then year + 1, 1 else year, month + 1
  in
  Printf.sprintf "%04d-%02d-%02d" next_year next_month
    (min day (days_in_month next_year next_month))


let validate_range from_ to_ =
  let () = ignore (parse_date "from" from_) in
  let () = ignore (parse_date "to" to_) in
  if String.compare from_ to_ > 0 then
    failf "from date %s is after to date %s" from_ to_

let mkdir_p path =
  let rec collect current acc =
    if current = "" || current = "." || current = "/" then acc
    else
      let parent = Filename.dirname current in
      if parent = current then current :: acc else collect parent (current :: acc)
  in
  let make directory =
    try Unix.mkdir directory 0o755 with
    | Unix.Unix_error (Unix.EEXIST, _, _) ->
        if (Unix.stat directory).Unix.st_kind <> Unix.S_DIR then
          failf "%s exists and is not a directory" directory
  in
  List.iter make (collect path [])

let remove_if_exists path =
  try Sys.remove path with Sys_error _ -> ()

let with_temp suffix f =
  let path = Filename.temp_file "bt-" suffix in
  Fun.protect ~finally:(fun () -> remove_if_exists path) (fun () -> f path)

let rec wait_for pid =
  try snd (Unix.waitpid [] pid) with
  | Unix.Unix_error (Unix.EINTR, _, _) -> wait_for pid

let run ?(stdout = Unix.stdout) program args =
  let argv = Array.of_list (program :: args) in
  wait_for (Unix.create_process program argv Unix.stdin stdout Unix.stderr)

let run_to_file program args path =
  let fd = Unix.openfile path [Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC] 0o600 in
  Fun.protect
    ~finally:(fun () -> Unix.close fd)
    (fun () -> run ~stdout:fd program args)

let run_quiet program args =
  let fd = Unix.openfile "/dev/null" [Unix.O_WRONLY] 0 in
  Fun.protect
    ~finally:(fun () -> Unix.close fd)
    (fun () -> run ~stdout:fd program args)

let process_ok = function
  | Unix.WEXITED 0 -> true
  | Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _ -> false

let read_text path =
  let input = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in input)
    (fun () ->
      let buffer = Buffer.create 64 in
      let rec loop first =
        match input_line input with
        | line ->
            let () =
              if not first then Buffer.add_char buffer '\n'
            in
            let () = Buffer.add_string buffer line in
            loop false
        | exception End_of_file -> Buffer.contents buffer
      in
      loop true)

let is_unreserved = function
  | 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '-' | '_' | '.' | '~' -> true
  | _ -> false

let url_encode value =
  let hex = "0123456789ABCDEF" in
  let buffer = Buffer.create (String.length value) in
  let () =
    String.iter
      (fun ch ->
        if is_unreserved ch then Buffer.add_char buffer ch
        else
          let code = Char.code ch in
          let () = Buffer.add_char buffer '%' in
          let () = Buffer.add_char buffer hex.[code lsr 4] in
          Buffer.add_char buffer hex.[code land 0x0f])
      value
  in
  Buffer.contents buffer

let api_url ~dataset ~symbol ~from_ ~to_ =
  Printf.sprintf
    "https://api.finmindtrade.com/api/v4/data?dataset=%s&data_id=%s&start_date=%s&end_date=%s"
    (url_encode dataset) (url_encode symbol) (url_encode from_) (url_encode to_)

let api_url_no_id ~dataset ~from_ ~to_ =
  Printf.sprintf
    "https://api.finmindtrade.com/api/v4/data?dataset=%s&start_date=%s&end_date=%s"
    (url_encode dataset) (url_encode from_) (url_encode to_)

let curl_get ~token ~url ~output =
  with_temp ".hdr" (fun header_path ->
    let channel = open_out header_path in
    let () =
      Fun.protect
        ~finally:(fun () -> close_out channel)
        (fun () ->
          output_string channel ("Authorization: Bearer " ^ token ^ "\n"))
    in
    with_temp ".status" (fun status_path ->
      let status =
        run_to_file "/usr/bin/curl"
          ["-sfS"; "-H"; "@" ^ header_path; "-o"; output;
           "-w"; "%{http_code}"; url]
          status_path
      in
      status, String.trim (read_text status_path)))

let jq_message json_path =
  with_temp ".msg" (fun output ->
    let status =
      run_to_file "/usr/bin/jq"
        ["-r"; ".msg // \"unknown API error\""; json_path]
        output
    in
    if process_ok status then String.trim (read_text output)
    else "unknown API error")
let jq_status json_path =
  with_temp ".status" (fun output ->
    let status =
      run_to_file "/usr/bin/jq"
        ["-r"; ".status // empty | tostring"; json_path]
        output
    in
    if process_ok status then Some (String.trim (read_text output))
    else None)


let check_api_response json_path =
  match run_quiet "/usr/bin/jq" ["-e"; ".status == 200"; json_path] with
  | Unix.WEXITED 0 -> `Ok
  | Unix.WEXITED 1 -> `Error (jq_message json_path)
  | _ -> failwith "jq failed while validating the FinMind response"

let require_price_response json_path process_status http_code =
  if http_code = "402" then failwith "FinMind quota exceeded (HTTP 402)"
  else if not (process_ok process_status) || http_code <> "200" then
    failf "fetch failed for api.finmindtrade.com (HTTP %s)"
      (if http_code = "" || http_code = "000" then "unavailable" else http_code)
  else
    match check_api_response json_path with
    | `Ok -> ()
    | `Error message -> failf "FinMind API error: %s" message

let unquote field =
  let length = String.length field in
  if length >= 2 && field.[0] = '"' && field.[length - 1] = '"' then
    String.sub field 1 (length - 2)
  else
    field

let normalize_row line =
  match String.split_on_char ',' line with
  | [] -> line
  | date :: fields -> String.concat "," (unquote date :: fields)

let row_date line =
  match String.split_on_char ',' line with
  | date :: _ -> unquote date
  | [] -> ""

let last_cached_date path =
  if not (Sys.file_exists path) then None
  else
    let input = open_in path in
    Fun.protect
      ~finally:(fun () -> close_in input)
      (fun () ->
        let rec loop last =
          match input_line input with
          | line ->
              let date = row_date line in
              loop (if date = "" || date = "date" then last else Some date)
          | exception End_of_file -> last
        in
        loop None)

let first_cached_date path =
  if not (Sys.file_exists path) then None
  else
    let input = open_in path in
    Fun.protect
      ~finally:(fun () -> close_in input)
      (fun () ->
        match input_line input with
        | exception End_of_file -> None
        | _header ->
            (match input_line input with
             | exception End_of_file -> None
             | line ->
                 (match row_date line with "" -> None | date -> Some date)))

let should_probe_head ~from_ ~first_cached =
  match from_ with
  | None -> false
  | Some date -> String.compare date first_cached < 0

let append_rows ~header ~rows_path ~cache_path ~after =
  let needs_header =
    not (Sys.file_exists cache_path) || (Unix.stat cache_path).Unix.st_size = 0
  in
  let output =
    open_out_gen [Open_wronly; Open_creat; Open_append; Open_binary] 0o644 cache_path
  in
  Fun.protect
    ~finally:(fun () -> close_out output)
    (fun () ->
      let () =
        if needs_header then output_string output (header ^ "\n")
      in
      let input = open_in rows_path in
      Fun.protect
        ~finally:(fun () -> close_in input)
        (fun () ->
          let rec loop () =
            match input_line input with
            | line ->
                let normalized = normalize_row line in
                let date = row_date normalized in
                let () =
                  if date <> "" &&
                     (match after with
                      | None -> true
                      | Some previous -> String.compare date previous > 0)
                  then output_string output (normalized ^ "\n")
                in
                loop ()
            | exception End_of_file -> ()
          in
          loop ()))

let prepend_rows ~header ~rows_path ~cache_path ~before =
  let directory = Filename.dirname cache_path in
  let temporary = Filename.temp_file ~temp_dir:directory ".bt-prepend-" ".csv" in
  let completed = ref false in
  Fun.protect
    ~finally:(fun () -> if not !completed then remove_if_exists temporary)
    (fun () ->
      let () =
        let output = open_out_bin temporary in
        Fun.protect
          ~finally:(fun () -> close_out output)
          (fun () ->
            let () = output_string output (header ^ "\n") in
            let rows = open_in rows_path in
            let () =
              Fun.protect
                ~finally:(fun () -> close_in rows)
                (fun () ->
                  let rec loop () =
                    match input_line rows with
                    | line ->
                        let normalized = normalize_row line in
                        let date = row_date normalized in
                        let () =
                          if date <> "" && String.compare date before < 0 then
                            output_string output (normalized ^ "\n")
                        in
                        loop ()
                    | exception End_of_file -> ()
                  in
                  loop ())
            in
            let cache = open_in cache_path in
            Fun.protect
              ~finally:(fun () -> close_in cache)
              (fun () ->
                let () =
                  match input_line cache with
                  | _header -> ()
                  | exception End_of_file -> ()
                in
                let rec loop () =
                  match input_line cache with
                  | line ->
                      let () = output_string output (line ^ "\n") in
                      loop ()
                  | exception End_of_file -> ()
                in
                loop ()))
      in
      let () = Sys.rename temporary cache_path in
      completed := true)

let rewrite_rows ~header ~rows_path ~cache_path =
  let directory = Filename.dirname cache_path in
  let temporary = Filename.temp_file ~temp_dir:directory ".bt-div-" ".csv" in
  let completed = ref false in
  Fun.protect
    ~finally:(fun () -> if not !completed then remove_if_exists temporary)
    (fun () ->
      let () =
        let output = open_out_bin temporary in
        Fun.protect
          ~finally:(fun () -> close_out output)
          (fun () ->
            let () = output_string output (header ^ "\n") in
            let input = open_in rows_path in
            Fun.protect
              ~finally:(fun () -> close_in input)
              (fun () ->
                let rec loop () =
                  match input_line input with
                  | line ->
                      let () =
                        if line <> "" then
                          output_string output (normalize_row line ^ "\n")
                      in
                      loop ()
                  | exception End_of_file -> ()
                in
                loop ()))
      in
      let () = Sys.rename temporary cache_path in
      completed := true)

let transform_json ~args ~expression ~json_path ~rows_path =
  match
    run_to_file "/usr/bin/jq" (("-r" :: args) @ [expression; json_path])
      rows_path
  with
  | Unix.WEXITED 0 -> ()
  | _ -> failwith "jq failed while converting the FinMind response"

let fetch_rows ~token ~dataset ~symbol ~from_ ~to_ ~expression ~consume =
  with_temp ".json" (fun json_path ->
    let url = api_url ~dataset ~symbol ~from_ ~to_ in
    let process_status, http_code = curl_get ~token ~url ~output:json_path in
    let () = require_price_response json_path process_status http_code in
    with_temp ".rows" (fun rows_path ->
      let () = transform_json ~args:[] ~expression ~json_path ~rows_path in
      consume rows_path))

let fetch_prices ~token ~market ~symbol ~from_ ~to_ ~cache_path =
  let default_from = "1994-10-01" in
  if market = "tw" then
    let tw_expression =
      ".data[] | [.date, .open, .max, .min, .close, .Trading_Volume] | @csv"
    in
    let tw_header = "date,open,high,low,close,volume" in
    let () =
      match from_, first_cached_date cache_path with
      | Some start_date, Some first
        when should_probe_head ~from_ ~first_cached:first ->
          let day_before = previous_date first in
          fetch_rows ~token ~dataset:"TaiwanStockPrice" ~symbol
            ~from_:start_date ~to_:day_before
            ~expression:tw_expression
            ~consume:(fun rows_path ->
              prepend_rows ~header:tw_header ~rows_path ~cache_path
                ~before:first)
      | _ -> ()
    in
    let last_date = last_cached_date cache_path in
    let start_date =
      match last_date, from_ with
      | Some date, _ -> next_date date
      | None, Some date -> date
      | None, None -> default_from
    in
    let () =
      if String.compare start_date to_ <= 0 then
        fetch_rows ~token ~dataset:"TaiwanStockPrice" ~symbol
          ~from_:start_date ~to_
          ~expression:tw_expression
          ~consume:(fun rows_path ->
            append_rows ~header:tw_header
              ~rows_path ~cache_path ~after:last_date)
    in
    ()
  else
    let first = first_cached_date cache_path in
    let start_date =
      match from_, first with
      | None, Some date -> date
      | None, None -> default_from
      | Some requested, Some date when String.compare date requested < 0 ->
          date
      | Some requested, _ -> requested
    in
    fetch_rows ~token ~dataset:"USStockPrice" ~symbol
      ~from_:start_date ~to_
      ~expression:".data[] | [.date, .Open, .High, .Low, .Close, .Adj_Close, .Volume] | @csv"
      ~consume:(fun rows_path ->
        rewrite_rows ~header:"date,open,high,low,close,adj_close,volume"
          ~rows_path ~cache_path)

let fetch_dividends ~token ~symbol ~to_ ~cache_path =
  with_temp ".json" (fun json_path ->
    let url =
      api_url ~dataset:"TaiwanStockDividendResult" ~symbol
        ~from_:"1900-01-01" ~to_
    in
    let process_status, http_code = curl_get ~token ~url ~output:json_path in
    let keep reason =
      Printf.eprintf "warning: dividend fetch failed (%s); %s\n" reason
        (if Sys.file_exists cache_path then "keeping cached dividend data"
         else "prices will be unadjusted for dividends")
    in
    if not (process_ok process_status) || http_code <> "200" then
      keep
        ("HTTP " ^
         (if http_code = "" || http_code = "000" then "unavailable"
          else http_code))
    else
      match check_api_response json_path with
      | `Error message -> keep message
      | `Ok ->
          with_temp ".rows" (fun rows_path ->
            let () =
              transform_json ~args:[]
                ~expression:(
                  ".data[] | select(.before_price != null and .after_price != null) " ^
                  "| select((.before_price | tonumber) != 0) " ^
                  "| [.date, ((.after_price | tonumber) / (.before_price | tonumber))] | @csv")
                ~json_path ~rows_path
            in
            rewrite_rows ~header:"date,factor" ~rows_path ~cache_path))

let event_expression ~before ~after =
  ".data[] | select(.stock_id == $sym) " ^
  "| select(." ^ before ^ " != null and ." ^ after ^ " != null) " ^
  "| select((." ^ before ^ " | tonumber) != 0) " ^
  "| [.date, ((." ^ after ^ " | tonumber) / (." ^ before ^
  " | tonumber))] | @csv"

let event_sources = [
  "TaiwanStockSplitPrice", "before_price", "after_price", true;
  "TaiwanStockCapitalReductionReferencePrice",
    "ClosingPriceonTheLastTradingDay", "PostReductionReferencePrice", true;
  "TaiwanStockParValueChange", "before_close", "after_ref_close", false;
]

let non_empty_lines path =
  List.filter
    (fun line -> String.trim line <> "")
    (String.split_on_char '\n' (read_text path))

let fetch_events ~token ~symbol ~to_ ~cache_path =
  let keep reason =
    Printf.eprintf "warning: events fetch failed (%s); %s\n" reason
      (if Sys.file_exists cache_path then "keeping cached event data"
       else "prices will be unadjusted for splits/reductions")
  in
  let fetch_one (dataset, before, after, use_data_id) =
    with_temp ".json" (fun json_path ->
      let url =
        if use_data_id then api_url ~dataset ~symbol ~from_:"1900-01-01" ~to_
        else api_url_no_id ~dataset ~from_:"1900-01-01" ~to_
      in
      let process_status, http_code = curl_get ~token ~url ~output:json_path in
      if not (process_ok process_status) || http_code <> "200" then
        let () =
          keep
            (dataset ^ ": HTTP " ^
             (if http_code = "" || http_code = "000" then "unavailable"
              else http_code))
        in
        None
      else
        match check_api_response json_path with
        | `Error message ->
            let () = keep (dataset ^ ": " ^ message) in
            None
        | `Ok ->
            with_temp ".rows" (fun rows_path ->
              let () =
                transform_json ~args:["--arg"; "sym"; symbol]
                  ~expression:(event_expression ~before ~after)
                  ~json_path ~rows_path
              in
              Some (non_empty_lines rows_path)))
  in
  let rec collect acc = function
    | [] -> Some (List.concat (List.rev acc))
    | source :: rest ->
        (match fetch_one source with
         | None -> None
         | Some rows -> collect (rows :: acc) rest)
  in
  match collect [] event_sources with
  | None -> ()
  | Some rows ->
      let rows = List.sort String.compare rows in
      with_temp ".rows" (fun rows_path ->
        let output = open_out rows_path in
        let () =
          Fun.protect
            ~finally:(fun () -> close_out output)
            (fun () ->
              List.iter (fun row -> output_string output (row ^ "\n")) rows)
        in
        rewrite_rows ~header:"date,factor" ~rows_path ~cache_path)

let fetch_stockinfo ~token ~symbol ~cache_path =
  with_temp ".json" (fun json_path ->
    let url =
      Printf.sprintf
        "https://api.finmindtrade.com/api/v4/data?dataset=TaiwanStockInfo&data_id=%s"
        (url_encode symbol)
    in
    let process_status, http_code = curl_get ~token ~url ~output:json_path in
    let keep reason =
      Printf.eprintf "warning: stockinfo fetch failed (%s); %s\n" reason
        (if Sys.file_exists cache_path then "keeping cached stock info"
         else "financing ratios will default to TWSE 60%")
    in
    if not (process_ok process_status) || http_code <> "200" then
      keep
        ("HTTP " ^
         (if http_code = "" || http_code = "000" then "unavailable"
          else http_code))
    else
      match check_api_response json_path with
      | `Error message -> keep message
      | `Ok ->
          with_temp ".rows" (fun rows_path ->
            let () =
              transform_json ~args:[]
                ~expression:(
                  ".data[] | select(.type == \"twse\" or .type == \"tpex\") " ^
                  "| [.stock_id, .type, .date] | @csv")
                ~json_path ~rows_path
            in
            let new_rows = non_empty_lines rows_path in
            let old_rows =
              if Sys.file_exists cache_path then
                List.filter
                  (fun line ->
                    match String.split_on_char ',' line with
                    | stock_id :: _ -> unquote stock_id <> symbol
                    | _ -> false)
                  (List.tl (String.split_on_char '\n' (read_text cache_path)))
              else []
            in
            with_temp ".merged" (fun merged_path ->
              let output = open_out merged_path in
              let () =
                Fun.protect
                  ~finally:(fun () -> close_out output)
                  (fun () ->
                    List.iter
                      (fun row ->
                        if String.trim row <> "" then
                          output_string output (normalize_row row ^ "\n"))
                      (old_rows @ new_rows))
              in
              rewrite_rows ~header:"stock_id,type,date"
                ~rows_path:merged_path ~cache_path)))


let float_field path line_number name value =
  try float_of_string value with Failure _ ->
    failf "%s:%d: invalid %s value %S" path line_number name value

let back_adjust bars dividends =
  let () =
    Array.sort (fun left right -> String.compare left.date right.date) bars
  in
  let () =
    Array.sort
      (fun (left, _) (right, _) -> String.compare left right)
      dividends
  in
  let rec descend bar_date dividend_index factor =
    if dividend_index >= 0 &&
       String.compare (fst dividends.(dividend_index)) bar_date > 0 then
      let factor = factor *. snd dividends.(dividend_index) in
      descend bar_date (dividend_index - 1) factor
    else dividend_index, factor
  in
  let rec adjust bar_index dividend_index factor =
    if bar_index < 0 then ()
    else
      let dividend_index, factor =
        descend bars.(bar_index).date dividend_index factor
      in
      let current = bars.(bar_index) in
      let () =
        bars.(bar_index) <-
          { current with
            o = current.o *. factor;
            h = current.h *. factor;
            l = current.l *. factor;
            c = current.c *. factor }
      in
      adjust (bar_index - 1) dividend_index factor
  in
  adjust (Array.length bars - 1) (Array.length dividends - 1) 1.

let back_adjust_volume bars events =
  let () =
    Array.sort
      (fun (left, _) (right, _) -> String.compare left right)
      events
  in
  let rec descend bar_date event_index factor =
    if event_index >= 0 &&
       String.compare (fst events.(event_index)) bar_date > 0 then
      let factor = factor *. snd events.(event_index) in
      descend bar_date (event_index - 1) factor
    else event_index, factor
  in
  let rec adjust bar_index event_index factor =
    if bar_index < 0 then ()
    else
      let event_index, factor =
        descend bars.(bar_index).date event_index factor
      in
      let current = bars.(bar_index) in
      let () =
        bars.(bar_index) <-
          { current with v = current.v *. (1. /. factor) }
      in
      adjust (bar_index - 1) event_index factor
  in
  adjust (Array.length bars - 1) (Array.length events - 1) 1.
let restate_dividend_cash dividends events =
  let dividends = Array.copy dividends in
  let events = Array.copy events in
  let () =
    Array.sort
      (fun left right -> String.compare left.ex_date right.ex_date)
      dividends
  in
  let () =
    Array.sort
      (fun (left, _) (right, _) -> String.compare left right)
      events
  in
  let rec descend ex_date event_index factor =
    if event_index >= 0 &&
       String.compare (fst events.(event_index)) ex_date >= 0 then
      let factor = factor *. snd events.(event_index) in
      descend ex_date (event_index - 1) factor
    else
      event_index, factor
  in
  let rec adjust dividend_index event_index factor =
    if dividend_index < 0 then ()
    else
      let current = dividends.(dividend_index) in
      let event_index, factor =
        descend current.ex_date event_index factor
      in
      let () =
        dividends.(dividend_index) <-
          { current with
            cash_per_share = current.cash_per_share *. factor }
      in
      adjust (dividend_index - 1) event_index factor
  in
  let () =
    adjust (Array.length dividends - 1) (Array.length events - 1) 1.
  in
  dividends

let read_us_planes path =
  let input = open_in path in
  Fun.protect
    ~finally:(fun () -> close_in input)
    (fun () ->
      let header =
        match input_line input with
        | line -> line
        | exception End_of_file -> ""
      in
      let () =
        if header <> "date,open,high,low,close,adj_close,volume" then
          failf "%s: expected header date,open,high,low,close,adj_close,volume"
            path
      in
      let rec read_rows line_number rows =
        match input_line input with
        | line when line = "" -> read_rows (line_number + 1) rows
        | line ->
            let fields = String.split_on_char ',' line in
            let money_bar, signal_bar, adjusted_close, ratio =
              match fields with
              | [date; o; h; l; c; adj_close; v] ->
                  let date = unquote date in
                  let o = float_field path line_number "open" o in
                  let h = float_field path line_number "high" h in
                  let l = float_field path line_number "low" l in
                  let c = float_field path line_number "close" c in
                  let v = float_field path line_number "volume" v in
                  let adjusted_close =
                    float_field path line_number "adj_close" adj_close
                  in
                  let ratio = adjusted_close /. c in
                  { date; o; h; l; c; v },
                  { date; o = o *. ratio; h = h *. ratio;
                    l = l *. ratio; c = c *. ratio; v },
                  adjusted_close, ratio
              | _ -> failf "%s:%d: malformed CSV row" path line_number
            in
            if money_bar.o > 0. && money_bar.h > 0. &&
               money_bar.l > 0. && money_bar.c > 0. &&
               signal_bar.c > 0. then
              read_rows (line_number + 1)
                ((money_bar, signal_bar, adjusted_close, ratio) :: rows)
            else
              read_rows (line_number + 1) rows
        | exception End_of_file -> rows
      in
      let rows =
        List.sort
          (fun (left, _, _, _) (right, _, _, _) ->
            String.compare left.date right.date)
          (read_rows 2 [])
      in
      let rec derive previous money signal dividends units = function
        | [] ->
            let money = Array.of_list (List.rev money) in
            let signal = Array.of_list (List.rev signal) in
            let dividends = Array.of_list (List.rev dividends) in
            let units = Array.of_list (List.rev units) in
            let () =
              if Array.length units > 0 then back_adjust money units
            in
            let () =
              if Array.length units > 0 then back_adjust_volume money units
            in
            let () =
              if Array.length units > 0 then back_adjust_volume signal units
            in
            money, signal, restate_dividend_cash dividends units
        | (money_bar, signal_bar, adjusted_close, ratio) :: rest ->
            let dividends, units =
              match previous with
              | Some (previous_close, previous_adjusted, previous_ratio) ->
                  let previous_high =
                    (previous_adjusted +. 0.005) /. previous_close
                  in
                  let current_low =
                    (adjusted_close -. 0.005) /. money_bar.c
                  in
                  if current_low > previous_high then
                    let factor = previous_ratio /. ratio in
                    let cash_per_share = previous_close *. (1. -. factor) in
                    let split_close = previous_close *. factor in
                    if abs_float (money_bar.c -. split_close) <= 0.01 then
                      dividends, (money_bar.date, factor) :: units
                    else if cash_per_share > 0. then
                      ({ ex_date = money_bar.date; cash_per_share;
                         pay_date = money_bar.date } :: dividends),
                      units
                    else
                      dividends, units
                  else
                    dividends, units
              | None -> dividends, units
            in
            derive (Some (money_bar.c, adjusted_close, ratio))
              (money_bar :: money) (signal_bar :: signal) dividends units rest
      in
      derive None [] [] [] [] rows)

let read_bars ~market path =
  if market = "us" then
    let _, signal, _ = read_us_planes path in
    signal
  else
    let input = open_in path in
    Fun.protect
      ~finally:(fun () -> close_in input)
      (fun () ->
        let header =
          match input_line input with
          | line -> line
          | exception End_of_file -> ""
        in
        let () =
          if header <> "date,open,high,low,close,volume" then
            failf "%s: expected header date,open,high,low,close,volume" path
        in
        let rec loop line_number acc =
          match input_line input with
          | line when line = "" -> loop (line_number + 1) acc
          | line ->
              let bar =
                match String.split_on_char ',' line with
                | [date; o; h; l; c; v] ->
                    { date = unquote date;
                      o = float_field path line_number "open" o;
                      h = float_field path line_number "high" h;
                      l = float_field path line_number "low" l;
                      c = float_field path line_number "close" c;
                      v = float_field path line_number "volume" v }
                | _ -> failf "%s:%d: malformed CSV row" path line_number
              in
              if bar.o > 0. && bar.h > 0. && bar.l > 0. && bar.c > 0. then
                loop (line_number + 1) (bar :: acc)
              else
                loop (line_number + 1) acc
          | exception End_of_file -> Array.of_list (List.rev acc)
        in
        loop 2 [])

let read_dividends path =
  let input = open_in path in
  Fun.protect
    ~finally:(fun () -> close_in input)
    (fun () ->
      let header =
        match input_line input with
        | line -> line
        | exception End_of_file -> ""
      in
      let () =
        if header <> "date,factor" then
          failf "%s: expected header date,factor" path
      in
      let rec loop line_number acc =
        match input_line input with
        | line when line = "" -> loop (line_number + 1) acc
        | line ->
            let item =
              match String.split_on_char ',' line with
              | [date; factor] ->
                  (unquote date, float_field path line_number "factor" factor)
              | _ -> failf "%s:%d: malformed dividend CSV row" path line_number
            in
            loop (line_number + 1) (item :: acc)
        | exception End_of_file -> Array.of_list (List.rev acc)
      in
      loop 2 [])
let read_cash_dividends path =
  let input = open_in path in
  Fun.protect
    ~finally:(fun () -> close_in input)
    (fun () ->
      let header =
        match input_line input with
        | line -> line
        | exception End_of_file -> ""
      in
      let () =
        if header <> "ex_date,cash_per_share,pay_date" then
          failf "%s: expected header ex_date,cash_per_share,pay_date" path
      in
      let rec loop line_number acc =
        match input_line input with
        | line when line = "" -> loop (line_number + 1) acc
        | line ->
            let dividend =
              match String.split_on_char ',' line with
              | [ex_date; cash_per_share; pay_date] ->
                  let ex_date = unquote ex_date in
                  let () = ignore (parse_date "cash dividend ex" ex_date) in
                  let cash_per_share =
                    float_field path line_number "cash_per_share"
                      cash_per_share
                  in
                  let pay_date = unquote pay_date in
                  let pay_date =
                    if pay_date = "" then add_one_month ex_date
                    else
                      let () =
                        ignore (parse_date "cash dividend pay" pay_date)
                      in
                      pay_date
                  in
                  { ex_date; cash_per_share; pay_date }
              | _ ->
                  failf "%s:%d: malformed cash dividend CSV row" path
                    line_number
            in
            let acc =
              if dividend.cash_per_share <> 0. then dividend :: acc else acc
            in
            loop (line_number + 1) acc
        | exception End_of_file -> Array.of_list (List.rev acc)
      in
      loop 2 [])

let derive_cash_dividends bars factors =
  let bars = Array.copy bars in
  let factors = Array.copy factors in
  let () =
    Array.sort (fun left right -> String.compare left.date right.date) bars
  in
  let () =
    Array.sort
      (fun (left, _) (right, _) -> String.compare left right)
      factors
  in
  let rec advance bar_index previous_close ex_date =
    if bar_index < Array.length bars &&
       String.compare bars.(bar_index).date ex_date < 0 then
      advance (bar_index + 1) (Some bars.(bar_index).c) ex_date
    else
      bar_index, previous_close
  in
  let rec collect factor_index bar_index previous_close acc =
    if factor_index = Array.length factors then
      Array.of_list (List.rev acc)
    else
      let ex_date, factor = factors.(factor_index) in
      let bar_index, previous_close =
        advance bar_index previous_close ex_date
      in
      let acc =
        match previous_close with
        | Some close ->
            let cash_per_share = (1. -. factor) *. close in
            if cash_per_share > 0. then
              { ex_date; cash_per_share;
                pay_date = add_one_month ex_date } :: acc
            else
              acc
        | None -> acc
      in
      collect (factor_index + 1) bar_index previous_close acc
  in
  collect 0 0 None []
let money_dividend_factors bars factors dividends =
  let bars = Array.copy bars in
  let factors = Array.copy factors in
  let () =
    Array.sort (fun left right -> String.compare left.date right.date) bars
  in
  let () =
    Array.sort
      (fun (left, _) (right, _) -> String.compare left right)
      factors
  in
  let cash_by_date = Hashtbl.create (Array.length dividends) in
  let () =
    Array.iter
      (fun dividend ->
        let total =
          match Hashtbl.find_opt cash_by_date dividend.ex_date with
          | Some amount -> amount +. dividend.cash_per_share
          | None -> dividend.cash_per_share
        in
        Hashtbl.replace cash_by_date dividend.ex_date total)
      dividends
  in
  let rec multiply_same_date date index factor =
    if index < Array.length factors && fst factors.(index) = date then
      multiply_same_date date (index + 1) (factor *. snd factors.(index))
    else
      index, factor
  in
  let rec group index acc =
    if index = Array.length factors then List.rev acc
    else
      let date, factor = factors.(index) in
      let next, factor = multiply_same_date date (index + 1) factor in
      group next ((date, factor) :: acc)
  in
  let rec advance bar_index previous_close ex_date =
    if bar_index < Array.length bars &&
       String.compare bars.(bar_index).date ex_date < 0 then
      advance (bar_index + 1) (Some bars.(bar_index).c) ex_date
    else
      bar_index, previous_close
  in
  let rec decompose bar_index previous_close acc = function
    | [] -> Array.of_list (List.rev acc)
    | (ex_date, full_factor) :: rest ->
        let bar_index, previous_close =
          advance bar_index previous_close ex_date
        in
        let money_factor =
          match previous_close, Hashtbl.find_opt cash_by_date ex_date with
          | Some close, Some cash_per_share ->
              let cash_factor = (close -. cash_per_share) /. close in
              if cash_factor > 0. then full_factor /. cash_factor
              else full_factor
          | _ -> full_factor
        in
        decompose bar_index previous_close
          ((ex_date, money_factor) :: acc) rest
  in
  decompose 0 None [] (group 0 [])

let merge_cash_dividend_cache dividends ~cache_path =
  let cached_dates = Hashtbl.create (Array.length dividends) in
  let cached_rows =
    if not (Sys.file_exists cache_path) then []
    else
      match non_empty_lines cache_path with
      | "ex_date,cash_per_share,pay_date" :: rows ->
          let () =
            List.iter
              (fun row -> Hashtbl.replace cached_dates (row_date row) ())
              rows
          in
          rows
      | _ ->
          failf "%s: expected header ex_date,cash_per_share,pay_date"
            cache_path
  in
  let derived_rows =
    dividends
    |> Array.to_list
    |> List.filter_map (fun dividend ->
      if Hashtbl.mem cached_dates dividend.ex_date then None
      else
        Some
          (Printf.sprintf "%s,%.17g," dividend.ex_date
             dividend.cash_per_share))
  in
  let rows =
    List.sort
      (fun left right -> String.compare (row_date left) (row_date right))
      (cached_rows @ derived_rows)
  in
  with_temp ".rows" (fun rows_path ->
    let output = open_out rows_path in
    let () =
      Fun.protect
        ~finally:(fun () -> close_out output)
        (fun () ->
          List.iter (fun row -> output_string output (row ^ "\n")) rows)
    in
    rewrite_rows ~header:"ex_date,cash_per_share,pay_date"
      ~rows_path ~cache_path)

let fetch_cash_dividends ~token ~symbol ~to_ ~price_cache ~factor_cache
    ~cache_path =
  let keep reason =
    Printf.eprintf "warning: cash dividend fetch failed (%s); %s\n" reason
      (if Sys.file_exists cache_path then
         "keeping cached cash dividend data"
       else
         "cash dividend data is unavailable")
  in
  let derive reason =
    Printf.eprintf
      "warning: TaiwanStockDividend unavailable (%s); deriving cash dividends from cached price factors and treating every factor as cash-only\n"
      reason;
    try
      let bars = read_bars ~market:"tw" price_cache in
      let factors = read_dividends factor_cache in
      let dividends = derive_cash_dividends bars factors in
      merge_cash_dividend_cache dividends ~cache_path
    with Failure message | Sys_error message ->
      keep (reason ^ "; factor derivation failed: " ^ message)
  in
  with_temp ".json" (fun json_path ->
    let url =
      api_url ~dataset:"TaiwanStockDividend" ~symbol
        ~from_:"1900-01-01" ~to_
    in
    let process_status, http_code = curl_get ~token ~url ~output:json_path in
    let tier_failure =
      match http_code with
      | "400" | "402" | "403" -> Some ("HTTP " ^ http_code)
      | "200" when process_ok process_status ->
          (match jq_status json_path with
           | Some ("400" | "402" | "403" as status) ->
               Some ("API status " ^ status)
           | _ -> None)
      | _ -> None
    in
    match tier_failure with
    | Some reason -> derive reason
    | None when not (process_ok process_status) || http_code <> "200" ->
        keep
          ("HTTP " ^
           (if http_code = "" || http_code = "000" then "unavailable"
            else http_code))
    | None ->
        (match check_api_response json_path with
         | `Error message -> keep message
         | `Ok ->
             with_temp ".rows" (fun rows_path ->
               let () =
                 transform_json ~args:[]
                   ~expression:(
                     ".data[] " ^
                     "| select((.CashExDividendTradingDate // \"\") != \"\") " ^
                     "| [.CashExDividendTradingDate, " ^
                     "(((.CashEarningsDistribution // 0) | tonumber) + " ^
                     "((.CashStatutorySurplus // 0) | tonumber)), " ^
                     "(.CashDividendPaymentDate // \"\")] " ^
                     "| select(.[1] != 0) | @csv")
                   ~json_path ~rows_path
               in
               rewrite_rows ~header:"ex_date,cash_per_share,pay_date"
                 ~rows_path ~cache_path)))

let fetch ~market ~symbol ~from_ ~to_ ~data_dir =
  let market = market_name market in
  let () = check_symbol symbol in
  let () =
    match from_ with
    | None -> ignore (parse_date "to" to_)
    | Some date -> validate_range date to_
  in
  let token =
    match Sys.getenv_opt "FINMIND_TOKEN" with
    | Some token when String.trim token <> "" -> token
    | _ -> failwith "export FINMIND_TOKEN=\"your_token_here\""
  in
  let directory = Filename.concat data_dir market in
  let () = mkdir_p directory in
  let price_cache = Filename.concat directory (symbol ^ ".csv") in
  let factor_cache = Filename.concat directory (symbol ^ ".div.csv") in
  let cash_cache = Filename.concat directory (symbol ^ ".cashdiv.csv") in
  let () =
    fetch_prices ~token ~market ~symbol ~from_ ~to_ ~cache_path:price_cache
  in
  if market = "tw" then
    let () =
      fetch_dividends ~token ~symbol ~to_ ~cache_path:factor_cache
    in
    let () =
      fetch_cash_dividends ~token ~symbol ~to_ ~price_cache ~factor_cache
        ~cache_path:cash_cache
    in
    let () =
      fetch_events ~token ~symbol ~to_
        ~cache_path:(Filename.concat directory (symbol ^ ".events.csv"))
    in
    fetch_stockinfo ~token ~symbol
      ~cache_path:(Filename.concat directory "stockinfo.csv")


let financing_ratio ~data_dir ~symbol =
  let path =
    Filename.concat (Filename.concat data_dir "tw") "stockinfo.csv"
  in
  let fallback () =
    let () =
      Printf.eprintf
        "warning: financing ratio unknown for %s; assuming TWSE 60%%\n" symbol
    in
    0.6
  in
  if not (Sys.file_exists path) then fallback ()
  else
    let input = open_in path in
    Fun.protect
      ~finally:(fun () -> close_in input)
      (fun () ->
        let () =
          match input_line input with
          | _header -> ()
          | exception End_of_file -> ()
        in
        let rec read_best best =
          match input_line input with
          | line ->
              let best =
                match String.split_on_char ',' line with
                | [stock_id; kind; date] when unquote stock_id = symbol ->
                    let date = unquote date in
                    (match best with
                     | Some (previous, _)
                       when String.compare previous date >= 0 ->
                         best
                     | _ -> Some (date, unquote kind))
                | _ -> best
              in
              read_best best
          | exception End_of_file -> best
        in
        match read_best None with
        | Some (_, "twse") -> 0.6
        | Some (_, "tpex") ->
            0.6
        | _ -> fallback ())




let in_range ~from_ ~to_ date =
  (match from_ with None -> true | Some first -> String.compare date first >= 0) &&
  (match to_ with None -> true | Some last -> String.compare date last <= 0)

let filter_range ~from_ ~to_ bars =
  bars
  |> Array.to_list
  |> List.filter (fun bar -> in_range ~from_ ~to_ bar.date)
  |> Array.of_list

let filter_dates ~keep bars =
  bars
  |> Array.to_list
  |> List.rev
  |> List.filter (fun bar -> keep bar.date)
  |> List.rev
  |> Array.of_list

let load_asset ~market ~symbol ~from_ ~to_ ~data_dir =
  let market = market_name market in
  let () = check_symbol symbol in
  let () =
    match from_ with
    | None -> ()
    | Some date -> ignore (parse_date "from" date)
  in
  let () =
    match to_ with
    | None -> ()
    | Some date -> ignore (parse_date "to" date)
  in
  let () =
    match from_, to_ with
    | Some first, Some last when String.compare first last > 0 ->
        failf "from date %s is after to date %s" first last
    | _ -> ()
  in
  let directory = Filename.concat data_dir market in
  let cache_path = Filename.concat directory (symbol ^ ".csv") in
  let () =
    if not (Sys.file_exists cache_path) then
      failf "%s not found; run bt fetch --market %s --symbol %s"
        cache_path market symbol
  in
  let money, signal, dividends =
    if market = "us" then
      read_us_planes cache_path
    else
      let signal = read_bars ~market cache_path in
      let money = Array.copy signal in
      let read_factors path warning =
        if Sys.file_exists path then read_dividends path
        else
          let () = prerr_endline warning in
          [||]
      in
      let dividend_factors =
        read_factors
          (Filename.concat directory (symbol ^ ".div.csv"))
          "warning: prices unadjusted for dividends"
      in
      let events =
        read_factors
          (Filename.concat directory (symbol ^ ".events.csv"))
          "warning: prices unadjusted for splits/reductions"
      in
      let cash_path = Filename.concat directory (symbol ^ ".cashdiv.csv") in
      let cash_dividends =
        if Sys.file_exists cash_path then read_cash_dividends cash_path
        else
          let () =
            prerr_endline
              "warning: cash dividend data unavailable; run bt fetch"
          in
          [||]
      in
      let signal_factors = Array.append dividend_factors events in
      let stock_dividend_factors =
        money_dividend_factors money dividend_factors cash_dividends
      in
      let money_factors =
        Array.append stock_dividend_factors events
      in
      let () =
        if Array.length signal_factors > 0 then
          back_adjust signal signal_factors
      in
      let () =
        if Array.length money_factors > 0 then back_adjust money money_factors
      in
      let () =
        if Array.length money_factors > 0 then
          back_adjust_volume signal money_factors
      in
      let () =
        if Array.length money_factors > 0 then
          back_adjust_volume money money_factors
      in
      let cash_dividends =
        restate_dividend_cash cash_dividends money_factors
      in
      money, signal, cash_dividends
  in
  let () =
    Array.sort (fun left right -> String.compare left.date right.date) money
  in
  let () =
    Array.sort (fun left right -> String.compare left.date right.date) signal
  in
  let () =
    Array.sort
      (fun left right -> String.compare left.ex_date right.ex_date)
      dividends
  in
  let money = filter_range ~from_ ~to_ money in
  let signal = filter_range ~from_ ~to_ signal in
  let dividends =
    dividends
    |> Array.to_list
    |> List.filter (fun dividend ->
      in_range ~from_ ~to_ dividend.ex_date)
    |> Array.of_list
  in
  let () =
    if Array.length signal < 2 then
      failf "%s contains fewer than 2 bars in the requested range; run bt fetch --market %s --symbol %s"
        cache_path market symbol
  in
  { money; signal; dividends }
