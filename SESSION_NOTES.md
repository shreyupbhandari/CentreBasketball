# Session Notes — Centre Basketball Analytics Work

This document captures everything done in one session of work on the Centre Basketball Lineup Analysis project: bugs found, what was tried, what worked, what didn't, and what's still outstanding. Intended as a context handoff for the next person (or session) to pick up where this left off.

The original `README.md` is the project's general overview and remains the starting point. This document is the **change log + decisions journal** for the deep work done on top of it.

---

## Session 2 update — full-dataset score reconciliation (June 2026)

**Headline:** systematic cross-school audit found a much broader set of bugs than the original Centre-only investigation revealed. Major fixes brought score reconciliation from ~60% perfect (across the full dataset, retroactively measured) to **98.9% perfect (2052 / 2075 games)**. Median gap dropped from ~14 pts to 0; mean gap from ~25 to 0.1.

### Headline diagnostics found across ALL schools × seasons

1. **Missing `tipin` and `two pointer` in the R loader case_when** — 232 made tipins (464 pts) and 68 made 2PTRs (136 pts) across the dataset were silently being scored as 0. Older Sidearm feeds (pre-2014) use `GOOD TIPIN by X` and `GOOD 2PTR by X` formats. Single-line fix; massive impact.

2. **2018-19 Sidearm HTML format change broke `Team` attribution** — affected 39 games across 5 schools, summing ~5,150 pts of mis-attribution. The 2018-19 HTML cells crammed both teams' plays into a single column; the Python parser's heuristic `data == df['homePlay'][i]` always fell through to the else-branch, labeling every row's `Team` as the away team. Detection signature: only one distinct Team value per CSV.

3. **`type_of_plays` list had a missing comma** between `'2ptr'` and `'steal'` in `getbasketballclean.py` (line 1436-1437). Python silently concatenated the strings into `'2ptrsteal'`. Result: `'steal'` was effectively absent from the list, and the `getPlayer` helper couldn't pull a player name for steal events OR for `GOOD 2PTR by X` plays. Knock-on: 2PTR rows had empty `Player`, which broke the score-delta-driven repair fallback for several games.

4. **Multi-game HTML contamination** — one 2018-19 file (`millsaps_oglethorpe_pbp_23.csv`) contained a SECOND game's PBP appended as Periods 3 & 4 (numPeriods=2 in header, max Period=4 in body). Likely a tournament-bracket page.

5. **Score-orientation swap** — a small cohort of games (e.g. `centre_2022-23_huntingdon`, `millsaps_2019-20_centenary`) have body data internally consistent but with home/away orientation inverted relative to the header (`finalScore` AWAY-HOME format). The fix uses finalScore as ground truth.

6. **`GOOD by [PLAYER]` plays with no shot-type token** — older Sidearm format (`GOOD  by GERALD,DUSTIN`) where the parser couldn't classify and the points went uncredited. ~10 affected files, ~20 pts.

### Tooling added

| File | Purpose |
|---|---|
| `MAT405basketballResearch/audit_scores.py` | Cross-school cross-season score reconciliation audit. Outputs master CSV + per-(school, season) summary. |
| `MAT405basketballResearch/patch_team_attribution.py` | Smart Team-column repair using per-row `homeTeamScore` / `awayTeamScore` deltas as ground truth. Handles both monotone-Team and home/away-swap corruption. Skip-regression safety: refuses to write when post-patch gap > pre-patch gap. |
| `MAT405basketballResearch/patch_extra_periods.py` | Detects + trims PBP rows that belong to a second game appended to the same CSV (Period > numPeriods, isOvertime=False, exact `finalScore` reached at end of last legitimate period). |
| `MAT405basketballResearch/patch_missing_playtype.py` | Backfills `playType` and `shotOutcome` on rows where the score delta confirms a scoring event but the parser couldn't classify the play text. |
| `MAT405basketballResearch/validate_pbp.py` | Per-game integrity check producing a confidence score (0..1) over 8 sanity tests. Writes a diffable manifest for regression-tracking. |

### Pipeline / parser changes — `getbasketballclean.py`

1. Fixed missing comma in `type_of_plays` list.
2. Added `_correct_team_from_score_deltas(df, home_name, away_name)` and hooked it into the cleanup pipeline alongside `_zero_phantom_possession_flags` / `_reattribute_phantom_lineups`. This makes the `Team` column self-healing: even when the original `homePlay`/`awayPlay` heuristic fails (as in 2018-19), the post-pass uses the box-score-derived `homeTeamScore`/`awayTeamScore` to attribute each row correctly and builds a player→team map for non-scoring rows.

### Loader / dashboard changes — `cenrebasketball.R`

1. Added `tipin` and `two pointer` to both `compute_lineup_metrics()` and `compute_subgroup_in_lineup_metrics()` case_when blocks AND to the `shot_types` vector (so they also count toward FGA/FGM rates).
2. Added `repair_team_attribution()` helper called from `load_pbp()` as a defence-in-depth check — fixes monotone-Team games on the fly even if the Python patcher hasn't been run yet against the CSVs.

### Result

Run `python3 MAT405basketballResearch/audit_scores.py` for the current state. Running totals after all fixes:

- **2052 / 2075 games (98.9%) reconcile EXACTLY** — pointsEarned from play stream equals box-score finalScore.
- **Mean gap 0.1, median gap 0** (was: mean ~14, median 3 before).
- **23 problem games remain**, summing 285 pts of unrecoverable gap. Breakdown:
  - **3 games = 243 pts (85% of residual)** — upstream HTML truncation or internal contamination beyond the scraper's reach (Rhodes 2018-19 Louisiana College: HTML has only 33 plays; BSC 2018-19 Millsaps: HTML has only one period; Rhodes 2012-13 Rust College: body has 38 extra pts in Period 1, source unclear without external box-score).
  - **20 games = 42 pts** — minor 1-6 pt residuals, mostly the rare unclassified play text or a single mis-attributed shot.

### Per-game validation manifest

`python3 MAT405basketballResearch/validate_pbp.py` produces `/tmp/pbp_validation.csv` with one row per game and an 8-check confidence score (R1-R8). Designed to:

- Catch regressions immediately when CSVs are regenerated.
- Surface low-confidence games for manual review.
- Auto-flag NEW Sidearm format quirks (R8 = unhandled scoring playTypes) so the parser case_when can be extended before silent data loss accumulates.

Currently: 2026 / 2075 games (97.6%) score 1.0 on every check. 2 games score below 0.75 (the upstream-truncated pair).

### CSV-level patches applied (one-shot, idempotent)

After regenerating CSVs via the Python pipeline, re-run:

```
python3 MAT405basketballResearch/patch_team_attribution.py
python3 MAT405basketballResearch/patch_extra_periods.py
python3 MAT405basketballResearch/patch_missing_playtype.py
```

Each is idempotent — running on an already-clean file is a no-op. They are safe to chain.

### Recommended ongoing process

1. Whenever the upstream scraper produces a new season's CSVs, run the three patchers (above) followed by `validate_pbp.py`.
2. Commit the validation manifest alongside the CSVs in git so confidence regressions show up as a diff.
3. If `validate_pbp.py` reports a new "R8 fail" (unhandled scoring playType), update the `SHOT_PTS` dicts in `audit_scores.py` + `validate_pbp.py` AND the case_when blocks in `cenrebasketball.R`.

---

## Session 2 follow-up — Centre 2023-24 lineup-tracking breakage

After the first round of fixes hit 98.9% CSV-level reconciliation, the user reported the dashboard was still showing missing points for 2023-24. Investigation found **a separate failure mode**: the CSVs reconcile perfectly against the box score, but **the R loader was dropping rows with NA lineup snapshots**, and the parser was silently producing those NA snapshots for hundreds of rows per game in 97 out of ~200 2023-24 games.

### Root cause

The parser's substitution loop compares raw player-name strings against the in-memory `home_lineup` / `away_lineup` lists. The same player can appear in the play stream under multiple spellings:

```
rasberry,jr.,darvis    (e.g. "GOOD FT by RASBERRY JR.,DARVIS")
rasberry jr,darvis     (e.g. "SUB IN by RASBERRY JR,DARVIS")
RASBERRY JR.,DARVIS    (raw case)
```

`player_name in home_lineup` then returns False for what's actually the same person. The sub event adds the player a second time. The lineup grows to 6 slots, the next sub event can't reconcile, and `expandColumn()` blanks every slot for every subsequent row.

