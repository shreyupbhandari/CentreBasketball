"""Per-game integrity check that any newly produced PBP CSV must pass.

Designed to run after `getbasketballclean.py` finishes a season, or any
time after a scraper update. It reads every CSV under SAA/*/pbp/<season>/
and computes a small set of cheap sanity checks. Each game gets a
confidence score (0 = irrecoverable; 1.0 = passes every check).

Checks:
  R1  finalScore parseable as "AWAY-HOME"
  R2  >= 100 real-clock rows (otherwise the PBP is severely truncated)
  R3  Minutes captured within 5 minutes of expected game length
      (40 for men's, +5 per OT period if isOvertime)
  R4  Team column has >= 2 distinct non-empty values
  R5  Per-row score totals reach exactly the finalScore in some row
  R6  Score deltas don't regress > 5 points (signals internal corruption)
  R7  Sum of made-shot points-per-team matches finalScore (gap <= 1)
  R8  No more than 2 distinct unhandled scoring playTypes
        (catches new Sidearm play strings the parser doesn't classify)

Writes a manifest CSV with each game's pass/fail per check and a final
confidence score. Designed to be diffable across runs so regressions
show up immediately.

Usage:
  python3 MAT405basketballResearch/validate_pbp.py
  python3 MAT405basketballResearch/validate_pbp.py --season 2023-24
"""

from __future__ import annotations

import argparse
import glob
import os
import sys

import pandas as pd

SHOT_PTS = {"three pointer": 3, "layup": 2, "jumper": 2, "dunk": 2,
            "tipin": 2, "two pointer": 2, "free throw": 1}
NON_SCORING_TYPES = {
    "subbing in", "subbing out", "sub", "starter",
    "defensive rebound", "offensive rebound", "deadball rebound",
    "foul", "turnover", "steal", "assist", "block", "timeout",
}


def to_int(s) -> int | None:
    if pd.isna(s):
        return None
    try:
        return int(str(s).strip())
    except (ValueError, AttributeError):
        return None


def expected_minutes(num_periods: int, is_ot: bool) -> float:
    base = 40.0   # NCAA men's regulation
    if is_ot and num_periods and num_periods > 2:
        # crude: every period beyond 2 is a 5-minute OT
        base += 5.0 * (num_periods - 2)
    return base


