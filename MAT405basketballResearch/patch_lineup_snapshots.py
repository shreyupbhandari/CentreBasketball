"""Repair broken lineup snapshots in PBP CSVs.

Two failure modes the Python parser introduced for Centre 2023-24 (and
~97 other 2023-24 games):

1. **Name-format inconsistency.** The parser added the same player to the
   lineup state under two different spellings — e.g. `rasberry,jr.,darvis`
   from one event and `rasberry jr,darvis` from another. The lineup state
   grew to 6 effective slots, the next legitimate substitution couldn't
   reconcile, and `expandColumn` blanked every subsequent row's lineup.

2. **Period-boundary state corruption.** End of period 1's `home_lineup`
   contains stale names (the parser missed an earlier sub-out). Period 2
   starts with that stale state, the first real sub fails, and every
   subsequent row gets blanked.

Both leave dozens-to-hundreds of rows with `homePlayer1..5` = NaN /
`playerMissing` = 1. The R loader was dropping these rows entirely, which
silently sliced 1-84 points out of the dashboard per affected game.

This patcher walks each CSV, normalizes names, dedupes, and where a row
has < 5 distinct lineup slots, re-derives the on-floor lineup from the
play stream around that row. Rows that genuinely can't be repaired keep
`playerMissing=1` so the loader can still filter them from per-lineup
aggregations if desired.

Idempotent. Run:
    python3 MAT405basketballResearch/patch_lineup_snapshots.py
    python3 MAT405basketballResearch/patch_lineup_snapshots.py --dry-run
"""

from __future__ import annotations

import argparse
import glob
import os
import re
import sys
from collections import Counter

import pandas as pd


def normalize_name(s) -> str:
    """Canonical form: lowercase, strip dots, collapse multiple commas/spaces,
    drop leading jersey digits. The same player under different scraper
    spellings reduces to the same string."""
    if not isinstance(s, str):
        return ""
    s = s.strip().lower()
    if not s or s in ("nan", "none"):
        return ""
    s = re.sub(r"^\d+,", "", s)              # "3,moore,chez" → "moore,chez"
    s = re.sub(r",\d+$", "", s)              # "gardner,2"     → "gardner"
    s = s.replace(".", "")                    # "jr.,darvis"    → "jr,darvis"
    s = re.sub(r"\s+", " ", s).strip()       # collapse whitespace
    s = re.sub(r"\s*,\s*", ",", s)           # tidy commas
    s = re.sub(r"\bjr\b", "jr", s)           # already normalized
    s = re.sub(r"^([^,]+) jr\b,", r"\1,jr,", s)  # "rasberry jr,darvis" → "rasberry,jr,darvis"
    return s


def lineup_slots(row: pd.Series, side: str) -> list[str]:
    return [str(row.get(f"{side}Player{i}", "") or "") for i in range(1, 6)]


def has_broken_lineup(row: pd.Series, side: str) -> bool:
    slots = lineup_slots(row, side)
    norms = [normalize_name(s) for s in slots]
    nonempty = [n for n in norms if n]
    return len(nonempty) < 5 or len(set(nonempty)) < 5


def dedupe_slots(slots: list[str]) -> list[str] | None:
    """Return the slots with duplicates merged, preserving first occurrence.
    None if dedupe leaves us with < 5 distinct players."""
    seen = set()
    out = []
    for s in slots:
        n = normalize_name(s)
        if not n or n in seen:
            continue
        seen.add(n)
        out.append(s)
    if len(out) == 5:
        return out
    return None


def discover_period_lineup(df: pd.DataFrame, period: str, side: str) -> list[str] | None:
    """Walk the period's real-clock rows in order. Each row's actor
    (Player column) confirms one player is on the floor for that team.
    Substitutions in/out modify the working set. The first 5 distinct
    confirmed players become the period's reconstructed lineup."""
    side_team_col = "Team"
    if side_team_col not in df.columns:
        return None
    # Determine which team is on which side from header.
    home = (df["homeTeam"].iloc[0] or "").strip().lower() if "homeTeam" in df.columns else ""
    away = (df["awayTeam"].iloc[0] or "").strip().lower() if "awayTeam" in df.columns else ""
    target_team = home if side == "home" else away
    if not target_team:
        return None

    on_floor: dict[str, str] = {}   # normalized -> original
    period_df = df[df["Period"].astype(str) == str(period)]
    for _, r in period_df.iterrows():
        play = str(r.get("Play", "")).lower()
        team = str(r.get(side_team_col, "")).strip().lower()
        player = str(r.get("Player", "")).strip()
        # Subs flip the working set.
        if "sub in by" in play and player and team == target_team:
            n = normalize_name(player)
            if n and n not in on_floor:
                on_floor[n] = player
            continue
        if "sub out by" in play and player and team == target_team:
            n = normalize_name(player)
            on_floor.pop(n, None)
            continue
        # Any non-sub action by a player on the target team confirms
        # they're on the floor.
        if player and team == target_team:
            n = normalize_name(player)
            if n and n not in on_floor:
                on_floor[n] = player
        if len(on_floor) >= 5:
            break

    if len(on_floor) >= 5:
        return list(on_floor.values())[:5]
    return None


