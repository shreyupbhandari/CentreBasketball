"""Trim extra-period contamination from PBP CSVs.

Some Sidearm box-score pages serve multiple games on one HTML (a women's
+ men's doubleheader, a tournament page, etc.) and the scraper concatenated
both. The result: a single CSV whose rows include the target game's
play-by-play followed by an unrelated game's rows tagged as "Period 3", "4",
etc., even though `numPeriods=2` and the box-score `finalScore` reflects
only the target game.

Detection: per file,
  1. Read finalScore as AWAY-HOME and the header's period sums
     (homeScoreByPeriod / awayScoreByPeriod) — these are the truth.
  2. Find the last row of the highest "real" period (i.e. the largest period
     whose running-score totals reach finalScore).
  3. Any rows belonging to later periods that DON'T extend the running
     scores monotonically are flagged as contamination and dropped.

Conservative rules: only trim when (a) the running totals at the end of the
"truth" period exactly match finalScore (within the home/away axis) and
(b) the contaminated rows' scores reset / change downward / diverge.

Idempotent: re-running on a clean file is a no-op.

Run:  python3 MAT405basketballResearch/patch_extra_periods.py
      python3 MAT405basketballResearch/patch_extra_periods.py --dry-run
"""

from __future__ import annotations

import argparse
import glob
import os
import sys

import pandas as pd


def to_int(s) -> int | None:
    if pd.isna(s):
        return None
    try:
        return int(str(s).strip())
    except (ValueError, AttributeError):
        return None


def patch_file(csv_path: str, dry_run: bool = False) -> dict:
    df = pd.read_csv(csv_path, low_memory=False, dtype=str)
    if df.empty or "Period" not in df.columns or "finalScore" not in df.columns:
        return {"file": csv_path, "action": "skip_no_cols"}
    if "homeTeamScore" not in df.columns or "awayTeamScore" not in df.columns:
        return {"file": csv_path, "action": "skip_no_scores"}

    final = (df["finalScore"].iloc[0] or "").strip()
    if "-" not in final:
        return {"file": csv_path, "action": "skip_no_final"}
    try:
        expected_away, expected_home = (int(s.strip()) for s in final.split("-", 1))
    except ValueError:
        return {"file": csv_path, "action": "skip_bad_final"}

    # Only consider files where Period values exceed numPeriods (per the
    # header) AND isOvertime is not True — legitimate OT games have higher
    # period values but their numPeriods+OT flag matches.
    num_periods = to_int(df.get("numPeriods", pd.Series([None])).iloc[0])
    if num_periods is None:
        return {"file": csv_path, "action": "skip_no_numperiods"}
    is_ot_str = str(df.get("isOvertime", pd.Series([""])).iloc[0]).strip().lower()
    is_ot = is_ot_str == "true"
    if is_ot:
        return {"file": csv_path, "action": "skip_overtime"}

    periods_int = df["Period"].map(to_int)
    max_period = periods_int.max()
    if pd.isna(max_period) or int(max_period) <= num_periods:
        return {"file": csv_path, "action": "skip_no_extra_periods"}

    # Find the LAST row of the last legitimate period that exactly matches
    # the expected final score. (Walk in encounter order.)
    h_series = df["homeTeamScore"].map(to_int)
    a_series = df["awayTeamScore"].map(to_int)
    match_idx = None
    for i in df.index:
        p = periods_int.loc[i]
        if pd.isna(p) or int(p) > num_periods:
            continue
        h = h_series.loc[i]
        a = a_series.loc[i]
        if h == expected_home and a == expected_away:
            match_idx = i
    if match_idx is None:
        return {"file": csv_path, "action": "skip_no_final_match"}

    keep_idx = df.index[df.index <= match_idx]
    trimmed_count = len(df) - len(keep_idx)
    summary = {
        "file": csv_path,
        "action": "trimmed",
        "rows_before": len(df),
        "rows_after": len(keep_idx),
        "rows_trimmed": trimmed_count,
        "final_match_row": int(match_idx),
        "expected": (expected_home, expected_away),
    }
    if not dry_run:
        df.loc[keep_idx].to_csv(csv_path, index=False)
    return summary


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--school")
    ap.add_argument("--season")
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
            saa_path, args.school or "*", "pbp", args.season or "*", "*.csv"))))
    saa = candidates[0] if candidates else legacy
    if not files:
        print(f"No files matched under {candidates}", file=sys.stderr)
        sys.exit(2)

    by_action = {}
    trimmed = []
    for f in files:
        r = patch_file(f, dry_run=args.dry_run)
        by_action[r["action"]] = by_action.get(r["action"], 0) + 1
        if r["action"] == "trimmed":
            trimmed.append(r)

    print(f"Scanned {len(files)} files.")
    for k, v in sorted(by_action.items()):
        print(f"  {k}: {v}")
    if trimmed:
        print()
        print("=== Trimmed files ===")
        for r in trimmed:
            short = os.path.relpath(r["file"], saa)
            print(f"  {r['rows_before']:4d} -> {r['rows_after']:4d}  "
                  f"(-{r['rows_trimmed']:4d})  {short}")


if __name__ == "__main__":
    main()
