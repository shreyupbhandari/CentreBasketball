#!/usr/bin/env bash
# Double-click this file (or run it) to launch the dashboard with the latest
# data. It pulls whatever the daily GitHub Actions job committed, then starts
# the Shiny app in your browser.
set -e
cd "$(dirname "$0")"

echo "Pulling latest data..."
# --ff-only refuses to merge if you have diverging local commits, which keeps
# your working copy safe. If it complains, commit/stash your local changes.
git pull --ff-only || echo "(skipped pull — resolve local changes and retry)"

echo "Starting dashboard..."
Rscript -e 'shiny::runApp("MAT405basketballResearch/cenrebasketball.R", launch.browser = TRUE)'
