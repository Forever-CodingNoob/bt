let format_percent value = Printf.sprintf "%.2f%%" (100. *. value)

let format_number value =
  match classify_float value with
  | FP_nan | FP_infinite -> "n/a"
  | FP_normal | FP_subnormal | FP_zero -> Printf.sprintf "%.3f" value

let format_optional = function
  | None -> "n/a"
  | Some value -> format_number value

let verdict ~lower strategy benchmark =
  if (if lower then strategy <= benchmark else strategy >= benchmark) then
    "WIN"
  else
    "LOSS"

let optional_verdict strategy benchmark =
  match strategy, benchmark with
  | Some strategy, Some benchmark -> verdict ~lower:false strategy benchmark
  | _ -> "n/a"

let print_row name strategy benchmark result =
  Printf.printf "%-16s | %12s | %12s | %7s\n"
    name strategy benchmark result

let date_range = function
  | [] -> None
  | first :: rest ->
      let last = List.fold_left (fun _ point -> point) first rest in
      Some (fst first, fst last)

let maximum_target target =
  let maximum = ref 0. in
  for i = 0 to Array.length target - 1 do
    if not (Float.is_nan target.(i)) && target.(i) > !maximum then
      maximum := target.(i)
  done;
  !maximum

let print ~(strategy : Engine.result) ~(benchmark : Engine.result) ~target ~fill =
  let strategy_metrics = Metrics.of_result strategy in
  let benchmark_metrics = Metrics.of_result benchmark in
  print_row "Metric" "Strategy" "Benchmark" "Verdict";
  print_endline (String.make 55 '-');
  print_row "Total return"
    (format_percent strategy_metrics.total_return)
    (format_percent benchmark_metrics.total_return)
    (verdict ~lower:false strategy_metrics.total_return benchmark_metrics.total_return);
  print_row "CAGR"
    (format_percent strategy_metrics.cagr)
    (format_percent benchmark_metrics.cagr)
    (verdict ~lower:false strategy_metrics.cagr benchmark_metrics.cagr);
  print_row "Sharpe"
    (format_number strategy_metrics.sharpe)
    (format_number benchmark_metrics.sharpe)
    (verdict ~lower:false strategy_metrics.sharpe benchmark_metrics.sharpe);
  print_row "MaxDD"
    (format_percent strategy_metrics.max_dd)
    (format_percent benchmark_metrics.max_dd)
    (verdict ~lower:true strategy_metrics.max_dd benchmark_metrics.max_dd);
  print_row "Calmar"
    (format_optional strategy_metrics.calmar)
    (format_optional benchmark_metrics.calmar)
    (optional_verdict strategy_metrics.calmar benchmark_metrics.calmar);
  Printf.printf "Trades: %d (win rate %s); Benchmark: -\n"
    (List.length strategy.trips)
    (match strategy_metrics.win_rate with
     | None -> "n/a"
     | Some rate -> format_percent rate);
  begin
    match date_range strategy.equity_curve with
    | None -> print_endline "Date range: n/a"
    | Some (first, last) ->
        Printf.printf "Date range: %s to %s; fill: %s\n" first last
          (match fill with
           | Engine.Close_same -> "close"
           | Engine.Open_next -> "open")
  end;
  if maximum_target target > 1. then
    print_endline "Exposure above 1.0 uses daily-reset leverage."

let write_file path contents =
  let output = open_out_bin path in
  Fun.protect
    ~finally:(fun () -> close_out output)
    (fun () -> output_string output contents)

let write_equity_csv ~out_dir
    ~(strategy : Engine.result) ~(benchmark : Engine.result) =
  let path = Filename.concat out_dir "equity.csv" in
  let output = open_out_bin path in
  Fun.protect
    ~finally:(fun () -> close_out output)
    (fun () ->
      output_string output "date,strategy,benchmark\n";
      let rec write strategy_curve benchmark_curve =
        match strategy_curve, benchmark_curve with
        | (strategy_date, strategy_equity) :: strategy_rest,
          (benchmark_date, benchmark_equity) :: benchmark_rest ->
            let order = String.compare strategy_date benchmark_date in
            if order = 0 then begin
              Printf.fprintf output "%s,%.17g,%.17g\n"
                strategy_date strategy_equity benchmark_equity;
              write strategy_rest benchmark_rest
            end
            else if order < 0 then
              write strategy_rest benchmark_curve
            else
              write strategy_curve benchmark_rest
        | [], _ | _, [] -> ()
      in
      write strategy.equity_curve benchmark.equity_curve)

let write_trades_csv ~out_dir (fills : Engine.fill_event list) =
  let path = Filename.concat out_dir "trades.csv" in
  let output = open_out_bin path in
  Fun.protect
    ~finally:(fun () -> close_out output)
    (fun () ->
      output_string output "date,price,from_exposure,to_exposure\n";
      List.iter
        (fun (fill : Engine.fill_event) ->
          Printf.fprintf output "%s,%.17g,%.17g,%.17g\n"
            fill.date fill.price fill.from_e fill.to_e)
        fills)

let write_csvs ~out_dir
    ~(strategy : Engine.result) ~(benchmark : Engine.result) =
  Data.mkdir_p out_dir;
  write_equity_csv ~out_dir ~strategy ~benchmark;
  write_trades_csv ~out_dir strategy.fills

let plot_script = {|import sys, csv
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from datetime import date

csv_path, png_path = sys.argv[1], sys.argv[2]
dates = []
with open(csv_path) as f:
    r = csv.reader(f)
    header = next(r)
    series = {name: [] for name in header[1:]}
    for row in r:
        dates.append(date.fromisoformat(row[0]))
        for name, v in zip(header[1:], row[1:]):
            series[name].append(float(v))
fig, ax = plt.subplots(figsize=(12, 6))
for name, ys in series.items():
    ax.plot(dates, ys, label=name, linewidth=1.5)
ax.set_title("Equity curve (start = 1.0)")
ax.set_ylabel("equity")
ax.legend(loc="upper left")
ax.grid(True, alpha=0.4)
fig.autofmt_xdate()
fig.savefig(png_path, dpi=100, bbox_inches="tight")
|}

let rec wait_for pid =
  try snd (Unix.waitpid [] pid) with
  | Unix.Unix_error (Unix.EINTR, _, _) -> wait_for pid

let warn_plot () =
  prerr_endline "warning: plot failed; skipping equity.png"

let write_png ~out_dir =
  try
    Data.mkdir_p out_dir;
    let script_path = Filename.concat out_dir "plot.py" in
    let csv_path = Filename.concat out_dir "equity.csv" in
    let png_path = Filename.concat out_dir "equity.png" in
    write_file script_path plot_script;
    let arguments = [|"python3"; script_path; csv_path; png_path|] in
    let pid =
      Unix.create_process "python3" arguments Unix.stdin Unix.stdout Unix.stderr
    in
    match wait_for pid with
    | Unix.WEXITED 0 -> ()
    | Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _ -> warn_plot ()
  with _ -> warn_plot ()
