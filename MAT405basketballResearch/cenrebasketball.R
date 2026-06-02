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
  shot_types <- c("layup", "jumper", "three pointer", "dunk")

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
        is.na(shotOutcome) | shotOutcome != "good" ~ 0,
        playType == "three pointer"                ~ 3,
        playType %in% c("layup","jumper","dunk")   ~ 2,
        playType == "free throw"                   ~ 1,
        TRUE                                       ~ 0
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

# Parent directory containing one folder per season (e.g. "2023-24", "2022-23").
# Listing it at startup gives us the season picker's choices without hardcoding.
seasons_root <- "/Users/shreyup/CentreBasketballLineupAnalysis/SAA/centrecolonels/pbp"
available_seasons <- sort(
  list.dirs(seasons_root, recursive = FALSE, full.names = FALSE),
  decreasing = TRUE   # newest first so the most recent season is the default
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
load_pbp <- function(season) {
  dir <- file.path(seasons_root, season)
  files <- list.files(dir, pattern = "\\.csv$", full.names = TRUE)
  if (length(files) == 0) return(NULL)

  d <- bind_rows(lapply(files, read.csv, colClasses = "character"))

  num_cols <- intersect(
    c("possPoints", "possStart", "teamChanged", "ASSIST",
      "OREB", "DREB", "secondsPerPoss", "playerMissing"),
    names(d)
  )
  d[num_cols] <- lapply(d[num_cols], as.numeric)

  # Normalize the four team-name columns to a single canonical spelling
  # per team, BEFORE any downstream filtering uses them. homeTeam/awayTeam
  # become the title-cased canonical ("Centre"); Team/possTeam are
  # tolower()'d after normalization because the existing code compares
  # tolower(input$TeamInput) against them.
  for (col in intersect(c("homeTeam", "awayTeam"), names(d))) {
    d[[col]] <- normalize_team(d[[col]])
  }
  for (col in intersect(c("Team", "possTeam"), names(d))) {
    d[[col]] <- tolower(normalize_team(d[[col]]))
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

  # Drop rows whose lineup slots have "None" or "" placeholders from the
  # scraper's substitution-handling code.
  lineup_cols <- intersect(
    c(paste0("awayPlayer", 1:5), paste0("homePlayer", 1:5)),
    names(d)
  )
  if (length(lineup_cols) > 0) {
    d[lineup_cols] <- lapply(d[lineup_cols], function(x) {
      ifelse(x == "None" | x == "", NA_character_, x)
    })
    has_none_lineup <- Reduce(`|`, lapply(d[lineup_cols], is.na))
    d <- d[!has_none_lineup, , drop = FALSE]
  }

  if ("playerMissing" %in% names(d)) {
    d <- subset(d, playerMissing == 0)
  }

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

  # Add elapsed_sec from the game clock — see add_elapsed_seconds() comment
  # for the rationale. Done AFTER row drops so each surviving row gets the
  # full clock span since the previous surviving row.
  d <- add_elapsed_seconds(d)
  d
}

# Tiny per-process cache so flipping back to a season you've already viewed
# is instant — the CSV parse happens once per season per process.
.pbp_cache <- new.env(parent = emptyenv())
load_pbp_cached <- function(season) {
  if (!exists(season, envir = .pbp_cache)) {
    assign(season, load_pbp(season), envir = .pbp_cache)
  }
  get(season, envir = .pbp_cache)
}


image_ratio <- 248/327
image_width <- 45

ui <- fluidPage(

  # Include Google Fonts and custom CSS
  tags$head(
    tags$link(rel = "stylesheet", href = "https://fonts.googleapis.com/css2?family=Oswald:wght@400;700&display=swap"),
    theme = shinytheme("sandstone"),
    tags$style(HTML("
     body {
        background-color: #f5f5f5;
       font-family: 'Oswald', sans-serif;
     }
      .title-panel {
        border: 5px solid rgb(241, 204, 44);
        padding: 10px;
        border-radius: 10px;
        text-align: center;
        background-color: rgb(241, 204, 44);
        color: black;
        font-size: 24px;
        font-weight: bold;
        margin: 20px;
      }
      .input-box {
        background-color: black;
        color: white;
        border: none;
        padding: 10px;
        margin-bottom: 0;
      }
      .input-box label {
        background-color: black;
        color: white;
      }
      .selectize-input {
        background-color: black;
        color: white;
        border: none;
      }
      .selectize-input:focus {
        border: none;
        box-shadow: none;
      }
      .selectize-dropdown {
        background-color: black;
        color: white;
      }
      .selectize-dropdown-content {
        background-color: black;
        color: white;
      }
      .selectize-dropdown-content .option {
        background-color: black;
        color: white;
      }
      .selectize-dropdown-content .option:hover {
        background-color: #0072B8;
      }
      .selectize-dropdown .active {
        background-color: black;
        color: white;
      }
      .sidebar-panel {
        background-color: #fff;
        padding: 15px;
        border-radius: 5px;
        box-shadow: 0 0 10px rgba(0, 0, 0, 0.1);
      }
      .data-table {
        margin-top: 20px;
      }
    "))
  ),

  titlePanel(
    title = div(
      style = "
      background-color: black;
      color: white;
      font-size: 20px;
      font-weight: 300;
      padding: 20px;
      text-align: left;
      width: 100%;
      margin: 0;
    ",
      img(src = "CentreCTransparent.png", alt = "Cannot find image", width = image_width, height = image_width*image_ratio),
      "Centre College Basketball"
    ),
    windowTitle = "Centre College Basketball"
  ),

  sidebarLayout(
    sidebarPanel(
      width = 4,
      div(class = "input-box",
          pickerInput(
            inputId = "seasonInput", label = "Select Season",
            choices  = available_seasons,
            selected = available_seasons[1],
            multiple = FALSE
          )
      ),
      div(class = "input-box",
          pickerInput(
            inputId = "TeamInput", label = "Select Team",
            choices = NULL,    # populated reactively from the selected season
            multiple = FALSE
          )
      ),
      div(class = "input-box",
          pickerInput(
            inputId = "det_game", label = "Select Game",
            choices = NULL,
            selected = NULL,
            multiple = TRUE,
            options = list(`live-search` = TRUE, `actions-box` = TRUE)
          )
      ),
      div(class = "input-box",
          pickerInput(
            inputId = "PlayerInput",
            label = "Select Player (choices narrow to shared-floor teammates as you pick)",
            choices = NULL,
            multiple = TRUE,
            options = list(`live-search` = TRUE, `actions-box` = TRUE)
          ),
          actionButton(
            inputId = "resetLineup",
            label = "Reset lineup",
            icon = icon("rotate-left"),
            style = "background-color: rgb(241, 204, 44); color: black; border: none; width: 100%; margin-top: 8px; font-weight: bold;"
          ),
          img(src = "centrelogo.jpg", alt = "Cannot find image", width = "100%", height = "100%")
      ),
      # Sample-size gate. With only 2-3 possessions a lineup can post a 300
      # DefRtg purely because the denominator is tiny — the rate is math-
      # ematically valid but statistically meaningless. The threshold below
      # is honored by both the "Lineups in Game" tab and the "Top 5 Lineups"
      # tab: no lineup with fewer combined OFF + DEF possessions is shown.
      div(class = "input-box", style = "margin-top: 10px;",
          numericInput(
            inputId = "min_poss",
            label = "Min total possessions (OFF + DEF) per lineup",
            value = 20, min = 1, max = 500, step = 1
          )
      )
    ),
    mainPanel(
      tabsetPanel(
        tabPanel("Player Tables",
                 dataTableOutput("lineupData"),
                 textOutput("summary")
        ),
        tabPanel("All Data",
                 dataTableOutput("allAwayData"),
                 dataTableOutput("allHomeData")
        ),
        tabPanel("Lineups in Game",
                 dataTableOutput("lineupsInGameData")
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
        )
      )
    )
  )
)



server <- function(input, output, session) {

  # Season-aware data source. Re-evaluates only when the user changes seasons;
  # load_pbp_cached() caches by season so the second visit to a season is
  # instant. Everything downstream calls pbp_data() instead of a global.
  pbp_data <- reactive({
    req(input$seasonInput)
    df <- load_pbp_cached(input$seasonInput)
    validate(need(!is.null(df) && nrow(df) > 0,
                  sprintf("No data found for season %s.", input$seasonInput)))
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
  
  # Reset button: clear the lineup and restore the full roster.
  observeEvent(input$resetLineup, {
    req(input$TeamInput, input$det_game)
    updatePickerInput(
      session, "PlayerInput",
      choices  = available_teammates(team_lineup_mat(), character(0)),
      selected = character(0)
    )
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

  output$lineupData <- renderDataTable({
    req(input$TeamInput)
    selected_team <- input$TeamInput

    # Min-possessions gate is honored here too so a 3-poss splinter lineup
    # doesn't appear with a 300 DefRtg. No forced sort — rows are shown in
    # the order they're aggregated, sortable by clicking column headers.
    min_poss <- if (is.null(input$min_poss) || is.na(input$min_poss)) 0 else input$min_poss
    lineup_data <- compute_lineup_metrics(PlayerData(), selected_team) %>%
      select(-OFFREB, -DEFREB, -opp_OFFREB, -opp_DEFREB) %>%
      filter(TOTAL_POSS >= min_poss)

    datatable(lineup_data, options = list(pageLength = 15))
  })

  output$lineupsInGameData <- renderDataTable({
    req(input$det_game)
    req(input$TeamInput)

    min_poss <- if (is.null(input$min_poss) || is.na(input$min_poss)) 0 else input$min_poss
    df <- AllLineupsData() %>%
      filter(TOTAL_POSS >= min_poss) %>%
      arrange(desc(NETRTG))

    datatable(df, options = list(pageLength = 15))
  })

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

    df <- df %>%
      filter(!is.na(CentreLineup), TOTAL_POSS >= min_poss) %>%
      filter(!is.na(.data[[metric]]), is.finite(.data[[metric]]))

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

    datatable(df, rownames = FALSE,
              options = list(dom = "t", pageLength = top_n, ordering = FALSE,
                             scrollX = TRUE))
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
}

shinyApp(ui = ui, server = server)
