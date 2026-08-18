# Multi-Strat Runs and Backfill Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `bt run` backtests one or more strat files side by side, each strat naming its own stock; the TW cache backfills backward; fetch defaults to 1994-10-01.

**Architecture:** The engine is untouched. The DSL gains a `stock "m/sym"` statement (string literal token). `bin/bt.ml` loops the existing single-asset pipeline over N strats, intersects all bar arrays on their common date set, and hands N result columns to a generalized report. TW backfill is a pure prepend operation on the cache file plus one head-gap fetch.

**Tech Stack:** OCaml stdlib + unix, dune, ocamllex/ocamlyacc. No new dependencies.

**Spec:** `docs/specs/multi-strat-and-backfill.md` (committed). Read it first.

## Global Constraints

- OCaml stdlib and `unix` only. No opam package dependencies.
- List recursion must be tail-recursive; series math uses `Array` index loops.
- Numeric series are `float array`; warmup NaN; NaN comparisons false.
- One space on each side of `=`; no alignment padding; no emojis.
- Engine (`lib/engine.ml`), metrics (`lib/metrics.ml`), and indicators (`lib/series.ml`) are untouched.
- The golden literal 1.7291207425596153 (sma_cross, fast=5, slow=20, fixture, `Open_next`) must keep passing.
- Clean cutover: `bt run` loses `--market`, `--symbol`, `--benchmark-market`. No compatibility shims.
- The user has edited example strat files; READ every file immediately before editing it. Never write from memory.
- Do NOT run `git commit`. Stage with `git add -A` (never `.swp` files) and report; the coordinator commits after user confirmation.
- Build: `eval $(opam env) && dune build --root .`; test: `eval $(opam env) && dune test --root . --force`. No formatters, no network (live checks happen in coordinator verification).

---

### Task 1: DSL `stock` statement and compile split

**Files:**
- Modify: `lib/lexer.mll` (STRING rule, `stock` keyword)
- Modify: `lib/parser.mly` (STRING/STOCK tokens, stmt production)
- Modify: `lib/ast.ml` (Stock constructor)
- Modify: `lib/dsl.ml` (stock extraction, parse-once API)
- Modify: `test/test_bt.ml` (parser tests)

