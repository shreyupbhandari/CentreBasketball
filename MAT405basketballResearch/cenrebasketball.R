library(shiny)
library(ggplot2)
library(grid)        # rasterGrob / circleGrob for logo markers on the scatter
library(tools)
library(shinythemes)
library(DT)
library(stringr)
library(dplyr)
library(shinydashboard)
library(shinyWidgets)
library(htmlwidgets)
library(htmltools)
library(readr)

# Null-coalescing helper. Returns `b` if `a` is NULL.
`%||%` <- function(a, b) if (is.null(a)) b else a

# Vectorized lineup builder — given five name columns plus a side indicator,
# returns a sorted "a, b, c, d, e" string per row, or NA_character_ when the
# selected team isn't on that side. Handles 0-row inputs cleanly (apply on a
# 0-row matrix used to break things).
# Returns a (nrow x 5) character matrix with the selected team's lineup on
# each row (NA rows where the selected team isn't on the floor).
team_lineup_matrix <- function(df, selected_team) {
  if (nrow(df) == 0) {
    return(matrix(character(0), ncol = 5))
  }
  away <- df$awayTeam == selected_team
  home <- df$homeTeam == selected_team
  pick <- function(a_col, h_col) {
    out <- rep(NA_character_, nrow(df))
    out[away] <- df[[a_col]][away]
    out[home] <- df[[h_col]][home]
    out
  }
  cbind(
    pick("awayPlayer1", "homePlayer1"),
    pick("awayPlayer2", "homePlayer2"),
    pick("awayPlayer3", "homePlayer3"),
    pick("awayPlayer4", "homePlayer4"),
    pick("awayPlayer5", "homePlayer5")
  )
}

# Given a lineup matrix and a set of already-picked players, return the set
# of teammates that have shared the floor with ALL picked players at least
# once. When nothing is picked, returns every player on the team.
available_teammates <- function(lineup_mat, picked) {
  if (nrow(lineup_mat) == 0) return(character(0))
  if (length(picked) == 0) {
    return(sort(unique(stats::na.omit(as.vector(lineup_mat)))))
  }
  rows_ok <- apply(lineup_mat, 1, function(row) all(picked %in% row))
  sub <- lineup_mat[rows_ok, , drop = FALSE]
  sort(unique(stats::na.omit(as.vector(sub))))
}

# Per-lineup metric aggregator. Takes a play-by-play data frame that already
# has a CentreLineup column (one canonical lineup string per row, NA on rows
# where the selected team isn't on the floor) plus a selected team string,
# and returns one row per distinct lineup with all the rate stats.
#
# Why a single helper: previously the Player-Tables tab and the Lineups-in-
# Game tab each duplicated this mutate+group_by+summarise block, and they
# drifted (different TIME_SEC formulas, different column subsets). The new
# top-5 tab needs the same numbers as both. One function = one source of
# truth.
#
# Metric definitions:
#   OFFRTG     points / OFFPOSS * 100         (per 100 offensive possessions)
#   DEFRTG     pointsAgainst / DEFPOSS * 100  (lower is better)
#   NETRTG     OFFRTG - DEFRTG
#   OREB_RATE  ORB / (ORB + opponent DRB) * 100        % of available oreb grabbed
#   DREB_RATE  DRB / (DRB + opponent ORB) * 100        % of available dreb grabbed
#   FG_PCT     FGM / FGA * 100                         field goal percentage
#   FG3_PCT    3PM / 3PA * 100                         three-point percentage
#   EFG_PCT    (FGM + 0.5*3PM) / FGA * 100             accounts for 3pt being worth more
#   TOV_PCT    TOV / OFFPOSS * 100                     possession-based TOV% (lower is better)
#   AST_TO     ASSISTS / TOV                           classic ratio
#   AST_RATIO  ASSISTS / OFFPOSS * 100                 (kept for parity with old tab)
#   PACE       TOTAL_POSS / 2 * 40 / (TIME_SEC/60)     possessions per 40 min (D3 game length)
#   TIME_SEC   sum of secondsPerPoss on possStart rows (BOTH sides — was
#              previously only summed on defensive possessions, which
#              undercounted minutes by ~half).
#   TIME_MIN   TIME_SEC / 60
compute_lineup_metrics <- function(df, selected_team) {
  lt <- tolower(selected_team)
  # NOTE: includes tipin and two pointer — both 2-point Sidearm play types
  # that appeared in older feeds (pre-2014 and a handful of 2018-19 games).
  # Excluding them silently dropped ~600 made shots across the dataset.
  shot_types <- c("layup", "jumper", "three pointer", "dunk", "tipin", "two pointer")

  df %>%
    mutate(
      .is_team_poss = possTeam == lt,
      .is_opp_poss  = possTeam != lt,
      .is_team_act  = Team == lt,
      # IMPORTANT: derive points directly from the play stream, not from
      # the Python pipeline's possPoints + teamChanged running tally. That
      # tally is systematically broken — when summed per game it matches
      # the real final score in 0 out of 25 games (mean undercount ~48
      # points). The play stream itself (playType + shotOutcome) matches
      # the real score in 16 of 25 games. The remaining 9 games have
      # upstream scraper data loss that no aggregation can fix.
      .row_pts = case_when(
        is.na(shotOutcome) | shotOutcome != "good"                       ~ 0,
        playType == "three pointer"                                       ~ 3,
        playType %in% c("layup","jumper","dunk","tipin","two pointer")    ~ 2,
        playType == "free throw"                                          ~ 1,
        TRUE                                                              ~ 0
      ),
      pointsEarned  = if_else(coalesce(.is_team_act, FALSE), .row_pts, 0),
      pointsAgainst = if_else(coalesce(!.is_team_act & !is.na(Team) & Team != "", FALSE),
                              .row_pts, 0),
      off_poss = if_else(.is_team_poss & possStart == 1, possStart, 0),
      def_poss = if_else(.is_opp_poss  & possStart == 1, possStart, 0),
      # Time on court: clock delta derived in load_pbp(). Every row carries
      # the time since the previous surviving row, so summing gives the
      # lineup's full minutes-on-court regardless of which side had the ball.
      time_sec_row = elapsed_sec,
      assists_row  = if_else(.is_team_poss, ASSIST, 0),
      oreb_row     = if_else(.is_team_poss, OREB,   0),
      dreb_row     = if_else(.is_team_poss, DREB,   0),
      op_oreb_row  = if_else(.is_opp_poss,  OREB,   0),
      op_dreb_row  = if_else(.is_opp_poss,  DREB,   0),
      fga_row  = as.integer(.is_team_act & playType %in% shot_types),
      fgm_row  = as.integer(.is_team_act & playType %in% shot_types & shotOutcome == "good"),
      fg3a_row = as.integer(.is_team_act & playType == "three pointer"),
      fg3m_row = as.integer(.is_team_act & playType == "three pointer" & shotOutcome == "good"),
      tov_row  = as.integer(.is_team_act & playType == "turnover")
    ) %>%
    group_by(CentreLineup) %>%
    summarise(
      pointsEarned  = sum(pointsEarned,  na.rm = TRUE),
      pointsAgainst = sum(pointsAgainst, na.rm = TRUE),
      OFFPOSS    = sum(off_poss, na.rm = TRUE),
      DEFPOSS    = sum(def_poss, na.rm = TRUE),
      TOTAL_POSS = OFFPOSS + DEFPOSS,
      OFFRTG     = round(pointsEarned  / OFFPOSS * 100, 1),
      DEFRTG     = round(pointsAgainst / DEFPOSS * 100, 1),
      NETRTG     = round(OFFRTG - DEFRTG, 1),
      plus_minus = pointsEarned - pointsAgainst,
      ASSISTS    = sum(assists_row, na.rm = TRUE),
      AST_RATIO  = round(ASSISTS / OFFPOSS * 100, 1),
      OFFREB     = sum(oreb_row, na.rm = TRUE),
      DEFREB     = sum(dreb_row, na.rm = TRUE),
      opp_OFFREB = sum(op_oreb_row, na.rm = TRUE),
      opp_DEFREB = sum(op_dreb_row, na.rm = TRUE),
      OREB_RATE  = round(OFFREB / (OFFREB + opp_DEFREB) * 100, 1),
      DREB_RATE  = round(DEFREB / (DEFREB + opp_OFFREB) * 100, 1),
      FGA  = sum(fga_row,  na.rm = TRUE),
      FGM  = sum(fgm_row,  na.rm = TRUE),
      FG3A = sum(fg3a_row, na.rm = TRUE),
      FG3M = sum(fg3m_row, na.rm = TRUE),
      TOV  = sum(tov_row,  na.rm = TRUE),
      FG_PCT  = round(FGM  / FGA  * 100, 1),
      FG3_PCT = round(FG3M / FG3A * 100, 1),
      EFG_PCT = round((FGM + 0.5 * FG3M) / FGA * 100, 1),
      TOV_PCT = round(TOV / OFFPOSS * 100, 1),
      AST_TO  = round(ASSISTS / TOV, 2),
      TIME_SEC = sum(time_sec_row, na.rm = TRUE),
      TIME_MIN = round(TIME_SEC / 60, 1),
      # Pace per 40 minutes (D3 men's game length): average possessions per
      # side scaled to a 40-min game.
      PACE = round(TOTAL_POSS / 2 * 40 / (TIME_SEC / 60), 1),
      .groups = "drop"
    ) %>%
    # Clean any NaN / Inf from divisions by zero so sorts / displays behave.
    mutate(across(
      c(OFFRTG, DEFRTG, NETRTG, AST_RATIO,
        OREB_RATE, DREB_RATE,
        FG_PCT, FG3_PCT, EFG_PCT, TOV_PCT,
        AST_TO, PACE),
      ~ if_else(is.finite(.x), .x, NA_real_)
    ))
}

# Expand a play-by-play frame with a CentreLineup column (5-man lineup
# string per row) into a longer frame with one row per N-player SUBGROUP
# of that lineup. Feeding the result into compute_lineup_metrics() then
# yields one aggregated row per distinct N-player group, pooled across
# every 5-man lineup that contained it.
#
# For N=3 each original row expands to C(5,3)=10 rows, each tagged with
# one sorted 3-player subgroup string. Used by the Player Combination tab.
expand_to_subgroups <- function(df, group_size) {
  if (nrow(df) == 0 || !"CentreLineup" %in% names(df)) {
    return(df[0, , drop = FALSE])
  }
  df <- df[!is.na(df$CentreLineup) & df$CentreLineup != "", , drop = FALSE]
  if (nrow(df) == 0) return(df)

  members_list <- strsplit(df$CentreLineup, ", ", fixed = TRUE)
  per_row_subs <- lapply(members_list, function(m) {
    if (length(m) < group_size) return(character(0))
    combos <- combn(m, group_size, simplify = FALSE)
    vapply(combos, function(x) paste(sort(x), collapse = ", "), character(1))
  })
  n_per_row <- vapply(per_row_subs, length, integer(1))
  row_idx <- rep(seq_len(nrow(df)), times = n_per_row)
  out <- df[row_idx, , drop = FALSE]
  out$CentreLineup <- unlist(per_row_subs, use.names = FALSE)
  out
}

# Per (N-player subgroup x full 5-man lineup) aggregator that credits ACTION
# stats only to the subgroup members — not to the rest of the lineup.
#
# For every play row, expand into all C(5, N) subgroups of the on-court
# lineup, then for each (subgroup, lineup) pair:
#   - ACTION stats (FG, 3PT, TOV, ASSISTS, OREB, DREB, points scored) count
#     ONLY when the row's actor (Player column) is one of the N subgroup
#     members — i.e. only what the subgroup itself did, not what their
#     5-man-lineup teammates did.
#   - LINEUP-LEVEL stats (possessions, time, opponent rebounds, opponent
#     points) are NOT gated — the subgroup was on the floor for everything
#     the lineup was on the floor for.
#
# Hybrid rates use the subgroup numerator over the lineup denominator:
#   OFFRTG = subgroup points / lineup OFFPOSS * 100
#          = "subgroup's points scored per 100 lineup-offensive-possessions"
#   TOV_PCT, AST_RATIO, OREB_RATE, DREB_RATE follow the same pattern.
# DEFRTG / pointsAgainst remain lineup-level (defense isn't cleanly
# attributable to specific players in the source data).
compute_subgroup_in_lineup_metrics <- function(df, selected_team, n) {
  lt <- tolower(selected_team)
  shot_types <- c("layup", "jumper", "three pointer", "dunk", "tipin", "two pointer")

  df <- df[!is.na(df$CentreLineup) & df$CentreLineup != "", , drop = FALSE]
  if (nrow(df) == 0) return(NULL)

  # Build the (subgroup, row) expansion.
  #
  # PERFORMANCE: compute the C(5, n) subgroups once per UNIQUE lineup
  # string (a few hundred per season), not once per row (tens of
  # thousands). The old per-row loop also grew its accumulator with
  # c(flat_combos, combos), which re-copies the whole list on every
  # append — quadratic time. Together those made the Player Combination
  # tab take ~9 s per recompute; this formulation runs in ~0.2 s.
  lineup_levels <- unique(df$CentreLineup)
  combos_by_lineup <- lapply(
    strsplit(lineup_levels, ", ", fixed = TRUE),
    function(m) {
      if (length(m) < n) return(character(0))
      combos <- combn(m, n, simplify = FALSE)
      vapply(combos, function(x) paste(sort(x), collapse = ", "), character(1))
    }
  )
  lineup_idx <- match(df$CentreLineup, lineup_levels)
  k_per_row  <- lengths(combos_by_lineup)[lineup_idx]
  if (sum(k_per_row) == 0) return(NULL)

  origin_idx <- rep(seq_len(nrow(df)), times = k_per_row)
  df_exp <- df[origin_idx, , drop = FALSE]
  df_exp$Group  <- unlist(combos_by_lineup[lineup_idx], use.names = FALSE)
  df_exp$Lineup <- df_exp$CentreLineup

  # The "is the row's actor a member of THIS subgroup?" flag, vectorized:
  # the actor is a member iff ", <player>, " appears in the padded
  # subgroup string. Names are full tokens between ", " separators, so
  # padding both sides makes the match exact — "wahl,nolan" can't hit
  # inside "wahl,nolanson".
  df_exp$.in_sub <- !is.na(df_exp$Player) & df_exp$Player != "" &
    stringr::str_detect(paste0(", ", df_exp$Group, ", "),
                        stringr::fixed(paste0(", ", df_exp$Player, ", ")))

  df_exp %>%
    mutate(
      .row_pts = case_when(
        is.na(shotOutcome) | shotOutcome != "good"                       ~ 0,
        playType == "three pointer"                                       ~ 3,
        playType %in% c("layup","jumper","dunk","tipin","two pointer")    ~ 2,
        playType == "free throw"                                          ~ 1,
        TRUE                                                              ~ 0
      ),
      .is_team_poss = possTeam == lt,
      .is_opp_poss  = possTeam != lt,
      .is_team_act  = coalesce(Team == lt, FALSE),
      # SUBGROUP action stats — gated on subgroup membership.
      sub_pts     = if_else(.in_sub & .is_team_act, .row_pts, 0),
      sub_fga     = if_else(.in_sub & .is_team_act & playType %in% shot_types, 1L, 0L),
      sub_fgm     = if_else(.in_sub & .is_team_act & playType %in% shot_types & shotOutcome == "good", 1L, 0L),
      sub_fg3a    = if_else(.in_sub & .is_team_act & playType == "three pointer", 1L, 0L),
      sub_fg3m    = if_else(.in_sub & .is_team_act & playType == "three pointer" & shotOutcome == "good", 1L, 0L),
      sub_tov     = if_else(.in_sub & .is_team_act & playType == "turnover", 1L, 0L),
      sub_assists = if_else(.in_sub & .is_team_poss, ASSIST, 0),
      sub_oreb    = if_else(.in_sub & .is_team_poss, OREB,   0),
      sub_dreb    = if_else(.in_sub & .is_team_poss, DREB,   0),
      # LINEUP-LEVEL stats — not gated by subgroup.
      lin_off         = if_else(.is_team_poss & possStart == 1, 1L, 0L),
      lin_def         = if_else(.is_opp_poss  & possStart == 1, 1L, 0L),
      lin_time        = elapsed_sec,
      lin_pts_against = if_else(.is_opp_poss & teamChanged == 1, possPoints, 0),
      lin_oreb        = if_else(.is_team_poss, OREB, 0),
      lin_dreb        = if_else(.is_team_poss, DREB, 0),
      lin_opp_oreb    = if_else(.is_opp_poss,  OREB, 0),
      lin_opp_dreb    = if_else(.is_opp_poss,  DREB, 0)
    ) %>%
    group_by(Group, Lineup) %>%
    summarise(
      pointsEarned  = sum(sub_pts,         na.rm = TRUE),
      pointsAgainst = sum(lin_pts_against, na.rm = TRUE),
      OFFPOSS    = sum(lin_off, na.rm = TRUE),
      DEFPOSS    = sum(lin_def, na.rm = TRUE),
      TOTAL_POSS = OFFPOSS + DEFPOSS,
      FGA  = sum(sub_fga,  na.rm = TRUE),
      FGM  = sum(sub_fgm,  na.rm = TRUE),
      FG3A = sum(sub_fg3a, na.rm = TRUE),
      FG3M = sum(sub_fg3m, na.rm = TRUE),
      TOV  = sum(sub_tov,  na.rm = TRUE),
      ASSISTS    = sum(sub_assists, na.rm = TRUE),
      OFFREB     = sum(sub_oreb, na.rm = TRUE),
      DEFREB     = sum(sub_dreb, na.rm = TRUE),
      lin_OFFREB = sum(lin_oreb, na.rm = TRUE),
      lin_DEFREB = sum(lin_dreb, na.rm = TRUE),
      opp_OFFREB = sum(lin_opp_oreb, na.rm = TRUE),
      opp_DEFREB = sum(lin_opp_dreb, na.rm = TRUE),
      TIME_SEC   = sum(lin_time, na.rm = TRUE),
      .groups = "drop"
    ) %>%
    mutate(
      TIME_MIN = round(TIME_SEC / 60, 1),
      OFFRTG = round(pointsEarned  / OFFPOSS * 100, 1),  # subgroup pts / lineup off poss
      DEFRTG = round(pointsAgainst / DEFPOSS * 100, 1),  # lineup-level
      NETRTG = round(OFFRTG - DEFRTG, 1),
      plus_minus = pointsEarned - pointsAgainst,
      FG_PCT  = round(FGM  / FGA  * 100, 1),
      FG3_PCT = round(FG3M / FG3A * 100, 1),
      EFG_PCT = round((FGM + 0.5 * FG3M) / FGA * 100, 1),
      TOV_PCT = round(TOV / OFFPOSS * 100, 1),
      AST_TO  = round(ASSISTS / TOV, 2),
      AST_RATIO = round(ASSISTS / OFFPOSS * 100, 1),
      # Subgroup's share of available OREB / DREB chances while on floor.
      OREB_RATE = round(OFFREB / (lin_OFFREB + opp_DEFREB) * 100, 1),
      DREB_RATE = round(DEFREB / (lin_DEFREB + opp_OFFREB) * 100, 1),
      PACE = round(TOTAL_POSS / 2 * 40 / (TIME_SEC / 60), 1)
    ) %>%
    mutate(across(
      c(OFFRTG, DEFRTG, NETRTG, AST_RATIO,
        OREB_RATE, DREB_RATE,
        FG_PCT, FG3_PCT, EFG_PCT, TOV_PCT,
        AST_TO, PACE),
      ~ if_else(is.finite(.x), .x, NA_real_)
    ))
}

