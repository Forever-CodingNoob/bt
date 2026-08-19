# Exact Corporate-Action Adjustment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the 25% gap heuristic with exact TW corporate-action factors fetched from three free FinMind event tables.

**Architecture:** `bt fetch` gains an events fetch that mirrors the dividend fetch: per-symbol factors cached in `data/tw/<symbol>.events.csv` (same `date,factor` format as `.div.csv`), applied at load time by the existing `back_adjust`. `detect_splits` is deleted.

**Tech Stack:** OCaml (stdlib + Unix only), external processes `/usr/bin/curl` and `/usr/bin/jq`, dune, single test binary `test/test_bt.ml`.

**Spec:** `docs/specs/corporate-action-adjustment.md`

## Global Constraints

- Factor semantics: `factor = after / before`; `back_adjust` multiplies bars strictly before the event date. The event `date` is the first trading day at the new price basis.
- The three datasets and factor fields, verbatim:
  - `TaiwanStockSplitPrice`: `after_price / before_price`
  - `TaiwanStockCapitalReductionReferencePrice`: `PostReductionReferencePrice / ClosingPriceonTheLastTradingDay`
  - `TaiwanStockParValueChange`: `after_ref_close / before_close`
- Rows with a null or zero "before" price are skipped. The jq transform selects `stock_id == $sym` (passed with `--arg`, never string-spliced).
- Events cache: `data/tw/<symbol>.events.csv`, header `date,factor`, rewritten wholesale only when all three dataset requests succeed; on any failure print one warning naming the dataset and keep the cached file.
- Missing `.events.csv` at load prints exactly `warning: prices unadjusted for splits/reductions` and continues.
- US market, engine, DSL, report, and CLI flags are untouched. `FINMIND_TOKEN` stays required by `bt fetch`.
- `data/` is gitignored; never commit cache files.
- Code style: two-space indent, one space on each side of `=`, no alignment padding. All tests live in `test/test_bt.ml` and are registered in the final `let () =` runner.
- Verification command for every task: `dune build && dune runtest` from the repo root.

---

### Task 1: Events fetch machinery

**Files:**
- Modify: `lib/data.ml:359-362` (transform_json), `lib/data.ml:428-459` (insert after fetch_dividends), `lib/data.ml:461-478` (fetch wiring)
- Test: `test/test_bt.ml`

**Interfaces:**
- Consumes: existing `with_temp`, `read_text`, `api_url`, `curl_get`, `process_ok`, `check_api_response`, `rewrite_rows` in `lib/data.ml`.
- Produces: `Data.transform_json ?args ~expression ~json_path ~rows_path`, `Data.event_expression ~before ~after : string`, `Data.event_sources : (string * string * string) list` (dataset, before field, after field), `Data.fetch_events ~token ~symbol ~to_ ~cache_path`. Task 2 relies on the `.events.csv` file format only.

- [ ] **Step 1: Write the failing test**

Append to `test/test_bt.ml` before the `let () =` runner. The test drives every configured dataset's jq expression over a fixture response shaped like the FinMind API, and checks factor extraction plus null, zero, and foreign-stock filtering:

```ocaml
let read_file path =
  let input = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in input)
    (fun () -> really_input_string input (in_channel_length input))

let test_event_transform () =
  List.iter
    (fun (_dataset, before, after) ->
      let json =
        Printf.sprintf
          {|{"msg":"success","status":200,"data":[
             {"date":"2026-07-07","stock_id":"00685L","%s":306,"%s":12.75},
             {"date":"2026-07-08","stock_id":"9999","%s":100,"%s":50},
             {"date":"2026-07-09","stock_id":"00685L","%s":0,"%s":1},
             {"date":"2026-07-10","stock_id":"00685L","%s":null,"%s":1}]}|}
          before after before after before after before after
      in
      with_temp_strategy json (fun json_path ->
        with_temp_strategy "" (fun rows_path ->
          Data.transform_json ~args:["--arg"; "sym"; "00685L"]
            ~expression:(Data.event_expression ~before ~after)
            ~json_path ~rows_path;
          match
            String.split_on_char '\n' (String.trim (read_file rows_path))
          with
          | [row] ->
              (match String.split_on_char ',' row with
               | [date; factor] ->
                   assert (date = "\"2026-07-07\"");
                   assert_close (12.75 /. 306.) (float_of_string factor)
               | _ -> assert false)
          | _ -> assert false)))
    Data.event_sources;
  assert (List.length Data.event_sources = 3)
```

