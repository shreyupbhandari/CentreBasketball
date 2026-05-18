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


directory_path <- "/Users/shreyup/Downloads/mens-basketball/basketballResearch/SAA/centrecolonels/pbp/2023-24"
all_files <- list.files(path = directory_path, pattern = ".csv$")

# Read and stack all game CSV files for the season into one data frame.
# full_join is used so that games with slightly different column sets still merge cleanly.
pbp_data <- read.csv(paste0(directory_path, "/", all_files[1]))

for (csv_name in all_files[-1]) {
  detail_file_path <- paste0(directory_path, "/", csv_name)
  game_file <- read.csv(detail_file_path)
  game_file$"attendance" <- as.integer(game_file$"attendance")
  pbp_data <- full_join(pbp_data, game_file)
}

# Drop rows where we couldn't track the full five-man lineup on both sides —
# those rows would produce unreliable lineup stats.
pbp_data <- subset(pbp_data, playerMissing == 0)


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
            inputId = "TeamInput", label = "Select Team",
            choices = unique(vctrs::vec_c(pbp_data$homeTeam, pbp_data$awayTeam)),
            multiple = FALSE
          )
      ),
      div(class = "input-box",
          pickerInput(
            inputId = "det_game", label = "Select Game",
            choices = NULL,
            selected = NULL,
            multiple = TRUE
          )
      ),
      div(class = "input-box",
          pickerInput(
            inputId = "PlayerInput", label = "Select Player",
            choices = NULL,
            multiple = TRUE
          ),
          img(src = "centrelogo.jpg", alt = "Cannot find image", width = "100%", height = "100%")
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
        )
      )
    )
  )
)



