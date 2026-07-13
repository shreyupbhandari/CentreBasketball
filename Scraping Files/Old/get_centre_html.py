# get_espn_pbp_html.py
# downloads espn pbp html for specified season
# writes html to file as a .txt file
# skips game files that have previously been downloaded

from bs4 import BeautifulSoup
import urllib
import urllib.request, urllib.error
import math
import re
import fileinput
import os

os.chdir('/Users/ericmerdian/Desktop/Desktop/A_Summer_Research/')

def getHTML(sport, years, year1):
    
    sport_schedule = open(r'/Users/ericmerdian/Desktop/Desktop/A_Summer_Research/' + sport + '/' + str(year1) + '_links.csv', 'r')
    sport_games = [line.rstrip('\n') for line in sport_schedule]
    sport_schedule.close()
# creates years folder for each sport in their HTML folder
    try:
        os.mkdir('/Users/ericmerdian/Desktop/Desktop/A_Summer_Research/' + sport + '/' + 'HTML/' + str(years))
    except FileExistsError:
        i=1
    for game_url in sport_games:
        list_game = game_url.split("/")
        try:
            game_html = urllib.request.urlopen(game_url).read()
            game_soup = BeautifulSoup(game_html, "html.parser")
            game_opponent = list_game[7]
            game_id= list_game[9]

            #need to create folder within sports and have html and then have year folder
            outfile = open(r'/Users/ericmerdian/Desktop/Desktop/A_Summer_Research/' + sport + '/' + 'HTML/' + str(years) + '/' + sport + '_' + str(years) + '_' + game_opponent + '_' + game_id + '.html', 'w')
            outfile.write(str(game_soup))
            outfile.close()
        except urllib.error.URLError:
            continue

def main():
    sports = ['baseball', 'mens-basketball', 'football', 'mens-lacrosse', 'mens-soccer', 'mens-tennis', 'womens-basketball', 
          'field-hockey', 'womens-lacrosse', 'womens-soccer', 'softball', 'womens-tennis', 'womens-volleyball']
       
    multi_year_sports = ['mens-basketball', 'womens-basketball', 'mens-tennis', 'womens-tennis']

    fall_sports = ['mens-basketball', 'football', 'mens-soccer', 'womens-basketball', 'field-hockey', 'womens-soccer', 'womens-volleyball']

    for sport in sports:
        if sport == 'mens-tennis' or sport == 'womens-tennis':
            year1 = 2018
        elif sport in fall_sports:
            year1 = 2010
        else:
            year1 = 2011

        while year1 != 2022:
            year2 = year1 + 1
            if sport in multi_year_sports:
                years = str(year1) + '-' + str(year2)
            else:
                years = year1
            getHTML(sport, years, year1)
            year1 += 1
            
   
main()