Register `test_event_transform ();` in the `let () =` runner before `print_endline "ok"`.

- [ ] **Step 2: Run the test to verify it fails**

Run: `dune build 2>&1 | head -20`
Expected: FAIL to compile with unbound `Data.event_expression` (and `~args` label error).

- [ ] **Step 3: Implement the fetch machinery**

In `lib/data.ml`, replace `transform_json` (lines 359-362) with:

```ocaml
let transform_json ?(args = []) ~expression ~json_path ~rows_path =
  match
    run_to_file "/usr/bin/jq" (("-r" :: args) @ [expression; json_path])
      rows_path
  with
  | Unix.WEXITED 0 -> ()
  | _ -> failwith "jq failed while converting the FinMind response"
```

Existing callers compile unchanged (the new argument is optional).

Insert after `fetch_dividends` (after line 459):

```ocaml
(* factor = after / before; back_adjust applies it to bars strictly
   before the event date, matching the ex-date convention *)
let event_expression ~before ~after =
  ".data[] | select(.stock_id == $sym) " ^
  "| select(." ^ before ^ " != null and ." ^ after ^ " != null) " ^
  "| select((." ^ before ^ " | tonumber) != 0) " ^
  "| [.date, ((." ^ after ^ " | tonumber) / (." ^ before ^
  " | tonumber))] | @csv"

let event_sources = [
  "TaiwanStockSplitPrice", "before_price", "after_price";
  "TaiwanStockCapitalReductionReferencePrice",
    "ClosingPriceonTheLastTradingDay", "PostReductionReferencePrice";
  "TaiwanStockParValueChange", "before_close", "after_ref_close";
]

let non_empty_lines path =
  List.filter
    (fun line -> String.trim line <> "")
    (String.split_on_char '\n' (read_text path))

let fetch_events ~token ~symbol ~to_ ~cache_path =
  (* a failed events fetch never destroys previously cached factors;
     stale factors beat none, same policy as fetch_dividends *)
  let keep reason =
    Printf.eprintf "warning: events fetch failed (%s); %s\n" reason
      (if Sys.file_exists cache_path then "keeping cached event data"
       else "prices will be unadjusted for splits/reductions")
  in
  let fetch_one (dataset, before, after) =
    with_temp ".json" (fun json_path ->
      let url = api_url ~dataset ~symbol ~from_:"1900-01-01" ~to_ in
      let process_status, http_code = curl_get ~token ~url ~output:json_path in
      if not (process_ok process_status) || http_code <> "200" then begin
        keep
          (dataset ^ ": HTTP " ^
           (if http_code = "" || http_code = "000" then "unavailable"
            else http_code));
        None
      end
      else
        match check_api_response json_path with
        | `Error message -> keep (dataset ^ ": " ^ message); None
        | `Ok ->
            with_temp ".rows" (fun rows_path ->
              transform_json ~args:["--arg"; "sym"; symbol]
                ~expression:(event_expression ~before ~after)
                ~json_path ~rows_path;
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
        Fun.protect
          ~finally:(fun () -> close_out output)
          (fun () ->
            List.iter (fun row -> output_string output (row ^ "\n")) rows);
        rewrite_rows ~header:"date,factor" ~rows_path ~cache_path)
```

In `fetch` (lines 476-478), extend the tw branch:

