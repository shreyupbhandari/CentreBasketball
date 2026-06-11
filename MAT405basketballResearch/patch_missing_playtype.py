"""Backfill `playType` and `shotOutcome` on rows where the per-row score
clearly shows a scoring event but the parser couldn't classify the play.

Real-world examples found in the dataset:
  - "GOOD  by GERALD,DUSTIN"    — older Sidearm format, no shot type word
  - "GOOD FT by" with no player — parser left both Player and shotOutcome blank
  - "GOOD 3PTR by X" classified as missed (parser bug)

These cause small residual reconciliation gaps (1-4 pts per affected game,
adds up to ~50 pts across the dataset). For each such row we look at the
score delta and the play text; if confident, write:
    shotOutcome = "good"
    playType    = "jumper"|"three pointer"|"free throw"|"tipin" based on text
The dashboard's case_when then credits the point.

Idempotent. Run:
    python3 MAT405basketballResearch/patch_missing_playtype.py
    python3 MAT405basketballResearch/patch_missing_playtype.py --dry-run
"""

from __future__ import annotations

import argparse
import glob
import os
import re
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


def classify_play_text(play: str, pts: int) -> str | None:
    """Infer playType from raw Play text + the points value implied by the
    score delta. Returns None if we can't be confident."""
    if not isinstance(play, str):
        return None
    p = play.lower()
    if "ft" in p or "free throw" in p:
        return "free throw"
    if "3ptr" in p or "three pointer" in p or pts == 3:
        return "three pointer"
    if "tipin" in p or "tip in" in p or "tip-in" in p:
        return "tipin"
    if "layup" in p:
        return "layup"
    if "dunk" in p:
        return "dunk"
    if "2ptr" in p:
        return "two pointer"
    if "jumper" in p:
        return "jumper"
    # Generic "GOOD by X" with no specifier — default to jumper (2-pt) when
    # the score delta is 2.
    if pts == 2 and re.search(r"\bgood\b", p):
        return "jumper"
    if pts == 1 and re.search(r"\bgood\b", p):
        return "free throw"
    return None


def patch_file(csv_path: str, dry_run: bool = False) -> dict:
    df = pd.read_csv(csv_path, low_memory=False, dtype=str)
    if df.empty:
        return {"file": csv_path, "action": "skip_empty"}
    needed = ("homeTeamScore", "awayTeamScore", "playType", "shotOutcome", "Play")
    if not all(c in df.columns for c in needed):
        return {"file": csv_path, "action": "skip_no_cols"}

    h = df["homeTeamScore"].map(to_int).tolist()
    a = df["awayTeamScore"].map(to_int).tolist()
    play_type = df["playType"].fillna("").tolist()
    shot_out = df["shotOutcome"].fillna("").tolist()
    play_text = df["Play"].fillna("").tolist()

    new_pt = list(play_type)
    new_so = list(shot_out)
    n_changed = 0
    prev_h = prev_a = 0
    for i in range(len(df)):
        ch = h[i] if h[i] is not None else prev_h
        ca = a[i] if a[i] is not None else prev_a
        dh = ch - prev_h
        da = ca - prev_a
        prev_h, prev_a = ch, ca

        score_delta = max(dh, da, 0)
        # Only act when one side incremented (clean signal) and the existing
        # playType+shotOutcome wouldn't credit the points.
        if score_delta <= 0 or score_delta > 3:
            continue
        already_credits = (shot_out[i] == "good" and play_type[i] in SHOT_PTS
                           and SHOT_PTS.get(play_type[i]) == score_delta)
        if already_credits:
            continue

        inferred = classify_play_text(play_text[i], score_delta)
        if inferred is None:
            continue
        # Sanity: the inferred playType's nominal points should match delta.
        if SHOT_PTS.get(inferred) != score_delta:
            continue
        if new_pt[i] != inferred or new_so[i] != "good":
            new_pt[i] = inferred
            new_so[i] = "good"
            n_changed += 1

    if n_changed == 0:
        return {"file": csv_path, "action": "skip_no_change"}

    if not dry_run:
        df["playType"] = new_pt
        df["shotOutcome"] = new_so
        df.to_csv(csv_path, index=False)

    return {"file": csv_path, "action": "patched", "rows_changed": n_changed}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--season")
    ap.add_argument("--school")
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
    patched = []
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
        print("=== Patched files (first 15) ===")
        for r in patched[:15]:
            print(f"  changed={r['rows_changed']:3d}  {os.path.relpath(r['file'], saa)[:80]}")


if __name__ == "__main__":
    main()
