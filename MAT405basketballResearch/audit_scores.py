"""Cross-school, cross-season score-reconciliation audit.

For every play-by-play CSV under SAA/<school>/pbp/<season>/, computes
home_pts / away_pts from the play stream (the corrected case_when:
layup, jumper, dunk, three pointer, free throw, tipin, two pointer)
and compares them to the header's finalScore (which is "AWAY-HOME").

Outputs:
  audit_scores_master.csv  — one row per game, with gaps and diagnostics.
  audit_scores_summary.csv — per (school, season) gap totals.

Run from the project root or this file's directory.
"""

from __future__ import annotations

import csv
import glob
import os
import re
import sys
from collections import defaultdict

import pandas as pd

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

def _saa_roots(root):
    """Return [(sport, abs_saa_path), ...] for every installed sport.
    Falls back to a single (None, <root>/SAA) entry for legacy single-sport
    installs that didn't get migrated."""
    roots = []
    for sport in ("mens-basketball", "womens-basketball"):
        p = os.path.join(root, sport, "SAA")
        if os.path.isdir(p):
            roots.append((sport, p))
    if not roots and os.path.isdir(os.path.join(root, "SAA")):
        roots.append((None, os.path.join(root, "SAA")))
    return roots

SAA = os.path.join(ROOT, "SAA")  # kept for backward refs

# Plays worth N points when shotOutcome == "good".
SHOT_POINTS = {
    "three pointer": 3,
    "layup": 2,
    "jumper": 2,
    "dunk": 2,
    "tipin": 2,
    "two pointer": 2,
    "free throw": 1,
}

CLOCK_RE = re.compile(r"^\d+:\d+$")


def parse_clock(s: str) -> float | None:
    if not isinstance(s, str) or not CLOCK_RE.match(s):
        return None
    m, sec = s.split(":")
    return int(m) * 60 + int(sec)


def normalize_team(s: str) -> str:
    """Light normalization mirroring the R loader's normalize_team()."""
    if not isinstance(s, str):
        return ""
    s = s.strip()
    s = re.sub(r"^#\d+\s+", "", s)
    s = re.sub(r"\s*\([^)]*\)\s*$", "", s)
    s = re.sub(r"~\d+$", "", s)
    s = re.sub(r"[ _\-](MB|WB|M|W)$", "", s, flags=re.IGNORECASE)
    if (s.isupper() or s.islower()) and s:
        s = s.title()
    s = re.sub(r"\s+(Men|Women)\s*$", "", s, flags=re.IGNORECASE).strip()
    aliases = {"Centre College", "Centrem", "Centremb"}
    if s in aliases:
        s = "Centre"
    return s