```ocaml
  if market = "tw" then begin
    fetch_dividends ~token ~symbol ~to_
      ~cache_path:(Filename.concat directory (symbol ^ ".div.csv"));
    fetch_events ~token ~symbol ~to_
      ~cache_path:(Filename.concat directory (symbol ^ ".events.csv"))
  end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `dune build && dune runtest`
Expected: build clean, tests print `ok`.

- [ ] **Step 5: Commit**

```bash
git add lib/data.ml test/test_bt.ml
git commit -m "feat: fetch corporate-action events from FinMind"
```

---

### Task 2: Load-time adjustment and heuristic deletion

**Files:**
- Modify: `lib/data.ml:580-594` (delete detect_splits and its comment), `lib/data.ml:615-643` (load)
- Modify: `test/test_bt.ml` (delete `test_detect_splits` at lines 602-614 and its runner line; add two tests)

**Interfaces:**
- Consumes: `.events.csv` format from Task 1; existing `read_dividends`, `back_adjust`.
- Produces: `Data.load` applies `.div.csv` and `.events.csv` factors; `Data.detect_splits` no longer exists.

- [ ] **Step 1: Write the failing tests**

Append to `test/test_bt.ml`. First, factor composition through `back_adjust` (a split, a sub-threshold capital reduction the old heuristic could not see, and a same-date dividend-plus-event pair):

```ocaml
let test_back_adjust_events () =
  let bars =
    [| bar "2026-06-30" 300. 306.;
       bar "2026-07-07" 13.09 12.23 |]
  in
  Data.back_adjust bars [| ("2026-07-07", 12.75 /. 306.) |];
  assert_close 12.75 bars.(0).c;
  assert_close 12.23 bars.(1).c;
  let reduction =
    [| bar "2020-01-01" 100. 100.;
       bar "2020-01-02" 90. 90. |]
  in
  Data.back_adjust reduction [| ("2020-01-02", 0.9) |];
  assert_close 90. reduction.(0).c;
  let combined =
    [| bar "2020-01-01" 100. 100.;
       bar "2020-01-02" 45. 45. |]
  in
  Data.back_adjust combined [| ("2020-01-02", 0.9); ("2020-01-02", 0.5) |];
  assert_close 45. combined.(0).c
```

Second, the integration path through `Data.load` with a 00685L-shaped fixture:

```ocaml
let test_load_events () =
  let root = Filename.temp_file "bt-test-data-" "" in
  Sys.remove root;
  Unix.mkdir root 0o700;
  let tw = Filename.concat root "tw" in
  Unix.mkdir tw 0o700;
  Fun.protect
    ~finally:(fun () ->
      Array.iter
        (fun name -> Sys.remove (Filename.concat tw name))
        (Sys.readdir tw);
      Unix.rmdir tw;
      Unix.rmdir root)
    (fun () ->
      let write path contents =
        let output = open_out path in
        Fun.protect
          ~finally:(fun () -> close_out output)
          (fun () -> output_string output contents)
      in
      write (Filename.concat tw "SPLIT.csv")
        "date,open,high,low,close,volume\n\
         2026-06-29,300,307,299,306,1000\n\
         2026-06-30,306,307,299,306,1000\n\
         2026-07-07,13.09,13.2,12.0,12.23,1000\n";
      write (Filename.concat tw "SPLIT.events.csv")
        "date,factor\n2026-07-07,0.041666666666666664\n";
      let bars =
        Data.load ~market:"tw" ~symbol:"SPLIT" ~from_:None ~to_:None
          ~data_dir:root
      in
      assert (Array.length bars = 3);
      assert_close 12.75 bars.(0).Data.c;
      assert_close 12.75 bars.(1).Data.c;
      assert_close 12.23 bars.(2).Data.c)
