# Project Handoff — Centre Basketball Lineup Analysis

A standalone context document for picking up where this work left off.
Captures everything from this multi-session pass: what was broken, what
was tried, what worked, what didn't, and (most importantly) what's still
outstanding on the score-reconciliation front.

The original `README.md` is the project's high-level overview and is
unchanged. The original `session_notes.md` is the change journal from
the earlier sessions — also unchanged. **This file is the consolidated
handoff so a fresh chat can pick up cold.**

---

## Table of contents

1. [Project layout (current)](#project-layout-current)
2. [Data flow at a glance](#data-flow-at-a-glance)
3. [R Shiny dashboard — what changed](#r-shiny-dashboard--what-changed)
4. [Python parser pipeline — what changed](#python-parser-pipeline--what-changed)
5. [Audit + patcher infrastructure built this session](#audit--patcher-infrastructure-built-this-session)
6. [Score-reconciliation history (the detailed bit)](#score-reconciliation-history-the-detailed-bit)
7. [Things tried that did NOT work](#things-tried-that-did-not-work)
8. [Current state of total-score discrepancies — what's left](#current-state-of-total-score-discrepancies--whats-left)
9. [How to continue the work](#how-to-continue-the-work)
10. [Quick-reference command cheat sheet](#quick-reference-command-cheat-sheet)

---

## Project layout (current)

The professor reorganised the project to support two sports. The current
on-disk layout is:

```
CentreBasketballLineupAnalysis/
├── MAT405basketballResearch/
│   ├── getbasketballclean.py        # main Python pipeline (~2,500 lines)
│   ├── html_parsers.py              # Sidearm HTML helpers
│   ├── cenrebasketball.R            # R Shiny dashboard (~2,180 lines)
│   ├── audit_scores.py              # cross-sport CSV-level audit
│   ├── audit_loader.py              # dashboard-view audit (per side)
│   ├── validate_pbp.py              # 8-check confidence manifest
│   ├── patch_team_attribution.py    # Team-column repair patcher
│   ├── patch_extra_periods.py       # multi-game-on-one-page trimmer
│   ├── patch_missing_playtype.py    # playType backfill from score deltas
│   └── patch_lineup_snapshots.py    # opt-in lineup patcher (dedup variant)
├── mens-basketball/
│   └── SAA/<school>/{HTML,Tables,headers,pbp}/<season>/*.csv
├── womens-basketball/
│   └── SAA/<school>/{HTML,Tables,headers,pbp}/<season>/*.csv
├── README.md                        # the original short README (kept)
├── session_notes.md                 # the historical change journal (kept)
└── PROJECT_HANDOFF.md               # THIS FILE
```

Notes on layout:
- The two new conference schools — `southwesternpirates` and
  `trinitytigers` — are in both sport folders for 2024-25 and 2025-26
  only.
- `Tables/` uses capital T in the new SAA dump; macOS APFS is
  case-insensitive so the pipeline reads it as `tables/`.
- `bscsports` does NOT have 2024-25 or 2025-26 (BSC left the conference).
  This is normal, not a bug.
- Centre 2010-11 has very few PBP files because that's just what was
  scraped originally; not a parser issue.

---

## Data flow at a glance

```
mens-basketball/SAA/<school>/HTML/<season>/*.html
                              ↓                   (html_parsers.py extracts
                              ↓                    starters / player tables /
                              ↓                    team names / CSS classes)
                              ↓
mens-basketball/SAA/<school>/{headers,tables}/<season>/*.csv
                              ↓                   (getbasketballclean.py
                              ↓                    main loop, per game:
                              ↓                    play classification,
                              ↓                    lineup tracker,
                              ↓                    possession counter)
                              ↓
mens-basketball/SAA/<school>/pbp/<season>/*.csv  ← analytical dataset
                              ↓
                              ↓                   (patch_*.py one-shot
                              ↓                    CSV-level repairs)
                              ↓
                              ↓                   (cenrebasketball.R
                              ↓                    reads via load_pbp())
                              ↓
                          Shiny dashboard
```

Identical for `womens-basketball/...`.

---

## R Shiny dashboard — what changed

### Sport toggle (mens / womens)

- New `available_sports` auto-detection at startup: scans for
  `mens-basketball/SAA/` and `womens-basketball/SAA/` directories.
- A `seasons_root_for_sport(sport)` helper returns the right `.../pbp`
  tree per sport.
- `load_pbp()` and `load_pbp_cached()` both accept an optional `sport`
  argument. The cache is keyed by `"<sport>::<season>"` so men's and
  women's data never collide when you toggle back and forth.
- In the UI: a sidebar radioButtons (rendered as a custom sliding-pill
  segmented control) appears at the top of the filter bar **only when
  both sport directories exist**. Single-sport installs hide it and
  behave exactly as before.

### Horizontal filter bar + visual redesign

- Old design: left sidebar with stacked inputs and a left-aligned image.
  New design: a single horizontal **filter bar** across the top with all
  the controls (Program / Season / Team / Game(s) / Player(s) /
  Min Poss / Reset Lineup) using CSS grid auto-wrap.
- Title bar simplified to just the Centre logo + ALL-CAPS
  "CENTRE COLLEGE BASKETBALL" on a black band with a gold underline.
- Applied **Centre Brand Standards** (August 2022 PDF, pages 33–45):
  - Official Centre Gold `#FFCD00` (not the `#f1cc2c` we used to use)
  - Black `#000000`, white `#FFFFFF`, deep slate `#333F4C`,
    teal `#115E67` available as secondary accents
  - Typography: open-source analogues of the brand's proprietary fonts
    - **DM Sans** ≈ Kapra Neue (UI / body text)
    - **Barlow Condensed** ≈ Kapra Neue Condensed (display / numbers /
      tags) — used for title bar, tab labels, table headers, picker pills,
      and especially numeric columns in DataTables with
      `font-feature-settings: 'tnum'` so digits line up.
  - "More white space, less black" rule honored — black is reserved
    for the header band, table head, active tabs, selected toggle.
  - Sharper geometry: corner radii 3–4px instead of 8–12px.

### Sport toggle — sliding pill design

The `program-toggle` div renders a 38px-tall pill that height-matches
the picker inputs. The black slider is a `::before` pseudo-element
that translates with `cubic-bezier(0.4, 0, 0.2, 1)` ease and a CSS
`:has()` selector detecting which radio is checked. Active text turns
gold, inactive stays muted gray. Labels shortened to "MEN'S" /
"WOMEN'S" (no "Basketball" suffix) to fit cleanly in the pill.

### Speed — dashboard load times dropped 18×

#### Root cause profiled

`load_pbp()` on Centre women's 2015-16 (the slowest case):

| Step                              | Time     |
| --------------------------------- | -------- |
| `data.table::fread` 23 CSVs       | 0.06 sec |
| numeric-col coercion              | 0.00 sec |
| `normalize_team` on home/away     | 0.10 sec |
| **`normalize_team` on Team/possTeam** | **2.97 sec** ← 92% of the load |
| jersey strip                      | 0.06 sec |
| None/empty → NA                   | 0.01 sec |
| `repair_team_attribution`         | 0.01 sec |
| `add_elapsed_seconds`             | 0.02 sec |
| **TOTAL (before fix)**            | **3.24 sec** |

The Team/possTeam columns have 12,000+ rows but only ~10–20 unique
team strings. `normalize_team` was being called per-element via
`sub()` chains — 25,000+ calls instead of 20.

#### The fix

A new `normalize_team_fast()` wrapper inside `load_pbp()`:

```r
normalize_team_fast <- function(x, lower = FALSE) {
  u  <- unique(x)
  nu <- normalize_team(u)
  if (lower) nu <- tolower(nu)
  nu[match(x, u)]
}
```

Result: every season loads in **0.17–0.24 sec** now.

Combined with:
1. **`data.table::fread`** instead of `read.csv` (10× faster CSV read).
2. **`.prewarm_seasons()`** runs synchronously BEFORE `shinyApp()` is
   called. It loads the most recent season of every installed sport
   into the cache so the first request the user makes is already
   served from RAM.
3. **`withProgress()` indicator** for any cold load (showing
   "Loading Men's Basketball · 2018-19 / reading play-by-play files…").
4. **`outputOptions(suspendWhenHidden = FALSE)`** on every tab output —
   keeps all renderers warm in the background so clicking a different
   tab swaps already-computed HTML instead of re-rendering.

#### Resulting UX

| Action                                                       | Before | After |
| ------------------------------------------------------------ | -----: | ----: |
| App startup (pre-warm both sports' newest seasons)           | n/a    | ~0.4s |
| First request after startup                                  | ~25 s  | 0 s   |
| Sport toggle (lands on newest season — pre-warmed)           | ~25 s  | 0 s   |
| Pick a non-default season                                    | ~25 s  | ~0.2s |
| Switch back to previously-viewed season                      | 0 s    | 0 s   |
| Switch between tabs                                          | small  | 0 s   |

### Metric-aware "Minimum possessions per side" filter

Originally the sidebar slider gated on `TOTAL_POSS = OFFPOSS + DEFPOSS`,
which let a 13-OFFPOSS / 13-DEFPOSS lineup (26 total) clear a "min 20"
filter and post a noisy 192 OFFRTG. The slider was renamed
**"Minimum possessions per side"** and the gate is now metric-aware:

| Metric class                            | Gate                                   |
| --------------------------------------- | -------------------------------------- |
| Offense-only (OFFRTG, AST_RATIO, …)     | `OFFPOSS ≥ min_poss`                  |
| Defense-only (DEFRTG, DREB_RATE)        | `DEFPOSS ≥ min_poss`                  |
| Multi-side (NETRTG, plus_minus)         | `OFFPOSS ≥ min_poss AND DEFPOSS ≥`     |
| Combined-sample (PACE, TIME_MIN)        | `TOTAL_POSS ≥ min_poss`               |

The Player Tables / Lineups-in-Game tables (which show both OFFRTG and
DEFRTG simultaneously) use the per-side AND-gate on both sides.

### Three-line totals footer

The `render_totals_ui` reactive now renders three lines (instead of
one) and splits the previously-misleading "unattributed" warning into
the two real reasons:

```
Totals across rows above: Centre scored 1037, opponent scored 1088.
   (759 / 774 in lineups below the min-possessions filter; 2 / 2 in
    rows where the parser lost lineup state)
Play-stream totals: Centre 1798, opponent 1864.
Actual final-score totals: Centre 1798, opponent 1864 (diff +0 / +0).
```

The play-stream totals always show the correct game total (independent
of lineup tracking). The "across rows above" total is what's in the
visible lineup table. The split tells the user how much of any
shortfall is fixable by lowering `min_poss` vs how much is genuinely
unattributed-from-parser-state.

### Tipin + two pointer added to the case_when

In both `compute_lineup_metrics()` and
`compute_subgroup_in_lineup_metrics()`, the `.row_pts` case_when now
includes `tipin` and `two pointer` (older-Sidearm 2-point shot types).
Excluding them silently dropped ~600 made shots across the full
dataset.

### Smaller dashboard refinements
- Lineup tables don't drop NA-lineup rows in `load_pbp()` anymore;
  the rows are kept (so total scores stay correct) and just land in an
  NA-CentreLineup bucket downstream which the table filters naturally.
- "Reset Lineup" button restyled as a gold pill with brand typography.
- Game Facts card uses brand styling (gold left-accent stripe, soft
  white card, ALL-CAPS title).

---

## Python parser pipeline — what changed

The parser is in `getbasketballclean.py`. This section captures **only
the changes added during the recent sessions**; for older history see
`session_notes.md`.

### Two-sport support
- `sports = ['mens-basketball', 'womens-basketball']` (was just mens-).
- `_sport_root(sport)` resolves the right top-level directory per sport.
- New schools added: `southwesternpirates`, `trinitytigers` (and the
  abbreviated team names `southwestern`, `trinity` in `saa_teams`).
- `end_year = 2025` so 2024-25 and 2025-26 are processed.

### Parser robustness fixes added this session

In rough order of discovery:

1. **Missing comma in `type_of_plays` list.** `'2ptr' 'steal'` got
   silently concatenated to `'2ptrsteal'`, so STEAL events couldn't
   have their Player extracted, AND `GOOD 2PTR by X` plays had Player
   left empty.
2. **`_correct_team_from_score_deltas`** — a post-pass that uses the
   per-row `homeTeamScore` / `awayTeamScore` columns (which are
   independent of play classification and always reliable) to:
   - Identify which side actually scored on each row by score delta.
   - Build a player → side map from confirmed scoring rows.
   - Override `Team` for every row using that map.
   Fixes the 2018-19 monotone-Team bug (where every row was labelled
   with one team) and the GOOD-2PTR-by-X plays with empty Player.
3. **`_normalize_player_key(name)`** — canonical key for sub-event
   membership checks. Collapses `rasberry,jr.,darvis` and
   `rasberry jr,darvis` to the same string. Fixed a Centre 2023-24
   class of bug where the lineup grew past 5 because the same player
   was added under two spellings.
4. **`_reorder_sub_blocks(df)`** — within a same-(Period, timeRemaining)
   block, reorders rows so every SUB OUT precedes every SUB IN. Some
   Sidearm exports list IN-before-OUT and the lineup briefly grows to 6
   under the original logic, blanking the snapshot.
5. **Replaced brittle `skip_line` cascade** with silent no-op on
   unresolvable subs. The old code set `skip_line = 1` when a sub
   couldn't be applied, then skipped the NEXT sub event. If a non-sub
   event (foul, timeout, etc.) intervened, the skip cascaded through
   to an unrelated sub and blanked the lineup for the rest of the
   period. The new behavior just no-ops the failed sub.
6. **SUB IN overflow guard.** When a SUB IN would push the target
   lineup past 5 (because an earlier SUB OUT no-op'd), drop the oldest
   entry instead of overflowing the snapshot.
7. **`_reattribute_phantom_lineups` rewritten** to prefer
   immediate-prior shot pairing (walks backward to find the adjacent
   real shot of the matching outcome) before falling back to the
   greedy FIFO chronological pairing the original code used. Also
   expanded the shot-type set to include `free throw`, `tipin`, and
   `two pointer` so phantom rebounds after FT misses pair correctly.
8. **Generic `MISS by X` handling.** Newer Sidearm format emits
   `MISS  by ROBINS,JARED` with no shot-type word. Previously the
   parser fell into the `else:` branch and appended `''` to `Team`,
   which crashed `assign_teams()` later with
   `UnboundLocalError: team1 not assigned`. The `else:` branch now
   classifies "miss by X" as `playType='shot' / shotOutcome='missed'`
   and assigns Team via the homePlay/awayPlay split with fallbacks.
9. **`assign_teams()` defensive walk.** Walks `teamName` to find the
   first row matching either home_team or away_team, falls back to
   the away team. Never crashes on an empty first-row Team value.
10. **Modifier strip in player_name extraction.** Sidearm sometimes
    glues `(fastbreak)` / `(in the paint)` onto the player name in the
    play text. Without the strip, `combs,isabelle(fastbreak)` got added
    to the lineup as if it were a different player from
    `combs,isabelle`.
11. **Period-boundary heal for 4-quarter games (women's).** At each
    new period, scan forward in the period-start clock block for SUB
    OUTs whose target isn't in the parser's lineup state. Add them
    retroactively — the SUB OUT confirms the player was on the floor
    at end of previous period. THEN process the SUB OUTs normally.
    Falls back to `_infer_period_starters` (Fix 6 from session notes)
    only if still short of 5.
12. **`_heal_lineups_from_play_stream(df, home_name, away_name,
    home_roster=None, away_roster=None)`** — the stretch-based
    self-healing helper. Has **three** passes:
    - **Pass 1**: identify "stretches" (runs of consecutive rows where
      one side's lineup snapshot doesn't change), then collect any
      same-team players who took an on-court action but aren't in the
      snapshot.
    - **Pass 2**: propagate the collected extras **bidirectionally**
      across the stretch — both forward and backward — because the
      player was on the floor for the entire stretch, not just from
      their first action.
    - **Pass 3 (NEW)**: roster-aware fallback. Uses the player-stats
      table parsed from the box-score HTML to identify the missing
      5th player when no on-court action exposed them. Picks the
      candidate with the highest minutes played who's confirmed
      on-floor by the sub-event walk OR who has ≥ 4 minutes played
      (skips DNP bench players).
13. **`parse_player_roster(player_table)`** in `html_parsers.py` —
    extracts `[{'name', 'minutes', 'is_starter'}, ...]` for every
    player. Handles both Sidearm layouts. Provides the roster
    ground-truth that Pass 3 of the heal helper uses.

### Possession counter fixes — three bugs in posschange / update_play_types

These were the cause of the "OFFRTG > 200" complaint and inflated
ratings.

1. **`update_play_types` had an unbounded forward scan.** Was
   supposed to revert `LAST FT MADE` → `GOOD FT` for and-one
   situations. But it walked the entire rest of the game looking for
   any `MISS FT` then any `FOUL`. Since every game has several of
   those, the revert triggered constantly and incorrectly. Dropped
   ~80% of free-throw-triggered possession changes.
   - **Fix**: bound the scan to the current trip to the line; stop at
     the first row that isn't `FT` / `FOUL` / `SUB` / `TIMEOUT`.
2. **`GOOD TIPIN` and `GOOD 2PTR` were missing** from `made_shots`
   and `change_poss` lists. Those scoring plays added points without
   ending possessions.
3. **First row of each period had `possStart = 0`.** The base loop only
   marks transitions FROM a previous row; the very first play of a
   period was never marked.
   - **Fix**: a new `_mark_period_starts()` runs AFTER `assign_teams`
     (so the team flip in assign_teams isn't triggered on row 0
     incorrectly) and just credits the first row of each period with
     the +1 OFFPOSS count it deserves.

After these three fixes (Centre 2023-24 example):

| Metric                          | Before  | After     |
| ------------------------------- | ------: | --------: |
| Mean OFFPOSS per game           | 59.6    | **67.8**  |
| Mean per-game OFFRTG            | 121.6   | **106.4** |
| Per-lineup median OFFRTG (≥10)  | —       | 110       |
| Lineups (≥10 OFFPOSS) > 150     | many    | 3 of 36   |

---

## Audit + patcher infrastructure built this session

All in `MAT405basketballResearch/`. Each script auto-detects the
two-sport layout (`mens-basketball/SAA/...` and
`womens-basketball/SAA/...`) and falls back to legacy `SAA/...` if
neither exists. Each output row carries a `sport` column so per-sport
slicing is trivial.

| Script                          | What it does                                                                                                                                                                |
| ------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `audit_scores.py`               | Cross-school, cross-season score reconciliation. For every CSV: compute home_pts and away_pts from the play stream (Team + playType + shotOutcome) and compare to header `finalScore`. Output: `/tmp/audit_scores_master.csv` + per-(school, season) summary. |
| `audit_loader.py`               | Dashboard-view audit. Mirrors the R loader's filtering. Computes both perspectives: when home is the selected team and when away is the selected team. Surfaces "X dashboard points unattributed" per side per game. |
| `validate_pbp.py`               | Per-game integrity check producing a confidence score (0..1) over 8 checks (R1-R8). Outputs `/tmp/pbp_validation.csv` — diffable across runs.                                                                       |
| `patch_team_attribution.py`     | Score-delta-driven Team-column rebuild. Two corruption signatures detected: (a) monotone Team column (single distinct value), (b) team-attributed pts disagrees with score-delta pts. Idempotent.            |
| `patch_extra_periods.py`        | Detects + trims rows belonging to a second game appended to the same CSV (Period > numPeriods, isOvertime=False, exact finalScore reached at end of last legitimate period).                                  |
| `patch_missing_playtype.py`     | Backfills `playType` and `shotOutcome` on rows where the per-row score delta confirms a scoring event but the parser couldn't classify the play (e.g. `GOOD  by GERALD,DUSTIN` with no shot-type word).      |
| `patch_lineup_snapshots.py`     | Opt-in heuristic patcher for lineup snapshots. Detects duplicate-name lineups and walks plays to re-derive. Less safe than `_heal_lineups_from_play_stream` in the parser, so left as opt-in.                  |

---

## Score-reconciliation history (the detailed bit)

This is the heart of the document — the chronological history of what
the data looked like at each stage, what move helped, and what's still
left.

### Stage 0 — original session_notes baseline

The original Centre-only investigation (session 1) ended with:

> 15 / 25 games reconcile exactly to the box score.
> 1 game has a 1-point opponent gap.
> 9 games have moderate to large gaps.

But the methodology there counted only Centre 2023-24 and used the
old, pre-tipin/two_pointer `case_when`. When the cross-school audit
was first built, with tipin and two pointer added, the picture was
substantially different: ~83% of all games perfect across the full
2,075-game dataset.

### Stage 1 — initial audit (full dataset, men's basketball only)

Run: `audit_scores.py` after just adding `tipin` and `two pointer` to
the case_when.

- 2009 / 2075 (96.8%) games perfect.
- 66 problem games, sum_gap = 5,851 pts, mean gap = 2.8 pts.
- Top problem cohorts:
  - 2018-19 season across 5 schools: ~5,150 pts in 38 games (Team
    monotone bug).
  - A few large per-game gaps from upstream HTML truncation.
  - Many small (1-3 pt) residuals from minor parser edge cases.

### Stage 2 — Team-attribution fix (2018-19 cohort)

Diagnosed via the fact that `computed_home = 0` and
`computed_away = real_home + real_away` for these games — every play
was labelled with the away team. Root cause: the 2018-19 Sidearm HTML
cram both teams' plays into one cell; the parser's heuristic
`data == df['homePlay'][i]` always fell to the else-branch.

Built `patch_team_attribution.py` and then ALSO added
`_correct_team_from_score_deltas` as a post-pass in the parser so
re-runs don't reintroduce the bug.

After this: 2040 / 2075 (98.3%) perfect, sum_gap = 430.

### Stage 3 — `patch_extra_periods.py` for multi-game CSVs

One 2018-19 file (`millsaps_oglethorpe_pbp_23.csv`) contained a second
game's PBP appended. numPeriods=2 in header, max Period=4 in body, and
the body's running score at end of Period 2 exactly matched the
header's finalScore. Trimmed it.

After this: 2041 perfect, sum_gap = 374.

### Stage 4 — `patch_missing_playtype.py` for unclassified plays

About 10 files had `GOOD  by X` plays (no shot-type word) plus one
case of `GOOD 3PTR by X` mis-classified as missed. Backfilled
`playType` and `shotOutcome` from the per-row score delta.

After this: 2052 / 2075 (98.9%) perfect, sum_gap = 285.

### Stage 5 — dashboard-view audit revealed a different problem

Even with the CSV-level audit at 98.9% perfect, the user reported:

> there are still missing points in the 2023-2024 season

`audit_loader.py` (which mirrors the R loader's `playerMissing == 0`
filter) revealed:

> Centre 2023-24: 25/25 CSV-perfect BUT 559 / 520 = **1,079 points
> unattributed in the dashboard view**

The CSVs were fine; the R loader was dropping rows with NA lineup
slots, and many of those dropped rows were Centre scoring rows.

Root cause: name normalization. `rasberry,jr.,darvis` and
`rasberry jr,darvis` are the same player; the parser's sub-event
membership check failed and added the player twice. The lineup grew
to 6 → expandColumn blanked all five slots → R loader dropped the
row.

### Stage 6 — incremental parser fixes

Each of these was discovered by investigating a specific problem game:

| Fix                                              | Centre 2023-24 unattributed |
| ------------------------------------------------ | --------------------------: |
| (baseline)                                       | 559 / 520 = 1,079           |
| Audit side-specific lineup check (was checking 10 slots, should check 5) | 139         |
| `_normalize_player_key` for sub-event membership | 139 (no further help here)  |
| `_reattribute_phantom_lineups` immediate-prior pair | (Wilkes recovery)        |
| `_reorder_sub_blocks`                            | (Wilkes recovery)           |
| `skip_line` cascade removed                      | 39                          |
| SUB IN overflow guard                            | **4**                       |

For Centre 2023-24, we went from 1,079 unattributed → **4 unattributed**
points. The 4 are in stretches where the unknown 5th player took
literally zero recorded actions; no algorithm could identify them.

### Stage 7 — stretch-based heal helper

`_heal_lineups_from_play_stream` was built to recover lineups across
many older seasons that had similar issues. Two-pass algorithm:

- **Pass 1**: identify stretches (runs of rows with unchanged snapshot).
  Collect same-team players who took actions but aren't in the snapshot.
- **Pass 2**: propagate **bidirectionally** across the stretch.

Critical: backward propagation. If a player's first action happens
mid-stretch, they were on the floor BEFORE that action too. Without
backward propagation, free throws shot in the period BEFORE their first
action stay unattributed.

Centre per-season impact at this stage (before roster fallback):

| Season           | Before heal | After two-pass heal | Recovered    |
| ---------------- | ----------: | ------------------: | -----------: |
| 2015-16          | 426         | 115                 | −311 (−73%)  |
| 2018-19          | 54          | 11                  | −43 (−80%)   |
| 2023-24          | 4           | 2                   | −2 (−50%)    |
| 2022-23          | 4           | 0                   | −4 ✓         |
| 2024-25          | 0           | 0                   | unchanged ✓  |
| 2025-26          | 13          | 4                   | −9 (−69%)    |

CSV-level reconciliation stayed at 99.0% — no regressions.

### Stage 8 — possession counter fixes (OFFRTG inflation)

Investigation: the user reported "OFFRTG > 200 on Top Lineups."
Profiled OFFPOSS per game: Centre 2023-24 averaged 59.6 possessions
per game when expected ~70. About 15% undercounted.

Three bugs in possession-tracking code:
1. `update_play_types` unbounded forward scan reverted 80% of last-FT
   possession changes.
2. `GOOD TIPIN` / `GOOD 2PTR` weren't in `made_shots` / `change_poss`.
3. First row of each period had `possStart=0`.

After fixing: mean OFFRTG went from 121.6 to **106.4** (D3 norm).
For meaningful lineups (≥10 OFFPOSS), only 3 of 36 still had OFFRTG > 150.

### Stage 9 — added 4-quarter handling (women's basketball)

Women's basketball uses 4 quarters and Sidearm emits SUB OUT events at
the start of each quarter for every player who finished the previous
quarter but isn't returning. The parser tried to remove these from an
already-incomplete lineup, cascading the state-break across quarters.

Fix: at each period boundary, scan forward in the period-start clock
block for SUB OUTs whose target isn't in our lineup state. Add them
retroactively — the SUB OUT confirms they were on the floor — THEN
process the sub block normally.

### Stage 10 — modifier strip + generic-miss handling

Found via debugging women's basketball:
- `(fastbreak)` and `(in the paint)` modifiers were getting glued
  onto player names → bogus duplicate lineup entries.
- New Sidearm format emits `MISS  by X` with no shot type → parser
  crashed in `assign_teams()`.

Both fixed; pipeline regenerated; women's basketball reconciliation
improved.

### Stage 11 — roster-aware Pass 3 (the latest fix)

For Centre women's 2025-26: the modifier strip surfaced a genuine
"we don't know who the 5th player is" gap in 19 of 24 games. Stretches
where the on-floor 5th player took zero recorded actions can't be
healed from PBP alone.

**Fix**: parse the player-stats table from the box-score HTML. For
each player it gives `(name, minutes_played, is_starter)`. The heal
helper's new Pass 3 uses this roster as ground truth:

For each stretch with <5 visible players:
1. Compute roster members not already in the snapshot.
2. Walk sub events from game start to the stretch's first row,
   maintaining a per-side "currently on floor" set (starters −
   subbed-out + subbed-in).
3. Filter the missing-roster set to candidates currently on floor.
4. If no confirmed-on-floor candidate, fall back to "anyone with
   ≥ 4 minutes played" (skips bench DNPs).
5. Pick the candidate with the most minutes (most likely on floor
   for a random moment within the stretch).
6. Apply to every row in the stretch.

**Tested on one season (Centre women's 2025-26)**: went from
4 / 24 perfect / 351 unattributed → **24 / 24 perfect / 0 unattributed**.

This is the single highest-impact fix in the entire session, but
**the full-pipeline regeneration that would apply it everywhere was
killed before completion**. Only Centre women's 2025-26 currently
has the roster-fallback applied. The rest of the dataset needs a
re-run.

---

## Things tried that did NOT work

Documenting these so future work doesn't relitigate them.

| Attempt                                                                          | What broke                                                                                                                                                                                                                            |
| -------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Unconditional period-boundary lineup reset**                                   | Regressed 12 previously-perfect Centre 2023-24 games. Most halftimes don't substitute everyone; re-inferring from upcoming plays caught players who later came in via sub. Now only fires when state is broken (< 5 distinct players). |
| **Cap lineup growth at 5 inside the sub-handling loop**                          | Regressed MillsapsCentre 01/07 (was 81/81 → became 29/29). Some games legitimately have brief lineup overflows during normal sub processing that resolve cleanly within a few events. Reverted; relying on the dedup helpers instead.   |
| **Forward-only stretch propagation in the heal helper**                          | Missed free-throw scoring rows that happened BEFORE the missing player's first recorded action. Switched to bidirectional propagation.                                                                                                |
| **Second-pass patcher with `attr_gap >= 6` detection**                           | Regressed 13 games whose home/away labels were already swapped at the file level. The patcher trusted `homeTeam`/`awayTeam` as ground truth; for those games it should have trusted finalScore. Switched to orientation detection.       |
| **Initial sliding-pill toggle CSS** that used `display:none` on the input        | Some browsers don't transmit click events through `display:none` radios. Switched to `position:absolute; opacity:0; pointer-events:none` and click-through-the-label semantics.                                                          |
| **Original "X / Y unattributed to lineups — parser lost lineup state" warning**  | The user found it misleading: most of the number was actually "in lineups below the min_poss filter," not parser issues. Split into two clearly-labelled components in the footer.                                                       |
| **Trying to patch the lineup snapshot CSVs post-hoc with dedup-only logic**      | `patch_lineup_snapshots.py` exists but is opt-in. The dedup step on its own doesn't reach 5 distinct players because the missing 5th really is missing. The period-walk reconstruction is heuristic and can mis-attribute borderline cases. |
| **Hardcoded anchor variants for Player Combination tab**                         | Went through 4 iterations (v1: lineups + Others column, v2: theoretical combinations, v3: per-lineup breakdown, v4: pooled subgroup-credited). Only v4 worked. See session_notes.md for the iteration history.                            |
| **Blue button styling on Top Lineups tab**                                       | User: "doesn't look good." Reverted to default theme.                                                                                                                                                                                  |
| **Pre-warming ALL seasons at startup**                                           | Would take ~6 seconds for both sports' newest, but ~30 seconds if we prewarmed everything. Decided pre-warm of the newest seasons only is the right tradeoff; lazy-load with progress for older.                                          |

---

## Current state of total-score discrepancies — what's left

This is the section to read carefully if you're picking up the
score-reconciliation work in a fresh chat.

### Snapshot from the last live audit run

The audit was run on Day 5 of this session and reflects the CSV state
on disk at that point. The roster fallback fix landed AFTER this
snapshot and is NOT yet applied to most of the dataset (because the
full-pipeline regeneration was killed).

**Cross-sport CSV-level reconciliation**: 4847 / 4927 games (98.4%)
exact match between play-stream computed totals and box-score
finalScore.

**Centre dashboard view, per season** (showing only the unattributed
pts the dashboard would warn about):

| Season  | Men's perfect / total / unattr | Women's perfect / total / unattr |
| ------- | -----------------------------: | -------------------------------: |
| 2025-26 | 22/23 / 4                      | (was 4/24 / 351 — now 24/24 / 0 after roster fix on that season) |
| 2024-25 | 24/24 / **0** ✓                | 25/27 / 2                        |
| 2023-24 | 24/25 / 2                      | 25/26 / 1                        |
| 2022-23 | 26/26 / **0** ✓                | 25/25 / **0** ✓                  |
| 2021-22 | 20/20 / **0** ✓                | 21/26 / 43                       |
| 2020-21 | 8/8 / **0** ✓                  | 9/10 / 10                        |
| 2019-20 | 22/26 / 28                     | 21/25 / 48                       |
| 2018-19 | 21/26 / 19                     | 13/20 / 30                       |
| 2017-18 | 18/25 / 33                     | 17/21 / 20                       |
| 2016-17 | 16/24 / 45                     | 14/23 / 71                       |
| 2015-16 | 14/25 / 104                    | 9/23 / 75                        |
| 2014-15 | 20/26 / 72                     | 14/21 / 54                       |
| 2013-14 | 21/27 / 40                     | 16/27 / 71                       |
| 2012-13 | 16/24 / 68                     | 14/23 / 49                       |
| 2011-12 | 18/22 / 43                     | 23/27 / 22                       |
| 2010-11 | 5/7 / 6                        | —                                |

### What's outstanding

#### A. The roster fallback hasn't been applied universally

The single highest-impact remaining fix is **already coded** —
`_heal_lineups_from_play_stream`'s Pass 3 plus the
`parse_player_roster` helper. It just hasn't been propagated to the
full dataset because the full pipeline regeneration was killed.

**Expected impact after pipeline runs**: based on the women's 2025-26
test (351 → 0), every season with significant unattributed counts is
likely to improve substantially. Conservative estimate: cuts another
50–80% off the existing per-season unattributed totals.

**To complete**: run

```bash
python3 -B MAT405basketballResearch/getbasketballclean.py > /tmp/pipeline_roster.log 2>&1
python3 MAT405basketballResearch/patch_team_attribution.py
python3 MAT405basketballResearch/patch_extra_periods.py
python3 MAT405basketballResearch/patch_missing_playtype.py
python3 MAT405basketballResearch/audit_scores.py /tmp
```

Takes ~25-30 min. The user has killed the background pipeline twice;
something about the running pipeline is probably not playing well
with their environment. Worth investigating WHY before re-attempting.
Maybe run it foreground in a terminal the user controls directly.

#### B. Two unrecoverable HTML-truncation games

Identified by `validate_pbp.py`:

| File                                                                                | Sport      | Issue                                                          |
| ----------------------------------------------------------------------------------- | ---------- | -------------------------------------------------------------- |
| `rhodes_mens-basketball_2018-19_5929_louisiana-college_pbp_25.csv`                  | men's      | Source HTML has only 33 play rows (vs expected ~400). 134 pts gap. |
| `birmingham-southern_mens-basketball_2018-19_0803_millsaps_pbp_25.csv`              | men's      | Source HTML has only one half. 71 pts gap.                     |

Verified via `wc -l` on the source HTML and counting `style="width:40%"` cells. The data is genuinely missing upstream. Either accept the gap or scrape an alternative source.

#### C. Internal inconsistency game

`rhodes_mens-basketball_2012-13_2378_rust-college_pbp_4.csv` has 130 pts of made shots when finalScore says 92. The body shows P1 ending at 31-37 but the header says half-time was 13-17. The score regresses by ~36 pts between Period 1 and Period 2 in the body — internal corruption in the source PBP. 38 pt unattributed. Hard to fix automatically without external box-score data; could be addressed by re-scraping just this game.

#### D. Stretches where no algorithm can recover the 5th player

A small fraction of stretches in older seasons have:
- 4 players in the visible snapshot
- 0 same-team actions during the stretch by anyone else
- Multiple bench players who could plausibly have been the 5th

For these the roster fallback picks the highest-minutes candidate
who's on the floor per the sub-event walk. Statistically correct
but not certain. These cases can be:
- **Accepted** (the heal helper's pick is the best guess available)
- **Improved** with additional signal — e.g., parse +/- columns from
  the box-score table, parse jersey-number-on-court overlays, etc.
- **Verified** by spot-checking the heal helper's picks against
  actual box-score numbers

#### E. Older Sidearm HTML quirks

Some pre-2014 games have unusual play strings (`GOOD 2PTR by`,
`GOOD TIPIN by`, various `MISS` variants) and slightly different
HTML structures. The parser handles most but some 1-3 pt gaps remain.
Concentrated in 2010-11 through 2013-14.

#### F. The "we don't even know who was supposed to be on the floor"
problem in really old games

A handful of pre-2014 women's games have very partial player tables
in the HTML — the roster parser comes back with only 6-8 players when
the actual roster was 12+. For these, even the roster fallback can't
fully reconstruct lineups because the source HTML itself is incomplete.

### What the dashboard does today when there ARE unattributed points

The lineup-table footer shows three lines:
1. **Totals across rows above** — sum of pointsEarned/pointsAgainst
   across visible lineups (filtered by the user's min_poss). Includes
   a warning span that splits any shortfall into:
   - `N / M in lineups below the min-possessions filter` (recoverable
     by lowering the filter)
   - `N / M in rows where the parser lost lineup state` (only
     recoverable by fixing the parser/data)
2. **Play-stream totals** — sum from raw rows (Team + playType +
   shotOutcome) independent of lineup tracking. Always matches the
   box score when the play stream is complete.
3. **Actual final-score totals** — parsed from the header's
   finalScore (AWAY-HOME). Same as the Game Facts card.

This three-line footer is the user's transparency mechanism — they
can immediately tell what's filter-driven vs parser-driven.

---

## How to continue the work

A handful of natural starting points for a fresh session:

### High priority

1. **Re-run the full pipeline to apply the roster fallback.** This is
   the single highest-impact remaining fix. The code is committed.
   Just needs ~25-30 min of pipeline time.
   ```bash
   cd /Users/shreyup/CentreBasketballLineupAnalysis
   python3 -B MAT405basketballResearch/getbasketballclean.py
   python3 MAT405basketballResearch/patch_team_attribution.py
   python3 MAT405basketballResearch/patch_extra_periods.py
   python3 MAT405basketballResearch/patch_missing_playtype.py
   python3 MAT405basketballResearch/audit_scores.py /tmp
   ```
   Then re-audit Centre per-season:
   ```bash
   python3 -c "
   import sys, glob, pandas as pd, os
   sys.path.insert(0, 'MAT405basketballResearch')
   from audit_loader import audit_one
   for sport in ['mens-basketball','womens-basketball']:
       for season in sorted(os.listdir(f'{sport}/SAA/centrecolonels/pbp'), reverse=True):
           files = sorted(glob.glob(f'{sport}/SAA/centrecolonels/pbp/{season}/*.csv'))
           if not files: continue
           results = [audit_one(f) for f in files]
           rs = [r for r in results if 'error' not in r]
           d = pd.DataFrame(rs)
           d['cf'] = d.apply(lambda r: r['home_persp_for'] if r['homeTeam']=='centre' else r['away_persp_for'], axis=1)
           d['ca'] = d.apply(lambda r: r['home_persp_against'] if r['homeTeam']=='centre' else r['away_persp_against'], axis=1)
           d['crf'] = d.apply(lambda r: r['real_home'] if r['homeTeam']=='centre' else r['real_away'], axis=1)
           d['cra'] = d.apply(lambda r: r['real_away'] if r['homeTeam']=='centre' else r['real_home'], axis=1)
           d['u'] = (d['crf']-d['cf']) + (d['cra']-d['ca'])
           print(f'  {sport} {season}: {int((d[\"u\"]==0).sum())}/{len(d)} perfect, {int(d[\"u\"].sum())} unattr')
   "
   ```

2. **Investigate why the background pipeline keeps getting killed.**
   Worth running it foreground for a single sport+season at a time
   to confirm it can complete. The killed processes returned exit
   status `killed`, suggesting external termination — maybe an
   OOM killer or session timeout. Add explicit memory profiling /
   confirm Python isn't leaking.

### Medium priority

3. **Apply per-game patcher to the roster-fallback output.** After
   the full pipeline runs with the roster fix, the three patchers
   should still find a few games to clean up. They're idempotent;
   running them is safe.

4. **Add +/− column parsing from the box-score HTML.** The Sidearm
   HTML has a +/− column per player. If we parse that, we get a
   second independent signal (besides minutes) for who was on the
   floor in any given window. Improves the roster fallback's
   accuracy when minutes alone is ambiguous.

5. **Profile older seasons (2010-2014) for un-handled play strings.**
   `validate_pbp.py` reports R8 (unhandled make-rows). After the
   pipeline runs, scan its output for any R8 failures and extend the
   `SHOT_PTS` map + parser case_when as needed.

### Lower priority

6. **Possession-counter validation.** The three possession-counter
   bugs are fixed, but the broader algorithm hasn't been tested
   exhaustively. Run a per-game sanity check: for each game, expected
   possessions ≈ `(FGA + 0.475*FTA - OREB + TOV) / 2`. Anywhere the
   counter disagrees by > 5%, investigate.

7. **Update the validation manifest's R8 / R7 thresholds.** As the
   parser improves, what counts as "low confidence" should tighten.
   Currently any game with confidence < 0.75 is flagged. After the
   roster fix it might be reasonable to raise that to 0.85 or 0.90.

8. **Document the dashboard's Player Combination tab v4 semantics
   somewhere user-facing.** The four-iteration history is in
   session_notes.md but a brief one-page description for coaches
   would help.

### What NOT to touch unless intentionally
- The pre-warm logic. It runs synchronously before `shinyApp()` and
  is what makes the app feel instant. Moving it later would
  reintroduce the slow first-load.
- The `:has()` selector for the sport toggle. Modern Chrome / Safari
  / Firefox handle it. If supporting a really old browser ever
  becomes a concern, add a JS fallback rather than degrading the CSS.
- The `outputOptions(suspendWhenHidden = FALSE)` loop. This is the
  reason tab switches are instant. Removing it brings back the
  multi-second tab-render delay.

---

## Quick-reference command cheat sheet

```bash
cd /Users/shreyup/CentreBasketballLineupAnalysis

# Run the full pipeline (both sports × all schools × all seasons)
python3 -B MAT405basketballResearch/getbasketballclean.py

# Run the pipeline for a single (sport, school, season) — for debugging
python3 -B -c "
import sys; sys.path.insert(0, 'MAT405basketballResearch')
from getbasketballclean import makeHeaderPBP
makeHeaderPBP('mens-basketball', 'centrecolonels', '2025-26')
"

# Run the three CSV-level patchers (each idempotent, can be re-run safely)
python3 MAT405basketballResearch/patch_team_attribution.py
python3 MAT405basketballResearch/patch_extra_periods.py
python3 MAT405basketballResearch/patch_missing_playtype.py

# Or scope a patcher to one season / school
python3 MAT405basketballResearch/patch_team_attribution.py --season 2025-26 --school centrecolonels

# Cross-sport CSV-level audit
python3 MAT405basketballResearch/audit_scores.py /tmp

# Per-game integrity check (confidence manifest)
python3 MAT405basketballResearch/validate_pbp.py

# Dashboard-view audit (mirrors the R loader's filtering)
python3 MAT405basketballResearch/audit_loader.py --school centrecolonels --season 2025-26

# Run the R Shiny app (from RStudio or via Rscript)
Rscript -e "shiny::runApp('MAT405basketballResearch/cenrebasketball.R', port=4567)"
```

### Key file locations

- **Parser**: `MAT405basketballResearch/getbasketballclean.py`
- **Parser helpers**: `MAT405basketballResearch/html_parsers.py`
- **R dashboard**: `MAT405basketballResearch/cenrebasketball.R`
- **CSV data**: `mens-basketball/SAA/<school>/pbp/<season>/*.csv` and
  `womens-basketball/SAA/<school>/pbp/<season>/*.csv`
- **Source HTML**: `<sport>/SAA/<school>/HTML/<season>/*.html`
- **Tables CSV (extracted from HTML)**: `<sport>/SAA/<school>/Tables/<season>/*.csv`
- **Headers CSV (game metadata)**: `<sport>/SAA/<school>/headers/<season>/*.csv`

### Key Python entry points

- `makeHeaderPBP(sport, school, year_str)` — process one (sport, school, season).
- `_correct_team_from_score_deltas(df, home_name, away_name)` — fix Team mis-attribution.
- `_reorder_sub_blocks(df)` — same-clock SUB OUT-before-IN reorder.
- `_normalize_player_key(name)` — canonical key for sub membership.
- `_heal_lineups_from_play_stream(df, home, away, home_roster, away_roster)` — three-pass lineup recovery.
- `_mark_period_starts(possession_starts, period)` — credit the first row of each period.
- `_reattribute_phantom_lineups(df)` — phantom rebound/assist row pairing.

### Key R entry points

- `load_pbp(season, sport=NULL)` — single (sport, season) load (with `normalize_team_fast` optimization).
- `load_pbp_cached(season, sport)` — memoized version, keyed by `"sport::season"`.
- `compute_lineup_metrics(df, selected_team)` — per-lineup aggregator (OFFRTG / DEFRTG / etc).
- `compute_subgroup_pooled_metrics(df, selected_team, n)` — N-player subgroup pooled across lineups.
- `seasons_root_for_sport(sport)` — directory lookup with legacy fallback.
- `current_sport()` — reactive that returns `input$sportInput` with single-sport fallback.

---

End of handoff. Pick up with section [How to continue the work](#how-to-continue-the-work).
