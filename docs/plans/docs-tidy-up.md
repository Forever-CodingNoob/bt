# Code and Docs Tidy-Up Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Execute docs/specs/docs-tidy-up.md: comment cleanup with an audit list, tracked keepachangelog CHANGELOG.md with retroactive versions and GitHub pre-releases, renovated CONTRIBUTING.md, README trimmed with docs/engine.md extracted (market-first hierarchy with per-market gap sections), structured docs with GitHub alerts, and a Default column in docs/cli.md.

## Global constraints

- The spec is binding, including the comment keep-set (test derivations, dated regulatory facts, .mli doc comments, spec cross-references stay; restatements, stale references, dead code, decoration, and `ponytail:` markers go).
- Docs style: one h1 per file; h2-h4 hierarchy (h5/h6 only when genuinely nested); GitHub alerts `[!NOTE]`/`[!TIP]`/`[!IMPORTANT]`/`[!WARNING]`/`[!CAUTION]` with the spec's semantics; tables for enumerable content; no hard-wrapped mid-sentence newlines; no emojis.
- Commits carry `Co-Authored-By: Claude <noreply@anthropic.com>`.
- `GH_TOKEN` is provided by the coordinator via environment; never print it, never write it to a file. Read `skill://github` before any gh command (REST only).
- Report: /sandbox/stock/.superpowers/sdd/docs-tidy-up/report.md (create the directory).

## Task steps

- [ ] **Step 1: comments.** Survey `(*` comments in lib/*.ml, bin/bt.ml, test/test_bt.ml. Remove per the keep-set; record every removal (file:line, exact text, reason) in the report. Gate: `opam exec -- dune build && opam exec -- dune runtest --force` prints ok. Commit `chore: remove redundant comments`.
- [ ] **Step 2: changelog.** Mine `git log --reverse --format='%h %ad %s' --date=short` to date the six version waves from the spec's map and pick each wave's final commit for the tag target; record the map (version, date, commit) in the report. Rewrite CHANGELOG.md in strict keepachangelog 1.1.0 (preamble with format and SemVer statements, empty `[Unreleased]`, versions latest-first, only non-empty categories, human-readable entries, compare-link references against https://github.com/Forever-CodingNoob/bt). Salvageable narrative prose is copied aside into the report for Step 4's engine.md. `git add CHANGELOG.md` (first time tracked). Commit `docs: keepachangelog changelog`.
- [ ] **Step 3: CONTRIBUTING.** Rewrite per the spec's content list; verify each build/test command by running it. Commit `docs: renovate CONTRIBUTING`.
- [ ] **Step 4: engine guide.** Move README's "How the engine trades" into new docs/engine.md with the exact hierarchy: `## Core engine` (targets/drift, fill planner, equity accounting, end-of-data close), `## Taiwan market (tw)` (costs and taxes; margin financing; dividends; then `### Gap between simulation and the real market` covering the spec's TW list), `## United States market (us)` (costs; dividends; open-ended margin; then its `### Gap between simulation and the real market` per the spec's US list). Sources: README section, old CHANGELOG narrative (from the report), docs/strategy.md margin passages (leave a DSL-focused summary and a link there), the TW audit disclosures already in docs. Trim README to the spec's keep-list with a link to docs/engine.md. Commit `docs: extract engine guide`.
- [ ] **Step 5: structure and defaults.** Sweep docs/cli.md and docs/strategy.md into the header/alert structure; add the `Default` column to every cli.md option/argument table, moving defaults out of descriptions (no default = em dash). Verify every relative link across README.md, CONTRIBUTING.md, CHANGELOG.md, docs/*.md resolves (script the check). Commit `docs: restructure with alerts and defaults column`.
- [ ] **Step 6: releases.** Push main. Create annotated tags v0.1.0 through v0.6.0 at the mapped commits (`git tag -a vX.Y.0 <commit> -m "<version summary>"`), push tags. For each: `gh release create vX.Y.0 --prerelease --title "vX.Y.0" --notes "<that version's changelog section>"`. Confirm with `gh release list` (six prereleases) and record URLs in the report.

## Verification (coordinator repeats independently)

Suite green; link check clean; `gh release list` shows six pre-releases; audit-list spot check against the Step 1 diff.