# Pool the per-(subgroup, lineup) output produced by
# compute_subgroup_in_lineup_metrics() across every lineup each subgroup
# appeared in, so there's ONE row per N-player group. Action stats are
# still gated on subgroup membership (the per-lineup helper already did
# that); we just sum the raw counts across lineups and re-derive the rate
# stats from the totals. The result tells you the subgroup's overall
# action footprint, with possessions and time aggregated to the subgroup's
# total floor presence.
compute_subgroup_pooled_metrics <- function(df, selected_team, n) {
  per_lineup <- compute_subgroup_in_lineup_metrics(df, selected_team, n)
  if (is.null(per_lineup) || nrow(per_lineup) == 0) return(NULL)

  per_lineup %>%
    group_by(Group) %>%
    summarise(
      pointsEarned  = sum(pointsEarned,  na.rm = TRUE),
      pointsAgainst = sum(pointsAgainst, na.rm = TRUE),
      OFFPOSS    = sum(OFFPOSS, na.rm = TRUE),
      DEFPOSS    = sum(DEFPOSS, na.rm = TRUE),
      TOTAL_POSS = OFFPOSS + DEFPOSS,
      FGA  = sum(FGA,  na.rm = TRUE),
      FGM  = sum(FGM,  na.rm = TRUE),
      FG3A = sum(FG3A, na.rm = TRUE),
      FG3M = sum(FG3M, na.rm = TRUE),
      TOV  = sum(TOV,  na.rm = TRUE),
      ASSISTS    = sum(ASSISTS, na.rm = TRUE),
      OFFREB     = sum(OFFREB,  na.rm = TRUE),
      DEFREB     = sum(DEFREB,  na.rm = TRUE),
      lin_OFFREB = sum(lin_OFFREB, na.rm = TRUE),
      lin_DEFREB = sum(lin_DEFREB, na.rm = TRUE),
      opp_OFFREB = sum(opp_OFFREB, na.rm = TRUE),
      opp_DEFREB = sum(opp_DEFREB, na.rm = TRUE),
      TIME_SEC   = sum(TIME_SEC, na.rm = TRUE),
      n_lineups  = dplyr::n(),  # how many distinct 5-man lineups this subgroup appeared in
      .groups = "drop"
    ) %>%
    mutate(
      TIME_MIN = round(TIME_SEC / 60, 1),
      OFFRTG   = round(pointsEarned  / OFFPOSS * 100, 1),
      DEFRTG   = round(pointsAgainst / DEFPOSS * 100, 1),
      NETRTG   = round(OFFRTG - DEFRTG, 1),
      plus_minus = pointsEarned - pointsAgainst,
      FG_PCT   = round(FGM  / FGA  * 100, 1),
      FG3_PCT  = round(FG3M / FG3A * 100, 1),
      EFG_PCT  = round((FGM + 0.5 * FG3M) / FGA * 100, 1),
      TOV_PCT  = round(TOV / OFFPOSS * 100, 1),
      AST_TO   = round(ASSISTS / TOV, 2),
      AST_RATIO  = round(ASSISTS / OFFPOSS * 100, 1),
      OREB_RATE  = round(OFFREB / (lin_OFFREB + opp_DEFREB) * 100, 1),
      DREB_RATE  = round(DEFREB / (lin_DEFREB + opp_OFFREB) * 100, 1),
      PACE     = round(TOTAL_POSS / 2 * 40 / (TIME_SEC / 60), 1)
    ) %>%
    mutate(across(
      c(OFFRTG, DEFRTG, NETRTG, AST_RATIO,
        OREB_RATE, DREB_RATE,
        FG_PCT, FG3_PCT, EFG_PCT, TOV_PCT,
        AST_TO, PACE),
      ~ if_else(is.finite(.x), .x, NA_real_)
    ))
}

# DataTables column renderer that converts a "lastname,first, lastname,first"
# lineup string into a row of pill-styled spans, one per player. Attached to
# any column whose cells hold a comma-space-separated player list (Lineup,
# Anchors, Others, Group). The pills give each name its own visual atom so
# the column reads as five distinct people, not one comma-glued string.
# `type !== 'display'` short-circuits during sort/filter so DataTables still
# compares against the raw text.
player_pill_renderer <- htmlwidgets::JS(
  "function(data, type, row) {",
  "  if (type !== 'display' || data === null || data === '') return data;",
  "  var parts = String(data).split(', ');",
  "  return parts.map(function(p){",
  "    return '<span class=\"player-pill\">' + p + '</span>';",
  "  }).join('');",
  "}"
)

# Standard column definitions for a lineup-style DataTable: pinned lineup
# column(s) on the left with the gold-accent `lineup-cell` class plus the
# player-pill JS renderer, and every other column right-aligned for clean
# numeric scanning. `lineup_targets` is the 0-based index (or vector of
# indices) of the player-list column(s) — e.g. 0 when CentreLineup is the
# first column, c(1, 2) when Anchors and Others are the second and third.
lineup_column_defs <- function(lineup_targets) {
  c(
    lapply(lineup_targets, function(t) list(
      targets   = t,
      className = "lineup-cell",
      render    = player_pill_renderer
    )),
    list(list(targets = "_all", className = "dt-right"))
  )
}

# ---------------------------------------------------------------------------
# Conditional formatting (cell-background heatmap) for rate metrics.
#
# Each metric gets a three-band scale — POOR (soft red), AVERAGE (no fill),
# GOOD (soft green) — split by two cutpoints. The cutpoints were chosen by
# pooling EVERY meaningful Centre lineup (>= 20 possessions per side) across
# all men's + women's seasons and reading the p25 / p75 of each metric, then
# rounding to clean basketball-meaningful numbers. The data p50s matched
# published D3 norms closely (eFG% median 50.0, TOV% 19.4, DREB% 73.3,
# FG% 43.9, 3P% 35.7), so the bands double as "below average / average /
# above average for a competitive D3 lineup".
#
# For "lower is better" metrics (DEFRTG, TOV_PCT) the scale is inverted so a
# LOW value is green. NA/Inf cells (division by zero on tiny samples) get no
# fill rather than being mis-colored as an extreme.
# Elegant two-channel palette: a very soft tint PLUS a matching darker text
# colour, so the strong cells read as refined coloured numbers rather than
# heavy blocks. The average band gets no fill and inherits the normal text
# colour, keeping wide tables clean. Tints are desaturated (Sheets/Linear
# style) so they sit quietly under the gold-and-black brand chrome.
.CF_GOOD_BG <- "'#E7F4EA'"   # whisper green
.CF_POOR_BG <- "'#FBEBEC'"   # whisper red
.CF_GOOD_TX <- "'#1C7C43'"   # deep green text
.CF_POOR_TX <- "'#B23A2E'"   # deep red text
.CF_NONE    <- "''"          # average — inherit

# Build a JS ternary that maps a cell value to one of three outputs
# (low-band / high-band / middle) using the two cutpoints. `lower_better`
# flips which end is "good". NA/Inf -> '' (no styling). Shared by the
# background-colour and text-colour channels so both use identical bands.
cf_expr <- function(c1, c2, lower_better, good, poor, mid) {
  lo <- if (lower_better) good else poor   # at/below c1
  hi <- if (lower_better) poor else good   # at/above c2
  htmlwidgets::JS(sprintf(
    paste0("value === null || value === '' || isNaN(parseFloat(value)) ? '' : ",
           "(parseFloat(value) <= %s ? %s : ",
           "(parseFloat(value) >= %s ? %s : %s))"),
    c1, lo, c2, hi, mid))
}

# (metric -> c1, c2, lower_better). Only metrics present in a given table
# get styled; raw counts (FGM/FGA/possessions/etc.) are intentionally left
# uncoloured because "more" isn't inherently good or bad for them.
.CF_SPECS <- list(
  OFFRTG     = list(95,  115, FALSE),  # points scored per 100 off. poss
  DEFRTG     = list(90,  105, TRUE),   # points allowed per 100 def. poss
  NETRTG     = list(0,   20,  FALSE),  # OFFRTG - DEFRTG
  plus_minus = list(0,   10,  FALSE),  # raw point differential on floor
  FG_PCT     = list(38,  50,  FALSE),
  FG3_PCT    = list(30,  40,  FALSE),
  EFG_PCT    = list(45,  55,  FALSE),  # 50 = D3 average
  TOV_PCT    = list(15,  22,  TRUE),   # turnovers per 100 off. poss
  AST_TO     = list(0.8, 1.3, FALSE),  # 1.0 = break-even
  AST_RATIO  = list(14,  22,  FALSE),
  OREB_RATE  = list(20,  33,  FALSE),
  DREB_RATE  = list(67,  80,  FALSE)
)

# Apply the heatmap to whichever .CF_SPECS columns exist in `df`. Each styled
# column gets a soft background tint AND a matching darker text colour in a
# single formatStyle pass, with a gentle CSS transition (see .dataTable td
# rule) so re-sorts/filters feel smooth rather than snapping. Call right
# before returning a datatable() from a renderer.
add_conditional_formatting <- function(dt, df) {
  cols <- names(df)
  for (m in names(.CF_SPECS)) {
    if (!m %in% cols) next
    s  <- .CF_SPECS[[m]]
    c1 <- s[[1]]; c2 <- s[[2]]; lb <- s[[3]]
    dt <- DT::formatStyle(
      dt, m,
      backgroundColor = cf_expr(c1, c2, lb, .CF_GOOD_BG, .CF_POOR_BG, .CF_NONE),
      color           = cf_expr(c1, c2, lb, .CF_GOOD_TX, .CF_POOR_TX, .CF_NONE)
    )
  }
  dt
}

# Row mask: TRUE where ALL of `players` are in the row's away lineup OR
# all are in the row's home lineup. Vectorized replacement for the old
# rowwise() + all() filter, which cost ~0.2 s per call on a full season;
# this runs in a few ms. NA lineup slots simply never match (same
# semantics as `p %in% c(...)` against an NA-containing vector).
rows_with_players <- function(df, players) {
  if (length(players) == 0) return(rep(TRUE, nrow(df)))
  away <- cbind(df$awayPlayer1, df$awayPlayer2, df$awayPlayer3,
                df$awayPlayer4, df$awayPlayer5)
  home <- cbind(df$homePlayer1, df$homePlayer2, df$homePlayer3,
                df$homePlayer4, df$homePlayer5)
  in_away <- rep(TRUE, nrow(df))
  in_home <- rep(TRUE, nrow(df))
  for (p in players) {
    in_away <- in_away & (rowSums(away == p, na.rm = TRUE) > 0)
    in_home <- in_home & (rowSums(home == p, na.rm = TRUE) > 0)
  }
  in_away | in_home
}

build_lineup <- function(away_team, home_team, selected_team,
                         a1, a2, a3, a4, a5,
                         h1, h2, h3, h4, h5) {
  n <- length(away_team)
  if (n == 0) return(character(0))
  # Sort + join once per UNIQUE 5-player combination, then map back to
  # rows. A season has ~10k rows but only a few hundred distinct
  # lineups, so this cuts the apply() work by ~30x (0.4 s -> ~0.01 s).
  sort_join_unique <- function(mat) {
    key <- do.call(paste, c(as.data.frame(mat, stringsAsFactors = FALSE),
                            sep = "\x01"))
    first <- !duplicated(key)
    joined <- apply(mat[first, , drop = FALSE], 1,
                    function(x) paste(sort(x), collapse = ", "))
    joined[match(key, key[first])]
  }
  away_str <- sort_join_unique(cbind(a1, a2, a3, a4, a5))
  home_str <- sort_join_unique(cbind(h1, h2, h3, h4, h5))
  out <- rep(NA_character_, n)
  out[away_team == selected_team] <- away_str[away_team == selected_team]
  out[home_team == selected_team] <- home_str[home_team == selected_team]
  out
}


# Conservative team-name normalizer.
#
# Source CSVs come from many different scoreboards/stats providers, each of
# which spells Centre slightly differently: "Centre", "Centre College",
# "Centre College (KY)", "#13 Centre", "Centre Men", "CENTRE_M", "CENTREM",
# "CENTRE-M", "CENTREMB", "CENTRE~1", and lowercase versions of all of the
# above. Left alone, this splits one team's stats across many keys.
#
# Strategy: do only generic, low-risk cleanups (rank prefix, parenthetical
# state, gender code preceded by a separator, DOS 8.3 truncation, " Men"/
# " Women" suffix, title-case single-case strings) — then fold the few
# Centre-specific oddities via an explicit alias table. Anything we're
# not certain about is LEFT ALONE, so two genuinely different schools
# never get merged.
normalize_team <- function(x) {
  if (length(x) == 0) return(character(0))
  s <- as.character(x)
  na_mask <- is.na(s)
  s <- trimws(s)

  s <- sub("^#\\d+\\s+", "", s)              # "#13 Centre"   -> "Centre"
  s <- sub("\\s*\\([^)]*\\)\\s*$", "", s)     # "Centre (Ky.)" -> "Centre"
  s <- sub("~\\d+$", "", s)                   # "CENTRE~1"     -> "CENTRE"
  s <- sub("[ _-](MB|WB|M|W)$", "", s,        # "CENTRE_M"     -> "CENTRE"
           ignore.case = TRUE)

  # Title-case strings that are entirely one case (all-upper or all-lower).
  # Mixed-case strings ("Centre", "Birmingham-Southern") are left alone so we
  # don't disturb intentional capitalization.
  has_low <- grepl("[a-z]", s); has_up <- grepl("[A-Z]", s)
  single_case <- (!has_low & has_up) | (has_low & !has_up)
  s[single_case] <- tools::toTitleCase(tolower(s[single_case]))

  s <- sub("\\s+(Men|Women)\\s*$", "", s, ignore.case = TRUE)
  # Strip a trailing institution word so the same club spelled "Millsaps"
  # and "Millsaps College" folds to one key. Without this, one Millsaps
  # game (vs Tougaloo, 2024-25) tagged every possession "millsaps college",
  # splitting it off from "millsaps" — which lost 54 points and skewed
  # their offensive/defensive possession split by 141 in the conference
  # table. Only strips when it's a trailing word, so "<X> College" -> "<X>"
  # but a hyphenated/embedded use is left alone. Safe for SAA: none of the
  # member schools' canonical short names need a College/University suffix.
  s <- sub("\\s+(College|University|Univ\\.?)\\s*$", "", s, ignore.case = TRUE)
  s <- trimws(s)

  # Centre-specific aliases. Only fires for exact matches.
  centre_aliases <- c("Centre College", "Centrem", "Centremb")
  s[s %in% centre_aliases] <- "Centre"

  # SAA member aliases — fold known multi-spelling clubs to one canonical
  # key so a team's own games don't split across variants (which silently
  # mis-attributes that game's points/possessions in the conference table).
  # Birmingham-Southern alone appears as four spellings in 2022-23 men's:
  # "Birmingham-So.", "Birmingham Southern", "Birmingham-Southern", "BSC".
  saa_aliases <- c(
    "Birmingham-So."      = "Birmingham-Southern",
    "Birmingham So."      = "Birmingham-Southern",
    "Birmingham Southern" = "Birmingham-Southern",
    "Bsc"                 = "Birmingham-Southern",
    "BSC"                 = "Birmingham-Southern"
  )
  hit <- match(s, names(saa_aliases))
  s[!is.na(hit)] <- unname(saa_aliases[hit[!is.na(hit)]])

  s[na_mask] <- NA_character_
  s
}

# Folder -> canonical team name. Each SAA school's data lives in its own
# folder, so we always know which club it is — even when that club is
# spelled many ways inside the files.
SCHOOL_CANON <- c(
  centrecolonels      = "Centre",
  berryvikings        = "Berry",
  bscsports           = "Birmingham-Southern",
  gomajors            = "Millsaps",
  hendrixwarriors     = "Hendrix",
  rhodeslynx          = "Rhodes",
  sewaneetigers       = "Sewanee",
  southwesternpirates = "Southwestern",
  trinitytigers       = "Trinity"
)

# Reverse map: canonical team name -> its data folder. Lets the dashboard
# load any SAA team's OWN full-season folder when that team is selected
# (so the Games picker shows their whole season, not just the game vs
# Centre). Non-SAA opponents aren't here and fall back to Centre's folder.
TEAM_TO_FOLDER <- setNames(names(SCHOOL_CANON), unname(SCHOOL_CANON))

# SAA membership is season-dependent. A school's data folder may contain
# seasons from AFTER it left the conference (e.g. Hendrix still has 2025-26
# games, but those are SCAC games — Hendrix rejoined the SCAC after 2024-25).
# Birmingham-Southern closed after 2023-24. The conference comparison only
# includes a school for seasons up to and including its last SAA season, so
# departed schools drop out of current views but remain in the historical
# seasons when they really were members.
SAA_LAST_SEASON <- c(
  hendrixwarriors = "2024-25",
  bscsports       = "2023-24"
)
school_in_saa <- function(school, season) {
  if (!school %in% names(SAA_LAST_SEASON)) return(TRUE)
  season <= SAA_LAST_SEASON[[school]]   # "2025-26" > "2024-25" lexically
}

# SAA members we have NO data folder for (never scraped — e.g. Oglethorpe).
# We reconstruct their season from the games they played against the SAA
# teams we DO have, so they still appear in the conference comparison. The
# catch: that only covers CONFERENCE games (their non-conference games live
# in their own un-scraped folder), so reconstructed teams are marked with a
# dagger and excluded from "all games" being truly all-games.
RECON_TEAMS  <- c("Oglethorpe")
RECON_FIRST  <- c(Oglethorpe = "2012-13")   # SAA play began 2012-13
recon_member <- function(team, season) {
  f <- RECON_FIRST[[team]]
  is.null(f) || season >= f
}

# Shared metric vocabulary for the conference pickers, scatter axes, and
# tables. CONF_METRIC_CHOICES drives the dropdowns (label -> code);
# METRIC_LABEL is the reverse for pretty display; LOWER_BETTER lists the
# metrics where a SMALLER number is better (so we sort ascending and flip
# the scatter axis so "good" is always toward the top-right).
CONF_METRIC_CHOICES <- c(
  "Net Rating"       = "NETRTG",
  "Offensive Rating" = "OFFRTG",
  "Defensive Rating" = "DEFRTG",
  "Plus / Minus"     = "plus_minus",
  "Effective FG %"   = "EFG_PCT",
  "FG %"             = "FG_PCT",
  "3-Point %"        = "FG3_PCT",
  "Assist / TO"      = "AST_TO",
  "Assist Ratio"     = "AST_RATIO",
  "TOV %"            = "TOV_PCT",
  "Off Reb Rate"     = "OREB_RATE",
  "Def Reb Rate"     = "DREB_RATE",
  "Pace"             = "PACE"
)
METRIC_LABEL <- setNames(names(CONF_METRIC_CHOICES), unname(CONF_METRIC_CHOICES))
LOWER_BETTER <- c("DEFRTG", "TOV_PCT")

# The rich rate-stat column order shared by the conference team table and the
# conference lineup table, so every conference view exposes the same metrics
# (3PT %, eFG %, AST/TO, Pace, +/- …) that used to live only in Top Lineups.
CONF_RATE_COLS <- c("OFFRTG", "DEFRTG", "NETRTG", "plus_minus",
                    "FG_PCT", "FG3_PCT", "EFG_PCT",
                    "AST_TO", "AST_RATIO", "TOV_PCT",
                    "OREB_RATE", "DREB_RATE", "PACE")

# Approximate primary brand colour per school (used for the bar chart
# fills and the scatter fallback tokens). Centre is brand gold.
SCHOOL_COLORS <- c(
  Centre = "#FFCD00", Berry = "#1B3A6B", `Birmingham-Southern` = "#C8A951",
  Millsaps = "#5B2D90", Hendrix = "#F58025", Rhodes = "#9D2235",
  Sewanee = "#582C83", Southwestern = "#C99700", Trinity = "#7C2529"
)

# ---- Team logos as scatter markers ---------------------------------------
# PNGs live in www/logos/<folder>.png (one per SAA school). We render each on
# a white circular "chip" so any logo — athletic mark or academic seal —
# reads cleanly on the dark Goldsberry-style panel. Cached per folder.
# project_root is defined further down, so resolve the dir lazily at call time.
.logo_dir   <- function() file.path(project_root, "MAT405basketballResearch", "www", "logos")
.logo_cache <- new.env(parent = emptyenv())

# Normalise a png::readPNG array (grayscale / GA / RGB / RGBA) to a raster.
.as_rgba_raster <- function(a) {
  d <- dim(a)
  if (length(d) == 2) { r <- g <- b <- a; al <- matrix(1, d[1], d[2]); h <- d[1] }
  else {
    h <- d[1]
    if (d[3] == 2)      { r <- g <- b <- a[, , 1]; al <- a[, , 2] }
    else if (d[3] == 3) { r <- a[, , 1]; g <- a[, , 2]; b <- a[, , 3]; al <- matrix(1, d[1], d[2]) }
    else                { r <- a[, , 1]; g <- a[, , 2]; b <- a[, , 3]; al <- a[, , 4] }
  }
  grDevices::as.raster(matrix(grDevices::rgb(r, g, b, al), nrow = h))
}

team_logo_raster <- function(folder) {
  if (is.null(folder) || is.na(folder)) return(NULL)
  if (exists(folder, envir = .logo_cache)) return(get(folder, envir = .logo_cache))
  path <- file.path(.logo_dir(), paste0(folder, ".png"))
  ras <- NULL
  if (file.exists(path) && requireNamespace("png", quietly = TRUE)) {
    a <- tryCatch(png::readPNG(path), error = function(e) NULL)
    if (!is.null(a)) ras <- tryCatch(.as_rgba_raster(a), error = function(e) NULL)
  }
  assign(folder, ras, envir = .logo_cache)
  ras
}

