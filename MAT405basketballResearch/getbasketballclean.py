from bs4 import BeautifulSoup as bs
import pandas as pd
import numpy as np
from pandas import DataFrame
import os
import urllib
import urllib.request
from pathlib import Path
import csv
import re
import ssl
import logging

import html_parsers

logger = logging.getLogger(__name__)

# Main directory to Summer Research folder              
#main_dir = '/Users/colby/OneDrive/Desktop/MAT 405/'

# Default data root is the repo root (one level above this file's folder).
# If a given sport has its own subfolder (e.g. `<root>/mens-basketball/`),
# we automatically use it; otherwise we write directly under `<root>/`.
main_dir = str(Path(__file__).resolve().parents[1]) + os.sep

def _sport_root(sport: str) -> Path:
    root = Path(main_dir)
    sport_dir = root / sport
    return sport_dir if sport and sport_dir.exists() else root
sports = ['mens-basketball', 'womens-basketball']

saa_teams = ['berry', 'birmingham-southern', 'centre', 'hendrix', 'millsaps',
             'oglethorpe', 'rhodes', 'sewanee', 'southwestern', 'trinity']
schools = ['berryvikings', 'bscsports', 'centrecolonels', 'hendrixwarriors',
           'gomajors', 'rhodeslynx', 'sewaneetigers',
           'southwesternpirates', 'trinitytigers']
# Temporary variable; should loop through all schools
##schools = ['centrecolonels']

start_year = 2010 # fall of first year to get header data
end_year = 2025   # fall of last year to get header data (2025 -> 2025-26)

# Player name corrections for scraping inconsistencies (scraped_name -> canonical_name)
PLAYER_NAME_CORRECTIONS = {
    'vanstaalduinen,matthijis': 'van staalduinen,matt',
}

# --------------------------------------------------------------------------
# Phantom-row hygiene
# --------------------------------------------------------------------------
# College PBP scoreboards emit each period in two passes:
#   1. The play-by-play itself — every row has a "MM:SS" clock value and
#      represents an actual game event (shot, foul, sub, turnover, etc.).
#   2. A box-score summary block tacked on at the end of each period — rows
#      have no clock ("--" or blank) and exist to annotate rebounds and
#      assists that were derived from the box score rather than from a
#      timestamped play.
#
# Historically, this pipeline ran the entire possession-tracking sequence
# (posschange -> assign_teams -> team_change_indicator -> calculate_possession_*)
# over EVERY row, including the phantom summary block. That created a
# second parallel possession sequence: phantom rows got their own possStart,
# teamChanged, and running possPoints, doubling each real possession's
# scoring contribution. Downstream code that summed possPoints on
# teamChanged==1 rows inflated OFFRTG by ~2x (we saw OFFRTG values over 220
# in seasons where the truth was ~110-120).
#
# Two fixes happen here:
#   - _zero_phantom_possession_flags: after the existing flag columns are
#     computed, zero possStart / teamChanged / possPoints on phantom rows
#     so they no longer act as a duplicate sequence.
#   - _reattribute_phantom_lineups: the lineup snapshot recorded for each
#     phantom row was the END-OF-PERIOD lineup (since phantom rows come
#     after every play). Walk the phantom rows and copy each one's lineup
#     from the corresponding real row — assist phantoms pair with made
#     shots, rebound phantoms pair with missed shots, in chronological
#     order within the period.
_CLOCK_RE = re.compile(r'^\d+:\d+$')

def _is_real_play_clock(t):
    """True if the timeRemaining cell is a proper 'MM:SS' clock value."""
    if not isinstance(t, str):
        return False
    return bool(_CLOCK_RE.match(t.strip()))

def _reorder_sub_blocks(df):
    """Re-order consecutive SUB IN / SUB OUT events at the SAME clock so
    every OUT comes before any IN within a (Period, timeRemaining) block.

    Real-world failure mode: some Sidearm exports list the 3 substitutions
    going IN before the 3 going OUT, all stamped with the same clock value.
    The parser's lineup-state machine doesn't reorder, so it tries to add
    the IN player while the lineup is still at 5, blowing past 5 slots and
    blanking every subsequent row's snapshot. Seen in Centre vs Wilkes
    2023-24 (203 rows broken from 15:41 of Period 1 onward).

    The reorder is loss-less: within a single clock tick the rows happened
    simultaneously, so swapping OUT-before-IN matches game logic. Rows
    that aren't subs, or aren't in a same-clock sub block, are left
    untouched.
    """
    if 'Play' not in df.columns or 'timeRemaining' not in df.columns:
        return df
    if 'Period' not in df.columns:
        return df

    play_lower = df['Play'].astype(str).str.lower()
    is_sub_out = play_lower.str.contains('sub out by', na=False)
    is_sub_in  = play_lower.str.contains('sub in by',  na=False)
    is_sub     = is_sub_out | is_sub_in
    if not is_sub.any():
        return df

    # Group rows by (Period, timeRemaining); within each group, if it
    # contains BOTH sub-outs and sub-ins AND any sub-in appears before any
    # sub-out, reorder so OUTs come first while preserving relative order
    # within each sub-class.
    new_order = list(df.index)
    period = df['Period'].astype(str).tolist()
    time_r = df['timeRemaining'].astype(str).tolist()
    out_flags = is_sub_out.tolist()
    in_flags  = is_sub_in.tolist()
    sub_flags = is_sub.tolist()

    i = 0
    n = len(df)
    while i < n:
        if not sub_flags[i]:
            i += 1
            continue
        # Find the end of the contiguous (Period, timeRemaining) sub block.
        p = period[i]; t = time_r[i]
        j = i
        while j < n and sub_flags[j] and period[j] == p and time_r[j] == t:
            j += 1
        block = new_order[i:j]
        block_outs = [new_order[k] for k in range(i, j) if out_flags[k]]
        block_ins  = [new_order[k] for k in range(i, j) if in_flags[k]]
        if block_outs and block_ins:
            # See if any IN comes before any OUT in this block.
            first_in_pos = next((k for k in range(i, j) if in_flags[k]), None)
            first_out_pos = next((k for k in range(i, j) if out_flags[k]), None)
            if first_in_pos is not None and first_out_pos is not None and first_in_pos < first_out_pos:
                new_order[i:j] = block_outs + block_ins
        i = j

    if new_order == list(df.index):
        return df
    return df.loc[new_order].reset_index(drop=True)


def _heal_lineups_from_play_stream(df, home_name, away_name,
                                    home_roster=None, away_roster=None):
    """Self-healing lineup recovery for rows where a sub event was
    mis-labeled in the source data and our parser was left with a 4-player
    lineup. When the play stream subsequently shows a player taking a
    real on-court action who ISN'T in our current snapshot, add them.

    Real-world failure mode: Sidearm sometimes emits a `SUB IN by X` event
    naming a player who's already on the floor (a name typo in the
    upstream feed, or a duplicated SUB IN that should have referred to a
    different player). Our parser silently no-ops the redundant SUB IN.
    If the SUB OUT it was paired with succeeded, the lineup is left at
    4 players for the rest of the period, blanking attribution on every
    scoring row until the period boundary resets the state.

    Heuristic:
      * Walk rows in order. For each row, look at the home/away lineup
        snapshot. If it has fewer than 5 distinct named players AND the
        row's Player is on the same team AND not in the current snapshot,
        slot them into the first NaN/missing position.
      * Only fires for real on-court actions (shots, rebounds, turnovers,
        fouls, blocks, steals, assists). Skips sub events themselves and
        timeouts.
      * Operates row-by-row on the saved `homeLineup` / `awayLineup`
        list columns so the change propagates forward — the next row
        starts from the healed state.

    Idempotent: if every snapshot is already 5-complete, no changes.
    """
    if 'homeLineup' not in df.columns or 'awayLineup' not in df.columns:
        return df
    if 'Player' not in df.columns or 'Team' not in df.columns:
        return df

    home_lc = (home_name or '').strip().lower()
    away_lc = (away_name or '').strip().lower()

    skip_types = {
        'subbing in', 'subbing out', 'sub', 'starter',
        'timeout', 'timeout 30sec by',
    }
    play_types = df['playType'].fillna('').astype(str).str.lower().tolist() \
                 if 'playType' in df.columns else [''] * len(df)
    players = df['Player'].fillna('').astype(str).tolist()
    teams = df['Team'].fillna('').astype(str).str.lower().tolist()
    home_lineups = list(df['homeLineup'].tolist())
    away_lineups = list(df['awayLineup'].tolist())

    def _norm_set(lineup):
        return frozenset(_normalize_player_key(x) for x in lineup if x)

    # Two-pass strategy. Pass 1 walks forward and records, for each
    # contiguous "stretch" (rows where the parser-snapshot's player set is
    # unchanged from the previous row), the set of extra same-team players
    # who took on-court actions but weren't in the parser's snapshot.
    # Pass 2 walks the rows again and adds the recorded extras to every
    # row in the stretch — including rows BEFORE the player's first action,
    # because they were on the floor the whole time.

    # Build stretch boundaries: stretch_id[i] gives a contiguous-stretch
    # index for the home side and the away side. A new stretch begins
    # whenever the parser's snapshot player-set changes from the previous
    # row's.
    home_stretch = [0] * len(df)
    away_stretch = [0] * len(df)
    prev_home_set = None
    prev_away_set = None
    hsid = asid = 0
    for i in range(len(df)):
        ph = list(home_lineups[i]) if isinstance(home_lineups[i], list) else []
        pa = list(away_lineups[i]) if isinstance(away_lineups[i], list) else []
        hs = _norm_set(ph); as_ = _norm_set(pa)
        if prev_home_set is not None and hs != prev_home_set:
            hsid += 1
        if prev_away_set is not None and as_ != prev_away_set:
            asid += 1
        home_stretch[i] = hsid
        away_stretch[i] = asid
        prev_home_set = hs
        prev_away_set = as_

    # Pass 1: for each stretch, collect distinct extra players who took
    # actions but weren't in the parser's snapshot at that row.
    home_extras = {}    # stretch_id -> [player_name, ...] in order
    away_extras = {}
    for i in range(len(df)):
        pt = play_types[i]
        if pt in skip_types or pt.startswith('sub'):
            continue
        p = players[i].strip()
        if not p:
            continue
        team_lc = teams[i]
        if team_lc == home_lc:
            sid = home_stretch[i]
            base = list(home_lineups[i]) if isinstance(home_lineups[i], list) else []
            target_extras = home_extras
        elif team_lc == away_lc:
            sid = away_stretch[i]
            base = list(away_lineups[i]) if isinstance(away_lineups[i], list) else []
            target_extras = away_extras
        else:
            continue
        cur_extras = target_extras.get(sid, [])
        eff_norms = _norm_set(base + cur_extras)
        p_norm = _normalize_player_key(p)
        if not p_norm or p_norm in eff_norms:
            continue
        if len(base) + len(cur_extras) >= 5:
            continue
        cur_extras.append(p)
        target_extras[sid] = cur_extras

    # Pass 2: apply extras to every row in their stretch.
    n_healed = 0
    for i in range(len(df)):
        if home_extras.get(home_stretch[i]):
            base = list(home_lineups[i]) if isinstance(home_lineups[i], list) else []
            base_norms = _norm_set(base)
            for x in home_extras[home_stretch[i]]:
                xn = _normalize_player_key(x)
                if xn and xn not in base_norms and len(base) < 5:
                    base.append(x)
                    base_norms = base_norms | {xn}
                    n_healed += 1
            home_lineups[i] = base
        if away_extras.get(away_stretch[i]):
            base = list(away_lineups[i]) if isinstance(away_lineups[i], list) else []
            base_norms = _norm_set(base)
            for x in away_extras[away_stretch[i]]:
                xn = _normalize_player_key(x)
                if xn and xn not in base_norms and len(base) < 5:
                    base.append(x)
                    base_norms = base_norms | {xn}
                    n_healed += 1
            away_lineups[i] = base

    # ---------- Pass 3: ROSTER-AWARE fallback ----------
    # The two passes above can only find a missing 5th player when that
    # player took an on-court action somewhere in the stretch. If they
    # touched the ball zero times, the stretches stay at <5. The
    # team-stats table on the box-score HTML page lists every player who
    # played, with minutes played and a starter flag — ground truth for
    # who was on the floor at all. We use this to identify the missing
    # 5th by elimination.
    #
    # Algorithm: for each stretch with a stable 4-player snapshot:
    #   1. Build the set of roster members not already in the snapshot.
    #   2. Eliminate anyone subbed out during or before the stretch and
    #      not subbed back in. Track sub events globally.
    #   3. Among remaining candidates, pick the one with the most minutes
    #      (most likely to be on the floor at any random moment).
    # The pick is statistical, not certain — but it's strictly better
    # than leaving an NA slot. Only fires when ROSTER data is available;
    # silently skips if the parser couldn't extract it.
    def _roster_norms(roster):
        if not roster:
            return {}
        return {_normalize_player_key(p['name']): p for p in roster
                if isinstance(p, dict) and p.get('name')}

    home_roster_idx = _roster_norms(home_roster)
    away_roster_idx = _roster_norms(away_roster)

    def _apply_roster_fallback(lineups, side_team_lc, roster_idx, stretches):
        if not roster_idx:
            return 0
        # Per stretch, count which roster members appear in any snapshot
        # row of that stretch. If exactly one roster member is missing
        # and the snapshot only has 4 distinct names, we can confidently
        # fill in the 5th. If multiple candidates, pick the one with
        # the highest minutes (most likely on floor for a random moment).
        n_filled = 0
        # Group rows by stretch id.
        stretch_rows = {}
        for i, sid in enumerate(stretches):
            stretch_rows.setdefault(sid, []).append(i)
        # Track team sub events globally so we can score candidates by
        # "has this player been on the floor recently".
        play_lower = df['Play'].astype(str).str.lower().tolist() \
                     if 'Play' in df.columns else [''] * len(df)
        team_col = df['Team'].astype(str).str.lower().tolist() \
                   if 'Team' in df.columns else [''] * len(df)

        for sid, idxs in stretch_rows.items():
            # Use the most-populated snapshot in the stretch as the base.
            best = []
            for i in idxs:
                snap = lineups[i] if isinstance(lineups[i], list) else []
                if len(snap) > len(best):
                    best = list(snap)
            if not best or len(best) >= 5:
                continue
            # Find roster members NOT in the snapshot.
            base_norms = {_normalize_player_key(x) for x in best if x}
            missing = [p for n, p in roster_idx.items() if n not in base_norms]
            if not missing:
                continue
            # Subtract anyone whose SUB OUT in this game came AFTER their
            # last SUB IN AND before the stretch start.
            stretch_start = min(idxs)
            on_floor_now = {n: True for n in roster_idx.keys()
                            if roster_idx[n].get('is_starter')}
            for j in range(0, stretch_start):
                if team_col[j] != side_team_lc:
                    continue
                pl = play_lower[j]
                if 'sub in by' in pl:
                    try:
                        nm = pl.split(' by ', 1)[1].strip()
                        on_floor_now[_normalize_player_key(nm)] = True
                    except IndexError:
                        pass
                elif 'sub out by' in pl:
                    try:
                        nm = pl.split(' by ', 1)[1].strip()
                        on_floor_now[_normalize_player_key(nm)] = False
                    except IndexError:
                        pass
            # Candidate = roster members who are NOT in the visible
            # snapshot AND ARE currently on-floor per the sub-event walk.
            candidates = [p for p in missing
                          if on_floor_now.get(_normalize_player_key(p['name']), False)]
            # Fall back to highest-minutes if no candidate is confirmed on-floor.
            if not candidates:
                candidates = sorted(missing, key=lambda p: p.get('minutes', 0), reverse=True)
                # Only use the top candidate if their minutes look meaningful
                # — < 4 min suggests bench player, don't guess.
                candidates = [c for c in candidates if c.get('minutes', 0) >= 4]
            if not candidates:
                continue
            # Pick the candidate with the most minutes.
            pick = max(candidates, key=lambda p: p.get('minutes', 0))
            pick_name = pick['name']
            # Apply to every row in this stretch.
            for i in idxs:
                cur = list(lineups[i]) if isinstance(lineups[i], list) else []
                cur_norms = {_normalize_player_key(x) for x in cur if x}
                if _normalize_player_key(pick_name) in cur_norms:
                    continue
                if len(cur) < 5:
                    cur.append(pick_name)
                    lineups[i] = cur
                    n_filled += 1
        return n_filled

    if home_roster_idx:
        # Build home stretch IDs (same logic as above pass-1)
        n_home_filled = _apply_roster_fallback(
            home_lineups, (home_name or '').strip().lower(),
            home_roster_idx, home_stretch)
    else:
        n_home_filled = 0
    if away_roster_idx:
        n_away_filled = _apply_roster_fallback(
            away_lineups, (away_name or '').strip().lower(),
            away_roster_idx, away_stretch)
    else:
        n_away_filled = 0
    n_healed += n_home_filled + n_away_filled

    if n_healed > 0:
        df['homeLineup'] = home_lineups
        df['awayLineup'] = away_lineups
    return df


