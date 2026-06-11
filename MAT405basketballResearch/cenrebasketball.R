library(shiny)
library(ggplot2)
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

  # Build the (subgroup, row) expansion. flat_combos[i] is the subgroup
  # vector for expanded row i; origin_idx[i] is the index back into df.
  members_list <- strsplit(df$CentreLineup, ", ", fixed = TRUE)
  flat_combos <- list()
  origin_idx <- integer(0)
  for (i in seq_along(members_list)) {
    m <- members_list[[i]]
    if (length(m) < n) next
    combos <- combn(m, n, simplify = FALSE)
    flat_combos <- c(flat_combos, combos)
    origin_idx <- c(origin_idx, rep(i, length(combos)))
  }
  if (length(flat_combos) == 0) return(NULL)

  df_exp <- df[origin_idx, , drop = FALSE]
  df_exp$Group  <- vapply(flat_combos,
                          function(x) paste(sort(x), collapse = ", "),
                          character(1))
  df_exp$Lineup <- df_exp$CentreLineup

  # The "is the row's actor a member of THIS subgroup?" flag.
  in_sub <- logical(nrow(df_exp))
  for (i in seq_len(nrow(df_exp))) {
    p <- df_exp$Player[i]
    in_sub[i] <- !is.na(p) && p != "" && p %in% flat_combos[[i]]
  }
  df_exp$.in_sub <- in_sub

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

build_lineup <- function(away_team, home_team, selected_team,
                         a1, a2, a3, a4, a5,
                         h1, h2, h3, h4, h5) {
  n <- length(away_team)
  if (n == 0) return(character(0))
  away_mat <- cbind(a1, a2, a3, a4, a5)
  home_mat <- cbind(h1, h2, h3, h4, h5)
  away_str <- apply(away_mat, 1, function(x) paste(sort(x), collapse = ", "))
  home_str <- apply(home_mat, 1, function(x) paste(sort(x), collapse = ", "))
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
  s <- trimws(s)

  # Centre-specific aliases. Only fires for exact matches.
  centre_aliases <- c("Centre College", "Centrem", "Centremb")
  s[s %in% centre_aliases] <- "Centre"

  s[na_mask] <- NA_character_
  s
}

# Sport toggle support. The project root contains one folder per sport
# (mens-basketball / womens-basketball); each holds an SAA/<school>/pbp
# tree with one folder per season. The seasons picker is rebuilt whenever
# the sport changes — see seasons_root_for_sport() and load_pbp().
project_root <- "/Users/shreyup/CentreBasketballLineupAnalysis"

