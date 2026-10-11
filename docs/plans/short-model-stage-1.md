# Short Model Stage 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> Implementers use executing-plans only. No subagents: never dispatch a reviewer or any other agent; the coordinator owns reviews.

**Goal:** Give the bt engine a short position model parameterized by the market profile, add the `short` and `overnight` DSL statements with their `bt run` flags and errors, and document both, without changing any existing output.

**Architecture:** The engine keeps a separate nonnegative short leg per asset (`short_values`, `short_reserved`, `short_borrow`) beside the long inventories; the sign lives in the target. `plan_fills` routes a negative effective target to the short leg (cover before the long sells, open after the long buys) and reserves `(1 + short_initial_ratio) x proceeds` of cash, so `available` for long buys excludes short proceeds. `walk_bars` gains an `Overnight` fill mode that exits every position at the open (without touching `prev_eff`) and enters at the close. The DSL floors targets at 0 unless the file declares `short`; TW files reject both statements at parse validation.

**Tech Stack:** OCaml 5 (stdlib and `unix` only), dune, ocamllex, ocamlyacc. No new dependencies.

## Global Constraints

- Base: branch `short-model` at commit `46d7810` in worktree `/sandbox/stock-short`. Never touch `/sandbox/stock` (daemons run there); `/sandbox/stock/data` and `/sandbox/stock/_opam` are read-only inputs.
- Spec: `/sandbox/stock-short/docs/specs/short-overnight.md`. Stage 1 covers Market profile, DSL, Engine inventory, Planning, Carried shorts, Overnight cadence, the non-daemon Errors rows, Tests 1-8, and the Docs row. The Live sections, Tests 9-14, and Acceptance are stage 2.
- Toolchain: run `eval $(opam env --switch=/sandbox/stock --set-switch)` once per shell in the worktree; `dune` then resolves to `/sandbox/stock/_opam/bin/dune`.
- Build and tests: `dune build 2>&1` and `dune test 2>&1` in the worktree; both must stay clean with zero warnings (warnings are errors: an unused top-level value fails the build).
- Byte gates: six pinned gates, baselines in `/sandbox/stock/.superpowers/sdd/us-paper-test/{us,tw}-baseline/` (`fp.csv`, `main.trades.csv`, `stdout.txt`) generated at `--to 2026-10-02`; the existing test suite holds the gate tests; they must stay byte-identical. The coordinator reruns the gates; the commands are `bt run /sandbox/research/strategies/tw/channel_ladder/main.strat --baseline tw/00685L --to 2026-10-02 --capital 1000000 --data-dir /sandbox/stock/data --out-dir OUT --out-name fp --no-plot` and `bt run /sandbox/research/strategies/us/dd_ladder/main.strat --baseline us/TQQQ --to 2026-10-02 --capital 100000 --data-dir /sandbox/stock/data --out-dir OUT --out-name fp --no-plot`, each compared with `cmp` against the three baseline files (stdout captured to a file).
- Network is forbidden for implementers; cached data only.
- Style (CONTRIBUTING.md): stdlib and `unix` only; no `for` or `while` loops; sequence side effects with `let () = e in`; branch on the market with `match` arms plus an error or default `_` arm; string and open matches always carry a default arm; preserve floating-point operation order; one space on each side of `=`; ASCII only; no mid-sentence newlines in docs; typed signatures where possible; succinct code, no speculative abstractions.
- Tests (CONTRIBUTING.md): plain asserts in `test/test_bt.ml`, exact values with a derivation comment above each expected value, one check per non-trivial branch. `test_engine_buyhold_costs` is the sentinel; byte-identity gates are never weakened to tolerances.
- Documentation style (CONTRIBUTING.md): one H1, disciplined H2-H4, full-depth table of contents in every document, tables for enumerable content with a `Default` column in `docs/cli.md`, alerts only with their fixed meanings. Every notable behavior or structural change adds an entry under `[Unreleased]` in `CHANGELOG.md` (Keep a Changelog 1.1.0).
- Commits: one per task, only after the coordinator confirms. Commit trailer for implementers (Claude models): `Co-Authored-By: Claude <noreply@anthropic.com>`. Never push; never change git settings.
- Every task's requirements implicitly include this section.

---

## Contents

