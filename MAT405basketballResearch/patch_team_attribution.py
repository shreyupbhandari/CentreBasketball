"""Score-reconciling patcher for the Team-attribution bug.

A subset of older Sidearm CSV exports have a corrupted `Team` column:

- Some games (mostly 2018-19) cram both teams' plays into one HTML cell.
  The parser's heuristic (`data == df['homePlay'][i]`) then always falls
  through to the else-branch and labels every row's `Team` as the away
  team. Audit signature: only one distinct non-empty Team value per file.

- Other games have two distinct Team values, but the body's home/away
  orientation is INVERTED relative to the header. Per-row deltas of
  `homeTeamScore`/`awayTeamScore` end up matching the FlipScore convention
  while the header's `finalScore` (AWAY-HOME) and `homeScoreByPeriod` /
  `awayScoreByPeriod` describe the opposite assignment.

This patcher takes the header (`finalScore`, plus `homeScoreByPeriod` /
`awayScoreByPeriod`) as ground truth for who-scored-what and rebuilds the
Team column from a player → side map derived from confirmed scoring rows.
Idempotent: re-running on an already-correct file is a no-op.

Run:  python3 MAT405basketballResearch/patch_team_attribution.py
      python3 MAT405basketballResearch/patch_team_attribution.py --dry-run
"""

from __future__ import annotations

import argparse
import glob
import os
import sys

import pandas as pd

SHOT_PTS = {"three pointer": 3, "layup": 2, "jumper": 2, "dunk": 2,
            "tipin": 2, "two pointer": 2, "free throw": 1}


def to_int(s) -> int | None:
    if pd.isna(s):
        return None
    try:
        return int(str(s).strip())
    except (ValueError, AttributeError):
        return None


def parse_period_sum(s) -> int | None:
    """Sum a comma-separated period-score string like '34,44' -> 78."""
    if not isinstance(s, str):
        return None
    try:
        return sum(int(p.strip()) for p in s.split(",") if p.strip())
    except ValueError:
        return None


def compute_pts_per_team(df: pd.DataFrame) -> tuple[int, int, str, str]:
    """Return (team1_pts, team2_pts, team1_lc, team2_lc) for the file's
    current Team column. If there's <2 distinct team values, returns 0/0/'' /''.
    """
    team = df.get("Team", pd.Series(dtype=str)).fillna("").str.strip().str.lower()
    distinct = sorted({t for t in team if t})
    if len(distinct) < 2:
        return 0, 0, (distinct[0] if distinct else ""), ""
    play_type = df.get("playType", pd.Series(dtype=str)).fillna("")
    shot_out = df.get("shotOutcome", pd.Series(dtype=str)).fillna("")
    row_pts = play_type.map(SHOT_PTS).fillna(0).astype(int)
    row_pts = row_pts.where(shot_out == "good", 0)
    t1, t2 = distinct[0], distinct[1]
    return (int(row_pts.where(team == t1, 0).sum()),
            int(row_pts.where(team == t2, 0).sum()), t1, t2)


def score_delta_totals(df: pd.DataFrame) -> tuple[int, int, dict[int, str]]:
    """Walk per-row score columns; return (home_pts_observed, away_pts_observed,
    scored_by) where scored_by[row_index] = 'home' | 'away' for confirmed
    single-side scoring rows."""
    h_series = df["homeTeamScore"].map(to_int)
    a_series = df["awayTeamScore"].map(to_int)
    prev_h = prev_a = 0
    truth_h = truth_a = 0
    scored_by: dict[int, str] = {}
    for i in df.index:
        h = h_series.loc[i]
        a = a_series.loc[i]
        if h is None or a is None:
            continue
        dh = h - prev_h
        da = a - prev_a
        if dh > 0 and da == 0:
            scored_by[i] = "home"
            truth_h += dh
        elif da > 0 and dh == 0:
            scored_by[i] = "away"
            truth_a += da
        prev_h = h if h is not None else prev_h
        prev_a = a if a is not None else prev_a
    return truth_h, truth_a, scored_by