In the Centre vs Hendrix 2023-24 game this happened ~halfway through Period 1; by Period 2 every row had `playerMissing=1` (260 of 263 rows). The R loader's old `playerMissing == 0` filter then dropped all of them — silently knocking 84 points out of the Centre score.

Per affected game: 1–84 attribution points lost. Across Centre 2023-24: **509 total points unattributed to any lineup**.

### Fixes applied

1. **Python parser (`getbasketballclean.py`).** Added `_normalize_player_key()` and switched the sub-event membership checks to compare on the normalized form. `'rasberry,jr.,darvis'` and `'rasberry jr,darvis'` now resolve to the same player. Future re-runs of the pipeline will track lineups correctly.

2. **R loader (`cenrebasketball.R::load_pbp`).** Stopped dropping rows with NA lineup slots or `playerMissing=1`. They're kept in the loader output so total scores remain correct; they naturally land in an NA-CentreLineup bucket that the per-lineup tables filter out (no change to those tabs' integrity).

3. **Dashboard totals footer (`render_totals_ui`).** Now shows three lines, in order:
   - **Totals across rows above** — sum from visible lineup table (per-lineup attributable). For games where lineup tracking broke, includes a warning span like `(509 / 0 unattributed to lineups — parser lost lineup state mid-game)`.
   - **Play-stream totals** — sum derived directly from `Team` + `playType` + `shotOutcome` on every row in the selected games, independent of lineup tracking. Matches the box score for every game whose play stream is complete.
   - **Actual final-score totals** — parsed from `finalScore` in `game_wanted()`. Same canonical reference as the Game Facts card.

   The diff line at the right reports `Play-stream vs. final-score` so the user immediately sees whether the play stream is itself complete or has upstream data loss.

### Verification

`MAT405basketballResearch/audit_loader.py` mirrors the dashboard's display logic and reports per-school per-season:

```
$ python3 MAT405basketballResearch/audit_loader.py --season 2023-24 --school centrecolonels
Audited 25 games (school=centrecolonels season=2023-24)
  Raw CSV perfect:                       25
  Play-stream totals match real:         25      ← what the dashboard now shows
  Lineup-attributable matches real:      15
  Games with UNATTRIBUTED points:        10  total pts: 509
```

All 25 Centre 2023-24 games now display the correct total score in the dashboard. The 509 pts that previously vanished are now visible in the "Play-stream totals" line; the warning span on the "Totals across rows above" line explains why some points can't be tied to a specific lineup.

### What's still left (and how to close it)

The lineup-attribution remains incomplete for those 10 games because the parser's broken substitution state can't be reconstructed from the saved snapshot columns alone — the missing 5th player isn't recorded anywhere. Two paths to close this:

1. **Re-run `getbasketballclean.py` for 2023-24.** With the new `_normalize_player_key()` in place, the parser will track lineups correctly end-to-end. After regeneration, run the three patchers + `validate_pbp.py` and the audit. Estimate: brings the dashboard's "Totals across rows above" line to match real for those 10 games.

2. **Heuristic lineup snapshot patcher (`patch_lineup_snapshots.py`).** Walks each broken period and re-derives the on-floor 5 from the play stream by following sub-in/sub-out events. Lower-quality than option 1 (may misattribute borderline cases) but doesn't require re-running the pipeline. Left as opt-in — run with `--dry-run` to preview before committing to it.

---

## Session 2 follow-up #2 — exhaustive lineup-tracking rebuild

Option 1 above was carried out for Centre 2023-24. Several **deeper, structural** parser bugs surfaced once the data flowed through cleanly. Cumulative improvement for Centre 2023-24:

| Step | Unattributed pts |
|---|---:|
| Initial (after the missing-name normalization fix) | 559 + 520 = **1079** |
| `audit_loader` corrected to check the SELECTED side's lineup only (not all 10 slots) | 139 |
| `_reattribute_phantom_lineups` switched to immediate-prior matching | 139 |
| `_reorder_sub_blocks` (within-clock OUT-before-IN reorder) | (Wilkes recovered) |
| `skip_line` cascade removed — failed subs now silently no-op | **39** |
| Sub-overflow guard (SUB IN with full lineup drops oldest) | **4** |

That's >99% recovery of the unattributed total for Centre 2023-24. The remaining 4 pts are spread across 2 games as 1-2 single-row residuals.

### New parser helpers / behaviour changes (`getbasketballclean.py`)