def _normalize_player_key(name):
    """Canonical key for membership comparisons on home_lineup/away_lineup.

    The same player can appear in the play stream under multiple spellings
    that the substitution logic must treat as identical:
      'rasberry,jr.,darvis' vs 'rasberry jr,darvis' vs 'RASBERRY JR,DARVIS'
    Comparing raw strings caused the 2023-24 Centre lineup-state breakage
    where the parser added the same player twice and the lineup blew past
    5 slots, blanking every subsequent row.
    """
    if not isinstance(name, str):
        return ''
    s = name.strip().lower()
    s = re.sub(r'^\d+,', '', s)           # strip jersey prefix
    s = re.sub(r',\d+$', '', s)           # strip jersey suffix
    s = s.replace('.', '')                 # 'jr.' -> 'jr'
    s = re.sub(r'\s+', ' ', s).strip()    # collapse whitespace
    s = re.sub(r'\s*,\s*', ',', s)        # tidy commas
    # Collapse " jr" appearing as a separator into a canonical ",jr,"
    # so "rasberry jr,darvis" and "rasberry,jr,darvis" agree.
    s = re.sub(r'^([^,]+) jr,', r'\1,jr,', s)
    return s


def _correct_team_from_score_deltas(df, home_name, away_name):
    """Repair the `Team` column when the play-loop's heuristic mis-attributed
    rows. Two failure modes are seen in the source data:

    1. The play-loop assigns Team via `data == df['homePlay'][i].lower()`,
       which always falls through to the away-team branch when `homePlay`
       is empty (every 2018-19 Sidearm export of this shape). Result:
       every Team value collapses to the away team.
    2. For "GOOD 2PTR by X"-style plays the parser couldn't pull a Player
       name (older Sidearm format) AND the homePlay/awayPlay heuristic
       split mis-routed the row, so individual scoring rows for one team
       got tagged with the other team's name.

    Reliable signal: the per-row `homeTeamScore` / `awayTeamScore` columns
    are populated straight from the box-score table cell-by-cell and are
    independent of the play-classification logic. When the running score
    increments on exactly one side, the scoring team for that row is
    unambiguous. We use that to:

      a) Override `Team` directly on confirmed scoring rows.
      b) Build a player → team map from confirmed scoring rows.
      c) Use the map to fix `Team` on the remaining (non-scoring) rows
         where the player is known.

    Idempotent — calling it on a correct file produces no changes.
    Skips silently if the required columns aren't all present.
    """
    needed = ('Team', 'Player', 'homeTeamScore', 'awayTeamScore')
    if not all(c in df.columns for c in needed):
        return df
    if len(df) == 0:
        return df

    home_lc = (home_name or '').strip().lower()
    away_lc = (away_name or '').strip().lower()
    if not home_lc or not away_lc:
        return df

    def _as_int(s):
        if pd.isna(s):
            return None
        try:
            return int(str(s).strip())
        except (ValueError, TypeError):
            return None

    h = df['homeTeamScore'].map(_as_int).tolist()
    a = df['awayTeamScore'].map(_as_int).tolist()

    # First pass: identify per-row scoring side from running deltas.
    scored_side = [None] * len(df)
    prev_h = prev_a = 0
    for i in range(len(df)):
        ch = h[i] if h[i] is not None else prev_h
        ca = a[i] if a[i] is not None else prev_a
        dh = ch - prev_h
        da = ca - prev_a
        if dh > 0 and da == 0:
            scored_side[i] = 'home'
        elif da > 0 and dh == 0:
            scored_side[i] = 'away'
        prev_h, prev_a = ch, ca

    # Build player → team map from confirmed scoring rows.
    players = df['Player'].tolist()
    player_team = {}
    conflict = set()
    for i, side in enumerate(scored_side):
        if side is None:
            continue
        p = players[i]
        if not isinstance(p, str) or not p.strip():
            continue
        p_lc = p.strip().lower()
        t = home_lc if side == 'home' else away_lc
        if p_lc in player_team and player_team[p_lc] != t:
            conflict.add(p_lc)
        else:
            player_team[p_lc] = t
    for p in conflict:
        player_team.pop(p, None)

    # Apply corrections.
    original_team = df['Team'].tolist()
    new_team = list(original_team)
    for i in range(len(df)):
        side = scored_side[i]
        if side is not None:
            new_team[i] = home_lc if side == 'home' else away_lc
            continue
        p = players[i]
        if isinstance(p, str) and p.strip():
            mapped = player_team.get(p.strip().lower())
            if mapped is not None:
                new_team[i] = mapped

    df['Team'] = new_team
    return df


def _zero_phantom_possession_flags(df):
    """Set possStart / teamChanged / possPoints to 0 on phantom rows so
    they don't get summed as duplicate possessions downstream. Other
    columns (possTeam, possSequence, secondsPerPoss, ASSIST, OREB, DREB)
    are left alone — the indicator columns are the real signal we want
    to preserve on phantom rows."""
    if 'timeRemaining' not in df.columns:
        return df
    real = df['timeRemaining'].apply(_is_real_play_clock)
    for col in ('possStart', 'teamChanged', 'possPoints'):
        if col not in df.columns:
            continue
        # These columns can land in the frame as either ints, floats, or
        # strings depending on which upstream function produced them
        # (posschange returns np floats, calculate_possession_points returns
        # str). Pandas' string dtype rejects integer assignment with
        # "Invalid value '0' for dtype 'str'", so coerce to numeric first
        # — that gives every column a consistent 0/1 integer view that
        # both the loc assignment and downstream CSV write handle cleanly.
        df[col] = pd.to_numeric(df[col], errors='coerce').fillna(0)
        df.loc[~real, col] = 0
    return df