**Interfaces:**
- Consumes: existing `Dsl.parse_file : string -> Ast.file`, `Dsl.compile`.
- Produces (Task 3 relies on these exact names):
  - `Ast.stmt` gains `| Stock of string`.
  - `Dsl.stock_of : filename:string -> Ast.file -> string * string` — returns `(market, symbol)`; errors (via `failwith`, message prefixed `<filename>: `) on zero `stock` statements ("add a stock statement, e.g. stock \"tw/00685L\""), on more than one ("multiple stocks per strat are not supported yet"), on a malformed string (expected shape `market/symbol` with market `tw` or `us`).
  - `Dsl.compile_ast : Ast.file -> params:(string * float) list -> Data.bar array -> Engine.strategy` — the existing compile body, taking a parsed file. `Stock _` statements are ignored by compilation.
  - `Dsl.compile : string -> params:(string * float) list -> Data.bar array -> Engine.strategy` stays as `parse_file` + `compile_ast` (tests keep working; a strat without `stock` still compiles — requiring `stock` is `bt run`'s job through `stock_of`).

- [ ] **Step 1: Lexer**

In `lib/lexer.mll`: add `| "stock" -> STOCK` to the keyword function, and a string rule to the token rule (before the catch-all):

```
  | '"' [^ '"' '\n']* '"' as s
      { STRING (String.sub s 1 (String.length s - 2)) }
```

An unterminated string falls through to the newline/EOF paths and surfaces as a parse error, which is acceptable.

- [ ] **Step 2: Parser and AST**

`lib/ast.ml`: append `| Stock of string` to `stmt`.
`lib/parser.mly`: declare `%token <string> STRING` and `%token STOCK`; add production `| STOCK STRING { Stock $2 }` to `stmt`. Zero conflicts expected.

- [ ] **Step 3: Dsl API split**

In `lib/dsl.ml`, rename the body of `compile` to `compile_ast` (parameter `statements` comes from the caller instead of `parse_file`), then:

```ocaml
let compile source ~params bars =
  compile_ast (parse_file source) ~params bars

let stock_of ~filename statements =
  let stocks =
    List.fold_left
      (fun acc -> function Stock s -> s :: acc | _ -> acc) [] statements
  in
  match stocks with
  | [] ->
      failwith (Printf.sprintf
        "%s: add a stock statement, e.g. stock \"tw/00685L\"" filename)
  | _ :: _ :: _ ->
      failwith (Printf.sprintf
        "%s: multiple stocks per strat are not supported yet" filename)
  | [spec] ->
      (match String.index_opt spec '/' with
       | Some i when i > 0 && i < String.length spec - 1 ->
           let market = String.sub spec 0 i in
           let symbol =
             String.sub spec (i + 1) (String.length spec - i - 1)
           in
           if market <> "tw" && market <> "us" then
             failwith (Printf.sprintf
               "%s: market must be tw or us in stock \"%s\"" filename spec)
           else (market, symbol)
       | _ ->
           failwith (Printf.sprintf
             "%s: stock expects \"market/symbol\", got \"%s\"" filename spec))
```

Where the statement fold in `compile_ast` matches statements, add a `| Stock _ -> accumulator-unchanged` arm so compilation ignores it.

- [ ] **Step 4: Tests**

Add to `test/test_bt.ml` (helpers `with_temp_strategy`, `assert_failure`, `dsl_bars` exist; read the file first for current shape):

```ocaml
let test_stock_statement () =
  with_temp_strategy
    "stock \"tw/00685L\"\ntarget 1.0\n"
    (fun path ->
      let parsed = Dsl.parse_file path in
      assert (Dsl.stock_of ~filename:path parsed = ("tw", "00685L"));
      (* stock is ignored by compilation *)
      let strategy = Dsl.compile path ~params:[] dsl_bars in
      assert (Array.length strategy.Engine.target = Array.length dsl_bars));
  let rejects source =
    with_temp_strategy source (fun path ->
      assert_failure (fun () ->
        ignore (Dsl.stock_of ~filename:path (Dsl.parse_file path))))
  in
  rejects "target 1.0\n";
  rejects "stock \"tw/1\"\nstock \"tw/2\"\ntarget 1.0\n";
  rejects "stock \"jp/7203\"\ntarget 1.0\n";
  rejects "stock \"tw00685L\"\ntarget 1.0\n"
```

Register `test_stock_statement` in the runner.

- [ ] **Step 5: Build, test, stage**

Run `eval $(opam env) && dune build --root . && dune test --root . --force`; both clean, golden untouched. `git add -A`; do not commit.

---

### Task 2: Backfill and fetch defaults

**Files:**
- Modify: `lib/data.ml` (prepend operation, TW head-gap fetch)
- Modify: `bin/bt.ml` (fetch default `--from`, positional `m/sym`)
- Modify: `test/test_bt.ml` (prepend unit test)

**Interfaces:**
- Consumes: `fetch_rows`, `append_rows`, `rewrite_rows`, `first_cached_date`, `last_cached_date`, `normalize_row`, `row_date` in `lib/data.ml` (read the file first; names are current as of this plan).
- Produces: `Data.prepend_rows : header:string -> rows_path:string -> cache_path:string -> before:string -> unit` — writes header, then rows from `rows_path` whose date is `< before`, then every data row of the existing cache, atomically (temp file + rename, like `rewrite_rows`).

- [ ] **Step 1: `prepend_rows` in `lib/data.ml`**

Place next to `rewrite_rows`, following its temp-file/rename pattern (read it first). Behavior: open the temp output; write `header`; stream `rows_path`, normalizing each row and writing only rows with a nonempty date strictly `< before` (string compare); then stream the existing cache at `cache_path`, skipping its header line, writing every data row; close; rename over `cache_path`. All loops tail-recursive per the existing pattern.

- [ ] **Step 2: TW head-gap fetch in `fetch_prices`**

In the `market = "tw"` branch (read the current function first), before the existing tail-append logic, add:

```ocaml
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
```

Where `tw_expression`/`tw_header` are the existing TW jq expression and header (factor them into `let` bindings if they are currently inline literals). Add a `previous_date` helper next to `next_date`, mirroring its logic (day minus one, month/year borrow; read `next_date` first). The `~before:first` filter makes double-fetch idempotent: re-running the same backfill inserts nothing new.

- [ ] **Step 3: fetch CLI defaults and positional form**

In `bin/bt.ml` fetch (read it first): change the `--from` default `"2010-01-01"` to `"1994-10-01"`. Replace the anonymous-argument rejection with: one positional argument of shape `market/symbol` sets `market` and `symbol` (split on the first `/`; malformed → `Arg.Bad` naming the expected shape); flags still work; a second positional is an error. If both a positional and the flags set the symbol, the last one parsed wins (document in `--help` text as "positional MARKET/SYMBOL is equivalent to --market and --symbol").

- [ ] **Step 4: Prepend unit test**

```ocaml
let test_prepend_rows () =
  let cache = Filename.temp_file "bt-test-cache" ".csv" in
  let rows = Filename.temp_file "bt-test-rows" ".csv" in
  let write path text =
    let out = open_out path in
    output_string out text;
    close_out out
  in
  write cache "date,open,high,low,close,volume\n2020-01-03,3.,3.,3.,3.,1\n2020-01-04,4.,4.,4.,4.,1\n";
  write rows "2020-01-01,1.,1.,1.,1.,1\n2020-01-02,2.,2.,2.,2.,1\n2020-01-03,9.,9.,9.,9.,9\n";
  Data.prepend_rows ~header:"date,open,high,low,close,volume"
    ~rows_path:rows ~cache_path:cache ~before:"2020-01-03";
  let bars = Data.read_bars ~market:"tw" cache in
  Sys.remove cache; Sys.remove rows;
  (* the 2020-01-03 row from the fetch is dropped: cache wins at the seam *)
  assert (Array.length bars = 4);
  assert (bars.(0).Data.date = "2020-01-01");
  assert (bars.(2).Data.date = "2020-01-03");
  assert (bars.(2).Data.c = 3.)
```

Register it. (`Data.read_bars` is exposed; the library has no mli.)

- [ ] **Step 5: Build, test, stage**

Build and test clean; `git add -A`; do not commit.

---

### Task 3: Multi-strat run, report, outputs, examples

**Files:**
- Modify: `bin/bt.ml` (run rewrite)
- Modify: `lib/data.ml` (date-set filter helper)
- Modify: `lib/report.ml` (N-column table, stem naming, per-strat fill logs)
- Create: `examples/00685L_bh.strat`
- Modify: `examples/sma_cross.strat`, `examples/bb_macd.strat` (add stock lines; READ them first, the user has edited them)
- Modify: `test/test_bt.ml` (two-strat integration, naming tests)
- Modify: `test/dune` (add the new example to deps if the test reads it)

**Interfaces:**
- Consumes: Task 1's `Dsl.stock_of`/`compile_ast`, Task 2 unchanged data API, existing `Engine.run`, `Metrics.of_result`.
- Produces:
  - `Data.filter_dates : keep:(string -> bool) -> bar array -> bar array`.
  - `Report.stem : names:string list -> out_name:string option -> string` (pure; joins basenames with `_vs_` or returns the override).
  - `Report.print_many : columns:(string * Engine.result) list -> benchmark:Engine.result option -> fill:Engine.fill -> unit`.
  - `Report.write_outputs : out_dir:string -> stem:string -> columns:(string * Engine.result) list -> benchmark:Engine.result option -> unit` (CSV named `<stem>.csv`, per-strat `<name>.trades.csv`).
  - `Report.write_png ~out_dir ~stem` (plot.py invocation now takes the stem-named csv and writes `<stem>.png`).

- [ ] **Step 1: Date-set intersection in `lib/data.ml`**

```ocaml
let filter_dates ~keep bars =
  let selected = ref [] in
  for index = Array.length bars - 1 downto 0 do
    if keep bars.(index).date then selected := bars.(index) :: !selected
  done;
  Array.of_list !selected
```

- [ ] **Step 2: Run pipeline in `bin/bt.ml`**

Read the current `run` function first. New flow (replace `overlap_bars`; delete `--market`/`--symbol`/`--benchmark-market` options and the old single-strat wiring):

1. Anonymous args accumulate as strat paths (at least one required). Duplicate basenames (extension stripped) → usage error. Basename `benchmark` with `--benchmark` given → usage error.
2. Parse each strat once (`Dsl.parse_file`), get `(market, symbol)` via `Dsl.stock_of`.
3. `--benchmark M/SYM` parses with the same split helper as fetch's positional.
4. Load bars per strat (and benchmark) with `Data.load` over the CLI range.
5. Compute the common date set: for each bar array build the sorted date list; keep dates present in ALL arrays (fold `List.filter` over a string-set built with `Hashtbl` or sorted-list intersection; tail-recursive). Fewer than 2 common dates → error `strats have fewer than 2 common trading dates`.
6. `Data.filter_dates` every array to the common set.
7. Per strat: `Dsl.compile_ast`, per-strat `Engine.default_costs` from its market/symbol, apply CLI cost overrides, `Engine.run ~fill`.
8. Benchmark: `{ target = Array.make n 1.0 }` on its filtered bars, its own default costs plus overrides.
9. `-p` validation moves across strats: collect declared params of every strat (expose the existing declared-params helper from `Dsl` as `Dsl.declared_params_ast : Ast.file -> (string * float) list` if not already public); error if an override matches none of the strats. Pass the full `params` list to every `compile_ast` (unknown names for THAT strat are filtered by the caller before the call — build the per-strat subset from its declared list).
10. `Report.print_many`, `Report.stem`, `Report.write_outputs`, then `Report.write_png ~stem` unless `--no-plot`.

- [ ] **Step 3: Report generalization in `lib/report.ml`**

Read the file first. Replace `print`/`write_csvs`/`write_equity_csv`/`write_trades_csv` with the interfaces above:

- Table: column width 12 stays; header row = `Metric`, one column per strat basename (truncate a name longer than 12 to its last 12 chars), `benchmark` last when present. Each metric row prints the per-strat formatted value; when a benchmark exists, append a marker to each strat cell: `format_value ^ " W"` or `" L"` (lower-wins only for MaxDD; `n/a` cells get no marker). Below the table, per strat: `<name>: <stock> — trades N (win rate X); ` then the shared `Date range: ...; fill: ...` line. The leverage footer prints if ANY strat's max target exceeds 1.
- CSV: header `date,<name1>,...,benchmark?`; rows zip the equity curves (all curves share the common date set by construction; assert equal lengths, fail loudly otherwise).
- Fill logs: one `<name>.trades.csv` per strat, existing format. Benchmark writes none.
- `write_png ~out_dir ~stem` runs `python3 out/plot.py <out_dir>/<stem>.csv <out_dir>/<stem>.png`. `plot_script` is unchanged (header-driven).
- `stem`: basenames (extension stripped) joined with `"_vs_"`; `--out-name` overrides.

- [ ] **Step 4: Examples**

READ `examples/sma_cross.strat` and `examples/bb_macd.strat` first (user-edited), then add `stock "tw/0050"` as the first line of each, preserving their current rules verbatim. Create `examples/00685L_bh.strat`:

```
stock "tw/00685L"
target 1.0
```

- [ ] **Step 5: Tests**

- `Report.stem`: `stem ~names:["a"; "b"] ~out_name:None = "a_vs_b"`; `stem ~names:["a"] ~out_name:(Some "x") = "x"`.
- Two-strat integration on the fixture (no network): build two temp strats that both name the fixture's data through direct `Dsl.compile` + `Engine.run` (the CLI layer is exercised in live verification). Strat A: the golden sma_cross body (fast=5, slow=20) — final equity must still equal 1.7291207425596153 under `Open_next`. Strat B: `target 1.0` — expected final equity computed in-test from the fixture itself: `last_close /. first_close` with zero costs under `Close_same` (an independent formula, not a frozen constant). Assert both.
- `Dsl.stock_of` reserved-name interplay is CLI-level; leave to live verification.

- [ ] **Step 6: Build, test, stage**

Build and test clean; `git add -A`; do not commit.

---

### Task 4: Documentation

**Files:**
- Modify: `README.md` (Commands, DSL statements, outputs; READ FIRST — user-authored sections must survive)
- Modify: `docs/cli.md` (run section rewrite, fetch defaults, positional form, out-name; READ FIRST)
- Modify: `CONTRIBUTING.md` (only if it references removed flags; READ FIRST)

**Interfaces:** consumes shipped behavior of Tasks 1-3.

- [ ] **Step 1: README**

- Commands block: new `bt run STRAT... [--benchmark M/SYM] [--out-name NAME] ...` grammar; remove `--market/--symbol/--benchmark-market` from the run line; note the `stock` statement; fetch line gains the positional form and the 1994-10-01 default.
- DSL statements section: add `stock "market/symbol"` with the exactly-one rule.
- Outputs: `<stem>.csv`/`<stem>.png` naming rule and `--out-name`; per-strat `<name>.trades.csv`.
- Update the Contents TOC only if a heading changed.

- [ ] **Step 2: docs/cli.md**

Rewrite the `bt run` section: positional strats, all flags with defaults, benchmark sugar and W/L markers, output naming, common-date intersection rule, duplicate-basename and reserved-benchmark errors. Update fetch: positional form, new default, backfill behavior (prepend; idempotent).

- [ ] **Step 3: Verification (coordinator runs live parts)**

```sh
eval $(opam env) && dune build --root . && dune test --root . --force
./_build/default/bin/bt.exe run examples/sma_cross.strat examples/00685L_bh.strat --benchmark tw/00685L --no-plot
./_build/default/bin/bt.exe run examples/sma_cross.strat --out-name smoke
export FINMIND_TOKEN=...   # coordinator only
./_build/default/bin/bt.exe fetch tw/0050 --from 2008-01-01   # backfill: cache start moves back
./_build/default/bin/bt.exe fetch tw/0050 --from 2008-01-01   # idempotent: no duplicates
```

Expected: table shows two strat columns plus benchmark with W/L markers; `out/sma_cross_vs_00685L_bh.csv` and `.png` exist (PNG has three labeled curves); `out/smoke.csv`/`.png` from the override; backfilled cache starts near 2008 with `sort | uniq -d` empty; run errors mention the strat file when `stock` is missing.

- [ ] **Step 4: Stage**

`git add -A`; do not commit.
