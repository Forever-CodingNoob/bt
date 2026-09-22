# Task 2 Report: Engine Share Quantum

## RED

Command:

```sh
opam exec --switch=/sandbox/stock -- dune runtest --root /sandbox/stock-tw-live --force
```

Exit code: `1`

Output:

```text
File "test/test_bt.ml", line 5092, characters 4-72:
5092 |     Engine.plan_fills ~costs:[| zero_costs |] ~capital:1000000. ~profile
           ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
Error: The function Engine.plan_fills has type
         costs:Engine.costs array ->
         capital:float ->
         financing_ratios:float array ->
         state:Engine.plan_state ->
         prices:float array ->
         targets:float array -> force:bool -> Engine.fill_plan
       It is applied to too many arguments
File "test/test_bt.ml", line 5092, characters 65-72:
5092 |     Engine.plan_fills ~costs:[| zero_costs |] ~capital:1000000. ~profile
                                                                        ^^^^^^^
  This extra argument is not expected.
```

This was the expected RED failure: the test supplied the required market profile before `Engine.plan_fills` accepted it.

## GREEN

Command:

```sh
opam exec --switch=/sandbox/stock -- dune runtest --root /sandbox/stock-tw-live --force
```

Exit code: `0`

Output summary:

```text
(cd _build/default/test && ./test_bt.exe)
ok
```

The suite also emitted its existing invalid-fixture, unavailable-matplotlib, localhost-curl, and missing-cache warnings; none failed the suite.

`Engine.market_profile` now carries `cash_share_quantum` and `margin_share_quantum`. TW uses `1.` and `1000.`; US uses `0.` and `0.`. `Engine.plan_fills` receives the profile, defines `floor_value` once, and applies it to margin sells, cash sells, cash buys, margin buys, cash-inventory refinance values, and margin-inventory refinance values. Buy down payments use the floored cash and margin values so the remainder stays in cash. `Engine.run` and the TW live planner pass the profile through.

The direct planner checks establish:

- TW cash at TWD 10: `floor(1 * 1,000,000 / 10) = 100,000` shares and normalized value `1.`.
- TW cash at TWD 11: `floor(1 * 1,000,000 / 11) = 90,909` shares and normalized value `0.999999`.
- TW margin at TWD 11: `floor(1 * 1,000,000 / 11 / 1,000) * 1,000 = 90,000` shares and normalized value `0.99`.
- US quantum zero preserves the corresponding pre-change fractional cash and margin values of `1.`.

### Fixed-point refinance derivation

The existing TWD scale-in fixture is intentionally asserted by share count because flooring makes the planner's fixed-point solve discontinuous. The largest fundable raw trade is `229999.99999999997`. Therefore:

```text
floor(229999.99999999997 / 10 / 1000) * 1000 = 22000 margin shares
raw minimum = 0.4 * 230000 = 92000
requested refinance value = 92000 / 0.6 = 153333.333...
floor(153333.333... / 10 / 1000) * 1000 = 15000 refinance shares
released cash = 15000 * 10 * 0.6 = 90000
down payment = 22000 * 10 * 0.4 = 88000
```

Both refinance sides use the same floored TWD 150,000 value, so each side is exactly 15 lots.

## Gates

### Build

Command:

```sh
opam exec --switch=/sandbox/stock -- dune build --root /sandbox/stock-tw-live
```

Exit code: `0`; no output.

### Full suite

Command:

```sh
opam exec --switch=/sandbox/stock -- dune runtest --root /sandbox/stock-tw-live --force
```

Exit code: `0`; `test_bt.exe` printed `ok`.

### LSP diagnostics

Per-file diagnostics for `engine/engine.ml`, `engine/engine.mli`, `broker/live.ml`, and `test/test_bt.ml` all returned `OK`.

### US byte identity

Current command:

```sh
/sandbox/stock-tw-live/_build/default/bin/bt.exe run /sandbox/research/strategies/us/dd_ladder/main.strat --baseline us/TQQQ --capital 100000 --data-dir /sandbox/stock/data --out-dir /tmp/stock-task2-us.jIS0QF --out-name fp --no-plot
```

Comparisons:

```text
cmp us-baseline/stdout.txt current/stdout.txt             exit 0
cmp us-baseline/fp.csv current/fp.csv                     exit 0
cmp us-baseline/main.trades.csv current/main.trades.csv   exit 0
git diff --exit-code -- us-baseline                      exit 0
```

The current US stdout, equity CSV, and trade CSV are byte-identical to the Task 1 reference, and the stored US baseline including `provenance.json` is unchanged.

## TW Reference Capture

Exact command:

```sh
/sandbox/stock-tw-live/_build/default/bin/bt.exe run /sandbox/research/strategies/tw/channel_ladder/main.strat --baseline tw/00685L --capital 1000000 --data-dir /sandbox/stock/data --out-dir /sandbox/stock-tw-live/.superpowers/sdd/share-quantum-and-odd-lots/tw-baseline --out-name fp --no-plot
```

Exit code: `0`.

```text
Metric           |         main |     baseline
----------------------------------------------
Total return     |   7288.06% W |     2793.18%
CAGR             |     57.53% W |       42.68%
Sharpe           |      1.448 W |        1.146
MaxDD            |     34.80% W |       54.81%
Calmar           |      1.653 W |        0.779
main: tw/00685L - trades 6 (win rate 83.33%);
main: margin - financing 6.35%/yr, min maintenance 0.00%, margin calls 6, refinances 39, clamps 11
Date range: 2017-03-30 to 2026-09-17; fill: close
```

Saved under `.superpowers/sdd/share-quantum-and-odd-lots/tw-baseline/`:

- `stdout.txt`
- `fp.csv`
- `main.trades.csv`
- `provenance.json`

The provenance records base commit `3a425eb549c3723cefbf9c24bae03e20ec31e3f7`, the exact command, and cache last row `2026-09-17,11.91,12.22,11.91,11.98,248983442`.

### First-fill hand-check

The first trade row is:

```text
2017-05-25,tw/00685L,0.43708333333333332,0,1.845
```

With zero starting exposure and a 1.845 target, the fee fixed point is:

```text
rate = 1.845 * 3.99 / 10000 = 0.000736155
equity after fee = 1 / (1 + rate) = 0.9992643865255373
raw trade value = 1.845 * equity * 1,000,000 = TWD 1,843,642.7931396162
```

The cash portion before flooring is TWD `436345.448782818`. Its whole-share quantity and floored value are:

```text
floor(436345.448782818 / 0.43708333333333332) = 998311 shares
998311 * 0.43708333333333332 = TWD 436345.0995833333
```

The remaining margin portion before flooring is TWD `1407297.6935562829`. Its lot-floor quantity and value are:

```text
floor(1407297.6935562829 / 0.43708333333333332 / 1000) * 1000
  = 3219000 shares
3219000 * 0.43708333333333332 = TWD 1406971.25
```

The commission is above the minimum:

```text
max(1843642.7931396162 * 3.99 / 10000, 20)
  = max(735.613474462707, 20)
  = TWD 735.613474462707
```

Thus the first equity row is `1 - 735.613474462707 / 1,000,000 = 0.9992643865255373`, matching `fp.csv` (`0.9992643865255374` after CSV formatting).
