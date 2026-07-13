# Centre Basketball Lineup Analysis

This is my research project for looking at basketball lineups for Centre
College and the other schools in our conference (the SAA). It has two
parts. The first part is a Python program that reads play-by-play web
pages and turns them into clean data files. The second part is an R Shiny
app (a dashboard you open in your web browser) that uses those data files
to show how different five-player lineups did.

I made it for both men's and women's basketball.


## What is in here

There are two kinds of things in this folder: the code and the data.

The code lives at the top level of this folder:

- `getbasketballclean.py` is the main Python program. It does most of the work.
- `html_parsers.py` has helper functions that the main program uses to read
  the web pages. You do not run this one by itself.
- `app.R` is the dashboard.
- The `Scraping Files` folder holds the scraper stages (LinkGetter,
  HTMLGetter, HeaderGetter, TableGetter) that download and pre-process games.
- `audit_scores.py` and `audit_loader.py` are checking tools. You only need
  them if the numbers ever look wrong and you want to find out why. They are
  explained near the bottom.

The data is in two folders, one for each sport:

- `mens-basketball`
- `womens-basketball`

Inside each of those there is a folder called `SAA`, and inside that there
is one folder per school. The schools are Berry, Birmingham-Southern,
Centre, Hendrix, Millsaps, Rhodes, Sewanee, Southwestern, and Trinity.
Each school folder has the raw web pages and the finished data files,
organized by season (like `2024-25`).


## What you need to install

You need Python (version 3.10 or newer) and R (version 4.0 or newer).

For Python, install these packages:

    pip install pandas numpy beautifulsoup4 lxml

For R, install these packages by opening R and running:

    install.packages(c("shiny", "shinythemes", "shinydashboard",
                       "shinyWidgets", "DT", "ggplot2", "ggrepel",
                       "dplyr", "stringr", "readr", "htmlwidgets",
                       "htmltools", "data.table", "later", "png",
                       "showtext", "sysfonts", "vctrs"))


## One thing you have to change first

The dashboard needs to know where this project lives on your computer.
Open `app.R` and look near the top for a line that looks
like this:

    project_root <- "/Users/shreyup/CentreBasketballLineupAnalysis"

Change the text in the quotes to the full path of this folder on your own
computer. That is the only setting you have to change.


## How to run the dashboard

You usually do not need to run the Python program, because the data files
are already made. Most of the time you just want the dashboard.

Open `app.R` in RStudio and click the "Run App" button. Or,
from the R console, run:

    shiny::runApp("app.R")

It opens in your web browser. At the top you pick the sport, the season,
a team, and one or more games. Then you can look at the different tabs:

- The lineup tabs show how each five-player group did (points scored,
  points allowed, shooting, and so on).
- The Conference tab compares whole teams across the league, with a chart
  and a table.
- The Conf Lineups tab compares Centre's best lineups against the best
  lineups from the other schools.


## How to run the Python program (only if you need new data)

You only need this if you add new games or want to remake the data files.
From this folder, run:

    python3 getbasketballclean.py

It reads the web pages in each school's `HTML` folder, figures out the
plays, the possessions, and which players were on the floor, and writes a
finished CSV file for every game into the `pbp` folder.

To change which years it processes, open `getbasketballclean.py` and edit
these two lines near the top:

    start_year = 2010
    end_year = 2025

A full run takes around 20 to 30 minutes and makes a few thousand game
files. While it runs it prints some progress messages. A couple of games
print a message saying they were skipped because their web page only had a
box score and no play-by-play. That is a problem with the school's website,
not a bug.


## If the numbers ever look wrong

If a game's points do not add up the way you expect, you can use the two
audit scripts to find the problem.

    python3 audit_scores.py

This one goes through every game, adds up the points from the play-by-play,
and compares them to the final score from the box score. It tells you which
games do not match and by how much.

    python3 audit_loader.py --school centrecolonels --season 2024-25

This one checks the numbers the same way the dashboard does, for one team
and season, so you can see if any points are getting lost in the dashboard.

Most of the time everything matches. When it does not, it is usually an old
season where the source web pages were missing some plays.