# Per-sport season root. Falls back to the legacy (no-sport) layout when
# the sport-specific directory isn't present, so a single-sport install
# keeps working without changes.
seasons_root_for_sport <- function(sport) {
  cand <- file.path(project_root, sport, "SAA", "centrecolonels", "pbp")
  if (dir.exists(cand)) return(cand)
  legacy <- file.path(project_root, "SAA", "centrecolonels", "pbp")
  legacy
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
load_pbp <- function(season, sport = NULL) {
  base <- if (!is.null(sport)) seasons_root_for_sport(sport) else seasons_root
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
# is instant — the CSV parse happens once per (sport, season) per process.
# Keyed by "<sport>::<season>" so men's and women's data don't collide.
.pbp_cache <- new.env(parent = emptyenv())
load_pbp_cached <- function(season, sport = NULL) {
  key <- if (!is.null(sport)) paste0(sport, "::", season) else season
  if (!exists(key, envir = .pbp_cache)) {
    assign(key, load_pbp(season, sport = sport), envir = .pbp_cache)
  }
  get(key, envir = .pbp_cache)
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
      table.dataTable tbody td { padding: 8px 9px; border-top: 1px solid var(--line) !important; }
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
      .player-pill {
        display: inline-block;
        background: #FFFFFF;
        color: var(--ink);
        /* Neutral gray ring by default — same warm-gray as the table
           grid lines — so the pill shape is visible but the column reads
           as quiet. The gold ring only fires when the row is hovered. */
        border: 1px solid #d0d0cb;
        border-radius: 999px;
        padding: 2px 9px;
        margin: 2px 3px 2px 0;
        font-family: 'Barlow Condensed', 'DM Sans', sans-serif;
        font-weight: 600;
        font-size: 12px;
        letter-spacing: 0.4px;
        text-transform: uppercase;
        white-space: nowrap;
        line-height: 1.35;
        transition: border-color 0.12s, background 0.12s, color 0.12s;
      }
      /* Row-level hover: every pill in the row picks up the gold ring so
         the whole lineup reads as a highlighted unit. */
      table.dataTable tbody tr:hover .player-pill {
        border-color: var(--gold);
      }
      /* Per-pill hover: dial up the contrast on the specific name the
         user is pointing at, so coaches can pick out individuals inside
         a hovered lineup. */
      .player-pill:hover {
        background: var(--black);
        color: var(--gold);
        border-color: var(--black);
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
        inputId = "det_game", label = "Game(s)",
        choices = NULL, selected = NULL, multiple = TRUE, width = "100%",
        options = list(`live-search` = TRUE, `actions-box` = TRUE,
                       `selected-text-format` = "count > 2")
      )
    ),
    div(class = "filter-item",
      pickerInput(
        inputId = "PlayerInput", label = "Player(s)",
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
  observeEvent(current_sport(), {
    root <- seasons_root_for_sport(current_sport())
    seasons <- sort(
      list.dirs(root, recursive = FALSE, full.names = FALSE),
      decreasing = TRUE
    )
    updatePickerInput(session, "seasonInput",
                      choices = seasons,
                      selected = if (length(seasons)) seasons[1] else character(0))
    # Clear downstream pickers — anything they showed was for the
    # previous sport's data.
    updatePickerInput(session, "TeamInput",   choices = character(0), selected = character(0))
    updatePickerInput(session, "det_game",    choices = character(0), selected = character(0))
    updatePickerInput(session, "PlayerInput", choices = character(0), selected = character(0))
  }, ignoreInit = FALSE)

  # Sport- and season-aware data source. Re-evaluates whenever either
  # changes; load_pbp_cached() caches per (sport, season) pair so flipping
  # back to a previously-viewed selection is instant. For the first load
  # of a (sport, season) combo we show a progress indicator so the user
  # gets feedback instead of staring at empty dropdowns.
  pbp_data <- reactive({
    req(input$seasonInput)
    sport <- current_sport()
    season <- input$seasonInput
    key <- paste0(sport, "::", season)
    df <- if (exists(key, envir = .pbp_cache)) {
      # Already cached — return instantly.
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

  # Refresh the Team picker whenever the season changes.
  observeEvent(input$seasonInput, {
    teams <- sort(unique(vctrs::vec_c(pbp_data()$homeTeam, pbp_data()$awayTeam)))
    updatePickerInput(session, "TeamInput",
                      choices = teams,
                      selected = if ("Centre" %in% teams) "Centre" else teams[1])
    # Clear downstream pickers so they don't show stale picks from another season.
    updatePickerInput(session, "det_game",     choices = character(0), selected = character(0))
    updatePickerInput(session, "PlayerInput",  choices = character(0), selected = character(0))
  }, ignoreInit = FALSE)

  team_data <- reactive({
    req(input$TeamInput)
    pbp_data() %>% filter(homeTeam == input$TeamInput | awayTeam == input$TeamInput)
  })

  game_wanted <- reactive({
    req(input$det_game)
    pbp_data() %>% filter(game %in% input$det_game)
  })

  # Update game choices whenever a team is selected
  observeEvent(input$TeamInput, {
    req(input$TeamInput)
    game_choices <- pbp_data() %>%
      filter(homeTeam == input$TeamInput | awayTeam == input$TeamInput) %>%
      pull(game) %>% unique()
    updatePickerInput(session, "det_game", choices = game_choices)
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

    filtered_data <- game_wanted() %>%
      filter(awayPlayer1 %in% selected_players |
               awayPlayer2 %in% selected_players |
               awayPlayer3 %in% selected_players |
               awayPlayer4 %in% selected_players |
               awayPlayer5 %in% selected_players |
               homePlayer1 %in% selected_players |
               homePlayer2 %in% selected_players |
               homePlayer3 %in% selected_players |
               homePlayer4 %in% selected_players |
               homePlayer5 %in% selected_players) %>%
      rowwise() %>%
      filter(all(selected_players %in% c(awayPlayer1, awayPlayer2, awayPlayer3, awayPlayer4, awayPlayer5)) |
               all(selected_players %in% c(homePlayer1, homePlayer2, homePlayer3, homePlayer4, homePlayer5))) %>%
      ungroup()

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
    datatable(
      lineupDataFiltered(),
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
    )
  })
  output$lineupDataTotals <- render_totals_ui(lineupDataFiltered)

  # Lineups-in-Game table — wider than the viewport once every rate stat
  # column is shown, so we enable horizontal scroll and pin the CentreLineup
  # column on the left. The lineup-cell className adds the gold accent so
  # the pinned column is also the visual anchor of the row.
  output$lineupsInGameData <- renderDataTable({
    datatable(
      lineupsInGameFiltered(),
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
    )
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
    )
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
      ) %>%
      rowwise() %>%
      filter(all(anchors %in% c(awayPlayer1, awayPlayer2, awayPlayer3, awayPlayer4, awayPlayer5)) |
             all(anchors %in% c(homePlayer1, homePlayer2, homePlayer3, homePlayer4, homePlayer5))) %>%
      ungroup()

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
    )
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
    )
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
                "allAwayData", "allHomeData",
                "gameFacts", "summary")) {
    outputOptions(output, oid, suspendWhenHidden = FALSE)
  }
}

shinyApp(ui = ui, server = server)