| Function | What it does |
|---|---|
| `_reorder_sub_blocks(df)` | Reorders consecutive sub events at the same clock so every SUB OUT precedes every SUB IN. Fixes "subs arrive IN before OUT" cases that briefly grow the lineup past 5 and trigger `expandColumn` blanking. |
| Multi-signal sub-event side detection | The play-loop's sub branch no longer relies on `data == df['homePlay'][i]`. Uses NaN-safe normalized comparisons against BOTH `homePlay` and `awayPlay`, then falls back to player-membership lookup, then to "which side is short of 5". Works for the 2018-19 single-column HTML format AND the 2023-24 misordered-sub format. |
| `skip_line` cascade removed | Old behaviour: when a sub event couldn't be applied, `skip_line=1` was set and the NEXT sub event was skipped to "rebalance". If a non-sub event (foul, timeout, etc.) intervened, the skip persisted incorrectly and blanked the lineup state for the rest of the game (Wilkes 2023-24 Period 2 was lost this way). New behaviour: failed subs silently no-op. |
| SUB IN overflow guard | When a SUB IN would push the target lineup past 5 (because an earlier SUB OUT no-op'd, leaving the lineup full), drop the oldest entry instead of overflowing. The new player is on the floor and the oldest entry was likely the one a previous SUB OUT meant to remove. Preserves snapshot integrity for every subsequent row. |
| Phantom-row immediate-prior pairing (`_reattribute_phantom_lineups`) | Old: greedy FIFO chronological pairing across the period — caused phantom rows mid-period to inherit the lineup from a different shot earlier in the period (rows 56 in Centre vs Huntingdon 2023-24 showed the wrong 5). New: walk backwards from the phantom to find the IMMEDIATELY preceding real shot of the matching outcome; only fall back to FIFO for end-of-period phantoms with no adjacent shot. The phantom-shot type set was also expanded to `{layup, jumper, three pointer, dunk, free throw, tipin, two pointer}` so missed-FT-followed-by-team-rebound phantoms match correctly. |
| `_normalize_player_key(name)` | Canonical key for membership checks. `rasberry,jr.,darvis` and `rasberry jr,darvis` reduce to the same string so substitution events recognize the same player across spelling variants. |

### After regeneration, validate with

```bash
python3 MAT405basketballResearch/getbasketballclean.py        # rerun pipeline (all 7 schools × 14 years; ~30 min)
python3 MAT405basketballResearch/patch_team_attribution.py    # re-apply team patches
python3 MAT405basketballResearch/patch_extra_periods.py
python3 MAT405basketballResearch/patch_missing_playtype.py
python3 MAT405basketballResearch/audit_scores.py /tmp         # CSV-level audit
python3 MAT405basketballResearch/audit_loader.py --season 2023-24 --school centrecolonels   # dashboard-view audit
python3 MAT405basketballResearch/validate_pbp.py              # confidence manifest
```

For incremental work (one school × one season), pass `--school` and `--season` flags to the patchers and audit. The `makeHeaderPBP(sport, school, year_str)` helper can be imported and called directly for a single season:

```python
from getbasketballclean import makeHeaderPBP
makeHeaderPBP('mens-basketball', 'centrecolonels', '2023-24')
```

### Full-dataset regeneration completed

After the parser fixes above were verified on Centre 2023-24, the full pipeline was rerun against every school × year (~2,500 games, ~13 minutes). Results across the dataset:

| Metric | Value |
|---|---:|
| CSV-level score reconciliation perfect | **2052 / 2075 (98.9%)** |
| Validation manifest confidence == 1.0 | 2026 / 2075 (97.6%) |
| Home-perspective lineup-attribution perfect | 1330 / 2075 (64.1%) |

Lineup-perfect percentage trends UPWARD over time as the source HTML format stabilized:

| Season | Lineup-perfect % |
|---|---:|
| 2023-24 | **91.6%** |
| 2022-23 | 86.7% |
| 2021-22 | 83.3% |
| 2019-20 | 83.3% |
| 2018-19 | 59.0% |
| 2015-16 | 30.1% |
| 2014-15 | 43.1% |

For Centre specifically (the dashboard's primary lens):

| Season | Games | Perfect | Unattributed pts |
|---|---:|---:|---:|
| 2023-24 | 25 | **23** | **4** |
| 2022-23 | 26 | **25** | **4** |
| 2021-22 | 20 | 18 | 30 |
| 2019-20 | 26 | 21 | 46 |
| 2018-19 | 26 | 19 | 54 |
| 2017-18 | 25 | 11 | 101 |
| 2015-16 | 25 | 6 | 426 |

Centre 2023-24 unattributed dropped from the user-reported **559 / 520 (= 1079)** to **4 total**. The play-stream-derived game-total line in the dashboard correctly matches the box score for every game, since the underlying CSV reconciliation is at 98.9%.

The older seasons (2012-13 through 2017-18) still have non-trivial lineup-attribution gaps because the older Sidearm HTML format had several parser-defeating quirks. Closing those would require additional parser work targeted at season-specific HTML variations — left as future work since the dashboard's score TOTALS are already correct from the play stream.

---

## Session 2 follow-up #3 — possession counter undercount → inflated OFFRTG

User reported some lineups showing OFFRTG > 200 in the dashboard. Investigation found the possession counter was undercounting by ~15-20% per game, inflating OFFRTG by the same factor.

### Three bugs in `posschange()` / `update_play_types()`

1. **`update_play_types` had an UNBOUNDED forward scan.** It was supposed to revert `LAST FT MADE` → `GOOD FT` for and-one situations where the marked FT wasn't actually the last. But it walked the rest of the game looking for ANY `MISS FT` followed by ANY `FOUL` and reverted as soon as the pair appeared anywhere downstream. Since basketball games always have several missed FTs followed by fouls, this triggered constantly and incorrectly — dropping ~80% of free-throw-triggered possession changes. The revert is now bounded to the current "trip to the line" (stops at the first row that isn't `FT` / `FOUL` / `SUB` / `TIMEOUT`).

2. **`GOOD TIPIN` and `GOOD 2PTR` weren't in the `made_shots` / `change_poss` lists.** Those scoring plays (used in older Sidearm formats and a few 2023-24 games) failed to end possessions — adding 2 pts to the team's score but no possession to the denominator.

3. **The first row of each period had `possStart=0`.** The base loop only marks possession STARTS as transitions FROM a previous row; the very first play of a period was never marked. Cost ~2 possessions per game.

Added `_mark_period_starts()` to run AFTER `assign_teams` so it doesn't shift who has the ball — it just credits the first row of each period with the +1 possession count it deserves.

### Centre 2023-24 verification

| Metric | Before | After |
|---|---:|---:|
| Mean OFFPOSS per game | 59.6 | **67.8** |
| Mean per-game OFFRTG | 121.6 | **106.4** |
| Per-lineup median OFFRTG (≥10 possessions) | — | 110 |
| Lineups (≥10 poss) with OFFRTG > 150 | many | **3 of 36** |

For meaningful sample sizes (lineups with ≥10 possessions), the OFFRTG distribution is now centered at ~110 — exactly the D3 norm. Lineups still showing OFFRTG > 200 in the dashboard have OFFPOSS of just 2-5 — mathematically valid but statistically meaningless. The `min_poss` filter in the sidebar handles those.

The CSV-level reconciliation didn't regress: 2052 / 2075 perfect (98.9%) unchanged. The fix only affects possStart counts (the OFFRTG denominator), not pointsEarned (the numerator).

---

## Session 2 follow-up #4 — Top Lineups filter + unattributed-pts warning

Two dashboard-side issues surfaced after the possession fix above.

### 1. `TOTAL_POSS >= min_poss` was the wrong gate for OFFRTG

Top Lineups was filtering by `TOTAL_POSS >= min_poss`, but `TOTAL_POSS = OFFPOSS + DEFPOSS`. So a 13-OFFPOSS / 13-DEFPOSS lineup (26 TOTAL_POSS) passed a "min 20 possessions" gate and could appear at the top of the OFFRTG leaderboard with a 192.3 figure backed by just 13 offensive possessions.

Fixed: the gate is now metric-aware in `output$topFiveLineups`. Pure-side ratings (OFFRTG, AST_RATIO, AST_TO, TOV_PCT, OREB_RATE, FG_PCT, FG3_PCT, EFG_PCT) gate on OFFPOSS. DEFRTG and DREB_RATE gate on DEFPOSS. Multi-side metrics (NETRTG, PACE, plus_minus) keep the TOTAL_POSS gate.

After the fix, the Top Lineups Centre 2023-24 OFFRTG leaderboard at min_poss=20:

| Rank | OFFPOSS | OFFRTG |
|---|---:|---:|
| 1 | 23 | 152.2 |
| 2 | 24 | 138 |
| 3 | 47 | 134 |

No more 192.3 outlier; all entries have at least 20 actual offensive possessions.

### 2. "Unattributed" warning conflated two distinct causes

The lineup-table footer in Player Tables / Lineups in Game showed a warning like:

```
(761 / 776 unattributed to lineups — parser lost lineup state mid-game)
```

That message was misleading. The big number was almost entirely **valid lineups hidden by the `min_poss` filter**, not parser issues. Investigation of Centre 2023-24 with `min_poss=20`:

| Component | Centre side | Opp side |
|---|---:|---:|
| Lineups below min-poss filter | 759 | 774 |
| Rows where parser lost lineup state | **2** | **2** |
| Total unattributed | 761 | 776 |

Fixed: the warning now splits the two causes and labels each explicitly. Example after the fix:

```
(759 / 774 in lineups below the min-possessions filter; 2 / 2 in rows where the parser lost lineup state)
```

The user can immediately see that the bulk is just min_poss filtering — adjusting that slider brings those points back into view.

### Followup — full per-side gate everywhere, slider relabeled

The metric-aware gate was extended to ALL lineup-display tabs and the sidebar slider relabeled accordingly:

- **Sidebar label**: changed from "Min total possessions (OFF + DEF) per lineup" to **"Minimum possessions per side"**. The new label matches the actual behavior under the new gates.
- **Top Lineups**: pure-side metrics gate on OFFPOSS / DEFPOSS; **NETRTG and plus_minus require BOTH OFFPOSS AND DEFPOSS** ≥ min_poss; PACE keeps the TOTAL_POSS gate (combined sample is the right denominator there).
- **Player Tables** and **Lineups in Game**: lineup rows are shown when `OFFPOSS ≥ min_poss AND DEFPOSS ≥ min_poss` — both sides must have a meaningful sample because the row displays BOTH OFFRTG and DEFRTG simultaneously.
- **Group Performance**: same metric-aware gate as Top Lineups.
- **Player Combination**: same metric-aware gate as Top Lineups, applied to the N-player subgroup.

### Effect on Centre 2023-24

| View | Before (TOTAL_POSS ≥ 20) | After (per-side ≥ 20) |
|---|---:|---:|
| Top OFFRTG lineup | 192.3 (13 OFFPOSS) | 152.2 (23 OFFPOSS) |
| Top NETRTG lineup | 192.3 OFFRTG, ?? NETRTG | 27.3 NETRTG (22/23 split) |
| Player Tables lineup count | 32 | 17 |

The Player Tables count drops because the new gate is strictly more demanding — but the rows that remain are all statistically meaningful on both sides of the floor.

---

## Session 2 follow-up #5 — 2024-25 / 2025-26 seasons + two new SAA schools

Professor delivered a fresh SAA folder containing 2024-25 and 2025-26 seasons for every existing school plus two newly-added conference members: **southwesternpirates** and **trinitytigers**.

### Pipeline updates

1. **`schools` list** in `getbasketballclean.py` extended to include `southwesternpirates` and `trinitytigers`. `saa_teams` likewise.
2. **`end_year = 2025`** so the iteration covers the new seasons.
3. **Generic `MISS by X` plays** — newer Sidearm format emits `MISS  by ROBINS,JARED` (no shot-type word). The play loop's `else:` branch was appending an empty string to `Team`, and `assign_teams()` later crashed with `UnboundLocalError: team1 not assigned` because `teamName[0] == ''` matched neither home nor away. Fixed both:
   - The `else` branch now classifies "miss by X" as `playType='shot'` with `shotOutcome='missed'` and assigns Team via the homePlay/awayPlay split with reasonable fallbacks.
   - `assign_teams()` now walks `teamName` to find the first non-empty match instead of relying on `teamName[0]`, and falls back to the away team when nothing matches — eliminating the crash class entirely.
4. **`Tables/` (capital T)** in the new folder structure — macOS APFS is case-insensitive so no code change needed.

### Results across the full updated dataset

| Metric | 2,470 games (full dataset incl. new seasons) |
|---|---:|
| CSV-level score reconciliation perfect | **2446 (99.0%)** |
| Validation manifest confidence 1.0 | 2411 (97.6%) |
| Lowest-confidence games | 2 (the unrecoverable HTML-truncation pair from 2018-19) |

### Per-season for Centre (the dashboard's primary lens)

| Season | CSV-level | Dashboard view |
|---|---|---|
| **2025-26** | **23/23 perfect** | **22/23 perfect, 13 unattributed pts** |
| **2024-25** | **24/24 perfect** | **24/24 perfect, 0 unattributed pts** |
| 2023-24 | 25/25 perfect | 23/25 perfect, 4 unattributed |
| 2022-23 | 26/26 perfect | 25/26 perfect, 4 unattributed |

The new seasons reconcile essentially perfectly out of the box — the parser improvements landed in time, and the 2024-25 Sidearm HTML format is consistent with 2022-23+ so no further parser tuning was required.

### New schools

- **southwesternpirates**: 25 games (2024-25) + 27 games (2025-26)
- **trinitytigers**: 27 games (2024-25) + 27 games (2025-26)

Both schools' games reconcile cleanly at the CSV level. They'll appear automatically in the dashboard's Team picker once the season picker is set to 2024-25 or 2025-26, since the team list is derived from the loaded play stream.

---

## Table of contents

1. [Pipeline at a glance](#pipeline-at-a-glance)
2. [R Shiny dashboard — features added](#r-shiny-dashboard--features-added)
3. [Python pipeline fixes](#python-pipeline-fixes)
4. [R loader fixes](#r-loader-fixes)
5. [Things tried that didn't work (and were reverted)](#things-tried-that-didnt-work-and-were-reverted)
6. [Outstanding work — total-score discrepancies](#outstanding-work--total-score-discrepancies)
7. [Diagnostic scripts from the session](#diagnostic-scripts-from-the-session)
8. [Files and helpers reference](#files-and-helpers-reference)
9. [Adding new seasons (2024-25, 2025-26, ...)](#adding-new-seasons-2024-25-2025-26-)

---

## Pipeline at a glance

```
SAA/<school>/HTML/<season>/                ← raw HTML (Sidearm box-score pages)
SAA/<school>/headers/<season>/             ← per-game header CSVs (game metadata)
SAA/<school>/tables/<season>/              ← per-game play-by-play table CSVs
            │
            ▼  MAT405basketballResearch/getbasketballclean.py
            │  + MAT405basketballResearch/html_parsers.py
            ▼
SAA/<school>/pbp/<season>/                 ← clean per-game CSVs (the analytical data)
            │
            ▼  MAT405basketballResearch/cenrebasketball.R
            ▼
Shiny dashboard
```

The Python step (`getbasketballclean.py`) runs once per scrape. The R Shiny app reads the pbp CSVs on demand and presents an interactive UI.

### Important caveats about the source data

- **`finalScore` is `"AWAY-HOME"`** — verified empirically. Got the parsing backwards in early diagnostics. Many places now depend on this.
- **`possPoints` is unreliable.** The Python pipeline's running-tally approach systematically loses points — when summed per game it matches the real final score in **0 of 25 games** in 2023-24. The R loader's `compute_lineup_metrics` now derives points directly from `playType` + `shotOutcome` instead.
- **`secondsPerPoss` is unreliable.** Only filled in for ~half of possessions. The R loader derives `elapsed_sec` per row from `timeRemaining` clock deltas instead.
- **`Team` column is who took the action.** `possTeam` is who has the ball. They diverge for things like defensive rebounds (action by defending team, but possession just changed).

---

## R Shiny dashboard — features added

### Tabs (current state)

| Tab | What it shows | Driven by |
|---|---|---|
| **Player Tables** | One row per distinct 5-man lineup containing every selected player | Sidebar player picker |
| **All Data** | Raw play-by-play rows (away and home views) | Sidebar player picker |
| **Lineups in Game** | Every 5-man lineup the selected team ran in the chosen games | Sidebar games |
| **Top Lineups** | Top N 5-man lineups by chosen metric, with `min_poss` gate | Metric radio + N input |
| **Group Performance** | 5-man lineups containing the 3 auto-picked anchors (most-played players) | Auto-anchored from data |
| **Player Combination** | One row per N-player subgroup (N∈{1,2,3,4}); stats pooled across every lineup containing the subgroup; **action stats credited only to subgroup members** | Group-size dropdown + metric |

### Sidebar inputs (top to bottom)

- **Season** — auto-detected from `pbp/<season>/` directories. New seasons appear automatically.
- **Team** — auto-populated from selected season's data, normalized (24 Centre variants collapse to one entry).
- **Game(s)** — multi-select with search box + select-all/deselect-all. Multi-game is OK; rows aggregate across selection.
- **Player(s)** — multi-select, **cascading**. After picking one, the choices narrow to teammates who've shared the floor. After picking three, only teammates who played with all three remain.
- **Reset lineup** button — clears player selection; cascade observer restores the full roster automatically.
- **Min total possessions** filter — gate for lineup-aggregated tabs.

### Main panel — Game Facts card (always visible)

A yellow-bordered card at the top showing date, matchup, location, final score, and total points scored for each selected game. Reads `game_wanted()` directly.

### Totals row under lineup tables

Below **Player Tables** and **Lineups in Game**, a footer line:

```
Totals across rows above: Centre scored 72, opponent scored 63.
Actual final-score totals: Centre 72, opponent 63 (diff +0 / +0).
```

For complete play-stream games the diffs are `+0`. For partial-data games the diff makes the data quality gap visible immediately.

### Metric library — `compute_lineup_metrics()`

One shared aggregator produces every rate stat the dashboard exposes:

| Metric | Formula | Notes |
|---|---|---|
| OFFRTG | `pointsEarned / OFFPOSS * 100` | per-100-possession |
| DEFRTG | `pointsAgainst / DEFPOSS * 100` | lower better |
| NETRTG | `OFFRTG - DEFRTG` | |
| plus_minus | `pointsEarned - pointsAgainst` | |
| OREB_RATE | `OFFREB / (OFFREB + opp_DEFREB) * 100` | % of available OREB chances grabbed |
| DREB_RATE | `DEFREB / (DEFREB + opp_OFFREB) * 100` | |
| FG_PCT | `FGM / FGA * 100` | excludes free throws |
| FG3_PCT | `FG3M / FG3A * 100` | |
| EFG_PCT | `(FGM + 0.5*FG3M) / FGA * 100` | weights 3PT properly |
| TOV_PCT | `TOV / OFFPOSS * 100` | possession-based; lower better |
| AST_TO | `ASSISTS / TOV` | classic ratio |
| AST_RATIO | `ASSISTS / OFFPOSS * 100` | preserved for parity |
| PACE | `TOTAL_POSS / 2 * 40 / (TIME_SEC / 60)` | per-40-min, D3 game length |
| TIME_MIN | `TIME_SEC / 60` | from `elapsed_sec`, not `secondsPerPoss` |

All non-finite values (NaN from divide-by-zero) coerced to `NA_real_` so sorts and displays behave.

### Player Combination tab — iteration history

This tab went through four iterations as the user clarified what they wanted. Documenting the trail in case you need to undo or re-pivot.

| Version | What it showed | Verdict |
|---|---|---|
| v1 | All 5-man lineups containing the picked players, with an "Others" column highlighting the varying slots | "not what I meant" |
| v2 | Enumerated every theoretical 5-man combo containing the picks, including unplayed ones with NA stats | "revert" |
| v3 | Per-lineup breakdown — one row per (subgroup, full lineup) pair, with the full lineup's metrics | "I want the subgroup's own metrics, not the lineup's" |
| **v4 (current)** | One row per N-player subgroup, **pooled** across every lineup containing them, with action stats credited only to the subgroup's members | What the user wanted |

Key design rule for v4: action stats (FG, 3PT, TOV, AST, OREB, DREB, pointsEarned) are gated on `Player ∈ subgroup`. Lineup-level stats (OFFPOSS, DEFPOSS, TIME, PACE, DEFRTG, pointsAgainst) are NOT gated — the subgroup was on the floor for all of them. Hybrid rates like OFFRTG use subgroup numerator over lineup denominator.

### Visual styling

Title bar uses Centre branding (black + gold #f1cc2c). Custom dark-theme CSS for picker dropdowns. The Top Lineups blue-button styling was tried and **reverted** — the default `shinytheme("sandstone")` is in use everywhere.

---

## Python pipeline fixes

Seven distinct fixes to `getbasketballclean.py` and `html_parsers.py`, ordered roughly by impact.

### Fix 1: Phantom row handling (`_zero_phantom_possession_flags`)

**Symptom:** Top lineup OFFRTG was 228 — physically impossible (2.28 PPP).

**Root cause:** Each game's CSV has two row classes:
- **Real plays** — `timeRemaining = "MM:SS"`.
- **Phantom rows** — `timeRemaining = "--"`, appended at the END of each period as a box-score-summary block that annotates rebounds and assists.

The Python possession tracker ran `posschange()` / `assign_teams()` / `team_change_indicator()` / running `possPoints` over **every** row, including phantom. That produced a second parallel possession sequence; summing `possPoints` on `teamChanged==1` double-counted real possessions.

**Fix:** `_zero_phantom_possession_flags(df)` zeros `possStart` / `teamChanged` / `possPoints` on every row whose `timeRemaining` isn't `MM:SS`. Phantom rows still carry their `ASSIST` / `OREB` / `DREB` indicators (we want those); they just stop contributing to possession arithmetic.

**Result:** Top OFFRTG 228 → 122. All ratings in realistic D3 ranges.

### Fix 2: Phantom row lineup re-attribution (`_reattribute_phantom_lineups`)

**Symptom:** Assists and rebounds attributed to the wrong lineup.

**Root cause:** Phantom rows are appended after every period's real plays. The lineup snapshot for each phantom row is the **end-of-period** lineup, not the lineup that was actually on the floor when the assist or rebound happened.

**Fix:** `_reattribute_phantom_lineups(df)` walks every phantom row and copies the lineup from the matching real play row:
- **ASSIST phantom** → next unmatched made-shot real row in same period.
- **OREB / DREB phantom** → next unmatched missed-shot real row in same period.
- Greedy chronological pairing per period.

Runs right before `expandColumn(df)` so corrected lineups propagate into `homePlayer1..5` / `awayPlayer1..5`.

### Fix 3: Jersey-stripped starter names (`html_parsers.py`)

**Symptom:** HuntingdonCentre 11/19/23 and LaGrangeCentre 11/18/23 captured only 2-5 of the 80+ points actually scored. ~90% of rows dropped by R's `playerMissing` filter.

**Root cause:** The HTML player tables for these two games embedded jersey numbers inside player names: `'3,moore,chez'`, `'5,baughman,carter'`, `'gardner,2'`, `'scott,5'`. Plays referenced players with normal `'moore,chez'` strings — sub-event matcher couldn't find them in the lineup, sub events failed, lineup state drifted past 5 players, `expandColumn` blanked every subsequent row.

**Fix:** `_strip_jersey()` helper:

```python
name = re.sub(r'^\d+,', '', name)   # "3,moore,chez" -> "moore,chez"
name = re.sub(r',\d+$', '', name)   # "gardner,2"    -> "gardner"
```

Called inside `_normalize_starter_name()` and the older-HTML-format path in `parse_starters()`.

### Fix 4: `expandColumn` over-5 lineup corruption

**Symptom:** Rows with `playerMissing == 0` AND lineup columns containing the literal string `"None"`. R's `is.na()` doesn't catch strings, so these rows slipped past every downstream filter.

**Root cause:** In `expandColumn`:

```python
df['homeLineup'] = df['homeLineup'].apply(
    lambda x: x + [None]*(5 - len(x)) if len(x) <= 5 else ['None']*5)  # ← bug
```

When the lineup state had **more than 5 players** (drift from a bad sub), the `else` wrote the **literal string** `'None'` into all 5 slots. `pandas.isna()` doesn't catch strings, so `playerMissing` said "all 5 slots are valid."

**Fix:** Changed `['None']*5` to `[None]*5` (real Python `None`). Now corrupted rows correctly raise `playerMissing = 1` and get dropped by the R loader.

### Fix 5: First-name recovery from play stream

**Symptom:** Even after Fix 3, LaGrange's home-team lineup tracking was still broken. Starter table had `scott,5` → stripped to `scott`. Plays referenced `SCOTT,BRODIE` → extracted as `scott,brodie`. String inequality: `scott != scott,brodie`. Sub events still failed.

**Root cause:** The source HTML player table substituted jersey numbers **for first names** entirely (not just adding them as prefix/suffix). Fix 3 strips the jersey but can't invent a missing first name.

**Fix:** `_build_name_recovery_maps(df)` walks the play stream once, extracts each player's full name via `getPlayer()`, and builds two `last_name → "lastname,firstname"` maps (one per team) from what the plays actually use. Then `_upgrade_lineup_names(lineup, name_map)` replaces any last-name-only lineup entry with the full canonical form.

Applied right after starter parsing in the main loop:

```python
away_name_map, home_name_map = _build_name_recovery_maps(df)
away_lineup = _upgrade_lineup_names(away_lineup, away_name_map)
home_lineup = _upgrade_lineup_names(home_lineup, home_name_map)
```

**Result:**
- HuntingdonCentre: gap `−82 / −73` → `−6 / −3`. Almost full recovery.
- LaGrangeCentre: gap `−75 / −81` → `−16 / −33`. Substantial recovery.
- 16/25 games still match exactly. No regressions.

### Fix 6: Conditional period-boundary lineup reset

**Symptom:** CentreWilkes 12/28/23 captured only Period 1 — all 221 Period 2 rows dropped. Total game time tracked: 19.2 min vs 40 expected.

**Root cause:** Two compounding issues:
1. By end of P1, Wilkes's Centre lineup state had drifted to only 3 players (sub events that didn't balance).
2. The Wilkes feed has **no explicit "starter" events** at the start of P2 — most games include them so the lineup re-initializes, but this one doesn't.

So P2 inherited the broken 3-player state. Every P2 row had at least 2 `None` slots → all P2 rows dropped.

**Fix:** `_infer_period_starters(df, start_idx, period, side)` walks forward from a given index within a period, collects the first distinct players who appear in **on-court actions** (skip `sub in` events — they imply the player wasn't on the floor), stops at 5 names.

Hooked into the main play loop as a **conditional** reset:

```python
if cur_period != prev_period:
    if len(home_lineup) != 5:   # only when state is BROKEN
        re-infer from upcoming plays
    if len(away_lineup) != 5:
        re-infer from upcoming plays
```

**Important — what didn't work first:** Initial cut was unconditional (reset every period boundary). That **regressed 12 previously-perfect games** because most halftimes don't change the lineup; the 5 who finish P1 also start P2. Inference picked up players who later came in via sub. Making the reset conditional (only fires when state has fewer than 5 players) preserved all previously-correct games while fixing the genuinely broken ones.

**Result:** Wilkes minutes captured 19.2 → 30.9; gap `−30 / −33` → `−23 / −23`. No regressions.

### Fix 7: Pandas string-dtype assignment guard

**Symptom:** `getbasketballclean.py` was crashing with `TypeError: Invalid value '0' for dtype 'str'` inside `_zero_phantom_possession_flags`.

**Root cause:** Pandas' newer string-dtype columns reject integer assignment. The pipeline's possession columns sometimes landed as string-typed; assigning `df.loc[...] = 0` failed.

**Fix:** Coerce to numeric first inside the helper:

```python
df[col] = pd.to_numeric(df[col], errors='coerce').fillna(0)
df.loc[~real, col] = 0
```

---

## R loader fixes

### Adaptive phantom-row handling

`load_pbp()` auto-detects whether a CSV was produced by the **old** Python pipeline (phantom rows still carry `possStart=1` / `teamChanged=1`) or the **new** one (phantom rows have those flags zeroed by Fix 1).
- Old CSVs → drop phantom rows entirely (fixes ratings, loses assist/rebound counts).
- New CSVs → keep them (post-pipeline-fix, attribution is correct).

### Clock-derived time (`add_elapsed_seconds`)

`secondsPerPoss` from the source CSV is unreliable — only filled in for ~half of possessions. Summing it across one game totaled 1191 sec against an expected 2400.

`add_elapsed_seconds(df)` derives `elapsed_sec` per row from `timeRemaining` deltas (parse `"MM:SS"`, group by `gameID × Period`, forward-fill NA clock values, compute `previous - current`). Substitution rows have 0 elapsed (clock stopped). Validated: per-game elapsed sums to ~2393 sec for a 40-min game.

`compute_lineup_metrics()` uses `elapsed_sec` everywhere. **PACE went from a fictional 26-509 range (median 315) to a realistic 27-81 range (median 58).**

### Team-name normalization (`normalize_team`)

Across older seasons, the same team appears under multiple labels:

```
Centre, Centre College, Centre College (KY), #13 Centre, Centre Men,
CENTRE_M, CENTREM, CENTRE-M, CENTREMB, CENTRE~1, and lowercase variants
```

`normalize_team(x)` does:

1. Strip AP rank prefix (`#13 Centre` → `Centre`).
2. Strip trailing parenthetical (`Centre (Ky.)` → `Centre`).
3. Strip DOS 8.3 truncation (`CENTRE~1` → `CENTRE`).
4. Strip separator-prefixed gender code (`CENTRE_M` → `CENTRE`).
5. Title-case single-case strings (`CENTRE` → `Centre`, `birmingham-southern` → `Birmingham-Southern`).
6. Strip trailing `" Men"` / `" Women"`.
7. Apply Centre-specific alias table for residual oddities (`Centre College`, `Centrem`, `Centremb` → `Centre`).

Applied to `homeTeam` / `awayTeam` directly; applied to `Team` / `possTeam` + `tolower()` (lowercase form). All 24 known Centre variants collapse to one canonical `Centre`. **Non-Centre teams are left untouched if there's any ambiguity** — safety bias.

### Points calculation rewrite (the big one)

**Symptom:** Pipeline's `pointsEarned` (`sum(possPoints where possTeam==selected & teamChanged==1)`) matched the actual final score for **0 of 25 games** in 2023-24. Mean undercount: 48 points per game.

**Root cause:** The Python pipeline's running-tally approach (`calculate_possession_points` + `team_change_indicator`) is systematically broken. The play stream itself (`playType` + `shotOutcome`) is reliable for 16 of 25 games.

**Fix:** Rewrote `compute_lineup_metrics()` to compute `pointsEarned` directly from the play stream:

```r
.row_pts = case_when(
  is.na(shotOutcome) | shotOutcome != "good" ~ 0,
  playType == "three pointer"                ~ 3,
  playType %in% c("layup","jumper","dunk")   ~ 2,
  playType == "free throw"                   ~ 1,
  TRUE                                       ~ 0
),
pointsEarned  = if_else(coalesce(Team == lt, FALSE), .row_pts, 0),
pointsAgainst = if_else(coalesce(!.is_team_act & !is.na(Team) & Team != "", FALSE),
                        .row_pts, 0)
```

**Result:** 16/25 games now reconcile exactly to the box score.

### Other R-side bugs fixed

- **`output$summary` was returning a tibble** to `renderText`. Now formats with `sprintf` showing OffRtg / DefRtg / NetRtg / +- / OffPoss / DefPoss / Ast / AstRatio / OREB% / DREB% / minutes.
- **`full_join` type collisions across game CSVs.** Original loader stacked games via `full_join` but only coerced `attendance` to integer — and only from the second file onward. If file 1 had `"N/A"` (character) and file 2 had a number, the join blew up. Rewrote to `bind_rows(lapply(files, read.csv, colClasses = "character"))` then coerce specific numeric columns.
- **`1:n()` over zero rows.** Player picker offered a "possible" 3-player lineup that had no co-floor row data → `mutate(CentreLineup = sapply(1:n(), ...))` evaluated `1:0 = c(1, 0)` and crashed on `awayTeam[0]`. Replaced with vectorized `build_lineup()`.
- **"None None None None None" phantom lineups in the leaderboard.** Python pipeline (pre-Fix 4) wrote `'None'` strings into corrupted lineups. R loader maps `"None"` and `""` to `NA` and drops rows whose lineup is incomplete.
- **Reset button didn't actually reset.** Was making two `updatePickerInput` calls (choices, selection) in quick succession; cascade observer fired right after — three updates, last-one-wins races. Simplified to one call (clear selection); cascade restores the full roster on its own.
- **`min_poss` filter on Player Tables.** Initially removed (so low-sample picked lineups still appear), then re-added per user request. Now consistent across all aggregated tabs.

---

## Things tried that didn't work (and were reverted)

Documenting these so future work doesn't relitigate them.

### Unconditional period-boundary lineup reset

Tried as the initial cut of Fix 6. Reset the lineup at every period change unconditionally. This **regressed 12 previously-perfect games** because most halftimes don't change the lineup. Replaced with conditional reset (only fires when state has fewer than 5 players).

### Cap lineup growth at 5 in sub-handling loop

Tried as part of the LaGrange/Huntingdon fixes — added `if len(home_lineup) < 5: home_lineup.append(player_name)` to prevent over-5 corruption. Regressed games like MillsapsCentre 01/07 (was 81/81 → became 29/29) because some games legitimately have brief lineup overflows during normal sub processing that resolve cleanly within a few events. Reverted; relying on Fix 4 (Python `None`) instead.

### Blue button styling on Top Lineups tab

Tried adding `status = "primary"` + custom CSS to color the radio buttons `#0072B8`. User said "doesn't look good" — reverted to default `shinytheme("sandstone")` styling.

### Hardcoded anchor variants for Player Combination tab

Tried v1 (lineups with picks + "Others" column), v2 (theoretical combinations including unplayed), v3 (per-lineup breakdown with full lineup metrics). All three were rejected before settling on v4 (pooled subgroup-credited stats). See [Player Combination iteration history](#player-combination-tab--iteration-history) above for details.

### Game-facts as part of the player picker

Considered adding game-info as a sidebar element. Instead became a dedicated top-of-main-panel card (better visibility).

---

## Outstanding work — total-score discrepancies

**This is where remaining effort would have the most impact.** Out of 25 Centre 2023-24 games (after all fixes above):

- **15 games** reconcile exactly with the box score (`gap = 0 / 0`).
- **1 game** has a 1-point opponent gap (essentially perfect).
- **9 games** have moderate to large gaps.

### Per-game state (latest pipeline run)

```
game                              centre_real  centre_pts  Δ    opp_real  opp_pts  Δ    rows  min
─────────────────────────────────────────────────────────────────────────────────────────────────
HendrixCentre 01/26               71           32          -39  79        34       -45  213   27.8
CentreHamline 12/30               69           41          -28  68        23       -45  192   25.7
CentreFranklin 11/28              95           59          -36  85        57       -28  249   34.4
CentreWilkes 12/28                53           23          -23  56        23       -23  216   30.9
RhodesCentre 01/28                72           35          -37  63        37       -26  266   39.6
CentreHendrix 01/19               75           42          -33  56        31       -25  259   39.3
LaGrangeCentre 11/18              77           61          -16  87        54       -33  255   29.0
OglethorpeCentre 02/11            66           49          -17  69        50       -19  263   27.9
HuntingdonCentre 11/19            87           81          -6   81        78       -3   426   39.7
CentreBirmingham-So. 02/02        77           77          0    65        64       -1   406   39.2
```

(The 15 perfect games are omitted — their Δ is 0 / 0.)

### Diagnosed root causes

All 9 problem games share a **common symptom**: row counts in the 175–270 range vs ~380–450 for healthy games. **The play stream itself is incomplete for these games** — not a math bug, data loss.

Three plausible categories:

#### A. HTML pagination / truncation (most likely for worst cases)

**Symptom:** game-clock minutes captured is much less than 40. CentreHamline (25.7 min), HendrixCentre (27.8 min), OglethorpeCentre (27.9 min), LaGrange (29.0 min).

**Hypothesis:** Sidearm pages may split the play-by-play across multiple HTML sections (a script-rendered "load more" or a `<section id="play-by-play-period-2">` the parser doesn't pick up). Current scraper consumes only one section.

**Investigation steps:**
- Open `SAA/centrecolonels/HTML/2023-24/centre_mens-basketball_2023-24_5775_wilkes.html` (or similar) in a browser.
- Look for multiple `<section>` blocks for play-by-play.
- Look for JavaScript-driven content that only renders on interaction.
- Look for a second `<table>` element following the main one.

**Possible fix:** update the table-extraction step (whatever produces `SAA/.../tables/<season>/*_table_*.csv`) to consume all PBP tables.

#### B. Within-period lineup drift

**Symptom:** Row count is moderate (~250) but only ~30 min of clock captured because mid-period the lineup state goes bad and dozens of rows get dropped.

**Hypothesis:** After Fix 6 (period-boundary reset), period transitions are handled. But within a period, a misordered sub sequence can still grow the lineup past 5 players, causing `expandColumn` to blank every subsequent row until something brings the count back to 5.

**Investigation steps:**
- Instrument the Python sub-handling loop to log every event where the lineup grows past 5 OR a sub-out fails (`player_name not in any lineup`).
- Run on one of the problem games. Look at where the drift sets in.

**Possible fixes (ranked by effort):**

1. **Last-name fallback in sub matching** (low effort, possibly high payoff). When `SUB OUT by SCOTT,BRODIE` fires and the lineup has `scott`, also try matching by last name. Risk: same-last-name teammates collapse, but for D3 rosters this is rare.

2. **Pair sub-ins and sub-outs that share a clock value** (medium effort, principled). NCAA play feeds typically list multiple subs at the same clock stoppage. Treat all subs at the same `timeRemaining` as a transaction — try every permutation of (in, out) pairings and pick whichever leaves the lineup at exactly 5.

3. **Within-period heartbeat reset** (medium effort, mirrors Fix 6). Periodically verify the lineup is exactly 5; if not, re-derive from upcoming plays via the same logic as the period boundary.

#### C. Unhandled play-string formats

**Symptom:** Row count is healthy (~250+) and clock looks normal, but specific play types don't get points credited.

**Hypothesis:** Play strings like `GOOD JUMPER BY BAUGHMAN,CARTER(in the paint)`, `TIP IN by ... (fastbreak)`, or free-throw sequences with non-standard prefixes might not match the `case_when` in `compute_lineup_metrics`. We cover `layup`, `jumper`, `dunk`, `three pointer`, `free throw` — but the Python classifier might emit other strings.

**Investigation steps:** dump distinct `playType` values per game for the 9 problem games and check for unrecognized strings:

```r
load_pbp("2023-24") |>
  dplyr::filter(game %in% problem_games) |>
  dplyr::count(playType, sort = TRUE)
```

**Possible fix:** extend the `case_when` in `compute_lineup_metrics`.

### Recommended next-investigation order

Ordered by impact-per-effort:

1. **CentreHamline / HendrixCentre raw HTML inspection** — lowest minutes captured (~26-28). If it's HTML pagination, fixing the table extractor unlocks several games at once.
2. **HendrixCentre 01/26** — biggest combined gap (−39 / −45 = 84 pts missing). If distinct from pagination, would expose a different root cause.
3. **CentreFranklin 11/28** — has 249 rows and 34 min captured (more than most problem games), but still 64 points missing. Smells like unhandled play strings rather than missing rows.
4. **Implement last-name-fallback sub matching** as a low-risk improvement that might also help LaGrange and Huntingdon's residual gaps.
5. **Within-period heartbeat reset** — generalize Fix 6 to fire mid-period when the lineup drifts below 5.

### What success would look like

If 4 or 5 of the 9 problem games can be fixed by HTML extractor + sub matching improvements, season exact-match coverage would jump from 15/25 → 20+/25. The remaining games may have genuinely unrecoverable upstream data — those are already flagged in the dashboard's Game Facts panel and Totals row.

---

## Diagnostic scripts from the session

These were written to `/tmp/` during development. **Worth checking into the repo at some point** — they're useful for verifying that any new fix doesn't regress what's already working.

| Script | Purpose |
|---|---|
| `/tmp/score_check5.R` | Per-game reconciliation: computed `pointsEarned` vs box-score totals for each game in a season |
| `/tmp/season_audit.R` | Full-season discrepancy report (powers the [Outstanding work table](#per-game-state-latest-pipeline-run)) |
| `/tmp/metric_check.R` | Validate metric ranges (PACE, EFG%, TOV%, etc.) are in realistic D3 bands |
| `/tmp/test_python_fix.py` | Smoke-test the Python pipeline helpers in isolation |
| `/tmp/wilkes.R` / `/tmp/wilkes2.R` | Single-game forensic deep dive (used to diagnose Wilkes period-2 loss) |
| `/tmp/test_subgroups.R` | Verify subgroup aggregation across N=1, 2, 3, 4 |
| `/tmp/test_whatif.R` | Verify enumerate-all-combinations logic for the rejected v2 of Player Combination |

### Typical season audit pattern

```r
suppressPackageStartupMessages({library(dplyr)})
src <- readLines("MAT405basketballResearch/cenrebasketball.R")
cut <- grep("^image_ratio", src)[1]
eval(parse(text = paste(src[seq_len(cut - 1)], collapse = "\n")))

d <- load_pbp("2023-24")
# ... do whatever audit, using the loaded helpers (build_lineup,
# compute_lineup_metrics, normalize_team, etc.)
```

This pattern lets you reuse the dashboard's exact helper functions in standalone scripts without spinning up Shiny.

---

## Files and helpers reference

### Files of interest

| File | Purpose |
|---|---|
| `MAT405basketballResearch/getbasketballclean.py` | Main Python pipeline — ~1900 lines |
| `MAT405basketballResearch/html_parsers.py` | Sidearm HTML extraction utilities |
| `MAT405basketballResearch/cenrebasketball.R` | Shiny dashboard |
| `SAA/<school>/HTML/<season>/` | Raw HTML inputs |
| `SAA/<school>/pbp/<season>/` | Cleaned pbp CSVs (the analytical dataset) |

### Key Python helpers added during this work

| Function | What it does |
|---|---|
| `_zero_phantom_possession_flags(df)` | Zero `possStart`/`teamChanged`/`possPoints` on `--`-clock rows |
| `_reattribute_phantom_lineups(df)` | Copy assist/rebound rows' lineup from matching real plays |
| `_strip_jersey(name)` | Remove `^\d+,` and `,\d+$` from names |
| `_build_name_recovery_maps(df)` | Last-name → full-name map from play stream |
| `_upgrade_lineup_names(lineup, map)` | Apply recovery map to lineup |
| `_infer_period_starters(df, idx, period, side)` | Re-derive period starters from first plays |
| `_extract_player_from_play(play_lower)` | Helper that tries every play-type prefix until `getPlayer` returns a name |
| `_is_real_play_clock(t)` | True iff `timeRemaining` is `MM:SS` (used by phantom-row detection) |

### Key R helpers

| Function | What it does |
|---|---|
| `normalize_team(x)` | Canonical team name (handles all 24 Centre variants) |
| `add_elapsed_seconds(d)` | Per-row `elapsed_sec` from `timeRemaining` deltas |
| `load_pbp(season)` / `load_pbp_cached(season)` | Season loader with full cleanup pipeline + per-process cache |
| `team_lineup_matrix(df, selected_team)` | (nrow × 5) lineup matrix for the selected team |
| `available_teammates(mat, picked)` | Cascading picker support |
| `build_lineup(...)` | Builds the CentreLineup string for the selected team |
| `compute_lineup_metrics(df, selected_team)` | Per-5-man-lineup metrics (one row per CentreLineup) |
| `compute_subgroup_in_lineup_metrics(df, team, n)` | One row per (subgroup, lineup) pair with subgroup-credited actions |
| `compute_subgroup_pooled_metrics(df, team, n)` | One row per subgroup, pooled across lineups (used by Player Combination v4) |
| `expand_to_subgroups(df, n)` | Row expansion to C(5,N) subgroups per play |

### Pipeline data-flow detail (one game)

**Python (`getbasketballclean.py::makeHeaderPBP`):**

1. Read header CSV → game metadata (date, teams, location, score).
2. Read table CSV → raw play-by-play rows.
3. `parse_starters` on HTML player tables → initial 5-man lineups.
4. Strip jerseys, apply `PLAYER_NAME_CORRECTIONS`, recover first names from play stream (Fix 5).
5. Main loop walks every play row in order, maintaining `home_lineup` / `away_lineup` state via sub-event handling. Snapshots the lineup on each row into `l_home_lineup` / `l_away_lineup`.
6. Period boundary check (Fix 6) re-initializes lineup if state is broken.
7. Build derived columns: `playType`, `shotOutcome`, `points`, `Team`, `Player`.
8. Run possession tracking: `posschange`, `assign_teams`, `team_change_indicator`, `calculate_possession_points`, `calculate_possession_numbers`, `calculate_possession_times`.
9. `_zero_phantom_possession_flags` (Fix 1) → kill phantom-row contributions.
10. `_reattribute_phantom_lineups` (Fix 2) → fix lineup attribution on phantom rows.
11. `expandColumn` → unpack `homeLineup` / `awayLineup` lists into `homePlayer1..5` / `awayPlayer1..5` columns. Strip `(fastbreak)` / `(in the paint)` modifiers from text columns.
12. Write CSV + JSON to `pbp/<season>/`.

**R loader (`cenrebasketball.R::load_pbp`):**

1. Read every CSV in `pbp/<season>/` as character.
2. Coerce specific columns to numeric.
3. `normalize_team` on `homeTeam` / `awayTeam` + lowercased version on `Team` / `possTeam`.
4. Strip jerseys in player columns (mirror of Fix 3, for old CSVs).
5. Map `"None"` and `""` in lineup columns to `NA`; drop rows where any of the 10 lineup slots is `NA`.
6. Filter `playerMissing == 0`.
7. Adaptive phantom-row handling (drop them if old-CSV signal detected; keep if new-CSV).
8. `add_elapsed_seconds` → derive accurate per-row clock deltas.

---

## Adding new seasons (2024-25, 2025-26, ...)

### R side

Zero code changes. The season picker uses `list.dirs(seasons_root, recursive = FALSE)` so any new `pbp/<season>/` directory auto-appears.

### Python side

1. Bump `end_year` in `getbasketballclean.py` to the latest fall year (e.g., `2025` for the 2025-26 season). The script computes `year_str = f"{year}-{year-2000+1}"`.
2. Make sure the upstream `SAA/centrecolonels/HTML/<season>/`, `headers/<season>/`, `tables/<season>/` directories are populated (this is a separate scraping pipeline not in this repo).
3. Run `python3 getbasketballclean.py`. Missing seasons are silently skipped, so it's safe to run with `end_year` higher than what's on disk.

### Watch for HTML layout shifts

Sidearm-hosted pages have changed layout twice in our data range (pre-2022 vs 2022-23+). The `html_parsers.parse_starters()` already handles both formats. If a new season scrapes but produces empty starter lineups or unrecognized play strings, look for a third layout variant.

Quick diagnostic for a new season:

```bash
wc -l SAA/centrecolonels/pbp/2024-25/*.csv
```

Healthy 2023-24 games produce 200-400 rows each. If 2024-25 games come out at 20-50 rows, the HTML layout has shifted and the parser needs updating.

Also worth running after a new season is added:

```r
# Adjust /tmp/season_audit.R to point at the new season's pbp/
Rscript /tmp/season_audit.R
```

If you see lots of new games with non-zero gaps, that's a sign the parser needs updates to handle the new HTML.

---

## Session 2 follow-up #6 — self-healing lineup recovery

Investigation of Centre 2025-26's residual 13 unattributed points revealed a new class of bug: **mislabeled SUB IN events in the source feed**. In the Centre vs Asbury opener (11/2025), the Sidearm feed emitted:

```
SUB OUT by INGRAM,DRAKE
SUB IN by SHENE,RYAN   ← but Shene was already on the floor
```

The "SUB IN by SHENE" was a name typo by the upstream feed — somebody else actually came in for Ingram. The parser correctly silently no-op'd the redundant SUB IN (adding Shene twice would corrupt the state), but that left Centre's lineup stuck at 4 players for the rest of the period, blanking every Centre scoring row.

### Fix — `_heal_lineups_from_play_stream(df, home_name, away_name)`

Hooked into the pipeline right after `_correct_team_from_score_deltas` and before `expandColumn`. Two-pass algorithm:

1. **Stretch identification.** A "stretch" is a run of consecutive PBP rows during which one side's lineup snapshot doesn't change — i.e. between consecutive substitution events. The function walks the saved `homeLineup` / `awayLineup` columns row-by-row and assigns each row an integer stretch ID per side.

2. **Pass 1 — collect missing players per stretch.** For each row, if a same-team Player took a real on-court action (shot / rebound / turnover / foul / steal / assist / block, NOT a sub or timeout) and they weren't in the parser's snapshot AND the snapshot has fewer than 5 distinct players, record them as an "extra" for that stretch.

3. **Pass 2 — propagate extras across the whole stretch.** For every row in a stretch with recorded extras, add the extras to the saved lineup. **Critically bidirectional** — backward AND forward propagation. The reasoning: if a player took an action at row N within stretch B, they must have been on the floor for the entire stretch (rows N-back-to-stretch-start AND rows N-forward-to-stretch-end), not just from row N onward. Without backward propagation, free throws shot before the missing player took their first action stay unattributed.

### Impact — Centre per-season unattributed points

| Season | Before heal | After heal | Recovery |
|---|---:|---:|---|
| 2015-16 | 426 | **115** | -311 (-73%) |
| 2018-19 | 54  | **11**  | -43 (-80%) |
| 2025-26 | 13  | **4**   | -9 (-69%) |
| 2023-24 | 4   | **2**   | -2 (-50%) |
| 2022-23 | 4   | **0**   | -4 (-100%) ✓ |
| 2024-25 | 0   | **0**   | unchanged ✓ |

CSV-level reconciliation across the full dataset: **2446 / 2470 (99.0%)** — unchanged (no regression).

### What's NOT recoverable

The 4 unattributed pts that remain in the Centre 2025-26 Asbury game are from free throws during a stretch where the unknown 5th player took **zero recorded actions**. No shots, no rebounds, no fouls, no anything. The play stream provides no evidence of who they were, so no algorithm can recover them without external data. These cases are inherently limited by upstream data quality — they're not bugs.

For the older seasons (e.g. 2015-16) the residual 115 unattributed points are similar — stretches where the missing player was passive enough to leave no fingerprint in the PBP. Future improvement would require integrating the Sidearm HTML's player-stats table (which has per-player minutes columns that could identify all 5 active players during any given clock window).

---

---

## Session 2 follow-up #7 — Women's basketball + sport toggle

Professor restructured the project layout to a per-sport root:

```
<project>/mens-basketball/SAA/<school>/{HTML,headers,Tables,pbp}/<season>/...
<project>/womens-basketball/SAA/<school>/{HTML,headers,Tables,pbp}/<season>/...
```

The existing pipeline already supported per-sport paths via `_sport_root()`; the only edit needed was enabling `sports = ['mens-basketball', 'womens-basketball']` so both are iterated.

### Six scripts updated for the new layout

`audit_scores.py`, `audit_loader.py`, `validate_pbp.py`, `patch_team_attribution.py`, `patch_extra_periods.py`, `patch_missing_playtype.py` were each updated to glob over BOTH sport directories (and fall back to legacy `<root>/SAA` if neither exists). Each game row in the audit output now carries a `sport` column so per-sport stats are trivial to slice.

### Dashboard sport toggle (`cenrebasketball.R`)

- **Sport detection**: at startup, `available_sports` lists which top-level sport directories actually exist on disk. The radio-button toggle in the sidebar only appears when both sports are installed; single-sport installs hide the control and behave exactly as before.
- **`seasons_root_for_sport(sport)`**: returns the right pbp tree for the selected sport, with a legacy fallback.
- **`load_pbp()` / `load_pbp_cached()`** accept an optional `sport` arg. The cache is keyed by `"<sport>::<season>"` so men's and women's data never collide when the user toggles back and forth.
- **Reactive wiring**: when the sport changes, the season picker rebuilds from the new sport's directories (different sports may have different season coverage), and the Team / Game / Player pickers reset so no stale selection survives the toggle.

### Results across the full dual-sport dataset

| Metric | Value |
|---|---:|
| Total games | **4,927** |
| Perfect score reconciliation | 4,879 (**99.0%**) |
| Men's basketball perfect | 2,446 / 2,470 (99.0%) |
| Women's basketball perfect | 2,433 / 2,457 (99.0%) |

### Centre per-sport per-season

| Sport | Season | Perfect |
|---|---|---:|
| Men's | 2025-26 | 23/23 ✓ |
| Men's | 2024-25 | 24/24 ✓ |
| Men's | 2023-24 | 25/25 ✓ |
| Men's | 2022-23 | 26/26 ✓ |
| Women's | 2025-26 | 24/24 ✓ |
| Women's | 2024-25 | 26/27 (1 game off) |
| Women's | 2023-24 | 26/26 ✓ |
| Women's | 2022-23 | 25/25 ✓ |

The single women's 2024-25 imperfect game has the same upstream-data quirks that affect any single game; the rest reconcile cleanly out of the gate.

The cross-sport ingestion required zero per-sport tuning — the existing parser handles women's basketball without modification because the Sidearm HTML format is consistent across men's and women's pages.

---
