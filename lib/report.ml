let format_percent value =
  match classify_float value with
  | FP_nan | FP_infinite -> "n/a"
  | FP_normal | FP_subnormal | FP_zero ->
      Printf.sprintf "%.2f%%" (100. *. value)

let format_number value =
  match classify_float value with
  | FP_nan | FP_infinite -> "n/a"
  | FP_normal | FP_subnormal | FP_zero -> Printf.sprintf "%.3f" value

let stem ~names ~out_name =
  match out_name with
  | Some name -> name
  | None -> String.concat "_vs_" names

let display_name name =
  let width = 12 in
  let length = String.length name in
  if length <= width then name else String.sub name (length - width) width

let print_cell value = Printf.printf " | %12s" value

let date_range = function
  | [] -> None
  | first :: rest ->
      let last = List.fold_left (fun _ point -> point) first rest in
      Some (fst first, fst last)


let marker ~lower value baseline =
  if (if lower then value <= baseline else value >= baseline) then
    " W"
  else
    " L"

let print_many ~columns ~baseline ~fill ~stocks ~financing_rate =
  let column_metrics =
    List.map
      (fun (name, result) -> name, Metrics.of_result result)
      columns
  in
  let baseline_metrics =
    match baseline with
    | None -> None
    | Some result -> Some (Metrics.of_result result)
  in
  let names =
    List.map fst columns @
    match baseline with None -> [] | Some _ -> ["baseline"]
  in
  let () = Printf.printf "%-16s" "Metric" in
  let () =
    List.iter (fun name -> print_cell (display_name name)) names
  in
  let () = print_newline () in
  let () =
    print_endline (String.make (16 + (15 * List.length names)) '-')
  in
  let rows =
    [ ("Total return", false,
       (fun (metrics : Metrics.t) -> Some metrics.total_return),
       format_percent);
      ("CAGR", false,
       (fun (metrics : Metrics.t) -> Some metrics.cagr),
       format_percent);
      ("Sharpe", false,
       (fun (metrics : Metrics.t) -> Some metrics.sharpe),
       format_number);
      ("MaxDD", true,
       (fun (metrics : Metrics.t) -> Some metrics.max_dd),
       format_percent);
      ("Calmar", false,
       (fun (metrics : Metrics.t) -> metrics.calmar),
       format_number) ]
  in
  let () =
    List.iter
      (fun (label, lower, get, formatter) ->
        let format = function
          | None -> "n/a"
          | Some value -> formatter value
        in
        let baseline_value =
          match baseline_metrics with
          | None -> None
          | Some metrics -> get metrics
        in
        let strategy_cell metrics =
          let value = get metrics in
          let formatted = format value in
          match value, baseline_value with
          | Some value, Some baseline_value
            when formatted <> "n/a" &&
                 format (Some baseline_value) <> "n/a" ->
              formatted ^ marker ~lower value baseline_value
          | _ -> formatted
        in
        let () = Printf.printf "%-16s" label in
        let () =
          List.iter
            (fun (_, metrics) -> print_cell (strategy_cell metrics))
            column_metrics
        in
        let () =
          match baseline_metrics with
          | None -> ()
          | Some metrics -> print_cell (format (get metrics))
        in
        print_newline ())
      rows
  in
  let () =
    List.iter2
      (fun (name, result) (_, metrics) ->
        let stock =
          match List.assoc_opt name stocks with
          | Some stock -> stock
          | None -> invalid_arg ("Report.print_many: missing stock for " ^ name)
        in
        let win_rate =
          match metrics.Metrics.win_rate with
          | None -> "n/a"
          | Some rate -> format_percent rate
        in
        let () =
          Printf.printf "%s: %s — trades %d (win rate %s);\n"
            name stock (List.length result.Engine.trips) win_rate
        in
        let stats = result.Engine.margin_stats in
        match stats.Engine.min_maintenance with
        | None -> ()
        | Some ratio ->
            Printf.printf
              "%s: margin — financing %.2f%%/yr, min maintenance %s, margin calls %d, refinances %d, clamps %d\n"
              name financing_rate (format_percent ratio)
              (List.length stats.Engine.margin_call_dates)
              stats.Engine.refinances stats.Engine.clamps)
      columns column_metrics
  in
  let curve =
    match columns with
    | [] -> []
    | (_, result) :: _ -> result.Engine.equity_curve
  in
  let range =
    match date_range curve with
    | None -> "n/a"
    | Some (first, last) -> first ^ " to " ^ last
  in
  Printf.printf "Date range: %s; fill: %s\n" range
    (match fill with
     | Engine.Close_same -> "close"
     | Engine.Open_next -> "open")