def audit_game(csv_path: str) -> dict | None:
    """Compute per-game audit row, or None if unreadable / empty."""
    try:
        df = pd.read_csv(csv_path, low_memory=False, dtype=str)
    except Exception as e:
        return {"file": csv_path, "error": f"read_csv: {e}"}

    if df.empty:
        return {"file": csv_path, "error": "empty"}

    home_team_raw = df["homeTeam"].iloc[0] if "homeTeam" in df.columns else ""
    away_team_raw = df["awayTeam"].iloc[0] if "awayTeam" in df.columns else ""
    home_team = normalize_team(home_team_raw)
    away_team = normalize_team(away_team_raw)

    final_score = df["finalScore"].iloc[0] if "finalScore" in df.columns else ""
    real_away = real_home = None
    if isinstance(final_score, str) and "-" in final_score:
        try:
            a, h = final_score.split("-", 1)
            real_away = int(a.strip())
            real_home = int(h.strip())
        except ValueError:
            pass

    # Compute points from the play stream using the corrected case_when.
    play_type = df.get("playType", pd.Series([""] * len(df), dtype=str)).fillna("")
    shot_out = df.get("shotOutcome", pd.Series([""] * len(df), dtype=str)).fillna("")
    team_col = df.get("Team", pd.Series([""] * len(df), dtype=str)).fillna("")

    # Mirror the R loader's repair_team_attribution(): if the Team column is
    # monotone (single distinct non-empty value), re-derive per row by
    # looking up Player in the home/away lineup snapshot columns.
    team_corrected = False
    distinct_teams = {t.strip().lower() for t in team_col if isinstance(t, str) and t.strip()}
    if len(distinct_teams) <= 1 and "Player" in df.columns:
        player = df["Player"].fillna("")
        home_slots = [df.get(f"homePlayer{i}", pd.Series([""] * len(df), dtype=str)).fillna("") for i in range(1, 6)]
        away_slots = [df.get(f"awayPlayer{i}", pd.Series([""] * len(df), dtype=str)).fillna("") for i in range(1, 6)]
        in_home = pd.Series(False, index=df.index)
        in_away = pd.Series(False, index=df.index)
        for s in home_slots:
            in_home |= (player == s) & (player != "")
        for s in away_slots:
            in_away |= (player == s) & (player != "")
        new_team = team_col.copy()
        only_home = in_home & ~in_away
        only_away = in_away & ~in_home
        new_team = new_team.mask(only_home, home_team.lower())
        new_team = new_team.mask(only_away, away_team.lower())
        # Fallback to possTeam for unresolved rows.
        unresolved = ~in_home & ~in_away
        if "possTeam" in df.columns:
            poss = df["possTeam"].fillna("")
            new_team = new_team.mask(unresolved & (poss != ""), poss)
        team_col = new_team
        team_corrected = True

    pts_per_row = play_type.map(SHOT_POINTS).fillna(0).astype(int)
    pts_per_row = pts_per_row.where(shot_out == "good", 0)

    actor_norm = team_col.str.strip().str.lower()
    home_lc = home_team.lower()
    away_lc = away_team.lower()

    computed_home = int(pts_per_row.where(actor_norm == home_lc, 0).sum())
    computed_away = int(pts_per_row.where(actor_norm == away_lc, 0).sum())
    # Some older feeds have variants (e.g., "centre college" vs "Centre"). Try
    # a normalized-fallback match for the actor team too.
    actor_norm2 = team_col.map(lambda x: normalize_team(x).lower() if isinstance(x, str) else "")
    computed_home2 = int(pts_per_row.where(actor_norm2 == home_lc, 0).sum())
    computed_away2 = int(pts_per_row.where(actor_norm2 == away_lc, 0).sum())
    # Use the better of the two matchings.
    if computed_home2 + computed_away2 > computed_home + computed_away:
        computed_home, computed_away = computed_home2, computed_away2

    # Row diagnostics.
    n_rows = len(df)
    tr = df.get("timeRemaining", pd.Series([""] * n_rows, dtype=str)).fillna("")
    real_clock_mask = tr.str.match(r"^\d+:\d+$").fillna(False)
    n_real = int(real_clock_mask.sum())
    n_phantom = n_rows - n_real

    # Minutes captured: sum elapsed seconds across real-clock rows by period.
    minutes_captured = 0.0
    if "Period" in df.columns:
        sub = df[real_clock_mask].copy()
        sub["clock_s"] = sub["timeRemaining"].map(parse_clock)
        for _, grp in sub.groupby("Period", sort=False):
            cs = grp["clock_s"].tolist()
            if not cs or cs[0] is None:
                continue
            period_start = max(c for c in cs if c is not None)
            prev = period_start
            for c in cs:
                if c is None:
                    continue
                delta = prev - c
                if delta > 0:
                    minutes_captured += delta
                prev = c
        minutes_captured = round(minutes_captured / 60.0, 2)

    # Player-missing flag (some pipelines wrote it as 0/1).
    player_missing_dropped = 0
    if "playerMissing" in df.columns:
        try:
            player_missing_dropped = int(
                pd.to_numeric(df["playerMissing"], errors="coerce").fillna(0).gt(0).sum()
            )
        except Exception:
            pass

    # Make-shot rows by unhandled types — quick flag for "data is there but
    # case_when missed it" cases.
    unhandled_make_rows = 0
    if "playType" in df.columns and "shotOutcome" in df.columns:
        unhandled_mask = (
            (shot_out == "good")
            & (~play_type.isin(SHOT_POINTS.keys()))
            & (play_type != "")
            & (~play_type.isin(["assist", "block", "steal", "offensive rebound", "defensive rebound"]))
        )
        unhandled_make_rows = int(unhandled_mask.sum())

    # Compute gaps (positive = missing points).
    home_gap = (real_home - computed_home) if real_home is not None else None
    away_gap = (real_away - computed_away) if real_away is not None else None
    total_gap = (
        abs(home_gap) + abs(away_gap)
        if home_gap is not None and away_gap is not None
        else None
    )

    return {
        "file": os.path.basename(csv_path),
        "home_team": home_team,
        "away_team": away_team,
        "real_home": real_home,
        "real_away": real_away,
        "computed_home": computed_home,
        "computed_away": computed_away,
        "home_gap": home_gap,
        "away_gap": away_gap,
        "total_gap": total_gap,
        "n_rows": n_rows,
        "n_real_clock": n_real,
        "n_phantom": n_phantom,
        "minutes_captured": minutes_captured,
        "unhandled_make_rows": unhandled_make_rows,
        "player_missing_dropped": player_missing_dropped,
        "team_corrected": team_corrected,
        "final_score": final_score,
    }


