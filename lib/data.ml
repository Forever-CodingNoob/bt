type bar = {
  date : string;
  o : float;
  h : float;
  l : float;
  c : float;
  v : float;
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
  else
    for i = 0 to String.length symbol - 1 do
      if symbol.[i] = '/' || symbol.[i] = '\\' || symbol.[i] = '\000' then
        failf "invalid symbol %S" symbol
    done

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
    if String.length value <> 10 || value.[4] <> '-' || value.[7] <> '-' then
      raise Exit;
    let year = int_of_string (String.sub value 0 4) in
    let month = int_of_string (String.sub value 5 2) in
    let day = int_of_string (String.sub value 8 2) in
    if year < 1 || month < 1 || month > 12 || day < 1 ||
       day > days_in_month year month then
      raise Exit;
    (year, month, day)
  with Failure _ | Exit -> failf "invalid %s date %S (expected YYYY-MM-DD)" label value

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

let validate_range from_ to_ =
  ignore (parse_date "from" from_);
  ignore (parse_date "to" to_);
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
            if not first then Buffer.add_char buffer '\n';
            Buffer.add_string buffer line;
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
  String.iter
    (fun ch ->
      if is_unreserved ch then Buffer.add_char buffer ch
      else
        let code = Char.code ch in
        Buffer.add_char buffer '%';
        Buffer.add_char buffer hex.[code lsr 4];
        Buffer.add_char buffer hex.[code land 0x0f])
    value;
  Buffer.contents buffer

let api_url ~dataset ~symbol ~from_ ~to_ =
  Printf.sprintf
    "https://api.finmindtrade.com/api/v4/data?dataset=%s&data_id=%s&start_date=%s&end_date=%s"
    (url_encode dataset) (url_encode symbol) (url_encode from_) (url_encode to_)

(* ponytail: curl+jq pipeline; native HTTP+JSON client if fetch ever needs to be self-contained *)
let curl_get ~token ~url ~output =
  (* the header travels in a 0600 temp file so the token never shows in argv *)
  with_temp ".hdr" (fun header_path ->
    let channel = open_out header_path in
    Fun.protect
      ~finally:(fun () -> close_out channel)
      (fun () ->
        output_string channel ("Authorization: Bearer " ^ token ^ "\n"));
    with_temp ".status" (fun status_path ->
      let status =
        run_to_file "/usr/bin/curl"
          ["-sfS"; "-H"; "@" ^ header_path; "-o"; output;
           "-w"; "%{http_code}"; url]
          status_path
      in
      (status, String.trim (read_text status_path))))

let jq_message json_path =
  with_temp ".msg" (fun output ->
    let status =
      run_to_file "/usr/bin/jq"
        ["-r"; ".msg // \"unknown API error\""; json_path]
        output
    in
    if process_ok status then String.trim (read_text output)
    else "unknown API error")

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
      if needs_header then output_string output (header ^ "\n");
      let input = open_in rows_path in
      Fun.protect
        ~finally:(fun () -> close_in input)
        (fun () ->
          let rec loop () =
            match input_line input with
            | line ->
                let normalized = normalize_row line in
                let date = row_date normalized in
                if date <> "" &&
                   (match after with None -> true | Some previous -> String.compare date previous > 0)
                then output_string output (normalized ^ "\n");
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
      let output = open_out_bin temporary in
      Fun.protect
        ~finally:(fun () -> close_out output)
        (fun () ->
          output_string output (header ^ "\n");
          let rows = open_in rows_path in
          Fun.protect
            ~finally:(fun () -> close_in rows)
            (fun () ->
              let rec loop () =
                match input_line rows with
                | line ->
                    let normalized = normalize_row line in
                    let date = row_date normalized in
                    if date <> "" && String.compare date before < 0 then
                      output_string output (normalized ^ "\n");
                    loop ()
                | exception End_of_file -> ()
              in
              loop ());
          let cache = open_in cache_path in
          Fun.protect
            ~finally:(fun () -> close_in cache)
            (fun () ->
              (match input_line cache with
               | _header -> ()
               | exception End_of_file -> ());
              let rec loop () =
                match input_line cache with
                | line ->
                    output_string output (line ^ "\n");
                    loop ()
                | exception End_of_file -> ()
              in
              loop ()));
      Sys.rename temporary cache_path;
      completed := true)

let rewrite_rows ~header ~rows_path ~cache_path =
  let directory = Filename.dirname cache_path in
  let temporary = Filename.temp_file ~temp_dir:directory ".bt-div-" ".csv" in
  let completed = ref false in
  Fun.protect
    ~finally:(fun () -> if not !completed then remove_if_exists temporary)
    (fun () ->
      let output = open_out_bin temporary in
      Fun.protect
        ~finally:(fun () -> close_out output)
        (fun () ->
          output_string output (header ^ "\n");
          let input = open_in rows_path in
          Fun.protect
            ~finally:(fun () -> close_in input)
            (fun () ->
              let rec loop () =
                match input_line input with
                | line ->
                    if line <> "" then output_string output (normalize_row line ^ "\n");
                    loop ()
                | exception End_of_file -> ()
              in
              loop ()));
      Sys.rename temporary cache_path;
      completed := true)

let transform_json ~expression ~json_path ~rows_path =
  match run_to_file "/usr/bin/jq" ["-r"; expression; json_path] rows_path with
  | Unix.WEXITED 0 -> ()
  | _ -> failwith "jq failed while converting the FinMind response"

let fetch_rows ~token ~dataset ~symbol ~from_ ~to_ ~expression ~consume =
  with_temp ".json" (fun json_path ->
    let url = api_url ~dataset ~symbol ~from_ ~to_ in
    let process_status, http_code = curl_get ~token ~url ~output:json_path in
    require_price_response json_path process_status http_code;
    with_temp ".rows" (fun rows_path ->
      transform_json ~expression ~json_path ~rows_path;
      consume rows_path))

let fetch_prices ~token ~market ~symbol ~from_ ~to_ ~cache_path =
  if market = "tw" then begin
    (* raw TW prices never change retroactively; cached rows win at both seams *)
    let tw_expression =
      ".data[] | [.date, .open, .max, .min, .close, .Trading_Volume] | @csv"
    in
    let tw_header = "date,open,high,low,close,volume" in
    (* ponytail: after backfill bottoms out, every fetch re-probes the empty head gap (one API call + cache rewrite); record a probed floor date if rate limits ever matter *)
    (match first_cached_date cache_path with
     | Some first when String.compare from_ first < 0 ->
         let day_before = previous_date first in
         fetch_rows ~token ~dataset:"TaiwanStockPrice" ~symbol
           ~from_ ~to_:day_before
           ~expression:tw_expression
           ~consume:(fun rows_path ->
             prepend_rows ~header:tw_header ~rows_path ~cache_path
               ~before:first)
     | _ -> ());
    let last_date = last_cached_date cache_path in
    let start_date =
      match last_date with None -> from_ | Some date -> next_date date
    in
    if String.compare start_date to_ <= 0 then
      fetch_rows ~token ~dataset:"TaiwanStockPrice" ~symbol
        ~from_:start_date ~to_
        ~expression:tw_expression
        ~consume:(fun rows_path ->
          append_rows ~header:tw_header
            ~rows_path ~cache_path ~after:last_date)
  end
  else begin
    (* US Adj_Close is rewritten retroactively by upstream dividends and
       splits; appending fresh rows to old ones would mix adjustment
       baselines, so the US cache is refetched in full and rewritten *)
    let start_date =
      match first_cached_date cache_path with
      | Some date when String.compare date from_ < 0 -> date
      | _ -> from_
    in
    fetch_rows ~token ~dataset:"USStockPrice" ~symbol
      ~from_:start_date ~to_
      ~expression:".data[] | [.date, .Open, .High, .Low, .Close, .Adj_Close, .Volume] | @csv"
      ~consume:(fun rows_path ->
        rewrite_rows ~header:"date,open,high,low,close,adj_close,volume"
          ~rows_path ~cache_path)
  end

let fetch_dividends ~token ~symbol ~to_ ~cache_path =
  with_temp ".json" (fun json_path ->
    let url =
      api_url ~dataset:"TaiwanStockDividendResult" ~symbol
        ~from_:"1900-01-01" ~to_
    in
    let process_status, http_code = curl_get ~token ~url ~output:json_path in
    (* a failed dividend fetch never destroys previously cached factors;
       stale factors beat none, and transient 402/429/5xx would otherwise
       silently flip later runs to unadjusted prices *)
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
            transform_json
              ~expression:(
                ".data[] | select(.before_price != null and .after_price != null) " ^
                "| select((.before_price | tonumber) != 0) " ^
                "| [.date, ((.after_price | tonumber) / (.before_price | tonumber))] | @csv")
              ~json_path ~rows_path;
            rewrite_rows ~header:"date,factor" ~rows_path ~cache_path))

