# Task 2 report: decision core and `bt target`

## Plan amendments

- `Alpaca.snapshot_t` now includes `day_date` and `prev_day_date`, parsed as the `YYYY-MM-DD` prefixes of `dailyBar.t` and `prevDailyBar.t`.
- `Live.provisional_bar` uses `snapshot.day_date`; cache freshness in `Live.decide` compares the Tiingo tail with `snapshot.prev_day_date`. This avoids local-clock and holiday assumptions.

## RED

Command: `opam exec -- dune runtest --force`

First failure for the snapshot date amendment:

```text
File "test/test_bt.ml", line 4301, characters 6-14:
4301 |     { day_date = "2022-08-16";
             ^^^^^^^^
Error: This record expression is expected to have type Alpaca.snapshot_t
       There is no field day_date within type Alpaca.snapshot_t
```

After the minimal snapshot extension, the planned decision-core failure was:

```text
File "test/test_bt.ml", line 4312, characters 10-14:
4312 |   assert (Live.desired_shares ~target:1.994 ~equity:10000. ~price:500. = 39);
                 ^^^^
Error: Unbound module Live
```

After adding the decision core but before wiring the subcommand, the CLI test failed because stderr did not contain `live trading supports us only`.

## GREEN

Command: `opam exec -- dune runtest --force`

```text
(cd _build/default/test && ./test_bt.exe)
ok
Wall time: 0.59 seconds
```

The existing expected data warnings were unchanged.

CLI smoke: `_build/default/bin/bt.exe target /sandbox/research/strategies/tw/channel_ladder/main.strat` exited 2 and printed `live trading supports us only` followed by usage.

## TW byte-identity gate

Ran:

```text
_build/default/bin/bt.exe run /sandbox/research/strategies/tw/channel_ladder/main.strat --baseline tw/00685L --data-dir data --out-dir /tmp/live-task2-gate.RTTGCb --out-name fp --no-plot
```

`diff -r /tmp/live-ref /tmp/live-task2-gate.RTTGCb` and `diff /tmp/live-ref.txt /tmp/live-task2-output.txt` both exited 0 with no output.

## Review fix: shared target normalization

RED command: `opam exec -- dune runtest --force`

```text
File "test/test_bt.ml", line 4314, characters 36-66:
4314 |     (Engine.profile_of_market "us").Engine.default_financing_ratio
                                           ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
Error: Unbound record field Engine.default_financing_ratio
Hint:          Did you mean Engine.default_financing_rate?
```

GREEN command: `opam exec -- dune runtest --force`

```text
(cd _build/default/test && ./test_bt.exe)
ok
Wall time: 1.02 seconds
```

The normalization test covers negative and NaN targets mapping to zero, the
single-asset 0.5 financing-ratio cap mapping 2.5 to 2.0, and the in-range
target 1.994 remaining unchanged.

TW byte-identity gate:

```text
_build/default/bin/bt.exe run /sandbox/research/strategies/tw/channel_ladder/main.strat --baseline tw/00685L --data-dir data --out-dir /tmp/live-task2-fix-gate.lnoJjK --out-name fp --no-plot
```

`diff -r /tmp/live-ref /tmp/live-task2-fix-gate.lnoJjK` and
`diff /tmp/live-ref.txt /tmp/live-task2-fix-output.txt` both exited 0 with no
output.