def patch_file(csv_path: str, dry_run: bool = False) -> dict:
    df = pd.read_csv(csv_path, low_memory=False, dtype=str)
    if df.empty:
        return {"file": csv_path, "action": "skip_empty"}
    needed = (["Period", "Team", "Player", "playerMissing"] +
              [f"homePlayer{i}" for i in range(1, 6)] +
              [f"awayPlayer{i}" for i in range(1, 6)])
    if not all(c in df.columns for c in needed):
        return {"file": csv_path, "action": "skip_no_cols"}

    n_rows_changed = 0
    n_pm_cleared = 0

    # Pre-compute reconstructed lineups for any period × side that has any
    # broken row. Cache to avoid re-walking the same period multiple times.
    reconstructed: dict[tuple, list[str] | None] = {}

    for side in ("home", "away"):
        broken_rows = df.index[df.apply(lambda r: has_broken_lineup(r, side), axis=1)]
        if len(broken_rows) == 0:
            continue
        for idx in broken_rows:
            period = str(df.at[idx, "Period"])
            slots = lineup_slots(df.iloc[idx], side)

            # Try cheap dedupe first (covers the duplicate-name case).
            deduped = dedupe_slots(slots)
            if deduped is not None:
                for i in range(5):
                    col = f"{side}Player{i+1}"
                    if df.at[idx, col] != deduped[i]:
                        df.at[idx, col] = deduped[i]
                        n_rows_changed += 1
                # Mark recoverable now that lineup is complete.
                if df.at[idx, "playerMissing"] in ("1", "1.0", 1, 1.0):
                    df.at[idx, "playerMissing"] = "0"
                    n_pm_cleared += 1
                continue

            # Cheap dedupe didn't help — try period-wide reconstruction.
            key = (period, side)
            if key not in reconstructed:
                reconstructed[key] = discover_period_lineup(df, period, side)
            recon = reconstructed[key]
            if recon is None:
                continue

            # Forward-fill from previous KNOWN-GOOD row in same period, if any.
            # Otherwise use the reconstructed period lineup as a baseline.
            same_period_before = df.iloc[:idx][df["Period"].iloc[:idx].astype(str) == period]
            if not same_period_before.empty:
                last_ok = None
                for j in range(len(same_period_before) - 1, -1, -1):
                    r = same_period_before.iloc[j]
                    if not has_broken_lineup(r, side):
                        last_ok = lineup_slots(r, side)
                        break
                if last_ok is not None:
                    for i in range(5):
                        col = f"{side}Player{i+1}"
                        if df.at[idx, col] != last_ok[i]:
                            df.at[idx, col] = last_ok[i]
                            n_rows_changed += 1
                    if df.at[idx, "playerMissing"] in ("1", "1.0", 1, 1.0):
                        df.at[idx, "playerMissing"] = "0"
                        n_pm_cleared += 1
                    continue

            # Use period-reconstructed as last-resort.
            for i in range(5):
                col = f"{side}Player{i+1}"
                if df.at[idx, col] != recon[i]:
                    df.at[idx, col] = recon[i]
                    n_rows_changed += 1
            if df.at[idx, "playerMissing"] in ("1", "1.0", 1, 1.0):
                df.at[idx, "playerMissing"] = "0"
                n_pm_cleared += 1

    if n_rows_changed == 0:
        return {"file": csv_path, "action": "skip_no_change"}

    if not dry_run:
        df.to_csv(csv_path, index=False)

    return {"file": csv_path, "action": "patched",
            "rows_changed": n_rows_changed,
            "playerMissing_cleared": n_pm_cleared}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--season")
    ap.add_argument("--school")
    args = ap.parse_args()

    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    saa = os.path.join(root, "SAA")
    files = sorted(glob.glob(os.path.join(saa, args.school or "*", "pbp", args.season or "*", "*.csv")))
    if not files:
        print(f"No files matched", file=sys.stderr); sys.exit(2)

    by_action = Counter()
    patched = []
    for f in files:
        r = patch_file(f, dry_run=args.dry_run)
        by_action[r["action"]] += 1
        if r["action"] == "patched":
            patched.append(r)

    print(f"Scanned {len(files)} files.")
    for k, v in sorted(by_action.items()):
        print(f"  {k}: {v}")
    if patched:
        total_changed = sum(r["rows_changed"] for r in patched)
        total_pm = sum(r["playerMissing_cleared"] for r in patched)
        print()
        print(f"Total rows touched: {total_changed}")
        print(f"Total playerMissing=1 cleared: {total_pm}")
        print()
        print("Top 15 patched files by rows changed:")
        for r in sorted(patched, key=lambda x: -x["rows_changed"])[:15]:
            short = os.path.relpath(r["file"], saa)
            print(f"  changed={r['rows_changed']:5d}  cleared={r['playerMissing_cleared']:4d}  {short[:75]}")


if __name__ == "__main__":
    main()