let fetch ~market ~symbol ~from_ ~to_ ~data_dir =
  let market = market_name market in
  check_symbol symbol;
  validate_range from_ to_;
  let token =
    match Sys.getenv_opt "FINMIND_TOKEN" with
    | Some token when String.trim token <> "" -> token
    | _ -> failwith "export FINMIND_TOKEN=\"your_token_here\""
  in
  let directory = Filename.concat data_dir market in
  mkdir_p directory;
  let cache_path = Filename.concat directory (symbol ^ ".csv") in
  fetch_prices ~token ~market ~symbol ~from_ ~to_ ~cache_path;
  if market = "tw" then
    fetch_dividends ~token ~symbol ~to_
      ~cache_path:(Filename.concat directory (symbol ^ ".div.csv"))

let float_field path line_number name value =
  try float_of_string value with Failure _ ->
    failf "%s:%d: invalid %s value %S" path line_number name value

let read_bars ~market path =
  let expected_header =
    if market = "tw" then "date,open,high,low,close,volume"
    else "date,open,high,low,close,adj_close,volume"
  in
  let input = open_in path in
  Fun.protect
    ~finally:(fun () -> close_in input)
    (fun () ->
      let header =
        match input_line input with
        | line -> line
        | exception End_of_file -> ""
      in
      if header <> expected_header then
        failf "%s: expected header %s" path expected_header;
      let rec loop line_number acc =
        match input_line input with
        | line when line = "" -> loop (line_number + 1) acc
        | line ->
            let fields = String.split_on_char ',' line in
            let bar =
              match market, fields with
              | "tw", [date; o; h; l; c; v] ->
                  { date = unquote date;
                    o = float_field path line_number "open" o;
                    h = float_field path line_number "high" h;
                    l = float_field path line_number "low" l;
                    c = float_field path line_number "close" c;
                    v = float_field path line_number "volume" v }
              | "us", [date; o; h; l; c; adj_close; v] ->
                  let raw_close = float_field path line_number "close" c in
                  let scale = float_field path line_number "adj_close" adj_close /. raw_close in
                  { date = unquote date;
                    o = float_field path line_number "open" o *. scale;
                    h = float_field path line_number "high" h *. scale;
                    l = float_field path line_number "low" l *. scale;
                    c = raw_close *. scale;
                    v = float_field path line_number "volume" v }
              | _ -> failf "%s:%d: malformed CSV row" path line_number
            in
            (* FinMind emits all-zero rows on non-trading days; skip them *)
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
      if header <> "date,factor" then failf "%s: expected header date,factor" path;
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

let back_adjust bars dividends =
  Array.sort (fun left right -> String.compare left.date right.date) bars;
  Array.sort (fun (left, _) (right, _) -> String.compare left right) dividends;
  let dividend_index = ref (Array.length dividends - 1) in
  let factor = ref 1. in
  for bar_index = Array.length bars - 1 downto 0 do
    while !dividend_index >= 0 &&
          String.compare (fst dividends.(!dividend_index)) bars.(bar_index).date > 0 do
      factor := !factor *. snd dividends.(!dividend_index);
      decr dividend_index
    done;
    let current = bars.(bar_index) in
    bars.(bar_index) <-
      { current with
        o = current.o *. !factor;
        h = current.h *. !factor;
        l = current.l *. !factor;
        c = current.c *. !factor }
  done

(* TW price bands cap daily moves at +/-10% (leveraged ETFs +/-20%), so a
   close-to-close jump beyond 25% is a split or capital reduction that raw
   TaiwanStockPrice does not adjust for and TaiwanStockDividendResult does
   not report. The factor uses the post-event open against the prior close
   so the event day's real open-to-close move is preserved.
   ponytail: 25% gap heuristic; switch to TaiwanStockPriceAdj if the token
   tier ever allows it *)
let detect_splits bars =
  let events = ref [] in
  for index = 1 to Array.length bars - 1 do
    let previous_close = bars.(index - 1).c in
    if abs_float (bars.(index).c /. previous_close -. 1.) > 0.25 then
      events := (bars.(index).date, bars.(index).o /. previous_close) :: !events
  done;
  Array.of_list (List.rev !events)

let in_range ~from_ ~to_ date =
  (match from_ with None -> true | Some first -> String.compare date first >= 0) &&
  (match to_ with None -> true | Some last -> String.compare date last <= 0)

let filter_range ~from_ ~to_ bars =
  let selected = ref [] in
  for index = Array.length bars - 1 downto 0 do
    if in_range ~from_ ~to_ bars.(index).date then
      selected := bars.(index) :: !selected
  done;
  Array.of_list !selected

let filter_dates ~keep bars =
  let selected = ref [] in
  for index = Array.length bars - 1 downto 0 do
    if keep bars.(index).date then selected := bars.(index) :: !selected
  done;
  Array.of_list !selected

let load ~market ~symbol ~from_ ~to_ ~data_dir =
  let market = market_name market in
  check_symbol symbol;
  (match from_ with None -> () | Some date -> ignore (parse_date "from" date));
  (match to_ with None -> () | Some date -> ignore (parse_date "to" date));
  (match from_, to_ with
   | Some first, Some last when String.compare first last > 0 ->
       failf "from date %s is after to date %s" first last
   | _ -> ());
  let directory = Filename.concat data_dir market in
  let cache_path = Filename.concat directory (symbol ^ ".csv") in
  if not (Sys.file_exists cache_path) then
    failf "%s not found; run bt fetch --market %s --symbol %s"
      cache_path market symbol;
  let bars = read_bars ~market cache_path in
  Array.sort (fun left right -> String.compare left.date right.date) bars;
  if market = "tw" then (
    let dividend_path = Filename.concat directory (symbol ^ ".div.csv") in
    let dividends =
      if Sys.file_exists dividend_path then read_dividends dividend_path
      else (prerr_endline "warning: prices unadjusted for dividends"; [||])
    in
    let factors = Array.append dividends (detect_splits bars) in
    if Array.length factors > 0 then back_adjust bars factors);
  let selected = filter_range ~from_ ~to_ bars in
  if Array.length selected < 2 then
    failf "%s contains fewer than 2 bars in the requested range; run bt fetch --market %s --symbol %s"
      cache_path market symbol;
  selected
