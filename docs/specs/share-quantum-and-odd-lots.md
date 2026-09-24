# Design: share quantum and odd lots

Date: 2026-09-19
Status: implemented

> [!IMPORTANT]
> If a market supports fractional shares, bt trades fractional shares. Otherwise bt rounds to the smallest unit the market trades, and the live path submits that exact quantity. Backtest and live share one rounding rule, held in the market profile, so live exposure equals backtest exposure by construction.

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

Close the gap between target exposure and real exposure in both live markets, and make the TW backtester size the way the TW market trades. Before this change, every backtest sized in fractional exposure units, TW live floored to 1000-share lots and discarded up to 999 shares per leg, and US live truncated to whole shares even though Alpaca fills fractions.

## Decisions

- One rounding rule per market, stored in `Engine.market_profile` and applied inside `Engine.plan_fills`, so `bt run`, `bt target`, and `bt live` floor with the same quantum. Live planning prices commission at the 14.25 bps debit rate, so its buy quantities can be slightly lower than a backtest's.
- `--capital` is required for `bt run` and `bt daytrade`. The share quantum converts value to shares, which needs a money scale, and real accounts always charge the minimum fee and per-share fees. The engine's `capital : float option` becomes `capital : float`, and every branch that ran without capital is deleted.
- TW cash inventory rounds to whole shares. TW margin inventory rounds to 1000-share lots because odd lots cannot be margined. US inventory is fractional.
- TW live submits each ordinary cash leg as one `Common` order for the lot part plus one `IntradayOdd` order for the remainder. Margin legs and refinance legs are whole lots only. Lot orders are `MKT` + `IOC`. Odd-lot orders are limit `ROD`, the only form TWSE accepts. Refinance ordering and dependency are unchanged: bt submits the rebuy only after the sell has completely filled, sized to the shares actually sold.
- US live submits a fractional `market` order with `time_in_force: day`. The decision runs 15 minutes before the close. The submit cutoff is 10 minutes before the close because Alpaca queues a day order sent after the close for the next session. Market-on-close is dropped because Alpaca rejects fractional MOC orders. `--slip-bps` already models the gap between the near-close fill and the backtester's close fill, so this change adds no new fidelity gap.
- TW default commission becomes 0.0285% with a TWD 1 minimum per order. That is the SinoPac electronic-trading promotion rate, applied flat without the monthly tier. Backtests use this 2.85 bps rate. Live planning and live funding both use the 14.25 bps settlement-debit list rate with the same TWD 1 minimum, because SinoPac debits the list rate at settlement and rebates the discount later.
- Odd lots cannot form a same-day round trip. The daemon trades once per session, and ordinary legs never contain both a buy and a sell of the same symbol, so a round trip cannot arise by construction. The executor still refuses an `IntradayOdd` order in the opposite direction of an `IntradayOdd` fill already recorded today, and stops the remaining legs.

## Market facts

