# Design: code and docs tidy-up

Date: 2026-09-02
Status: approved

## Goal

Six cleanup items: remove redundant code comments with an auditable list, convert CHANGELOG.md to tracked keepachangelog 1.1.0 format with retroactive versions and GitHub pre-releases, renovate CONTRIBUTING.md, extract the engine documentation from README.md into docs/engine.md with per-market gap analysis, restructure every doc with a real header hierarchy and GitHub alert blocks, and add a Default column to the cli.md option tables.

## Item 1: comment removal

Remove comments that restate adjacent code, stale references, commented-out code, decorative section markers, and `ponytail:` markers. Keep test derivation comments, dated regulatory facts (for example the TPEX 2014-11-10 ratio change and the bond-ETF exemption window), `.mli` doc comments, and spec cross-references. The report lists every removal as file:line, exact text, and reason, for user audit. The suite must stay green; the change is comments-only.

## Item 2: changelog

CHANGELOG.md becomes git-tracked and follows keepachangelog 1.1.0, read in full from the site: preamble declaring the format and Semantic Versioning adherence, `[Unreleased]` section at the top, versions latest-first as `## [x.y.z] - YYYY-MM-DD`, only the standard categories (`Added`, `Changed`, `Deprecated`, `Removed`, `Fixed`, `Security`) and only when non-empty, human-readable entries (no commit-log dumps), and link references with real compare URLs against github.com/Forever-CodingNoob/bt.

`[Unreleased]` starts empty: the tidy-up itself is a docs-and-comments change with no notable behavior, and future behavior-changing commits fill the section.

Retroactive version map, with exact dates and commits finalized from git log during implementation and recorded in the report:

- 0.1.0: initial CLI, DSL, engine, fetch/cache, plot.
- 0.2.0: fill modes, target and partial-order DSL styles, round-trip statistics.
- 0.3.0: exact corporate-action adjustment, multi-stock strategies, baseline, backfill.
- 0.4.0: margin financing with drift accounting.
- 0.5.0: two-inventory margin engine, loan term, settlement-window interest, TW tax and ratio alignment, functional refactor with `.mli` interfaces, volume restatement.
- 0.6.0: dividend cash accounting.

The current file's narrative engine prose migrates to docs/engine.md (item 4); the changelog keeps only entries.

## Item 3: CONTRIBUTING renovation

Rewrite to current reality: module layout including the seven `.mli` files; build and test commands; binding style rules (no `for`/`while`, `let () = e in` sequencing, tail recursion only, float operation order preservation, one space around `=`); test rules (derivation comments, the `test_engine_buyhold_costs` sentinel, byte-identity gates); the `bt-test<n>.exe` fetch convention; data cache layout; an updated add-an-indicator walkthrough; a docs map.

## Item 4: README and docs/engine.md

README.md keeps: intro, contents, requirements, build and test, quick start, command summary linking docs/cli.md, DSL summary linking docs/strategy.md, trimmed data notes, contributing pointer, license, acknowledgements. The "How the engine trades" section moves out.

docs/engine.md hierarchy (user-specified):

- `## Core engine`: targets and drift, the fill planner (E1, minimum-down-payment allocation, waterfall, refinancing), equity accounting (inventories, receivables, residual debt), end-of-data close.
- `## Taiwan market (tw)`: costs and sell-tax classes; margin financing (ratios with the 2014-11-10 note, T+2 settlement-window interest, 18-month loan term and rollover, collateral-only maintenance, calls, bankruptcy); dividend lifecycle (ex-date receivable, pay-date forced loan paydown, re-fill, tax flag); ending with `### Gap between simulation and the real market`: same-close fill timing, limit-down locks on forced sales, the real two-business-day grace and restore-to-initial-ratio process versus next-open liquidation, marginability eligibility of leveraged ETFs, board lots and tick sizes, dividend cash timing, T+2 cash settlement, day-trade tax reduction, odd lots.
- `## United States market (us)`: costs; dividends derived from adj_close with zero-lag ex-date credit; open-ended margin loans; ending with `### Gap between simulation and the real market`: split-detection heuristic, no short selling, no borrow costs, no US regulatory margin rules (Reg T, maintenance) modeled.

Content sources: the README engine section, the old CHANGELOG narrative, docs/strategy.md margin passages (strategy.md keeps a DSL-focused summary plus a link), and the TW market audit findings.

## Item 5: structure

Every doc: one h1; disciplined h2-h4 with h5/h6 where genuinely nested; GitHub alert blocks with consistent semantics (`[!NOTE]` context, `[!TIP]` usage advice, `[!IMPORTANT]` load-bearing semantics, `[!WARNING]` fidelity gaps, `[!CAUTION]` destructive or irreversible actions); tables for enumerable content; short paragraphs, no essay walls.

## Item 6: cli.md defaults

Option and argument tables gain a `Default` column; default values move out of descriptions; entries without a default show an em dash.

## Execution

One task agent, sequential, five commits with the Claude co-author trailer:

1. `chore: remove redundant comments` (code only; suite green; audit list in report).
2. `docs: keepachangelog changelog` (first commit tracking CHANGELOG.md; version map in report).
3. `docs: renovate CONTRIBUTING`.
4. `docs: extract engine guide` (README trim plus docs/engine.md).
5. `docs: restructure with alerts and defaults column` (cli.md and strategy.md sweep; Default column).

Then: annotated tags v0.1.0 through v0.6.0 at the mapped commits, pushed to origin; `gh release create --prerelease` per tag with the changelog section as notes; `GH_TOKEN` passed via environment only and never printed; the implementer reads `skill://github` before using gh. Release URLs in the report.

## Verification

Suite green after commit 1 (comments-only proof). Every relative link in the docs resolves. `gh release list` shows the six pre-releases. Coordinator's independent pass: fresh suite run, doc read-through against the six items, audit-list spot check against the commit diff.

## Aftermath

The sandbox memory note "CHANGELOG.md stays untracked; edit, never git add" is obsolete after commit 2 and flips to "CHANGELOG.md is tracked; behavior-changing commits update [Unreleased]".