server <- function(input, output, session) {

  team_data <- reactive({
    req(input$TeamInput)
    pbp_data %>% filter(homeTeam == input$TeamInput | awayTeam == input$TeamInput)
  })

  game_wanted <- reactive({
    req(input$det_game)
    pbp_data %>% filter(game %in% input$det_game)
  })

  # Update game choices whenever a team is selected
  observeEvent(input$TeamInput, {
    game_choices <- pbp_data %>%
      filter(homeTeam == input$TeamInput | awayTeam == input$TeamInput) %>%
      pull(game) %>% unique()
    updatePickerInput(session, "det_game", choices = game_choices)
  })

  # Update player choices whenever a game is selected
  observeEvent(input$det_game, {
    req(game_wanted())
    player_choices <- sort(game_wanted() %>%
                             filter(tolower(Team) == tolower(input$TeamInput)) %>%
                             pull(Player) %>%
                             unique())
    updatePickerInput(session, "PlayerInput", choices = player_choices)
  })

  PlayerData <- reactive({
    req(input$PlayerInput)
    req(game_wanted())
    selected_players <- input$PlayerInput

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

    filtered_data <- filtered_data %>%
      mutate(CentreLineup = sapply(1:n(), function(i) {
        if (awayTeam[i] == "Centre") {
          paste(sort(c(awayPlayer1[i], awayPlayer2[i], awayPlayer3[i], awayPlayer4[i], awayPlayer5[i])), collapse = ", ")
        } else if (homeTeam[i] == "Centre") {
          paste(sort(c(homePlayer1[i], homePlayer2[i], homePlayer3[i], homePlayer4[i], homePlayer5[i])), collapse = ", ")
        } else {
          NA
        }
      }))

    filtered_data
  })

  # Build a summary table across all lineup combinations seen in the selected game(s).
  AllLineupsData <- reactive({
    req(game_wanted())
    selected_team <- input$TeamInput

    all_lineups_data <- game_wanted() %>%
      mutate(
        CentreLineup = sapply(1:n(), function(i) {
          paste(sort(c(awayPlayer1[i], awayPlayer2[i], awayPlayer3[i], awayPlayer4[i], awayPlayer5[i])), collapse = ", ")
        }),
        # Points scored / allowed while this lineup was on court
        pointsEarned   = if_else(possTeam == tolower(selected_team) & teamChanged == 1, possPoints, 0),
        pointsAgainst  = if_else(possTeam != tolower(selected_team) & teamChanged == 1, possPoints, 0),
        # Offensive and defensive possessions
        off_poss = if_else(possTeam == tolower(selected_team) & possStart == 1, possStart, 0),
        def_poss = if_else(possTeam != tolower(selected_team) & possStart == 1, possStart, 0),
        assists  = if_else(possTeam == tolower(selected_team), ASSIST, 0),
        oreb     = if_else(possTeam == tolower(selected_team), OREB, 0),
        dreb     = if_else(possTeam == tolower(selected_team), DREB, 0),
        op_oreb  = if_else(possTeam != tolower(selected_team), OREB, 0),
        op_dreb  = if_else(possTeam != tolower(selected_team), DREB, 0),
        time_sec = if_else(possTeam != tolower(selected_team), secondsPerPoss, 0)
      ) %>%
      group_by(CentreLineup) %>%
      summarise(
        pointsEarned    = sum(pointsEarned,   na.rm = TRUE),
        pointsAgainst   = sum(pointsAgainst,  na.rm = TRUE),
        OFFPOSS         = sum(off_poss,        na.rm = TRUE),
        DEFPOSS         = sum(def_poss,        na.rm = TRUE),
        OFFRTG          = round(pointsEarned  / OFFPOSS * 100, 1),
        DEFRTG          = round(pointsAgainst / DEFPOSS * 100, 1),
        NETRTG          = round(OFFRTG - DEFRTG, 1),
        ASSISTS         = sum(assists,  na.rm = TRUE),
        AST_RATIO       = round(ASSISTS / OFFPOSS * 100, 1),
        OFFREB          = sum(oreb,     na.rm = TRUE),
        DEFREB          = sum(dreb,     na.rm = TRUE),
        opponent_OFFREB = sum(op_oreb,  na.rm = TRUE),
        opponent_DEFREB = sum(op_dreb,  na.rm = TRUE),
        plus_minus      = sum(pointsEarned) - sum(pointsAgainst),
        OREBP           = round((OFFREB) / (OFFREB + sum(op_dreb, na.rm = TRUE)), 1),
        DREBP           = round((DEFREB) / (DEFREB + sum(op_oreb, na.rm = TRUE)), 1),
        TIME_SEC        = sum(time_sec, na.rm = TRUE)
      )

    all_lineups_data
  })

  output$lineupData <- renderDataTable({
    req(input$TeamInput)
    selected_team <- input$TeamInput

    lineup_data <- PlayerData() %>%
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
        time_sec = secondsPerPoss
      ) %>%
      group_by(CentreLineup) %>%
      summarise(
        pointsEarned  = sum(pointsEarned,  na.rm = TRUE),
        pointsAgainst = sum(pointsAgainst, na.rm = TRUE),
        OFFPOSS       = sum(off_poss,       na.rm = TRUE),
        DEFPOSS       = sum(def_poss,       na.rm = TRUE),
        OFFRTG        = round(pointsEarned  / OFFPOSS * 100, 1),
        DEFRTG        = round(pointsAgainst / DEFPOSS * 100, 1),
        NETRTG        = round(OFFRTG - DEFRTG, 1),
        ASSISTS       = sum(assists,  na.rm = TRUE),
        AST_RATIO     = round(ASSISTS / OFFPOSS * 100, 1),
        OFFREB        = sum(oreb,     na.rm = TRUE),
        DEFREB        = sum(dreb,     na.rm = TRUE),
        plus_minus    = sum(pointsEarned) - sum(pointsAgainst),
        OREBP         = round((OFFREB) / (OFFREB + sum(op_dreb, na.rm = TRUE)), 1),
        DREBP         = round((DEFREB) / (DEFREB + sum(op_oreb, na.rm = TRUE)), 1),
        TIME_SEC      = sum(time_sec, na.rm = TRUE)
      ) %>%
      select(-OFFREB, -DEFREB)

    datatable(lineup_data)
  })

  output$lineupsInGameData <- renderDataTable({
    req(input$det_game)
    req(input$TeamInput)
    AllLineupsData()
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
        time_sec = secondsPerPoss
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
        OREBP               = round((OFFREB) / (OFFREB + sum(op_dreb, na.rm = TRUE)), 1),
        DREBP               = round((DEFREB) / (DEFREB + sum(op_oreb, na.rm = TRUE)), 1),
        TIME_SEC            = sum(time_sec, na.rm = TRUE),
        total_plus_minus    = total_pointsEarned - total_pointsAgainst
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