def _reattribute_phantom_lineups(df):
    """Copy the home/away lineup from each phantom row's matching real row.

    Matching is greedy and per-period:
      - ASSIST phantom -> next unmatched 'good' shot in same period
      - OFFENSIVE/DEFENSIVE REBOUND phantom -> next unmatched 'missed' shot
        in same period
    If no match is found, the existing (end-of-period) lineup is left in
    place; playerMissing will still flag any incomplete lineup downstream.
    """
    if 'homeLineup' not in df.columns or 'awayLineup' not in df.columns:
        return df
    if 'timeRemaining' not in df.columns or 'playType' not in df.columns:
        return df

    real = df['timeRemaining'].apply(_is_real_play_clock).tolist()
    play_types    = df['playType'].fillna('').astype(str).str.lower().tolist()
    shot_outcomes = df['shotOutcome'].fillna('').astype(str).str.lower().tolist() \
                    if 'shotOutcome' in df.columns else [''] * len(df)
    periods       = df['Period'].fillna('').astype(str).tolist() \
                    if 'Period' in df.columns else [''] * len(df)

    home_lineup = df['homeLineup'].tolist()
    away_lineup = df['awayLineup'].tolist()

    # Include 'free throw' / 'tipin' / 'two pointer' — phantom rebound rows
    # often follow a missed FT, and pre-2014 feeds use 'two pointer'/'tipin'
    # for what later seasons split into 'layup'/'jumper'/'dunk'. Excluding
    # any of these caused the immediate-prior pair to silently fail and the
    # phantom row's lineup to land far away in the FIFO queue (Centre vs
    # Wilkes 2023-24 row 264 / 287 symptom: 3 player slots changed across
    # a single phantom row).
    shot_types = {'layup', 'jumper', 'three pointer', 'dunk',
                  'free throw', 'tipin', 'two pointer'}

    # Track which real-shot rows have already been paired with a phantom
    # so we don't double-count them. Pairing strategy:
    #
    # 1. **Immediate-prior pair** (preferred). Sidearm typically emits a
    #    mid-period phantom row IMMEDIATELY after the play it annotates —
    #    e.g. `GOOD 3PTR by RING,NOAH` at 14:56, then `--  ASSIST by
    #    COLEMAN,HUNTER` on the next row. The right lineup for the phantom
    #    is the previous real shot row's lineup. Walk backwards through
    #    only the SAME period; stop at the first eligible real shot row.
    #
    # 2. **Chronological FIFO fallback**. End-of-period phantom rows have
    #    no immediate-prior play; fall back to the original "next
    #    unmatched real shot in same period" logic the old code used.
    used = set()
    # Build per-period chronological queue of real shot rows for the FIFO
    # fallback.
    made_q = {}
    miss_q = {}
    for j in range(len(df)):
        if not real[j]:
            continue
        if play_types[j] in shot_types:
            per = periods[j]
            if shot_outcomes[j] == 'good':
                made_q.setdefault(per, []).append(j)
            elif shot_outcomes[j] == 'missed':
                miss_q.setdefault(per, []).append(j)

    def _find_immediate_prior(i, per, want_outcome):
        for k in range(i - 1, -1, -1):
            if periods[k] != per:
                return None
            if not real[k]:
                continue
            # Only consider real shot rows. Stop at any non-shot real row
            # so we don't reach back over a turnover, sub, foul, etc.
            if play_types[k] not in shot_types:
                return None
            if shot_outcomes[k] == want_outcome and k not in used:
                return k
            # Same row type but wrong outcome — keep looking back through
            # other shots (rare but possible).
            return None
        return None

    for i in range(len(df)):
        if real[i]:
            continue
        target = None
        per = periods[i]
        pt  = play_types[i]
        if pt == 'assist':
            target = _find_immediate_prior(i, per, 'good')
            if target is None:
                q = made_q.get(per)
                if q:
                    # Pop first un-used entry.
                    while q and q[0] in used:
                        q.pop(0)
                    if q:
                        target = q.pop(0)
        elif pt in ('offensive rebound', 'defensive rebound'):
            target = _find_immediate_prior(i, per, 'missed')
            if target is None:
                q = miss_q.get(per)
                if q:
                    while q and q[0] in used:
                        q.pop(0)
                    if q:
                        target = q.pop(0)
        if target is not None:
            used.add(target)
            # Copy the list contents — avoid aliasing the same list reference
            # across two rows, which would cause silent corruption later.
            home_lineup[i] = list(home_lineup[target])
            away_lineup[i] = list(away_lineup[target])

    df['homeLineup'] = home_lineup
    df['awayLineup'] = away_lineup
    return df

# -----------------------------------------------------------------------
# First-name recovery for jersey-corrupted player tables
# -----------------------------------------------------------------------
# Some game pages (e.g. the 2023-24 LaGrange box score) stored jersey
# numbers in place of first names in the player-stats table — entries
# like "scott,5", "cofield,4", "lyons,0". After parse_starters strips the
# trailing jersey number we're left with last-name-only starter entries
# ("scott", "cofield", "lyons"), which fail to match the full-name
# references in actual plays ("scott,brodie", "cofield,gabe", "lyons,cam").
# The sub-event matcher then fails on every substitution involving those
# players, the lineup state drifts past 5, expandColumn() blanks every
# subsequent row, and ~90% of the game's data is dropped downstream.
#
# Fix: before the main lineup-tracking loop runs, scan the play stream
# to learn the full canonical name for each last name actually mentioned
# in play strings. Then upgrade any last-name-only starter entry to the
# full form so subsequent sub events find their target.
_NAME_PLAY_TYPES = (
    'foul ', 'jumper', 'rebound', '3ptr', ' ft ', 'turnover',
    'timeout 30sec by ', '2ptr', 'steal', 'assist', 'layup',
    'block ', 'sub', 'tipin'
)

def _extract_player_from_play(play_lower):
    """Try every known play-type prefix until getPlayer returns something."""
    if not isinstance(play_lower, str) or not play_lower:
        return None
    for pt in _NAME_PLAY_TYPES:
        pname = getPlayer(pt, play_lower)
        if pname and pname != '0':
            return pname
    return None

def _build_name_recovery_maps(df):
    """Return (away_map, home_map): each maps last-name -> full canonical
    "lastname,firstname" by scanning the play stream. We keep the FIRST
    full name we see for each last name, so the result is deterministic.
    """
    away_map, home_map = {}, {}
    if 'Play' not in df.columns:
        return away_map, home_map
    plays      = df['Play'].astype(str).str.lower().tolist()
    home_plays = df['homePlay'].astype(str).str.lower().tolist() if 'homePlay' in df.columns else [''] * len(plays)
    away_plays = df['awayPlay'].astype(str).str.lower().tolist() if 'awayPlay' in df.columns else [''] * len(plays)

    for i, play in enumerate(plays):
        if play == 'nan' or play == '':
            continue
        pname = _extract_player_from_play(play)
        if not pname or ',' not in pname:
            continue
        last = pname.split(',')[0].strip()
        if not last or last == 'team':
            continue
        # Which side did this play belong to? Match the lowercased Play
        # text against home/away play columns.
        if home_plays[i] and play == home_plays[i]:
            home_map.setdefault(last, pname)
        elif away_plays[i] and play == away_plays[i]:
            away_map.setdefault(last, pname)
    return away_map, home_map

def _infer_period_starters(df, start_idx, period, side, max_lookahead=80):
    """Re-derive the 5 starting players for one team at the start of a new
    period by walking forward from start_idx and collecting the first
    distinct players who appear in on-floor actions (i.e. NOT sub-in
    events, since a sub-in implies they weren't already on the floor).

    Stops as soon as we've collected 5 names or the lookahead is
    exhausted. Returns whatever it found, which may be fewer than 5 in
    very short periods.

    Why this matters: the Wilkes 12/28/23 game (and probably others) has
    no explicit "starter" play events for period 2 — the Sidearm feed
    just transitions from period 1 directly into the next play. Without
    a reset, the lineup state at end of period 1 (which may already be
    drifted) carries into period 2 and corrupts every subsequent row.
    """
    play_col = 'homePlay' if side == 'home' else 'awayPlay'
    if play_col not in df.columns or 'Period' not in df.columns:
        return []
    plays   = df[play_col].astype(str).str.lower().tolist()
    periods = df['Period'].astype(str).tolist()
    seen = []
    end_idx = min(len(df), start_idx + max_lookahead)
    for j in range(start_idx, end_idx):
        if periods[j] != str(period):
            break
        play_text = plays[j]
        if play_text in ('', 'nan'):
            continue
        # A sub-in by definition means the player was NOT on the floor
        # before the sub, so don't treat them as a starter.
        if 'sub in' in play_text:
            continue
        # Also skip blocks (the blocker doesn't have to be on offense or
        # be the original poss-team, but is on the floor). Actually
        # blocks DO imply on the floor — keep them. Same for everything
        # except sub-in.
        pname = _extract_player_from_play(play_text)
        if pname and pname != '0' and ',' in pname and pname not in seen:
            seen.append(pname)
            if len(seen) >= 5:
                break
    return seen


def _upgrade_lineup_names(lineup, name_map):
    """For each lineup entry that lacks a comma (or has only a last name),
    replace it with the full name from the recovery map if available."""
    upgraded = []
    for p in lineup:
        if not isinstance(p, str) or not p:
            upgraded.append(p)
            continue
        # An entry without a comma is last-name-only — upgrade if we can.
        if ',' not in p:
            upgraded.append(name_map.get(p, p))
        else:
            upgraded.append(p)
    return upgraded


def getPlayer(play_type, data):
    '''Pull the player name out of a play description string.
    Returns the name as "lastname,firstname", or '0' if no player is mentioned.
    '''
    
  
    if play_type in data:
        if ' team' in data:
            return '0'
        else:
            index = data.find('by')
            subset = data[index+len('by '):(len(data))]
            occurance = 1
            end_of_name = len(subset)
            for m in re.finditer(',', subset):
                start = m.start()
                end = m.end()
                if occurance == 2:
                    end_of_name = m.end()
                occurance +=1
            player_name = subset[0:(end_of_name)]
            player_name = player_name.replace('.','')
            player_name = player_name.strip()
            name = player_name
            # if ',' in player_name:
            #      player_name = player_name.split(',')
            #      name = player_name[1] + ' ' + player_name[0]
            # else:
            #      name = player_name
            if '(in the paint)' in data:
                name = name.replace('(in the paint)', '')


            return name


        
    else:
       
        return '0'

def getCentreIndex(boxscore):
    '''Figure out which slot (0 = away, 1 = home) belongs to Centre College.
    Returns (index, [away_name, home_name]).
    '''
    headline=[]
    away_team = boxscore.find('div', {'class':'team away'})
    away_logo = away_team.find('img')
    home_team = boxscore.find('div',{'class':'team home'})
    home_logo= home_team.find('img')
    
    headline.append(away_logo.attrs['alt'].lower())
    headline.append(home_logo.attrs['alt'].lower())
    
    if "centre" in headline[0]:
        index = 0
    else:
        index = 1
   
    return index, headline

# Gets all players from both teams assigned with an asterisk.
# Delegates to html_parsers for format-agnostic parsing (handles 2022-23+ vs older layouts).
def get_starters(player_table):
    return html_parsers.parse_starters(player_table)

def isHome(data, df):
    '''Check whether a play string matches any entry in the home_play column.
    Returns '1' if found, '0' otherwise. Not currently used — team assignment is
    done by comparing the play string directly to the homePlay cell for that row.
    '''
    for info in df["home_play"]:
        if data == info.lower():
            return '1'
    return "0"


def update_play_types(play_types):
    """Revert LAST FT MADE → GOOD FT when the marked row was actually NOT
    the last FT of its sequence — e.g. an and-one shooting foul that gave
    the team 3 FTs and the LAST FT MADE candidate was only the 2nd. The
    signal: a MISS FT immediately follows (within the same trip to the
    line), then a FOUL is called on the rebound.

    HISTORICAL BUG: the lookahead was UNBOUNDED — it walked the entire
    rest of the game looking for `MISS FT` then `FOUL` and reverted the
    candidate. Since basketball games always have several missed FTs
    followed by fouls, this triggered constantly and incorrectly. It
    silently dropped ~80% of free-throw-triggered possession changes,
    undercounting OFFPOSS by ~10-20% per game and inflating OFFRTG by
    the same margin.

    Fix: stop scanning at the first row that isn't `GOOD FT` / `MISS FT`
    / `FOUL` / `SUB` / `TIMEOUT` / `STARTER` (i.e. anything that ENDS the
    current trip to the line). Only revert if the MISS FT + FOUL pair
    appears within that bounded window.
    """
    same_trip = {"GOOD FT", "MISS FT", "FOUL", "SUB", "TIMEOUT", "STARTER",
                 "subbing in", "subbing out", "timeout 30sec by",
                 "free throw", "foul"}
    for i in range(len(play_types)):
        if play_types[i] != "LAST FT MADE":
            continue
        found_miss_ft = False
        for j in range(i + 1, len(play_types)):
            cur = play_types[j]
            # Stop when the trip to the line is clearly over.
            if cur not in same_trip:
                break
            if cur == "MISS FT":
                found_miss_ft = True
            if found_miss_ft and cur == "FOUL":
                play_types[i] = "GOOD FT"
                break
    return play_types