- [Global Constraints](#global-constraints)
- [Spec readings](#spec-readings)
- [File map](#file-map)
- [Tasks](#tasks)
  - [Task 1: Profile fields and short types](#task-1-profile-fields-and-short-types)
  - [Task 2: DSL short and overnight statements](#task-2-dsl-short-and-overnight-statements)
  - [Task 3: Short inventory and planning](#task-3-short-inventory-and-planning)
  - [Task 4: Carried shorts](#task-4-carried-shorts)
  - [Task 5: Overnight cadence](#task-5-overnight-cadence)
  - [Task 6: CLI flags and errors](#task-6-cli-flags-and-errors)
  - [Task 7: Docs and changelog](#task-7-docs-and-changelog)
- [Self-review](#self-review)
  - [Spec coverage](#spec-coverage)
  - [Placeholder scan](#placeholder-scan)
  - [Type consistency](#type-consistency)
  - [Offline verification](#offline-verification)

## Spec readings

These are the points where the spec left room or where two of its sentences pull apart; each task below follows the reading stated here.

| Point | Reading |
| --- | --- |
| Where the two `bt run` overrides live | The Decisions table says short terms live in `Engine.market_profile` as data with flag overrides; the Market profile section says `Engine.margin` carries them as options. The plan puts both overrides in the profile: `--borrow-rate` sets `default_borrow_rate`, and `--short-maintenance-ratio` replaces `short_maintenance` with `Tiers [ { price_below = infinity; per_share = 0.; rate } ]`, which is exactly the flat rule `rate x short_value`. `Engine.margin` is unchanged, so its 62 record literals (59 in tests, 3 in `bin/bt.ml`) stay as they are and the engine keeps one maintenance code path. |
| Short position arrays | Spec lines 83, 87, and 103 describe one short position per asset as three arrays (`short_values`, `short_reserved`, `short_borrow`), with `proceeds = reserved / (1 + short_initial_ratio)` and the share count `short_value x capital / price` derived, never stored. The plan follows that. |
| No upper cap in the DSL | Spec line 73: `Dsl.compile_ast` floors a target at `-short_cap` in a `short` file and at 0 otherwise; the DSL has no upper cap today and gains none, the engine keeps its upper handling (`effective_targets` joint scaling). So `floor_target` is a lower bound only, and raw targets `[3.; -0.5]` scale jointly to `[12/7; -2/7]` rather than being capped at 2 first. |
| Third cadence | `Engine.fill` gains an `Overnight` constructor rather than a new `run` argument; `Close_same` and `Open_next` are untouched. `Report` prints `fill: overnight`; `Intraday.run` rejects it with `invalid_arg` at its input boundary, before the decision dispatcher that would otherwise drop it silently. |
| Who allows negatives in the engine | `Engine.run` derives `short_ratio` from the profile (`Tiers _` allows, `Unsupported` clamps to 0 as today) and the DSL floors targets at 0 for files without `short`. `Engine.effective_targets` keeps its clamp unless `?short_ratio` is passed, which pins the existing `effective (-1.) = 0` test. |
| Maintenance checks under `overnight` | Spec line 114: the daily check keeps its place at the close after the entry, so `min_maintenance` tracks the held position; a call recorded at the close is dropped at the next open before the exit, since the forced exit covers everything at the price a cure would use. The plan follows that. |
| Mixed runs | `bt run a.strat b.strat` where only one file declares `overnight`: each file runs under its own fill, the baseline runs under the CLI fill, and the report line prints `fill: overnight` when any file declares it. |
| `bt daytrade`, `bt target`, and `bt live` in stage 1 | `bt daytrade` runs `short_of` and `overnight_of` so a `bars` file fails with the daily-only messages instead of silently ignoring the statement. `bt target` and `bt live` reject TW `short` and `overnight` files with the parse messages, as the spec requires. They also reject US `short` and `overnight` files with `short and overnight are not supported by bt target and bt live yet`, because a stage 1 daemon would otherwise hold an `overnight` long across sessions. Stage 2 removes that guard. |
| Reserved cash in the plan | The plan treats `reserved` as a funding constraint: a short open may not need more collateral (`short_initial_ratio x open`) than `available` after covers; a cut open counts as a funding clamp and an open cut to zero pays no charge. `projected_cash` includes the short cash flows. |
| Long-only path | Every short array, pass, and arithmetic term in `plan_fills` sits behind one `short_active` boolean (any negative target or any held short); the inactive path runs the original code and shares one zero array. In `run`, the short terms enter `total_value` and `total_liabilities` as `x -. 0.` and `x +. 0.`, which are exact; Task 3 lists every changed long expression with its justification. The six byte gates remain the contract. |
| Whole-share cycle in the E1 solver | The solver's two-cycle detection and its conservative choice (`lower_buy`) count the short open when `short_active`, so a target whose whole-share floor flips between two E1 bases resolves to the lower open. |

## File map

| File | Responsibility in this plan |
| --- | --- |
| `engine/engine.ml`, `engine/engine.mli` | Short types and profile fields, `effective_targets ?short_ratio`, the short leg in `plan_fills`, short state and helpers in `run`, borrow, dividends, maintenance and cure, the `Overnight` cadence. |
| `lang/ast.ml`, `lang/ast.mli`, `lang/lexer.mll`, `lang/parser.mly` | `Short` and `Overnight` statements and keywords. |
| `lang/dsl.ml`, `lang/dsl.mli` | `short_of`, `overnight_of`, the target floor in `compile_ast ?short_cap`. |
| `bin/bt.ml` | `--borrow-rate`, `--short-maintenance-ratio`, `--fill` rejection, per-file fill, parse validation in `bt target` and `bt live`. |
| `broker/live.ml`, `intraday/intraday.ml`, `report/report.ml` | Record and match updates only. |
| `test/test_bt.ml` | Tests 1-8. |
| `docs/strategy.md`, `docs/engine.md`, `docs/cli.md`, `CONTRIBUTING.md`, `CHANGELOG.md` | Docs row. |

## Tasks

### Task 1: Profile fields and short types

**Files:**
- Modify: `engine/engine.ml:106-139` (maintenance model, `market_profile`, `profile_of_market`), `engine/engine.ml:237-256` (`effective_targets`)
- Modify: `engine/engine.mli:106-125`, `engine/engine.mli:151-153`
- Test: `test/test_bt.ml:3963-3975` (`test_profile_of_market`), new `test_short_effective_targets` after `test_engine_effective_targets` (`test/test_bt.ml:4672-4687`)

**Interfaces:**
- Consumes: nothing new.
- Produces: `type short_tier = { price_below : float; per_share : float; rate : float }`; `type short_maintenance = Tiers of short_tier list | Unsupported`; `market_profile` fields `short_initial_ratio : float`, `short_maintenance : short_maintenance`, `default_borrow_rate : float`, `short_owes_dividends : bool`, `short_share_quantum : float`; `val effective_targets : ?short_ratio:float -> financing_ratios:float array -> float array -> float array * bool`.

- [ ] **Step 1: Write the failing tests**

Replace `test_profile_of_market` (`test/test_bt.ml:3963-3975`) with:

```ocaml
let test_profile_of_market () =
  let tw = Engine.profile_of_market "tw" in
  assert (tw.Engine.interest_day_count = 365.);
  assert (tw.Engine.settlement_lag = 2);
  assert (tw.Engine.maintenance = Engine.Collateral_over_loan);
  assert (tw.Engine.default_financing_rate = 6.35);
  (* TW declares shorts unsupported; the other short fields are unused. *)
  assert (tw.Engine.short_maintenance = Engine.Unsupported);
  let us = Engine.profile_of_market "us" in
  assert (us.Engine.interest_day_count = 360.);
  assert (us.Engine.settlement_lag = 1);
  assert (us.Engine.maintenance = Engine.Equity_over_required);
  assert (us.Engine.default_financing_rate = 6.25);
  (* Reg T 150%: 0.5 of collateral per unit of proceeds; ETB borrow is
     free; the short pays dividends; whole shares only. *)
  assert (us.Engine.short_initial_ratio = 0.5);
  assert (us.Engine.default_borrow_rate = 0.);
  assert us.Engine.short_owes_dividends;
  assert (us.Engine.short_share_quantum = 1.);
  (* The Alpaca table: $2.50/share or 100% below $5, else $5/share or 30%. *)
  assert
    (us.Engine.short_maintenance
     = Engine.Tiers
         [ { price_below = 5.0; per_share = 2.5; rate = 1.0 };
           { price_below = Float.infinity; per_share = 5.0; rate = 0.30 } ]);
  (try ignore (Engine.profile_of_market "xx"); assert false
   with Invalid_argument _ -> ())
```

Insert after `test_engine_effective_targets` (after `test/test_bt.ml:4687`):

```ocaml
let test_short_effective_targets () =
  let effective ?short_ratio targets =
    Engine.effective_targets ?short_ratio ~financing_ratios:[| 0.5; 0.5 |]
      targets
  in
  (* Without short_ratio the existing clamp pins -1 to 0. *)
  assert (effective [| -1.; 0. |] = ([| 0.; 0. |], false));
  (* -1 needs 0.5 of collateral, which fits. *)
  assert (effective ~short_ratio:0.5 [| -1.; 0. |] = ([| -1.; 0. |], false));
  (* Long 1.5 needs 0.75 down and short -0.5 needs 0.25: exactly 1, no
     scaling. *)
  assert
    (effective ~short_ratio:0.5 [| 1.5; -0.5 |] = ([| 1.5; -0.5 |], false));
  (* Long 2 needs 1 and short -1 needs 0.5: need 1.5 scales both by 2/3. *)
  let scaled, clamped = effective ~short_ratio:0.5 [| 2.; -1. |] in
  assert clamped;
  assert_close (4. /. 3.) scaled.(0);
  assert_close (-. 2. /. 3.) scaled.(1);
  (* NaN still clamps to 0 with short_ratio. *)
  assert (effective ~short_ratio:0.5 [| Float.nan; 0. |] = ([| 0.; 0. |], false))
```

Register it in the `let () =` block (`test/test_bt.ml:9567`): after the line `  test_engine_effective_targets ();` add `  test_short_effective_targets ();`.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `dune build 2>&1 | head -20`
Expected: a type error on `tw.Engine.short_maintenance` (unbound record field).

- [ ] **Step 3: Add the types and profile fields**

In `engine/engine.ml`, after `type maintenance_model` (lines 106-108) insert:

```ocaml
type short_tier = {
  price_below : float;
  per_share : float;
  rate : float;
}

type short_maintenance = Tiers of short_tier list | Unsupported
```

Replace `type market_profile` (lines 110-118) with:

```ocaml
type market_profile = {
  interest_day_count : float;
  settlement_lag : int;
  maintenance : maintenance_model;
  default_financing_rate : float;
  default_financing_ratio : float;
  cash_share_quantum : float;
  margin_share_quantum : float;
  short_initial_ratio : float;
  short_maintenance : short_maintenance;
  default_borrow_rate : float;
  short_owes_dividends : bool;
  short_share_quantum : float;
}
```

Replace the two profile literals in `profile_of_market` (lines 121-136) with:

```ocaml
  | "tw" ->
      { interest_day_count = 365.;
        settlement_lag = 2;
        maintenance = Collateral_over_loan;
        default_financing_rate = 6.35;
        default_financing_ratio = 0.6;
        cash_share_quantum = 1.;
        margin_share_quantum = 1000.;
        short_initial_ratio = 0.;
        short_maintenance = Unsupported;
        default_borrow_rate = 0.;
        short_owes_dividends = false;
        short_share_quantum = 0. }
  | "us" ->
      { interest_day_count = 360.;
        settlement_lag = 1;
        maintenance = Equity_over_required;
        default_financing_rate = 6.25;
        default_financing_ratio = 0.5;
        cash_share_quantum = 0.;
        margin_share_quantum = 0.;
        short_initial_ratio = 0.5;
        short_maintenance =
          Tiers [ { price_below = 5.0; per_share = 2.5; rate = 1.0 };
                  { price_below = Float.infinity; per_share = 5.0;
                    rate = 0.30 } ];
        default_borrow_rate = 0.;
        short_owes_dividends = true;
        short_share_quantum = 1. }
```

- [ ] **Step 4: Add `?short_ratio` to `effective_targets`**

Replace `effective_targets` (`engine/engine.ml:237-256`) with:

```ocaml
let effective_targets ?short_ratio ~financing_ratios targets =
  if Array.length financing_ratios <> Array.length targets then
    invalid_arg "Engine.effective_targets: length mismatch";
  let need = ref 0. in
  let effective =
    Array.mapi
      (fun index target ->
        match short_ratio with
        | Some ratio when target < 0. ->
            need := !need +. (-. target *. ratio);
            target
        | None | Some _ ->
            let target = clamp_target target in
            need :=
              !need +. (target *. (1. -. financing_ratios.(index)));
            target)
      targets
  in
  let scale = if !need > 1. then 1. /. !need else 1. in
  let () =
    Array.iteri
      (fun index target -> effective.(index) <- target *. scale)
      effective
  in
  effective, scale < 1.
```

The `None | Some _` arm is the existing body verbatim, so every nonnegative target follows the same operation order as before.

- [ ] **Step 5: Mirror the interface**

In `engine/engine.mli`, replace lines 106-122 (from `(** TW collateral-over-loan ...` through the closing `}` of `market_profile`) with:

```ocaml
(** TW collateral-over-loan or US equity-over-required maintenance. *)
type maintenance_model =
  | Collateral_over_loan
  | Equity_over_required

(** One US short maintenance band. The first tier whose [price_below] is
    strictly above the mark price applies; the last tier has
    [price_below = infinity]. *)
type short_tier = {
  price_below : float;
  per_share : float;
  rate : float;
}

(** Short maintenance terms: the requirement is
    [max (per_share * shares / capital) (rate * short_value)] per asset,
    or shorts are rejected at parse time. *)
type short_maintenance = Tiers of short_tier list | Unsupported

(** Per-market simulation constants and tradable share quanta. *)
type market_profile = {
  interest_day_count : float;
  settlement_lag : int;
  maintenance : maintenance_model;
  default_financing_rate : float;
  default_financing_ratio : float;
  cash_share_quantum : float;
  (** Minimum cash share increment; zero preserves fractional shares. *)
  margin_share_quantum : float;
  (** Minimum margin share increment; zero preserves fractional shares. *)
  short_initial_ratio : float;
  (** Collateral reserved per unit of short proceeds. *)
  short_maintenance : short_maintenance;
  default_borrow_rate : float;
  (** Annual borrow fee on the short value, per [interest_day_count]. *)
  short_owes_dividends : bool;
  (** The short pays the cash dividend on the ex-date. *)
  short_share_quantum : float;
  (** Minimum short share increment; zero preserves fractional shares. *)
}
```

Replace lines 151-153 (`effective_targets`) with:

```ocaml
(** Clamp invalid targets and rescale a bar's portfolio to its funding cap.
    Without [short_ratio] a negative target clamps to 0; with it a negative
    target is kept and needs [-target * short_ratio] of equity. *)
val effective_targets :
  ?short_ratio:float ->
  financing_ratios:float array -> float array -> float array * bool
```

- [ ] **Step 6: Build and run the tests**

Run: `dune build 2>&1` then `dune test --force 2>&1`
Expected: no output from the build; the test run ends with `ok`.

- [ ] **Step 7: Commit**

Commit only after the coordinator confirms; use the co-author trailer the coordinator names; never push; never change git settings.

```bash
git add engine/engine.ml engine/engine.mli test/test_bt.ml
git commit -m "feat: short profile fields and signed effective targets"
```

### Task 2: DSL short and overnight statements

**Files:**
- Modify: `lang/ast.ml:8-18`, `lang/ast.mli:10-20`, `lang/lexer.mll:12-14`, `lang/parser.mly:8`, `lang/parser.mly:61-62`
- Modify: `lang/dsl.ml:469-490` (after `rebalance_of`, `compile_ast` head), `lang/dsl.ml:617`, `lang/dsl.ml:670-678`, `lang/dsl.ml:779-789` (`compile`)
- Modify: `lang/dsl.mli:8-10`, `lang/dsl.mli:24-38`
- Test: `test/test_bt.ml`, new `test_short_declaration` and `test_short_opt_in_clamp` after `test_rebalance_declaration` (`test/test_bt.ml:162-181`)

**Interfaces:**
- Consumes: `market_profile.short_initial_ratio` from Task 1 (read by `Dsl.compile` and, in Task 6, by `bt run`).
- Produces: `Ast.Short`, `Ast.Overnight`; `val short_of : filename:string -> Ast.stmt list -> bool`; `val overnight_of : filename:string -> Ast.stmt list -> bool`; `compile_ast ?extra ?short_cap statements ~params ~assets` where `short_cap = Some cap` keeps negative targets down to `-cap` and `None` floors them at 0; `Dsl.compile` validates both declarations and derives `short_cap` from the file's market.

- [ ] **Step 1: Write the failing tests**

Insert after `test_rebalance_declaration` (after `test/test_bt.ml:181`):

```ocaml
let test_short_declaration () =
  let parse source function_ =
    with_temp_strategy source (fun path ->
      function_ path (Dsl.parse_file path))
  in
  let () =
    parse "stock \"us/SPY\"\nshort\ntarget -1\n" (fun path ast ->
      assert (Dsl.short_of ~filename:path ast);
      assert (not (Dsl.overnight_of ~filename:path ast)))
  in
  let () =
    parse "stock \"us/SPY\"\novernight\ntarget 1\n" (fun path ast ->
      assert (Dsl.overnight_of ~filename:path ast);
      assert (not (Dsl.short_of ~filename:path ast)))
  in
  let rejects source suffix =
    parse source (fun path ast ->
      match Dsl.short_of ~filename:path ast, Dsl.overnight_of ~filename:path ast with
      | _ -> assert false
      | exception Failure message -> assert (message = path ^ suffix))
  in
  rejects "stock \"us/SPY\"\nshort\nshort\ntarget -1\n"
    ": duplicate short declaration";
  rejects "stock \"us/SPY\"\nbars 5m\nshort\ntarget -1\n"
    ": short applies to daily strategies only";
  rejects "stock \"tw/0050\"\nshort\ntarget -1\n"
    ": short targets are not supported for tw";
  rejects "stock \"us/SPY\"\novernight\novernight\ntarget 1\n"
    ": duplicate overnight declaration";
  rejects "stock \"us/SPY\"\nbars 5m\novernight\ntarget 1\n"
    ": overnight applies to daily strategies only";
  rejects "stock \"tw/0050\"\novernight\ntarget 1\n"
    ": overnight is not supported for tw";
  (* Dsl.compile validates like the CLI and derives the market's cap. *)
  let compile source function_ =
    with_temp_strategy source (fun path ->
      function_ path (fun () -> Dsl.compile path ~params:[] sample_bars))
  in
  compile "stock \"us/SPY\"\nshort\ntarget -3\n" (fun _ compile ->
    assert_float_array [| -2.; -2.; -2.; -2.; -2. |]
      (compile ()).Engine.targets.(0));
  compile "stock \"us/SPY\"\novernight\ntarget 1\n" (fun _ compile ->
    assert_float_array [| 1.; 1.; 1.; 1.; 1. |] (compile ()).Engine.targets.(0));
  let compile_rejects source suffix =
    compile source (fun path compile ->
      match compile () with
      | _ -> assert false
      | exception Failure message -> assert (message = path ^ suffix))
  in
  compile_rejects "stock \"us/SPY\"\nshort\nshort\ntarget -1\n"
    ": duplicate short declaration";
  compile_rejects "stock \"tw/0050\"\nshort\ntarget -1\n"
    ": short targets are not supported for tw";
  compile_rejects "stock \"us/SPY\"\nbars 5m\nshort\ntarget -1\n"
    ": short applies to daily strategies only";
  compile_rejects "stock \"us/SPY\"\novernight\novernight\ntarget 1\n"
    ": duplicate overnight declaration";
  compile_rejects "stock \"tw/0050\"\novernight\ntarget 1\n"
    ": overnight is not supported for tw";
  compile_rejects "stock \"us/SPY\"\nbars 5m\novernight\ntarget 1\n"
    ": overnight applies to daily strategies only";
  (* A short file without a stock has no market to size the floor. *)
  compile_rejects "short\ntarget -1\n"
    ": add a stock statement, e.g. stock \"tw/00685L\""

let test_short_opt_in_clamp () =
  let compile ?short_cap source =
    with_temp_strategy source (fun path ->
      (Dsl.compile_ast ?short_cap (Dsl.parse_file path) ~params:[]
         ~assets:[ (None, sample_bars) ]).Engine.targets.(0))
  in
  (* Without short the zero floor applies and nothing fails. *)
  assert_float_array [| 0.; 0.; 0.; 0.; 0. |]
    (compile "stock \"us/SPY\"\ntarget -1\n");
  (* With short the US cap is 1 / 0.5 = 2; -3 clamps to -2 and -1 stays. *)
  assert_float_array [| -2.; -2.; -2.; -2.; -2. |]
    (compile ~short_cap:2. "stock \"us/SPY\"\nshort\ntarget -3\n");
  assert_float_array [| -1.; -1.; -1.; -1.; -1. |]
    (compile ~short_cap:2. "stock \"us/SPY\"\nshort\ntarget -1\n")
```

Register both in the `let () =` block right after `  test_rebalance_declaration ();` (search for that line in `test/test_bt.ml:9541-9809`): add `  test_short_declaration ();` and `  test_short_opt_in_clamp ();`.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `dune build 2>&1 | head -5`
Expected: `Unbound value Dsl.short_of`.

- [ ] **Step 3: Add the statements to the AST, lexer, and parser**

`lang/ast.ml` and `lang/ast.mli`: after `  | Rebalance of bool` add:

```ocaml
  | Short
  | Overnight
```

`lang/lexer.mll`: after `  | "on_change" -> ON_CHANGE` (line 14) add:

```ocaml
  | "short" -> SHORT
  | "overnight" -> OVERNIGHT
```

`lang/parser.mly`: replace line 8 with `%token REBALANCE DAILY ON_CHANGE SHORT OVERNIGHT` and after `| REBALANCE ON_CHANGE { Rebalance false }` (line 62) add:

```ocaml
| SHORT { Short }
| OVERNIGHT { Overnight }
```

- [ ] **Step 4: Add `short_of` and `overnight_of`**

In `lang/dsl.ml`, after `rebalance_of` (after line 488, before `let compile_ast`) insert:

```ocaml
let declared_once ~filename statements ~name ~tw_message ~matches =
  let count = List.length (List.filter matches statements) in
  let () =
    if count > 1 then
      failwith
        (Printf.sprintf "%s: duplicate %s declaration" filename name)
  in
  let () =
    if count = 1
       && List.exists (function Bars _ -> true | _ -> false) statements
    then failwith
      (Printf.sprintf "%s: %s applies to daily strategies only" filename name)
  in
  let () =
    if count = 1
       && List.exists
            (function
              | Stock (spec, _) ->
                  (match fst (split_spec ~filename spec) with
                   | "tw" -> true
                   | _ -> false)
              | _ -> false)
            statements
    then failwith (Printf.sprintf "%s: %s" filename tw_message)
  in
  count = 1

let short_of ~filename statements =
  declared_once ~filename statements ~name:"short"
    ~tw_message:"short targets are not supported for tw"
    ~matches:(function Short -> true | _ -> false)

let overnight_of ~filename statements =
  declared_once ~filename statements ~name:"overnight"
    ~tw_message:"overnight is not supported for tw"
    ~matches:(function Overnight -> true | _ -> false)
```

`split_spec` (`lang/dsl.ml:363-378`) already returns `market, symbol` and fails on an invalid spec with the file name.

- [ ] **Step 5: Floor targets in `compile_ast`**

Replace line 490 with `let compile_ast ?extra ?short_cap statements ~params ~assets =`.

Replace line 617 (`        | Stock _ | Rebalance _ -> environment)`) with:

```ocaml
        | Stock _ | Rebalance _ | Short | Overnight -> environment)
```

Replace lines 670-678 (the `match value with` in the `has_target` branch, from `      match value with` through `      | Bools _ -> fail_expr expression "target must be numeric"`) with:

```ocaml
      let floor_target value =
        match short_cap with
        | None -> if value < 0. then 0. else value
        | Some cap -> if value < -. cap then -. cap else value
      in
      match value with
      | Scalar number -> Array.make context.length (floor_target number)
      | Series series ->
          let () =
            if Array.length series <> context.length then
              fail_expr expression "target series length mismatch"
          in
          Array.map floor_target series
      | Bools _ -> fail_expr expression "target must be numeric"
```

A NaN target is never `< 0.`, so it still reaches the engine, which maps it to 0 as today; a negative target in a file without `short` reaches 0 here, which is the value `Engine.clamp_target` gave it before, so the byte gates are unaffected. The partial-order and legacy styles already clamp at 0 and 1 and are untouched.

Then make the exported file compiler validate and size like the CLI. Replace `compile` (`lang/dsl.ml:779-789`) with:

```ocaml
let compile ?extra source ~params bars =
  let ast = parse_file source in
  let () = ignore (rebalance_of ~filename:source ast) in
  let short = short_of ~filename:source ast in
  let () = ignore (overnight_of ~filename:source ast) in
  if not short && not (List.exists (function Stock _ -> true | _ -> false) ast)
  then compile_ast ?extra ast ~params ~assets:[ (None, bars) ]
  else
    match stocks_of ~filename:source ast with
    | [ (None, market, _) ] ->
        let short_cap =
          if short then
            Some
              (1.
               /. (Engine.profile_of_market market).Engine.short_initial_ratio)
          else None
        in
        compile_ast ?extra ?short_cap ast ~params ~assets:[ (None, bars) ]
    | _ ->
        failwith "Dsl.compile supports single unaliased stocks; use compile_ast"
```

A stock-less file keeps its old path unless it declares `short`, in which case `stocks_of` fails with the existing `<file>: add a stock statement, e.g. stock "tw/00685L"` message, since there is no market to size the floor. `short_of` has already rejected a TW stock, so `short_initial_ratio` is never 0 here.

- [ ] **Step 6: Mirror the interface**

In `lang/dsl.mli`, after `val rebalance_of ...` (line 10) insert:

```ocaml

(** Return whether the file declares [short]. A second declaration, use
    with [bars], and a tw stock fail with messages that name [filename]. *)
val short_of : filename:string -> Ast.stmt list -> bool

(** Return whether the file declares [overnight]. A second declaration,
    use with [bars], and a tw stock fail with messages that name
    [filename]. *)
val overnight_of : filename:string -> Ast.stmt list -> bool
```

Replace lines 24-38 (`compile_ast`, `compile`, and their comments) with:

```ocaml
(** Compile a parsed strategy against its aliased asset data.
    [extra] injects predefined numeric series of the same length as the assets.
    Session series [since_open] and [to_close] require injection by bt daytrade.
    A target-style series is floored at 0, or at [-short_cap] when
    [short_cap] is given for a file that declares [short]. *)
val compile_ast :
  ?extra:(string * float array) list ->
  ?short_cap:float ->
  Ast.stmt list ->
  params:(string * float) list ->
  assets:(string option * Data.bar array) list ->
  Engine.strategy

(** Parse and compile a single-asset strategy source file, with optional
    predefined series as in [compile_ast]. Validates [rebalance], [short],
    and [overnight] like the CLI; a [short] file floors its targets at the
    market's [-1 / short_initial_ratio] and needs a stock statement. *)
val compile :
  ?extra:(string * float array) list ->
  string -> params:(string * float) list -> Data.bar array -> Engine.strategy
```

- [ ] **Step 7: Build and run the tests**

Run: `dune build 2>&1` then `dune test --force 2>&1`
Expected: the build prints nothing; the test command exits 0 and its last line is `ok`. `bin/bt.ml` and `broker/live.ml` still call `compile_ast` without `short_cap`, and `Dsl.compile` passes `None` for every file without `short`, so every existing file compiles exactly as before.

- [ ] **Step 8: Commit**

Commit only after the coordinator confirms; use the co-author trailer the coordinator names; never push; never change git settings.

```bash
git add lang/ast.ml lang/ast.mli lang/lexer.mll lang/parser.mly lang/dsl.ml lang/dsl.mli test/test_bt.ml
git commit -m "feat: short and overnight DSL statements with the target floor"
```

### Task 3: Short inventory and planning

**Files:**
- Modify: `engine/engine.ml:55-98` (`planned_asset`, `plan_state`), `engine/engine.ml:200-216` (after `absolute_sell_cost`), `engine/engine.ml:282-944` (`plan_fills`), `engine/engine.ml:983-2232` (`run`)
- Modify: `engine/engine.mli:58-104`
- Modify: `broker/live.ml:106-110`, `broker/live.ml:857-860`
- Test: `test/test_bt.ml` plan_state literals at base lines 4779, 6151, 6209, 6243, 6403, 6430, 6461, 6476, 6503, 7027, 7110, 7168, 7228, 7387; new `test_short_joint_scaling`, `test_short_leg_plan`, `test_short_reserved_cash_run`, `test_engine_short_leg_run`, `test_short_whole_shares` before `test_us_cure_tail_aware` (`test/test_bt.ml:4469`)

**Interfaces:**
- Consumes: `market_profile.short_initial_ratio`, `short_maintenance`, `short_share_quantum` and `effective_targets ?short_ratio` from Task 1.
- Produces: `plan_state` fields `short_values : float array`, `short_reserved : float array`, `short_borrow : float array`; `planned_asset` fields `plan_short_open`, `plan_short_cover`, `plan_short_final`, `plan_short_cost`, `plan_short_borrow`, `plan_short_from_e`, `plan_short_to_e` (all `float`); inside `run`: arrays `short_values`, `short_reserved`, `short_borrow`, `trip_short`, values `short_quantized`, `short_ratio`, and `cover_short index ~date ~price ~remaining` (Task 4 and Task 5 call these); top-level `absolute_buy_cost costs capital index value`.

- [ ] **Step 1: Write the failing tests**

Insert before `let test_us_cure_tail_aware () =` (`test/test_bt.ml:4469`):

```ocaml
let short_state ?(short_values = [| 0.; 0. |]) ?(short_reserved = [| 0.; 0. |])
    ~equity ~cash ~cash_values ~previous_targets () : Engine.plan_state =
  { equity; cash; cash_values; margin_values = [| 0.; 0. |];
    loans = [| 0.; 0. |]; interests = [| 0.; 0. |];
    tail_interests = [| 0.; 0. |]; debt = 0.; receivables = 0.;
    previous_targets; short_values; short_reserved;
    short_borrow = [| 0.; 0. |] }

let test_short_joint_scaling () =
  (* Flat account, capital 1000000 at price 10 so 0.5 is 50000 whole shares. *)
  let plan =
    Engine.plan_fills ~costs:[| zero_costs; zero_costs |] ~capital:1000000.
      ~profile:us_profile ~financing_ratios:[| 0.5; 0.5 |]
      ~state:(short_state ~equity:1. ~cash:1. ~cash_values:[| 0.; 0. |]
                ~previous_targets:[| 0.; 0. |] ())
      ~prices:[| 10.; 10. |] ~targets:[| 1.5; -0.5 |] ~force:false
  in
  let long = plan.Engine.planned_assets.(0) in
  let short = plan.Engine.planned_assets.(1) in
  (* The short opens first: proceeds 0.5, reserved 0.75, collateral 0.25
     leaves available cash 0.75. The positive sum 1.5 classifies the book
     as levered, so the long leg is financed as 1.5 of margin inventory
     with a 0.75 down payment instead of being cut to the 0.75 cash cap. *)
  assert_close 0.5 short.Engine.plan_short_open;
  assert_close 0.5 short.Engine.plan_short_final;
  assert_close (-0.5) short.Engine.plan_short_to_e;
  assert_close 1.5 long.Engine.plan_trade;
  assert_close 1.5 long.Engine.plan_buy_margin;
  assert_close 0. long.Engine.plan_buy_cash;
  assert_close 0.75 long.Engine.plan_down_payment;
  assert (not plan.Engine.planned_funding_clamp)

let test_short_leg_plan () =
  let costs = { zero_costs with Engine.fee_bps = 100. } in
  let plan ?short_values ?short_reserved ~equity ~cash ~cash_values
      ~previous_targets targets =
    Engine.plan_fills ~costs:[| costs; costs |] ~capital:1000.
      ~profile:us_profile ~financing_ratios:[| 0.5; 0.5 |]
      ~state:(short_state ?short_values ?short_reserved ~equity ~cash
                ~cash_values ~previous_targets ())
      ~prices:[| 10.; 10. |] ~targets ~force:false
  in
  (* Open from flat at 1% commission: E1 = 1 - 0.0049 = 0.9951 sizes
     0.5 * 0.9951 * 1000 / 10 = 49.755 shares, floored to 49 = 0.49,
     whose sell charge is 0.0049. *)
  let opened =
    (plan ~equity:1. ~cash:1. ~cash_values:[| 0.; 0. |]
       ~previous_targets:[| 0.; 0. |] [| -0.5; 0. |]).Engine.planned_assets.(0)
  in
  assert_close 0.49 opened.Engine.plan_short_open;
  assert_close 0.0049 opened.Engine.plan_short_cost;
  assert_close 0. opened.Engine.plan_short_from_e;
  assert_close (-. 0.49 /. 0.9951) opened.Engine.plan_short_to_e;
  (* After that open: cash 1 + 0.49 - 0.0049 = 1.4851, reserved
     1.5 * 0.49 = 0.735. A long 1.0 on the second asset is unlevered and
     cut to the available cash E1 - 0.245, where E1 = 0.9951 - 0.01 *
     trade, so trade = 0.7501 / 1.01: the proceeds are not spendable. *)
  let capped =
    plan ~equity:0.9951 ~cash:1.4851 ~cash_values:[| 0.; 0. |]
      ~short_values:[| 0.49; 0. |] ~short_reserved:[| 0.735; 0. |]
      ~previous_targets:[| -0.5; 0. |] [| -0.5; 1. |]
  in
  assert_close 0. capped.Engine.planned_assets.(0).Engine.plan_short_open;
  assert_close 0. capped.Engine.planned_assets.(0).Engine.plan_short_cover;
  assert_close (0.7501 /. 1.01) capped.Engine.planned_assets.(1).Engine.plan_trade;
  (* Reduce to -0.2: E1 = 0.9951 - 0.003 = 0.9921 sizes 0.2 * 0.9921 *
     100 = 19.84 shares, floored to 19 = 0.19, so the cover is 0.30 at a
     1% buy charge of 0.003. *)
  let reduced =
    (plan ~equity:0.9951 ~cash:1.4851 ~cash_values:[| 0.; 0. |]
       ~short_values:[| 0.49; 0. |] ~short_reserved:[| 0.735; 0. |]
       ~previous_targets:[| -0.5; 0. |] [| -0.2; 0. |]).Engine.planned_assets.(0)
  in
  assert_close 0.30 reduced.Engine.plan_short_cover;
  assert_close 0.19 reduced.Engine.plan_short_final;
  assert_close 0.003 reduced.Engine.plan_short_cost;
  assert_close (-. 0.49 /. 0.9951) reduced.Engine.plan_short_from_e;
  (* Cover to zero takes the whole 0.49 and ends at exposure 0. *)
  let covered =
    (plan ~equity:0.9951 ~cash:1.4851 ~cash_values:[| 0.; 0. |]
       ~short_values:[| 0.49; 0. |] ~short_reserved:[| 0.735; 0. |]
       ~previous_targets:[| -0.5; 0. |] [| 0.; 0. |]).Engine.planned_assets.(0)
  in
  assert_close 0.49 covered.Engine.plan_short_cover;
  assert_close 0. covered.Engine.plan_short_final;
  assert_close 0. covered.Engine.plan_short_to_e;
  (* Whole-share cycle: at target -0.5025 the E1 solver alternates
     between 50 shares (cost 0.005, E1 0.995, which funds 49.99875) and
     49 shares (cost 0.0049, E1 0.9951, which funds 50.003775). The cycle
     resolves to the lower open, 49 shares = 0.49. *)
  let cycle =
    (plan ~equity:1. ~cash:1. ~cash_values:[| 0.; 0. |]
       ~previous_targets:[| 0.; 0. |] [| -0.5025; 0. |]).Engine.planned_assets.(0)
  in
  assert_close 0.49 cycle.Engine.plan_short_open;
  assert_close 0.0049 cycle.Engine.plan_short_cost;
  (* No available cash: the open clamps to zero and pays no minimum fee,
     so the plan's total cost is zero and only the clamp is recorded. *)
  let minimum = { zero_costs with Engine.min_fee = 1. } in
  let clamped =
    Engine.plan_fills ~costs:[| minimum; minimum |] ~capital:1000.
      ~profile:us_profile ~financing_ratios:[| 0.5; 0.5 |]
      ~state:(short_state ~equity:1. ~cash:0. ~cash_values:[| 1.; 0. |]
                ~previous_targets:[| 1.; 0. |] ())
      ~prices:[| 10.; 10. |] ~targets:[| 1.; -0.5 |] ~force:false
  in
  assert_close 0. clamped.Engine.planned_assets.(1).Engine.plan_short_open;
  assert_close 0. clamped.Engine.planned_assets.(1).Engine.plan_short_cost;
  assert_close 0. clamped.Engine.planned_total_cost;
  assert clamped.Engine.planned_funding_clamp

let test_short_reserved_cash_run () =
  let bars =
    [| bar "2020-01-01" 100. 100.; bar "2020-01-02" 100. 100. |]
  in
  let result =
    Engine.run ~profile:us_profile
      [| ("us/SHORT", bars); ("us/LONG", bars) |]
      { Engine.targets = [| [| -0.5; -0.5 |]; [| 0.; 1. |] |] }
      [| zero_costs; zero_costs |] ~margin:(no_margin 2) ~capital:1000.
      ~fill:Engine.Close_same ~rebalance:false
  in
  (* The first close shorts 0.5: cash 1.5, reserved 0.75. The second
     close keeps the short and asks for a 1.0 long: the planner may spend
     only 1.5 - 0.75 = 0.75, so the long entry is 0.75, not 1.0. *)
  let long_entry =
    List.find
      (fun (fill : Engine.fill_event) ->
        fill.date = "2020-01-02" && fill.stock = "us/LONG"
        && fill.to_e > 0.)
      result.Engine.fills
  in
  assert_close 0. long_entry.from_e;
  assert_close 0.75 long_entry.to_e;
  assert_float_array [| 1.; 1. |]
    (Array.of_list (List.map snd result.Engine.equity_curve))

let test_engine_short_leg_run () =
  let bars =
    [| bar "2020-01-01" 100. 100.;
       bar "2020-01-02" 100. 100.;
       bar "2020-01-03" 100. 100.;
       bar "2020-01-06" 100. 100.;
       bar "2020-01-07" 100. 100.;
       bar "2020-01-08" 100. 100. |]
  in
  let result =
    Engine.run ~profile:us_profile [| ("us/TEST", bars) |]
      { Engine.targets = [| [| -0.5; -0.8; -0.3; 0.; 0.5; -0.4 |] |] }
      [| zero_costs |] ~margin:(no_margin 1) ~capital:1000.
      ~fill:Engine.Close_same ~rebalance:false
  in
  (* Flat prices and zero costs: opening, adding, reducing, covering, a
     long, and a long-to-short flip all leave equity at 1 on every bar. *)
  assert_float_array [| 1.; 1.; 1.; 1.; 1.; 1. |]
    (Array.of_list (List.map snd result.Engine.equity_curve));
  (* The flip bar writes the long exit row first, then the short entry;
     the end-of-run cover ends at 0. *)
  let expected =
    [ "2020-01-01", 0., -0.5; "2020-01-02", -0.5, -0.8;
      "2020-01-03", -0.8, -0.3; "2020-01-06", -0.3, 0.;
      "2020-01-07", 0., 0.5; "2020-01-08", 0.5, 0.;
      "2020-01-08", 0., -0.4; "2020-01-08", -0.4, 0. ]
  in
  assert (List.length result.Engine.fills = List.length expected);
  List.iter2
    (fun (fill : Engine.fill_event) (date, from_e, to_e) ->
      assert (fill.date = date);
      assert_close from_e fill.from_e;
      assert_close to_e fill.to_e)
    result.Engine.fills expected;
  (* Three trips: the first short (entry 100, exit 100), the long, and
     the final short, all at return 0. *)
  assert (List.length result.Engine.trips = 3);
  List.iter (fun (trip : Engine.trip) -> assert_close 0. trip.net_ret)
    result.Engine.trips

let test_short_whole_shares () =
  let bars =
    [| bar "2020-01-01" 100. 100.; bar "2020-01-02" 100. 100. |]
  in
  let result =
    Engine.run ~profile:us_profile
      [| ("us/SHORT", bars); ("us/LONG", bars) |]
      { Engine.targets = [| [| -0.26; -0.26 |]; [| 0.26; 0.26 |] |] }
      [| zero_costs; zero_costs |] ~margin:(no_margin 2) ~capital:1000.
      ~fill:Engine.Close_same ~rebalance:false
  in
  let entry stock =
    List.find
      (fun (fill : Engine.fill_event) ->
        fill.date = "2020-01-01" && fill.stock = stock)
      result.Engine.fills
  in
  (* 0.26 of 1000 at 100 is 2.6 shares: the short plans 2 shares (0.2)
     while the fractional long keeps 0.26. *)
  assert_close 0.26 (entry "us/LONG").to_e;
  assert_close (-0.2) (entry "us/SHORT").to_e;
  assert (List.length result.Engine.fills = 4)
```

Register the five tests in the `let () =` block right after `  test_us_cure_tail_aware ();` (`test/test_bt.ml:9733`):

```ocaml
  test_short_joint_scaling ();
  test_short_leg_plan ();
  test_short_reserved_cash_run ();
  test_engine_short_leg_run ();
  test_short_whole_shares ();
```

`zero_costs` (line 103), `us_profile` (line 309), `no_margin` (line 301), and `bar` (line 66) already exist above the insertion point. `test_engine_exit_fee_bankruptcy` (line 858) and `test_tw_dividend_receivable` (line 948) stay unchanged; they pin the equity identity with debt and receivables.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `dune build 2>&1 | head -5`
Expected: an error naming the missing record fields `short_values short_reserved short_borrow`.

- [ ] **Step 3: Extend the plan records**

In `engine/engine.ml`, after `  plan_refinance_margin_buy_cost : float;` (line 77, inside `planned_asset`) add:

```ocaml
  plan_short_open : float;
  plan_short_cover : float;
  plan_short_final : float;
  plan_short_cost : float;
  plan_short_borrow : float;
  plan_short_from_e : float;
  plan_short_to_e : float;
```

After `  previous_targets : float array;` (line 97, inside `plan_state`) add:

```ocaml
  short_values : float array;
  short_reserved : float array;
  short_borrow : float array;
```

After `absolute_sell_cost` (after line 215) add the buy-side counterpart used by forced covers when equity is not positive:

```ocaml
let absolute_buy_cost costs capital index value =
  let costs = costs.(index) in
  let commission = value *. costs.fee_bps /. 10000. in
  let commission =
    if costs.min_fee > 0. then Float.max commission (costs.min_fee /. capital)
    else commission
  in
  commission +. value *. costs.slip_bps /. 10000.
```

- [ ] **Step 4: Route the short leg through `plan_fills`**

All edits are inside `plan_fills` (`engine/engine.ml:282-944`). One boolean, `short_active` (any negative target or any held short), guards every short array, pass, and arithmetic term; when it is false the planner allocates one shared zero array per call and otherwise runs the original long-only code. The long-path expressions that change at all are listed at the end of this step with the reason each one is bit-identical.

Replace lines 299-304 (from `  let prev_eff = state.previous_targets in` through `  let unlevered = sum eff <= 1. in`) with:

```ocaml
  let prev_eff = state.previous_targets in
  let eff = targets in
  let short_values = state.short_values in
  let short_reserved = state.short_reserved in
  let short_borrow = state.short_borrow in
  let short_active =
    Array.exists (fun value -> value < 0.) eff
    || Array.exists (fun value -> value > 0.) short_values
  in
  let zeros = Array.make asset_count 0. in
  let long_eff index = if eff.(index) < 0. then 0. else eff.(index) in
  let cash = state.cash in
  let debt = state.debt in
  let e0 = state.equity in
  let unlevered =
    if short_active then
      sum (Array.map (fun value -> Float.max 0. value) eff) <= 1.
    else sum eff <= 1.
  in
```

After `        let post_tails = Array.copy current_tails in` (line 339) insert the short arrays and the cover pass:

```ocaml
        let short_opens =
          if short_active then Array.make asset_count 0. else zeros
        in
        let short_covers =
          if short_active then Array.make asset_count 0. else zeros
        in
        let short_finals =
          if short_active then Array.copy short_values else short_values
        in
        let short_costs =
          if short_active then Array.make asset_count 0. else zeros
        in
        let short_borrows =
          if short_active then Array.make asset_count 0. else zeros
        in
        let short_from_es =
          if short_active then Array.make asset_count 0. else zeros
        in
        let short_to_es =
          if short_active then Array.make asset_count 0. else zeros
        in
        let post_reserved =
          if short_active then Array.copy short_reserved else short_reserved
        in
        let post_borrow =
          if short_active then Array.copy short_borrow else short_borrow
        in
        let short_clamp = ref false in
        let () =
          if short_active then
          iter_assets (fun index ->
            let before = short_values.(index) in
            let () =
              if before > 0. then short_from_es.(index) <- -. before /. e0
            in
            if changed.(index) then
              let desired =
                if eff.(index) < 0. then
                  floor_value ~quantum:profile.short_share_quantum
                    ~price:(price_at index) (-. eff.(index) *. e1)
                else 0.
              in
              if desired < before then
                let cover = before -. desired in
                let fraction = if desired = 0. then 1. else cover /. before in
                let () = short_covers.(index) <- cover in
                let () = short_finals.(index) <- desired in
                let () =
                  short_costs.(index) <-
                    charge index ~equity_before:equity_basis
                      ~delta:(cover /. equity_basis) ~price:(price_at index)
                    *. equity_basis
                in
                let () =
                  short_borrows.(index) <- short_borrow.(index) *. fraction
                in
                let () =
                  post_reserved.(index) <-
                    short_reserved.(index) *. (1. -. fraction)
                in
                post_borrow.(index) <-
                  short_borrow.(index) -. short_borrows.(index))
        in
```

The shared `zeros`, `short_values`, `short_reserved`, and `short_borrow` arrays are never written when `short_active` is false (every write sits inside an `if short_active` block), so sharing them is safe. The `before > 0.` guard keeps `plan_short_from_e` at `0.` rather than `-0.` for a flat asset, so fill rows never print `-0`.

In the long pass that follows, replace line 344 (`              if changed.(index) then eff.(index) *. e1 else current`) with:

```ocaml
              if changed.(index) then long_eff index *. e1 else current
```

and line 353 (`                if changed.(index) then eff.(index) else from_e`) with:

```ocaml
                if changed.(index) then long_eff index else from_e
```

Replace the `available` binding (lines 437-440) with the version that, only when a short is active, nets the short leg and then funds short opens before any long buy:

```ocaml
        let available =
          e1 -. post_assets +. post_liabilities +. debt
          -. total_receivables ()
        in
        let available =
          if short_active then
            available +. sum short_finals +. sum post_borrow
            -. sum post_reserved
          else available
        in
        let available =
          if not short_active then available
          else
          fold_assets
            (fun available index ->
              let before = short_values.(index) in
              if changed.(index) && eff.(index) < 0. then
                let desired =
                  floor_value ~quantum:profile.short_share_quantum
                    ~price:(price_at index) (-. eff.(index) *. e1)
                in
                if desired > before then
                  let ratio = profile.short_initial_ratio in
                  let affordable =
                    if available <= 0. then 0.
                    else
                      floor_value ~quantum:profile.short_share_quantum
                        ~price:(price_at index) (available /. ratio)
                  in
                  let open_, final =
                    if ratio *. (desired -. before) > available +. tolerance
                    then
                      let () = short_clamp := true in
                      let open_ = Float.min (desired -. before) affordable in
                      open_, before +. open_
                    else desired -. before, desired
                  in
                  let () = short_opens.(index) <- open_ in
                  let () = short_finals.(index) <- final in
                  let () =
                    if open_ > 0. then
                      short_costs.(index) <-
                        charge index ~equity_before:equity_basis
                          ~delta:(-. open_ /. equity_basis)
                          ~price:(price_at index)
                        *. equity_basis
                  in
                  let () =
                    post_reserved.(index) <-
                      post_reserved.(index) +. (1. +. ratio) *. open_
                  in
                  available -. ratio *. open_
                else available
              else available)
            available
        in
        let () =
          if short_active then
          iter_assets (fun index ->
            if short_finals.(index) > 0. then
              short_to_es.(index) <- -. short_finals.(index) /. equity_basis)
        in
```

An open clamped to zero pays nothing: `charge` would otherwise bill the minimum commission for an order that `apply_fills` never executes. An unclamped open sets `final` to the floored `desired`, so the post-fill short value is exact at this bar's price; `apply_fills` stores it as is.

In the `total_cost` fold (lines 701-721), replace line 710 (`                  else eff.(index) -. current /. equity_basis`) with:

```ocaml
                  else long_eff index -. current /. equity_basis
```

and line 720 (`            (sum interest_tails)`) with:

```ocaml
            (if short_active then sum interest_tails +. sum short_costs
             else sum interest_tails)
```

Replace lines 860-869 (from `                  plan_refinance_margin_buy_cost =` through `          planned_funding_clamp = funding_clamp }`) with:

```ocaml
                  plan_refinance_margin_buy_cost =
                    margin_refinance_buy_costs.(index);
                  plan_short_open = short_opens.(index);
                  plan_short_cover = short_covers.(index);
                  plan_short_final = short_finals.(index);
                  plan_short_cost = short_costs.(index);
                  plan_short_borrow = short_borrows.(index);
                  plan_short_from_e = short_from_es.(index);
                  plan_short_to_e = short_to_es.(index) });
          planned_total_cost = total_cost;
          planned_refinances =
            Array.exists (fun value -> value > 0.) cash_refinance_values
            || Array.exists
                 (fun value -> value > 0.) margin_refinance_values;
          planned_funding_clamp = funding_clamp || !short_clamp }
```

In `projected_cash` (lines 871-900), replace lines 873-879 (the first `Array.fold_left`) with:

```ocaml
          Array.fold_left
            (fun projected item ->
              let projected =
                if short_active then
                  projected +. item.plan_short_open -. item.plan_short_cover
                  -. item.plan_short_cost -. item.plan_short_borrow
                else projected
              in
              if item.plan_changed && item.plan_trade < 0. then
                projected -. item.plan_trade -. item.plan_repayment
                -. item.plan_interest_settled -. item.plan_trade_cost
              else projected)
            cash plan.planned_assets
```

In `solve` (lines 901-928), the E1 iteration detects a two-cycle only when `quantized` (true for TW; false for the US profile, whose long quanta are 0) and keeps the lower buy. The short leg has its own quantum, so the detection and the conservative choice must also count short opens. Replace `buy_value` (lines 902-908) with:

```ocaml
        let buy_value plan =
          Array.fold_left
            (fun total item ->
              let total =
                if item.plan_trade > 0. then total +. item.plan_trade
                else total
              in
              if short_active then total +. item.plan_short_open else total)
            0. plan.planned_assets
        in
```

and line 922 (`              | Some value when quantized && next = value ->`) with:

```ocaml
              | Some value when (quantized || short_active) && next = value ->
```

Long-path expressions that change, each bit-identical when `short_active` is false:

| Expression | Why the long-only value is unchanged |
| --- | --- |
| `long_eff index` in `final_value`, `to_es`, and `delta_e` | A selection, not an arithmetic operation: with no negative target it returns `eff.(index)` itself. |
| `unlevered` | The `else` arm is the original `sum eff <= 1.`. |
| `available` | The original four-term expression is kept verbatim; the short terms are added only inside `if short_active`. |
| `total_cost` seed | The `else` arm is the original `sum interest_tails`. |
| `projected_cash` | The short terms are added only inside `if short_active`. |
| `buy_value` | The `else` arm returns the original running total. |
| Cycle guard | `quantized || false` is `quantized`. |
| `planned_funding_clamp` | `funding_clamp || false` is `funding_clamp`. |

The `plan_short_*` record fields read the shared zero arrays in the inactive case; no floating-point operation runs on them.

- [ ] **Step 5: Add the short state and helpers to `run`**

All edits are inside `run` (`engine/engine.ml:983-2232`).

After `  let sell_exposure = Array.make asset_count 0. in` (line 1058) insert:

```ocaml
  let short_values = Array.make asset_count 0. in
  let short_reserved = Array.make asset_count 0. in
  let short_borrow = Array.make asset_count 0. in
  let trip_short = Array.make asset_count false in
  let short_quantized = profile.short_share_quantum > 0. in
  let short_ratio =
    match profile.short_maintenance with
    | Tiers _ -> Some profile.short_initial_ratio
    | Unsupported -> None
  in
```

Replace `total_value`, `total_liabilities`, and `has_inventory` (lines 1143-1155; `total_assets` between them stays) so the net value and the borrow liability enter `equity ()` unchanged:

```ocaml
  let total_value index =
    cash_values.(index) +. margin_values.(index) -. short_values.(index)
  in
  let total_assets () =
    fold_assets (fun total index -> total +. total_value index) 0.
  in
  let total_liabilities () =
    total_loans () +. total_interests () +. !debt +. sum short_borrow
  in
  let has_inventory () =
    Array.exists (fun value -> value > 0.) cash_values
    || Array.exists (fun value -> value > 0.) margin_values
    || Array.exists (fun value -> value > 0.) short_values
  in
```

`equity ()` (line 1166) keeps its expression: `cash + total_assets - total_liabilities + receivables` now equals `cash + long + receivables - short - loans - interest - debt - borrow`. For a book without shorts `x -. 0.` and `x +. 0.` are exact.

Replace `start_trip` and `close_trip` (lines 1294-1307) with:

```ocaml
  let start_trip ?(short = false) index ~date =
    let () = entry_dates.(index) <- date in
    let () = trip_short.(index) <- short in
    let () = buy_value.(index) <- 0. in
    let () = buy_exposure.(index) <- 0. in
    let () = sell_value.(index) <- 0. in
    sell_exposure.(index) <- 0.
  in
  let close_trip index ~date =
    let net_ret =
      if trip_short.(index) then
        let entry_price = sell_value.(index) /. sell_exposure.(index) in
        let exit_price = buy_value.(index) /. buy_exposure.(index) in
        (entry_price -. exit_price) /. entry_price
      else
        let entry_price = buy_value.(index) /. buy_exposure.(index) in
        let exit_price = sell_value.(index) /. sell_exposure.(index) in
        exit_price /. entry_price -. 1.
    in
    trips :=
      { entry_date = entry_dates.(index); exit_date = date; net_ret }
      :: !trips
  in
```

A short trip accumulates its opening sales in `sell_value`/`sell_exposure` and its covers in `buy_value`/`buy_exposure`, so `net_ret = (entry - exit) / entry` with entry the sale VWAP.

Between `record_call` (lines 1622-1626) and `bankrupt_all` (line 1627) insert the forced cover, and replace `bankrupt_all` and `effective` (lines 1627-1644) so bankruptcy covers every short and signed targets reach the engine:

```ocaml
  let cover_short index ~date ~price ~remaining =
    let before = short_values.(index) in
    let value = before -. remaining in
    if value > 0. then
      let equity_now = equity () in
      let fraction = if remaining = 0. then 1. else value /. before in
      let open_exposure = sell_exposure.(index) -. buy_exposure.(index) in
      let covered_e =
        if equity_now > 0. then value /. equity_now
        else open_exposure *. fraction
      in
      let from_e =
        if equity_now > 0. then -. before /. equity_now else -. open_exposure
      in
      let to_e = if remaining = 0. then 0. else from_e +. covered_e in
      let cost_value =
        if equity_now > 0. then
          charge index ~equity_before:equity_now ~delta:covered_e ~price
          *. equity_now
        else absolute_buy_cost costs capital index value
      in
      let borrow = short_borrow.(index) *. fraction in
      let () = buy_value.(index) <- buy_value.(index) +. covered_e *. price in
      let () =
        buy_exposure.(index) <- buy_exposure.(index) +. covered_e
      in
      let () = short_values.(index) <- remaining in
      let () =
        short_reserved.(index) <- short_reserved.(index) *. (1. -. fraction)
      in
      let () = short_borrow.(index) <- short_borrow.(index) -. borrow in
      let () = cash := !cash -. value -. cost_value -. borrow in
      let () =
        if !cash < 0. then
          let () = debt := !debt -. !cash in
          cash := 0.
      in
      let () = record_fill index ~date ~price ~from_e ~to_e in
      if remaining = 0. then close_trip index ~date
  in
  let bankrupt_all ~bar_index ~date price_at =
    let () = ignore (track_maintenance price_at) in
    let () = record_call date in
    let () =
      iter_assets (fun index ->
        sell_inventory index ~margin_only:false ~bar_index
          ~date ~price:(price_at index))
    in
    let () =
      iter_assets (fun index ->
        cover_short index ~date ~price:(price_at index) ~remaining:0.)
    in
    let () = settle_all_liabilities () in
    let () = bankrupt := true in
    pending_liquidation := false
  in
  let effective t =
    let targets =
      Array.init asset_count (fun index -> strategy.targets.(index).(t))
    in
    effective_targets ?short_ratio ~financing_ratios:margin.ratios targets
  in
```

`cover_short ~remaining` takes the short value to keep (already floored by its caller) and sets it directly, so no share count is recomputed from a difference.

In `scale_values` (lines 1654-1671), replace lines 1669-1670 (the final `if margin_values ...` expression) with:

```ocaml
      let () =
        if margin_values.(index) <> 0. then
          margin_values.(index) <- scale margin_values.(index)
      in
      if short_values.(index) <> 0. then
        short_values.(index) <-
          (if short_quantized then
             share_value ~capital ~price:next_price
               (floor_shares ~capital ~quantum:profile.short_share_quantum
                  ~price:previous_price short_values.(index))
           else short_values.(index) *. factor))
```

The short leg recovers its whole-share count at the previous price and remarks it, the same device the quantized long inventories use.

In `apply_fills` (lines 1684-1897), replace the `state` record (lines 1692-1697) with:

```ocaml
    let state : plan_state =
      { equity = e0; cash = !cash; cash_values; margin_values;
        loans = current_loans; interests = current_interests;
        tail_interests = current_tails; debt = !debt;
        receivables = total_receivables (); previous_targets = prev_eff;
        short_values; short_reserved; short_borrow }
    in
```

After the `incr clamps` binding (lines 1702-1704, `let () = if clamped || plan.planned_funding_clamp then incr clamps in`) and before the long sell loop (`let () = iter_assets (fun index -> ... if item.plan_changed && item.plan_trade < 0. then`, line 1705) insert the cover loop:

```ocaml
      let () =
        iter_assets (fun index ->
          let item = plan.planned_assets.(index) in
          if item.plan_short_cover > 0. then
            let before = short_values.(index) in
            let fraction =
              if item.plan_short_final = 0. then 1.
              else item.plan_short_cover /. before
            in
            let exposure =
              abs_float (item.plan_short_to_e -. item.plan_short_from_e)
            in
            let () =
              buy_value.(index) <-
                buy_value.(index) +. exposure *. price_at index
            in
            let () =
              buy_exposure.(index) <- buy_exposure.(index) +. exposure
            in
            let () = short_values.(index) <- item.plan_short_final in
            let () =
              short_reserved.(index) <-
                short_reserved.(index) *. (1. -. fraction)
            in
            let () =
              short_borrow.(index) <-
                short_borrow.(index) -. item.plan_short_borrow
            in
            let () =
              cash :=
                !cash -. item.plan_short_cover -. item.plan_short_cost
                -. item.plan_short_borrow
            in
            let () =
              record_fill index ~date ~price:(price_at index)
                ~from_e:item.plan_short_from_e ~to_e:item.plan_short_to_e
            in
            if item.plan_short_final = 0. then close_trip index ~date)
      in
```

After the long buy loop (which ends at line 1882 with `~from_e:item.plan_from_e ~to_e:item.plan_to_e)` followed by `        in`) and before `let () = if !cash < 0. then let deficit = ...` (line 1883) insert the open loop:

```ocaml
        let () =
          iter_assets (fun index ->
            let item = plan.planned_assets.(index) in
            if item.plan_short_open > 0. then
              let () =
                if item.plan_short_from_e = 0. then
                  start_trip ~short:true index ~date
              in
              let exposure =
                abs_float (item.plan_short_to_e -. item.plan_short_from_e)
              in
              let () =
                sell_value.(index) <-
                  sell_value.(index) +. exposure *. price_at index
              in
              let () =
                sell_exposure.(index) <- sell_exposure.(index) +. exposure
              in
              let () = short_values.(index) <- item.plan_short_final in
              let () =
                short_reserved.(index) <-
                  short_reserved.(index)
                  +. (1. +. profile.short_initial_ratio)
                     *. item.plan_short_open
              in
              let () =
                cash :=
                  !cash +. item.plan_short_open -. item.plan_short_cost
              in
              record_fill index ~date ~price:(price_at index)
                ~from_e:item.plan_short_from_e ~to_e:item.plan_short_to_e)
        in
```

Covers run before the long sells and opens after the long buys, so a sign flip sells or covers the old leg, records its row ending at 0, and only then opens the new leg from 0 in the same bar. The existing `if equity () <= 0. then if has_inventory () then bankrupt_all ...` tail (lines 1889-1894) now sees short inventory through `has_inventory`.

Long-path expressions in `run` that change in this step, each bit-identical for a book that never holds a short:

| Expression | Why the long-only value is unchanged |
| --- | --- |
| `total_value index` | `cash +. margin -. 0.` is exact (`x -. 0. = x` for every finite `x`, and `-0.` never arises because the left operand is a sum of nonnegative values). |
| `total_liabilities ()` | `x +. 0.` with `sum short_borrow = 0.` is exact. |
| `has_inventory ()`, the solvency and bankruptcy tails | Boolean `||` with a false right operand. |
| `effective t` | `effective_targets ?short_ratio` takes the original arm for every nonnegative target (Task 1). |
| `scale_values`, `apply_fills` cover and open loops, `closed_any` | Each short branch sits behind `short_values.(index) <> 0.`, `item.plan_short_cover > 0.`, `item.plan_short_open > 0.`, or `short_values.(index) > 0.`; no floating-point operation runs on the long path. |
| `start_trip`, `close_trip` | The long arm of `close_trip` is the original expression; `trip_short` is a boolean. |

Replace the end-of-run `closed_any` fold (lines 2203-2215) with:

```ocaml
  let closed_any =
    fold_assets
      (fun closed_any index ->
        let closed_any =
          if total_value index > 0. then
            let () =
              sell_inventory index ~margin_only:false ~bar_index:last_index
                ~date:(snd assets.(index)).(last_index).Data.date
                ~price:(close_at index last_index)
            in
            true
          else closed_any
        in
        if short_values.(index) > 0. then
          let () =
            cover_short index
              ~date:(snd assets.(index)).(last_index).Data.date
              ~price:(close_at index last_index) ~remaining:0.
          in
          true
        else closed_any)
      false
  in
```

- [ ] **Step 6: Mirror the interface**

In `engine/engine.mli`, replace lines 58-82 (`planned_asset` and its comment) with:

```ocaml
(** One asset's frozen sell, refinancing, buy, and short legs, in
    account-value units. The short leg covers before the long leg sells
    and opens after the long leg buys; a long and a short never coexist
    in one asset. *)
type planned_asset = {
  plan_changed : bool;
  plan_final_value : float;
  plan_trade : float;
  plan_from_e : float;
  plan_to_e : float;
  plan_trade_cost : float;
  plan_sell_margin : float;
  plan_sell_cash : float;
  plan_repayment : float;
  plan_interest_settled : float;
  plan_buy_cash : float;
  plan_buy_margin : float;
  plan_down_payment : float;
  plan_refinance_cash : float;
  plan_refinance_margin : float;
  plan_refinance_margin_repayment : float;
  plan_refinance_margin_interest : float;
  plan_refinance_e : float;
  plan_refinance_cash_sell_cost : float;
  plan_refinance_cash_buy_cost : float;
  plan_refinance_margin_sell_cost : float;
  plan_refinance_margin_buy_cost : float;
  plan_short_open : float;
  (** Short value sold at the fill price; proceeds raise cash. *)
  plan_short_cover : float;
  (** Short value bought back at the fill price. *)
  plan_short_final : float;
  (** Short value held after the fill, floored to the short quantum. *)
  plan_short_cost : float;
  (** Sell-side charge of the open plus buy-side charge of the cover. *)
  plan_short_borrow : float;
  (** Accrued borrow fee settled from cash by the cover. *)
  plan_short_from_e : float;
  plan_short_to_e : float;
}
```

Replace lines 92-104 (`plan_state` and its comment) with:

```ocaml
(** Explicit account and inventory inputs to the pure fill planner.
    [short_values] is the marked short exposure, [short_reserved] the
    cash reserved against it, and [short_borrow] its accrued borrow fee,
    all nonnegative and per asset. *)
type plan_state = {
  equity : float;
  cash : float;
  cash_values : float array;
  margin_values : float array;
  loans : float array;
  interests : float array;
  tail_interests : float array;
  debt : float;
  receivables : float;
  previous_targets : float array;
  short_values : float array;
  short_reserved : float array;
  short_borrow : float array;
}
```

- [ ] **Step 7: Update the two live record literals**

`broker/live.ml:106-110` (`us_plan_state`) becomes:

```ocaml
  { Engine.equity = cash +. total -. debit; cash;
    cash_values = Array.mapi (fun i value -> value -. margin_values.(i)) values;
    margin_values; loans; interests = Array.make count 0.;
    tail_interests = Array.make count 0.; debt = 0.; receivables = 0.;
    previous_targets; short_values = Array.make count 0.;
    short_reserved = Array.make count 0.; short_borrow = Array.make count 0. }
```

`broker/live.ml:857-860` (the TW `state`) becomes:

```ocaml
      let state : Engine.plan_state =
        { equity; cash; cash_values; margin_values; loans; interests;
          tail_interests = Array.make (Array.length symbols) 0.;
          debt = 0.; receivables = 0.; previous_targets;
          short_values = Array.make (Array.length symbols) 0.;
          short_reserved = Array.make (Array.length symbols) 0.;
          short_borrow = Array.make (Array.length symbols) 0. } in
```

- [ ] **Step 8: Update the fourteen test literals**

Fourteen `Engine.plan_state` literals in `test/test_bt.ml` end with a `previous_targets = ... }` line; each gains the three zero arrays. Base-commit lines and the replacement for the field's line (keep the existing indentation; keep a trailing `in` where the base line has one):

Line 4779 (`test_us_plan_state_split`):

```ocaml
        debt = 0.; receivables = 0.; previous_targets = [|1.5|];
        short_values = [|0.|]; short_reserved = [|0.|];
        short_borrow = [|0.|] } in
```

Lines 6151, 6209, 7027, and 7110 (`previous_targets = [| previous |] }`):

```ocaml
          previous_targets = [| previous |]; short_values = [| 0. |];
          short_reserved = [| 0. |]; short_borrow = [| 0. |] }
```

Line 6243 (`previous_targets = [| 5. /. 3. |] }`):

```ocaml
          receivables = 0.; previous_targets = [| 5. /. 3. |];
          short_values = [| 0. |]; short_reserved = [| 0. |];
          short_borrow = [| 0. |] }
```

Line 6403 (`previous_targets = [| 1. |] }`):

```ocaml
          receivables = 0.; previous_targets = [| 1. |];
          short_values = [| 0. |]; short_reserved = [| 0. |];
          short_borrow = [| 0. |] }
```

Lines 6430, 6461, 6476, 6503, and 7228 (`previous_targets = [| 0. |] }`):

```ocaml
          previous_targets = [| 0. |]; short_values = [| 0. |];
          short_reserved = [| 0. |]; short_borrow = [| 0. |] }
```

Lines 7168 and 7387 (`receivables = 0.; previous_targets = [|0.|] }`):

```ocaml
      receivables = 0.; previous_targets = [|0.|]; short_values = [|0.|];
      short_reserved = [|0.|]; short_borrow = [|0.|] }
```

Where the base line also starts with `receivables = 0.;` (6209, 6243, 6403, 6430, 6461, 7027), keep that field at the front of the first line as shown for 6243 and 6403. Line 4779 belongs to `test_us_plan_state_split`, whose `Marshal.to_bytes expected [] = Marshal.to_bytes actual []` gate keeps holding because `Live.us_plan_state` now builds the same three zero arrays. After the edit, `grep -c "short_borrow = " test/test_bt.ml` prints at least 15 (fourteen literals plus `short_state`).

- [ ] **Step 9: Build and run the tests**

Run: `dune build 2>&1` then `dune test --force 2>&1`
Expected: the build prints nothing; the test command exits 0 and its last line is `ok`. The coordinator reruns the six byte gates after this task.

- [ ] **Step 10: Commit**

Commit only after the coordinator confirms; use the co-author trailer the coordinator names; never push; never change git settings.

```bash
git add engine/engine.ml engine/engine.mli broker/live.ml test/test_bt.ml
git commit -m "feat: short leg in the fill planner and engine inventory"
```

### Task 4: Carried shorts

**Files:**
- Modify: `engine/engine.ml:200-216` (after `absolute_sell_cost`), `engine/engine.ml:1180-1187` (`required_margin`), `engine/engine.ml:1227-1228` (`process_dividends` book_event), `engine/engine.ml:1426-1428` (`track_maintenance`), `engine/engine.ml:1672-1683` (`accrue_interest`), `engine/engine.ml:1923-2052` (`minimum_cure`), `engine/engine.ml:2187-2193` (daily trigger)
- Test: `test/test_bt.ml`, new `test_carried_short` after `test_short_whole_shares`

**Interfaces:**
- Consumes: `short_values`, `short_borrow`, `cover_short`, `short_requirement_rate` (defined here), `profile.default_borrow_rate`, `profile.short_owes_dividends`, `profile.short_maintenance` from Tasks 1 and 3.
- Produces: top-level `short_requirement_rate : market_profile -> price:float -> float` (requirement per unit of short value: `max (per_share / price) rate`); inside `run`: `cure_shorts ~date price_at`.

- [ ] **Step 1: Write the failing test**

Insert after `test_short_whole_shares` in `test/test_bt.ml`:

```ocaml
let test_carried_short () =
  let run ?(profile = us_profile) ?(dividends = [||]) bars targets =
    Engine.run ~dividends:[| dividends |] ~profile [| ("us/TEST", bars) |]
      { Engine.targets = [| targets |] } [| zero_costs |] ~margin:(no_margin 1)
      ~capital:1000. ~fill:Engine.Close_same ~rebalance:false
  in
  let equity result = Array.of_list (List.map snd result.Engine.equity_curve) in
  (* Borrow 36%/yr on 0.5 is 0.0005 per calendar day: Friday to Monday
     accrues three days, Monday to Tuesday one; the end-of-run cover
     pays the 0.002 from cash. *)
  let borrow =
    run ~profile:{ us_profile with Engine.default_borrow_rate = 0.36 }
      [| bar "2020-01-03" 100. 100.; bar "2020-01-06" 100. 100.;
         bar "2020-01-07" 100. 100. |]
      [| -0.5; -0.5; -0.5 |]
  in
  assert_float_array [| 1.; 0.9985; 0.998 |] (equity borrow);
  (* Three shares at 10 are 0.03 of 1000; a USD 1 dividend on the ex-date
     costs 3 * 1 / 1000 = 0.003. *)
  let dividend =
    run ~dividends:[| dividend "2020-01-02" 1. "2020-01-20" |]
      [| bar "2020-01-01" 10. 10.; bar "2020-01-02" 10. 10. |]
      [| -0.03; -0.03 |]
  in
  assert_float_array [| 1.; 0.997 |] (equity dividend);
  (* Ten shares shorted at 4: tier 1 requires max(2.5 * 10 / 1000, 1.0 *
     0.04) = 0.04, ratio 25. At 6 the band switches: max(5 * 10 / 1000,
     0.3 * 0.06) = 0.05, the per-share floor, against equity 0.98. *)
  let tiers =
    run [| bar "2020-01-01" 4. 4.; bar "2020-01-02" 6. 6. |] [| -0.04; -0.04 |]
  in
  (match tiers.Engine.margin_stats.Engine.min_maintenance with
   | Some ratio -> assert_close (0.98 /. 0.05) ratio
   | None -> assert false);
  (* A loan-free short of 2.0 under a flat 30% requirement: at 120 the
     short is 2.4 against equity 0.6, required 0.72, so the close records
     a call. The next open covers deficit 0.12 / relief 0.3 = 0.4, keeping
     2.0 floored to 16 shares at 120 = 1.92, a cover of 0.48 from
     exposure -4 to -3.2. The trip sold at 100 and covered at 120. *)
  let flat =
    { us_profile with
      Engine.short_maintenance =
        Engine.Tiers [ { price_below = Float.infinity; per_share = 0.;
                         rate = 0.3 } ] }
  in
  let cure =
    run ~profile:flat
      [| bar "2020-01-01" 100. 100.; bar "2020-01-02" 100. 120.;
         bar "2020-01-03" 120. 120. |]
      [| -2.; -2.; -2. |]
  in
  assert (cure.Engine.margin_stats.Engine.margin_call_dates = [ "2020-01-02" ]);
  assert_float_array [| 1.; 0.6; 0.6 |] (equity cure);
  (match cure.Engine.fills with
   | [ _; cover; close ] ->
       assert (cover.date = "2020-01-03" && cover.price = 120.);
       assert_close (-4.) cover.from_e;
       assert_close (-3.2) cover.to_e;
       assert_close (-3.2) close.from_e;
       assert_close 0. close.to_e
   | _ -> assert false);
  (match cure.Engine.trips with
   | [ trip ] -> assert_close (-0.2) trip.net_ret
   | _ -> assert false);
  (* A gap to 160 marks the 2.0 short at 3.2 against cash 3.0: the
     solvency guard covers everything, debt carries the 0.2 deficit, and
     the account stays frozen. *)
  let gap =
    run [| bar "2020-01-01" 100. 100.; bar "2020-01-02" 160. 160.;
           bar "2020-01-03" 100. 100. |]
      [| -2.; -2.; -2. |]
  in
  assert_float_array [| 1.; -0.2; -0.2 |] (equity gap);
  assert (List.length gap.Engine.fills = 2);
  assert (gap.Engine.margin_stats.Engine.margin_call_dates = [ "2020-01-02" ])
```

Register it after `  test_short_whole_shares ();` in the `let () =` block: `  test_carried_short ();`. The `dividend` helper (`test/test_bt.ml:933`) already exists.

- [ ] **Step 2: Run the test to verify it fails**

Run: `dune build 2>&1` then `dune test --force 2>&1`
Expected: the build is clean (every name exists after Task 3) and the suite stops at the first `assert_float_array` of `test_carried_short`, because borrow does not accrue yet (`Assertion failed`).

- [ ] **Step 3: Add the tier lookup**

In `engine/engine.ml`, after `absolute_buy_cost` (added in Task 3 after `absolute_sell_cost`) insert:

```ocaml
let short_requirement_rate (profile : market_profile) ~price =
  match profile.short_maintenance with
  | Unsupported -> 0.
  | Tiers tiers ->
      let tier =
        List.find (fun (tier : short_tier) -> price < tier.price_below) tiers
      in
      Float.max (tier.per_share /. price) tier.rate
```

`per_share x shares / capital` equals `per_share / price x short_value`, so the per-unit rate is `max (per_share / price) rate`. `List.find` relies on the last tier's `price_below = infinity`, which both the US profile and the `--short-maintenance-ratio` override guarantee.

- [ ] **Step 4: Accrue borrow and pay dividends**

Replace `accrue_interest` (`engine/engine.ml:1672-1683`) with:

```ocaml
  let accrue_interest ~bar_index ~date ~prev_date =
    let days = day_number date - day_number prev_date in
    iter_assets (fun index ->
      let () =
        if short_values.(index) > 0. then
          short_borrow.(index) <-
            short_borrow.(index)
            +. short_values.(index) *. profile.default_borrow_rate
               *. float_of_int days /. profile.interest_day_count
      in
      List.iter
        (fun lot ->
          if bar_index > settlement_start_index lot then
            lot.interest <-
              lot.interest
              +. lot.principal *. margin.financing_rate
                 *. float_of_int days /. profile.interest_day_count)
        margin_lots.(index))
  in
```

`accrue_interest` runs at the top of bar `t > 0` before any scaling, so `short_values` is the previous close mark and `days` is the calendar gap to it; the last bar has no successor and accrues nothing.

In `process_dividends` (`engine/engine.ml:1207-1283`), replace lines 1227-1228 (`          let total = cash_amount +. margin_amount in` and `          if total > 0. then`) with:

```ocaml
          let total = cash_amount +. margin_amount in
          let owed =
            if profile.short_owes_dividends && short_values.(index) > 0.
               && price > 0.
            then
              short_values.(index) /. price *. event.Data.cash_per_share
            else 0.
          in
          let () =
            if owed > 0. then
              let () = cash := !cash -. owed in
              if !cash < 0. then
                let () = debt := !debt -. !cash in
                cash := 0.
          in
          if total > 0. then
```

`short_values / price x cash_per_share` is `shares x cash_per_share / capital` in engine units, with no withholding; a payment does not set `landed`. The `short_values.(index) > 0.` guard keeps the long-only path free of the division.

- [ ] **Step 5: Maintenance on the short leg**

Replace `required_margin` (`engine/engine.ml:1180-1187`) with:

```ocaml
  let required_margin price_at =
    fold_assets
      (fun acc index ->
        let value = total_value index in
        let acc =
          if value > 0. then acc +. tier_rate index price_at *. value
          else acc
        in
        if short_values.(index) > 0. then
          acc
          +. short_requirement_rate profile ~price:(price_at index)
             *. short_values.(index)
        else acc)
      0.
  in
```

In `track_maintenance` (line 1428) replace `    if total_loan > 0. then` with:

```ocaml
    if total_loan > 0. || sum short_values > 0. then
```

In the daily trigger (line 2191) replace `              if total_loans () > 0. && e < required then` with:

```ocaml
              if (total_loans () > 0. || sum short_values > 0.) && e < required
              then
```

The TW arm of `track_maintenance` divides by `total_loan`; TW never holds a short (`Unsupported`), so it is only reached with `total_loan > 0.` as before.

- [ ] **Step 6: Cure by buy-to-cover**

Before `minimum_cure` (`engine/engine.ml:1923`) insert:

```ocaml
  let cure_shorts ~date price_at =
    let e = equity () in
    let required = required_margin price_at in
    let total_short = sum short_values in
    if total_short > 0. && e > 0. && e < required then
      let deficit = required -. e in
      let weighted =
        fold_assets
          (fun acc index ->
            if short_values.(index) > 0. then
              acc
              +. short_requirement_rate profile ~price:(price_at index)
                 *. short_values.(index)
            else acc)
          0.
      in
      let cost_per_unit =
        fold_assets
          (fun acc index ->
            if short_values.(index) > 0. then
              acc
              +. charge index ~equity_before:e ~delta:1.
                   ~price:(price_at index)
                 *. short_values.(index)
            else acc)
          0.
        /. total_short
      in
      let relief = weighted /. total_short -. cost_per_unit in
      let cover_total =
        if relief > 0. then Float.min total_short (deficit /. relief)
        else total_short
      in
      let fraction = cover_total /. total_short in
      iter_assets (fun index ->
        if short_values.(index) > 0. then
          let keep =
            floor_value ~capital ~quantum:profile.short_share_quantum
              ~price:(price_at index)
              ((1. -. fraction) *. short_values.(index))
          in
          cover_short index ~date ~price:(price_at index) ~remaining:keep)
  in
```

The remainder is floored, not the cover, so a whole-share cover is never short of the requirement.

Then wrap the existing long cure. Replace the head of `minimum_cure` (lines 1923-1932, from `  let minimum_cure ~bar_index ~date price_at =` through `        let deficit = required -. e in`) with:

```ocaml
  let minimum_cure ~bar_index ~date price_at =
    let e = equity () in
    let total_margin = sum margin_values in
    if e <= 0. || (total_margin <= 0. && sum short_values <= 0.) then
      bankrupt_all ~bar_index ~date price_at
    else
      let required = required_margin price_at in
      if e >= required then ()
      else
        let () =
          if total_margin > 0. then
        let deficit = required -. e in
```

and the tail (lines 2050-2052, `        if equity () <= 0. then` / `          bankrupt_all ~bar_index ~date price_at` / `  in`) with:

```ocaml
        if equity () <= 0. then
          bankrupt_all ~bar_index ~date price_at
        in
        let () = if not !bankrupt then cure_shorts ~date price_at in
        if not !bankrupt && equity () <= 0. then
          bankrupt_all ~bar_index ~date price_at
  in
```

The body between (the tier-weighted long sell, lines 1933-2049) is unchanged and keeps its indentation; it now runs only when the book holds long margin, longs are cured first, then shorts, each the minimum that restores the requirement. A book with no long margin and no short is bankrupt as before; a short-only book cures by covering.

- [ ] **Step 7: Build and run the tests**

Run: `dune build 2>&1` then `dune test --force 2>&1`
Expected: the build prints nothing; the test command exits 0 and its last line is `ok`.

- [ ] **Step 8: Commit**

Commit only after the coordinator confirms; use the co-author trailer the coordinator names; never push; never change git settings.

```bash
git add engine/engine.ml test/test_bt.ml
git commit -m "feat: borrow fee, dividends, and maintenance for carried shorts"
```

### Task 5: Overnight cadence

**Files:**
- Modify: `engine/engine.ml:12` (`fill`), `engine/engine.ml:1684` (`apply_fills` head), `engine/engine.ml:1896` (`prev_eff` blit), `engine/engine.ml:2121-2166` (after the `Open_next` arm of `walk_bars`)
- Modify: `engine/engine.mli:14-15`
- Modify: `report/report.ml:151-154`, `report/report.ml:323-324`, `intraday/intraday.ml:39-40` (before `normalize`), `intraday/intraday.ml:124-128`
- Test: `test/test_bt.ml`, new `test_overnight_cadence` after `test_carried_short`; `test_intraday_normalization` (`test/test_bt.ml:6058-6072`) gains the Overnight rejection

**Interfaces:**
- Consumes: `apply_fills`, `guard_solvency`, `scale_values`, `process_dividends`, `effective`, `differs` inside `run`.
- Produces: `Engine.fill = Open_next | Close_same | Overnight`; `apply_fills ?(remember = true)` inside `run`.

- [ ] **Step 1: Write the failing test**

Insert after `test_carried_short` in `test/test_bt.ml`:

```ocaml
let test_overnight_cadence () =
  let run ?(profile = us_profile) ?(dividends = [||]) ?(rebalance = true)
      bars targets =
    Engine.run ~dividends:[| dividends |] ~profile [| ("us/TEST", bars) |]
      { Engine.targets = [| targets |] } [| zero_costs |] ~margin:(no_margin 1)
      ~capital:1000. ~fill:Engine.Overnight ~rebalance
  in
  let equity result = Array.of_list (List.map snd result.Engine.equity_curve) in
  let rows result =
    List.map
      (fun (fill : Engine.fill_event) ->
        fill.date, fill.price, fill.from_e, fill.to_e)
      result.Engine.fills
  in
  let bars =
    [| bar "2020-01-01" 100. 100.; bar "2020-01-02" 110. 105.;
       bar "2020-01-03" 100. 100. |]
  in
  (* Short 5 shares at the first close. The 110 open marks them at 0.55,
     equity 0.95, and the exit covers there. The 105 close re-enters
     0.5 * 0.95 = 0.475, floored to 4 shares = 0.42. The 100 open marks
     0.40 for equity 0.97; the close re-enters 4 shares = 0.40; the
     end-of-run cover leaves 0.97. One equity point per bar. *)
  let cycle = run bars [| -0.5; -0.5; -0.5 |] in
  assert_float_array [| 1.; 0.95; 0.97 |] (equity cycle);
  assert (List.length (rows cycle) = 6);
  (match rows cycle with
   | [ ("2020-01-01", 100., 0., e0);
       ("2020-01-02", 110., e1, 0.); ("2020-01-02", 105., 0., e2);
       ("2020-01-03", 100., e3, 0.); ("2020-01-03", 100., 0., e4);
       ("2020-01-03", 100., e5, 0.) ] ->
       assert_close (-0.5) e0;
       assert_close (-. 0.55 /. 0.95) e1;
       assert_close (-. 0.42 /. 0.95) e2;
       assert_close (-. 0.40 /. 0.97) e3;
       assert_close (-. 0.40 /. 0.97) e4;
       assert_close (-. 0.40 /. 0.97) e5
   | _ -> assert false);
  (* A USD 1 dividend on the second date is paid by the 5 overnight
     shares at the open, before the exit: 0.005 off equity 0.95. *)
  let ex_date =
    run ~dividends:[| dividend "2020-01-02" 1. "2020-01-20" |] bars
      [| -0.5; -0.5; -0.5 |]
  in
  assert_close 0.945 (equity ex_date).(1);
  (* 20 shares short at 100 marked at a 150 open are 3.0 against cash
     3.0: equity 0 liquidates at the open, the close places no entry, and
     the run ends with two rows and a flat account. *)
  let gap =
    run [| bar "2020-01-01" 100. 100.; bar "2020-01-02" 150. 140.;
           bar "2020-01-03" 100. 100. |]
      [| -2.; -2.; -2. |]
  in
  assert_float_array [| 1.; 0.; 0. |] (equity gap);
  assert (List.length gap.Engine.fills = 2);
  assert (gap.Engine.margin_stats.Engine.margin_call_dates = [ "2020-01-02" ]);
  (* Under on_change an unchanged target exits at the open and does not
     re-enter: the forced exit left prev_eff at -0.5. *)
  let on_change = run ~rebalance:false bars [| -0.5; -0.5; -0.5 |] in
  assert_float_array [| 1.; 0.95; 0.95 |] (equity on_change);
  assert (List.length on_change.Engine.fills = 2);
  (* Borrow 36%/yr is 0.1% per calendar day of the value held. Friday's
     0.5 accrues three nights, 0.0015. Monday re-enters 0.5 * 0.9985 *
     10 = 4.99 shares, floored to 4 = 0.4, which accrues one night,
     0.0004. Tuesday's entry is covered at the close and accrues nothing,
     so the run ends at 0.9981. *)
  let nights =
    run ~profile:{ us_profile with Engine.default_borrow_rate = 0.36 }
      [| bar "2020-01-03" 100. 100.; bar "2020-01-06" 100. 100.;
         bar "2020-01-07" 100. 100. |]
      [| -0.5; -0.5; -0.5 |]
  in
  assert_float_array [| 1.; 0.9985; 0.9981 |] (equity nights)
```

Register it after `  test_carried_short ();`: `  test_overnight_cadence ();`.

In `test_intraday_normalization` (`test/test_bt.ml:6058-6072`), after `  let () = assert rejected in` (line 6065) insert:

```ocaml
  (* The overnight cadence is daily only: it is rejected at the input
     boundary even for flat targets, before any session is simulated. *)
  let overnight_rejected =
    try
      let () =
        ignore (run_intraday ~fill:Engine.Overnight (Array.make 8 0.))
      in
      false
    with Invalid_argument message ->
      message = "Intraday.run: overnight is a daily fill"
  in
  let () = assert overnight_rejected in
```

`run_intraday` (`test/test_bt.ml:5989-5993`) already takes `?fill`.

- [ ] **Step 2: Run the test to verify it fails**

Run: `dune build 2>&1 | head -5`
Expected: `Unbound constructor Engine.Overnight`.

- [ ] **Step 3: Add the constructor and its downstream arms**

`engine/engine.ml:12` becomes `type fill = Open_next | Close_same | Overnight`.

`engine/engine.mli:14-15` becomes:

```ocaml
(** Price used to execute scheduled exposure changes. [Overnight] enters at
    the bar's close and exits at the next bar's open. *)
type fill = Open_next | Close_same | Overnight
```

`report/report.ml:151-154` becomes:

```ocaml
  Printf.printf "Date range: %s; fill: %s\n" range
    (match fill with
     | Engine.Close_same -> "close"
     | Engine.Open_next -> "open"
     | Engine.Overnight -> "overnight")
```

`report/report.ml:323-324` becomes:

```ocaml
  Printf.printf "Date range: %s; fill: %s\n" range
    (match fill with
     | Engine.Close_same -> "close"
     | Engine.Open_next -> "open"
     | Engine.Overnight -> "overnight")
```

In `intraday/intraday.ml`, the decision dispatcher at lines 112-115 sends every fill other than `Close_same` and `Open_next` to its `| _ -> None` arm, so a rejection inside the price match would never run. Reject at the input boundary instead. After the capital check (after line 39, before `  let normalize target =`) insert:

```ocaml
  let fill_price (bar : Data.bar) =
    match config.fill with
    | Engine.Close_same -> bar.c
    | Engine.Open_next -> bar.o
    | Engine.Overnight -> invalid_arg "Intraday.run: overnight is a daily fill"
  in
  let () =
    match config.fill with
    | Engine.Overnight -> invalid_arg "Intraday.run: overnight is a daily fill"
    | Engine.Close_same | Engine.Open_next -> ()
  in
```

and replace lines 124-128 (from `                  let price = match config.fill with` through `                  execute ~cap ~time:bar.date ~price target account`) with:

```ocaml
                  execute ~cap ~time:bar.date ~price:(fill_price bar) target
                    account
```

The boundary check raises before any session is simulated; `fill_price` keeps the price selection in one exhaustive match with the same message on its unreachable arm.

- [ ] **Step 4: Let `apply_fills` skip the `prev_eff` update**

Replace line 1684 (`  let apply_fills ~bar_index ~date ~eff ~clamped ~force price_at =`) with:

```ocaml
  let apply_fills ?(remember = true) ~bar_index ~date ~eff ~clamped ~force
      price_at =
```

and line 1896 (`    Array.blit eff 0 prev_eff 0 asset_count`) with:

```ocaml
    if remember then Array.blit eff 0 prev_eff 0 asset_count
```

- [ ] **Step 5: Add the cadence to `walk_bars`**

After the `Open_next` arm, which ends at lines 2165-2166 with:

```ocaml
                scale_values
                  (fun i -> close_at i t) (fun i -> open_at i t)
```

insert the third arm:

```ocaml
          | Overnight ->
              let eff, clamped = effective t in
              let () =
                if t > 0 then
                  let () =
                    scale_values (fun i -> open_at i t)
                      (fun i -> close_at i (t - 1))
                  in
                  let () =
                    ignore
                      (process_dividends ~previous_date ~date
                         (fun i -> open_at i t))
                  in
                  let () = pending_liquidation := false in
                  let () =
                    guard_solvency ~bar_index:t ~date
                      (fun i -> open_at i t)
                  in
                  let () =
                    if not !bankrupt then
                      apply_fills ~remember:false ~bar_index:t ~date
                        ~eff:(Array.make asset_count 0.) ~clamped:false
                        ~force:true (fun i -> open_at i t)
                  in
                  scale_values
                    (fun i -> close_at i t) (fun i -> open_at i t)
              in
              let () =
                guard_solvency ~bar_index:t ~date (fun i -> close_at i t)
              in
              if not !bankrupt && (rebalance || differs eff) then
                apply_fills ~bar_index:t ~date ~eff ~clamped
                  ~force:rebalance (fun i -> close_at i t)
```

Per bar: the open step scales to the open, books ex-date dividends on the overnight position, drops any call pending from the previous close (the exit covers it), guards solvency (a bankrupt open covers everything and skips both fills), exits everything with `force:true` without remembering, and scales to the close. The close step enters the bar's target; under `on_change`, `differs eff` compares with the previous close-entry targets. The code after the `match` (solvency guard, maintenance check, equity point at the close, lines 2168-2199) is unchanged and runs once per bar, so the equity curve keeps one point per bar. `accrue_interest` at the top of the bar covers the nights.

- [ ] **Step 6: Build and run the tests**

Run: `dune build 2>&1` then `dune test --force 2>&1`
Expected: the build prints nothing; the test command exits 0 and its last line is `ok`.

- [ ] **Step 7: Commit**

Commit only after the coordinator confirms; use the co-author trailer the coordinator names; never push; never change git settings.

```bash
git add engine/engine.ml engine/engine.mli report/report.ml intraday/intraday.ml test/test_bt.ml
git commit -m "feat: overnight fill cadence"
```

### Task 6: CLI flags and errors

**Files:**
- Modify: `bin/bt.ml:7-13` (usage), `bin/bt.ml:149-156` (`strategy_input`), `bin/bt.ml:181-202` (refs and `--fill`), `bin/bt.ml:230-232` (after `--loan-term-months`), `bin/bt.ml:270-295` (`parsed`, `all_markets`), `bin/bt.ml:308` (`profile`), `bin/bt.ml:332-342` (`inputs`), `bin/bt.ml:419-421` (compile), `bin/bt.ml:461-467` (run), `bin/bt.ml:504-507` (report), `bin/bt.ml:578` (daytrade parse), `bin/bt.ml:744-749` (`live_command_args`)
- Test: `test/test_bt.ml`, new `test_short_cli_errors` after `test_bars_rebalance_target_routing` (`test/test_bt.ml:5886-5898`)

**Interfaces:**
- Consumes: `Dsl.short_of`, `Dsl.overnight_of`, `Dsl.compile_ast ?short_cap`, `Engine.Overnight`, `Engine.Tiers`, profile fields `short_initial_ratio`, `default_borrow_rate`, `short_maintenance`.
- Produces: `bt run --borrow-rate PCT`, `bt run --short-maintenance-ratio PCT`, the error `overnight does not take --fill`, and parse validation of `short`/`overnight` in `bt run`, `bt daytrade`, `bt target`, and `bt live`.

- [ ] **Step 1: Write the failing test**

Insert after `test_bars_rebalance_target_routing` (after `test/test_bt.ml:5898`):

```ocaml
let test_short_cli_errors () =
  let binary = locate ["_build/default/bin/bt.exe"; "../bin/bt.exe"] in
  let invoke source command extra expected =
    let stderr_path = Filename.temp_file "bt-test-short-cli-" ".txt" in
    Fun.protect ~finally:(fun () -> Sys.remove stderr_path) (fun () ->
      with_temp_strategy source (fun path ->
        let invocation = String.concat " "
          (Filename.quote binary :: command :: Filename.quote path :: extra
           @ [">/dev/null"; "2>" ^ Filename.quote stderr_path]) in
        let () = assert (Sys.command invocation = 1) in
        assert (read_file stderr_path = expected path ^ "\n")))
  in
  (* Every daily entry point rejects the TW boundary at parse validation. *)
  List.iter
    (fun (command, extra) ->
      invoke "stock \"tw/0050\"\nshort\ntarget -1\n" command extra
        (fun path -> path ^ ": short targets are not supported for tw");
      invoke "stock \"tw/0050\"\novernight\ntarget 1\n" command extra
        (fun path -> path ^ ": overnight is not supported for tw"))
    ["run", ["--capital"; "1"]; "target", []; "live", []];
  (* bt daytrade validates the declarations before any calendar read. *)
  invoke "stock \"us/SPY\"\nbars 5m\nshort\ntarget 1\n" "daytrade"
    ["--capital"; "1"]
    (fun path -> path ^ ": short applies to daily strategies only");
  invoke "stock \"us/SPY\"\nbars 5m\novernight\ntarget 1\n" "daytrade"
    ["--capital"; "1"]
    (fun path -> path ^ ": overnight applies to daily strategies only");
  invoke "stock \"us/SPY\"\novernight\ntarget 1\n" "run"
    ["--fill"; "open"; "--capital"; "1"]
    (fun _ -> "overnight does not take --fill");
  invoke "stock \"us/SPY\"\nshort\nshort\ntarget -1\n" "run" ["--capital"; "1"]
    (fun path -> path ^ ": duplicate short declaration");
  invoke "stock \"us/SPY\"\novernight\novernight\ntarget 1\n" "run"
    ["--capital"; "1"]
    (fun path -> path ^ ": duplicate overnight declaration")
```

Register it after `  let () = test_bars_rebalance_target_routing () in` (`test/test_bt.ml:9558`): `  let () = test_short_cli_errors () in`. Every invocation fails before any cache, calendar, or network read, like `test_bars_run_routing`; `bt daytrade` checks `--capital` before parsing, hence the flag.

- [ ] **Step 2: Run the test to verify it fails**

Run: `dune build 2>&1` then `dune test --force 2>&1`
Expected: the build is clean and the suite fails inside `test_short_cli_errors` (`bt run` on the TW file currently fails later with a missing cache message, so the stderr comparison fails).

- [ ] **Step 3: Usage, record, and flags**

Replace `bin/bt.ml:11-12` (the two usage lines for the margin flags) with:

```ocaml
   \         [--dividend-tax PCT] [--financing-rate PCT] [--maintenance-ratio PCT] [--financing-ratio PCT]\n\
   \         [--loan-term-months N] [--borrow-rate PCT] [--short-maintenance-ratio PCT]\n\
```

Replace `strategy_input` (lines 149-156) with:

```ocaml
type strategy_input = {
  name : string;
  rebalance : bool;
  short : bool;
  overnight : bool;
  stocks : (string option * string * string) list;
  ast : Ast.file;
  declarations : (string * float) list;
  assets : Data.loaded_asset list;
}
```

Replace lines 181-186 (from `  let loan_term_months = ref 18 in` through `  let fill = ref Engine.Close_same in`) with:

```ocaml
  let loan_term_months = ref 18 in
  let borrow_rate = ref None in
  let short_maintenance_ratio = ref None in
  let data_dir = ref "data" in
  let out_dir = ref "out" in
  let out_name = ref None in
  let no_plot = ref false in
  let fill = ref Engine.Close_same in
  let fill_given = ref false in
```

Replace the `--fill` option (lines 195-202) with:

```ocaml
      ("--fill",
       Arg.String
         (fun value ->
           let () = fill_given := true in
           match value with
           | "open" -> fill := Engine.Open_next
           | "close" -> fill := Engine.Close_same
           | _ -> raise (Arg.Bad "--fill must be open or close")),
       "fill mode: open or close (default close)");
```

After the `--loan-term-months` option (lines 230-232) add:

```ocaml
      ("--borrow-rate",
       Arg.Float (fun value -> borrow_rate := Some value),
       "annual short borrow fee percent (default: market profile)");
      ("--short-maintenance-ratio",
       Arg.Float (fun value -> short_maintenance_ratio := Some value),
       "flat short maintenance ratio percent (default: market profile tiers)");
```

- [ ] **Step 4: Parse validation and profile overrides**

Replace `parsed` and the first `all_markets` (lines 270-295) with:

```ocaml
  let parsed =
    List.map2
      (fun path name ->
        let ast = Dsl.parse_file path in
        let rebalance = Dsl.rebalance_of ~filename:path ast in
        let short = Dsl.short_of ~filename:path ast in
        let overnight = Dsl.overnight_of ~filename:path ast in
        let () =
          if List.exists (function Ast.Bars _ -> true | _ -> false) ast then
            failwith "day trading strategies run under bt daytrade"
        in
        let () =
          if overnight && !fill_given then
            failwith "overnight does not take --fill"
        in
        let () =
          if rebalance = None then
            Printf.eprintf
              "warning: %s does not declare rebalance; trading only when the target changes\n"
              path
        in
        let stocks = Dsl.stocks_of ~filename:path ast in
        (name, ast, stocks, Dsl.declared_params_ast ast,
         Option.value rebalance ~default:false, short, overnight))
      strategy_files names
  in
  let all_markets =
    List.concat_map
      (fun (_, _, stocks, _, _, _, _) ->
        List.map (fun (_, market, _) -> market) stocks)
      parsed
  in
```

`Dsl.short_of` and `Dsl.overnight_of` raise the duplicate, `bars`, and TW messages here, before any cache read.

Replace line 308 (`  let profile = Engine.profile_of_market market in`) with:

```ocaml
  let profile = Engine.profile_of_market market in
  let profile =
    match !borrow_rate with
    | Some v -> { profile with Engine.default_borrow_rate = v /. 100. }
    | None -> profile
  in
  let profile =
    match !short_maintenance_ratio with
    | Some v ->
        { profile with
          Engine.short_maintenance =
            Engine.Tiers
              [ { price_below = Float.infinity; per_share = 0.;
                  rate = v /. 100. } ] }
    | None -> profile
  in
```

Replace `inputs` (lines 332-342) with:

```ocaml
  let inputs =
    List.map
      (fun (name, ast, stocks, declarations, rebalance, short, overnight) ->
        let assets =
          List.map
            (fun (_, market, symbol) -> load_cached ~market ~symbol)
            stocks
        in
        { name; stocks; ast; declarations; rebalance; short; overnight; assets })
      parsed
  in
```

- [ ] **Step 5: Compile, run, and report per file**

Replace lines 419-421 (`let strategy = Dsl.compile_ast input.ast ~params ~assets:assets_for_compile in`) with:

```ocaml
        let strategy =
          Dsl.compile_ast
            ?short_cap:
              (if input.short then Some (1. /. profile.Engine.short_initial_ratio)
               else None)
            input.ast ~params ~assets:assets_for_compile
        in
```

Replace the `Engine.run` call (lines 461-467) with:

```ocaml
        let result =
          Engine.run ~dividends
            ~dividend_tax:(!dividend_tax /. 100.)
            engine_assets strategy costs
            ~profile ~margin:margin_config ~capital
            ~fill:(if input.overnight then Engine.Overnight else !fill)
            ~rebalance:input.rebalance
        in
```

The baseline run (lines 490-496) keeps `~fill:!fill`. Replace lines 504-507 (`let output_stem = ...` through `~financing_rate;`) with:

```ocaml
  let output_stem = Report.stem ~names ~out_name:!out_name in
  let run_fill =
    if List.exists (fun input -> input.overnight) inputs then Engine.Overnight
    else !fill
  in
  Report.print_many
    ~columns ~baseline:baseline_result ~fill:run_fill ~stocks
    ~financing_rate;
```

- [ ] **Step 6: Validate in `bt daytrade`, `bt target`, and `bt live`**

In `daytrade` (`bin/bt.ml:576-588`), after `    let () = ignore (Dsl.rebalance_of ~filename:path ast) in` (line 578) insert:

```ocaml
    let () = ignore (Dsl.short_of ~filename:path ast) in
    let () = ignore (Dsl.overnight_of ~filename:path ast) in
```

A `bars` file that declares either statement fails here with the daily-only message, before `Data.read_calendar` (line 595) and before `compile_ast` (line 641), which would otherwise silently ignore the statement.

In `live_command_args`, replace lines 745-749 (from `  let rebalance = Dsl.rebalance_of ~filename:strat_path ast in` through the `in` that closes the `bars` check) with:

```ocaml
  let rebalance = Dsl.rebalance_of ~filename:strat_path ast in
  let short = Dsl.short_of ~filename:strat_path ast in
  let overnight = Dsl.overnight_of ~filename:strat_path ast in
  let () =
    if List.exists (function Ast.Bars _ -> true | _ -> false) ast then
      failwith "day trading strategies run under bt daytrade"
  in
  let () =
    (* Stage 1 ships the backtest only; the live short and overnight paths land in stage 2. *)
    if short || overnight then
      failwith "short and overnight are not supported by bt target and bt live yet"
  in
```

The TW messages come first, from `short_of` and `overnight_of`; a US `short` or `overnight` file then stops before any broker call.

- [ ] **Step 7: Build and run the tests**

Run: `dune build 2>&1` then `dune test --force 2>&1`
Expected: the build prints nothing; the test command exits 0 and its last line is `ok`. Then run `_build/default/bin/bt.exe run -h | grep -c "borrow-rate\|short-maintenance-ratio"` and expect `2`.

- [ ] **Step 8: Commit**

Commit only after the coordinator confirms; use the co-author trailer the coordinator names; never push; never change git settings.

```bash
git add bin/bt.ml test/test_bt.ml
git commit -m "feat: bt run short flags and overnight validation"
```

### Task 7: Docs and changelog

**Files:**
- Modify: `docs/strategy.md:5-30`, `docs/strategy.md:121-170`
- Modify: `docs/engine.md:5-31`, `docs/engine.md:59-62`, `docs/engine.md:66-82`, `docs/engine.md:111-137`, `docs/engine.md:147`
- Modify: `docs/cli.md:50-55`, `docs/cli.md:64-70`, `docs/cli.md:257-266`, `docs/cli.md:656-698`, `docs/cli.md:715-733`
- Modify: `CONTRIBUTING.md:143-144`
- Modify: `CHANGELOG.md:7-12`

**Interfaces:**
- Consumes: the behavior shipped by Tasks 1-6.
- Produces: documentation only.

- [ ] **Step 1: Strategy reference**

In `docs/strategy.md`, in Contents (lines 7-10) insert after `  - [Target exposure](#target-exposure)`:

```markdown
  - [Short targets](#short-targets)
  - [Overnight cycle](#overnight-cycle)
```

After the `### Target exposure` section (after line 30) insert:

````markdown
### Short targets

```
stock "us/QQQ"
short
rebalance daily
target -0.3
```

`short` declares that `target` may be negative. A negative target is a short position: the engine sells the shares at the fill price, keeps the proceeds plus the market profile's collateral as reserved cash, and buys them back when the target rises. Without `short`, a target below 0 floors at 0 and nothing fails. With `short`, a target below `-1 / short_initial_ratio` (-2.0 at the US default) floors there. Longs and shorts fund one book: each long needs its down payment and each short its collateral, and the engine scales every target down when the sum exceeds equity. A long and a short never coexist in one stock; a sign change closes the old leg and opens the new one in the same bar. `short` is US only: a TW file fails with `short targets are not supported for tw`. [engine.md](./engine.md#short-positions) describes the short model.

### Overnight cycle

```
stock "us/QQQ"
short
overnight
rebalance daily
target -0.3
```

`overnight` holds each bar's target from that bar's close to the next bar's open and then exits. Every bar enters at the close and exits at the next open; the exit is forced. A negative target needs `short`; without it the target floors at 0. `rebalance daily` re-enters an unchanged target every bar; `rebalance on_change` still exits at the open but skips the entry while the target is unchanged, which leaves the account flat. `bt run --fill` is rejected for an `overnight` file. `overnight` is US only: a TW file fails with `overnight is not supported for tw`. [engine.md](./engine.md#overnight-cadence) describes the cadence.
````

In the grammar (lines 125-127) add two alternatives after `             | "rebalance" ( "daily" | "on_change" )`:

```markdown
             | "short"
             | "overnight"
```

In Statements (lines 160-168), after the `rebalance` bullet add:

```markdown
- `short` declares that targets may be negative, once per file, in daily strategies only. A TW file cannot declare it. `short` is a reserved word.
- `overnight` holds each bar's target from the close to the next open, once per file, in daily strategies only. A negative target also needs `short`. A TW file cannot declare it. `overnight` is a reserved word.
```

Replace the trips paragraph (line 170) with:

```markdown
Trips are per stock. Entry and exit prices are the exposure-weighted fill VWAPs. A long trip has `net_ret = exit VWAP / entry VWAP - 1`; a short trip opens on the first sale from zero, closes on the cover to zero, and has `net_ret = (entry VWAP - exit VWAP) / entry VWAP`. Trip returns exclude costs, borrow fees, and dividends. They are ex-dividend price returns, so dividend cash moves portfolio equity but not the trip win rate.
```

- [ ] **Step 2: Engine guide**

In `docs/engine.md`, in Contents (lines 7-12) insert after `  - [Equity accounting](#equity-accounting)`:

```markdown
  - [Short positions](#short-positions)
  - [Overnight cadence](#overnight-cadence)
```

and after `    - [Margin financing](#margin-financing)` (line 17) insert:

```markdown
    - [Short selling](#short-selling)
```

Replace the share-quantum table (lines 59-62) with:

```markdown
| Market | Cash inventory | Margin inventory | Short leg |
|---|---|---|---|
| US | Fractional (quantum 0) | Fractional (quantum 0) | Whole shares (quantum 1) |
| Taiwan | Whole shares (quantum 1) | 1000-share lots (quantum 1000) | Not supported |
```

Replace the equity formula block (lines 72-78) with:

````markdown
The engine computes equity as:

```
equity = cash + cash_inventories + margin_inventories + dividend_receivables - short_values - loan_principal - accrued_interest - residual_debt - accrued_borrow
```

After a complete frozen cover-sell-refinance-buy-open sequence, cash is never below zero; any deficit becomes residual debt.
````

Replace the End-of-data close paragraph (line 82) with:

```markdown
At the end of the data, the engine sells every open long inventory and covers every open short at its last close with normal costs. Margin-sale proceeds settle loan principal and accrued interest, with the settlement tail capped at that same last bar; a cover settles its accrued borrow fee. Trip statistics use per-leg VWAP returns.
```

After the End-of-data close section (after line 82) insert:

```markdown
### Short positions

A negative effective target is a short. Each asset carries a nonnegative short value, the cash reserved against it, and its accrued borrow fee beside the long inventories; the sign lives in the target. The profile fields that shape a short are:

| Field | Meaning | US | Taiwan |
|---|---|---|---|
| `short_initial_ratio` | Collateral reserved per unit of proceeds; the position is held at `1 + ratio` times proceeds | 0.5 (Reg T 150%) | n/a |
| `short_maintenance` | Tiers of `price_below`, `per_share`, `rate`, or `Unsupported` | $2.50/share or 100% below $5; $5/share or 30% at $5 and above | `Unsupported` |
| `default_borrow_rate` | Annual borrow fee on the short value, per `interest_day_count` | 0 (easy to borrow); `--borrow-rate` overrides | n/a |
| `short_owes_dividends` | The short pays the cash dividend on the ex-date | true | n/a |
| `short_share_quantum` | Minimum short share increment | 1 (whole shares) | n/a |

Opening a short sells `|target| x equity` at the fill price, floored to whole shares, pays the sell-side charge, and raises cash by the proceeds. Values stay normalized to the starting capital: the share count is `short_value x capital / price`, and every per-share amount (the per-share maintenance floor, a cash dividend) multiplies that count and is divided by `capital` before it enters cash or the requirement, so for USD 1,000 of capital and three shares a USD 1 dividend is `3 x 1 / 1000 = 0.003` engine units. The planner reserves `(1 + short_initial_ratio) x proceeds` of cash, so the proceeds cannot buy longs and the collateral comes from equity: the own-equity cost of a short is `short_initial_ratio x |target|`, which the effective-target scaling adds to the long down payments in one joint need. A short open that would need more collateral than the available cash is cut to what fits and counts as a funding clamp. The leverage test for the long leg uses the sum of the positive targets only, so long 1.5 with short -0.5 is financed as a levered book.

Covering buys back at the fill price, pays the buy-side charge, releases the reserve in proportion, and settles the same share of the accrued borrow fee. Within one bar the planner covers before the long sells and opens after the long buys, so a sign flip closes the old leg (its fill row ends at 0) before the new leg opens from 0.

Between bars a short is marked to the price and accrues `short_value x borrow_rate x days / interest_day_count` per calendar night as a liability. On an ex-date it pays `shares x cash_per_share / capital` from cash with no withholding, where the long receipt is booked. The maintenance requirement adds, per short, `max(per_share x shares / capital, rate x short_value)` from the tier whose `price_below` is strictly above the mark price; `--short-maintenance-ratio PCT` replaces the tiers with one flat rate. The close check and the next-open cure also run for a loan-free short book. A breach cures longs first, then shorts by the smallest whole-share cover that restores the requirement. Bankruptcy covers every short. The margin line in the report appears whenever the book had a loan or a short on some bar.

### Overnight cadence

`overnight` runs a third cadence beside `--fill close` and `--fill open`, which are unchanged. On each bar after the first: at the open, the engine marks the overnight position, books ex-date dividends on it (a long receives, a short pays), runs the solvency guard, and if solvent exits every asset to 0 at the open price with normal costs; a call pending from the previous close is dropped, since the exit covers it. At the close the engine enters the bar's effective target at the close price, unless the account went bankrupt at the open. Interest and borrow accrue for the calendar nights between consecutive bars; the last bar accrues nothing because the end-of-data close liquidates at its close.

The exit never updates the previous-target memory, so `rebalance on_change` compares each close against the last close entry: an unchanged target exits at the open and places no entry. The equity curve keeps one point per bar at the close. The fill log keeps its five columns: a bar has up to two rows per asset, the exit row at the open price first (ending at 0), then the entry row at the close price; a skipped entry writes nothing; the end-of-data close writes its row after the last entry. The close entry of a date is the row for that symbol and date whose `to_exposure` is nonzero.
```

In the US market section, after `#### Margin financing` (which ends at line 131) and before `#### Dividends` (line 133) insert:

```markdown
#### Short selling

A US file may declare `short`. The profile reserves 150% of the proceeds (Reg T), charges no borrow fee by default (`--borrow-rate PCT` sets one), floors shorts to whole shares, makes the short pay dividends on the ex-date, and applies the per-share-or-rate maintenance table above ($2.50/share or 100% below $5, $5/share or 30% at $5 and above; `--short-maintenance-ratio PCT` flattens it). Leveraged-ETF short requirements and hard-to-borrow locates are not modeled. See [Short positions](#short-positions).
```

In the US Gaps between simulation and the real market section, replace line 147 (`- The engine does not auto-classify leveraged-ETF house requirements (2x 50%, 3x 75%) or short tiers. Use \`--maintenance-ratio\` to set the correct rate.`) with:

```markdown
- The engine does not auto-classify leveraged-ETF house requirements (2x 50%, 3x 75%) on either side. Use `--maintenance-ratio` to set the long rate and `--short-maintenance-ratio` to set the short rate; without the override, shorts use the per-share-or-rate table in [Short selling](#short-selling).
```

Replace the US Dividends paragraph (line 137) with:

```markdown
A US dividend becomes cash on its ex-date, with no receivable period. When dividend cash arrives, the engine runs one normal cost-bearing fill pass toward the current targets. A short pays the dividend from cash on the ex-date; a payment does not trigger a fill pass.
```

- [ ] **Step 3: CLI reference**

In `docs/cli.md`, Command syntax (lines 64-70): replace line 69 with:

```text
       [--financing-ratio PERCENT] [--loan-term-months N] [--dividend-tax PERCENT]
       [--borrow-rate PERCENT] [--short-maintenance-ratio PERCENT]
```

In the Strategy validation table (lines 261-266) add two rows after the `--provisional-close` row:

```markdown
| `<file>: short targets are not supported for tw`, `<file>: overnight is not supported for tw` | A TW strategy that declares `short` or `overnight` fails at parse validation, exit 1, before any broker call. The same messages apply to `bt run`. |
| `short and overnight are not supported by bt target and bt live yet` | A US strategy that declares `short` or `overnight` fails before any broker call; live support is a later stage. |
```

In the Run arguments table (lines 658-682): replace the `--fill` row with:

```markdown
| `--fill open\|close` | `close` | Select the fill mode. A strategy that declares `overnight` sets its own cadence; passing `--fill` with such a file fails with `overnight does not take --fill`. |
```

and after the `--loan-term-months N` row add:

```markdown
| `--borrow-rate PERCENT` | US 0 | Set the annual short borrow fee as a percent of the short value, accrued per calendar day over the market's day count. |
| `--short-maintenance-ratio PERCENT` | US per-share-or-rate table | Set a flat short maintenance requirement as a percent of the short value, replacing the tiered table ($2.50/share or 100% below $5, $5/share or 30% at $5 and above). |
```

Replace the note at lines 684-685 with:

```markdown
> [!NOTE]
> The four margin options, the two short options, and `--dividend-tax` apply to every strategy and the baseline. US assets ignore `--loan-term-months`; TW assets ignore the short options because TW files cannot declare `short`.
```

Replace the share-quantum paragraph (line 691, `The engine floors Taiwan cash quantities to whole shares ...`) with:

```markdown
The engine floors Taiwan cash quantities to whole shares and Taiwan margin quantities to 1000-share lots; the floored remainder stays in cash. US long quantities stay fractional; US short quantities are whole shares. See [Share quantum](./engine.md#share-quantum) and [Short positions](./engine.md#short-positions).
```

After the `--baseline` paragraph (line 698) add:

```markdown
`bt run` fails with `<file>: duplicate short declaration`, `<file>: short applies to daily strategies only`, `<file>: duplicate overnight declaration`, `<file>: overnight applies to daily strategies only`, `<file>: short targets are not supported for tw`, or `<file>: overnight is not supported for tw` at parse validation, before any cache read. See [strategy.md](./strategy.md#short-targets).
```

In Fill modes, after the `--fill open` paragraph (line 719) add:

```markdown
A strategy that declares `overnight` enters its target at each bar's close and exits it at the next bar's open, without `--fill`. The report line prints `fill: overnight` when any strategy in the run declares it; the other strategies and the baseline keep the `--fill` cadence. See [Overnight cadence](./engine.md#overnight-cadence).
```

Replace the last Fill modes paragraph (line 721) with:

```markdown
The engine closes a final open exposure, long or short, at the last close in every mode. It applies the fee, sell tax, and slippage to a long close and the fee and slippage to a cover.
```

In Run outputs, replace line 733 (`A strategy that never had a loan has no margin line.`) with:

```markdown
A strategy that never had a loan or a short has no margin line. Under `overnight` the fill log has up to two rows per stock per date: the exit at the open price, ending at `to_exposure` 0, then the entry at the close price.
```

- [ ] **Step 4: Contributing contracts**

In `CONTRIBUTING.md`, replace lines 143-144 (the fill modes and margin accounting bullets) with:

```markdown
- Engine fill modes: `Close_same` fills at the decision close. `Open_next` fills at the next open. `Overnight` enters at the decision close and exits at the next open.
- Margin accounting keeps separate cash and margin inventories for each asset, plus a nonnegative short leg (short value, reserved cash, accrued borrow) whose sign lives in the target. Equity subtracts short values, loans, accrued interest, accrued borrow, and residual debt.
```

- [ ] **Step 5: Changelog**

In `CHANGELOG.md`, under `## [Unreleased]` / `### Added` (line 11), add after the `bt --version` entry:

```markdown
- Short positions in the backtest. A daily US file declares `short` to allow negative targets, floored at `-1 / short_initial_ratio` (-2.0). The engine carries a separate short leg per asset: proceeds plus Reg T collateral (`(1 + 0.5) x proceeds`) are reserved cash, longs and shorts scale jointly by down payment and collateral, shorts are whole shares, a borrow fee accrues per calendar day (`--borrow-rate PCT`, default 0), the short pays dividends on the ex-date, and maintenance uses Alpaca's per-share-or-rate table (`--short-maintenance-ratio PCT` flattens it). A loan-free short book records calls and cures by buy-to-cover; bankruptcy and the end-of-data close cover every short. Short trips carry `(entry - exit) / entry`. `Engine.plan_state` and `Engine.planned_asset` gain short fields; `Engine.market_profile` gains the five short fields. TW files reject `short` with `short targets are not supported for tw`.
- The overnight cycle. A daily US file declares `overnight` to enter each bar's target at the close and exit at the next open under a third `Engine.fill` mode, `Overnight`; `rebalance on_change` exits without re-entering an unchanged target. `bt run --fill` with such a file fails with `overnight does not take --fill`; the report prints `fill: overnight`. TW files reject it with `overnight is not supported for tw`; `bt target` and `bt live` reject `short` and `overnight` files until live support lands.
```

- [ ] **Step 6: Check the docs**

Run: `grep -c "short-positions\|overnight-cadence" docs/engine.md docs/strategy.md docs/cli.md; grep -nP "[^\x00-\x7F]" docs/strategy.md docs/engine.md docs/cli.md CHANGELOG.md CONTRIBUTING.md | wc -l`
Expected: engine.md at least 4, strategy.md at least 2, cli.md at least 1; the non-ASCII count is `0` (it is 0 at the base commit). Then `dune build 2>&1` prints nothing and `dune test --force 2>&1` exits 0 with `ok` as its last line.

- [ ] **Step 7: Commit**

Commit only after the coordinator confirms; use the co-author trailer the coordinator names; never push; never change git settings.

```bash
git add docs/strategy.md docs/engine.md docs/cli.md CONTRIBUTING.md CHANGELOG.md
git commit -m "docs: short positions and the overnight cycle"
```

## Self-review

### Spec coverage

| Spec section | Task |
| --- | --- |
| Market profile: five fields, US defaults, TW `Unsupported` | Task 1 |
| Market profile: `--borrow-rate`, `--short-maintenance-ratio` | Task 6 (profile overrides; see Spec readings for why not `Engine.margin`) |
| DSL: `short` (duplicate, daily only), target floor at `-short_cap` / 0 with no upper cap in the DSL, joint need in `effective_targets` | Tasks 1 and 2; `short_cap` wired in Task 6 |
| DSL: `overnight` (duplicate, daily only), `--fill` rejection, `rebalance` semantics | Tasks 2, 5, 6 |
| DSL: `short_of`, `overnight_of` shaped like `rebalance_of`; `Dsl.compile` validates both and derives `short_cap` from the file's market | Task 2 |
| Engine inventory: short arrays, equity identity, `total_value = long - short`, reserved cash, no coexistence | Task 3 |
| Planning: short-leg trade, open/add with reserve and sell charge (none for a zero open), cover with buy charge and proportional release, `available` minus reserved, positive-only leverage test, `plan_short_open`/`plan_short_cover`, whole-share floor on the short leg only with the E1 cycle resolved to the lower open, long-only path guarded by `short_active` | Task 3 |
| Carried shorts: borrow per calendar day, ex-date payment, tiered maintenance with per-share floor, gates for loan-free short books, cure by cover, bankruptcy guard, trips with sign, end-of-run cover | Tasks 3 and 4 |
| Overnight cadence: open step (scale, dividends, solvency, forced exit without `prev_eff`), close entry, accrual, one equity point, two fill rows | Task 5 |
| Errors: duplicate/daily-only messages (also through `bt daytrade`), `overnight does not take --fill`, TW messages in `bt run`, `bt target`, `bt live` | Tasks 2 and 6 |
| Test 1 Opt-in clamp | Tasks 1 and 2 |
| Test 2 Joint scaling | Tasks 1 and 3 (`test_short_joint_scaling`) |
| Test 3 Short leg (open, reserve, available through `plan_fills` and through `Engine.run`, add, reduce, cover, flip, zero-open fee, whole-share cycle, equity identity with existing tests untouched) | Task 3 |
| Test 4 Whole shares | Task 3 |
| Test 5 Carried short | Task 4 |
| Test 6 Overnight cadence (`--fill` rejection in Task 6; `Intraday.run` rejection in Task 5) | Tasks 5 and 6 |
| Test 7 Byte gates | Coordinator after Tasks 3-6; commands in Global Constraints; verified identical on the prototype |
| Test 8 DSL errors incl. TW boundary in run, target, live and the daily-only boundary in daytrade | Tasks 2 and 6 |
| Docs: strategy.md, engine.md, cli.md, CHANGELOG entries for the backtest short model and the overnight cycle | Task 7 (`docs/specs/live-trading.md` and the live changelog entry are stage 2) |

Gaps: none in stage 1 scope. `legs_of_plan` (TW) needs no change because its plan never carries a short (TW rejects at parse time and `effective_targets` clamps negatives for `Unsupported`).

### Placeholder scan

No "TBD", "TODO", "implement later", "similar to Task N", or code-free code steps. Every modified function is shown in full or by an exact replacement window with base-commit line numbers. The one scaffold-like line (the stage 1 guard in `live_command_args`) is a shipped behavior documented in `docs/cli.md` and the changelog, and stage 2 removes it.

### Type consistency

- `short_tier`, `short_maintenance`, `Tiers`, `Unsupported` (Task 1) are the names used by `short_requirement_rate` (Task 4), `profile_of_market` (Task 1), the `--short-maintenance-ratio` override (Task 6), and `test_carried_short` (Task 4).
- `plan_state.short_values`, `short_reserved`, `short_borrow` (Task 3) match `apply_fills`'s record (Task 3), `us_plan_state` and the TW state (Task 3), and every test literal.
- `planned_asset.plan_short_open`, `plan_short_cover`, `plan_short_final`, `plan_short_cost`, `plan_short_borrow`, `plan_short_from_e`, `plan_short_to_e` (Task 3) are the names read by `apply_fills`, `projected_cash`, and the Task 3 tests.
- `effective_targets ?short_ratio` (Task 1) is called with `?short_ratio` by `run` (Task 3) and positionally by `broker/live.ml:642`, which is unchanged.
- `apply_fills ?(remember = true)` (Task 5) is called with `~remember:false` only by the `Overnight` arm.
- `cover_short index ~date ~price ~remaining` (Task 3) is called by `bankrupt_all` and the end-of-run fold (Task 3) and by `cure_shorts` (Task 4).
- `compile_ast ?extra ?short_cap` (Task 2) is called with `?short_cap:(... option)` by `bt run` (Task 6) and by `Dsl.compile` (Task 2), and with `~short_cap:2.` by `test_short_opt_in_clamp`.
- `Engine.Overnight` (Task 5) is produced by `bt run` (Task 6) and matched in `report.ml` and `intraday.ml` (Task 5).

### Offline verification

Every code block in Tasks 1-6 was applied to a scratch copy of the worktree at `46d7810` and built with the project switch (`dune build --root .`, zero warnings). The full existing suite plus the eleven new tests (`test_short_effective_targets`, `test_short_declaration`, `test_short_opt_in_clamp`, `test_short_joint_scaling`, `test_short_leg_plan`, `test_short_reserved_cash_run`, `test_engine_short_leg_run`, `test_short_whole_shares`, `test_carried_short`, `test_overnight_cadence`, `test_short_cli_errors`) and the extended `test_profile_of_market` and `test_intraday_normalization` passed (`dune test --root . --force` exited 0 and printed `ok`). The six byte gates were rerun on that build with the commands in Global Constraints and compared with `cmp` against the pinned baselines: all six identical. The review round 1 revisions (the `short_active` guard, the zero-open charge, the short-aware E1 cycle, the `Intraday.run` boundary check, the `bt daytrade` validation, and the reserved-cash run) and the round 2 revision (`Dsl.compile` validation and market-derived `short_cap`, with its nine file-based assertions) were applied to the same scratch copy and verified the same way: the cycle case at target -0.5025 resolves to 49 shares, the zero-open case plans a zero total cost with the clamp set, and the two-bar reserved-cash run enters the long at 0.75. Every expected value in the test derivation comments was confirmed against that build. The Task 7 markdown was not rendered or built.