let write_equity ~out_dir ~stem ~columns ~baseline =
  let () =
    if columns = [] then invalid_arg "Report.write_outputs: no columns"
  in
  let named_results =
    match baseline with
    | None -> columns
    | Some result -> columns @ ["baseline", result]
  in
  let curves =
    Array.of_list
      (List.map
         (fun (name, result) ->
           name, Array.of_list result.Engine.equity_curve)
         named_results)
  in
  let length = Array.length (snd curves.(0)) in
  let () =
    Array.iter
      (fun (_, curve) -> assert (Array.length curve = length))
      curves
  in
  let () =
    Array.iteri
      (fun row _ ->
        let date = fst (snd curves.(0)).(row) in
        Array.iteri
          (fun column (_, curve) ->
            if column > 0 then assert (fst curve.(row) = date))
          curves)
      (snd curves.(0))
  in
  let path = Filename.concat out_dir (stem ^ ".csv") in
  let output = open_out_bin path in
  Fun.protect
    ~finally:(fun () -> close_out output)
    (fun () ->
      let () = output_string output "date" in
      let () =
        Array.iter
          (fun (name, _) -> Printf.fprintf output ",%s" name)
          curves
      in
      let () = output_char output '\n' in
      Array.iteri
        (fun row _ ->
          let () =
            Printf.fprintf output "%s" (fst (snd curves.(0)).(row))
          in
          let () =
            Array.iter
              (fun (_, curve) ->
                Printf.fprintf output ",%.17g" (snd curve.(row)))
              curves
          in
          output_char output '\n')
        (snd curves.(0)))

let write_fills ~out_dir ~name (fills : Engine.fill_event list) =
  let path = Filename.concat out_dir (name ^ ".trades.csv") in
  let output = open_out_bin path in
  Fun.protect
    ~finally:(fun () -> close_out output)
    (fun () ->
      let () =
        output_string output "date,stock,price,from_exposure,to_exposure\n"
      in
      List.iter
        (fun (fill : Engine.fill_event) ->
          Printf.fprintf output "%s,%s,%.17g,%.17g,%.17g\n"
            fill.date fill.stock fill.price fill.from_e fill.to_e)
        fills)

let write_outputs ~out_dir ~stem ~columns ~baseline =
  let () = Data.mkdir_p out_dir in
  let () = write_equity ~out_dir ~stem ~columns ~baseline in
  List.iter
    (fun (name, result) ->
      write_fills ~out_dir ~name result.Engine.fills)
    columns

let rec wait_for pid =
  try snd (Unix.waitpid [] pid) with
  | Unix.Unix_error (Unix.EINTR, _, _) -> wait_for pid

let warn_plot stem =
  Printf.eprintf "warning: plot failed; skipping %s.png\n" stem

let write_png ~out_dir ~stem =
  let executable_dir = Filename.dirname Sys.executable_name in
  let direct_path = Filename.concat executable_dir "scripts/plot.py" in
  let build_path = executable_dir ^ "/../../../scripts/plot.py" in
  let script_path =
    if Sys.file_exists direct_path then Some direct_path
    else if Sys.file_exists build_path then Some build_path
    else None
  in
  match script_path with
  | None -> warn_plot stem
  | Some script_path ->
      try
        let () = Data.mkdir_p out_dir in
        let csv_path = Filename.concat out_dir (stem ^ ".csv") in
        let png_path = Filename.concat out_dir (stem ^ ".png") in
        let arguments = [|"python3"; script_path; csv_path; png_path|] in
        let pid =
          Unix.create_process "python3" arguments
            Unix.stdin Unix.stdout Unix.stderr
        in
        match wait_for pid with
        | Unix.WEXITED 0 -> ()
        | Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _ ->
            warn_plot stem
      with _ -> warn_plot stem
