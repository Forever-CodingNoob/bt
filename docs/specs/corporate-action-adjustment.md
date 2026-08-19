# Design: exact corporate-action adjustment for TW prices

Date: 2026-08-19
Status: approved in discussion; pending spec review

## Context

TW raw prices from TaiwanStockPrice are not adjusted for splits,
capital reductions, or par value changes. The current workaround is a
heuristic: `detect_splits` treats any close-to-close move above 25% as
an event and infers the factor from the post-event open against the
prior close. The heuristic has two known defects:

1. The inferred factor absorbs the event day's real overnight move.
   For the 00685L 1:24 split on 2026-07-07 it uses 13.09/306 = 0.0428
   instead of the true 12.75/306 = 0.04167, which erases a +2.67% real
   market move from the return series.
2. Events below the 25% threshold (most capital reductions and par
   value changes) are invisible and stay unadjusted.

FinMind provides three free datasets with exact before/after reference
prices. `TaiwanStockSplitPrice` was verified live from this sandbox
without a token; `TaiwanStockPriceAdj` was verified unavailable
(HTTP 400) and is not an option.

This is sub-project A of the DSL-expressiveness update. Sub-project B
(multi-stock strategies) and C (margin financing) build on its data
correctness and have their own specs.

## Goals

- Adjust TW price history with exact factors for splits, reverse
  splits, capital reductions, and par value changes.
- Keep the raw price cache immutable and append-only; adjustment stays
  a load-time transform, as with dividends today.
- Delete the 25% gap heuristic.

## Non-goals

- US market changes (adj_close already covers corporate actions).
- Engine, DSL, report, or CLI flag changes.
- Backer/Sponsor datasets, whole-market queries, or intraday data.

## Data

### Datasets and factors

| Dataset | Factor | Notes |
|---|---|---|
| `TaiwanStockSplitPrice` | `after_price / before_price` | splits and reverse splits |
| `TaiwanStockCapitalReductionReferencePrice` | `PostReductionReferencePrice / ClosingPriceonTheLastTradingDay` | pass `data_id` |
| `TaiwanStockParValueChange` | `after_ref_close / before_close` | data starts 2020-01-01 |

Rows with a null or zero "before" price are skipped. Each request
passes `data_id`, and the jq transform additionally selects on
`stock_id` equal to the requested symbol, so a dataset that ignores
`data_id` server-side still yields per-symbol rows.

In every table, `date` is the first trading day at the new price
basis. `back_adjust` multiplies bars strictly before the event date,
which matches this convention and the existing ex-dividend handling.

### Cache file

One file per symbol: `data/tw/<symbol>.events.csv`, header
`date,factor`, rows sorted by date, factors from all three datasets
merged. The format equals `.div.csv`, so `read_dividends` reads it
unchanged. The file is rewritten wholesale on each fetch through the
existing temp-file pattern; the tables are tiny.

## Fetch

`Data.fetch` (tw market only) fetches events after dividends into
`data/tw/<symbol>.events.csv`. Failure tolerance mirrors
`fetch_dividends`: the rewrite happens only when all three dataset
requests succeed; otherwise print one warning naming the failed
dataset and keep the cached file if it exists. Stale factors beat
none, and a transient API error must not flip later runs to
unadjusted prices.

`FINMIND_TOKEN` stays required by `bt fetch` as today; the events
requests reuse the same token plumbing.

## Load

In `Data.load` for the tw market:

- Read `.div.csv` and `.events.csv`, append the factor arrays, and
  pass the result to the existing `back_adjust`. Same-date factors
  from both files compose multiplicatively, which `back_adjust`
  already does.
- If `.events.csv` is missing, print
  `warning: prices unadjusted for splits/reductions` and continue,
  mirroring the dividend warning.
- Delete `detect_splits` and its call site.

## Result changes

00685L's 2026-07-07 return becomes 12.23/12.75 - 1 = -4.08% instead of
the heuristic's -6.57%, and all pre-split history rescales by exactly
1/24. Every published metric on symbols with detected events shifts
accordingly. This is the correction, not a regression; no
compatibility flag reproduces the heuristic numbers.

## Tests

- `back_adjust` unit tests through fixture factor files: one split,
  one capital reduction below the 25% threshold, one same-date
  dividend-plus-event composition.
- A fetch transform test per dataset with a fixture JSON response:
  factor formula, null and zero before-price skipping, and stock_id
  selection.
- An integration test on a small 00685L-shaped fixture asserting the
  event-day return uses the exact factor.
- Delete `test_detect_splits` (the function it covers is deleted).

## Migration

- `lib/data.ml`: `fetch_events`, `.events.csv` load path, warning,
  delete `detect_splits`.
- `test/test_bt.ml`, `test/fixtures/`: per the Tests section.
- `README.md` (lines 160-162), `docs/cli.md` (Price adjustments
  section), `CONTRIBUTING.md` (module table): replace mentions of the
  split heuristic with the events fetch. Respect user edits; edit
  surgically.
