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

let symbol_directory ~data_dir ~market ~symbol =
  Filename.concat (Filename.concat data_dir market) symbol

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

let curl_get ~scheme ~token ~url ~output =
  with_temp ".hdr" (fun header_path ->
    let channel = open_out header_path in
    let () =
      Fun.protect
        ~finally:(fun () -> close_out channel)
        (fun () ->
          output_string channel
            ("Authorization: " ^ scheme ^ " " ^ token ^ "\n"))
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
    let process_status, http_code = curl_get ~scheme:"Bearer" ~token ~url ~output:json_path in
    let () = require_price_response json_path process_status http_code in
    with_temp ".rows" (fun rows_path ->
      let () = transform_json ~args:[] ~expression ~json_path ~rows_path in
      consume rows_path))

let fetch_tw_prices ~token ~symbol ~from_ ~to_ ~cache_path =
  let default_from = "1994-10-01" in
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
  if String.compare start_date to_ <= 0 then
    fetch_rows ~token ~dataset:"TaiwanStockPrice" ~symbol
      ~from_:start_date ~to_
      ~expression:tw_expression
      ~consume:(fun rows_path ->
        append_rows ~header:tw_header
          ~rows_path ~cache_path ~after:last_date)

let fetch_dividends ~token ~symbol ~to_ ~cache_path =
  with_temp ".json" (fun json_path ->
    let url =
      api_url ~dataset:"TaiwanStockDividendResult" ~symbol
        ~from_:"1900-01-01" ~to_
    in
    let process_status, http_code = curl_get ~scheme:"Bearer" ~token ~url ~output:json_path in
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
      let process_status, http_code = curl_get ~scheme:"Bearer" ~token ~url ~output:json_path in
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
    let process_status, http_code = curl_get ~scheme:"Bearer" ~token ~url ~output:json_path in
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


let read_bars ~market:_ path =
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
    let process_status, http_code = curl_get ~scheme:"Bearer" ~token ~url ~output:json_path in
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

let snap_split_factor value =
  let rec search p q best best_err =
    if p > 50 then
      if best_err < 1e-4 then best else value
    else if q > 50 then
      search (p + 1) 1 best best_err
    else
      let candidate = float_of_int p /. float_of_int q in
      let err = abs_float (candidate /. value -. 1.) in
      if err < best_err then search p (q + 1) candidate err
      else search p (q + 1) best best_err
  in
  search 1 1 value infinity

let tiingo_required_columns =
  ["date"; "close"; "high"; "low"; "open"; "volume"; "divCash"; "splitFactor"]

let find_tiingo_columns header_line =
  let columns = String.split_on_char ',' (String.trim header_line) in
  let rec index_of name i = function
    | [] -> failf "Tiingo: missing column %S in header" name
    | col :: rest ->
        if col = name then i else index_of name (i + 1) rest
  in
  List.map (fun name -> name, index_of name 0 columns) tiingo_required_columns

let write_tiingo_rows ~csv_path ~prev_close
    ~prices_path ~events_path ~cashdiv_path ~div_path =
  let csv = open_in csv_path in
  Fun.protect
    ~finally:(fun () -> close_in csv)
    (fun () ->
      let header_line =
        match input_line csv with
        | line -> line
        | exception End_of_file -> ""
      in
      let col_map = find_tiingo_columns header_line in
      let idx name = List.assoc name col_map in
      let i_date = idx "date" in
      let i_close = idx "close" in
      let i_high = idx "high" in
      let i_low = idx "low" in
      let i_open = idx "open" in
      let i_volume = idx "volume" in
      let i_div_cash = idx "divCash" in
      let i_split_factor = idx "splitFactor" in
      let field fields i = List.nth fields i in
      let p = open_out prices_path in
      let e = open_out events_path in
      let c = open_out cashdiv_path in
      let d = open_out div_path in
      Fun.protect
        ~finally:(fun () ->
          close_out d; close_out c; close_out e; close_out p)
        (fun () ->
          let rec loop prev =
            match input_line csv with
            | exception End_of_file -> ()
            | line ->
                let line = String.trim line in
                if line = "" then loop prev
                else
                  let fields = String.split_on_char ',' line in
                  let date =
                    let raw = unquote (field fields i_date) in
                    if String.length raw > 10 then String.sub raw 0 10
                    else raw
                  in
                  let open_v = field fields i_open in
                  let high_v = field fields i_high in
                  let low_v = field fields i_low in
                  let close_v = field fields i_close in
                  let volume_v = field fields i_volume in
                  let close_f = float_of_string close_v in
                  let div_cash_f = float_of_string (field fields i_div_cash) in
                  let split_factor_f =
                    float_of_string (field fields i_split_factor)
                  in
                  let () =
                    Printf.fprintf p "%s,%s,%s,%s,%s,%s\n"
                      date open_v high_v low_v close_v volume_v
                  in
                  let () =
                    if split_factor_f <> 1. then
                      Printf.fprintf e "%s,%.17g\n" date
                        (1. /. snap_split_factor split_factor_f)
                  in
                  let () =
                    if div_cash_f > 0. then
                      Printf.fprintf c "%s,%.17g,\n" date div_cash_f
                  in
                  let () =
                    match prev with
                    | Some pc when div_cash_f > 0. && pc > 0. ->
                        Printf.fprintf d "%s,%.17g\n"
                          date ((pc -. div_cash_f) /. pc)
                    | _ -> ()
                  in
                  loop (Some close_f)
          in
          loop prev_close))

let last_cached_close path =
  if not (Sys.file_exists path) then None
  else
    let input = open_in path in
    Fun.protect
      ~finally:(fun () -> close_in input)
      (fun () ->
        let () =
          match input_line input with
          | _ -> ()
          | exception End_of_file -> ()
        in
        let rec loop close =
          match input_line input with
          | "" -> loop close
          | line ->
              let close =
                match String.split_on_char ',' line with
                | [_; _; _; _; c; _] ->
                    (try Some (float_of_string c) with Failure _ -> close)
                | _ -> close
              in
              loop close
          | exception End_of_file -> close
        in
        loop None)

let fetch_us ~token ~symbol ~from_ ~to_ ~directory =
  let price_cache = Filename.concat directory (symbol ^ ".csv") in
  let events_cache = Filename.concat directory (symbol ^ ".events.csv") in
  let cashdiv_cache = Filename.concat directory (symbol ^ ".cashdiv.csv") in
  let div_cache = Filename.concat directory (symbol ^ ".div.csv") in
  let default_from = "1994-10-01" in
  let ph = "date,open,high,low,close,volume" in
  let eh = "date,factor" in
  let ch = "ex_date,cash_per_share,pay_date" in
  let dh = "date,factor" in
  let keep reason =
    Printf.eprintf "warning: Tiingo fetch failed (%s); %s\n" reason
      (if Sys.file_exists price_cache then "keeping cached data"
       else "US prices unavailable")
  in
  let do_range ~start ~stop ~prev_close ~on_prices ~on_events ~on_cashdiv
      ~on_div =
    with_temp ".tiingo" (fun csv_path ->
      let url =
        Printf.sprintf
          "https://api.tiingo.com/tiingo/daily/%s/prices?startDate=%s&endDate=%s&format=csv"
          (url_encode symbol) (url_encode start) (url_encode stop)
      in
      let status, http =
        curl_get ~scheme:"Token" ~token ~url ~output:csv_path
      in
      let () =
        if not (process_ok status) || http <> "200" then
          failf "HTTP %s"
            (if http = "" || http = "000" then "unavailable" else http)
      in
      with_temp ".p" (fun pp ->
        with_temp ".e" (fun ep ->
          with_temp ".c" (fun cp ->
            with_temp ".d" (fun dp ->
              let () =
                write_tiingo_rows ~csv_path ~prev_close
                  ~prices_path:pp ~events_path:ep
                  ~cashdiv_path:cp ~div_path:dp
              in
              let () = on_prices pp in
              let () = on_events ep in
              let () = on_cashdiv cp in
              on_div dp)))))
  in
  (* Head-gap backfill *)
  let () =
    match from_, first_cached_date price_cache with
    | Some start_date, Some first
      when should_probe_head ~from_ ~first_cached:first ->
        let day_before = previous_date first in
        (try
          do_range ~start:start_date ~stop:day_before ~prev_close:None
            ~on_prices:(fun pp ->
              prepend_rows ~header:ph ~rows_path:pp
                ~cache_path:price_cache ~before:first)
            ~on_events:(fun ep ->
              if Sys.file_exists events_cache then
                prepend_rows ~header:eh ~rows_path:ep
                  ~cache_path:events_cache ~before:first
              else
                rewrite_rows ~header:eh ~rows_path:ep
                  ~cache_path:events_cache)
            ~on_cashdiv:(fun cp ->
              if Sys.file_exists cashdiv_cache then
                prepend_rows ~header:ch ~rows_path:cp
                  ~cache_path:cashdiv_cache ~before:first
              else
                rewrite_rows ~header:ch ~rows_path:cp
                  ~cache_path:cashdiv_cache)
            ~on_div:(fun dp ->
              if Sys.file_exists div_cache then
                prepend_rows ~header:dh ~rows_path:dp
                  ~cache_path:div_cache ~before:first
              else
                rewrite_rows ~header:dh ~rows_path:dp
                  ~cache_path:div_cache)
        with Failure message -> keep message)
    | _ -> ()
  in
  (* Forward append *)
  let last = last_cached_date price_cache in
  let start_date =
    match last, from_ with
    | Some date, _ -> next_date date
    | None, Some date -> date
    | None, None -> default_from
  in
  if String.compare start_date to_ <= 0 then
    let prev_close = last_cached_close price_cache in
    (try
      do_range ~start:start_date ~stop:to_ ~prev_close
        ~on_prices:(fun pp ->
          append_rows ~header:ph ~rows_path:pp
            ~cache_path:price_cache ~after:last)
        ~on_events:(fun ep ->
          append_rows ~header:eh ~rows_path:ep
            ~cache_path:events_cache ~after:last)
        ~on_cashdiv:(fun cp ->
          append_rows ~header:ch ~rows_path:cp
            ~cache_path:cashdiv_cache ~after:last)
        ~on_div:(fun dp ->
          append_rows ~header:dh ~rows_path:dp
            ~cache_path:div_cache ~after:last)
    with Failure message -> keep message)

let require_token name =
  match Sys.getenv_opt name with
  | Some token when String.trim token <> "" -> token
  | _ -> failf "export %s=\"your_api_token\"" name

let fetch ~market ~symbol ~from_ ~to_ ~data_dir =
  let market = market_name market in
  let () = check_symbol symbol in
  let () =
    match from_ with
    | None -> ignore (parse_date "to" to_)
    | Some date -> validate_range date to_
  in
  let directory = symbol_directory ~data_dir ~market ~symbol in
  let () = mkdir_p directory in
  match market with
  | "us" ->
      let token = require_token "TIINGO_TOKEN" in
      fetch_us ~token ~symbol ~from_ ~to_ ~directory
  | "tw" ->
      let token = require_token "FINMIND_TOKEN" in
      let price_cache = Filename.concat directory (symbol ^ ".csv") in
      let factor_cache = Filename.concat directory (symbol ^ ".div.csv") in
      let cash_cache = Filename.concat directory (symbol ^ ".cashdiv.csv") in
      let () =
        fetch_tw_prices ~token ~symbol ~from_ ~to_
          ~cache_path:price_cache
      in
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
      let market_dir = Filename.concat data_dir market in
      fetch_stockinfo ~token ~symbol
        ~cache_path:(Filename.concat market_dir "stockinfo.csv")
  | _ -> failf "invalid market %S (expected tw or us)" market


let financing_ratio ~market ~data_dir ~symbol =
  let market = market_name market in
  match market with
  | "us" -> 0.5
  | "tw" ->
    let path =
      Filename.concat (Filename.concat data_dir "tw") "stockinfo.csv"
    in
    let fallback () =
      let () =
        Printf.eprintf
          "warning: financing ratio unknown for %s; assuming TWSE 60%%\n"
          symbol
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
                  | [stock_id; kind; date]
                    when unquote stock_id = symbol ->
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
          (match read_best None with
           | Some (_, "twse") -> 0.6
           | Some (_, "tpex") -> 0.6
           | _ -> fallback ()))
  | _ -> failf "invalid market %S (expected tw or us)" market




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
  let directory = symbol_directory ~data_dir ~market ~symbol in
  let cache_path = Filename.concat directory (symbol ^ ".csv") in
  let () =
    if not (Sys.file_exists cache_path) then
      failf "%s not found; run bt fetch %s/%s"
        cache_path market symbol
  in
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
    if Sys.file_exists cash_path then
      let raw = read_cash_dividends cash_path in
      (match market with
       | "us" -> Array.map (fun d -> { d with pay_date = d.ex_date }) raw
       | "tw" -> raw
       | _ -> failf "invalid market %S (expected tw or us)" market)
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
  let dividends =
    restate_dividend_cash cash_dividends money_factors
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
      failf "%s contains fewer than 2 bars in the requested range; run bt fetch %s/%s"
        cache_path market symbol
  in
  { money; signal; dividends }
