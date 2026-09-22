# Design: share quantum and odd lots

Date: 2026-09-19
Status: approved design, not implemented

> [!IMPORTANT]
> If a market supports fractional shares, bt trades fractional shares. If it does not, bt rounds to the smallest unit the market trades and the live path submits that exact quantity. Backtest and live use one rounding rule, held in the market profile, so live exposure equals backtest exposure by construction.

## Contents

- [Goal](#goal)
- [Decisions](#decisions)
- [Market facts](#market-facts)
- [Engine: share quantum](#engine-share-quantum)
- [TW live: lot and odd-lot orders](#tw-live-lot-and-odd-lot-orders)
- [US live: fractional shares](#us-live-fractional-shares)
- [Costs](#costs)
- [Testing and gates](#testing-and-gates)
- [Docs](#docs)
- [Non-goals](#non-goals)

## Goal

Close the gap between target exposure and real exposure in both live markets, and make the TW backtester size the way the TW market trades. Today every backtest sizes in fractional exposure units, TW live floors to 1000-share lots and discards up to 999 shares per leg, and US live truncates to whole shares even though Alpaca fills fractions.

## Decisions

- One rounding rule per market, stored in `Engine.market_profile` and applied inside `Engine.plan_fills`, so `bt run`, `bt target`, and `bt live` produce the same share counts.
- `--capital` is required for `bt run` and `bt daytrade`. The share quantum converts value to shares, which needs a money scale, and the minimum fee and per-share fees always apply in real accounts. The engine's `capital : float option` becomes `capital : float` and every branch that ran without capital is deleted.
- TW cash inventory rounds to whole shares. TW margin inventory rounds to 1000-share lots because odd lots cannot be margined. US inventory is fractional.
- TW live submits each ordinary cash leg as one `Common` order for the lot part plus one `IntradayOdd` order for the remainder. Margin legs and refinance legs are whole lots only. Refinance ordering and dependency are unchanged: the rebuy is submitted only after the sell has completely filled, sized to the shares actually sold.
- US live submits a fractional `market` order with `time_in_force: day` at the existing decision time near the close. Market-on-close is dropped because Alpaca rejects fractional MOC orders. The near-close fill versus the backtester's close fill is the case `--slip-bps` already models, so no new fidelity gap is introduced.
- TW default commission becomes 0.0285% with a TWD 1 minimum per order (SinoPac electronic-trading promotion rate, flat, no monthly tier).
- Odd lots cannot form a same-day round trip. The daemon trades once per session and ordinary legs never contain both a buy and a sell of the same symbol, so this cannot happen by construction; the executor still refuses an `IntradayOdd` order in the opposite direction of an `IntradayOdd` fill already recorded today.

## Market facts

- Taiwan: no fractional shares. Regular session trades 1000-share lots. Intraday odd lots (1 to 999 shares) trade 09:00 to 13:30 in a separate book with its own prices; the Shioaji server exposes no odd-lot quote, so odd-lot orders are priced from the lot quote and their fills may differ. Odd lots are cash only and cannot be day traded. Sell tax 0.3% on both books.
- SinoPac fees: 0.1425% list rate; electronic-trading promotion 20% of list (0.0285%) with TWD 1 minimum per order on the first TWD 1,000,000 per month, refunded on the 15th of the following month. The full list rate is debited at settlement, so the daemon's pending-settlement cash is conservative and needs no change.
- Alpaca: fractional quantities on `market` and `limit` orders with `time_in_force: day` only; all buy orders must have a minimum market value of USD 1, while sell orders have no minimum validation, so any open position can be closed. [Alpaca broker API FAQ](https://docs.alpaca.markets/us/docs/broker-api-faq.md#what-is-the-minimum-order-value); no fractional MOC.

## Engine: share quantum

`Engine.market_profile` gains two fields:

| Field | TW | US | Meaning |
|---|---|---|---|
| `cash_share_quantum` | 1. | 0. | Cash inventory quantities are floored to a multiple of this many shares; 0 means fractional. |
| `margin_share_quantum` | 1000. | 0. | Margin inventory quantities are floored to a multiple of this many shares; 0 means fractional. |

`Engine.plan_fills` receives the profile. For each planned quantity it converts value to shares at the fill price using the mandatory capital scale, floors to the applicable quantum when that quantum is positive, and converts back to value. Cash buys and cash sells use the cash quantum. Margin buys, margin sells, and both sides of every refinance leg use the margin quantum. The floored remainder stays in cash, exactly as the live executor treats retained remainders today. `Engine.run` passes the profile through its existing partial application; no other engine code changes.

With quantum 0 the floor is skipped, so US backtests at a fixed capital are byte-identical before and after the quantum change. TW backtests change on purpose.

## TW live: lot and odd-lot orders

Share counts arrive from the engine already floored. `Live.legs_of_plan` translates each leg into orders:

- Cash buy or sell of N shares: one `Common` order for N / 1000 lots when that is positive, then one `IntradayOdd` order for N mod 1000 shares when that is positive. Same action and condition.
- Margin buy, margin sell, and every refinance leg: one `Common` order. N is a multiple of 1000 by the margin quantum, so there is no remainder.

Leg record: `{ action; cond; lot : Common | IntradayOdd; quantity }` where `quantity` is lots for `Common` and shares for `IntradayOdd`, matching what Shioaji expects for each. `Shioaji.place_order` passes the lot kind through. Odd-lot orders use `MKT` + `IOC` like lot orders; the implementer verifies this against the official stock-order reference and records the source.

Executor rules:

- Funding and fill math are in shares. A `Common` fill of k lots is k x 1000 shares.
- The lot order and the odd order of one leg are independent: if either fails, the other still goes and later ordinary legs still go.
- Refinance dependency is unchanged: sells run first, the rebuy waits for the complete sell fill and is sized to the shares actually sold.
- Failure handling is unchanged: a rejected or failed order places nothing and the daemon continues with independent legs; an IOC partial fill is final and the unfilled remainder is re-planned next session; an ambiguous placement is never resubmitted and stops the day.
- Same-day round-trip guard: the executor refuses an `IntradayOdd` order when today's trade listing already holds an `IntradayOdd` fill in the opposite direction for the symbol.
- Simulation server: odd lots are unsupported. In simulation the odd order is skipped with a log line; production submits it.
- Positions are read with `unit: Share` so odd holdings count in inventory and equity.

## US live: fractional shares

- `desired_shares` returns a float. The order quantity is the fractional difference between desired and held, formatted to Alpaca's precision. Buy deltas below USD 1 notional are skipped. Sells of any positive quantity are submitted, so a sub-USD-1 position can always be closed.
- Order: `type: market`, `time_in_force: day`, submitted at the existing decision time about 15 minutes before the close. The deterministic `client_order_id` and the query-before-submit dedup are unchanged.
- Whole-share truncation (`desired_shares`, `order_delta`) is removed. The US backtester never rounded, so its outputs are unchanged.

## Costs

TW defaults: `fee_bps` 2.85 and `min_fee` 1, replacing 3.99 and 20. Sell tax and slippage unchanged. The minimum applies per order, so a cash leg split into a lot order and an odd order pays two minimums; the live executor's per-leg cost already works per order once the leg carries its own quantity. Because capital is mandatory, the minimum fee and the US per-share fees always apply in the backtester; the "only with `--capital`" clauses are removed from code and docs.

## Testing and gates

Hand-derived behavioral tests:

- Engine: TW cash quantity floors to 1 share; TW margin quantity floors to 1000; refinance sides both floor to 1000; US quantities unchanged; `test_engine_buyhold_costs` (US) is re-derived once for mandatory capital and then stays bit-identical.
- CLI: `bt run` and `bt daytrade` without `--capital` fail with a usage error naming the flag.
- TW live translation: 86,580 shares -> `Common` 86 + `IntradayOdd` 580; 999 -> odd only; 1000 -> lot only; margin 86,580 -> `Common` 86 with 580 retained.
- TW executor: lot order fails but the odd order proceeds; odd order skipped in simulation; same-day opposite-direction odd guard; `unit: Share` position totals include a 1-share holding.
- US live: fractional delta; buy deltas below USD 1 notional are skipped; sells of any positive quantity are submitted, so a sub-USD-1 position can always be closed; market day order body.
- Costs: TWD 1 minimum on a TWD 1,000 odd order; two minimums on a split leg.

Gates:

- Build and full suite exit 0.
- US byte-identity: `bt run` on the SPY strategy with `--capital` equals a reference captured at the commit before the engine change with the same `--capital` value. This proves quantum 0 is a no-op at fixed capital.
- TW byte-identity: the old reference is retired. A new reference is captured after the engine change with `--capital`, one fill is hand-checked (share count floored, commission at the TWD 1 minimum), and the new reference is pinned for later commits.
- Every example, fixture, and documented command that runs `bt run` or `bt daytrade` gains a `--capital` value.
- Smoke: `bt target` on the simulation server logs the odd leg as skipped; one user-approved production session exercises a cash leg that produces both a lot order and an odd order.

## Docs

- `docs/cli.md`: `bt run` and `bt daytrade` argument tables (`--capital` required, Default column `-`), `bt target` and `bt live` for both markets (order forms, MOC removal, odd-lot rules, simulation skip), TW cost table rows, removal of every "applies only with `--capital`" clause.
- `docs/engine.md`: sizing row, TW cost defaults, US live fidelity, TW live fidelity, cost sections that mention optional capital.
- `docs/specs/tw-live-trading.md`: board-lot sentences replaced by references to this spec.
- `README.md` and `docs/strategy.md`: every `bt run` or `bt daytrade` example carries `--capital`.
- `CHANGELOG.md`: add Changed entries under `[Unreleased]` (`--capital` required, TW whole-share and lot rounding, TW fee defaults, US fractional market orders replacing MOC), then cut `[0.10.0]` containing every `[Unreleased]` entry, including the earlier TW live entries, with the compare links updated. The tag and GitHub pre-release are the user's.

## Non-goals

- Modeling the monthly TWD 1,000,000 promotion tier or the delayed rebate.
- After-hours odd-lot session (`Odd`) and fixed-price session (`Fixing`).
- Odd-lot quotes: the server exposes none, so odd fills are accepted at whatever the odd book gives.
- Short selling: targets remain clamped to non-negative exposure.