# A white circular chip holding the logo (aspect-preserved). Centre gets a
# bold gold ring; everyone else a faint slate ring. Falls back to a plain
# chip when the logo file is missing.
logo_chip_grob <- function(ras, centre = FALSE) {
  ring_col <- if (centre) "#FFCD00" else "#C7CCD1"
  ring_lwd <- if (centre) 3.6 else 1.1
  circ <- grid::circleGrob(r = grid::unit(0.5, "snpc"),
                           gp = grid::gpar(fill = "white", col = ring_col, lwd = ring_lwd))
  if (is.null(ras)) return(grid::grobTree(circ))
  d <- dim(ras); asp <- d[2] / d[1]
  fill <- 0.86   # how much of the chip the logo fills (aspect-preserved)
  if (asp >= 1) { wf <- fill; hf <- fill / asp } else { hf <- fill; wf <- fill * asp }
  grid::grobTree(circ, grid::rasterGrob(ras, width = grid::unit(wf, "snpc"),
                                        height = grid::unit(hf, "snpc")))
}

# Plot font = the dashboard's display face, Barlow Condensed, loaded into the
# graphics device via showtext (it's a Google web-font, not a system font, so
# the plot device can't see it otherwise). Falls back to a condensed/system
# sans if showtext or the download isn't available.
.PLOT_FONT <- local({
  ok <- requireNamespace("showtext", quietly = TRUE) &&
        requireNamespace("sysfonts", quietly = TRUE)
  if (ok) {
    fam <- tryCatch({
      sysfonts::font_add_google("Barlow Condensed", "barlow")
      showtext::showtext_auto()
      showtext::showtext_opts(dpi = 96)
      "barlow"
    }, error = function(e) NA_character_)
    if (!is.na(fam)) fam else "sans"
  } else "sans"
})
.LABEL_FONT <- .PLOT_FONT
.BASE_FONT  <- .PLOT_FONT

# Light (white-background) theme shared by all three conference visuals.
.conf_plot_theme <- function() {
  theme_minimal(base_size = 14, base_family = .BASE_FONT) +
    theme(
      plot.background  = element_rect(fill = "#FFFFFF", colour = NA),
      panel.background = element_rect(fill = "#FFFFFF", colour = NA),
      panel.grid.minor = element_blank(),
      panel.grid.major = element_line(colour = "#ECECE7"),
      axis.text   = element_text(colour = "#5b6772"),
      axis.title  = element_text(colour = "#333F4C", face = "bold", size = 12),
      plot.title  = element_text(colour = "#1a1f24", face = "bold", size = 16),
      plot.caption = element_text(colour = "#B23A2E", hjust = 0, size = 10),
      legend.position = "none"
    )
}

# Build the conference visualization. `viz` is "scatter" | "bar".
# Scatter uses x/y metrics with logo markers + a gold average crosshair;
# bar ranks teams on a single metric with Centre in gold.
build_conference_plot <- function(d, viz, xm, ym, metric) {
  if (is.null(d) || nrow(d) == 0) return(NULL)
  d$is_centre <- d$Team == "Centre"
  d$folder    <- names(SCHOOL_CANON)[match(d$Team, unname(SCHOOL_CANON))]
  # Folderless teams (reconstructed, e.g. Oglethorpe) -> slug for the logo file.
  na_f <- is.na(d$folder)
  if (any(na_f)) d$folder[na_f] <- tolower(gsub("[^A-Za-z]", "", d$Team[na_f]))
  any_flagged <- "reliable" %in% names(d) && any(!d$reliable)
  cap <- if (any_flagged)
    "*  season totals don't fully reconcile to box scores" else NULL
  d$mark <- if ("reliable" %in% names(d)) ifelse(d$reliable, "", " *") else ""

  if (viz == "scatter") {
    d <- d[is.finite(d[[xm]]) & is.finite(d[[ym]]), , drop = FALSE]
    if (nrow(d) == 0) return(NULL)
    d$.x <- d[[xm]]; d$.y <- d[[ym]]
    avg_x <- mean(d$.x); avg_y <- mean(d$.y)
    xr <- diff(range(d$.x)); yr <- diff(range(d$.y))
    if (xr == 0) xr <- 1; if (yr == 0) yr <- 1
    # Logo marker size as a fraction of each axis range. The panel is forced
    # square (aspect.ratio = 1 below), so equal x/y fractions render as equal
    # visual sizes and the markers stay round and stable on window resize.
    dx <- 0.12 * xr; dy <- 0.12 * yr

    # geom_blank trains the x/y scales on the true data points (the logos are
    # annotation layers that DON'T train scales). No team-name labels — the
    # logos identify the teams (Goldsberry style).
    p <- ggplot(d, aes(.x, .y)) +
      geom_hline(yintercept = avg_y, colour = "#000000", linewidth = 1.1) +
      geom_vline(xintercept = avg_x, colour = "#000000", linewidth = 1.1) +
      geom_blank()
    # Non-Centre chips first, Centre last (on top) and 1.3x larger.
    for (i in order(d$is_centre)) {
      mlt <- if (d$is_centre[i]) 1.3 else 1
      p <- p + annotation_custom(
        logo_chip_grob(team_logo_raster(d$folder[i]), d$is_centre[i]),
        xmin = d$.x[i] - dx * mlt / 2, xmax = d$.x[i] + dx * mlt / 2,
        ymin = d$.y[i] - dy * mlt / 2, ymax = d$.y[i] + dy * mlt / 2)
    }
    p <- p +
      labs(x = METRIC_LABEL[[xm]] %||% xm,
           y = METRIC_LABEL[[ym]] %||% ym) +
      .conf_plot_theme()
    p <- p + (if (xm %in% LOWER_BETTER)
                scale_x_reverse(expand = expansion(mult = 0.14))
              else scale_x_continuous(expand = expansion(mult = 0.14)))
    p <- p + (if (ym %in% LOWER_BETTER)
                scale_y_reverse(expand = expansion(mult = 0.14))
              else scale_y_continuous(expand = expansion(mult = 0.14)))
    return(p)
  }

  # ---- bar chart on a single metric ----
  mm <- metric
  d <- d[is.finite(d[[mm]]), , drop = FALSE]; if (nrow(d) == 0) return(NULL)
  asc <- mm %in% LOWER_BETTER
  d <- d[order(d[[mm]], decreasing = !asc), ]
  lbls <- paste0(d$Team, d$mark)                   # append * / † markers
  d$Team <- factor(lbls, levels = rev(lbls))       # best at top after coord_flip
  lab <- METRIC_LABEL[[mm]] %||% mm
  pad <- 0.14 * diff(range(d[[mm]])); if (!is.finite(pad) || pad == 0) pad <- 1

  # Bar chart (the only non-scatter option). Same bold Barlow Condensed
  # treatment as the scatter for the team names and value labels.
  ggplot(d, aes(Team, .data[[mm]], fill = is_centre)) +
    geom_col(width = 0.72) +
    geom_text(aes(label = formatC(.data[[mm]], format = "f", digits = 1)),
              hjust = -0.18, colour = "#333F4C", size = 4.4,
              family = .BASE_FONT, fontface = "bold") +
    scale_fill_manual(values = c("FALSE" = "#A7BACB", "TRUE" = "#FFCD00")) +
    coord_flip(clip = "off") +
    scale_y_continuous(expand = expansion(mult = c(0, 0.14))) +
    labs(x = NULL, y = lab, caption = cap) +
    .conf_plot_theme() +
    theme(axis.text.y = element_text(colour = "#1a1f24", family = .LABEL_FONT,
                                     face = "bold", size = 15))
}

# Fold a school's OWN name variants to one canonical key inside its folder.
#
# Older Sidearm feeds spell a team's own name many ways across its season:
# gender suffixes ("Hendrixm", "Rhodeswb", "Centrew"), mascots ("Tigers",
# "Sewwomen"), truncations ("Millsa", "Sewane"), and "<X> Men's Basketball".
# When a team's name varies, the rows from its variant-named games don't
# match `Team == team`, so that game's points and possessions get counted
# as the opponent's — silently losing offense and skewing the off/def
# possession split (the conference audit found 60+ team-seasons like this,
# the worst losing 1454 points). normalize_team() can't catch open-ended
# variants, but inside a known school folder we can: a value is the school
# if it covers many games (opponents appear in only 1-3) OR is prefix-
# related to the canonical name. Cross-checked: folds every known variant
# while leaving clean teams (and all opponents) untouched.
.prefix_related <- function(v, canon_lc) {
  k <- pmin(nchar(v), nchar(canon_lc))
  k >= 4 & substr(v, 1, k) == substr(canon_lc, 1, k)
}
canonicalize_school_team <- function(d, canonical) {
  if (is.null(d) || nrow(d) == 0 || is.na(canonical) ||
      !"gameID" %in% names(d)) return(d)
  ng  <- dplyr::n_distinct(d$gameID)
  thr <- max(4, 0.30 * ng)
  variants_in <- function(col, canon) {
    vals <- unique(d[[col]]); vals <- vals[!is.na(vals) & vals != ""]
    if (length(vals) == 0) return(character(0))
    cov <- d %>% distinct(gameID, .val = .data[[col]]) %>%
      filter(!is.na(.val) & .val != "") %>% count(.val)
    high_cov <- cov$.val[cov$n >= thr]
    pref     <- vals[.prefix_related(tolower(vals), tolower(canon))]
    union(high_cov, pref)
  }
  for (col in intersect(c("homeTeam", "awayTeam"), names(d))) {
    hits <- variants_in(col, canonical)
    if (length(hits)) d[[col]][d[[col]] %in% hits] <- canonical
  }
  canon_lc <- tolower(canonical)
  for (col in intersect(c("Team", "possTeam"), names(d))) {
    hits <- variants_in(col, canon_lc)
    if (length(hits)) d[[col]][d[[col]] %in% hits] <- canon_lc
  }
  d
}

# Sport toggle support. The project root contains one folder per sport
# (mens-basketball / womens-basketball); each holds an SAA/<school>/pbp
# tree with one folder per season. The seasons picker is rebuilt whenever
# the sport changes — see seasons_root_for_sport() and load_pbp().
project_root <- "/Users/shreyup/CentreBasketballLineupAnalysis"

# Per-sport season root. Falls back to the legacy (no-sport) layout when
# the sport-specific directory isn't present, so a single-sport install
# keeps working without changes. `school` defaults to Centre so every
# existing call is unchanged; the conference-comparison feature passes
# other SAA schools to pull their play-by-play.
seasons_root_for_sport <- function(sport, school = "centrecolonels") {
  cand <- file.path(project_root, sport, "SAA", school, "pbp")
  if (dir.exists(cand)) return(cand)
  legacy <- file.path(project_root, "SAA", school, "pbp")
  legacy
}

# List the SAA schools that have a data folder for the given sport. Used to
# build the conference-comparison table (one row per school's team).
available_schools_for_sport <- function(sport) {
  saa <- file.path(project_root, sport, "SAA")
  if (!dir.exists(saa)) saa <- file.path(project_root, "SAA")
  if (!dir.exists(saa)) return(character(0))
  list.dirs(saa, recursive = FALSE, full.names = FALSE)
}

# Auto-detect available sports based on which top-level sport dirs exist.
available_sports <- {
  candidates <- c("mens-basketball", "womens-basketball")
  found <- candidates[vapply(candidates, function(s) {
    dir.exists(file.path(project_root, s, "SAA"))
  }, logical(1))]
  if (length(found) == 0) "mens-basketball" else found
}

# Initial seasons_root uses the first available sport. The Shiny server
# overrides this reactively as the user toggles between sports.
seasons_root <- seasons_root_for_sport(available_sports[1])
available_seasons <- sort(
  list.dirs(seasons_root, recursive = FALSE, full.names = FALSE),
  decreasing = TRUE   # newest first so the most recent season is the default
)

# Pretty labels for the radio buttons.
sport_labels <- c(
  "mens-basketball"   = "Men's Basketball",
  "womens-basketball" = "Women's Basketball"
)

# Derive a per-row "elapsed seconds since previous row" column from the
# game clock (`timeRemaining` is "MM:SS" remaining in the current period).
#
# Why: `secondsPerPoss` in the source feed only fills in for ~half the
# possessions, so summing it undercounts minutes-on-court by ~50% and
# inflates PACE by a corresponding factor. The clock deltas cover every
# row, summing to ~2400 sec per 40-min game.
#
# Approach: group by gameID + Period, parse the "MM:SS" string, forward-
# fill missing clock values, and take (previous clock - this clock) as the
# elapsed seconds attributed to *this* row. Sub rows (clock stopped) get
# zero elapsed time, which is correct.
add_elapsed_seconds <- function(d) {
  if (!"timeRemaining" %in% names(d)) { d$elapsed_sec <- 0; return(d) }

  parse_clock <- function(s) {
    out <- rep(NA_real_, length(s))
    ok <- !is.na(s) & grepl("^\\d+:\\d+$", s)
    parts <- strsplit(s[ok], ":")
    out[ok] <- vapply(parts, function(p) as.numeric(p[1]) * 60 + as.numeric(p[2]), numeric(1))
    out
  }
  d$.tr_sec <- parse_clock(d$timeRemaining)

  game_key <- if ("gameID" %in% names(d)) d$gameID else rep("x", nrow(d))
  period   <- if ("Period" %in% names(d)) d$Period else rep("1", nrow(d))
  key      <- paste(game_key, period, sep = "|")

  d$elapsed_sec <- 0
  for (k in unique(key)) {
    idx <- which(key == k)
    tr  <- d$.tr_sec[idx]
    # Forward-fill NA so a non-clock row inherits the previous clock value.
    for (i in seq_along(tr)) {
      if (is.na(tr[i])) tr[i] <- if (i == 1) NA_real_ else tr[i - 1]
    }
    period_start <- suppressWarnings(max(tr, na.rm = TRUE))
    if (!is.finite(period_start)) next
    prev <- c(period_start, head(tr, -1))
    el   <- prev - tr
    el[is.na(el) | el < 0] <- 0
    d$elapsed_sec[idx] <- el
  }
  d$.tr_sec <- NULL
  d
}

# Loader for one season. Same cleanup pipeline as before; pulled into a
# function so the season picker can re-run it on demand. Uses intersect()
# when picking columns so older seasons with slightly different schemas
# don't crash if a column is missing.
#
# Accepts an optional `sport` arg so the dashboard's sport toggle can
# request mens-basketball or womens-basketball at runtime. Defaults to
# whatever module-level `seasons_root` is set to (legacy behavior).
load_pbp <- function(season, sport = NULL, school = "centrecolonels") {
  base <- if (!is.null(sport)) seasons_root_for_sport(sport, school) else seasons_root
  dir <- file.path(base, season)
  files <- list.files(dir, pattern = "\\.csv$", full.names = TRUE)
  if (length(files) == 0) return(NULL)

  # FAST CSV READ. read.csv on 200+ files takes 25-30 sec; readr::read_csv
  # is ~10x faster (~2-3 sec) and data.table::fread is faster still. We
  # prefer fread if available, fall back to readr, fall back to base R.
  d <- if (requireNamespace("data.table", quietly = TRUE)) {
    data.table::rbindlist(
      lapply(files, function(f) data.table::fread(
        f, colClasses = "character", showProgress = FALSE, fill = TRUE)),
      fill = TRUE, use.names = TRUE
    ) |> as.data.frame()
  } else if (requireNamespace("readr", quietly = TRUE)) {
    bind_rows(lapply(files, function(f) readr::read_csv(
      f, col_types = readr::cols(.default = "c"), progress = FALSE)))
  } else {
    bind_rows(lapply(files, read.csv, colClasses = "character"))
  }

  num_cols <- intersect(
    c("possPoints", "possStart", "teamChanged", "ASSIST",
      "OREB", "DREB", "secondsPerPoss", "playerMissing"),
    names(d)
  )
  d[num_cols] <- lapply(d[num_cols], as.numeric)

  # Normalize team-name columns to a single canonical spelling.
  # PERFORMANCE: normalize_team() runs per-element via sub() chains; calling
  # it directly on a 12k-row Team/possTeam column burns ~3 sec per season.
  # Each season has only ~10-20 unique values, so we cache the
  # normalization on the unique set and map back. Drops load_pbp time from
  # ~3.2s to ~0.3s on the biggest seasons.
  normalize_team_fast <- function(x, lower = FALSE) {
    if (length(x) == 0) return(character(0))
    u <- unique(x)
    nu <- normalize_team(u)
    if (lower) nu <- tolower(nu)
    nu[match(x, u)]
  }
  for (col in intersect(c("homeTeam", "awayTeam"), names(d))) {
    d[[col]] <- normalize_team_fast(d[[col]])
  }
  for (col in intersect(c("Team", "possTeam"), names(d))) {
    d[[col]] <- normalize_team_fast(d[[col]], lower = TRUE)
  }

  # Fold this school's own name variants to its canonical name. We know the
  # club from the folder, so even open-ended spellings ("Centrew", "Rhodeswb",
  # "Tigers") collapse to one key — without which that game's points and
  # possessions get mis-credited to the opponent. No-op for clean teams and
  # for unknown folders (canonical = NA). See canonicalize_school_team().
  d <- canonicalize_school_team(d, unname(SCHOOL_CANON[school]))

  # Strip jersey tokens that some games prepend or append to player names
  # (e.g. "3,moore,chez" / "gardner,2" -> "moore,chez" / "gardner").
  player_cols <- intersect(
    c("Player", paste0("awayPlayer", 1:5), paste0("homePlayer", 1:5)),
    names(d)
  )
  d[player_cols] <- lapply(d[player_cols], function(x) {
    x <- sub("^[0-9]+,", "", x)
    x <- sub(",[0-9]+$", "", x)
    x
  })

  # Normalize "None" / "" lineup-slot placeholders to NA. We DO NOT drop
  # these rows anymore. Previously load_pbp() filtered them out entirely,
  # which silently removed every scoring play in any period where the
  # parser's substitution tracker drifted (the lineup state goes to NA
  # for the rest of the period). That undercounted the dashboard's score
  # totals for ~10 Centre 2023-24 games by 1-84 points each (509 total) —
  # even though the play stream itself is complete and the per-row Team /
  # playType data is fine.
  #
  # New behaviour: keep the rows. They get an NA `CentreLineup` downstream
  # so they don't pollute per-lineup aggregations, but they still count
  # toward the game's total points (the "Game Facts" / "Totals" footer).
  # The dashboard's `Lineups in Game` and `Player Tables` tabs naturally
  # exclude NA-lineup rows because they group by CentreLineup; the
  # difference between the per-lineup sum and the game total surfaces in
  # the existing footer-diff line, where users were already trained to
  # see it.
  lineup_cols <- intersect(
    c(paste0("awayPlayer", 1:5), paste0("homePlayer", 1:5)),
    names(d)
  )
  if (length(lineup_cols) > 0) {
    d[lineup_cols] <- lapply(d[lineup_cols], function(x) {
      ifelse(x == "None" | x == "", NA_character_, x)
    })
  }
  # playerMissing == 1 means the same thing (parser lost track of the
  # on-court lineup) and the same logic applies — keep the row, let it
  # land in the NA-CentreLineup bucket.

  # Handle "phantom" rows — the box-score-summary block the Python
  # scraper appends at the end of each period (rows with no game clock,
  # i.e. "--" or empty). These rows hold the assist/rebound indicators
  # but NOT timestamped plays.
  #
  # The OLD Python pipeline ran the possession tracker over phantom rows
  # too, creating a duplicate possession sequence on top of the real plays.
  # Summing possPoints on teamChanged==1 then over-counted by ~2x,
  # producing OFFRTG values north of 200.
  #
  # The NEW Python pipeline (getbasketballclean.py with
  # _zero_phantom_possession_flags + _reattribute_phantom_lineups) zeros
  # possStart/teamChanged/possPoints on phantom rows AND copies each
  # phantom assist/rebound row's lineup from the matching real play.
  #
  # Auto-detect which pipeline produced this CSV: if any phantom row
  # still carries possStart==1 or teamChanged==1, we're looking at an
  # OLD CSV and must drop the phantom rows to fix the ratings (cost:
  # rebound/assist counts go to zero per lineup). If phantom rows are
  # already clean (NEW CSV), keep them — they now carry correctly
  # attributed assist/rebound indicators.
  if ("timeRemaining" %in% names(d) && nrow(d) > 0) {
    is_real <- grepl("^\\d+:\\d+$", d$timeRemaining)
    if (any(!is_real)) {
      phantom_has_bad_flags <- FALSE
      for (col in c("possStart", "teamChanged")) {
        if (col %in% names(d)) {
          vals <- suppressWarnings(as.numeric(d[[col]][!is_real]))
          if (any(vals == 1, na.rm = TRUE)) {
            phantom_has_bad_flags <- TRUE
            break
          }
        }
      }
      if (phantom_has_bad_flags) {
        # OLD pipeline output — drop phantom rows so they can't inflate
        # OFFRTG. Once the CSVs are regenerated with the new Python code,
        # this branch is bypassed automatically.
        d <- d[is_real, , drop = FALSE]
      }
      # else: NEW pipeline output — keep phantom rows; their flags are
      # already zero and their lineups have been re-attributed.
    }
  }

  # Repair the `Team` column for games where the Python parser mis-attributed
  # every play to a single side. ~35 of the 2018-19 Sidearm games shipped HTML
  # tables that crammed both teams' plays into one column; the parser's
  # heuristic (`data == df['homePlay'][i]`) then always fell through to the
  # else-branch and tagged every row with the away team. Audit signature:
  # one distinct non-empty Team value per gameID, and the box-score score
  # for the missing team is zero.
  #
  # The lineup snapshot columns (homePlayer1..5 / awayPlayer1..5) are still
  # populated correctly because they come from the parser's substitution
  # tracker, not the play-text heuristic. So we re-derive Team from
  # Player ∈ which-lineup, per row.
  d <- repair_team_attribution(d)

  # Add elapsed_sec from the game clock — see add_elapsed_seconds() comment
  # for the rationale. Done AFTER row drops so each surviving row gets the
  # full clock span since the previous surviving row.
  d <- add_elapsed_seconds(d)
  d
}