- Taiwan: no fractional shares. Regular session trades 1000-share lots. Intraday odd lots trade 09:00 to 13:30 in a separate book with its own prices. That book accepts limit `ROD` orders only, 1 to 999 shares, with no margin or securities-lending sales, and uses the same daily price bands and ticks as regular trading ([TWSE intraday odd-lot rules](https://www.twse.com.tw/downloads/zh/trading/introduce/introduce4-1.pdf)). The Shioaji server exposes no odd-lot quote, so odd-lot limits come from the regular-book snapshot and their fills may differ. Odd lots are cash only and cannot be day traded. Sell tax 0.3% on both books.
- SinoPac fees: 0.1425% list rate; electronic-trading promotion 20% of list (0.0285%) with TWD 1 minimum per order on the first TWD 1,000,000 per month, refunded on the 15th of the following month. The full list rate is debited at settlement, so live funding uses the list rate.
- Alpaca: fractional quantities on `market` and `limit` orders with `time_in_force: day` only; all buy orders must have a minimum market value of USD 1, while sell orders have no minimum validation, so any open position can be closed. [Alpaca broker API FAQ](https://docs.alpaca.markets/us/docs/broker-api-faq.md#what-is-the-minimum-order-value). Alpaca rejects fractional MOC orders. A day order submitted after the close queues for the next session ([Alpaca orders](https://docs.alpaca.markets/us/docs/orders-at-alpaca.md)).

## Engine: share quantum

`Engine.market_profile` gains two fields:

| Field | TW | US | Meaning |
|---|---|---|---|
| `cash_share_quantum` | 1. | 0. | Cash inventory quantities are floored to a multiple of this many shares; 0 means fractional. |
| `margin_share_quantum` | 1000. | 0. | Margin inventory quantities are floored to a multiple of this many shares; 0 means fractional. |

`Engine.plan_fills` receives the profile. For each planned quantity it converts value to shares at the fill price using the mandatory capital scale, floors to the applicable quantum when that quantum is positive, and converts back to value. Cash buys and cash sells use the cash quantum. Margin buys, margin sells, and both sides of every refinance leg use the margin quantum. The floored remainder stays in cash. `Engine.run` passes the profile through its existing partial application. It also floors maturity rollovers, margin-call sales, and forced sales to the quantum of the inventory they sell, and carries quantized inventories as share counts between bars.

With quantum 0 the floor is skipped, so US backtests at a fixed capital are byte-identical before and after the quantum change. TW backtests change on purpose.

## TW live: lot and odd-lot orders

Share counts arrive from the engine already floored. `Live.legs_of_plan` translates each leg into orders:

- Cash buy or sell of N shares: one `Common` order for N / 1000 lots when that is positive, then one `IntradayOdd` order for N mod 1000 shares when that is positive. Both orders carry the leg's action and condition.
- Margin buy, margin sell, and every refinance leg: one `Common` order. The margin quantum makes N a multiple of 1000, so no remainder exists.

Leg record: `{ action; cond; lot : Common | IntradayOdd; quantity }`. `quantity` counts lots for `Common` and shares for `IntradayOdd`, matching what Shioaji expects for each. `Shioaji.place_order` passes the lot kind through. Lot orders use `MKT` + `IOC` with price 0. Odd-lot orders use `LMT` + `ROD`, priced at the snapshot ask for a buy and the snapshot bid for a sell. A missing or non-positive quote skips only the odd-lot order. The request builder rejects an odd-lot quantity above 999 or a condition other than `Cash`.

Executor rules:

- Funding and fill math are in shares. A `Common` fill of k lots is k x 1000 shares.
- The lot order and the odd order of one leg are independent. If either is rejected, bt still sends the other and the later ordinary legs.
- The executor does not wait for an odd-lot fill. A sent odd-lot buy reserves its full cost from cash at once. The executor never credits odd-lot sale proceeds to same-session cash; an invariant test shows that a live plan never holds an odd-lot sell followed by a buy.
- Refinance dependency is unchanged: sells run first, the rebuy waits for the complete sell fill and is sized to the shares actually sold.
- Failure handling: a `Common` order rejected with no fill, or a rejected odd-lot placement, lets later independent legs run. A failed sell blocks its dependent rebuy and every leg after it. An IOC partial fill is final and stops later legs. bt trades the unfilled remainder again only when a later session's effective target changes; an unchanged target keeps the resulting drift. An ambiguous placement stops the day, and bt never resubmits it.
- Same-day round-trip guard: the executor refuses an `IntradayOdd` order when today's trade listing already holds an `IntradayOdd` fill in the opposite direction for the symbol.
- Simulation server: odd lots are unsupported. In simulation bt skips the odd order with a log line; production submits it.
- Positions are read with `unit: Share` so odd holdings count in inventory and equity. `position_detail` takes no unit field and reports lots; a detail quantity larger than the held margin shares stops the day.
- Live funding uses the 14.25 bps settlement-debit list rate with a TWD 1 minimum per order for affordability and cash carry.

## US live: fractional shares

- Desired shares are fractional: target x equity / price. The order quantity is the fractional difference between desired and held, rounded down to Alpaca's 9-decimal precision. bt skips buy deltas below USD 1 notional. It submits sells of any positive quantity, so a sub-USD-1 position can always be closed.
- Order: `type: market`, `time_in_force: day`. The decision runs about 15 minutes before the close and submission stops 10 minutes before the close. The deterministic `client_order_id` and the query-before-submit dedup are unchanged.
- US live no longer truncates desired shares or the order delta to whole shares. The US backtester never rounded, so its outputs are unchanged.

## Costs

TW defaults: `fee_bps` 2.85 and `min_fee` 1 replace the previous defaults. Sell tax and slippage are unchanged. The minimum applies per order, so a cash leg split into a lot order and an odd order pays two minimums in live execution. The backtest planner charges one minimum per asset trade, a fidelity note in `docs/engine.md`. Live funding debits the 14.25 bps list rate with the same TWD 1 minimum. Because capital is mandatory, the backtester always applies the minimum fee and the US per-share fees, and the "only with `--capital`" clauses are removed from code and docs.

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
- Smoke: `bt target` on the simulation server prints the `IntradayOdd` leg, and `bt live` on the simulation server logs `submitted=skip:odd-lot-unsupported-in-simulation` for it; one user-approved production session exercises a cash leg that produces both a lot order and an odd order.

## Docs

- `docs/cli.md`: `bt run` and `bt daytrade` argument tables (`--capital` required, Default column `required`), `bt target` and `bt live` for both markets (order forms, MOC removal, odd-lot rules, simulation skip), TW cost table rows, removal of every "applies only with `--capital`" clause.
- `docs/engine.md`: sizing row, TW cost defaults, US live fidelity, TW live fidelity, cost sections that mention optional capital.
- `docs/specs/tw-live-trading.md`: board-lot sentences replaced by references to this spec.
- `README.md` and `docs/strategy.md`: every `bt run` or `bt daytrade` example carries `--capital`.
- `CHANGELOG.md`: add Changed entries under `[Unreleased]` (`--capital` required, TW whole-share and lot rounding, TW fee defaults, US fractional market orders replacing MOC), then cut `[0.10.0]` containing every `[Unreleased]` entry, including the earlier TW live entries, with the compare links updated. The tag and GitHub pre-release are the user's.

## Non-goals

- Modeling the monthly TWD 1,000,000 promotion tier or the delayed rebate.
- After-hours odd-lot session (`Odd`) and fixed-price session (`Fixing`).
- Odd-lot quotes: the server exposes none, so odd-lot limits come from the regular-book snapshot and fills are accepted at whatever the odd book gives.
- Short selling: targets remain clamped to non-negative exposure.
