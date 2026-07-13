"""
Utility functions for scraping basketball box scores off Sidearm-hosted game pages.
The HTML layout shifted somewhat starting in 2022-23, so several functions here handle
both the newer and older table formats.
"""

import logging
import re
from typing import Optional, Tuple, List

from bs4 import BeautifulSoup, Tag

logger = logging.getLogger(__name__)

# HTML structure constants
BOXSCORE_SECTION_ID = 'box-score'
BOXSCORE_GRAPHIC_CLASS = 'box-score-graphic'
TEAM_AWAY_CLASS = 'team away'
TEAM_HOME_CLASS = 'team home'
PLAYER_TABLE_CLASS = 'sidearm-table overall-stats full hide-caption highlight-hover highlight-column-hover'

# Names to skip when building starter lineup (e.g., "Team" as 6th entry)
STARTER_SKIP_NAMES = {'team', 'team rebound'}


def _strip_jersey(name: str) -> str:
    """Strip jersey-number tokens that some box-score tables embed in the
    player name. Two forms appear in real data:
      - leading "<digits>," before the actual name: "3,moore,chez" -> "moore,chez"
      - trailing ",<digits>" after the actual name: "gardner,2"   -> "gardner"
    Without this, plays by "MOORE,CHEZ" can't match a starter row of
    "3,moore,chez", which causes the sub-event matcher in
    getbasketballclean.py to silently corrupt the lineup state on every sub
    — leaving downstream tools to see "None" placeholders for most plays in
    games like the 2023-24 Huntingdon and LaGrange box scores.
    """
    name = re.sub(r'^\d+,', '', name)   # leading jersey
    name = re.sub(r',\d+$', '', name)   # trailing jersey
    return name


def _normalize_starter_name(name: str) -> str:
    """Normalize player name to 'lastname,firstname' format."""
    name = name.strip().lower()
    if not name:
        return ''
    if ',' in name:
        name = name.replace(', ', ',').replace(' ', ',')
        return _strip_jersey(name)
    parts = name.split()
    if len(parts) >= 2:
        return _strip_jersey(parts[-1] + ',' + parts[0])
    return _strip_jersey(name)


def _extract_name_from_td(td_cell: Tag) -> str:
    """Extract player name from td, stripping jersey number prefix (e.g. '00 Name' -> 'Name')."""
    text = td_cell.get_text(separator=' ', strip=True)
    if len(text) >= 2 and text[1] in '0123456789':
        text = text[2:].lstrip()
    return text


def parse_starters(player_table: Tag) -> List[str]:
    """
    Pull the five starter names from a player stats table.
    Two HTML layouts exist: in the newer format (2022-23 onward) the asterisk
    sits in td[2] with the name in td[1]; in older games the asterisk is in td[1]
    and the name lives in a <th> element. Both are handled here.
    'Team' rows that occasionally appear as a sixth entry are skipped.
    """
    if player_table is None:
        return []

    lineup = []
    rows = player_table.find_all('tr')[1:]  # skip header

    for tr in rows:
        tds = tr.find_all('td')
        th = tr.find('th', scope='row')

        # Newer format: td[2] = *, name in td[1]
        if len(tds) >= 3 and tds[2].get_text(strip=True) == '*':
            raw_name = _extract_name_from_td(tds[1])
            if not raw_name:
                continue
            if raw_name.lower() in STARTER_SKIP_NAMES:
                continue
            lineup.append(_normalize_starter_name(raw_name))
            continue

        # Older format: td[1] = *, name in th (may include jersey number prefix)
        if len(tds) >= 2 and tds[1].get_text(strip=True) == '*' and th:
            raw_name = th.get_text(separator=' ', strip=True).lower()
            # Strip leading jersey number (e.g. "11 Taylen Alexander" -> "taylen alexander")
            raw_name = re.sub(r'^\d+\s+', '', raw_name)
            if not raw_name:
                continue
            if raw_name in STARTER_SKIP_NAMES:
                continue
            try:
                if ',' in raw_name:
                    # "Last, First" -> normalize to "last,first"
                    candidate = raw_name.replace(', ', ',').strip()
                    lineup.append(_strip_jersey(candidate))
                else:
                    # "First Last" or "First Middle Last" -> "last,first"
                    parts = raw_name.split()
                    if len(parts) >= 2:
                        lineup.append(_strip_jersey(parts[-1] + ',' + parts[0]))
                    else:
                        lineup.append(_strip_jersey(raw_name))
            except (IndexError, AttributeError):
                continue

    return lineup


def parse_team_names_from_boxscore(boxscore: Tag) -> Optional[Tuple[str, str]]:
    """
    Extract (away_name, home_name) from a box score Tag.
    Use when you already have the box-score section.
    """
    if boxscore is None:
        return None
    graphic = boxscore.find('div', {'class': BOXSCORE_GRAPHIC_CLASS})
    container = graphic if graphic is not None else boxscore

    away_div = container.find('div', {'class': TEAM_AWAY_CLASS})
    home_div = container.find('div', {'class': TEAM_HOME_CLASS})

    if away_div is None or home_div is None:
        logger.warning("Team away/home divs not found in box score")
        return None

    away_img = away_div.find('img')
    home_img = home_div.find('img')

    if away_img is None or home_img is None:
        logger.warning("Team logo img not found")
        return None

    away_alt = away_img.attrs.get('alt', '')
    home_alt = home_img.attrs.get('alt', '')

    away_name = away_alt.replace('logo', '').strip().lower()
    home_name = home_alt.replace('logo', '').strip().lower()

    if not away_name or not home_name:
        logger.warning("Empty team names extracted")
        return None

    return away_name, home_name