def patch_file(csv_path: str, dry_run: bool = False) -> dict:
    df = pd.read_csv(csv_path, low_memory=False, dtype=str)
    if df.empty:
        return {"file": csv_path, "action": "skip_empty"}

    needed = ["homeTeam", "awayTeam", "finalScore",
              "homeTeamScore", "awayTeamScore", "Player", "Team"]
    if not all(c in df.columns for c in needed):
        return {"file": csv_path, "action": "skip_no_cols"}

    home_team_raw = (df["homeTeam"].iloc[0] or "").strip()
    away_team_raw = (df["awayTeam"].iloc[0] or "").strip()
    if not home_team_raw or not away_team_raw:
        return {"file": csv_path, "action": "skip_no_teams"}
    home_lc = home_team_raw.lower()
    away_lc = away_team_raw.lower()

    final_score = (df["finalScore"].iloc[0] or "").strip()
    if "-" not in final_score:
        return {"file": csv_path, "action": "skip_no_final"}
    try:
        expected_away, expected_home = (int(s.strip()) for s in final_score.split("-", 1))
    except ValueError:
        return {"file": csv_path, "action": "skip_bad_final"}

    # Compute observed per-side totals from running score columns.
    truth_h, truth_a, scored_by = score_delta_totals(df)
    if truth_h + truth_a == 0:
        return {"file": csv_path, "action": "skip_no_scoring"}

    # Compare current Team-attributed totals to finalScore truth.
    team_pts_a, team_pts_b, t1, t2 = compute_pts_per_team(df)
    current_attr_gap = None
    if t1 == home_lc and t2 == away_lc:
        current_attr_gap = abs(team_pts_a - expected_home) + abs(team_pts_b - expected_away)
    elif t1 == away_lc and t2 == home_lc:
        current_attr_gap = abs(team_pts_a - expected_away) + abs(team_pts_b - expected_home)

    # Determine the body→header orientation. Two possibilities:
    #   normal:  body's "home" side == header's home_team (truth_h ~ expected_home)
    #   swapped: body's "home" side == header's away_team (truth_h ~ expected_away)
    normal_fit = abs(truth_h - expected_home) + abs(truth_a - expected_away)
    swap_fit   = abs(truth_h - expected_away) + abs(truth_a - expected_home)
    if normal_fit <= swap_fit:
        orientation = "normal"
        side_for_home_team_in_body = "home"
        side_for_away_team_in_body = "away"
        fit = normal_fit
    else:
        orientation = "swapped"
        side_for_home_team_in_body = "away"
        side_for_away_team_in_body = "home"
        fit = swap_fit

    # If the file's current Team column already lines up with finalScore truth,
    # no patch is needed (catches the vast majority of clean files).
    if current_attr_gap is not None and current_attr_gap == 0:
        return {"file": csv_path, "action": "skip_ok"}

    # If we can't confidently orient (fit > 6), it's likely a truncated or
    # double-game file — don't patch, leave for manual investigation.
    if fit > 6:
        return {"file": csv_path, "action": "skip_unresolvable",
                "normal_fit": normal_fit, "swap_fit": swap_fit}

    # Build player → header_team map from scoring rows.
    # scored_by[idx] = "home"/"away" describes the side of the BODY.
    # Translate body-side to header-team via the orientation:
    body_side_to_header_team = {
        side_for_home_team_in_body: home_lc,
        side_for_away_team_in_body: away_lc,
    }
    player_team: dict[str, str] = {}
    player_conflict: set[str] = set()
    for idx, body_side in scored_by.items():
        p = df.at[idx, "Player"]
        if not isinstance(p, str) or not p.strip():
            continue
        p_lc = p.strip().lower()
        header_team = body_side_to_header_team[body_side]
        if p_lc in player_team and player_team[p_lc] != header_team:
            player_conflict.add(p_lc)
        else:
            player_team[p_lc] = header_team
    for p in player_conflict:
        player_team.pop(p, None)

    if not player_team:
        return {"file": csv_path, "action": "skip_no_player_map"}

    # Re-attribute Team for every row. Priority:
    #   1. Score delta — if running score increased on this row, the scoring
    #      team is unambiguous. Set Team directly from delta + orientation.
    #      This catches rows like "GOOD 2PTR by X" where the parser couldn't
    #      extract Player so the player_team map is useless for them.
    #   2. Player → header_team map (from confirmed scoring rows).
    #   3. possTeam (only when orientation is "normal" — a swapped file's
    #      possTeam is just as inverted as Team).
    #   4. Keep original.
    poss = df.get("possTeam", pd.Series(dtype=str)).fillna("")
    original_team = df["Team"].fillna("")
    new_team = []
    n_changed = 0
    n_unresolved = 0
    for i in df.index:
        # Score-delta direct attribution (highest priority).
        body_side = scored_by.get(i)
        if body_side is not None:
            mapped = body_side_to_header_team[body_side]
            new_team.append(mapped)
            if mapped != original_team.loc[i]:
                n_changed += 1
            continue
        # Player → team map.
        p = df.at[i, "Player"] if pd.notna(df.at[i, "Player"]) else ""
        mapped = None
        if isinstance(p, str) and p.strip():
            mapped = player_team.get(p.strip().lower())
        if mapped is not None:
            new_team.append(mapped)
            if mapped != original_team.loc[i]:
                n_changed += 1
            continue
        # possTeam fallback (normal orientation only).
        if orientation == "normal" and isinstance(poss.loc[i], str) and poss.loc[i].strip():
            new_team.append(poss.loc[i].strip().lower())
            if poss.loc[i].strip().lower() != original_team.loc[i]:
                n_changed += 1
            continue
        new_team.append(original_team.loc[i])
        n_unresolved += 1

    # Sanity check the patched totals match the header.
    play_type = df["playType"].fillna("")
    shot_out = df["shotOutcome"].fillna("")
    row_pts = play_type.map(SHOT_PTS).fillna(0).astype(int)
    row_pts = row_pts.where(shot_out == "good", 0)
    nt = pd.Series(new_team, index=df.index).fillna("")
    new_h = int(row_pts.where(nt == home_lc, 0).sum())
    new_a = int(row_pts.where(nt == away_lc, 0).sum())
    post_gap = abs(new_h - expected_home) + abs(new_a - expected_away)

    summary = {
        "file": csv_path,
        "action": "patched" if n_changed > 0 else "skip_no_change",
        "orientation": orientation,
        "rows": len(df),
        "rows_changed": n_changed,
        "rows_unresolved": n_unresolved,
        "players_mapped": len(player_team),
        "pre_gap": current_attr_gap if current_attr_gap is not None else "?",
        "post_gap": post_gap,
    }

    # Refuse to write if the patch would make things WORSE (defence in depth).
    if current_attr_gap is not None and post_gap > current_attr_gap:
        summary["action"] = "skip_regression"
        return summary

    if not dry_run and n_changed > 0:
        df["Team"] = new_team
        df.to_csv(csv_path, index=False)

    return summary


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--season")
    ap.add_argument("--school")
    args = ap.parse_args()

    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    # Glob both sport directories AND the legacy <root>/SAA. The first
    # path that yields any matches is used. When both layouts coexist —
    # which shouldn't happen post-migration — we just chain them.
    candidates = []
    for sport in ("mens-basketball", "womens-basketball"):
        saa = os.path.join(root, sport, "SAA")
        if os.path.isdir(saa):
            candidates.append(saa)
    legacy = os.path.join(root, "SAA")
    if not candidates and os.path.isdir(legacy):
        candidates.append(legacy)
    files = []
    for saa in candidates:
        files.extend(sorted(glob.glob(os.path.join(
            saa, args.school or "*", "pbp", args.season or "*", "*.csv"))))
    # For relpath display below, use whichever SAA the file lives under.
    saa = candidates[0] if candidates else os.path.join(root, "SAA")
    if not files:
        print(f"No files matched under {candidates}", file=sys.stderr)
        sys.exit(2)

    patched, by_action = [], {}
    for f in files:
        r = patch_file(f, dry_run=args.dry_run)
        by_action[r["action"]] = by_action.get(r["action"], 0) + 1
        if r["action"] == "patched":
            patched.append(r)

    print(f"Scanned {len(files)} files.")
    for k, v in sorted(by_action.items()):
        print(f"  {k}: {v}")
    if patched:
        print()
        print(f"=== First 15 patched files ===")
        for r in patched[:15]:
            short = os.path.relpath(r["file"], saa)
            print(f"  [{r['orientation']:7s}] pre={r['pre_gap']!s:3s} post={r['post_gap']:3d} "
                  f"changed={r['rows_changed']:4d}/{r['rows']:4d}  {short[:75]}")


if __name__ == "__main__":
    main()
