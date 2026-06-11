"""Replicate the R loader's row-filtering and re-audit.

The cross-school CSV audit (`audit_scores.py`) reads raw CSVs and reports
98.9% perfect reconciliation. But the dashboard's `load_pbp()` drops
several row classes before computing lineup metrics:

  * `playerMissing == 1` rows
  * rows where any of the 10 lineup slots is NA or "None"
  * OLD-CSV phantom rows (timeRemaining=="--" with possStart/teamChanged
    flags still set to 1)

Any made-shot row dropped by these filters silently lowers the dashboard's
total points. This script applies the same filters and reports the gap.
"""

from __future__ import annotations

import glob
import os
import sys

import pandas as pd

SHOT_PTS = {"three pointer": 3, "layup": 2, "jumper": 2, "dunk": 2,
            "tipin": 2, "two pointer": 2, "free throw": 1}


def apply_loader_filters(df: pd.DataFrame) -> tuple[pd.DataFrame, dict]:
    """Mirror load_pbp() AS OF the post-Session-2 architecture: rows with NA
    lineup slots / playerMissing=1 are no longer dropped — they remain in
    the loader output so total scores stay correct. The per-lineup tables
    in the dashboard still filter !is.na(CentreLineup), so this audit
    tracks BOTH:
      - rows_after_filters: what survives for raw scoring totals (== all rows).
      - rows_with_valid_lineup: subset attributable to a specific lineup.
    """
    counts = {"start": len(df)}

    # 1. Strip jerseys (not row-dropping, but parity).
    player_cols = [c for c in (["Player"] + [f"awayPlayer{i}" for i in range(1,6)]
                               + [f"homePlayer{i}" for i in range(1,6)]) if c in df.columns]
    for c in player_cols:
        df[c] = df[c].astype(str).str.replace(r"^\d+,", "", regex=True)
        df[c] = df[c].str.replace(r",\d+$", "", regex=True)

    # Normalize "None"/"" to NaN in lineup slots (matches new load_pbp).
    lineup_cols = [c for c in ([f"awayPlayer{i}" for i in range(1,6)]
                               + [f"homePlayer{i}" for i in range(1,6)]) if c in df.columns]
    if lineup_cols:
        for c in lineup_cols:
            df[c] = df[c].astype(str).where(~df[c].astype(str).isin(["None", "", "nan"]),
                                            other=pd.NA)
        # Track how many rows DON'T have a complete lineup (these end up in
        # the NA-CentreLineup bucket and disappear from per-lineup tabs).
        none_mask = pd.Series(False, index=df.index)
        for c in lineup_cols:
            none_mask |= df[c].isna()
        counts["rows_no_valid_lineup"] = int(none_mask.sum())

    if "playerMissing" in df.columns:
        counts["rows_playerMissing_1"] = int(
            pd.to_numeric(df["playerMissing"], errors="coerce").fillna(0).eq(1).sum()
        )

    # 4. Old-CSV phantom-row drop: if any non-clock row has possStart==1 or
    #    teamChanged==1, drop ALL non-clock rows.
    if "timeRemaining" in df.columns:
        is_real = df["timeRemaining"].astype(str).str.match(r"^\d+:\d+$").fillna(False)
        if (~is_real).any():
            phantom_has_bad_flags = False
            for col in ("possStart", "teamChanged"):
                if col in df.columns:
                    vals = pd.to_numeric(df[col][~is_real], errors="coerce")
                    if (vals == 1).any():
                        phantom_has_bad_flags = True
                        break
            if phantom_has_bad_flags:
                df = df[is_real].copy()
                counts["after_phantom_drop"] = len(df)

    counts["end"] = len(df)
    return df, counts


