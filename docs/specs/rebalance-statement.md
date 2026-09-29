# Design: rebalance statement

Date: 2026-09-29
Status: approved, not implemented

> [!IMPORTANT]
> A strategy file declares `rebalance daily` or `rebalance on_change`. The backtest, `bt target`, and both live daemons follow that one rule, so live trading matches what you backtested. A file without the statement trades only when its target changes, and bt warns about it.

## Contents

- [Goal](#goal)
- [Decisions](#decisions)
- [Engine](#engine)
- [DSL](#dsl)
- [Live trading](#live-trading)
  - [TW live](#tw-live)
  - [US live](#us-live)
- [Edge cases](#edge-cases)
- [Testing and gates](#testing-and-gates)
- [Docs](#docs)
- [Non-goals](#non-goals)

## Goal

Give each strategy one rebalancing rule, declared in the strategy file and followed by the backtest, `bt target`, and both live daemons, so live trading matches what you backtested.

Today the three paths disagree. The engine trades a bar only when the effective target differs from the previous bar's: `Engine.run` calls `apply_fills` only when `cash_landed || differs eff`, and `plan_fills` leaves an asset at its current value unless `force` is set or its target differs from `previous_targets`. TW live calls `plan_fills ~force:false` against the previous bar's effective target, so it follows the same rule. US live sizes `target x equity / price - held` in `Live.decide_action` every session, so it rebalances every day. Under the change-only rule, bt never made up a missed TW entry (the 09-21 channel_ladder entry), and it never completes an IOC partial fill or a leg sequence that a failed order stopped.

## Decisions

- A new DSL statement, `rebalance daily` or `rebalance on_change`, appears at most once per file. The lexer's existing `keyword` mapping produces its keywords. Identifiers cannot contain `-`, so the second form is `on_change`. The AST gains `Ast.Rebalance of bool`, and `Dsl.rebalance_of : Ast.file -> bool option` returns `Some true` for daily, `Some false` for on_change, and `None` when the file has no statement.
- A file without the statement trades on_change and triggers a warning. `bt run` and `bt target` print `warning: <file> does not declare rebalance; trading only when the target changes` on stderr, once per file. `bt live` logs the same text once at startup, as a timestamped log line after the `startup` line. `bt run` and `bt target` never write the warning to stdout, so byte gates on stdout stay identical.
- A file with `bars` (a day-trading strategy) that declares `rebalance` fails with `rebalance applies to daily strategies only`.
- `rebalance daily` re-plans fully every bar. `Engine.run ~rebalance:true` calls `apply_fills` on every bar with `~force:true`, the path dividend cash already takes. `plan_fills` is unchanged. With `~rebalance:false`, output is byte-identical to today.
- No drift band: every planned difference trades, subject to the market's share and lot quanta.
- TW live passes `~force:rebalance` to `plan_fills`.
- US live keeps `decide_action` sizing (target x equity / price - held) and gains the previous-target computation TW live uses. With on_change and an unchanged target, `decide` returns `Skip "target unchanged"`. With daily, or with a changed target, it sizes as today. Moving US live onto `plan_fills` is a later spec, because it needs a mapping from Alpaca account data to `plan_state` margin fields.
- Cures and liquidations: under daily, the fill pass after a cure re-plans to the same target and rebuys on margin within the initial-margin ratio. There is no skip window. TW live behaves the same way after a broker margin call; the daemon does not react to margin calls itself.
- Every daily example strategy and every daily test fixture declares one form.

## Engine

`Engine.run` takes `~rebalance`. `bt run` passes `Dsl.rebalance_of` for the strategy file, with `None` read as `false`.

With `~rebalance:true`, both fill modes call `apply_fills` on every bar with `~force:true`. Today `force` is `cash_landed`, true only on a bar where dividend cash lands. `force` makes `plan_fills` mark every asset changed, so it plans each asset to its effective target instead of leaving it at its current value. `plan_fills` itself does not change. `apply_fills` still copies `eff` into `prev_eff` after each pass, but under daily that comparison no longer decides anything.

With `~rebalance:false`, `run` keeps today's gates: `cash_landed || differs eff` under `--fill close` and `cash_landed || scheduled` under `--fill open`, each with `~force:cash_landed`. Output is byte-identical to today.

A maintenance breach at a bar's close sets `pending_liquidation`. At the next bar's open the engine runs `liquidate` for TW (`Collateral_over_loan`, sells margin inventory) or `minimum_cure` for US (`Equity_over_required`, sells the smallest margin fraction that restores the requirement). Under daily, that bar's fill pass re-plans to the target and rebuys on margin: at the bar's close under `--fill close`, and at the same open right after the cure under `--fill open`. `effective_targets` already scales targets so the financed part fits within the initial-margin ratio, and the rebuy stays within that limit. Under on_change, the cured position stays below target until the target changes, as today.

## DSL

- Syntax: `rebalance daily` or `rebalance on_change`, one per file.
- Lexer: `rebalance`, `daily`, and `on_change` go through `Lexer.keyword`, like `bars` and `stock`, so none of the three can serve as an identifier afterwards. Identifier characters are letters, digits, and `_`, and `-` lexes as `MINUS`, which rules out `on-change`.
- Parser: two statement rules in the style of `BARS MINUTES { Bars $2 }`, producing `Rebalance true` and `Rebalance false`.
- AST: `Ast.stmt` gains `Rebalance of bool`.
- `Dsl.rebalance_of : Ast.file -> bool option`, next to `Dsl.timeframe`, which reads `bars` the same way.
- Errors: a second `rebalance` fails with `<file>: duplicate rebalance declaration`, worded like `Dsl.timeframe`'s `duplicate bars declaration`, and `rebalance` in a file with `bars` fails with `<file>: rebalance applies to daily strategies only`. Both name the file, as `Dsl.stocks_of`'s `<file>: duplicate alias` does, but not the line: `Ast.stmt` carries no source positions, and these checks run after parsing, outside the `file:line:` prefix `Dsl.parse_file` adds.
- Warning: `bin/bt.ml` prints it with `Printf.eprintf`, as it already does for the cached minute-bar warning. `bt run` checks each strategy file it loads, so a run with two undeclared files warns twice.

## Live trading

### TW live

The TW arm of `Live.decide` already computes `target` and `previous_target` as the effective targets of the last two bars, with a previous target of 0 on the first bar. It passes `~force:rebalance` to `Engine.plan_fills` in place of `~force:false`. Under daily, each session plans back to target, so a missed entry, an IOC partial fill, or legs that a failed order stopped are traded again at the next session. Maturity rollover legs are unchanged.

`bt live` for TW logs the warning through `Live.log` after the `startup` line when the file has no statement. After a broker margin call sells shares, the next daily session rebuys up to target on margin within the initial-margin ratio.

### US live

The US arm of `Live.decide` computes the previous bar's effective target the way the TW arm does, using the same `default_financing_ratio` it applies to today's target, with 0 on the first bar. With on_change and a target equal to the previous one, `decide` returns the action `Skip "target unchanged"`. Otherwise it calls `decide_action` unchanged. `bt live` for US logs the warning through `Live.log` after the `startup` line when the file has no statement.

## Edge cases

- An undeclared file never errors; it trades on_change and warns.
- A second `rebalance`, or `rebalance` together with `bars`, is a compile error that names the file but not the line.
- In a multi-stock file the statement applies to every stock. Live trading still rejects multi-stock files; a later spec covers them.
- First bar: unchanged. The previous target is 0 in the engine and in both live arms.
- Dividend cash: unchanged. It already forces a fill pass under both rules.
- US fidelity: the US profile has zero share quanta, so a daily backtest trades any drift, while US live skips buys under USD 1 and truncates quantities to 9 decimals. This small difference is known and deferred to the later US planner spec.

## Testing and gates

Behavioral tests:

- DSL: `rebalance daily` parses to `Some true`, `rebalance on_change` to `Some false`, no statement to `None`; a duplicate statement and a `bars` conflict fail with the expected messages.
- Engine, two bars with a constant target: `~rebalance:true` trades back to target on the second bar, `~rebalance:false` does not.
- Engine, levered cure: target about 1.9, a drop through maintenance, the cure at the next open, flat prices after. Daily rebuys at that bar's close; on_change does not.
- TW `Live.decide` with injected broker data, a constant target, and holdings below target: daily returns buy legs, on_change returns none.
- US `Live.decide` with a constant target: daily returns an order, on_change returns `Skip "target unchanged"`; a changed target returns an order under both.
- `bt run` on an undeclared file prints the warning on stderr, and its stdout is unchanged.

Gates:

- Build and full suite exit 0.
- Six byte gates on the US TQQQ dd_ladder and TW 00685L channel_ladder baselines. Both research strategies stay undeclared: the gates prove that an undeclared file produces byte-identical stdout, `fp.csv`, and `main.trades.csv` to today, while the warning goes to stderr.

## Docs

- `docs/strategy.md`: the Statements list gains `rebalance`, and the `statement` rule in the Grammar (BNF) section gains the alternative `"rebalance" ( "daily" | "on_change" )`.
- `docs/engine.md`: "Targets and drift" describes both rules and the cure rebuy.
- `docs/cli.md`: the warning, and the US and TW sections of `bt target` and `bt live`.
- `docs/specs/live-trading.md` and `docs/specs/tw-live-trading.md`: a note that drift handling is per strategy.
- Examples and test fixtures declare one form.
- `CHANGELOG.md` under `[Unreleased]`: Added, the `rebalance` statement; Changed, US live without the statement stops rebalancing daily.

## Non-goals

- US live through `plan_fills`.
- Multi-stock live trading.
- A drift band.
- `rebalance` for day-trading strategies.
- Automated response to margin calls.