def posschange(homePlays, awayPlays, plays, period, teamName):
    # Coerce plays to strings so NaN cells from empty CSV rows don't cause TypeError.
    # homePlays/awayPlays are kept as-is so pd.isna() checks below still work.
    plays = [str(p) if not isinstance(p, str) else p for p in plays]
    # Find every free throw made, then figure out which ones are the last of their sequence.
    # A "last FT made" ends the possession, unlike mid-sequence FTs.
    good_ft_indexes = []
    for i in range(len(plays)):
        if 'GOOD FT' in plays[i]:
            good_ft_indexes.append(i)
    last_ft_indicators = ['REBOUND DEF', 'REBOUND OFF', 'JUMPER', 'LAYUP', 'BLOCK', 'DUNK', 'TURNOVER', 'FOUL']
    last_fts = []
    for i in range(1, len(good_ft_indexes)):
        for j in range(good_ft_indexes[i-1], good_ft_indexes[i]):
            if any(x in plays[j] for x in last_ft_indicators):
                last_fts.append(good_ft_indexes[i-1])
                break
    if good_ft_indexes:
        last_fts.append(good_ft_indexes[-1])

    home_or_away = []
    for i in range(len(homePlays)):
        if not pd.isna(homePlays[i]):
            home_or_away.append('HOME')
        elif not pd.isna(awayPlays[i]):
            home_or_away.append('AWAY')
        else:
            home_or_away.append('HOME')  # default for rows with no play text
    for i in last_fts:
        plays[i] = plays[i].replace('GOOD FT', 'LAST FT MADE')
    old_plays_no_player = []
    for play in plays:
        play = play.split(' by')[0]
        if play.endswith(' '):
            play = play.rstrip()
        old_plays_no_player.append(play)
    plays_no_player = update_play_types(old_plays_no_player)
    possession_starts = np.zeros(len(plays))
    no_poss_change = ['MISS', 'SUB', 'TIMEOUT', 'BLOCK', 'REBOUND OFF', 'REBOUND DEADB', 'GOOD FT']
    # GOOD TIPIN and GOOD 2PTR (older Sidearm formats) must be in both
    # change_poss and made_shots; without them, ~14% of made shots in older
    # seasons (and ~17 across 2023-24) fail to end the possession, and
    # OFFPOSS gets undercounted — inflating OFFRTG by 10-15% per affected
    # game.
    change_poss = ['TURNOVER', 'REBOUND DEF', 'LAST FT MADE',
                   'GOOD JUMPER', 'GOOD LAYUP', 'GOOD DUNK', 'GOOD 3PTR',
                   'GOOD TIPIN', 'GOOD 2PTR']
    made_shots  = ['GOOD JUMPER', 'GOOD LAYUP', 'GOOD DUNK', 'GOOD 3PTR',
                   'GOOD TIPIN', 'GOOD 2PTR']
# FOUL is a special case ASSIST gets checked for by made_shot
    for i in range(len(plays_no_player)-1):

        if plays_no_player[i] in change_poss and plays_no_player[i+1]!='ASSIST':
            if plays_no_player[i+1]=='FOUL' and teamName[i+1]!=teamName[i]:
                possession_starts[i+1]=0
            else:
                possession_starts[i+1]=1


        elif plays_no_player[i] =='ASSIST' and plays_no_player[i-1] in made_shots and plays_no_player[i+1] :

            possession_starts[i]=0
            possession_starts[i+1]=1

        elif plays_no_player[i] in made_shots  and plays_no_player[i+1] == 'FOUL' and teamName[i+1]!=teamName[i]:
            possession_starts[i+1] = 0
        elif plays_no_player[i] == 'ASSIST' and plays_no_player[i-1] in made_shots and plays_no_player[i+1]=='FOUL':
            possession_starts[i-1] = 0

    return possession_starts


def _mark_period_starts(possession_starts, period):
    """Mark the FIRST row of each period as a possession start.

    Done AFTER assign_teams runs so the team flip in assign_teams isn't
    triggered on row 0 (which would swap who gets credit for the first
    possession). assign_teams seeds with team1 = the actual first team
    in the play stream, so we want possTeam at row 0 to stay = team1 —
    only the OFFPOSS counter needs incrementing.

    Without this fix, the first possession of every period (one per
    half = 2 per game = ~50 per season) was uncounted, undercounting
    OFFPOSS by ~3-4% and inflating OFFRTG correspondingly.
    """
    period_list = [str(p) if not pd.isna(p) else '' for p in period]
    last_period = None
    for i in range(len(period_list)):
        cur = period_list[i]
        if not cur:
            continue
        if cur != last_period:
            possession_starts[i] = 1
            last_period = cur
    return possession_starts

def assign_teams(num_list, boxscore, teamName):
    """Seed the possession-team list with whichever team owns the FIRST
    row, then flip on every num==1 marker."""
    team_list = []
    away_team_name, home_team_name = getOfficialName(boxscore)
    # Walk teamName to find the first non-empty value that matches either
    # the home or away team. Older versions crashed when teamName[0] was
    # empty (e.g. a generic 'MISS by X' play whose Type branch didn't
    # append a Team) — UnboundLocalError on team1.
    team1 = team2 = None
    for t in teamName:
        if t == home_team_name:
            team1, team2 = home_team_name, away_team_name
            break
        if t == away_team_name:
            team1, team2 = away_team_name, home_team_name
            break
    if team1 is None:
        # No row matched either team name — fall back to the away team as
        # team1 (this preserves the original loop's invariant when every
        # row had been assigned away).
        team1, team2 = away_team_name, home_team_name
    current_team = team1

    for num in num_list:
        if num == 1:
            current_team = team2 if current_team == team1 else team1
        team_list.append(current_team)
    return team_list

def calculate_possession_points(points_list, possession_list):
    possession_points = []
    current_points = 0

    for i in range(len(points_list)):
        if possession_list[i] == 1 and i > 0:
            current_points = 0
        if points_list[i] != "":
            current_points += int(points_list[i])
        possession_points.append(str(current_points))
    
    return possession_points

# Calculate how long each possession lasted based on the game clock.

def calculate_possession_times(times, possession):
    possession_times = [0] * len(times)  # Initialize the result list with 0s
    last_valid_time = 1200  # Start the first possession using 1200 seconds
    
    for i in range(len(times)):
        possession_indicator = possession[i]

        if possession_indicator == 1:
            # Find the closest valid time for the current possession
            current_time = None
            for j in range(i, -1, -1):  # Look backwards for the nearest valid time
                if times[j] != "":
                    current_time = int(times[j])
                    break

            if current_time is None:
                # If no valid time is found for the current possession, skip it
                possession_times[i] = 0
                continue

            # Calculate the time difference between the last valid time and the current valid time
            possession_times[i] = last_valid_time - current_time
            last_valid_time = current_time  # Update the last valid time for the next possession

    return possession_times

def calculate_possession_numbers(possession_indicators):
    possession_numbers = []
    current_possession = 1

    for indicator in possession_indicators:
        if indicator == 1:
            current_possession += 1
        possession_numbers.append(current_possession)

    return possession_numbers

def team_change_indicator(team_list):
    # Initialize the result list with 0s
    result = [0] * len(team_list)
    
    # Track the last team seen
    last_team = team_list[0]
    
    # Iterate through the list to find changes
    for i in range(1, len(team_list)):
        if team_list[i] != last_team:
            result[i-1] = 1
            last_team = team_list[i]
    
    return result

def _play_types_from_plays(plays):
    """Strip player names from play strings and normalize free throw labels."""
    stripped = [play.split(' by')[0].rstrip() for play in plays]
    return update_play_types(stripped)

def assist_ind(homePlays, awayPlays, plays, period, teamName):
    """Return a 1/0 list indicating which rows are assists."""
    plays_no_player = _play_types_from_plays(plays)
    return [1 if p == 'ASSIST' else 0 for p in plays_no_player]

def defreb_ind(homePlays, awayPlays, plays, period, teamName):
    """Return a 1/0 list indicating which rows are defensive rebounds."""
    plays_no_player = _play_types_from_plays(plays)
    return [1 if p == 'REBOUND DEF' else 0 for p in plays_no_player]

def oreb_ind(homePlays, awayPlays, plays, period, teamName):
    """Return a 1/0 list indicating which rows are offensive rebounds."""
    plays_no_player = _play_types_from_plays(plays)
    offre_list = []
    for i in range(len(plays_no_player)):
        if plays_no_player[i]=='REBOUND OFF':
            offre_list.append(1)
        else:
            offre_list.append(0)

    return offre_list

def time_left(times, possessions):
    possession_durations = [0] * len(times)
    last_valid_time = None
    current_start_time = None

    for i in range(len(times)):
        try:
            current_time = int(times[i])
        except (ValueError, TypeError):
            continue
        
        last_valid_time = current_time
        if current_start_time is None:
            current_start_time = current_time
            
        if possessions[i] == 1 and last_valid_time is not None:
            possession_durations[i] = current_start_time - last_valid_time
            current_start_time = None

    return possession_durations

def classification(playDescription, playData, points, teamName, a):
    '''Map every row in the play-by-play to a fine-grained category string
    (e.g. "made shot", "final free throw made", "offensive foul").
    The result is used by possession_tracker() to figure out who has the ball.

    a is the year_check flag — True for seasons before 2016 where offensive fouls
    were recorded as turnovers instead.
    '''
    subData = ['subbing in', 'subbing out']
    shot = ['layup', 'three pointer', 'jumper', "tipin", 'dunk']
    # Pre-fill every row with an empty string so d[i] never raises KeyError
    # in possession_tracker even when a row doesn't match any play type.
    d = {i: '' for i in range(len(playData))}
    count = 0
    quarter = []
    if a == True:
        pass  # early-year mode: offensive fouls are recorded as turnovers
    #print(playData)
    #print(playData[655], "AAA")
    for i in range(len(playData)):
        if playData[i-1] == 'free throw':
            if points[i-1] == 1:
                if playData[i-2] != 'free throw' and playData[i-2] != 'deadball rebound':
                    if playData[i] != 'free throw' and playData[i] != 'deadball rebound':
                        d[i-1] = 'final free throw made'
                                               
        if playData[i] == 'free throw':
            if points[i] == 1:
                if playData[i-1] == 'free throw':
                    d[i] = 'final free throw made'
                elif playData[i-1] == 'deadball rebound':
                    d[i] = 'final free throw made'
                    
                else:
                    d[i] = 'free throw made'
            else:
                d[i] = 'free throw missed'
        elif playData[i] in subData:
            d[i] = 'sub'
        elif playData[i] in shot and points[i] == 2 or points[i] == 3:
            d[i] = 'made shot'    
        elif playData[i] in shot and points[i] != 2 and points[i] != 3:
            if 'GOOD DUNK' in str(playDescription[i]):
                #print(i, 'its working')
                d[i] = 'made shot'
            else:
                d[i] = 'missed shot'    
        elif playData[i] == 'turnover':
            d[i] = 'turnover'
            
        elif playData[i] == 'steal':
            d[i] = 'steal'
        elif playData[i] == 'block':
            d[i] = 'block'
        elif playData[i] == 'assist':
            d[i] = 'assist'
        elif playData[i] == 'jumper':
            d[i] = 'jumper'
        elif playData[i] == 'defensive rebound':
            if 'TEAM' in str(playDescription[i]):
                d[i] = 'team rebound'
                print(i, 'what')
            else:
                d[i] = 'defensive rebound'
        elif playData[i] == 'offensive rebound':
            d[i] = 'offensive rebound'
        elif playData[i] == 'deadball rebound':
            d[i] = 'deadball rebound'
        elif playData[i] == 'timeout':
            d[i] = 'timeout'
        elif playData[i] == 'foul':
            if 'TECH' in str(playDescription[i]):
                #print(i, 'Tech')
                d[i] = 'technical foul'
            else:
                d[i] = 'foul'
        #elif playData[i] == 'technical foul':
            #d[i] = 'technical foul'
        #I don't think any plays are classified as technical fouls, but if wrong
        #this can be used
        
        
        else:
            #d[i] = 'start of quarter'
            #print(i)
            count = count + 1
            quarter.append(i)
            if count == 1:
                d[i] = 'start of quarter1'
                #print(i, d[i])
            if count == 2:
                d[i] = 'start of quarter2'
                #print(i, d[i])
            if count == 3:
                d[i] = 'start of quarter3'
                #print(i, d[i])
            if count == 4:
                d[i] = 'start of quarter4'
                #print(i, d[i])
        for i in range(2, len(d)):
            try:
                if d[i-2] == 'technical foul':
                    if d[i-1] == 'final free throw made':
                        #print(i, 'technical free throw made')
                        d[i-1] = 'technical free throw made'
                    elif d[i-1] == 'free throw missed':
                        #print(i, 'technical free throw missed')
                        d[i-1] ='technical free throw missed'
                    elif d[i] == 'final free throw made':
                        #print(i, 'technical free throw made')
                        d[i] = 'technical free throw made'
                    elif d[i] == 'free throw missed':
                        #print(i, 'technical free throw missed')
                        d[i] = 'technical free throw missed'
            except KeyError:
                continue
    
                    
    #print(count)
    # print(d, len(d))
    # print()
    # print()
    # #print(quarter)
    # #print(len(d), len(playData))
    # print(playData, len(playData))
    # for key in range(len(d)):
    #     if not key in d.keys():
    #         d[key] = ""
    return d

