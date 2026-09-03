# Design: US market run with Alpaca-modeled defaults

Date: 2026-09-02
Status: approved

## Goal

Make `bt run` correct for the US market. The engine keeps its shared two-inventory machinery; a single market profile carries every TW/US divergence; US defaults model trading through Alpaca, the same way TW defaults model Shioaji. All facts below were verified on 2026-09-02 against Alpaca's documentation and regulator schedules.

## Single-market runs

Every run simulates exactly one market. `bin/bt.ml` validates that all `stock` declarations across all strategy files plus the `--baseline` share one market; any mix is a usage error (`run: all stocks must share one market`). Mixed-market runs are forbidden in all cases, levered or not.

## Market profile

One pure function, the only market match in the run path:

```ocaml
type maintenance_model =
  | Collateral_over_loan   (* TW: margin value / loan, threshold 130%, call sells all margin inventory *)
  | Equity_over_required   (* US: equity >= sum of tiered requirements, call sells the minimum cure *)

type market_profile = {
  interest_day_count : float;      (* TW 365., US 360. *)
  settlement_lag : int;            (* trading bars: TW 2, US 1 *)
  maintenance : maintenance_model;
  default_financing_rate : float;  (* TW 6.35, US 6.25 *)
}
```

`profile_of_market : string -> market_profile` matches `"tw"` and `"us"` and fails on anything else. The profile travels as a parameter into `Engine.run`; engine forks match on the profile's variants, never on market strings. `--financing-rate` and `--maintenance-ratio` become optional flags resolved against the profile when unset.

## US behavior

- Interest: `loan * rate * calendar_days / 360` (Alpaca formula verbatim: `daily_margin_interest_charge = settlement_date_debit_balance * rate / 360`; weekends accrue). Default rate 6.25% per year (standard tier; Elite is 4.75% via `--financing-rate 4.75`).
- Settlement: interest windows use T+1 trading bars (US settlement cycle since 2024-05-28). US dividends keep their ex-date credit; no receivable period exists for US.
- Maintenance (`Equity_over_required`): required margin = sum over long positions of `tier(price) * position value`, with Alpaca's overnight table: 100% below $2.50, 50% from $2.50 to $6.00, 30% above $6.00, evaluated at each close on the money series. The account passes while `equity >= required`. `--maintenance-ratio PCT` overrides the whole table with one flat rate (the escape hatch for leveraged ETFs at 50%/75% and other house add-ons).
- Margin call: an end-of-close breach schedules a next-open minimum cure: sell the smallest amount (proceeds repaying the loan) that restores `equity >= required`, positions surviving partially, matching Alpaca's "liquidate some or all positions to reduce your margin requirement sufficiently" with no grace entitlement. Bankruptcy and solvency-guard behavior are unchanged and shared.
- Initial margin: Reg T 50% (already shipped as the 0.5 financing ratio). US loan lots stay open-ended.

## US cost defaults (Alpaca)

- Commission: 0 both sides.
- SEC fee, sells only: `tax_bps = 0.206` ($20.60 per $1,000,000, effective 2026-04-04; this rate changes with SEC fiscal years and is date-stamped in the docs).
- FINRA TAF, sells only: new cost fields `per_share_sell_fee` and `per_share_sell_cap`, US defaults $0.000195 per share and $9.79 per order, with a $0.01 per-order minimum, rounded up to the cent (rates effective 2026-01-01). Like `min_fee`, per-share dollar amounts charge only when `--capital` supplies a dollar scale; without capital they are inactive and documented as such. TW defaults: 0 and no cap.
- Slippage: 0 (override with `--slip-bps`).

## TW invariance

TW behavior must not move: profile values reproduce today's constants (365, T+2, collateral formula, 130%, 6.35), and the TW smoke must stay byte-identical. The maintenance check and call machinery refactor into variant matches, but the TW arms are the existing logic verbatim.

## Documented gaps (engine.md US gap section)

- Leveraged-ETF house requirements (2x 50%, 3x 75%) and short tiers are not auto-classified; use `--maintenance-ratio`.
- The concentration rule (single position at 70% of equities value with a margin balance of $100,000 or more raises that position to 50%) is not modeled.
- Intraday buying power (4x) and the intraday margin framework are out of scope; the engine is end-of-day.
- Elite-tier margin pricing is a flag override, not a default.
- CAT fee pass-throughs are not modeled (Alpaca has announced but not scheduled them).

## Verification

TDD per behavior with recorded red runs: day count (360 vs 365 on a weekend fixture), T+1 window arithmetic, tiered required-margin computation across all three price bands, minimum-cure sizing (hand-derived: cure exactly to the threshold), flat-rate override, TAF charge with floor and cap under `--capital`, SEC fee on sells, mixed-market rejection (levered and unlevered), and the TW byte-identity gate on the 00685L smoke. A SPY margin-run smoke before and after, recorded with interpretation.

## Execution

One task agent under `skill://executing-plans` and the TDD contract; commits only (user pushes); no git-settings changes; Claude trailer; market matches per the AGENTS.md golden rule (the profile centralizes them).