def parse_team_names(soup: BeautifulSoup) -> Optional[Tuple[str, str]]:
    """
    Extract (away_name, home_name) from full page soup.
    Tries box-score-graphic first; falls back to box-score section.
    Returns None if structure is invalid.
    """
    boxscore = soup.find('section', {'id': BOXSCORE_SECTION_ID})
    if boxscore is None:
        logger.warning("Box score section not found")
        return None
    return parse_team_names_from_boxscore(boxscore)


def find_player_tables(soup: BeautifulSoup) -> Optional[Tuple[Tag, Tag]]:
    """
    Find away and home player stats tables.
    Returns (away_table, home_table) or None if structure invalid.
    """
    tables = soup.find_all('table', {'class': PLAYER_TABLE_CLASS})
    if len(tables) < 2:
        logger.warning("Expected at least 2 player tables, got %d", len(tables))
        return None
    return tables[0], tables[1]


def parse_player_roster(player_table: Tag) -> List[dict]:
    """Extract every player who appeared in the player stats table, with
    minutes played and a starter flag. Used downstream as ground truth for
    the team's roster — when the play-by-play loop's lineup state has a
    missing 5th player and no on-court action reveals their identity, we
    fall back to this roster and the recorded minutes to identify the most
    likely candidate.

    Returns a list of {'name': 'last,first', 'minutes': int, 'is_starter': bool}.
    Players with 0 or missing minutes (DNP) are still returned so callers can
    skip them explicitly. Robust to both Sidearm HTML layouts:
      - newer (2022-23+): name in td[1], starter '*' in td[2], MIN in td[3]
      - older:            name in th,    starter '*' in td[1], MIN in td[2]
    Falls back to a 'TEAM' row skip mirrored from parse_starters().
    """
    if player_table is None:
        return []

    out: List[dict] = []
    rows = player_table.find_all('tr')[1:]   # skip header

    # Detect format by inspecting the first data row.
    # Newer format has the starter '*' in td[2]; older has it in td[1].
    for tr in rows:
        tds = tr.find_all('td')
        th  = tr.find('th', scope='row')
        name = None
        minutes = 0
        is_starter = False

        # Newer format
        if len(tds) >= 4:
            star_cell = tds[2].get_text(strip=True)
            if star_cell in ('*', ''):
                is_starter = (star_cell == '*')
                raw_name = _extract_name_from_td(tds[1])
                if raw_name and raw_name.lower() not in STARTER_SKIP_NAMES:
                    name = _normalize_starter_name(raw_name)
                    min_text = tds[3].get_text(strip=True)
                    try:
                        minutes = int(re.sub(r'[^\d]', '', min_text) or '0')
                    except ValueError:
                        minutes = 0

        # Older format (only if we didn't get a name above)
        if name is None and len(tds) >= 3 and th:
            star_cell = tds[1].get_text(strip=True)
            is_starter = (star_cell == '*')
            raw_name = th.get_text(separator=' ', strip=True).lower()
            raw_name = re.sub(r'^\d+\s+', '', raw_name)
            if raw_name and raw_name not in STARTER_SKIP_NAMES:
                try:
                    if ',' in raw_name:
                        candidate = raw_name.replace(', ', ',').strip()
                        name = _strip_jersey(candidate)
                    else:
                        parts = raw_name.split()
                        if len(parts) >= 2:
                            name = _strip_jersey(parts[-1] + ',' + parts[0])
                        else:
                            name = _strip_jersey(raw_name)
                    min_text = tds[2].get_text(strip=True)
                    minutes = int(re.sub(r'[^\d]', '', min_text) or '0')
                except (IndexError, AttributeError, ValueError):
                    minutes = 0

        if name:
            out.append({'name': name, 'minutes': minutes, 'is_starter': is_starter})
    return out


def validate_game_html(soup: BeautifulSoup) -> Tuple[bool, str]:
    """
    Quick sanity check before we try to parse a game page.
    Returns (True, '') if the page looks usable, or (False, reason) if something
    critical is missing (no box-score section, fewer than 2 player tables, etc.).
    """
    if soup is None:
        return False, "Soup is None"

    boxscore = soup.find('section', {'id': BOXSCORE_SECTION_ID})
    if boxscore is None:
        return False, "Missing section#box-score"

    tables = soup.find_all('table', {'class': PLAYER_TABLE_CLASS})
    if len(tables) < 2:
        return False, f"Expected at least 2 player tables, found {len(tables)}"

    team_names = parse_team_names(soup)
    if team_names is None:
        return False, "Could not extract team names"

    return True, ""