def validate_file(csv_path: str) -> dict:
    try:
        df = pd.read_csv(csv_path, low_memory=False, dtype=str)
    except Exception as e:
        return {"file": csv_path, "error": f"read_csv: {e}", "confidence": 0.0}
    if df.empty:
        return {"file": csv_path, "error": "empty", "confidence": 0.0}

    final = (df["finalScore"].iloc[0] or "").strip() if "finalScore" in df.columns else ""
    try:
        exp_away, exp_home = (int(s.strip()) for s in final.split("-", 1))
        R1 = True
    except ValueError:
        exp_away = exp_home = None
        R1 = False

    n_real = int(df["timeRemaining"].astype(str).str.match(r"^\d+:\d+$").sum())
    R2 = n_real >= 100

    # Minutes captured
    mins = 0.0
    if "Period" in df.columns:
        real = df[df["timeRemaining"].astype(str).str.match(r"^\d+:\d+$")].copy()
        if not real.empty:
            real["sec"] = real["timeRemaining"].map(
                lambda s: int(s.split(":")[0]) * 60 + int(s.split(":")[1])
                if isinstance(s, str) and ":" in s else None)
            for _, grp in real.groupby("Period", sort=False):
                xs = [x for x in grp["sec"].tolist() if x is not None]
                if not xs:
                    continue
                start = max(xs)
                prev = start
                for c in xs:
                    if c is None:
                        continue
                    d = prev - c
                    if d > 0:
                        mins += d
                    prev = c
            mins /= 60.0

    num_periods = to_int(df["numPeriods"].iloc[0]) if "numPeriods" in df.columns else 2
    is_ot = str(df.get("isOvertime", pd.Series([""])).iloc[0]).strip().lower() == "true"
    exp_mins = expected_minutes(num_periods or 2, is_ot)
    R3 = abs(mins - exp_mins) <= 5.0

    teams_distinct = {t.strip().lower() for t in df.get("Team", pd.Series(dtype=str)).fillna("") if t.strip()}
    R4 = len(teams_distinct) >= 2

    # R5: do per-row scores ever reach exactly finalScore?
    R5 = False
    if exp_home is not None and "homeTeamScore" in df.columns:
        h = df["homeTeamScore"].map(to_int)
        a = df["awayTeamScore"].map(to_int)
        R5 = bool(((h == exp_home) & (a == exp_away)).any())

    # R6: any > 5pt score regression
    R6 = True
    if "homeTeamScore" in df.columns:
        h = df["homeTeamScore"].map(to_int).ffill()
        a = df["awayTeamScore"].map(to_int).ffill()
        if (h.diff() < -5).any() or (a.diff() < -5).any():
            R6 = False

    # R7: Team-attributed pts match header
    R7 = False
    home_lc = (df["homeTeam"].iloc[0] or "").strip().lower() if "homeTeam" in df.columns else ""
    away_lc = (df["awayTeam"].iloc[0] or "").strip().lower() if "awayTeam" in df.columns else ""
    computed_home = computed_away = 0
    if exp_home is not None and "playType" in df.columns and "shotOutcome" in df.columns:
        pt = df["playType"].fillna("")
        so = df["shotOutcome"].fillna("")
        team = df["Team"].fillna("").str.strip().str.lower()
        rp = pt.map(SHOT_PTS).fillna(0).astype(int).where(so == "good", 0)
        computed_home = int(rp.where(team == home_lc, 0).sum())
        computed_away = int(rp.where(team == away_lc, 0).sum())
        gap = abs(computed_home - exp_home) + abs(computed_away - exp_away)
        R7 = gap <= 1

    # R8: any unhandled scoring playTypes? (made shots whose type isn't recognized)
    R8 = True
    unhandled = 0
    if "playType" in df.columns and "shotOutcome" in df.columns:
        pt = df["playType"].fillna("")
        so = df["shotOutcome"].fillna("")
        made = (so == "good") & ~pt.isin(SHOT_PTS.keys()) & (pt != "") & ~pt.isin(NON_SCORING_TYPES)
        unhandled = int(made.sum())
        R8 = unhandled <= 2

    checks = {"R1": R1, "R2": R2, "R3": R3, "R4": R4, "R5": R5, "R6": R6, "R7": R7, "R8": R8}
    confidence = sum(int(v) for v in checks.values()) / len(checks)

    return {
        "file": os.path.relpath(csv_path),
        **checks,
        "confidence": round(confidence, 3),
        "n_real": n_real,
        "minutes": round(mins, 1),
        "exp_minutes": exp_mins,
        "computed_home": computed_home,
        "computed_away": computed_away,
        "real_home": exp_home,
        "real_away": exp_away,
        "unhandled_makes": unhandled,
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--season")
    ap.add_argument("--school")
    ap.add_argument("--out", default="/tmp/pbp_validation.csv")
    ap.add_argument("--fail-threshold", type=float, default=0.75,
                    help="Print warnings for games scoring below this.")
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
    if not files:
        print(f"No files matched under {candidates}", file=sys.stderr)
        sys.exit(2)

    rows = [validate_file(f) for f in files]
    df = pd.DataFrame(rows)
    df.to_csv(args.out, index=False)

    n_total = len(df)
    n_perfect = int((df["confidence"] == 1.0).sum())
    n_warn = int((df["confidence"] < args.fail_threshold).sum())

    print(f"Validated {n_total} files -> {args.out}")
    print(f"  Confidence == 1.0: {n_perfect} ({n_perfect/n_total*100:.1f}%)")
    print(f"  Confidence  < {args.fail_threshold}: {n_warn}")
    if n_warn:
        worst = df[df["confidence"] < args.fail_threshold].sort_values("confidence").head(15)
        print()
        print("Lowest confidence games (worst 15):")
        for _, r in worst.iterrows():
            failed = [k for k in ("R1","R2","R3","R4","R5","R6","R7","R8") if not r[k]]
            print(f"  conf={r['confidence']:.2f}  fail={','.join(failed):20s}  {r['file']}")


if __name__ == "__main__":
    main()