def audit_one(csv_path: str) -> dict:
    raw = pd.read_csv(csv_path, low_memory=False, dtype=str)
    if raw.empty:
        return {"file": csv_path, "error": "empty"}

    home = (raw["homeTeam"].iloc[0] or "").strip().lower()
    away = (raw["awayTeam"].iloc[0] or "").strip().lower()
    final = (raw["finalScore"].iloc[0] or "").strip()
    try:
        exp_away, exp_home = (int(s.strip()) for s in final.split("-", 1))
    except ValueError:
        return {"file": csv_path, "error": "bad_final"}

    pt_raw = raw["playType"].fillna("")
    so_raw = raw["shotOutcome"].fillna("")
    team_raw = raw["Team"].fillna("").str.strip().str.lower()
    rp_raw = pt_raw.map(SHOT_PTS).fillna(0).astype(int).where(so_raw == "good", 0)
    pre_home = int(rp_raw.where(team_raw == home, 0).sum())
    pre_away = int(rp_raw.where(team_raw == away, 0).sum())

    filtered, counts = apply_loader_filters(raw.copy())

    # All-rows totals (matches the new "Play-stream totals" line in the
    # dashboard).
    pt = filtered["playType"].fillna("")
    so = filtered["shotOutcome"].fillna("")
    team = filtered["Team"].fillna("").str.strip().str.lower()
    rp = pt.map(SHOT_PTS).fillna(0).astype(int).where(so == "good", 0)
    all_home = int(rp.where(team == home, 0).sum())
    all_away = int(rp.where(team == away, 0).sum())

    # Lineup-attributable subset for the SELECTED TEAM's lineup. The
    # dashboard's `build_lineup()` pulls the 5 slots from the side the
    # selected team is on (awayPlayer1..5 when selected is away, etc.).
    # We compute attribution from BOTH teams' perspectives so both numbers
    # in the audit match what the dashboard shows when the user picks
    # either team.
    home_cols = [f"homePlayer{i}" for i in range(1, 6)]
    away_cols = [f"awayPlayer{i}" for i in range(1, 6)]
    has_home_lineup = pd.Series(True, index=filtered.index)
    for c in home_cols:
        if c in filtered.columns:
            has_home_lineup &= filtered[c].notna()
    has_away_lineup = pd.Series(True, index=filtered.index)
    for c in away_cols:
        if c in filtered.columns:
            has_away_lineup &= filtered[c].notna()

    # When the user picks team T in the dashboard, every row is grouped by
    # T's 5-man lineup. T's pointsEarned counts plays where Team == T AND
    # T's lineup slots are complete. The OPPONENT's points-against also
    # require T's lineup to be complete, because the grouping is by T's
    # lineup — opponent scoring rows where T's lineup snapshot is NaN
    # don't land in any displayable T-lineup group either.
    #
    # We compute BOTH perspectives (home-selected and away-selected) so
    # the audit matches whichever team the user picks.
    home_persp_for     = int(rp.where(has_home_lineup & (team == home), 0).sum())  # home-selected scored
    home_persp_against = int(rp.where(has_home_lineup & (team == away), 0).sum())  # home-selected gave up
    away_persp_for     = int(rp.where(has_away_lineup & (team == away), 0).sum())  # away-selected scored
    away_persp_against = int(rp.where(has_away_lineup & (team == home), 0).sum())  # away-selected gave up
    # Legacy field names: attr_home == what gets attributed when HOME is
    # selected and the user is looking at home team's score.
    attr_home = home_persp_for
    attr_away = away_persp_for

    # When the picked team is the HOME team in this game, the user sees
    # picked-team-scored = home_persp_for and opponent-scored = home_persp_against.
    # When picked team is AWAY, swap. Many tasks ask "if I pick Centre,
    # what does it look like?" — Centre is sometimes home, sometimes away,
    # so we report both perspectives and a `centre_persp_*` slot too if
    # Centre is one of the teams.
    return {
        "file": os.path.basename(csv_path),
        "homeTeam": home, "awayTeam": away,
        "real_home": exp_home, "real_away": exp_away,
        "pre_home": pre_home, "pre_away": pre_away,
        "pre_gap": abs(pre_home - exp_home) + abs(pre_away - exp_away),
        "all_home": all_home, "all_away": all_away,
        "attr_home": attr_home, "attr_away": attr_away,
        "home_persp_for": home_persp_for, "home_persp_against": home_persp_against,
        "away_persp_for": away_persp_for, "away_persp_against": away_persp_against,
        "all_gap": abs(all_home - exp_home) + abs(all_away - exp_away),
        "attr_gap": abs(attr_home - exp_home) + abs(attr_away - exp_away),
        "unattributed_pts": (all_home - attr_home) + (all_away - attr_away),
        "rows_total": counts.get("start", 0),
        "rows_no_valid_lineup": counts.get("rows_no_valid_lineup", 0),
    }


def main():
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument("--season", default="*")
    ap.add_argument("--school", default="*")
    args = ap.parse_args()

    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    candidates = []
    for sport in ("mens-basketball", "womens-basketball"):
        p = os.path.join(root, sport, "SAA")
        if os.path.isdir(p):
            candidates.append(p)
    legacy = os.path.join(root, "SAA")
    if not candidates and os.path.isdir(legacy):
        candidates.append(legacy)
    files = []
    for saa_path in candidates:
        files.extend(sorted(glob.glob(os.path.join(
            saa_path, args.school, "pbp", args.season, "*.csv"))))

    rows = [audit_one(f) for f in files]
    df = pd.DataFrame([r for r in rows if "error" not in r])
    df.to_csv("/tmp/audit_loader.csv", index=False)

    total = len(df)
    raw_perfect = int((df["pre_gap"] == 0).sum())
    all_perfect = int((df["all_gap"] == 0).sum())
    attr_perfect = int((df["attr_gap"] == 0).sum())
    unattr_games = df[df["unattributed_pts"] > 0]
    print(f"Audited {total} games (school={args.school} season={args.season})")
    print(f"  Raw CSV perfect:                       {raw_perfect}")
    print(f"  Play-stream totals match real:         {all_perfect}")
    print(f"  Lineup-attributable matches real:      {attr_perfect}")
    print(f"  Games with UNATTRIBUTED points:        {len(unattr_games)}  total pts: {int(unattr_games['unattributed_pts'].sum())}")
    if len(unattr_games):
        print()
        print("Top 20 by unattributed points (parser lineup tracking failed):")
        print(unattr_games[["file","real_home","real_away","all_home","all_away","attr_home","attr_away","unattributed_pts","rows_no_valid_lineup"]].sort_values("unattributed_pts", ascending=False).head(20).to_string())


if __name__ == "__main__":
    main()