```

In the `let () =` runner: delete `test_detect_splits ();`, add `test_back_adjust_events ();` and `test_load_events ();`. Delete the `test_detect_splits` function (lines 602-614).

- [ ] **Step 2: Run the tests to verify the new one fails**

Run: `dune build && dune runtest 2>&1 | head -5`
Expected: `test_load_events` FAILS — `Data.load` does not read `.events.csv` yet, so `bars.(0).c` is still 306. (`test_back_adjust_events` passes already: `back_adjust` composition is existing behavior that these tests pin down.)

- [ ] **Step 3: Implement the load path and delete the heuristic**

In `lib/data.ml`, delete `detect_splits` and its comment block (lines 580-594). In `load`, replace the tw branch (lines 631-638) with:

```ocaml
  if market = "tw" then (
    let read_factors path warning =
      if Sys.file_exists path then read_dividends path
      else (prerr_endline warning; [||])
    in
    let dividends =
      read_factors
        (Filename.concat directory (symbol ^ ".div.csv"))
        "warning: prices unadjusted for dividends"
    in
    let events =
      read_factors
        (Filename.concat directory (symbol ^ ".events.csv"))
        "warning: prices unadjusted for splits/reductions"
    in
    let factors = Array.append dividends events in
    if Array.length factors > 0 then back_adjust bars factors);
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `dune build && dune runtest`
Expected: build clean (no unused-value warning survives because `detect_splits` and its test are both gone), tests print `ok`.

- [ ] **Step 5: Commit**

```bash
git add lib/data.ml test/test_bt.ml
git commit -m "feat: adjust TW prices with exact event factors"
```

---

### Task 3: Documentation and end-to-end smoke

**Files:**
- Modify: `README.md:159-162`, `docs/cli.md:89-93`, `CONTRIBUTING.md:7`
- Create (local cache, never committed): `data/tw/00685L.events.csv`

**Interfaces:**
- Consumes: the events fetch and load behavior from Tasks 1-2.
- Produces: user-facing docs that match the code; a locally usable 00685L cache.

- [ ] **Step 1: Update the docs**

`README.md` lines 160-162 — replace the heuristic bullet with:

```markdown
- The loader adjusts TW prices for splits, capital reductions, and par
  value changes with factors from `TaiwanStockSplitPrice`,
  `TaiwanStockCapitalReductionReferencePrice`, and
  `TaiwanStockParValueChange`, cached per symbol in
  `data/tw/<symbol>.events.csv`.
```

`docs/cli.md` line 93 (Price adjustments section) — replace the heuristic paragraph with:

```markdown
`bt fetch` also downloads split, capital-reduction, and par-value-change
reference prices for Taiwan symbols into `<symbol>.events.csv`. Each row
holds the event date and the exact price factor. `bt` applies these
factors together with the dividend factors during the same load step. If
the file is missing, `bt` prints a warning and loads unadjusted prices.
```

`CONTRIBUTING.md` line 7 — change the module table entry to:

```
lib/data.ml      FinMind fetch, CSV cache, dividend and corporate-action adjustment
```

Read each file section before editing; respect any user edits and edit surgically.

- [ ] **Step 2: Build the local events cache for 00685L**

`data/` is gitignored; this file makes the existing research workflows correct again after the heuristic removal. The factor is the verified exact split (12.75 / 306 = 1/24):

```bash
printf 'date,factor\n2026-07-07,0.041666666666666664\n' > data/tw/00685L.events.csv
```

- [ ] **Step 3: Smoke test on real data**

```bash
dune build && dune runtest
_build/default/bin/bt.exe run examples/00685L_bh.strat \
  --data-dir data --out-dir /tmp/ca-smoke --out-name ca_smoke --no-plot
```

Expected: tests print `ok`; the run prints one warning-free (no split/reduction warning) report whose date range starts 2017-03-30, and the buy-and-hold total return differs from the pre-change value because the exact factor replaced the heuristic one. Sanity bound: 306 * 0.041666666666666664 = 12.75, so pre-split closes scale to the 12-13 range.

- [ ] **Step 4: Commit**

```bash
git add README.md docs/cli.md CONTRIBUTING.md
git commit -m "docs: describe corporate-action events fetch"
```