def getOfficialName(boxscore):
    '''
    Returns (away_name, home_name) for the teams in the game.
    Uses html_parsers for uniform extraction with null safety.
    Raises ValueError if team names cannot be extracted.
    '''
    result = html_parsers.parse_team_names_from_boxscore(boxscore)
    if result is None:
        raise ValueError("Could not extract team names from box score")
    return result

def possession_tracker(d, teamName, quarter, p, a, boxscore, home_team_name=None, away_team_name=None):
    '''Walk through every play and figure out which team has the ball.
    Appends the possessing team's name to list p for each row.

    d          - classification dict from classification()
    teamName   - list of team names from the Team column
    quarter    - passed as d_copy; not actually a quarter list (legacy parameter name)
    p          - empty list that gets filled with possession team names
    a          - year_check flag (True for pre-2016 seasons)
    '''
    nochange = ['free throw made', 'free throw missed', "sub", 'subbing in', 'subbing out', 'timeout', 'missed shot', 'block', 'offensive rebound', 'deadball rebound']
    tagon = ['assist', 'steal']
    track = None
    if len(d) == 0:
        return  # nothing to process for an empty game
    if home_team_name is None or away_team_name is None:
        if boxscore is None:
            raise ValueError("possession_tracker requires boxscore or home_team_name/away_team_name")
        away_team_name, home_team_name = getOfficialName(boxscore)
    # Normalize to match pbp 'Team' column casing (typically lowercase).
    if isinstance(home_team_name, str):
        home_team_name = home_team_name.lower()
    if isinstance(away_team_name, str):
        away_team_name = away_team_name.lower()

    # If the first row doesn't have a team indicator (e.g., quarter marker), use the first non-empty one.
    team0 = teamName[0] if len(teamName) > 0 else ""
    if not isinstance(team0, str) or not team0.strip():
        for t in teamName:
            if isinstance(t, str) and t.strip():
                team0 = t
                break
    if not isinstance(team0, str) or not team0.strip():
        team0 = home_team_name
    #at the start of each quarter it checks who has possession
    if d[0] == 'made shot' or d[0] == 'turnover':
        if team0 == home_team_name:
            track = home_team_name
        elif team0 != home_team_name:
            track = away_team_name
    elif d[0] == 'foul':
        if team0 == home_team_name:
            track = away_team_name
        elif team0 != home_team_name:
            track = home_team_name
    else:
        if team0 == home_team_name:
            track = home_team_name
        else:
            track = away_team_name
    
    c = 0
    q1 = None
    q2 = None
    q3 = None
    q4 = None

    def _handle_quarter_start(i, fallback_index=None):
        nonlocal track
        next_i = i + 1
        if next_i not in d or next_i >= len(teamName):
            if track is None:
                track = home_team_name
            p.append(track)
            return

        next_d = d[next_i]
        next_team = teamName[next_i]

        if next_d == 'made shot' or next_d == 'turnover':
            track = home_team_name if next_team == home_team_name else away_team_name
            p.append(track)
            return

        if next_d == 'foul':
            track = away_team_name if next_team == home_team_name else home_team_name
            p.append(track)
            return

        # Fallback: if we know what possession started the previous quarter, flip it.
        if fallback_index is not None and 0 <= fallback_index < len(p):
            if p[fallback_index] == home_team_name:
                track = away_team_name
            elif p[fallback_index] == away_team_name:
                track = home_team_name
            else:
                track = home_team_name if next_team == home_team_name else away_team_name
        else:
            track = home_team_name if next_team == home_team_name else away_team_name

        p.append(track)

    for i in range(0, len(d)):
        if d[i] == 'defensive rebound':
            if teamName[i] == home_team_name:
                p.append(track)
                track = home_team_name
            else:
                p.append(track)
                track = away_team_name
        elif d[i] == 'jumper':
            if teamName[i] == home_team_name:
                p.append(track)
                track = away_team_name
            else:
                p.append(track)
                track = home_team_name
        elif d[i] == 'team rebound':
            if teamName[i] == teamName[i-1]:
                if teamName[i] == home_team_name:
                    track = away_team_name
                    p.append(track)
                else:
                    track = home_team_name
                    p.append(track)
            else:
                if teamName[i] == home_team_name:
                    track = home_team_name
                    p.append(track)
                else:
                    track = away_team_name
                    p.append(track)
        elif d[i] == 'turnover':
            if teamName[i] == home_team_name:
                p.append(track)
                track = away_team_name
            else:
                p.append(track)
                track = home_team_name
        
        elif d[i] == 'made shot':
        #Checks to see if it's an and one situation
            if i != len(d) - 2 and i != len(d) - 1:
                if d[i+1] == 'foul' and teamName[i+2] == teamName[i] and (d[i+2] == 'final free throw made' or d[i+2] == 'free throw missed'):
                    d[i+1] = 'defensive foul'
                    if teamName[i] != teamName[i+1]:
                        d[i] = 'and one'
                        #print(d[i], i, teamName[i], teamName[i+1])
                        if track == home_team_name:
                            p.append(track)
                        elif track == away_team_name:
                            p.append(track)
                    else:
                        if track == home_team_name:
                            p.append(track)
                            track = away_team_name
                        elif track == away_team_name:
                            p.append(track)
                            track = home_team_name
                elif i + 3 < len(d) and d[i+1] == 'assist' and d[i+2] == 'foul' and teamName[i+3] == teamName[i] and (d[i+3] == 'final free throw made' or d[i+3] == 'free throw missed'):
                    d[i+2] = 'defensive foul'
                    if teamName[i] != teamName[i+2]:
                        d[i] = 'and one'
                        #print(d[i], i, teamName[i], teamName[i+1])
                        if track == home_team_name:
                            p.append(track)
                        elif track == away_team_name:
                            p.append(track)
                    else:
                        if track == home_team_name:
                            p.append(track)
                            track = away_team_name
                        elif track == away_team_name:
                            p.append(track)
                            track = home_team_name
                else:
                    if teamName[i] == home_team_name:
                        p.append(track)
                        track = away_team_name
                    else:
                        p.append(track)
                        track = home_team_name
            elif i == len(d) - 2 or i == len(d) - 1:
                if teamName[i] == home_team_name:
                    p.append(track)
                    track = away_team_name
                else:
                    p.append(track)
                    track = home_team_name
        elif d[i] == 'final free throw made':
            if teamName[i] == home_team_name:
                p.append(track)
                track = away_team_name
            else:
                p.append(track)
                track = home_team_name
        elif d[i] == 'start of quarter':
            if teamName[1] == home_team_name:
                if quarter[i] == 1 or quarter[i] == 3:
                    track = home_team_name
                    p.append(track)
                else:
                    track = away_team_name
                    p.append(track)
            else:
                if quarter[i] == 1 or quarter[i] == 3:
                    track = away_team_name
                    p.append(track)
                else:
                    track = home_team_name
                    p.append(track)
        elif d[i] == 'start of quarter1':
            #at the start of each quarter it checks who has possession
            _handle_quarter_start(i, None)
            q1 = len(p) - 1
        elif d[i] == 'start of quarter2':
            _handle_quarter_start(i, q1)
            q2 = len(p) - 1
        elif d[i] == 'start of quarter3':
            _handle_quarter_start(i, q2)
            q3 = len(p) - 1
        elif d[i] == 'start of quarter4':
            _handle_quarter_start(i, q3)
            #print(p[i], 7)
        elif d[i] in nochange:
            #if len(p)!= 0:
                if track == home_team_name:
                    p.append(track)
                elif track == away_team_name:
                    p.append(track)
        elif d[i] == 'defensive foul':
            if track == home_team_name:
                p.append(track)
            elif track == away_team_name:    
                p.append(track)
        elif d[i] == 'and one':
            if track == home_team_name:    
                p.append(track)
            elif track == away_team_name:   
                p.append(track)
        elif d[i] == 'foul':
        #Checks if fouls are offensive or defensive
                if track == home_team_name:
                    if teamName[i] == home_team_name:
                        if i + 1 < len(d) and d[i+1] != 'turnover':
                            if a == False:
                                p.append(track)
                                track = away_team_name
                            elif a == True:
                                track = home_team_name
                                p.append(track)
                            d[i] = 'offensive foul'
                        else:
                            p.append(track)
                    
                    elif teamName[i] != home_team_name:
                        track = home_team_name
                        p.append(track)
                        d[i] = 'defensive foul'
                    
                elif track == away_team_name:
                    if teamName[i] == home_team_name:
                        track = away_team_name
                        p.append(track)
                        d[i] = 'defensive foul'
                
                    elif teamName[i] != home_team_name:
                        if i + 1 < len(d) and d[i+1] != 'turnover':
                            if a == False:
                                p.append(track)
                                track = home_team_name
                            elif a == True:
                                track = away_team_name
                                p.append(track)
                            d[i] = 'offensive foul'
                            #print(i, 'off foul')
                        else:
                            p.append(track)
        elif d[i] == 'technical foul':
            if track == home_team_name:
                if teamName[i] == home_team_name:
                    p.append(track)
                    track = away_team_name
                else:
                    p.append(track)
            else:
                if teamName[i] == home_team_name:
                    p.append(track)
                else:
                    p.append(track)
                    track = home_team_name ####
        
        elif d[i] in tagon:
            #print("001", i, p)
            # Possession for assist/steal should match the previously appended possession.
            if len(p) > 0:
                p.append(p[-1])
            else:
                p.append(track if track is not None else home_team_name)
        elif d[i] == 'technical free throw made' or d[i] == 'technical free throw missed':
            p.append(track)
        else:
            if d[i]:
                logger.warning("Unhandled play type at index %d: %s", i, d[i])
            # Always append so p stays the same length as d.
            p.append(track if track is not None else home_team_name)
        # if i < 20:
        #     #print(d[i], p)
    '''for i in range(0, len(p)-2):
        if p[i] != p[i+1]:
            print(i+2)'''
    #print(p)
    #print(len(p))
    #print(p[q1], p[q2], p[q3], p[q4])
    # return (d)
    # return p

