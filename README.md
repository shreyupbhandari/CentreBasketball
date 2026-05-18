# Centre Basketball Lineup Analysis

A pipeline that turns SAA Division III men's basketball play-by-play web
pages into structured CSV and JSON files, and an R Shiny app that shows
lineup efficiency stats on top of that data.

## What is in this folder

```
CentreBasketballLineupAnalysis/
├── MAT405basketballResearch/   # the code
│   ├── getbasketballclean.py   # main Python pipeline
│   ├── html_parsers.py         # HTML parsing helpers
│   └── cenrebasketball.R       # R Shiny app
└── SAA/                        # the data, one folder per school
    └── <school>/
        ├── HTML/<season>/      # raw scraped game pages
        ├── headers/<season>/   # box-score CSV per game
        ├── tables/<season>/    # play-by-play CSV per game
        └── pbp/<season>/       # final possession-tagged output
```

## What you need to install

**Python 3.10 or newer:**

```
pip install pandas numpy beautifulsoup4 lxml
```

**R 4.0 or newer:**

```r
install.packages(c("shiny", "shinythemes", "shinydashboard",
                   "shinyWidgets", "DT", "ggplot2", "dplyr",
                   "stringr", "readr", "htmlwidgets", "htmltools"))
```

## How to run the Python pipeline

From this folder:

```
python3 MAT405basketballResearch/getbasketballclean.py
```

It reads the HTML files in `SAA/<school>/HTML/<season>/`, parses them,
tracks possession and lineups, and writes one CSV and one JSON per game
to `SAA/<school>/pbp/<season>/`.

To change which seasons get processed, edit the top of
`getbasketballclean.py`:

```python
start_year = 2010
end_year = 2023
```

A full run takes about 5 to 10 minutes and produces just over 2,000
game files across all seven schools.

## How to run the R Shiny app

Open `MAT405basketballResearch/cenrebasketball.R` in RStudio and click
"Run App," or from the R console:

```r
shiny::runApp("MAT405basketballResearch/cenrebasketball.R")
```

Near the top of the file there is a variable that points at the season
folder to load. Change it to whichever team and season you want:

```r
directory_path <- "/Users/.../SAA/centrecolonels/pbp/2023-24"
```

Once the app opens in your browser, pick a team, a game, and one or
more players. The app shows lineup efficiency tables and the raw
play-by-play for the rows where those players were on the floor.

## What the output files contain

Each game writes one CSV and one matching JSON to
`SAA/<school>/pbp/<season>/`. The important columns are:

- `homePlay`, `awayPlay`: raw play text
- `Team`, `Player`, `playType`, `shotOutcome`, `pointsEarned`
- `homePlayer1` through `homePlayer5`, `awayPlayer1` through `awayPlayer5`
- `possStart`: 1 on the first row of a new possession
- `possTeam`: team holding the ball
- `possPoints`: points scored on that possession
- `possSequence`: running possession number
- `teamChanged`: 1 on the last row before possession switches
- `secondsPerPoss`: possession duration in seconds

## What a successful run looks like

- Exit code 0.
- Three games print `Skipping empty game: ...` because their source HTML
  pages have a box score but no play-by-play. This is a data problem on
  the school's website, not a bug.
- The console prints `0 should be 0` at the end of each game. That is a
  sanity check, not an error.

That's it. Run the Python script first, then open the Shiny app.