def main(out_dir: str = "/tmp") -> None:
    rows = []
    for sport, saa_path in _saa_roots(ROOT):
        schools = sorted(d for d in os.listdir(saa_path)
                         if os.path.isdir(os.path.join(saa_path, d)))
        for school in schools:
            pbp_root = os.path.join(saa_path, school, "pbp")
            if not os.path.isdir(pbp_root):
                continue
            seasons = sorted(os.listdir(pbp_root))
            for season in seasons:
                season_dir = os.path.join(pbp_root, season)
                if not os.path.isdir(season_dir):
                    continue
                for csv_path in sorted(glob.glob(os.path.join(season_dir, "*.csv"))):
                    r = audit_game(csv_path)
                    if r is None:
                        continue
                    r["sport"] = sport or "mens-basketball"
                    r["school"] = school
                    r["season"] = season
                    rows.append(r)

    if not rows:
        print("No games found.", file=sys.stderr)
        return

    df = pd.DataFrame(rows)
    cols = [
        "school", "season", "file", "home_team", "away_team",
        "real_home", "real_away", "computed_home", "computed_away",
        "home_gap", "away_gap", "total_gap",
        "n_rows", "n_real_clock", "n_phantom",
        "minutes_captured", "unhandled_make_rows",
        "player_missing_dropped", "final_score",
    ]
    df = df.reindex(columns=cols + [c for c in df.columns if c not in cols])
    master = os.path.join(out_dir, "audit_scores_master.csv")
    df.to_csv(master, index=False)

    has_gap = df.dropna(subset=["total_gap"])
    summary = (
        has_gap.groupby(["school", "season"])
        .agg(
            games=("file", "count"),
            perfect=("total_gap", lambda s: int((s == 0).sum())),
            mean_gap=("total_gap", "mean"),
            max_gap=("total_gap", "max"),
            sum_abs_gap=("total_gap", "sum"),
            mean_minutes=("minutes_captured", "mean"),
            unhandled_makes=("unhandled_make_rows", "sum"),
        )
        .reset_index()
    )
    summary["pct_perfect"] = (summary["perfect"] / summary["games"] * 100).round(1)
    summary_csv = os.path.join(out_dir, "audit_scores_summary.csv")
    summary.to_csv(summary_csv, index=False)

    print(f"Wrote {master} ({len(df)} games)")
    print(f"Wrote {summary_csv} ({len(summary)} school-season rows)")
    print()
    print("=== Top-level totals ===")
    total = len(df)
    with_gap = len(has_gap)
    perfect = int((has_gap["total_gap"] == 0).sum())
    print(f"  total games: {total}")
    print(f"  games with usable real score: {with_gap}")
    print(f"  perfect reconciliations (gap=0): {perfect}  ({perfect/with_gap*100:.1f}%)")
    print(f"  median gap: {has_gap['total_gap'].median():.1f}")
    print(f"  mean gap:   {has_gap['total_gap'].mean():.1f}")
    print(f"  total unhandled make-rows across dataset: {int(has_gap['unhandled_make_rows'].sum())}")


if __name__ == "__main__":
    out = sys.argv[1] if len(sys.argv) > 1 else "/tmp"
    main(out)
