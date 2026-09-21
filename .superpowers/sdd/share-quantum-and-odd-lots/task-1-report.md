# Task 1 Report: Mandatory Capital

## RED

Command:

```sh
opam exec --switch=/sandbox/stock -- dune runtest --root . --force
```

Exit code: `1`

Output:

```text
File "test/test_bt.ml", line 5127, characters 50-52:
5127 |     Engine.plan_fills ~costs:[| costs |] ~capital:1.
                                                         ^^
Error: The constant 1. has type float but an expression was expected of type
         float option
```

This was the expected failure: the new engine test supplied mandatory float capital while the pre-change engine still required `float option`. The same RED patch added the `bt run` and `bt daytrade` missing-capital CLI assertions.

## GREEN

Command:

```sh
opam exec --switch=/sandbox/stock -- dune runtest --root . --force
```

Exit code: `0`

Output summary:

```text
(cd _build/default/test && ./test_bt.exe)
ok
```

The suite also emitted its existing fixture-error and unavailable-matplotlib warnings; they did not fail the suite.

## Cost sentinels

### `test_engine_buyhold_costs`

The old effective pinned value was `1.0782178217821783`, derived by the test expression:

```text
entry equity = 1 / 1.01
final equity = (1 / 1.01) * 1.1 * 0.99
             = 1.0782178217821783
```

With mandatory `~capital:1.`, the new pinned value remains `1.0782178217821783`. This fixture has `min_fee = 0.` and `per_share_sell_fee = 0.`, so supplying capital does not change its cost sequence. The test now pins the literal value and retains the derivation comment.

### Mandatory-capital TW planner sentinel

For an unsolved TWD 1,000,000 buy, 3.99 bps is:

```text
1,000,000 * 3.99 / 10,000 = 399
max(399, 20) = 399
```

`Engine.charge` is asserted directly at `399.`. The brief's requested planner value of `399.` omitted the planner's existing fixed-point equity solve. The planner correctly pins:

```text
399 / (1 + 0.000399) = 398.84086249586414
```

This correction was confirmed by the coordinator so the established cost identity and US byte reference remain unchanged.

## US reference capture

Reference source commit:

```text
4289c001b4581a8269916f9d395dcbf2f6ce8281
```

The source tree was created without stashing by extracting `git archive HEAD` into `/tmp/stock-task1-base.ItnHRi` and building it with the required opam switch.

Exact reference command:

```sh
/tmp/stock-task1-base.ItnHRi/_build/default/bin/bt.exe run /sandbox/research/strategies/us/dd_ladder/main.strat --baseline us/TQQQ --capital 100000 --data-dir /sandbox/stock/data --out-dir /sandbox/stock-tw-live/.superpowers/sdd/share-quantum-and-odd-lots/us-baseline --out-name fp --no-plot
```

TQQQ cache last row:

```text
2026-09-02,68.969,69.7599,68.3899,69.6,38887353
```

Saved under `.superpowers/sdd/share-quantum-and-odd-lots/us-baseline/`:

- `stdout.txt`
- `fp.csv`
- `main.trades.csv`
- `provenance.json`

Reference stdout:

```text
Metric           |         main |     baseline
----------------------------------------------
Total return     |  12332.07% L |    33781.29%
CAGR             |     33.82% L |       42.17%
Sharpe           |      0.837 L |        0.886
MaxDD            |     74.85% W |       81.65%
Calmar           |      0.452 L |        0.516
main: us/TQQQ - trades 1 (win rate 100.00%);
Date range: 2010-02-11 to 2026-09-02; fill: close
```

## Final gates

### Build

```sh
opam exec --switch=/sandbox/stock -- dune build --root /sandbox/stock-tw-live
```

Exit code: `0`; no output.

### Full suite

```sh
opam exec --switch=/sandbox/stock -- dune runtest --root /sandbox/stock-tw-live --force
```

Exit code: `0`; `test_bt.exe` printed `ok`.

### US byte identity

Current command:

```sh
/sandbox/stock-tw-live/_build/default/bin/bt.exe run /sandbox/research/strategies/us/dd_ladder/main.strat --baseline us/TQQQ --capital 100000 --data-dir /sandbox/stock/data --out-dir /tmp/stock-task1-current.fApBsY --out-name fp --no-plot
```

Byte comparisons:

```text
cmp us-baseline/stdout.txt current/stdout.txt       exit 0
cmp us-baseline/fp.csv current/fp.csv               exit 0
cmp us-baseline/main.trades.csv current/main.trades.csv exit 0
```

All three current outputs are byte-identical to the base reference.

## Commit

```text
e283e8cc58a05190b50991ca71475a8d8f565e02
feat: require --capital for bt run and bt daytrade

Co-authored-by: ChatGPT <noreply@openai.com>
```

## Fix round 1

### Build

```sh
opam exec --switch=/sandbox/stock -- dune build --root /sandbox/stock-tw-live
```

Exit code: `0`; no output.

### Full suite

```sh
opam exec --switch=/sandbox/stock -- dune runtest --root /sandbox/stock-tw-live --force
```

Exit code: `0`; output included:

```text
(cd _build/default/test && ./test_bt.exe)
ok
```

The suite also emitted its existing fixture, unavailable-matplotlib, and
localhost-curl warnings; they did not fail the suite.

### US byte identity

```sh
/sandbox/stock-tw-live/_build/default/bin/bt.exe run /sandbox/research/strategies/us/dd_ladder/main.strat --baseline us/TQQQ --capital 100000 --data-dir /sandbox/stock/data --out-dir /tmp/stock-task1-current-round1 --out-name fp --no-plot > /tmp/stock-task1-current-round1/stdout.txt
```

Exit code: `0`; no output.

Byte comparisons:

```text
cmp us-baseline/stdout.txt current-round1/stdout.txt             exit 0
cmp us-baseline/fp.csv current-round1/fp.csv                     exit 0
cmp us-baseline/main.trades.csv current-round1/main.trades.csv   exit 0
```

All three current outputs are byte-identical to the base reference.
