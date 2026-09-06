# Task 1: minute-bar data layer

## Contents

- [Scope and plan amendment](#scope-and-plan-amendment)
- [RED evidence](#red-evidence)
- [GREEN evidence](#green-evidence)
- [Gates](#gates)
- [Remaining verification](#remaining-verification)
- [Task 1 review fixes](#task-1-review-fixes)
  - [Inherited edits and disposition](#inherited-edits-and-disposition)
  - [Review RED and GREEN evidence](#review-red-and-green-evidence)
  - [Offline persistence and lookup smokes](#offline-persistence-and-lookup-smokes)
  - [Review gates](#review-gates)

## Scope and plan amendment

Implemented additive minute-bar year caches, sorted calendar merging, pure US DST offsets, session-open-anchored OHLCV resampling, Alpaca calendar/page parsers and paginated SIP bars fetching, and a new guarded `fetch --bars` dispatch arm. Existing daily fetch functions, daily dispatch arm, engine code, and existing interface exports were not edited. Cache writes use same-directory temporary files and atomic rename; fetched rows replace matching timestamps without discarding retained history.

Coordinator-approved amendment: `Alpaca.bars` takes `sessions:Data.session array` in addition to the planned symbol/start/end arguments. The CLI refreshes and writes the full calendar, reads it back, and passes those sessions to `bars`. The bars function never makes a hidden calendar request. Added `parse_bars` and `parse_calendar` exports support offline fixture tests using the same production parsers.

All work and commands ran in `/sandbox/stock-daytrading`; `/sandbox/stock/data` was read only for the daily gate. No subagents, network calls, pushes, Git settings changes, or author overrides were used. CLI/engine/strategy documentation and changelog entries remain assigned to Task 4, as specified by the plan.

## RED evidence

Before adding production functions, wrote fixture-backed assertions for DST boundaries, calendar merge/round trip, minute cache round trip across a year boundary, date and minute bounds, 5-minute OHLCV aggregation, early-close bucket retention, 1-minute identity, Alpaca fixture parsing, UTC-to-ET conversion, session filtering, and invalid parser/resampling input.

Command: `opam exec -- dune runtest --force`

Exit: 1.

```text
File "test/test_bt.ml", line 4550, characters 45-67:
4550 |     List.iter (fun (date, offset) -> assert (Data.et_offset_minutes date = offset))
                                                    ^^^^^^^^^^^^^^^^^^^^^^
Error: Unbound value Data.et_offset_minutes
```

The hand-written minute fixture has twelve regular-session rows and three rows immediately preceding a 13:00 early close. Literal OHLCV expectations and derivation comments are in `test_minute_data`.

## GREEN evidence

The initial implementation run found a page-token serialization bug: `Failure("invalid Alpaca page token response")`. Inspecting jq output showed that TSV did not escape JSON quote characters as assumed. The parser now emits JSON token text without TSV re-escaping and decodes that JSON directly through jq; null and nonempty token assertions both pass.

Final command: `opam exec -- dune runtest --force`

Exit: 0; stdout: `ok`.

Expected stderr includes the deliberately malformed timestamp fixture's jq error, existing missing corporate-action/cache warnings, and the existing unknown TW financing-ratio warning. Dune also reports that it cannot inspect `/` while searching parent directories; this is an environment root-discovery warning, not a compiler warning.

## Gates

| Gate | Result |
| --- | --- |
| `opam exec -- dune build` | Exit 0, no compiler errors or warnings; only the environment root-discovery warning |
| `opam exec -- dune runtest --force` | Exit 0, `ok` |
| Daily run exit | 0, empty stderr |
| Daily stdout against `/tmp/dt-ref.txt` | Byte-identical |
| Daily output filename set against `/tmp/dt-ref` | Identical |
| `fp.csv` against reference | Byte-identical |
| `main.trades.csv` against reference | Byte-identical |
| Offline CLI: `bt fetch us/SPY --bars 5m` | Exit 2, `fetch --bars supports 1m only`, before any network request |

Daily command:

```sh
_build/default/bin/bt.exe run /sandbox/research/strategies/tw/channel_ladder/main.strat --baseline tw/00685L --data-dir /sandbox/stock/data --out-dir /tmp/dt-task1-s65lfpve --out-name fp --no-plot
```

The gate captured subprocess stdout as bytes and compared it directly with `/tmp/dt-ref.txt`; it compared the complete filename sets and every output file's bytes with `/tmp/dt-ref`.

## Remaining verification

Live fetch, pagination over real pages, and broker/network failure behavior are intentionally unexercised: Task 1 forbids network calls, and Task 4 owns the blessed-binary network smoke. Production page parsing, calendar filtering (including exclusive close and absent sessions), null/nonempty pagination tokens, cache merging, and resampling are covered offline.

## Task 1 review fixes

### Inherited edits and disposition

Inspected the inherited uncommitted diff and status before making changes: six modified files (`bin/bt.ml`, `broker/alpaca.ml`, `market/data.ml`, `market/data.mli`, `test/fixtures/alpaca/bars.json`, and `test/test_bt.ml`) plus the untracked `test/fixtures/alpaca/bars-empty.json`. All four requested fixes were already implemented correctly; retained their production code, interface addition, fixtures, and assertions unchanged.

- `fetch_minute` processes `Data.year_ranges` sequentially, fetching and writing each year before requesting the next. Its failure path rechecks disk so a completed year from an initially empty cache is retained.
- `Data.year_ranges` is a pure, tail-recursive splitter with a hand-derived December/January boundary assertion. It preserves the original first and final bounds; `Alpaca.bars` retains its existing signature.
- `parse_bars` uses `(.bars // [])[]`; the null-bars fixture asserts `([], None)`.
- The minute resume lookup selects the newest numeric year filename and streams it through the daily `Data.last_cached_date` helper, retaining only its last timestamp rather than loading all cached bars. A header-only `time` result is treated as empty.
- The summer fixture asserts `2024-07-01T13:30:00Z` becomes `2024-07-01T09:30`, with the explicit `13:30 - 4h` derivation beside the winter assertion.

This continuation added regression evidence, offline CLI smoke evidence, final gates, and this report update. No additional production changes were needed. Existing daily fetch functions, engine code, and daily dispatch were intentionally unchanged. General CLI documentation and changelog remain assigned to Task 4; the new helper is documented in `market/data.mli`.

### Review RED and GREEN evidence

The implementation and tests were inherited together, so these are explicit regression checks against temporarily restored broken behavior, not a claim that this continuation authored the inherited tests before the inherited implementation.

Command for each targeted run: `opam exec -- dune exec --root . ./test/test_bt.exe`.

| Stage | Temporary behavior | Observed result |
| --- | --- | --- |
| RED: year split | `year_ranges` returns one unsplit `(start, end_)` range | Exit 2: `File "test/test_bt.ml", line 4550, characters 11-17: Assertion failed` |
| RED: null page | Restored the splitter, retained the old `.bars[]` parser | Exit 2: jq `Cannot iterate over null (null)`, then `Failure("invalid Alpaca bars response")` |
| GREEN | Restored both inherited fixes | Exit 0, `ok`; includes the null-bars and summer-offset fixture assertions |

Both temporary regressions were removed before the final build, full suite, and daily gate. The malformed timestamp test still deliberately emits its expected jq error.

### Offline persistence and lookup smokes

Built a throwaway copy of the actual CLI source with only the network-bound `Alpaca.calendar` and `Alpaca.bars` functions replaced by deterministic responses. The real CLI argument handling, `year_ranges`, cache lookup, `Data.write_minute_bars`, and failure handler ran unchanged. Each next-year response first asserted that the previous year's file already contained its final timestamp, then raised `offline injected next-year failure`.

| Scenario | Observable result |
| --- | --- |
| Initially empty cache | First request was `2016-01-01` through `2016-12-31T23:59:59Z`; the 2016 file existed before the `2017-01-01T00:00:00Z` request failed. Exit 0 with the keep-cached warning; exact persisted row `2016-01-04T09:30,100,102,99,101,10`. |
| Resume from summer 2024 | A malformed `2015.csv` and nonnumeric `zzzz.csv` were ignored. Request resumed at `2024-07-01T09:30:00-04:00`; the replacement 2024 row was persisted before the 2025 request failed. Exit 0 with the keep-cached warning; old file bytes unchanged. |
| Unmodified production CLI | With both Alpaca credential variables removed, a valid newest 2024 cache and malformed 2015 cache produced exit 0 and `warning: export APCA_API_KEY_ID="your_api_token"; keeping cached minute bars for SPY`. The old cache was not parsed; no network request occurred. |

The injected CLI harness and all temporary minute caches were removed after use. These are offline orchestration checks, not live Alpaca or pagination verification. An attempted mount/network namespace for transport isolation was unavailable (`unshare: Operation not permitted`), so the fixture-backed throwaway CLI was used instead.

### Review gates

All commands ran in `/sandbox/stock-daytrading` on `day-trading`.

| Gate | Result |
| --- | --- |
| `opam exec -- dune build` | Exit 0, no compiler errors or warnings; only the existing environment root-discovery warning |
| `opam exec -- dune runtest --force` | Exit 0, `ok`; expected fixture/cache warnings only |
| Daily run | Exit 0, empty stderr |
| Daily stdout vs `/tmp/dt-ref.txt` | Byte-identical |
| Daily filename set vs `/tmp/dt-ref` | Identical: `fp.csv`, `main.trades.csv` |
| Both daily output files | Byte-identical to the reference |

Daily command:

```sh
_build/default/bin/bt.exe run /sandbox/research/strategies/tw/channel_ladder/main.strat --baseline tw/00685L --data-dir /sandbox/stock/data --out-dir /tmp/dt-task1-review-hfjge837 --out-name fp --no-plot
```

No subagents, live network calls, writes to `/sandbox/stock`, pushes, Git settings changes, or author overrides. The only remaining verification is the Task 4 live-network smoke already described above.