# Re-derive the Team column for games where every play row was mis-attributed
# to a single side (see comment in load_pbp). Detection: per-gameID, the set
# of distinct non-NA Team values has size 1. Resolution: per row, look up
# Player in the home / away lineup snapshot columns and assign Team from the
# side it appears on. Rows where the player can't be located in either
# lineup fall back to possTeam, and finally to the original (corrupted) value.
#
# Safe-by-default: only fires on games whose Team column is monotone. Good
# games (the overwhelming majority) are untouched.
repair_team_attribution <- function(d) {
  needed <- c("Team", "Player", "homeTeam", "awayTeam", "gameID",
              paste0("homePlayer", 1:5), paste0("awayPlayer", 1:5))
  if (!all(needed %in% names(d))) return(d)
  if (nrow(d) == 0) return(d)

  team_lc <- tolower(d$Team)
  # Identify games with monotone Team (corruption signature).
  bad_games <- d %>%
    mutate(.t = team_lc) %>%
    group_by(gameID) %>%
    summarise(n_distinct = dplyr::n_distinct(.t[!is.na(.t) & .t != ""]),
              .groups = "drop") %>%
    filter(n_distinct <= 1) %>%
    pull(gameID)
  if (length(bad_games) == 0) return(d)

  mask <- d$gameID %in% bad_games & !is.na(d$Player) & d$Player != ""
  if (!any(mask)) return(d)

  idx <- which(mask)
  player <- d$Player[idx]
  home_team_lc <- tolower(d$homeTeam[idx])
  away_team_lc <- tolower(d$awayTeam[idx])

  in_home <- (player == d$homePlayer1[idx]) | (player == d$homePlayer2[idx]) |
             (player == d$homePlayer3[idx]) | (player == d$homePlayer4[idx]) |
             (player == d$homePlayer5[idx])
  in_away <- (player == d$awayPlayer1[idx]) | (player == d$awayPlayer2[idx]) |
             (player == d$awayPlayer3[idx]) | (player == d$awayPlayer4[idx]) |
             (player == d$awayPlayer5[idx])
  in_home[is.na(in_home)] <- FALSE
  in_away[is.na(in_away)] <- FALSE

  new_team <- d$Team[idx]   # default: keep original
  new_team[in_home & !in_away] <- home_team_lc[in_home & !in_away]
  new_team[in_away & !in_home] <- away_team_lc[in_away & !in_home]

  # Fallback for rows where the player isn't in either snapshot (NA lineup
  # rows in older feeds): use possTeam if available.
  unresolved <- !in_home & !in_away
  if (any(unresolved) && "possTeam" %in% names(d)) {
    pt <- d$possTeam[idx]
    use_pt <- unresolved & !is.na(pt) & pt != ""
    new_team[use_pt] <- pt[use_pt]
  }

  d$Team[idx] <- new_team
  d
}

# Tiny per-process cache so flipping back to a season you've already viewed
# is instant — the CSV parse happens once per (sport, school, season) per
# process. Keyed by "<sport>::<school>::<season>" so men's/women's and the
# different SAA team folders never collide.
.pbp_cache <- new.env(parent = emptyenv())
pbp_cache_key <- function(sport, school, season) {
  paste0(sport %||% "", "::", school, "::", season)
}
load_pbp_cached <- function(season, sport = NULL, school = "centrecolonels") {
  key <- pbp_cache_key(sport, school, season)
  if (!exists(key, envir = .pbp_cache)) {
    assign(key, load_pbp(season, sport = sport, school = school), envir = .pbp_cache)
  }
  get(key, envir = .pbp_cache)
}

# ===========================================================================
# Conference comparison — season-level team metrics for every SAA school.
#
# Each school's pbp folder is self-contained (it holds that school's games,
# home and away). We load each school's season, identify its own team (the
# club present in essentially every game), and pool the whole play stream
# into ONE group so compute_lineup_metrics() yields that team's season
# totals — the exact same point/possession/shooting logic already validated
# for lineups, just aggregated team-wide. Cross-checked: a team's pooled
# pointsEarned/pointsAgainst match the sum of its box-score final scores.
# ===========================================================================

# The school's own team name = the normalized club present in the most games
# (it appears in every game while opponents vary).
own_team_name <- function(d) {
  if (is.null(d) || nrow(d) == 0) return(NA_character_)
  tab <- sort(table(c(d$homeTeam, d$awayTeam)), decreasing = TRUE)
  if (length(tab) == 0) return(NA_character_)
  names(tab)[1]
}

# Season totals for one team. `conf_only` restricts to SAA-flagged games.
# Returns a one-row data frame, or NULL if no qualifying games.
compute_team_season_metrics <- function(d, team, conf_only = FALSE) {
  if (is.null(d) || nrow(d) == 0 || is.na(team)) return(NULL)
  if (conf_only && "saaGame" %in% names(d)) {
    d <- d[!is.na(d$saaGame) & d$saaGame == "1", , drop = FALSE]
  }
  if (nrow(d) == 0) return(NULL)

  # Pool every row into a single group so the per-lineup aggregator returns
  # the team's season line. selected_team is lowercased inside the helper.
  d$CentreLineup <- "ALL"
  m <- compute_lineup_metrics(d, team)
  if (is.null(m) || nrow(m) == 0) return(NULL)
  m$CentreLineup <- NULL

  # Win/loss record + box-score reconciliation from distinct games.
  gmeta <- d %>% distinct(gameID, finalScore, homeTeam, homeWin)
  home_is_team <- gmeta$homeTeam == team
  team_won <- (home_is_team & gmeta$homeWin == "Win") |
              (!home_is_team & gmeta$homeWin != "Win")
  m$Team   <- team
  m$Games  <- nrow(gmeta)
  m$Wins   <- sum(team_won, na.rm = TRUE)
  m$Losses <- m$Games - m$Wins

  # DATA CONFIDENCE. finalScore is "AWAY-HOME". Sum the team's real points
  # for/against across its games and compare to the play-stream totals; a
  # large gap (or a big offensive/defensive possession imbalance) means the
  # parser lost data somewhere in that team's folder, so its rates should
  # be read with caution. These two signals caught the Millsaps name-split
  # before it was fixed; they now surface any residual noise per team.
  parts <- strsplit(gmeta$finalScore, "-")
  box_for <- 0L; box_against <- 0L
  for (i in seq_along(parts)) {
    p <- suppressWarnings(as.integer(parts[[i]]))
    if (length(p) != 2 || any(is.na(p))) next
    if (home_is_team[i]) { box_for <- box_for + p[2]; box_against <- box_against + p[1] }
    else                 { box_for <- box_for + p[1]; box_against <- box_against + p[2] }
  }
  m$box_for     <- box_for
  m$box_against <- box_against
  m$recon_gap   <- abs(m$pointsEarned - box_for) + abs(m$pointsAgainst - box_against)
  m$poss_skew   <- m$OFFPOSS - m$DEFPOSS
  total_box     <- box_for + box_against
  rel_err       <- if (total_box > 0) m$recon_gap / total_box else 0
  # Reliable unless points are >=1.5% off OR possessions skew by >=20.
  m$reliable    <- !(rel_err >= 0.015 | abs(m$poss_skew) >= 20)
  m
}

# Build the full conference table for a (sport, season). One row per SAA
# school that has data that season. Result is cached per
# "sport::season::conf|all" so re-opening the tab is instant.
.conf_cache <- new.env(parent = emptyenv())
compute_conference_table <- function(sport, season, conf_only = FALSE) {
  key <- paste0(sport, "::", season, "::", if (conf_only) "conf" else "all")
  if (exists(key, envir = .conf_cache)) return(get(key, envir = .conf_cache))

  schools <- available_schools_for_sport(sport)
  rows <- list()
  recon_games <- setNames(vector("list", length(RECON_TEAMS)), RECON_TEAMS)
  for (sc in schools) {
    if (!school_in_saa(sc, season)) next   # skip departed schools this season
    d <- tryCatch(load_pbp(season, sport = sport, school = sc),
                  error = function(e) NULL)
    if (is.null(d) || nrow(d) == 0) next
    # While we have this folder loaded, grab any games it holds against a
    # folderless SAA team (Oglethorpe) so we can reconstruct that team below.
    for (rt in RECON_TEAMS) {
      g <- d[coalesce(d$homeTeam == rt, FALSE) | coalesce(d$awayTeam == rt, FALSE), , drop = FALSE]
      if (nrow(g)) recon_games[[rt]] <- dplyr::bind_rows(recon_games[[rt]], g)
    }
    # Canonical name from the folder (load_pbp already folded variants to it);
    # fall back to the modal team if the folder isn't in the map.
    tm <- unname(SCHOOL_CANON[sc]); if (is.na(tm)) tm <- own_team_name(d)
    r  <- tryCatch(compute_team_season_metrics(d, tm, conf_only = conf_only),
                   error = function(e) NULL)
    if (!is.null(r)) { r$reconstructed <- FALSE; rows[[sc]] <- r }
  }
  # Append reconstructed (folderless) SAA members from their opponent games.
  for (rt in RECON_TEAMS) {
    if (!recon_member(rt, season)) next
    g <- recon_games[[rt]]
    if (is.null(g) || nrow(g) == 0) next
    g <- g[!duplicated(g$gameID) | TRUE, , drop = FALSE]   # games are already unique
    r <- tryCatch(compute_team_season_metrics(g, rt, conf_only = conf_only),
                  error = function(e) NULL)
    if (!is.null(r)) { r$reconstructed <- TRUE; rows[[rt]] <- r }
  }
  out <- if (length(rows)) dplyr::bind_rows(rows) else NULL
  if (!is.null(out)) {
    if (!"reconstructed" %in% names(out)) out$reconstructed <- FALSE
    out$reconstructed[is.na(out$reconstructed)] <- FALSE
    out <- out %>% arrange(desc(NETRTG))
  }
  assign(key, out, envir = .conf_cache)
  out
}

# Every team's five-man lineups across the conference, for the lineup-vs-
# lineup comparison. For each school we build that team's lineups (using its
# canonical name) and run the SAME per-lineup aggregator the Centre tabs use,
# then tag each row with the team. The full set is cached; the min-possession
# filter is applied later in the renderer so the slider stays instant. A
# `reliable` column is carried from the conference table so the UI can warn
# when a team's season data didn't fully reconcile.
.conf_lu_cache <- new.env(parent = emptyenv())
compute_conference_lineups <- function(sport, season, conf_only = FALSE) {
  key <- paste0(sport, "::", season, "::", if (conf_only) "conf" else "all")
  if (exists(key, envir = .conf_lu_cache)) return(get(key, envir = .conf_lu_cache))

  rel <- compute_conference_table(sport, season, conf_only)
  rel_map <- if (!is.null(rel)) setNames(rel$reliable, rel$Team) else character(0)

  # Build one team's lineups from a play-by-play frame.
  team_lineups <- function(d, team, reconstructed) {
    if (conf_only && "saaGame" %in% names(d)) {
      d <- d[!is.na(d$saaGame) & d$saaGame == "1", , drop = FALSE]
    }
    if (nrow(d) == 0) return(NULL)
    d <- d %>% mutate(CentreLineup = build_lineup(
      awayTeam, homeTeam, team,
      awayPlayer1, awayPlayer2, awayPlayer3, awayPlayer4, awayPlayer5,
      homePlayer1, homePlayer2, homePlayer3, homePlayer4, homePlayer5))
    m <- tryCatch(compute_lineup_metrics(d, team), error = function(e) NULL)
    if (is.null(m) || nrow(m) == 0) return(NULL)
    m <- m %>% filter(!is.na(CentreLineup) & CentreLineup != "")
    if (nrow(m) == 0) return(NULL)
    m$Team          <- team
    m$reliable      <- if (length(rel_map)) isTRUE(unname(rel_map[team])) else TRUE
    m$reconstructed <- reconstructed
    m
  }

  rows <- list()
  recon_games <- setNames(vector("list", length(RECON_TEAMS)), RECON_TEAMS)
  for (sc in available_schools_for_sport(sport)) {
    if (!school_in_saa(sc, season)) next   # skip departed schools this season
    d <- tryCatch(load_pbp(season, sport = sport, school = sc),
                  error = function(e) NULL)
    if (is.null(d) || nrow(d) == 0) next
    for (rt in RECON_TEAMS) {
      g <- d[coalesce(d$homeTeam == rt, FALSE) | coalesce(d$awayTeam == rt, FALSE), , drop = FALSE]
      if (nrow(g)) recon_games[[rt]] <- dplyr::bind_rows(recon_games[[rt]], g)
    }
    team <- unname(SCHOOL_CANON[sc]); if (is.na(team)) team <- own_team_name(d)
    rows[[sc]] <- team_lineups(d, team, FALSE)
  }
  # Reconstructed (folderless) SAA members' lineups from their opponent games.
  for (rt in RECON_TEAMS) {
    if (!recon_member(rt, season)) next
    g <- recon_games[[rt]]
    if (is.null(g) || nrow(g) == 0) next
    rows[[rt]] <- team_lineups(g, rt, TRUE)
  }
  out <- if (length(rows)) dplyr::bind_rows(rows) else NULL
  assign(key, out, envir = .conf_lu_cache)
  out
}

# Cache pre-warm — run BEFORE the server function starts. R blocks the
# Shiny startup until this returns, so the first request the user makes
# is already served from RAM and feels instant. We only pre-warm the
# newest season of the default sport; everything else is loaded lazily.
.prewarm_seasons <- function() {
  for (sport in available_sports) {
    root <- seasons_root_for_sport(sport)
    seasons <- sort(
      list.dirs(root, recursive = FALSE, full.names = FALSE),
      decreasing = TRUE
    )
    if (length(seasons) >= 1) {
      try(load_pbp_cached(seasons[1], sport = sport), silent = TRUE)
    }
  }
}
.prewarm_seasons()

# Background pre-warm of every REMAINING season. Each season now loads
# in ~0.2 s (post fread + normalize_team_fast), so warming all ~30 of
# them costs a few seconds of idle event-loop time and ~100 MB of RAM —
# after which EVERY season pick and sport toggle is instant, no
# progress bar. Scheduled via later::later() with staggered delays so
# the callbacks run between user interactions instead of blocking
# startup or any request; a season the user picks before its background
# slot simply loads on demand (the cache check makes the background job
# a no-op).
.prewarm_rest_in_background <- function() {
  if (!requireNamespace("later", quietly = TRUE)) return(invisible())
  make_job <- function(sp, se) {
    function() try(load_pbp_cached(se, sport = sp), silent = TRUE)
  }
  delay <- 2
  for (sport in available_sports) {
    root <- seasons_root_for_sport(sport)
    seasons <- sort(
      list.dirs(root, recursive = FALSE, full.names = FALSE),
      decreasing = TRUE
    )
    for (season in seasons) {
      key <- pbp_cache_key(sport, "centrecolonels", season)
      if (exists(key, envir = .pbp_cache)) next
      later::later(make_job(sport, season), delay)
      delay <- delay + 0.5
    }
  }
}
.prewarm_rest_in_background()


# CentreBasketballLogo.png is the wide horizontal lockup (758 x 359, ratio
# ≈ 0.474). At ~140 px wide the eagle and "CENTRE BASKETBALL" wordmark
# both read cleanly inside the black header band.
image_ratio <- 359/758
image_width <- 140