def possession_points(points, poss, p, d, ppr, ppr2):
    '''Tally points per possession and assign possession sequence numbers.

    poss  - empty list; filled with the possession number for each row
    ppr   - empty list; filled with total points at the end of each possession (0 otherwise)
    ppr2  - empty list; like ppr but repeats the total on every row of the possession
    '''
    if len(p) == 0:
        return  # empty game — nothing to compute
    count = 1
    counter = 0
    point = 0
    per = {}
    pe = []
    for i in range(0, len(p)-1):
        if p[i] == p[i+1]:
            poss.append(count)
            pe.append(0)
            if d[i+1] == 'start of quarter2':
                count = count + 1
            if d[i+1] == 'start of quarter3':
                count = count + 1            
            if d[i+1] == 'start of quarter4':
                count = count + 1
        elif p[i] != p[i+1]:
            poss.append(count)
            count = count + 1
            pe.append(points[i])
    '''for i in range(0, len(p)-1):
        if points[i] == 2 or points[i] == 3:
            if p[i] == p[i-1]:
                poss[i] = poss[i-1]
            #elif p[i] != p[i-1]:
                #poss[i] = poss[i] - 1
        if d[i] == 'turnover':
            if p[i] == p[i-1]:
                poss[i] = poss[i-1]
            #else:
                #poss[i] = poss[i] - 1
        if d[i] == 'assist':
            poss[i] = poss[i-1]
        if d[i] == 'final free throw made':
            poss[i] = poss[i-1]
            if i > 2:
                if d[i-2] == 'and one':
                    if p[i] == p[i-1]:
                        poss[i-2] = poss[i-3]
                        poss[i] = poss[i-1]
                    elif p[i] != p[i-1]:
                        poss[i] = poss[i] - 1
                        poss[i-2] = poss[i-2] - 1'''
    '''for i in range(0, len(p) - 1):
        if d[i] == 'made shot':
            if d[i] == d[i+1]:
                poss[i+1] = poss[i] + 1'''
    for i in range(1, len(d)):
        if d[i] == 'start of quarter':
            #print(i, start)
            poss[i] = poss[i] + 1
    '''for i in range(0, len(p) - 1):
        if d[i] == 'and one':
            poss[i] = poss[i] + 1
            poss[i+2] = poss[i+2] + 1
            if d[i-1] == 'turnover':
                poss[i] = poss[i] + 1   '''     
    for i in range(0, len(poss)):
        per[poss[i]] = 0
    for i in range(0, len(poss)):
        if points[i] == 2 or points[i] == 3 or points[i] == 1:
            per[poss[i]] += points[i]
            counter += points[i]
        elif d[i] == 'made shot' and points[i] == 0:
            per[poss[i]] += 2
            counter += 2
        '''if points[i] == 2 or points[i] == 3:
            per[int(poss[i])] = int(points[i])
            for j in range(0, len(poss)):
                if points[j] == 2 or points[i] == 3 or points[i] == 1 and poss[j] == poss[i] and i != j:
                    per[int(poss[[i]])] += int(points[j])
            #if d[i] == 'and one':
                #per[poss[i]] = per[poss[i]] + 
        else:
            per[poss[i]] = 0'''
            
    for i in range(0, len(poss)-1):
        #Designates which play is last in a possession
        if i != len(poss)-1:
            if poss[i] != poss[i+1]:
                ppr.append(per[poss[i]])
                if per[poss[i]] == 1 or per[poss[i]] == 2 or per[poss[i]] == 3:
                    ppr2.append(per[poss[i]])
                else:
                    ppr2.append(0)
            if poss[i] == poss[i+1]:
                ppr.append(' ')
                if per[poss[i]] == 1 or per[poss[i]] == 2 or per[poss[i]] == 3:
                    ppr2.append(per[poss[i]])
                else:
                    ppr2.append(0)
        if i == len(poss)-1 and d[i] != 'made shot':
            ppr.append(' ')
        if i == len(poss)-1 and d[i] == 'made shot':
            if points[i] == 0:
                ppr.append(2)
            else:
                ppr.append(points[i])
       
        '''if poss[i] == poss[len(poss)-1]:
            print('hhhh')
            if d[i+1] == 'made shot':
                del ppr[-1]
                ppr.append(per[poss[i]])
            if d[i+1] == 'made shot':
                del ppr[-1]
                ppr.append(per[poss[i]])'''
    #print(ppr)
    #print(per)
    ppr.append(' ')
    ppr.append(' ')
    ppr2.append(per[poss[len(poss)-1]])
    ppr2.append(per[poss[len(poss)-1]])
    for i in range(0, len(ppr)):
        if ppr[i] == ' ':
            ppr[i] = 0
    print(ppr[len(ppr)-1], 'should be 0')
    #print(sum(ppr), 'game sum')
    #print(len(ppr))        
    #print(counter)            
    #print(per)
    #print(poss[len(poss)-1], 'here')
    #print(ppr2)
    if p[len(p)-2] == p[len(p)-1]:
        poss.append(poss[len(poss)-1])
    else:
        poss.append(poss[len(poss)-2] + 1)
    if d[len(poss)-2] == 'made shot':
        ppr[len(poss)-2] = per[poss[len(poss) - 2]]
    if d[len(poss)-1] == 'made shot':
        del ppr[-1]
        ppr.append(per[poss[len(poss)-1]])
    return poss

def year_check(file_path):
    '''Returns True for seasons before 2016.
    In those years the data source records offensive fouls as turnovers,
    so the possession logic needs to handle them differently.
    '''
    ch = ['2010', '2011', '2012', '2013', '2014', '2015']
    early_year = False
    for element in ch:
        if element in file_path:
            early_year = True
    #print(early_year)
    return early_year

# No actual use for this function
def plusminus(player, p, ppr, poss, players):
    #print(p)
    plusminus = 0
    lineup = ["", "", "", "", ""]
    for i in range(0, len(players)):
        #lineup = lineup.sort()
        if ppr[i] != " ":
            if player in players:
                if p[i] == "C":
                    plusminus = plusminus + ppr[i]
                else:
                    plusminus = plusminus - ppr[i]
    print(plusminus, player)
    print(players[0])

def expandColumn(df):
    #df['homeLineup'] = df['homeLineup'].apply(eval)
    #df['awayLineup'] = df['awayLineup'].apply(eval)


    # When the lineup state is exactly 5 players, just unpack it.
    # When it has < 5 (sub failed to find a player to remove, etc.), pad
    # with Python None so playerMissing fires.
    # When it has > 5 (sub-in fired without a matching sub-out), the state
    # is corrupted — write Python None across all 5 slots so playerMissing
    # fires and downstream code drops the row. The OLD code wrote the
    # STRING "None" here, which slipped past every is.na/playerMissing
    # check downstream and produced phantom "None, None, None, None, None"
    # lineups in the leaderboard.
    df['homeLineup'] = df['homeLineup'].apply(
        lambda x: x + [None] * (5 - len(x)) if len(x) <= 5 else [None] * 5)
    df['awayLineup'] = df['awayLineup'].apply(
        lambda x: x + [None] * (5 - len(x)) if len(x) <= 5 else [None] * 5)


    df_expanded = pd.DataFrame(df['homeLineup'].tolist(), columns=['homePlayer1','homePlayer2','homePlayer3','homePlayer4','homePlayer5'])
    df = pd.concat([df, df_expanded], axis=1)


    df_expanded = pd.DataFrame(df['awayLineup'].tolist(), columns=['awayPlayer1','awayPlayer2','awayPlayer3','awayPlayer4','awayPlayer5'])
    df_result = pd.concat([df, df_expanded], axis=1)


    columns_to_check = ['homePlayer1','homePlayer2','homePlayer3','homePlayer4','homePlayer5', 'awayPlayer1','awayPlayer2','awayPlayer3','awayPlayer4','awayPlayer5']


    df_result['playerMissing'] = (df_result[columns_to_check].isna().any(axis=1)).astype(int)


    # Strip trailing play modifiers like "(fastbreak)" and "(in the paint)" from text columns.
    # Using vectorized str.replace avoids the chained-assignment error pandas raises on row-by-row writes.
    parse_out = ['(fastbreak)', '(in the paint)']
    for string in parse_out:
        suffix_pat = re.escape(string) + r'\s*$'
        for col in ('homePlay', 'awayPlay', 'Player', 'Play'):
            df_result[col] = df_result[col].astype(str).str.replace(suffix_pat, '', regex=True)
    
    return df_result

