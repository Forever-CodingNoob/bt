# Design: dividend cash accounting

Date: 2026-09-01
Status: approved

Supersedes the dividend treatment implied by the corporate-action sections of earlier specs: cash dividends no longer smooth the execution prices. Splits, capital reductions, and par-value changes keep their factor adjustment in every series. Stock dividends (股票股利) also keep factor adjustment; they are unit changes, not cash.

## Goal

Model cash dividends the way they work in the real market: the ex-date drops the traded price, the pay date delivers cash, a TW broker applies the cash on margin-financed shares against the loan, and a US account receives everything as cash. Strategies keep their current signal behavior.

## Two price series per asset

- Signal series: dividend-and-event adjusted, exactly today's series. The DSL evaluates every indicator and rule on it, so existing strategies keep their meaning.
- Money series: event-adjusted only (splits, reductions, par changes), with dividend drops left in. The engine prices every fill, inventory value, loan, collateral, and equity point on it.

Volume is split-adjusted in both (already shipped).

## Dividend lifecycle

1. Ex-date (TW). The money-series price gaps down naturally. The engine books a receivable: shares held at the ex-date times cash per share, split between the cash inventory's shares and the margin inventory's shares. Equity includes receivables. Maintenance does not: collateral is margin shares only, so the maintenance ratio genuinely worsens between ex-date and pay date.
2. Pay date (TW). The cash-inventory receivable becomes account cash. The margin-inventory receivable repays that asset's loan lots pro-rata, settling the matching share of accrued interest under the existing proportional convention; any excess over the remaining loan and interest becomes account cash.
3. US. The full dividend becomes account cash on the ex-date. This zero-lag treatment is a documented simplification: no US receivable period exists because nothing is forced onto the loan and the timing has no maintenance effect.
4. Re-fill trigger. On any bar where dividend cash lands in the account, the engine runs one normal fill pass toward the current targets for every asset in the run, through the standard fill machinery with normal costs. On every other bar, drift semantics are unchanged: fills fire only on target changes.
5. Tax. `--dividend-tax PCT`, default 0, reduces every receivable (and US ex-date credit) at creation. The single percentage stands in for income tax and the NHI supplementary premium.
6. Frozen accounts. A bankrupt account still converts receivables on their pay dates; the cash reduces residual debt.

## Data

- TW: a new cache file `data/tw/<symbol>.cashdiv.csv` with header `ex_date,cash_per_share,pay_date`, fetched from FinMind's `TaiwanStockDividend` table. When the source lacks a pay date, the loader uses ex-date plus one calendar month and the docs disclose the fallback. The existing `<symbol>.div.csv` factor file remains the signal-series input.
- US: no new fetch. The loader derives cash per share from the daily ratio between the cached raw close and adjusted close, credited on the ex-date.
- The loader returns money-series bars, signal-series bars, and per-asset dated dividend events. `bin/bt.ml` wires signal bars into the DSL and money bars plus events into the engine.

## Result changes

- Assets with no cash dividends (00685L) are bit-identical end to end; this is the regression gate.
- Dividend payers without margin: totals drop below today's frictionless reinvestment by reinvestment costs, pay-date timing, and any configured tax.
- Dividend payers on margin: loans shrink at every pay date, interest falls, maintenance improves stepwise at pay dates and dips between ex-date and pay date.
- Trip statistics become ex-dividend price returns; the dividend lands in equity, not in the trip win rate. Documented.

## Verification

Hand-derived fixtures: receivable in equity but not in maintenance; TW pay-date paydown including the excess-spill case; US ex-date credit; the re-fill trigger paying costs; the tax flag; a frozen-account receivable. Full suite green from a clean tree. Byte-identical 00685L smoke against the pre-change binary. A recorded before-and-after 0050 buy-and-hold comparison in the task report.

## Execution

Spec, then plan, then subagent tasks with scoped reviews and a final whole-branch review. If the Codex backend runs out of credits mid-task, the work pauses and waits for restoration per the standing user rule.