ui <- fluidPage(

  tags$head(
    # Brand-aligned typography. Kapra Neue and Galaxie Copernicus are
    # proprietary, so use the closest open-source analogues:
    #   - DM Sans            ≈ Kapra Neue            (UI, body)
    #   - Barlow Condensed   ≈ Kapra Neue Condensed  (display, headers, numbers)
    #   - Source Serif 4     ≈ Galaxie Copernicus    (long-form, academic accent)
    tags$link(rel = "stylesheet", href = "https://fonts.googleapis.com/css2?family=DM+Sans:wght@400;500;600;700&family=Barlow+Condensed:wght@400;500;600;700&family=Source+Serif+4:ital,wght@0,400;0,600;1,400&display=swap"),
    tags$link(rel = "stylesheet", href = "https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.4.0/css/all.min.css"),
    theme = shinytheme("sandstone"),
    tags$style(HTML("
      /* ---------- Brand palette (Centre Brand Standards, Aug 2022) ----------
         Primary:  Centre Gold #FFCD00, Black #000000, White #FFFFFF
         Secondary accents we use sparingly:
           #333F4C  deep slate   (PMS 432)
           #115E67  teal         (PMS 209)
           #A7BACB  light slate  (PMS 545)
           #D9D9D6  warm gray    (PMS Cool Gray 1)
         Brand rule: 'When using secondary colors, use more white space and
         less black.' Most of the chrome is white-on-light-gray with gold
         used as the single accent. Black is reserved for the header band,
         table head, and active controls. ---------------------------------- */
      :root {
        --gold:       #FFCD00;
        --gold-soft:  #FFF3B0;
        --gold-line:  rgba(255,205,0,0.30);
        --black:      #000000;
        --slate:      #333F4C;
        --slate-2:    #5b6772;
        --teal:       #115E67;
        --warm-gray:  #D9D9D6;
        --bg:         #FAFAF7;
        --panel:      #FFFFFF;
        --line:       #ECECE7;
        --ink:        #1a1f24;
        --ink-2:      #5b6772;
      }
      html, body {
        background: var(--bg);
        color: var(--ink);
        font-family: 'DM Sans', system-ui, sans-serif;
      }
      .container-fluid { max-width: 1480px; }

      /* All-caps display labels (mimicking Kapra Neue Condensed) */
      .display, .display-num, .nav-tabs > li > a, table.dataTable thead th,
      .filter-item label, .card-soft__title, .app-header__title,
      .app-header__subtitle, .btn-group .btn, .reset-lineup-btn {
        font-family: 'Barlow Condensed', 'DM Sans', sans-serif;
      }

      /* ---------- Header band ---------- */
      .app-header {
        background: var(--black);
        color: white;
        padding: 16px 30px;
        border-bottom: 3px solid var(--gold);
        display: flex;
        align-items: center;
        gap: 14px;
      }
      /* Let the logo size from its width/height attributes — the wide
         horizontal lockup is ~2:1, so a fixed-height rule squishes the
         wordmark. display:block removes the inline-img baseline gap so
         the logo sits flush against the header band. */
      .app-header__logo { display: block; height: auto; max-height: 72px; }
      .app-header__title {
        font-weight: 600;
        font-size: 24px;
        letter-spacing: 1.2px;
        text-transform: uppercase;
      }
      .app-header__subtitle {
        color: var(--gold);
        font-size: 13px;
        font-weight: 500;
        margin-left: auto;
        letter-spacing: 2px;
        text-transform: uppercase;
      }

      /* ---------- Top filter bar ---------- */
      .filter-bar {
        background: var(--panel);
        border: 1px solid var(--line);
        border-radius: 4px;
        padding: 16px 18px;
        margin: 18px 0 14px 0;
        display: grid;
        grid-template-columns: repeat(auto-fit, minmax(190px, 1fr));
        gap: 14px;
        align-items: end;
      }
      .filter-item label {
        display: block;
        font-size: 11px;
        font-weight: 600;
        letter-spacing: 1.4px;
        text-transform: uppercase;
        color: var(--ink-2);
        margin-bottom: 6px;
      }
      /* pickerInput / numericInput wrap their control in a Bootstrap
         .form-group div with a 15px bottom margin. The bare program
         toggle and the Reset button don't carry that wrapper, so without
         this reset the picker rows sit ~15px lower than the toggle and
         the button. Zero out the wrapper margin so every filter-item is
         exactly the same height (label + 6px gap + 38px control). */
      .filter-item .form-group,
      .filter-item .shiny-input-container {
        margin-bottom: 0 !important;
      }

      /* ---------- Program toggle — sliding pill, height-matched to pickers ----------
         A 38px-tall track with a black slider pill that moves between the
         two halves. The pill is a pseudo-element (::before) so clicks pass
         through to the radio inputs on top. :has() detects which radio is
         checked and translates the pill. Active text turns gold. */
      .program-toggle {
        position: relative;
        display: block;
        background: #F1F0EB;
        border: 1px solid #d0d0cb;
        border-radius: 6px;
        padding: 3px;
        height: 38px;
        width: 100%;
        box-sizing: border-box;
        overflow: hidden;
      }
      /* The sliding black pill */
      .program-toggle::before {
        content: '';
        position: absolute;
        top: 3px;
        left: 3px;
        width: calc(50% - 3px);
        height: calc(100% - 6px);
        background: var(--black);
        border-radius: 4px;
        box-shadow: 0 1px 3px rgba(0,0,0,0.18);
        transform: translateX(0);
        transition: transform 0.28s cubic-bezier(0.4, 0.0, 0.2, 1);
        z-index: 0;
        pointer-events: none;
      }
      /* Slide right when the SECOND radio is checked. The Shiny inline
         radioButtons render <label class='radio-inline'>...</label>; we
         target the 2nd one. */
      .program-toggle:has(.radio-inline:nth-of-type(2) input:checked)::before,
      .program-toggle:has(.shiny-options-group label:nth-of-type(2) input:checked)::before {
        transform: translateX(100%);
      }
      /* Layout of the Shiny radio group inside the track */
      .program-toggle .shiny-input-radiogroup,
      .program-toggle .shiny-options-group {
        display: flex;
        height: 100%;
        margin: 0;
        padding: 0;
        position: relative;
        z-index: 1;
        width: 100%;
      }
      .program-toggle .radio-inline,
      .program-toggle .radio {
        flex: 1;
        margin: 0 !important;
        padding: 0 !important;
        display: flex;
        align-items: center;
        justify-content: center;
        cursor: pointer;
      }
      .program-toggle .radio-inline + .radio-inline,
      .program-toggle .radio + .radio { margin-left: 0 !important; }
      .program-toggle .radio-inline span,
      .program-toggle .radio span {
        font-family: 'Barlow Condensed', 'DM Sans', sans-serif;
        font-size: 13px;
        font-weight: 600;
        letter-spacing: 0.9px;
        text-transform: uppercase;
        color: var(--ink-2);
        transition: color 0.22s ease;
        white-space: nowrap;
        line-height: 1;
        padding: 0 6px;
      }
      .program-toggle .radio-inline:hover span,
      .program-toggle .radio:hover span { color: var(--black); }
      /* Active half — gold text on the sliding black pill */
      .program-toggle .radio-inline:has(input:checked) span,
      .program-toggle .radio:has(input:checked) span {
        color: var(--gold) !important;
      }
      /* Hide the actual radio circles — clicks still register via the label */
      .program-toggle input[type='radio'] {
        position: absolute !important;
        opacity: 0 !important;
        width: 0 !important;
        height: 0 !important;
        margin: 0 !important;
        pointer-events: none !important;
      }
      .filter-item .program-toggle { margin-top: 0; }

      /* ---------- Inputs ---------- */
      .selectize-input, .selectize-input.focus {
        background: var(--panel) !important;
        color: var(--ink) !important;
        border: 1px solid #d0d0cb !important;
        border-radius: 4px !important;
        box-shadow: none !important;
        min-height: 38px;
        padding: 7px 11px;
        font-family: 'DM Sans', sans-serif;
      }
      .selectize-input.focus {
        border-color: var(--gold) !important;
        box-shadow: 0 0 0 2px var(--gold-line) !important;
      }
      .selectize-dropdown {
        border: 1px solid #d0d0cb !important;
        border-radius: 4px !important;
        margin-top: 2px;
      }
      .selectize-dropdown, .selectize-dropdown-content, .selectize-dropdown-content .option {
        background: var(--panel) !important; color: var(--ink) !important;
      }
      .selectize-dropdown-content .option:hover, .selectize-dropdown .active {
        background: var(--gold-soft) !important; color: var(--black) !important;
      }
      .selectize-input > div { /* picked tag pills */
        background: var(--black) !important;
        color: var(--gold) !important;
        border-radius: 3px;
        padding: 2px 9px !important;
        margin: 2px 3px 0 0 !important;
        font-family: 'Barlow Condensed', sans-serif;
        font-weight: 500;
        letter-spacing: 0.5px;
        text-transform: uppercase;
        font-size: 12px;
      }
      input[type='number'] {
        border: 1px solid #d0d0cb !important;
        border-radius: 4px !important;
        padding: 7px 10px !important;
        font-family: 'DM Sans', sans-serif;
      }
      input[type='number']:focus {
        border-color: var(--gold) !important;
        box-shadow: 0 0 0 2px var(--gold-line) !important; outline: none;
      }

      /* ---------- Reset button — gold pill ---------- */
      .reset-lineup-btn {
        background: var(--gold) !important;
        color: var(--black) !important;
        border: none !important;
        font-weight: 600 !important;
        font-size: 13px;
        letter-spacing: 1.2px;
        text-transform: uppercase;
        border-radius: 4px;
        width: 100%;
        padding: 9px;
        transition: background 0.15s, transform 0.05s;
      }
      .reset-lineup-btn:hover { background: #E6B800 !important; }
      .reset-lineup-btn:active { transform: translateY(1px); }

      /* ---------- Tab navigation ---------- */
      .nav-tabs {
        border-bottom: none;
        background: var(--panel);
        border: 1px solid var(--line);
        border-radius: 4px;
        padding: 4px;
        margin-bottom: 14px;
        display: flex;
        flex-wrap: wrap;
        gap: 2px;
      }
      .nav-tabs > li > a {
        border: none !important;
        background: transparent !important;
        color: var(--ink-2) !important;
        font-weight: 600;
        font-size: 14px;
        letter-spacing: 0.9px;
        text-transform: uppercase;
        padding: 9px 18px;
        border-radius: 3px;
      }
      .nav-tabs > li > a:hover {
        background: var(--gold-soft) !important;
        color: var(--black) !important;
      }
      .nav-tabs > li.active > a,
      .nav-tabs > li.active > a:focus,
      .nav-tabs > li.active > a:hover {
        background: var(--black) !important;
        color: var(--gold) !important;
        border: none !important;
      }
      .tab-content > .tab-pane { animation: fadein 0.18s ease-out; }
      @keyframes fadein { from { opacity: 0; transform: translateY(2px); } to { opacity: 1; transform: translateY(0); } }

      /* ---------- Game Facts card ---------- */
      .card-soft {
        background: var(--panel);
        border: 1px solid var(--line);
        border-left: 3px solid var(--gold);
        border-radius: 4px;
        padding: 14px 18px;
        margin-bottom: 14px;
      }
      .card-soft__title {
        font-weight: 600;
        letter-spacing: 1.4px;
        text-transform: uppercase;
        font-size: 11px;
        color: var(--ink-2);
        margin-bottom: 6px;
      }

      /* ---------- Conference scatter hover tooltip ---------- */
      .conf-tip {
        position: absolute;
        pointer-events: none;
        z-index: 50;
        background: var(--black);
        color: #fff;
        border-radius: 6px;
        padding: 8px 11px;
        box-shadow: 0 4px 14px rgba(0,0,0,0.28);
        font-family: 'DM Sans', system-ui, sans-serif;
        font-size: 12px;
        min-width: 150px;
      }
      .conf-tip__team {
        font-family: 'Barlow Condensed', 'DM Sans', sans-serif;
        font-weight: 700; text-transform: uppercase; letter-spacing: 0.6px;
        font-size: 15px; color: var(--gold); margin-bottom: 4px;
      }
      .conf-tip__row {
        display: flex; justify-content: space-between; gap: 16px;
        line-height: 1.5;
      }
      .conf-tip__row span { color: #c7ccd1; }

      /* ---------- Conference-lineup headline ---------- */
      .lu-headline { display: flex; flex-direction: column; gap: 14px; }
      .lu-block { display: flex; flex-direction: column; gap: 4px; }
      .lu-label {
        font-family: 'Barlow Condensed', 'DM Sans', sans-serif;
        font-weight: 600; letter-spacing: 1.2px; text-transform: uppercase;
        font-size: 11px; color: var(--ink-2);
      }
      .lu-rank {
        font-weight: 700; color: var(--ink);
        background: var(--gold-soft); border-radius: 3px; padding: 0 6px;
      }
      .lu-team {
        font-family: 'Barlow Condensed', 'DM Sans', sans-serif;
        font-weight: 700; font-size: 18px; letter-spacing: 0.4px; color: var(--ink);
      }
      .lu-team--centre { color: #b8860b; }
      .lu-row { display: flex; align-items: center; flex-wrap: wrap; gap: 8px; }
      .lu-metric {
        font-family: 'Barlow Condensed', 'DM Sans', sans-serif;
        font-weight: 700; font-size: 14px; color: var(--black);
        background: var(--gold); border-radius: 999px; padding: 2px 12px;
        white-space: nowrap;
      }
      .lu-poss { font-size: 12px; color: var(--ink-2); white-space: nowrap; }
      .lu-leader {
        align-self: flex-start;
        font-family: 'Barlow Condensed', 'DM Sans', sans-serif;
        font-weight: 700; letter-spacing: 1px; text-transform: uppercase;
        font-size: 12px; color: #1C7C43;
        background: #E7F4EA; border-radius: 999px; padding: 3px 12px;
      }

      /* ---------- Data table ---------- */
      table.dataTable { font-size: 14.5px; font-family: 'DM Sans', sans-serif; }
      table.dataTable thead th {
        background: var(--black);
        color: var(--gold);
        font-weight: 500;
        text-transform: uppercase;
        font-size: 11px;
        letter-spacing: 1px;
        border-bottom: none !important;
        padding: 11px 9px;
      }
      table.dataTable tbody tr {
        transition: background 0.1s;
        border-bottom: 1px solid var(--line);
      }
      table.dataTable tbody tr:hover { background: var(--gold-soft) !important; }
      table.dataTable tbody td {
        padding: 8px 9px;
        border-top: 1px solid var(--line) !important;
        /* Ease the conditional-formatting tint/text colour in when the
           table re-sorts or re-filters, so cells fade between states
           instead of snapping. */
        transition: background-color 0.18s ease, color 0.18s ease;
      }
      /* numeric cells get tabular Barlow Condensed so columns line up */
      table.dataTable td.dt-right, table.dataTable td.dt-body-right {
        font-family: 'Barlow Condensed', monospace;
        font-feature-settings: 'tnum' 1;
        font-weight: 500;
      }

      /* ---------- Lineup column accent ----------
         Used by the Lineups-in-Game table (and any other table that opts in
         via the `lineup-cell` className on the CentreLineup column). The
         column is the visual anchor of the table — gold left-stripe, soft
         gold background, bolder display typography — so the eye returns to
         the lineup identity no matter how far the user has scrolled. */
      /* Default state: lineup column is type-only — Barlow Condensed bold
         + room to wrap the capsules. NO gold background, NO accent stripe.
         The visual highlight (gold wash + left stripe) only fires when
         the row is hovered, so the column reads as quiet most of the
         time and pops on intent. */
      table.dataTable td.lineup-cell {
        font-family: 'Barlow Condensed', 'DM Sans', sans-serif !important;
        font-weight: 600 !important;
        letter-spacing: 0.5px;
        color: var(--ink) !important;
        /* Generous min-width so the row of player capsules has enough
           breathing room — but no nowrap, so when the lineup has 5
           players the capsules wrap onto a second/third line instead of
           ballooning the column out to the entire viewport. */
        min-width: 240px;
        max-width: 320px;
        vertical-align: middle;
        white-space: normal;
        padding: 6px 8px !important;
      }
      /* Header cell — explicit black/gold paint. Required because the
         FixedColumns extension clones the pinned column into a separate
         DTFC_LeftHeadWrapper that ships with a white background;
         without these !important overrides the cloned header reads as a
         white square next to the rest of the black header band. */
      table.dataTable thead th.lineup-cell {
        background: var(--black) !important;
        color: var(--gold) !important;
        font-family: 'Barlow Condensed', 'DM Sans', sans-serif !important;
        letter-spacing: 1px;
        text-transform: uppercase;
      }
      /* Hover state for the body cell — soft gold wash + inset gold stripe. */
      table.dataTable tbody tr:hover td.lineup-cell {
        background: var(--gold-soft) !important;
        box-shadow: inset 4px 0 0 0 var(--gold);
      }

      /* ---------- Player capsules ----------
         Each player in a lineup cell is wrapped in a player-pill span by
         the column JS renderer. The pills mark each name as its own
         atomic unit — coaches can scan a lineup as five distinct people
         instead of one comma-glued string. White fill with a gold ring
         sits well against the gold-soft lineup-cell background. */
      /* Default state: white chip ringed in Centre gold with black
         wordmark — high-contrast black-on-white type sits inside a gold
         capsule outline. Hover flips to gold fill (still black text) so
         the specific name being pointed at lights up. */
      .player-pill {
        display: inline-block;
        background: #FFFFFF;
        color: var(--black);
        border: 1.5px solid var(--gold);
        border-radius: 999px;
        padding: 2px 9px;
        margin: 2px 3px 2px 0;
        font-family: 'Barlow Condensed', 'DM Sans', sans-serif;
        font-weight: 700;
        font-size: 12px;
        letter-spacing: 0.4px;
        text-transform: uppercase;
        white-space: nowrap;
        line-height: 1.35;
        transition: border-color 0.12s, background 0.12s, color 0.12s;
      }
      /* Per-pill hover — fill with gold (text stays black for contrast)
         so the specific name pops against the row of white capsules. */
      .player-pill:hover {
        background: var(--gold);
        color: var(--black);
        border-color: var(--gold);
      }

      /* ---------- Horizontal-scroll wrapper + FixedColumns ----------
         When `scrollX = TRUE` is set, DataTables wraps the table in a
         dts_scroll layout. We need to make sure the wrapper actually shows
         a scrollbar (default is suppressed on Safari) and that the cloned
         FixedColumns layer doesn't lose the lineup-cell accent. */
      .dataTables_scrollBody { overflow-x: auto !important; }
      .dataTables_scrollBody::-webkit-scrollbar { height: 10px; }
      .dataTables_scrollBody::-webkit-scrollbar-thumb {
        background: var(--gold);
        border-radius: 5px;
      }
      .dataTables_scrollBody::-webkit-scrollbar-track {
        background: var(--line);
      }
      /* FixedColumns clones the frozen column into a separate layer. Lift
         it with a soft shadow so the pinned column reads as floating over
         the horizontally-scrolling area. */
      .DTFC_LeftWrapper, .DTFC_LeftBodyWrapper, .DTFC_LeftHeadWrapper {
        box-shadow: 4px 0 8px rgba(0,0,0,0.08);
      }

      /* ---------- radioGroupButtons (Top Lineups metric picker) ---------- */
      .btn-group .btn {
        background: var(--panel) !important;
        color: var(--ink) !important;
        border: 1px solid #d0d0cb !important;
        font-size: 12px;
        font-weight: 600;
        letter-spacing: 0.6px;
        text-transform: uppercase;
        padding: 6px 12px;
      }
      .btn-group .btn:hover {
        background: var(--gold-soft) !important;
        border-color: var(--gold) !important;
      }
      .btn-group .btn.active,
      .btn-group .btn.active:hover {
        background: var(--black) !important;
        color: var(--gold) !important;
        border-color: var(--black) !important;
      }

      /* ---------- Hide top-of-page Shiny margin ---------- */
      .container-fluid > .row { margin-left: 0; margin-right: 0; }
    "))
  ),

  titlePanel(
    title = div(
      class = "app-header",
      img(src = "CentreBasketballLogo.png", alt = "Centre logo",
          class = "app-header__logo",
          width = image_width, height = image_width * image_ratio),
      span(class = "app-header__title", "Centre College Basketball")
    ),
    windowTitle = "Centre College Basketball"
  ),

  # Horizontal top filter bar — all controls in a single row across the
  # window. CSS grid lays them out side-by-side with auto-wrap so the bar
  # stays usable on narrower screens.
  div(class = "filter-bar",
    if (length(available_sports) > 1) div(
      class = "filter-item",
      tags$label("Program"),
      div(class = "program-toggle",
        radioButtons(
          inputId = "sportInput", label = NULL,
          choiceNames  = lapply(available_sports, function(s)
            # short labels — "Men's" / "Women's" fit better in a compact toggle
            tags$span(sub(" Basketball$", "", sport_labels[[s]]))),
          choiceValues = available_sports,
          selected = available_sports[1], inline = TRUE
        )
      )
    ) else NULL,
    div(class = "filter-item",
      pickerInput(
        inputId = "seasonInput", label = "Season",
        choices = available_seasons, selected = available_seasons[1],
        multiple = FALSE, width = "100%"
      )
    ),
    div(class = "filter-item",
      pickerInput(
        inputId = "TeamInput", label = "Team",
        choices = NULL, multiple = FALSE, width = "100%"
      )
    ),
    div(class = "filter-item",
      pickerInput(
        inputId = "det_game", label = "Games",
        choices = NULL, selected = NULL, multiple = TRUE, width = "100%",
        options = list(`live-search` = TRUE, `actions-box` = TRUE,
                       `selected-text-format` = "count > 2")
      )
    ),
    div(class = "filter-item",
      pickerInput(
        inputId = "PlayerInput", label = "Players",
        choices = NULL, multiple = TRUE, width = "100%",
        options = list(`live-search` = TRUE, `actions-box` = TRUE,
                       `selected-text-format` = "count > 2")
      )
    ),
    # Sample-size gate: applied PER SIDE — OFFRTG gates on OFFPOSS,
    # DEFRTG on DEFPOSS, NETRTG/plus_minus on both.
    div(class = "filter-item",
      numericInput(
        inputId = "min_poss", label = "Min Poss / Side",
        value = 20, min = 1, max = 500, step = 1, width = "100%"
      )
    ),
    div(class = "filter-item",
      tags$label(HTML("&nbsp;")),  # spacer so button aligns with inputs
      actionButton(
        inputId = "resetLineup", label = "Reset Lineup",
        icon = icon("rotate-left"), class = "reset-lineup-btn"
      )
    )
  ),


  div(style = "padding: 0 14px 14px 14px;",
    div(
      # Quick-facts panel for the selected game(s). Always visible above
      # the tabs so the coach has the box-score context at a glance.
      tags$div(
        class = "card-soft",
        tags$div(class = "card-soft__title",
                 icon("clipboard-list", style = "margin-right: 6px;"),
                 "Game Facts"),
        htmlOutput("gameFacts")
      ),
      tabsetPanel(
        # Conference comparison — how every SAA team's season stacks up.
        # Independent of the Team / Game(s) pickers: it always shows the
        # whole conference for the selected sport + season.
        tabPanel("Conference",
                 div(style = "margin: 12px 0 6px 0;",
                     radioGroupButtons(
                       inputId  = "conf_scope",
                       label    = "Games included:",
                       choices  = c("All games" = "all",
                                    "Conference games only" = "conf"),
                       selected = "all",
                       direction = "horizontal",
                       individual = TRUE, size = "sm"
                     ),
                     radioGroupButtons(
                       inputId = "conf_viz", label = "Chart type:",
                       choices = c("Scatter" = "scatter", "Bar" = "bar"),
                       selected = "scatter", direction = "horizontal",
                       individual = TRUE, size = "sm"
                     ),
                     div(style = "display:flex; flex-wrap:wrap; gap:18px; align-items:flex-end;",
                       div(pickerInput(
                         inputId = "conf_x", label = "Scatter X axis",
                         choices = CONF_METRIC_CHOICES, selected = "OFFRTG",
                         width = "180px")),
                       div(pickerInput(
                         inputId = "conf_y", label = "Scatter Y axis",
                         choices = CONF_METRIC_CHOICES, selected = "DEFRTG",
                         width = "180px")),
                       div(pickerInput(
                         inputId = "conf_metric", label = "Bar / table metric",
                         choices = CONF_METRIC_CHOICES, selected = "NETRTG",
                         width = "220px"))
                     )
                 ),
                 # Relative wrapper so the hover tooltip can be absolutely
                 # positioned over the plot. The plot height is responsive
                 # (60vh, clamped) so it grows/shrinks with the window.
                 div(style = "position: relative;",
                   plotOutput("conferencePlot",
                              height = "60vh",
                              hover = hoverOpts("conf_hover", delay = 60,
                                                delayType = "debounce")),
                   uiOutput("conf_hover_tip")
                 ),
                 div(style = "height: 10px;"),
                 dataTableOutput("conferenceTable")
        ),
        # Conference lineups — compare Centre's five-man units against
        # every other SAA team's lineups (their full season, not just the
        # game vs Centre). Headline shows the conference's best lineup next
        # to Centre's best; the team filter lets you drill into any club.
        tabPanel("Conf Lineups",
                 div(style = "margin: 12px 0 6px 0;",
                     radioGroupButtons(
                       inputId = "conf_lu_scope",
                       label   = "Games included:",
                       choices = c("All games" = "all",
                                   "Conference games only" = "conf"),
                       selected = "all", direction = "horizontal",
                       individual = TRUE, size = "sm"
                     ),
                     div(style = "display:flex; flex-wrap:wrap; gap:18px; align-items:flex-end;",
                       div(pickerInput(
                         inputId = "conf_lu_team", label = "Show team",
                         choices = "All teams", selected = "All teams",
                         width = "190px")),
                       div(radioGroupButtons(
                         inputId = "conf_lu_metric", label = "Rank by:",
                         choices = c("Net Rating"="NETRTG","Off Rating"="OFFRTG",
                                     "Def Rating"="DEFRTG","Eff FG %"="EFG_PCT",
                                     "Pts Scored"="pointsEarned"),
                         selected = "NETRTG", direction = "horizontal",
                         individual = TRUE, size = "sm")),
                       div(numericInput(
                         inputId = "conf_lu_minposs", label = "Min Poss / Side",
                         value = 20, min = 1, max = 500, step = 1, width = "150px")),
                       div(numericInput(
                         inputId = "conf_lu_topn", label = "Rows",
                         value = 25, min = 1, max = 200, step = 5, width = "110px"))
                     )
                 ),
                 uiOutput("confLineupHeadline"),
                 div(style = "height: 8px;"),
                 dataTableOutput("conferenceLineups")
        ),
        tabPanel("Player Tables",
                 dataTableOutput("lineupData"),
                 # Totals row — sums computed pointsEarned / pointsAgainst
                 # across the visible lineups and compares to the actual
                 # final score so the coach can spot when the play stream
                 # is missing data for these particular lineups.
                 uiOutput("lineupDataTotals"),
                 textOutput("summary")
        ),
        tabPanel("All Data",
                 dataTableOutput("allAwayData"),
                 dataTableOutput("allHomeData")
        ),
        tabPanel("Lineups in Game",
                 dataTableOutput("lineupsInGameData"),
                 uiOutput("lineupsInGameDataTotals")
        ),
        # New "Top 5" view: pick a metric, see the 5 lineups that lead it
        # AMONG lineups clearing the sidebar's min-possessions threshold.
        # Independent of the picker so you can browse without disturbing
        # your current Player-Tables selection.
        tabPanel("Top Lineups",
                 div(style = "margin: 12px 0 6px 0;",
                     numericInput(
                       inputId = "top_n",
                       label   = "How many top lineups to show",
                       value   = 5, min = 1, max = 50, step = 1,
                       width   = "260px"
                     ),
                     radioGroupButtons(
                       inputId  = "top5_metric",
                       label    = "Rank lineups by:",
                       choices  = c(
                         "Net Rating"        = "NETRTG",
                         "Offensive Rating"  = "OFFRTG",
                         "Defensive Rating"  = "DEFRTG",
                         "Plus / Minus"      = "plus_minus",
                         "Off Rebound Rate"  = "OREB_RATE",
                         "Def Rebound Rate"  = "DREB_RATE",
                         "TOV %"             = "TOV_PCT",
                         "FG %"              = "FG_PCT",
                         "3PFG %"            = "FG3_PCT",
                         "Effective FG %"    = "EFG_PCT",
                         "Assist / Turnover" = "AST_TO",
                         "Pace"              = "PACE",
                         "Minutes on Court"  = "TIME_MIN"
                       ),
                       selected   = "NETRTG",
                       direction  = "horizontal",
                       individual = TRUE,
                       size       = "sm"
                     )
                 ),
                 dataTableOutput("topFiveLineups")
        ),
        # "Group Performance" — auto-anchor view. The system picks the 3
        # most-played players in the selected games as anchors, then
        # surfaces every 5-man lineup containing them with the 2 varying
        # slots broken out in the "Others" column. No manual picker
        # selection required; coach gets the comparison directly from
        # team-level data.
        tabPanel("Group Performance",
                 div(style = "margin: 12px 0 6px 0;",
                     tags$p(style = "color: #444; margin: 0 0 8px 0;",
                            "The system automatically picks the ",
                            tags$b("3 players with the most floor time"),
                            " in the selected games as anchors, then lists every 5-man lineup containing those 3. The ",
                            tags$em("Others"),
                            " column shows the 2 varying slots so you can compare what each combination of remaining teammates brings on top of the core."),
                     tags$div(style = "font-weight: bold; margin: 6px 0;",
                              textOutput("group_anchors_label", inline = TRUE)),
                     radioGroupButtons(
                       inputId  = "group_metric",
                       label    = "Rank groups by:",
                       choices  = c(
                         "Net Rating"        = "NETRTG",
                         "Offensive Rating"  = "OFFRTG",
                         "Defensive Rating"  = "DEFRTG",
                         "Plus / Minus"      = "plus_minus",
                         "Off Rebound Rate"  = "OREB_RATE",
                         "Def Rebound Rate"  = "DREB_RATE",
                         "TOV %"             = "TOV_PCT",
                         "FG %"              = "FG_PCT",
                         "3PFG %"            = "FG3_PCT",
                         "Effective FG %"    = "EFG_PCT",
                         "Assist / Turnover" = "AST_TO",
                         "Pace"              = "PACE",
                         "Minutes on Court"  = "TIME_MIN",
                         "Total Possessions" = "TOTAL_POSS"
                       ),
                       selected   = "NETRTG",
                       direction  = "horizontal",
                       individual = TRUE,
                       size       = "sm"
                     )
                 ),
                 dataTableOutput("groupPerformanceData")
        ),
        # "Player Combination" — N-player subgroup leaderboard.
        #
        # The user picks N (1-4) from the dropdown; the table lists every
        # distinct N-player combination that has actually played together
        # on the selected team in the selected games, with metrics POOLED
        # across every 5-man lineup that contained that group. No need to
        # pick individual players — the tab enumerates the universe of
        # observed N-groups and sorts them by the chosen metric.
        tabPanel("Player Combination",
                 div(style = "margin: 12px 0 6px 0;",
                     tags$p(style = "color: #444; margin: 0 0 8px 0;",
                            "Pick the group size, and the table lists every ",
                            tags$b("observed"),
                            " N-player combination on the selected team.",
                            tags$em("min possessions"),
                            " applies."),
                     numericInput(
                       inputId = "combo_size",
                       label   = "How many players per combination?",
                       value   = 3, min = 1, max = 4, step = 1,
                       width   = "260px"
                     ),
                     radioGroupButtons(
                       inputId  = "combo_metric",
                       label    = "Rank combinations by:",
                       choices  = c(
                         "Net Rating"        = "NETRTG",
                         "Offensive Rating"  = "OFFRTG",
                         "Defensive Rating"  = "DEFRTG",
                         "Plus / Minus"      = "plus_minus",
                         "Off Rebound Rate"  = "OREB_RATE",
                         "Def Rebound Rate"  = "DREB_RATE",
                         "TOV %"             = "TOV_PCT",
                         "FG %"              = "FG_PCT",
                         "3PFG %"            = "FG3_PCT",
                         "Effective FG %"    = "EFG_PCT",
                         "Assist / Turnover" = "AST_TO",
                         "Pace"              = "PACE",
                         "Minutes on Court"  = "TIME_MIN",
                         "Total Possessions" = "TOTAL_POSS"
                       ),
                       selected   = "NETRTG",
                       direction  = "horizontal",
                       individual = TRUE,
                       size       = "sm"
                     )
                 ),
                 dataTableOutput("combinationData")
        )
      )
    )
  )
)

server <- function(input, output, session) {

  # Resolve the currently selected sport. If the toggle isn't in the UI
  # (single-sport install), default to the first available sport.
  current_sport <- reactive({
    s <- input$sportInput
    if (is.null(s) || !nzchar(s)) available_sports[1] else s
  })

  # Refresh the season picker when the sport changes. The seasons
  # available under mens-basketball and womens-basketball can differ
  # (e.g. women's coverage may start in a different year).
  # NOTE: this observer ONLY touches the season picker. It must NOT
  # clear the downstream pickers — the downstream observers below are
  # driven by pbp_data() invalidation and repopulate everything
  # themselves. Racing a "clear" message against their repopulate
  # message (both land in the same flush) sometimes applied the clear
  # LAST, leaving the Team/Games pickers frozen empty until the user
  # manually toggled season and team.
  observeEvent(current_sport(), {
    root <- seasons_root_for_sport(current_sport())
    seasons <- sort(
      list.dirs(root, recursive = FALSE, full.names = FALSE),
      decreasing = TRUE
    )
    updatePickerInput(session, "seasonInput",
                      choices = seasons,
                      selected = if (length(seasons)) seasons[1] else character(0))
  }, ignoreInit = FALSE)

  # Sport- and season-aware data source. Re-evaluates whenever either
  # changes; load_pbp_cached() caches per (sport, season) pair so flipping
  # back to a previously-viewed selection is instant. For the first load
  # of a (sport, season) combo we show a progress indicator so the user
  # gets feedback instead of staring at empty dropdowns.
  # Base data = Centre's folder for the selected sport/season. Drives the
  # Team picker (lists Centre + every opponent Centre played).
  pbp_data <- reactive({
    req(input$seasonInput)
    sport <- current_sport()
    season <- input$seasonInput
    key <- pbp_cache_key(sport, "centrecolonels", season)
    df <- if (exists(key, envir = .pbp_cache)) {
      get(key, envir = .pbp_cache)
    } else {
      withProgress(
        message = sprintf("Loading %s · %s",
                          if (!is.null(sport_labels[[sport]])) sport_labels[[sport]] else sport,
                          season),
        detail  = "reading play-by-play files…",
        value   = NULL,
        load_pbp_cached(season, sport = sport)
      )
    }
    validate(need(!is.null(df) && nrow(df) > 0,
                  sprintf("No data found for %s season %s.", sport, season)))
    df
  })

  # Team-aware data. When a non-Centre SAA team is selected, load THAT team's
  # own folder so the Games picker and every tab reflect their full season —
  # not just the one game they played against Centre. Centre and any non-SAA
  # opponent (no folder of their own) fall back to Centre's data.
  team_pbp_data <- reactive({
    req(input$seasonInput, input$TeamInput)
    sport  <- current_sport()
    season <- input$seasonInput
    team   <- input$TeamInput
    folder <- if (team %in% names(TEAM_TO_FOLDER)) unname(TEAM_TO_FOLDER[[team]]) else NA
    if (is.na(folder) || team == "Centre") return(pbp_data())

    key <- pbp_cache_key(sport, folder, season)
    df <- if (exists(key, envir = .pbp_cache)) {
      get(key, envir = .pbp_cache)
    } else {
      withProgress(
        message = sprintf("Loading %s · %s", team, season),
        detail  = "reading their full-season play-by-play…",
        value   = NULL,
        load_pbp_cached(season, sport = sport, school = folder)
      )
    }
    # Folder may not exist for this season (e.g. BSC after leaving the
    # conference) — fall back to the vs-Centre games rather than erroring.
    if (is.null(df) || nrow(df) == 0) return(pbp_data())
    df
  })
  
  # Refresh the Team picker whenever the LOADED DATA changes.
  #
  # The event is pbp_data() — NOT input$seasonInput — because the data
  # invalidates on every sport OR season change, while the season input
  # value sometimes doesn't change at all. Concretely: toggling the
  # sport resets the season picker to the new sport's newest season; if
  # that's the same season string the user already had selected (both
  # sports default to the same year), input$seasonInput never fires and
  # an input-driven observer would leave the Team picker stale/empty —
  # the "frozen pickers" bug. Data-driven invalidation always fires.
  observeEvent(pbp_data(), {
    d <- pbp_data()
    teams <- sort(unique(vctrs::vec_c(d$homeTeam, d$awayTeam)))
    keep <- input$TeamInput
    updatePickerInput(session, "TeamInput",
                      choices = teams,
                      selected = if (!is.null(keep) && keep %in% teams) keep
                                 else if ("Centre" %in% teams) "Centre"
                                 else teams[1])
  }, ignoreInit = FALSE)

  team_data <- reactive({
    req(input$TeamInput)
    team_pbp_data() %>% filter(homeTeam == input$TeamInput | awayTeam == input$TeamInput)
  })

  game_wanted <- reactive({
    req(input$det_game)
    team_pbp_data() %>% filter(game %in% input$det_game)
  })

  # Update game choices whenever the team selection OR the loaded data
  # changes. Keying on the data matters for the same reason as the Team
  # observer above: after a sport/season switch the Team picker often
  # re-selects the same value ("Centre"), so input$TeamInput never
  # changes and a team-only observer would leave the games picker
  # holding the previous season's games (or nothing at all).
  observeEvent(list(team_pbp_data(), input$TeamInput), {
    req(input$TeamInput)
    game_choices <- team_pbp_data() %>%
      filter(homeTeam == input$TeamInput | awayTeam == input$TeamInput) %>%
      pull(game) %>% unique()
    # Preserve any still-valid picks (no-op refires keep the selection);
    # picks from another season/team simply drop out.
    keep <- intersect(input$det_game, game_choices)
    updatePickerInput(session, "det_game",
                      choices = game_choices, selected = keep)
    # The roster picker depends on the chosen games — reset it when the
    # game list rebuilds. It repopulates via its own observer once games
    # are picked. (This replaces the clear the season observer used to
    # send, which raced against repopulation.)
    if (length(keep) == 0) {
      updatePickerInput(session, "PlayerInput",
                        choices = character(0), selected = character(0))
    }
  })

  # Lineup matrix for the selected team across the chosen games. This is the
  # source of truth for "who has shared the floor with whom."
  team_lineup_mat <- reactive({
    req(input$TeamInput, input$det_game)
    team_lineup_matrix(game_wanted(), input$TeamInput)
  })

  # When the team or game(s) change, repopulate the picker with the full
  # roster for those games and clear any previous selection.
  observeEvent(list(input$TeamInput, input$det_game), {
    req(input$TeamInput, input$det_game)
    updatePickerInput(
      session, "PlayerInput",
      choices  = available_teammates(team_lineup_mat(), character(0)),
      selected = character(0)
    )
  }, ignoreInit = TRUE)

  # Cascading filter: every time the user adds/removes a player, narrow the
  # remaining choices to teammates who've been on the floor with ALL of the
  # currently picked players. Already-picked players stay in `choices` so the
  # picker doesn't drop them from the selection.
  observeEvent(input$PlayerInput, {
    req(input$TeamInput, input$det_game)
    picked <- input$PlayerInput
    teammates <- available_teammates(team_lineup_mat(), picked)
    new_choices <- sort(unique(c(picked, teammates)))
    updatePickerInput(
      session, "PlayerInput",
      choices  = new_choices,
      selected = picked
    )
  }, ignoreNULL = FALSE, ignoreInit = TRUE)

  # Reset button: clear the player selection. The cascading observer above
  # (input$PlayerInput) fires automatically when the selection changes to
  # empty and broadens the choice list back to the full roster, so we only
  # need to clear `selected` here — the picker repopulates itself.
  observeEvent(input$resetLineup, {
    updatePickerInput(session, "PlayerInput", selected = character(0))
  })
  PlayerData <- reactive({
    req(input$PlayerInput)
    req(game_wanted())
    selected_players <- input$PlayerInput
    selected_team <- input$TeamInput

    gw <- game_wanted()
    filtered_data <- gw[rows_with_players(gw, selected_players), , drop = FALSE]

    if (nrow(filtered_data) == 0) {
      # No row has all selected players on the same lineup — return an
      # empty frame with the CentreLineup column so downstream code is happy.
      return(filtered_data %>% mutate(CentreLineup = character(0)))
    }

    filtered_data <- filtered_data %>%
      mutate(CentreLineup = build_lineup(
        awayTeam, homeTeam, selected_team,
        awayPlayer1, awayPlayer2, awayPlayer3, awayPlayer4, awayPlayer5,
        homePlayer1, homePlayer2, homePlayer3, homePlayer4, homePlayer5
      ))

    filtered_data
  })
  # Build a summary table across all lineup combinations seen in the selected game(s).
  AllLineupsData <- reactive({
    req(game_wanted())
    selected_team <- input$TeamInput

    game_wanted() %>%
      mutate(
        CentreLineup = build_lineup(
          awayTeam, homeTeam, selected_team,
          awayPlayer1, awayPlayer2, awayPlayer3, awayPlayer4, awayPlayer5,
          homePlayer1, homePlayer2, homePlayer3, homePlayer4, homePlayer5
        )
      ) %>%
      compute_lineup_metrics(selected_team)
  })

  # Shared reactives so the table renderers and their totals UIs see the
  # exact same filtered rows. Otherwise the totals could drift if either
  # were re-derived from a slightly different source.
  # Per-side gate for the lineup tables. The displayed columns cover BOTH
  # OFFRTG and DEFRTG simultaneously, so a lineup needs enough sample on
  # both sides for the row to be statistically meaningful. Require
  # OFFPOSS >= min_poss AND DEFPOSS >= min_poss.
  lineupDataFiltered <- reactive({
    req(input$TeamInput)
    min_poss <- if (is.null(input$min_poss) || is.na(input$min_poss)) 0 else input$min_poss
    compute_lineup_metrics(PlayerData(), input$TeamInput) %>%
      select(-OFFREB, -DEFREB, -opp_OFFREB, -opp_DEFREB) %>%
      filter(OFFPOSS >= min_poss, DEFPOSS >= min_poss)
  })

  lineupsInGameFiltered <- reactive({
    req(input$det_game, input$TeamInput)
    min_poss <- if (is.null(input$min_poss) || is.na(input$min_poss)) 0 else input$min_poss
    AllLineupsData() %>%
      filter(OFFPOSS >= min_poss, DEFPOSS >= min_poss) %>%
      arrange(desc(NETRTG))
  })

  # Builds the "computed totals vs actual final score" line below each
  # lineup table. Sums pointsEarned and pointsAgainst across the displayed
  # rows and compares to the parsed final scores for the selected games.
  render_totals_ui <- function(df_reactive) {
    renderUI({
      df <- df_reactive()
      if (is.null(df) || nrow(df) == 0) return(NULL)

      # "Across rows above" — sums whatever lineups are currently in the
      # visible per-lineup table. For games where the parser couldn't track
      # the on-court 5 (mid-period state-break, see load_pbp() comment),
      # those rows have NA CentreLineup and are filtered out before this
      # table is built — so this number underrepresents the true game total.
      attributed_for     <- sum(df$pointsEarned,  na.rm = TRUE)
      attributed_against <- sum(df$pointsAgainst, na.rm = TRUE)

      # True per-game scoring tally computed directly from the play stream
      # (Team + playType + shotOutcome), independent of lineup tracking.
      # This matches the box score for every game whose play stream is
      # itself complete, regardless of how well lineup tracking worked.
      gw <- game_wanted()
      true_for <- NA_integer_; true_against <- NA_integer_
      if (!is.null(gw) && nrow(gw) > 0 && !is.null(input$TeamInput)) {
        shot_types <- c("layup","jumper","three pointer","dunk","tipin","two pointer")
        lt <- tolower(input$TeamInput)
        row_pts <- dplyr::case_when(
          is.na(gw$shotOutcome) | gw$shotOutcome != "good"               ~ 0L,
          gw$playType == "three pointer"                                  ~ 3L,
          gw$playType %in% c("layup","jumper","dunk","tipin","two pointer") ~ 2L,
          gw$playType == "free throw"                                      ~ 1L,
          TRUE                                                             ~ 0L
        )
        is_team_act <- coalesce(gw$Team == lt, FALSE)
        true_for     <- sum(row_pts[is_team_act], na.rm = TRUE)
        true_against <- sum(row_pts[!is_team_act &
                                    !is.na(gw$Team) & gw$Team != ""],
                            na.rm = TRUE)
      }

      # Real totals from the finalScore column of game_wanted(), summed
      # across the selected games. finalScore is "AWAY-HOME".
      real_team <- NA_integer_; real_opp <- NA_integer_
      if (!is.null(gw) && nrow(gw) > 0 && !is.null(input$TeamInput)) {
        games_meta <- gw %>% distinct(game, finalScore, homeTeam, awayTeam)
        parsed <- t(vapply(seq_len(nrow(games_meta)), function(i) {
          parts <- suppressWarnings(as.integer(strsplit(games_meta$finalScore[i], "-")[[1]]))
          if (length(parts) != 2 || any(is.na(parts))) return(c(NA_integer_, NA_integer_))
          if (games_meta$awayTeam[i] == input$TeamInput) c(parts[1], parts[2])
          else                                            c(parts[2], parts[1])
        }, integer(2)))
        real_team <- sum(parsed[, 1], na.rm = TRUE)
        real_opp  <- sum(parsed[, 2], na.rm = TRUE)
      }

      unattr_for     <- if (!is.na(true_for))     true_for     - attributed_for     else 0
      unattr_against <- if (!is.na(true_against)) true_against - attributed_against else 0
      delta_for      <- if (!is.na(real_team) && !is.na(true_for))     true_for     - real_team else NA
      delta_opp      <- if (!is.na(real_opp)  && !is.na(true_against)) true_against - real_opp  else NA

      # Distinguish two reasons the lineup table's totals can be smaller
      # than the play-stream totals:
      #   (a) min_poss filter — the user gated lineups with fewer than N
      #       total possessions out of the visible table; those points are
      #       in valid lineups, just hidden.
      #   (b) Parser lineup-tracking gap — for the games where the parser
      #       couldn't track the on-court 5 mid-period, those rows have
      #       NA CentreLineup and aren't in any lineup row, displayed or
      #       hidden. The cross-school audit usually shows this at <2pts
      #       per Centre 2023-24 game and ~10-50pts per older-season
      #       game.
      # Compute (b) directly from game_wanted() so we can split the
      # warning into the two real reasons.
      gap_pts_for <- 0
      gap_pts_against <- 0
      if (!is.null(gw) && nrow(gw) > 0 && !is.null(input$TeamInput)) {
        lt <- tolower(input$TeamInput)
        lineup_cols_self <- if (any(coalesce(gw$awayTeam == input$TeamInput, FALSE))) {
          c("awayPlayer1","awayPlayer2","awayPlayer3","awayPlayer4","awayPlayer5")
        } else c("homePlayer1","homePlayer2","homePlayer3","homePlayer4","homePlayer5")
        # The selected team can be home in some games and away in others.
        # Build per-row "selected-team lineup present" flag accordingly.
        is_away_team <- coalesce(gw$awayTeam == input$TeamInput, FALSE)
        is_home_team <- coalesce(gw$homeTeam == input$TeamInput, FALSE)
        has_self_lineup <- rep(TRUE, nrow(gw))
        for (col in c("awayPlayer1","awayPlayer2","awayPlayer3","awayPlayer4","awayPlayer5")) {
          if (col %in% names(gw)) has_self_lineup[is_away_team] <- has_self_lineup[is_away_team] &
            !is.na(gw[[col]][is_away_team])
        }
        for (col in c("homePlayer1","homePlayer2","homePlayer3","homePlayer4","homePlayer5")) {
          if (col %in% names(gw)) has_self_lineup[is_home_team] <- has_self_lineup[is_home_team] &
            !is.na(gw[[col]][is_home_team])
        }
        row_pts2 <- dplyr::case_when(
          is.na(gw$shotOutcome) | gw$shotOutcome != "good"                  ~ 0L,
          gw$playType == "three pointer"                                     ~ 3L,
          gw$playType %in% c("layup","jumper","dunk","tipin","two pointer")  ~ 2L,
          gw$playType == "free throw"                                        ~ 1L,
          TRUE                                                               ~ 0L
        )
        is_team_act2 <- coalesce(gw$Team == lt, FALSE)
        gap_pts_for     <- sum(row_pts2[!has_self_lineup & is_team_act2], na.rm = TRUE)
        gap_pts_against <- sum(row_pts2[!has_self_lineup & !is_team_act2 &
                                        !is.na(gw$Team) & gw$Team != ""], na.rm = TRUE)
      }
      # Whatever's missing from the displayed total beyond the parser gap
      # is the min_poss / no-selection filter portion.
      filtered_for     <- max(0, unattr_for     - gap_pts_for)
      filtered_against <- max(0, unattr_against - gap_pts_against)

      lineup_attribution_note <- if (filtered_for > 0 || filtered_against > 0 ||
                                     gap_pts_for > 0 || gap_pts_against > 0) {
        parts <- list()
        if (filtered_for > 0 || filtered_against > 0) {
          parts[[length(parts) + 1]] <- sprintf(
            "%d / %d in lineups below the min-possessions filter",
            as.integer(filtered_for), as.integer(filtered_against))
        }
        if (gap_pts_for > 0 || gap_pts_against > 0) {
          parts[[length(parts) + 1]] <- sprintf(
            "%d / %d in rows where the parser lost lineup state",
            as.integer(gap_pts_for), as.integer(gap_pts_against))
        }
        tags$span(
          style = "margin-left: 12px; color: #b85c00;",
          sprintf("(%s)", paste(parts, collapse = "; "))
        )
      } else NULL

      tags$div(
        style = "background: #fafafa; border-top: 2px solid #ddd; padding: 8px 12px; margin-top: 6px; font-size: 0.95em;",
        tags$b("Totals across rows above: "),
        sprintf("%s scored %d, opponent scored %d.",
                input$TeamInput %||% "Team", attributed_for, attributed_against),
        lineup_attribution_note,
        tags$br(),
        tags$b("Play-stream totals: "),
        sprintf("%s %d, opponent %d.",
                input$TeamInput %||% "Team",
                if (is.na(true_for)) attributed_for else as.integer(true_for),
                if (is.na(true_against)) attributed_against else as.integer(true_against)),
        if (!is.na(real_team)) tags$span(
          style = "margin-left: 12px; color: #555;",
          sprintf("Actual final-score totals: %s %d, opponent %d (diff %+d / %+d).",
                  input$TeamInput %||% "Team", real_team, real_opp,
                  as.integer(delta_for), as.integer(delta_opp))
        )
      )
    })
  }

  output$lineupData <- renderDataTable({
    df <- lineupDataFiltered()
    datatable(
      df,
      rownames   = FALSE,
      escape     = FALSE,
      extensions = "FixedColumns",
      class      = "stripe hover row-border",
      options = list(
        pageLength      = 15,
        scrollX         = TRUE,
        scrollCollapse  = TRUE,
        fixedColumns    = list(leftColumns = 1),
        autoWidth       = FALSE,
        columnDefs      = lineup_column_defs(0)
      )
    ) %>% add_conditional_formatting(df)
  })
  output$lineupDataTotals <- render_totals_ui(lineupDataFiltered)

  # Lineups-in-Game table — wider than the viewport once every rate stat
  # column is shown, so we enable horizontal scroll and pin the CentreLineup
  # column on the left. The lineup-cell className adds the gold accent so
  # the pinned column is also the visual anchor of the row.
  output$lineupsInGameData <- renderDataTable({
    df <- lineupsInGameFiltered()
    datatable(
      df,
      rownames   = FALSE,
      escape     = FALSE,
      extensions = "FixedColumns",
      class      = "stripe hover row-border",
      options = list(
        pageLength      = 15,
        scrollX         = TRUE,
        scrollCollapse  = TRUE,
        fixedColumns    = list(leftColumns = 1),
        autoWidth       = FALSE,
        columnDefs      = lineup_column_defs(0)
      )
    ) %>% add_conditional_formatting(df)
  })
  output$lineupsInGameDataTotals <- render_totals_ui(lineupsInGameFiltered)

  # Top-5-by-metric leaderboard.
  #
  # Reuses AllLineupsData() (already filtered to the chosen games and run
  # through the same metric helper as everything else), then:
  #   1. Drops lineups under the min-possessions gate so a 3-poss lineup
  #      can't post a "300 OffRtg" headline.
  #   2. Drops rows where the chosen metric is NA/Inf (division by zero on
  #      lineups that never had a chance to record it).
  #   3. Sorts ascending for stats where lower is better (DEFRTG, TOV%),
  #      descending for everything else.
  #   4. Shows the top 5 with a sensible column order so you can compare
  #      the headline metric against the other rate stats at a glance.
  output$topFiveLineups <- renderDataTable({
    req(input$top5_metric)
    df <- AllLineupsData()
    if (is.null(df) || nrow(df) == 0) {
      return(datatable(data.frame(message = "No data yet — pick a team and game(s).")))
    }

    metric   <- input$top5_metric
    min_poss <- if (is.null(input$min_poss) || is.na(input$min_poss)) 0 else input$min_poss

    # Metric-aware possessions gate. The sidebar's min_poss has to mean
    # different things for different metrics — a 13/13 OFFPOSS/DEFPOSS
    # lineup (26 TOTAL_POSS) shouldn't post a noisy 192 OFFRTG under a
    # "min 20" filter. Three classes of metrics:
    #
    #  - offense-only  → gate on OFFPOSS
    #  - defense-only  → gate on DEFPOSS
    #  - multi-side    → gate on BOTH OFFPOSS AND DEFPOSS
    #
    # PACE is the only metric for which combined possessions is the
    # statistically relevant denominator, so it stays on TOTAL_POSS.
    off_side <- c("OFFRTG", "AST_RATIO", "AST_TO", "TOV_PCT",
                  "OREB_RATE", "FG_PCT", "FG3_PCT", "EFG_PCT")
    def_side <- c("DEFRTG", "DREB_RATE")
    both_side <- c("NETRTG", "plus_minus")
    df <- df %>% filter(!is.na(CentreLineup))
    if (metric %in% off_side) {
      df <- df %>% filter(OFFPOSS >= min_poss)
    } else if (metric %in% def_side) {
      df <- df %>% filter(DEFPOSS >= min_poss)
    } else if (metric %in% both_side) {
      df <- df %>% filter(OFFPOSS >= min_poss, DEFPOSS >= min_poss)
    } else {
      # PACE, TIME_MIN, raw totals — combined-possession sample is fine.
      df <- df %>% filter(TOTAL_POSS >= min_poss)
    }
    df <- df %>% filter(!is.na(.data[[metric]]), is.finite(.data[[metric]]))

    if (nrow(df) == 0) {
      return(datatable(data.frame(
        message = sprintf("No lineup meets %d total possessions for this metric.", min_poss)
      )))
    }

    ascending <- metric %in% c("DEFRTG", "TOV_PCT")
    df <- if (ascending) df %>% arrange(.data[[metric]]) else df %>% arrange(desc(.data[[metric]]))

    top_n <- if (is.null(input$top_n) || is.na(input$top_n)) 5 else max(1, as.integer(input$top_n))
    df <- head(df, top_n)
    # Explicit rank column — distinct serial-number identifier for each row
    # (1 = best by the chosen metric). Survives column reordering and
    # ignores DataTables' internal row numbering.
    df$Rank <- seq_len(nrow(df))

    # Column order — headline rate first, then ratings, then RAW counts
    # (points, FGM/FGA, rebounds, assists, TOV) so users can verify the
    # ratings against the underlying data and spot when a flashy number
    # came from a 9-possession sample.
    col_order <- c("Rank", "CentreLineup", metric,
                   # Ratings
                   "OFFRTG", "DEFRTG", "NETRTG", "plus_minus",
                   # Raw scoring
                   "pointsEarned", "pointsAgainst",
                   # Shooting raw + rates
                   "FGM", "FGA", "FG_PCT",
                   "FG3M", "FG3A", "FG3_PCT", "EFG_PCT",
                   # Rebounding raw + rates
                   "OFFREB", "opp_DEFREB", "OREB_RATE",
                   "DEFREB", "opp_OFFREB", "DREB_RATE",
                   # Ball-handling raw + rates
                   "ASSISTS", "TOV", "AST_TO", "AST_RATIO", "TOV_PCT",
                   # Tempo / sample size
                   "PACE", "OFFPOSS", "DEFPOSS", "TOTAL_POSS", "TIME_MIN")
    col_order <- unique(intersect(col_order, names(df)))
    df <- df[, col_order]

    datatable(
      df,
      rownames   = FALSE,
      escape     = FALSE,
      extensions = "FixedColumns",
      class      = "stripe hover row-border",
      options = list(
        dom             = "t",
        pageLength      = top_n,
        ordering        = FALSE,
        scrollX         = TRUE,
        scrollCollapse  = TRUE,
        # Pin Rank + CentreLineup so the identifying columns stay visible
        # as the user scrolls right through ratings/raw stats.
        fixedColumns    = list(leftColumns = 2),
        autoWidth       = FALSE,
        columnDefs      = lineup_column_defs(1)
      )
    ) %>% add_conditional_formatting(df)
  })

  # Group Performance — auto-anchor view.
  #
  # The 3 anchors aren't taken from the sidebar picker. Instead, we
  # compute the 3 players with the most lineup-slot appearances across
  # the selected games — i.e. the team's most-played core — and use
  # those automatically. Counting appearances in team_lineup_mat() is a
  # good proxy for floor time because each row in that matrix is one
  # play-by-play row with the 5 players on the floor at that moment.
  group_anchors <- reactive({
    req(input$TeamInput, input$det_game)
    team_mat <- team_lineup_mat()
    if (is.null(team_mat) || nrow(team_mat) == 0) return(character(0))
    counts <- sort(table(stats::na.omit(as.vector(team_mat))), decreasing = TRUE)
    if (length(counts) < 3) return(character(0))
    sort(names(counts)[1:3])
  })

  output$group_anchors_label <- renderText({
    anchors <- group_anchors()
    if (length(anchors) == 0) return("")
    sprintf("Anchors auto-selected (top 3 by floor time): %s",
            paste(anchors, collapse = ", "))
  })

  output$groupPerformanceData <- renderDataTable({
    req(input$TeamInput, input$det_game, input$group_metric)
    selected_team <- input$TeamInput
    anchors       <- group_anchors()
    if (length(anchors) < 3) {
      return(datatable(data.frame(
        message = "Need at least 3 distinct players in the selected games to form anchors.")))
    }

    # Same filter logic as PlayerData(), but driven by the auto-anchors
    # rather than the sidebar picker so this tab works independently.
    filtered <- game_wanted() %>%
      mutate(
        CentreLineup = build_lineup(
          awayTeam, homeTeam, selected_team,
          awayPlayer1, awayPlayer2, awayPlayer3, awayPlayer4, awayPlayer5,
          homePlayer1, homePlayer2, homePlayer3, homePlayer4, homePlayer5
        )
      )
    filtered <- filtered[rows_with_players(filtered, anchors), , drop = FALSE]

    if (nrow(filtered) == 0) {
      return(datatable(data.frame(
        message = "The 3 auto-anchored players never shared the floor in these games.")))
    }

    df <- compute_lineup_metrics(filtered, selected_team)
    metric   <- input$group_metric
    min_poss <- if (is.null(input$min_poss) || is.na(input$min_poss)) 0 else input$min_poss

    # Metric-aware per-side gate (matches Top Lineups behavior).
    off_side  <- c("OFFRTG", "AST_RATIO", "AST_TO", "TOV_PCT",
                   "OREB_RATE", "FG_PCT", "FG3_PCT", "EFG_PCT")
    def_side  <- c("DEFRTG", "DREB_RATE")
    both_side <- c("NETRTG", "plus_minus")
    df <- df %>% filter(!is.na(CentreLineup))
    if (metric %in% off_side) {
      df <- df %>% filter(OFFPOSS >= min_poss)
    } else if (metric %in% def_side) {
      df <- df %>% filter(DEFPOSS >= min_poss)
    } else if (metric %in% both_side) {
      df <- df %>% filter(OFFPOSS >= min_poss, DEFPOSS >= min_poss)
    } else {
      df <- df %>% filter(TOTAL_POSS >= min_poss)
    }
    df <- df %>% filter(!is.na(.data[[metric]]), is.finite(.data[[metric]]))

    if (nrow(df) == 0) {
      return(datatable(data.frame(
        message = sprintf("No lineups containing the 3 anchors meet %d possessions for this metric.",
                          min_poss))))
    }

    # Split the lineup into two explicit columns:
    #   - "Anchors": the 3 auto-selected players (identical across rows).
    #   - "Others":  the 2 varying slots (the actual point of comparison).
    anchor_str <- paste(sort(anchors), collapse = ", ")
    df$Anchors <- anchor_str
    df$Others <- vapply(df$CentreLineup, function(s) {
      members <- strsplit(s, ", ", fixed = TRUE)[[1]]
      paste(sort(setdiff(members, anchors)), collapse = ", ")
    }, character(1))

    # Lower-is-better metrics sort ascending.
    ascending <- metric %in% c("DEFRTG", "TOV_PCT")
    df <- if (ascending) df %>% arrange(.data[[metric]]) else df %>% arrange(desc(.data[[metric]]))
    df$Rank <- seq_len(nrow(df))

    col_order <- c("Rank", "Anchors", "Others", metric,
                   "OFFRTG", "DEFRTG", "NETRTG", "plus_minus",
                   "pointsEarned", "pointsAgainst",
                   "FGM", "FGA", "FG_PCT",
                   "FG3M", "FG3A", "FG3_PCT", "EFG_PCT",
                   "OFFREB", "opp_DEFREB", "OREB_RATE",
                   "DEFREB", "opp_OFFREB", "DREB_RATE",
                   "ASSISTS", "TOV", "AST_TO", "AST_RATIO", "TOV_PCT",
                   "PACE", "OFFPOSS", "DEFPOSS", "TOTAL_POSS", "TIME_MIN")
    col_order <- unique(intersect(col_order, names(df)))
    df <- df[, col_order]

    datatable(
      df,
      rownames   = FALSE,
      escape     = FALSE,
      extensions = "FixedColumns",
      class      = "stripe hover row-border",
      options = list(
        pageLength      = 15,
        ordering        = TRUE,
        scrollX         = TRUE,
        scrollCollapse  = TRUE,
        # Pin Rank + Anchors + Others so the trio + the two varying slots
        # always remain visible while the user scrolls across the stats.
        fixedColumns    = list(leftColumns = 3),
        autoWidth       = FALSE,
        # Anchors (col 1) and Others (col 2) are both player-list cells —
        # render both as pill columns.
        columnDefs      = lineup_column_defs(c(1, 2))
      )
    ) %>% add_conditional_formatting(df)
  })

  # Player Combination — per-lineup breakdown for each N-player subgroup.
  #
  # NOT pooled. For each distinct N-player group that's actually played,
  # the table lists every specific 5-man lineup the group appeared in as
  # its own row, with THAT LINEUP'S OWN metrics (not aggregated across
  # appearances). So a trio that played in 5 different 5-man lineups gets
  # 5 rows — one per lineup — each row showing how the trio's parent
  # 5-man unit performed in that specific configuration. Sort by "Group"
  # to cluster every appearance of the same subgroup together.
  output$combinationData <- renderDataTable({
    req(input$TeamInput, input$det_game, input$combo_size, input$combo_metric)
    selected_team <- input$TeamInput
    n <- as.integer(input$combo_size)
    validate(need(n >= 1 && n <= 4, "Group size must be 1-4."))

    # Build a per-row CentreLineup so the subgroup aggregator can expand
    # by 5-man membership. Action stats are credited only to the subgroup
    # members within each lineup; possessions/time aggregate to the
    # subgroup's total floor presence across every lineup they appeared in.
    base <- game_wanted() %>%
      mutate(
        CentreLineup = build_lineup(
          awayTeam, homeTeam, selected_team,
          awayPlayer1, awayPlayer2, awayPlayer3, awayPlayer4, awayPlayer5,
          homePlayer1, homePlayer2, homePlayer3, homePlayer4, homePlayer5
        )
      )
    df <- compute_subgroup_pooled_metrics(base, selected_team, n)
    if (is.null(df) || nrow(df) == 0) {
      return(datatable(data.frame(
        message = "No data — pick a team and at least one game in the sidebar.")))
    }

    metric   <- input$combo_metric
    min_poss <- if (is.null(input$min_poss) || is.na(input$min_poss)) 0 else input$min_poss

    # Metric-aware per-side gate (matches Top Lineups / Group Performance).
    off_side  <- c("OFFRTG", "AST_RATIO", "AST_TO", "TOV_PCT",
                   "OREB_RATE", "FG_PCT", "FG3_PCT", "EFG_PCT")
    def_side  <- c("DEFRTG", "DREB_RATE")
    both_side <- c("NETRTG", "plus_minus")
    df <- df %>% filter(!is.na(Group))
    if (metric %in% off_side) {
      df <- df %>% filter(OFFPOSS >= min_poss)
    } else if (metric %in% def_side) {
      df <- df %>% filter(DEFPOSS >= min_poss)
    } else if (metric %in% both_side) {
      df <- df %>% filter(OFFPOSS >= min_poss, DEFPOSS >= min_poss)
    } else {
      df <- df %>% filter(TOTAL_POSS >= min_poss)
    }
    df <- df %>% filter(!is.na(.data[[metric]]), is.finite(.data[[metric]]))

    if (nrow(df) == 0) {
      return(datatable(data.frame(
        message = sprintf("No %d-player groups meet %d possessions for this metric.",
                          n, min_poss))))
    }

    # Sort by chosen metric (ascending for lower-is-better).
    ascending <- metric %in% c("DEFRTG", "TOV_PCT")
    df <- if (ascending) df %>% arrange(.data[[metric]]) else df %>% arrange(desc(.data[[metric]]))
    df$Rank <- seq_len(nrow(df))

    # Column order: Rank, Group (the N-player subset whose actions are
    # being credited), then the chosen metric, ratings, raw counts, and
    # finally context columns. n_lineups shows how many distinct 5-man
    # lineups the subgroup appeared in (sample-size context).
    col_order <- c("Rank", "Group", metric,
                   "OFFRTG", "DEFRTG", "NETRTG", "plus_minus",
                   "pointsEarned", "pointsAgainst",
                   "FGM", "FGA", "FG_PCT",
                   "FG3M", "FG3A", "FG3_PCT", "EFG_PCT",
                   "OFFREB", "opp_DEFREB", "OREB_RATE",
                   "DEFREB", "opp_OFFREB", "DREB_RATE",
                   "ASSISTS", "TOV", "AST_TO", "AST_RATIO", "TOV_PCT",
                   "PACE", "OFFPOSS", "DEFPOSS", "TOTAL_POSS", "TIME_MIN",
                   "n_lineups")
    col_order <- unique(intersect(col_order, names(df)))
    df <- df[, col_order]

    datatable(
      df,
      rownames   = FALSE,
      escape     = FALSE,
      extensions = "FixedColumns",
      class      = "stripe hover row-border",
      options = list(
        pageLength      = 15,
        ordering        = TRUE,
        scrollX         = TRUE,
        scrollCollapse  = TRUE,
        # Pin Rank + Group so the subgroup identity stays visible while
        # the user scrolls horizontally across ratings/raw stats.
        fixedColumns    = list(leftColumns = 2),
        autoWidth       = FALSE,
        # Group (col 1) is the player-list cell.
        columnDefs      = lineup_column_defs(1)
      )
    ) %>% add_conditional_formatting(df)
  })

  # ---- Conference comparison ----------------------------------------------
  # Whole-conference season table for the selected sport + season. Driven by
  # the data (current_sport + season), not the Team/Game pickers, so it shows
  # every SAA team regardless of which team the user is otherwise viewing.
  conference_data <- reactive({
    req(input$seasonInput)
    sport <- current_sport()
    conf_only <- identical(input$conf_scope, "conf")
    key <- paste0(sport, "::", input$seasonInput, "::",
                  if (conf_only) "conf" else "all")
    if (exists(key, envir = .conf_cache)) {
      compute_conference_table(sport, input$seasonInput, conf_only)
    } else {
      withProgress(
        message = "Building conference comparison",
        detail  = "aggregating every SAA team's season…",
        value   = NULL,
        compute_conference_table(sport, input$seasonInput, conf_only)
      )
    }
  })

  # Conference visualization — Goldsberry-style logo scatter (default), or a
  # bar ranking. White-background Centre-themed panel with a bold black
  # average crosshair on the scatter. Rendering lives in build_conference_plot().
  output$conferencePlot <- renderPlot({
    d <- conference_data()
    validate(need(!is.null(d) && nrow(d) > 0,
                  "No conference data for this sport / season yet."))
    viz <- input$conf_viz %||% "scatter"
    xm  <- input$conf_x %||% "OFFRTG"
    ym  <- input$conf_y %||% "DEFRTG"
    mm  <- input$conf_metric %||% "NETRTG"
    p <- build_conference_plot(d, viz, xm, ym, mm)
    validate(need(!is.null(p), "Not enough data to draw this chart."))
    p
  }, bg = "#FFFFFF", res = 96)

  # Hover tooltip for the scatter — since the logos are static images, this is
  # how you identify them (especially where logos overlap). Finds the nearest
  # team to the cursor in normalized metric space and shows its name + the two
  # plotted values in a small card that follows the mouse.
  output$conf_hover_tip <- renderUI({
    hv <- input$conf_hover
    if (is.null(hv) || (input$conf_viz %||% "scatter") != "scatter") return(NULL)
    d <- conference_data()
    xm <- input$conf_x %||% "OFFRTG"; ym <- input$conf_y %||% "DEFRTG"
    if (is.null(d) || nrow(d) == 0 || !all(c(xm, ym) %in% names(d))) return(NULL)
    xr <- diff(range(d[[xm]], na.rm = TRUE)); yr <- diff(range(d[[ym]], na.rm = TRUE))
    if (!is.finite(xr) || xr == 0) xr <- 1; if (!is.finite(yr) || yr == 0) yr <- 1
    dist <- sqrt(((d[[xm]] - hv$x) / xr)^2 + ((d[[ym]] - hv$y) / yr)^2)
    i <- which.min(dist)
    if (length(i) == 0 || !is.finite(dist[i]) || dist[i] > 0.09) return(NULL)  # not over a logo
    row <- d[i, ]
    # Position the card next to the cursor (pixel coords within the plot div).
    left <- round(hv$coords_css$x) + 14
    top  <- round(hv$coords_css$y) + 8
    div(class = "conf-tip",
        style = sprintf("left:%dpx; top:%dpx;", left, top),
        div(class = "conf-tip__team", row$Team),
        div(class = "conf-tip__row",
            tags$span(METRIC_LABEL[[xm]] %||% xm),
            tags$b(formatC(row[[xm]], format = "f", digits = 1))),
        div(class = "conf-tip__row",
            tags$span(METRIC_LABEL[[ym]] %||% ym),
            tags$b(formatC(row[[ym]], format = "f", digits = 1))),
        div(class = "conf-tip__row",
            tags$span("Record"),
            tags$b(sprintf("%d-%d", row$Wins, row$Losses))))
  })

  # Ranked conference table with the same conditional-formatting heatmap as
  # the lineup tables, plus a gold left-stripe on the Centre row.
  output$conferenceTable <- renderDataTable({
    d <- conference_data()
    validate(need(!is.null(d) && nrow(d) > 0,
                  "No conference data for this sport / season yet."))
    metric <- input$conf_metric %||% "NETRTG"
    ascending <- metric %in% c("DEFRTG", "TOV_PCT")
    d <- if (ascending) d %>% arrange(.data[[metric]])
         else            d %>% arrange(desc(.data[[metric]]))
    d$Rank <- seq_len(nrow(d))

    # Data-confidence badge: green check when the team's season totals
    # reconcile to its box scores, amber warning (with the gap in the
    # tooltip) when they don't. Built before column subsetting so we can
    # read recon_gap / poss_skew, then rendered as HTML (escape = FALSE).
    if (all(c("reliable", "recon_gap", "poss_skew") %in% names(d))) {
      d$Data <- ifelse(
        d$reliable,
        "<span style='color:#1C7C43' title='Season totals reconcile to box scores'>&#10004;</span>",
        sprintf(paste0("<span style='color:#B23A2E' ",
                       "title='Off box score by %d pts; off/def possession skew %+d. ",
                       "Rates may be slightly distorted.'>&#9888;</span>"),
                d$recon_gap, d$poss_skew))
    }

    cols <- c("Rank", "Team", "Data", "Games", "Wins", "Losses",
              CONF_RATE_COLS, "pointsEarned", "pointsAgainst")
    cols <- intersect(cols, names(d))
    d <- d[, cols]

    centre_row <- which(d$Team == "Centre")
    dt <- datatable(
      d, rownames = FALSE, escape = FALSE,
      extensions = "FixedColumns",
      class = "stripe hover row-border",
      options = list(
        pageLength     = 12,
        dom            = "t",
        ordering       = TRUE,
        scrollX        = TRUE,
        scrollCollapse = TRUE,
        fixedColumns   = list(leftColumns = 2),
        autoWidth      = FALSE,
        columnDefs     = list(
          # Data badge (col index 2) centered; everything else right-aligned.
          list(targets = if ("Data" %in% names(d)) 2 else integer(0),
               className = "dt-center", orderable = FALSE),
          list(targets = "_all", className = "dt-right")
        )
      )
    ) %>% add_conditional_formatting(d)

    # Gold left-stripe + bold on the Centre row so it's instantly findable.
    if (length(centre_row) == 1) {
      dt <- dt %>% formatStyle(
        "Team", target = "row",
        fontWeight = styleEqual("Centre", "700"),
        backgroundColor = styleEqual("Centre", "#FFF8DD"),
        boxShadow = styleEqual("Centre", "inset 4px 0 0 0 #FFCD00")
      )
    }
    dt
  })

  # ---- Conference LINEUPS comparison ---------------------------------------
  conf_lineups_all <- reactive({
    req(input$seasonInput)
    sport <- current_sport()
    conf_only <- identical(input$conf_lu_scope, "conf")
    key <- paste0(sport, "::", input$seasonInput, "::",
                  if (conf_only) "conf" else "all")
    if (exists(key, envir = .conf_lu_cache)) {
      compute_conference_lineups(sport, input$seasonInput, conf_only)
    } else {
      withProgress(
        message = "Building conference lineups",
        detail  = "aggregating every team's five-man units…",
        value   = NULL,
        compute_conference_lineups(sport, input$seasonInput, conf_only)
      )
    }
  })

  # Keep the team filter populated with the teams actually present.
  observeEvent(conf_lineups_all(), {
    d <- conf_lineups_all()
    teams <- if (is.null(d)) character(0) else sort(unique(d$Team))
    sel <- if (!is.null(input$conf_lu_team) && input$conf_lu_team %in% c("All teams", teams))
             input$conf_lu_team else "All teams"
    updatePickerInput(session, "conf_lu_team",
                      choices = c("All teams", teams), selected = sel)
  }, ignoreNULL = FALSE)

  # The filtered + ranked lineup set shared by the headline and the table.
  conf_lineups_view <- reactive({
    d <- conf_lineups_all()
    if (is.null(d) || nrow(d) == 0) return(NULL)
    mp <- if (is.null(input$conf_lu_minposs) || is.na(input$conf_lu_minposs)) 0
          else input$conf_lu_minposs
    metric <- input$conf_lu_metric %||% "NETRTG"
    d <- d %>% filter(OFFPOSS >= mp, DEFPOSS >= mp,
                      !is.na(.data[[metric]]), is.finite(.data[[metric]]))
    if (nrow(d) == 0) return(d)
    ascending <- metric %in% c("DEFRTG", "TOV_PCT")
    if (ascending) d %>% arrange(.data[[metric]]) else d %>% arrange(desc(.data[[metric]]))
  })

  # Headline: conference's best lineup for the chosen metric vs Centre's best.
  # Render a "lastname,first, lastname,first" lineup string as the same gold
  # player pills used in the tables, so names stay recognizable in the
  # headline (instead of a comma-stripped lowercase blob).
  lineup_pills_html <- function(s) {
    if (is.null(s) || is.na(s) || s == "") return("")
    players <- strsplit(s, ", ", fixed = TRUE)[[1]]
    paste0(sprintf("<span class='player-pill'>%s</span>", players), collapse = "")
  }

  output$confLineupHeadline <- renderUI({
    d <- conf_lineups_view()
    if (is.null(d) || nrow(d) == 0)
      return(HTML("<em>No lineups meet the minimum-possessions filter for this metric.</em>"))
    metric <- input$conf_lu_metric %||% "NETRTG"
    mlab   <- METRIC_LABEL[[metric]] %||% metric

    # One clean row: pills, then a metric badge, then the possession count.
    row_html <- function(row) paste0(
      "<div class='lu-row'>",
      lineup_pills_html(row$CentreLineup),
      sprintf("<span class='lu-metric'>%s %s</span>",
              mlab, formatC(row[[metric]], format = "f", digits = 1)),
      sprintf("<span class='lu-poss'>%d / %d poss</span>",
              row$OFFPOSS, row$DEFPOSS),
      "</div>")

    best       <- d[1, ]
    centre_idx <- which(d$Team == "Centre")
    best_is_centre <- length(centre_idx) > 0 && centre_idx[1] == 1

    parts <- paste0(
      "<div class='card-soft lu-headline'>",
      "<div class='lu-block'>",
      "<div class='lu-label'>Best lineup in conference</div>",
      sprintf("<div class='lu-team%s'>%s</div>",
              if (best$Team == "Centre") " lu-team--centre" else "", best$Team),
      row_html(best), "</div>")

    if (!best_is_centre && length(centre_idx) > 0) {
      cb <- d[centre_idx[1], ]
      parts <- paste0(parts,
        "<div class='lu-block'>",
        sprintf("<div class='lu-label'>Centre's best &nbsp;<span class='lu-rank'>#%d of %d</span></div>",
                centre_idx[1], nrow(d)),
        row_html(cb), "</div>")
    } else if (best_is_centre) {
      parts <- paste0(parts,
        "<div class='lu-leader'>Conference leader</div>")
    }
    HTML(paste0(parts, "</div>"))
  })

  output$conferenceLineups <- renderDataTable({
    d <- conf_lineups_view()
    validate(need(!is.null(d) && nrow(d) > 0,
                  "No lineups meet the minimum-possessions filter for this metric."))
    if (!is.null(input$conf_lu_team) && input$conf_lu_team != "All teams") {
      d <- d %>% filter(Team == input$conf_lu_team)
    }
    topn <- if (is.null(input$conf_lu_topn) || is.na(input$conf_lu_topn)) 25
            else max(1, as.integer(input$conf_lu_topn))
    d <- head(d, topn)
    d$Rank <- seq_len(nrow(d))
    # Mark lineups from teams whose season data didn't fully reconcile.
    d$Team <- ifelse(d$reliable, d$Team, paste0(d$Team, " *"))

    cols <- c("Rank", "Team", "CentreLineup", CONF_RATE_COLS,
              "OFFPOSS", "DEFPOSS", "pointsEarned", "pointsAgainst")
    cols <- intersect(cols, names(d))
    d <- d[, cols]
    names(d)[names(d) == "CentreLineup"] <- "Lineup"

    centre_rows <- grep("^Centre", d$Team)
    dt <- datatable(
      d, rownames = FALSE, escape = FALSE,
      extensions = "FixedColumns",
      class = "stripe hover row-border",
      options = list(
        pageLength = topn, dom = "t", ordering = TRUE,
        scrollX = TRUE, scrollCollapse = TRUE,
        fixedColumns = list(leftColumns = 3), autoWidth = FALSE,
        columnDefs = lineup_column_defs(2)   # Lineup is column index 2
      )
    ) %>% add_conditional_formatting(d)

    if (length(centre_rows)) {
      dt <- dt %>% formatStyle(
        "Team", target = "row",
        backgroundColor = styleEqual(d$Team[centre_rows],
                                     rep("#FFF8DD", length(centre_rows))),
        boxShadow = styleEqual(d$Team[centre_rows],
                               rep("inset 4px 0 0 0 #FFCD00", length(centre_rows)))
      )
    }
    dt
  })

  # Game-facts panel — shows date / matchup / location / final score for
  # each selected game (or an aggregate when multiple games are picked).
  # Reads directly from game_wanted() so it's always in sync with the
  # sidebar selection.
  output$gameFacts <- renderUI({
    if (is.null(input$det_game) || length(input$det_game) == 0) {
      return(HTML("<em>Pick at least one game in the sidebar to see its details.</em>"))
    }
    gw <- game_wanted()
    if (is.null(gw) || nrow(gw) == 0) return(HTML("<em>No data for the selected game(s).</em>"))

    facts <- gw %>%
      distinct(game, gameDate, homeTeam, awayTeam, gameLocation, finalScore)

    # finalScore is "AWAY-HOME" in the source CSVs.
    parse_pts <- function(fs) {
      parts <- suppressWarnings(as.integer(strsplit(fs, "-")[[1]]))
      if (length(parts) != 2 || any(is.na(parts))) return(c(NA, NA))
      parts
    }
    rows <- vapply(seq_len(nrow(facts)), function(i) {
      pts <- parse_pts(facts$finalScore[i])
      away_pts <- pts[1]; home_pts <- pts[2]
      sprintf(
        paste0("<tr>",
               "<td style='padding:2px 8px;'>%s</td>",
               "<td style='padding:2px 8px;'>%s @ %s</td>",
               "<td style='padding:2px 8px;'>%s</td>",
               "<td style='padding:2px 8px;text-align:right;'>%s %d &mdash; %s %d</td>",
               "<td style='padding:2px 8px;text-align:right;'>Total: %d</td>",
               "</tr>"),
        facts$gameDate[i] %||% "",
        facts$awayTeam[i] %||% "",
        facts$homeTeam[i] %||% "",
        facts$gameLocation[i] %||% "",
        facts$awayTeam[i] %||% "", as.integer(away_pts),
        facts$homeTeam[i] %||% "", as.integer(home_pts),
        as.integer((away_pts %||% 0) + (home_pts %||% 0))
      )
    }, character(1))

    HTML(paste0(
      "<table style='width:100%; font-size: 0.95em;'>",
      "<thead><tr style='text-align:left;color:#666;'>",
      "<th style='padding:2px 8px;'>Date</th>",
      "<th style='padding:2px 8px;'>Matchup</th>",
      "<th style='padding:2px 8px;'>Location</th>",
      "<th style='padding:2px 8px;text-align:right;'>Final score</th>",
      "<th style='padding:2px 8px;text-align:right;'>Total points</th>",
      "</tr></thead><tbody>",
      paste(rows, collapse = ""),
      "</tbody></table>"
    ))
  })

  output$summary <- renderText({
    selected_team <- input$TeamInput

    player_data <- PlayerData() %>%
      mutate(
        pointsEarned  = if_else(possTeam == tolower(selected_team) & teamChanged == 1, possPoints, 0),
        pointsAgainst = if_else(possTeam != tolower(selected_team) & teamChanged == 1, possPoints, 0),
        off_poss = if_else(possTeam == tolower(selected_team) & possStart == 1, possStart, 0),
        def_poss = if_else(possTeam != tolower(selected_team) & possStart == 1, possStart, 0),
        assists  = if_else(possTeam == tolower(selected_team), ASSIST, 0),
        oreb     = if_else(possTeam == tolower(selected_team), OREB, 0),
        dreb     = if_else(possTeam == tolower(selected_team), DREB, 0),
        op_oreb  = if_else(possTeam != tolower(selected_team), OREB, 0),
        op_dreb  = if_else(possTeam != tolower(selected_team), DREB, 0),
        time_sec = elapsed_sec   # use the clock-derived per-row elapsed time
      ) %>%
      summarise(
        total_pointsEarned  = sum(pointsEarned,  na.rm = TRUE),
        total_pointsAgainst = sum(pointsAgainst, na.rm = TRUE),
        total_OFFPOSS       = sum(off_poss,       na.rm = TRUE),
        total_DEFPOSS       = sum(def_poss,       na.rm = TRUE),
        total_OFFRTG        = round(total_pointsEarned  / total_OFFPOSS * 100, 1),
        total_DEFRTG        = round(total_pointsAgainst / total_DEFPOSS * 100, 1),
        total_NETRTG        = round(total_OFFRTG - total_DEFRTG, 1),
        ASSISTS             = sum(assists, na.rm = TRUE),
        AST_RATIO           = round(ASSISTS / total_OFFPOSS * 100, 1),
        OFFREB              = sum(oreb,    na.rm = TRUE),
        DEFREB              = sum(dreb,    na.rm = TRUE),
        OREB_RATE           = round(OFFREB / (OFFREB + sum(op_dreb, na.rm = TRUE)) * 100, 1),
        DREB_RATE           = round(DEFREB / (DEFREB + sum(op_oreb, na.rm = TRUE)) * 100, 1),
        TIME_MIN            = round(sum(time_sec, na.rm = TRUE) / 60, 1),
        total_plus_minus    = total_pointsEarned - total_pointsAgainst
      )

    sprintf(
      "OffRtg %.1f | DefRtg %.1f | NetRtg %.1f | +/- %d | OffPoss %d | DefPoss %d | Ast %d | AstRatio %.1f | OREB%% %.1f | DREB%% %.1f | %.1f min",
      player_data$total_OFFRTG, player_data$total_DEFRTG, player_data$total_NETRTG,
      as.integer(player_data$total_plus_minus),
      as.integer(player_data$total_OFFPOSS), as.integer(player_data$total_DEFPOSS),
      as.integer(player_data$ASSISTS), player_data$AST_RATIO,
      player_data$OREB_RATE, player_data$DREB_RATE,
      player_data$TIME_MIN
    )
  })
  output$allAwayData <- renderDataTable({
    PlayerData() %>% select(awayPlayer1, awayPlayer2, awayPlayer3, awayPlayer4, awayPlayer5, everything())
  })
  
  output$allHomeData <- renderDataTable({
    PlayerData() %>% select(homePlayer1, homePlayer2, homePlayer3, homePlayer4, homePlayer5, everything())
  })

  # Keep every tab's renderer active even when the user is on a different
  # tab. Shiny's default is to SUSPEND hidden output renderers, so the
  # first time you click a new tab it re-runs the whole expression — that
  # feels like a "buttons appear slowly" pause. Forcing suspendWhenHidden
  # to FALSE means the renderers stay warm: tab switches just swap the
  # already-computed HTML in. Costs a small amount of RAM per session
  # but is invisible at the user level.
  for (oid in c("lineupData", "lineupDataTotals",
                "lineupsInGameData", "lineupsInGameDataTotals",
                "topFiveLineups",
                "groupPerformanceData", "group_anchors_label",
                "combinationData",
                "conferencePlot", "conferenceTable", "conf_hover_tip",
                "confLineupHeadline", "conferenceLineups",
                "allAwayData", "allHomeData",
                "gameFacts", "summary")) {
    outputOptions(output, oid, suspendWhenHidden = FALSE)
  }
}

shinyApp(ui = ui, server = server)