def makeHeaderPBP(sport, school, year_str):
    
    sport_root = _sport_root(sport)

    # Directory to the header folder of the current year
    header_dir = sport_root / 'SAA' / school / 'headers' / year_str

    
    if not header_dir.exists(): 
        return # bail out if no header directory for that year
    
    # Directory to the HTML folder of the current year
    html_dir = sport_root / 'SAA' / school / 'HTML' / year_str
    
    # Directory to the Table folder of the current year
    table_dir = sport_root / 'SAA' / school / 'tables' / year_str
    
    # Directory to the pbp folder of the current year
    pbp_dir = sport_root / 'SAA' / school / 'pbp' / year_str
    
    # Create a pbp directory for that team is not already in existence
    (sport_root / 'SAA' / school / 'pbp').mkdir(parents=True, exist_ok=True)

    # Create a directory for that year if not already in existence
    pbp_dir.mkdir(parents=True, exist_ok=True)


    # Creates a list of all csv files from the header directory of the current year
    header_files = sorted(os.listdir(header_dir))
    
    
    for header_file in header_files: # Loop through every csv files from the list


        # Open the csv files from the header directory for reading
        print(header_file)
        print()
        try:
            with open(str(header_dir / header_file), 'r', encoding='utf-8', errors='replace') as header_file_h:
                header_data = list(csv.reader(header_file_h))
        except FileNotFoundError:
            logger.warning("Header file not found: %s", str(header_dir / header_file))
            continue
        #print(header_data)
 
        html_file = str(html_dir / (header_file.split('_header')[0] + '.html'))
        try:
            with open(html_file, 'r', encoding='utf-8', errors='replace') as html_file_h:
                soup = bs(html_file_h, 'lxml')
        except FileNotFoundError:
            logger.warning("HTML file not found: %s", html_file)
            continue

        # Validate HTML structure before parsing
        valid, err_msg = html_parsers.validate_game_html(soup)
        if not valid:
            logger.warning("Skipping %s: %s", header_file, err_msg)
            continue

        tables_result = html_parsers.find_player_tables(soup)
        if tables_result is None:
            logger.warning("Skipping %s: could not find player tables", header_file)
            continue
        player_tables = tables_result

        boxscore = soup.find('section', {'id': 'box-score'})
        #centre_index, headline_temp = getCentreIndex(boxscore)
        #centre_index, headline = getCentreIndex(boxscore)


        #assigns first row of the header as list'header_titles' and second row as 'header_info'
        header_titles = header_data[0]
        header_info = header_data[1]


        table_file = header_file.replace('header', 'table')
        table_file_path = str(table_dir / table_file)
        try:
            with open(table_file_path, 'r', encoding='utf-8', errors='replace') as table_fh:
                table_data = list(csv.reader(table_fh))
        except FileNotFoundError:
            logger.warning("Table file not found: %s", table_file_path)
            continue

        pbp = soup.find('section', {'id': 'play-by-play'})
        table_titles = table_data[0]
        table_titles[0], table_titles[1], table_titles[5] ="timeRemaining", "awayPlay", "homePlay"
        table_titles[2], table_titles[3], table_titles[4] = "awayTeamScore", "playTeamIndicator", "homeTeamScore"
        table_titles[6], table_titles[7] = "gameScore", "teamIndicator"
        s_away, s_home = "", ""
        for pos in range(1, len(table_data)):
            '''
            I had to split the code into multiple if statements
            For the away and home side
            
            The away and home score don't have the same format
            so an error might occur if i try to encompass everything in one boolean expression
            Also, it will not look neat
            
            '''
            # For score with parenthesis on away side
            away_val = str(table_data[pos][2]).strip()
            if "(" in away_val:
                away_index = away_val.find("(")
                table_data[pos][2] = away_val[:away_index]
                s_away = table_data[pos][2]

            # For regular score on away side
            if "(" not in away_val and away_val != "":
                s_away = away_val

            # For score with parenthesis on home side
            home_val = str(table_data[pos][4]).strip()
            if "(" in home_val:
                home_index = home_val.find("(")
                table_data[pos][4] = home_val[:home_index]
                s_home = table_data[pos][4]

            # For regular score on home side
            if "(" not in home_val and home_val != "":
                s_home = home_val
                
            # Only place where the format is the same on play-by-play
            # For cells with empty strings
            # Replace with current home and away score
            if "" == table_data[pos][2]:
                table_data[pos][2] = s_away
                table_data[pos][4] = s_home
        
        # print(table_data)
    
        #puts all titles into a combined list
        all_titles = header_titles
        all_titles.extend(table_titles)


        df = pd.DataFrame(columns = all_titles)
        
        i = 1
        for row in range(len(table_data)-1):
            combined = header_info[:]
            combined.extend(table_data[i])
            df.loc[len(df.index)] = combined
            i+=1
                        
        away_name, home_name = getOfficialName(boxscore)
        away_lineup = list(get_starters(player_tables[0]))
        home_lineup = list(get_starters(player_tables[1]))
        # Full team rosters (everyone who played, with minutes) — used by
        # the post-pass heal helper to resolve stretches where the
        # play-stream walk left fewer than 5 visible players but didn't
        # find an action by the missing 5th player.
        try:
            away_roster = html_parsers.parse_player_roster(player_tables[0])
            home_roster = html_parsers.parse_player_roster(player_tables[1])
        except Exception:
            away_roster = []
            home_roster = []
        for scraped, canonical in PLAYER_NAME_CORRECTIONS.items():
            if scraped in away_lineup:
                away_lineup[away_lineup.index(scraped)] = canonical
            if scraped in home_lineup:
                home_lineup[home_lineup.index(scraped)] = canonical

        # First-name recovery: if any starter entry is last-name-only
        # (because the source HTML stored a jersey number in place of the
        # first name), scan the play stream for the player's full name and
        # upgrade the lineup entry before the sub-tracking loop begins.
        away_name_map, home_name_map = _build_name_recovery_maps(df)
        away_lineup = _upgrade_lineup_names(away_lineup, away_name_map)
        home_lineup = _upgrade_lineup_names(home_lineup, home_name_map)

        df.head()
        #loops through the dataFrame.
        #going to use to loop through play data to create a new column
        #called type.
        Type, l_away_lineup, l_home_lineup = [], [], []
        #outcome from a shot
        Outcome= []
        #what team did what
        Team = []
        #name of player who was involved in the play
        player=[]
        #points earned
        points = []
        
        # NOTE: missing comma between '2ptr' and 'steal' (now fixed) caused
        # Python to silently concatenate the tokens, dropping 'steal' from
        # the play-type list — so steal events couldn't have their Player
        # extracted. Same root cause as the Team-attribution failure for
        # "GOOD 2PTR by X" plays in older Sidearm feeds.
        type_of_plays = ['foul ', 'jumper', 'rebound', '3ptr', ' ft ',
                         'turnover', 'timeout 30sec by ', '2ptr',
                         'steal', 'assist', 'layup', 'block ', 'sub', 'tipin']
        
        # Within-clock sub-block reorder — see _reorder_sub_blocks() comment
        # for the failure mode. Done here, after df is fully populated but
        # before the play-state loop starts, so the loop sees subs in the
        # OUT-then-IN order the lineup-state machine assumes.
        df = _reorder_sub_blocks(df)
        # Reset df index after reorder so subsequent df[col][i] integer
        # indexing in the play loop hits the right row (the play loop uses
        # `for data in df['Play']` plus positional `df["homePlay"][i]`).
        df = df.reset_index(drop=True)

        i = 0
        skip_line = 0 # Sets boolean to check order of substituition
        prev_period = None  # Period-boundary watcher (see comment below).
        for data in df['Play']:
            data = data.lower()

            # PERIOD BOUNDARY HEALING.
            #
            # Two-step repair at each period boundary:
            #
            # 1. Retroactively add to the previous-period lineup any
            #    player whose SUB OUT appears in the period-start clock
            #    block. Sidearm's convention at quarter boundaries (and
            #    halftime in 2-half formats) is to emit SUB OUTs for
            #    every player who finished the previous period but
            #    doesn't return for the new one, followed by SUB INs for
            #    every player who replaces them. A SUB OUT for a player
            #    NOT in our parser-state means the parser missed them
            #    earlier; they were on the floor at the end of the
            #    previous period. Adding them now lets the upcoming SUB
            #    OUT events succeed cleanly and keeps the lineup at 5.
            #
            # 2. If the lineup is STILL broken (fewer than 5 players)
            #    after step 1 — e.g. the period boundary has no sub
            #    events and we entered it with a broken state — fall
            #    back to `_infer_period_starters` to derive 5 from
            #    upcoming on-court actions.
            cur_period = df['Period'].iloc[i] if 'Period' in df.columns else None
            if prev_period is not None and cur_period is not None and cur_period != prev_period:
                # Step 1: scan the period-start clock block for SUB OUTs
                # whose target isn't in our state.
                period_start_clock = df['timeRemaining'].iloc[i] if 'timeRemaining' in df.columns else None
                if isinstance(period_start_clock, str) and period_start_clock:
                    j = i
                    while j < len(df):
                        row_period = df['Period'].iloc[j] if 'Period' in df.columns else None
                        row_clock  = df['timeRemaining'].iloc[j] if 'timeRemaining' in df.columns else None
                        if row_period != cur_period:
                            break
                        if row_clock != period_start_clock:
                            break
                        play_lc = str(df['Play'].iloc[j]).lower() if 'Play' in df.columns else ''
                        if 'sub out by' in play_lc:
                            # Extract the player name from `SUB OUT by FIRST,LAST`.
                            try:
                                sub_player = play_lc.split(' by ', 1)[1].strip()
                            except IndexError:
                                sub_player = ''
                            if sub_player:
                                sub_norm = _normalize_player_key(sub_player)
                                home_norms = {_normalize_player_key(x) for x in home_lineup}
                                away_norms = {_normalize_player_key(x) for x in away_lineup}
                                if sub_norm and sub_norm not in home_norms and sub_norm not in away_norms:
                                    # Use the row's homePlay / awayPlay split to
                                    # pick the right side. Same defensive
                                    # NaN-safe pattern as the main sub branch.
                                    hp_raw = df['homePlay'].iloc[j]
                                    ap_raw = df['awayPlay'].iloc[j]
                                    hp_lc  = hp_raw.lower() if isinstance(hp_raw, str) else ''
                                    ap_lc  = ap_raw.lower() if isinstance(ap_raw, str) else ''
                                    if play_lc == hp_lc and hp_lc and len(home_lineup) < 5:
                                        home_lineup.append(sub_player)
                                    elif play_lc == ap_lc and ap_lc and len(away_lineup) < 5:
                                        away_lineup.append(sub_player)
                                    elif len(home_lineup) < 5 and not ap_lc:
                                        home_lineup.append(sub_player)
                                    elif len(away_lineup) < 5 and not hp_lc:
                                        away_lineup.append(sub_player)
                        j += 1

                # Step 2: only re-infer if we're STILL short. Done
                # conditionally because re-infer can pick up subs-in
                # as "starters" by mistake (saw this regress 12 games
                # when applied unconditionally — see session_notes).
                if len(home_lineup) != 5:
                    new_home = _infer_period_starters(df, i, cur_period, 'home')
                    if len(new_home) >= 5:
                        home_lineup = list(new_home[:5])
                if len(away_lineup) != 5:
                    new_away = _infer_period_starters(df, i, cur_period, 'away')
                    if len(new_away) >= 5:
                        away_lineup = list(new_away[:5])
                # Clear any pending skip_line so a stale skip from the
                # previous period doesn't carry over.
                skip_line = 0
            prev_period = cur_period

            player_added = False
            for play_type in type_of_plays:
                player_name = getPlayer(play_type, data)
                # Strip play modifiers that some Sidearm feeds glue onto
                # the player name in the play text — e.g. "GOOD LAYUP by
                # COMBS,ISABELLE(fastbreak)" produces a `player_name` of
                # `combs,isabelle(fastbreak)` which then gets added to the
                # lineup as if it were a different player from `combs,
                # isabelle`. Without the strip, the lineup state silently
                # grows past 5 (or registers duplicates) and breaks every
                # subsequent snapshot. Seen in women's Centre 2025-26 P2
                # around 04:13.
                for _mod in ('(fastbreak)', '(in the paint)', '(in the paint',
                             '(fastbreak'):
                    if _mod in player_name:
                        player_name = player_name.replace(_mod, '').strip()
                player_name = player_name.rstrip(' )')
                player_name_check = player_name
                if player_name != '0' and player_name != "":
                    player.append(player_name)
                    player_added = True
                    break


            if 'jumper by' in data:
                Type.append('jumper')
                if 'good jumper ' in data:
                    Outcome.append('good')
                    points.append('2')
                elif 'miss jumper ' in data:
                    Outcome.append('missed')
                    points.append('')
                else:
                    Outcome.append('')
                    points.append('')

                if player_added == False:
                    player.append('')
                #if isHome(data, df)== '1':
                if data == df['homePlay'][i].lower():
                    #Team.append('Centre')
                    Team.append(home_name)
                else:
                    #Team.append(official_opponent_name)
                    Team.append(away_name)
            elif 'layup by' in data:
                Type.append('layup')
                if 'good layup' in data:
                    Outcome.append('good')
                    points.append('2')
                elif 'miss layup' in data:
                    Outcome.append('missed')
                    points.append('')
                else:
                    Outcome.append('')
                    points.append('')
                if player_added == False:
                    player.append('')
                #if isHome(data, df) == '1':
                if data == df['homePlay'][i].lower():
                    #Team.append('Centre')
                    Team.append(home_name)
                else:
                    #Team.append(official_opponent_name)
                    Team.append(away_name)
                    
            elif 'tipin' in data:
                 Type.append('tipin')
                 if 'good tipin' in data:
                     Outcome.append('good')
                     points.append('2')
                 elif 'miss tipin' in data:
                     Outcome.append('missed')
                     points.append('')
                 else:
                     Outcome.append('')
                     points.append('')
                 if player_added == False:
                     player.append('')
                 #if isHome(data, df) == '1':
                 if data == df['homePlay'][i].lower():
                     #Team.append('Centre')
                     Team.append(home_name)
                 else:
                     #Team.append(official_opponent_name)
                     Team.append(away_name)
            # NOTE on branch order: '3ptr by' and 'ft by' MUST be tested
            # BEFORE the loose 'dunk' / 'assist' / 'block' substring
            # branches. Those keywords can appear inside PLAYER NAMES —
            # "GOOD 3PTR by BLOCK,KELSEY" was typed as a block (−3 pts
            # per make) and "GOOD FT by DUNKELBERGER" as a good dunk
            # (+2 instead of +1). The shot tests are anchored on
            # "<type> by" so they can't fire on a name.
            elif '3ptr by' in data:
                Type.append('three pointer')
                if 'miss' in data:
                    Outcome.append('missed')
                    points.append('')
                elif 'good' in data:
                    Outcome.append('good')
                    points.append('3')
                else:
                    Outcome.append('')
                    points.append('')

                if player_added == False:
                    player.append('')
                #if isHome(data, df) == '1':
                if data == df['homePlay'][i].lower():
                    Team.append(home_name)
                else:
                    Team.append(away_name)
            elif 'ft by' in data:
                if player_added == False:
                    player.append('')
                Type.append('free throw')
                if 'good ft by ' in data:
                    Outcome.append('good')
                    points.append('1')
                elif 'miss ft by ' in data:
                    Outcome.append('missed')
                    points.append('')
                else:
                    Outcome.append('')
                    points.append('')
                #if isHome(data, df) == '1':
                if data == df['homePlay'][i].lower():
                    #Team.append('Centre')
                    Team.append(home_name)
                else:
                    #Team.append(official_opponent_name)
                    Team.append(away_name)
            elif 'dunk' in data:
                Type.append('dunk')
                if 'good dunk' in data:
                    Outcome.append('good')
                    points.append('2')
                else:
                    Outcome.append('')
                    points.append('')
                if player_added == False:
                    player.append('')
                #if isHome(data, df) == '1':
                if data == df['homePlay'][i].lower():
                    #Team.append('Centre')
                    Team.append(home_name)
                else:
                    #Team.append(official_opponent_name)
                    Team.append(away_name)
            elif 'assist' in data:
                Type.append('assist')
                if player_added == False:
                    player.append('')
                Outcome.append('')
                points.append('')
                #if isHome(data, df) == '1':
                if data == df['homePlay'][i].lower():
                    #Team.append('Centre')
                    Team.append(home_name)
                else:
                    #Team.append(official_opponent_name)
                    Team.append(away_name)
            elif "2ptr by" in data:
                if player_added == False:
                    player.append('')
                Type.append('two pointer')
                if 'good' in data:
                    Outcome.append('good')
                    points.append('2')
                elif 'miss' in data:
                    Outcome.append('miss')
                    points.append('')
                else:
                    Outcome.append('')
                    points.append('')
                #if isHome(data, df) == '1':
                if data == df['homePlay'][i].lower():
                    Team.append(home_name)
                else:
                    Team.append(away_name)
                
            elif 'foul' in data:
                if player_added == False:
                    player.append('')
                Type.append('foul')
                Outcome.append('')
                points.append('')
                #if isHome(data, df) == '1':
                if data == df['homePlay'][i].lower():
                    Team.append(home_name)
                else:
                    Team.append(away_name)
            elif 'turnover' in data:
                if player_added == False:
                    player.append('')
                Type.append('turnover')
                Outcome.append('')
                points.append('')
                #if isHome(data, df) == '1':
                if data == df['homePlay'][i].lower():
                    Team.append(home_name)
                else:
                    Team.append(away_name)
            
            elif 'jumper' in data:
                if player_added == False:
                    player.append('')
                Type.append('jumper')
                Outcome.append('')
                points.append('')
                #if isHome(data, df) == '1':
                if data == df['homePlay'][i].lower():
                    Team.append(home_name)
                else:
                    Team.append(away_name)
            elif 'steal ' in data:
                if player_added == False:
                    player.append('')
                Type.append('steal')
                Outcome.append('')
                points.append('')
                #if isHome(data, df) == '1':
                if data == df['homePlay'][i].lower():
                    Team.append(home_name)
                else:
                    Team.append(away_name)
            elif 'rebound' in data:
                if player_added == False:
                    player.append('')
                Outcome.append('')
                points.append('')
                if 'def by' in data:
                    Type.append('defensive rebound')
                elif 'deadb by' in data:
                    Type.append('deadball rebound')
                    
                elif 'off by' in data:
                    Type.append('offensive rebound')
                    
                else:
                    Type.append('')


                #if isHome(data, df) == '1':
                if data == df['homePlay'][i].lower():
                    Team.append(home_name)
                else:
                    Team.append(away_name)
                    
            elif 'sub' in data:
                # Determine which side this sub event belongs to. The
                # robust signal: the actor's team membership in the current
                # lineup state. Old code used the homePlay/awayPlay
                # heuristic which fails when the scraper crams both teams'
                # subs into one column.
                #
                # NOTE: the old skip_line cascade is intentionally NOT used
                # here. A sub event that doesn't apply (SUB IN of a player
                # already in the lineup, SUB OUT of a player not in the
                # lineup) is silently no-op'd rather than poisoning the
                # NEXT sub. The previous behaviour set skip_line=1 and
                # waited for any subsequent sub to absorb the skip — but
                # if a non-sub event (foul, timeout, etc.) intervened, the
                # skip persisted through to a later, unrelated sub and
                # blanked the lineup state for the rest of the game.
                pn_norm = _normalize_player_key(player_name)
                home_norms = {_normalize_player_key(x): x for x in home_lineup}
                away_norms = {_normalize_player_key(x): x for x in away_lineup}
                hp_raw = df["homePlay"][i]
                ap_raw = df["awayPlay"][i]
                hp_lc = hp_raw.lower() if isinstance(hp_raw, str) else ""
                ap_lc = ap_raw.lower() if isinstance(ap_raw, str) else ""
                is_home_event = (data == hp_lc) and hp_lc
                is_away_event = (data == ap_lc) and ap_lc
                if 'out' in data:
                    Type.append("subbing out")
                    if pn_norm in home_norms or pn_norm in away_norms:
                        if is_home_event and pn_norm in home_norms:
                            home_lineup.remove(home_norms[pn_norm])
                        elif is_away_event and pn_norm in away_norms:
                            away_lineup.remove(away_norms[pn_norm])
                        elif pn_norm in home_norms:
                            home_lineup.remove(home_norms[pn_norm])
                        elif pn_norm in away_norms:
                            away_lineup.remove(away_norms[pn_norm])
                    # else: silently no-op — player not in any lineup;
                    # do not skip the next sub.
                elif "in" in data:
                    Type.append("subbing in")
                    if pn_norm not in home_norms and pn_norm not in away_norms:
                        # Decide which side this SUB IN belongs to.
                        if is_home_event:
                            target = 'home'
                        elif is_away_event:
                            target = 'away'
                        elif len(home_lineup) < 5 and len(away_lineup) >= 5:
                            target = 'home'
                        elif len(away_lineup) < 5 and len(home_lineup) >= 5:
                            target = 'away'
                        else:
                            target = 'away'
                        # Overflow-guard. If the target lineup is already at
                        # 5, a previous SUB OUT for this side silently
                        # no-op'd (the player wasn't found in the parser's
                        # state). The new SUB IN is legitimate, so drop the
                        # oldest entry to keep the lineup at 5 rather than
                        # blow past it and blank every subsequent snapshot.
                        target_lineup = home_lineup if target == 'home' else away_lineup
                        if len(target_lineup) >= 5:
                            target_lineup.pop(0)
                        target_lineup.append(player_name)
                    # else: silently no-op — player already on the floor.
                    
                    
                elif 'starter' in data:
                    Type.append('starter')
                Outcome.append('')
                points.append('')
                if player_added == False:
                    player.append('')
                #if isHome(data, df) == '1':
                if data == df['homePlay'][i].lower():
                    Team.append(home_name)
                else:
                    Team.append(away_name)
            elif 'block' in data:
                Type.append('block')
                Outcome.append('')
                points.append('')
                if player_added == False:
                    player.append('')
                #if isHome(data, df) == '1':
                if data == df['homePlay'][i].lower():
                    Team.append(home_name)
                else:
                    Team.append(away_name)
            elif 'timeout' in data:
                Type.append('timeout')
                Outcome.append('')
                points.append('')
                if player_added == False:
                    player.append('')
                #if isHome(data, df) == '1':
                if data == df['homePlay'][i].lower():
                    Team.append(home_name)
                else:
                    Team.append(away_name)
            else:
                # Generic "MISS  by X" with no shot-type word, or any other
                # play the type-of_plays list doesn't match. Still assign
                # Team using the homePlay/awayPlay split so downstream
                # assign_teams() doesn't see an empty teamName[0] (which
                # would leave team1 undefined and crash on lookup). Also
                # classify generic misses as 'shot' so score reconciliation
                # works — score_delta confirmation kicks in for the actual
                # made/miss outcome.
                hp_raw = df['homePlay'][i] if i < len(df) else ''
                ap_raw = df['awayPlay'][i] if i < len(df) else ''
                hp_lc  = hp_raw.lower() if isinstance(hp_raw, str) else ''
                ap_lc  = ap_raw.lower() if isinstance(ap_raw, str) else ''
                if data and 'miss' in data and 'by' in data:
                    Type.append('shot')
                    Outcome.append('missed')
                else:
                    Type.append('')
                    Outcome.append('')
                points.append('')
                if data == hp_lc and hp_lc:
                    Team.append(home_name)
                elif data == ap_lc and ap_lc:
                    Team.append(away_name)
                else:
                    # Fall back to whichever side has a non-empty play cell.
                    if hp_lc and not ap_lc:
                        Team.append(home_name)
                    elif ap_lc and not hp_lc:
                        Team.append(away_name)
                    else:
                        # Last resort — default to away (the original
                        # behaviour); _correct_team_from_score_deltas will
                        # repair it from the running score later.
                        Team.append(away_name)
                if player_added == False:
                    player.append('')
            i+=1
            #print(away_lineup)
            l_away_lineup.append(away_lineup.copy())
            l_home_lineup.append(home_lineup.copy())
            
            
        
        
        if len(Type) == 0:
            print("Skipping empty game:", header_file)
            continue

        #EDIT!!!!!!!!!!!!

        df['playType'] = Type
        print("len of play type", len(Type))
        df['shotOutcome'] = Outcome
        #print(Outcome, Team)
        df['Team']= Team
        df['Player'] = player
        df['pointsEarned'] = points
        df["awayLineup"] = l_away_lineup
        df["homeLineup"] = l_home_lineup
        time_in_secs = []
        for time in df['timeRemaining']:
        #for time in df['Time Remaining']:
            if time != '--' and 'Start' not in time:
                minutes = int(time.split(':')[0])
                seconds = int(time.split(':')[1])
                total_seconds = minutes * 60 + seconds
                time_in_secs.append(total_seconds)
                    
            else:
                time_in_secs.append('')
        df['timeSeconds'] = time_in_secs




        ## BEGIN POSSESSION DATA
        playDescription = df['Play'].tolist()


        playOutcome = list(zip(Type,Team,time_in_secs))   
        limit = len(playOutcome) - 2
        possessionChange = []
        possessionCentre = []
        possessionClock = []
        possessionOpp = []
        
        p_tracker = [] # An empty list passed through that eventually tracks possession
        p_track_number = [] # An empty list passed through that eventually tracks possession number
        ppp_home = [] # An empty list that eventually tracks points scored during a whole possession
        ppp_away= [] # Same thing but for the away side
        
        p_track_time = []
        extraData = ['timeout', 'foul', 'deadball rebound', 'free throw', 'offensive rebound']
        change = ['defensive rebound', 'steal']
        possessionChange.append(np.nan)
        possessionClock.append(np.nan)
        #a is year check


        b_check_year = year_check(year_str)

        # Classify every row into a play category (made shot, turnover, foul, etc.)
        d_play_type = classification(playDescription, Type, points, Team, b_check_year)

        # d_copy is passed separately so possession_tracker can mutate d_play_type
        # (it relabels some fouls as offensive/defensive) while classification() output is preserved.
        d_copy = d_play_type.copy()
        possession_tracker(d_play_type, Team, d_copy, p_tracker, b_check_year, boxscore)

        possession_points(points, p_track_number, p_tracker, d_copy, ppp_home, ppp_away)
        for i in range(0, len(ppp_away)):
            ppp_away[i] = float(ppp_away[i])


        df['Poss'] = p_tracker
        df['possNum'] = p_track_number


        if len(ppp_home) != len(ppp_away):
            ppp_home.append(0)
        df['pppHome'] = ppp_home
        df['pppAway'] = ppp_away
        #print(ppp_home)
        i_num, play_of_poss = 1, [1]
        for i in range(1, len(p_track_number)):
            if p_track_number[i] == i_num:
                play_of_poss.append(0)
            else:
                play_of_poss.append(1)
                i_num += 1
       
        df["PlayOfPoss"] = play_of_poss
        homePlays = df['homePlay']
        awayPlays = df['awayPlay']
        plays = df['Play']
        period = df['Period']
        p_1 = posschange(homePlays, awayPlays, plays, period, Team)
        p_2 = assign_teams(p_1, boxscore, Team)
        # possTeam: name of the team currently holding possession
        df["possTeam"] = p_2
        # NOW mark the first row of each period as a possession start.
        # This step has to come AFTER assign_teams because it doesn't shift
        # who has the ball — it just credits the first row of each period
        # with the +1 possession count it deserves.
        p_1 = _mark_period_starts(p_1, period)
        # possStart: 1 on the row where a new possession begins, 0 otherwise
        df["possStart"] = p_1

        p_3 = calculate_possession_points(points, p_1)
        # possPoints: total points produced by that possession
        df["possPoints"] = p_3

        p_4 = calculate_possession_numbers(p_1)
        # possSequence: running count of possessions across the game
        df["possSequence"] = p_4
        p_5 = team_change_indicator(p_2)
        # teamChanged: 1 on the last row before possession switches to the other team
        df["teamChanged"] = p_5
        df["game"]=df["homeTeam"]+df["awayTeam"]+df["gameDate"]
        
        p_6=assist_ind(homePlays, awayPlays, plays, period,Team)
        
        df["ASSIST"]=p_6
        # Make a column for each player in the lineup
        p_7=oreb_ind(homePlays,awayPlays,plays,period,Team)
        
        df["OREB"]=p_7
        
        p_8=defreb_ind(homePlays,awayPlays,plays,period,Team)
        df["DREB"]=p_8
        
        
        p_9 = calculate_possession_times(time_in_secs, p_5)
        # secondsPerPoss: time in seconds consumed by each possession
        df["secondsPerPoss"] = p_9

        # Phantom-row hygiene — see helper comments above the function
        # definitions for the full story. In short:
        #   * zero out possStart/teamChanged/possPoints on box-score-summary
        #     rows so they don't form a duplicate possession sequence;
        #   * copy each phantom assist/rebound row's lineup from the
        #     matching real play row so OREB / DREB / ASSIST attribution
        #     reflects the lineup that was actually on the floor.
        df = _zero_phantom_possession_flags(df)
        df = _reattribute_phantom_lineups(df)
        # Repair Team mis-attribution using the per-row score columns as
        # ground truth — see _correct_team_from_score_deltas() comment for
        # the failure modes this fixes (monotone-Team 2018-19 exports, and
        # "GOOD 2PTR by X" plays whose Player wasn't extracted).
        df = _correct_team_from_score_deltas(df, home_name, away_name)
        # Self-heal lineups whose 5th slot was stranded by a mis-labeled
        # sub event (e.g. Centre vs Asbury 2025-26 at 03:47 — `SUB OUT by
        # INGRAM,DRAKE` followed by `SUB IN by SHENE,RYAN` when Shene was
        # already on the floor). The play stream's subsequent on-court
        # actions identify the actual 5th player; we slot them in.
        df = _heal_lineups_from_play_stream(
            df, home_name, away_name,
            home_roster=home_roster, away_roster=away_roster)

        df = expandColumn(df)
        



        pbp_file = str(pbp_dir / header_file.replace('header', 'pbp'))
        df.to_csv(pbp_file)

        json_file = pbp_file.replace('.csv', '.json')
        df.to_json(json_file, orient='records', indent=2, date_format='iso',
                   default_handler=str, force_ascii=False)
        
    

def main(schools, sports, start_year, end_year):
    logging.basicConfig(level=logging.WARNING, format='%(levelname)s: %(message)s')

    for sport in sports: 
        for school in schools:
            year = start_year
            while year <= end_year:
                year_str = str(year) + '-' + str(year-2000+1)
                makeHeaderPBP(sport, school, year_str)
                #possession(sport, school, year_str)
                year += 1
    #print(sports)

    
if __name__ == "__main__":
    main(schools, sports, start_year, end_year)

