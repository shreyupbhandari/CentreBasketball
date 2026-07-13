import requests
from bs4 import BeautifulSoup as bs
import re
import pandas as pd
import fileinput
import os
import urllib
import urllib.request, urllib.error
import math
from pathlib import Path


def getHTML(sport, years, year1):
    sport_schedule = open(r'/Users/ericmerdian/Desktop/Desktop/A_Summer_Research/' + sport + '/' + str(year1) + '_links.csv', 'r')
    sport_games = [line.rstrip('\n') for line in sport_schedule]
    sport_schedule.close()

    for game_url in sport_games:
        print(game_url)
        list_game = game_url.split("/")
        try:
            game_opponent = list_game[7]
            game_id= list_game[9]
        except urllib.error.URLError:
            continue


        r = requests.get(game_url)

        # Convert to a BS object
        soup = bs(r.content, features='lxml')

        # Print out html
        #print(soup.prettify())
        try:
            table = soup.find('table', {'class':'sidearm-table play-by-play'})

            #print(table)

            headers = []

            for i in table.find_all('thead'):
                for i in table.find_all('th'):
                    title = i.text.strip()
                    headers.append(title)

            # print(headers)

            headers = headers[0:9]

            # print(headers)

            df = pd.DataFrame(columns = headers)

            print(df)

            for row in table.find_all('tr')[1:]:
                data = row.find_all('td')
                print(data)
                row_data = [td.text.strip() for td in data]
                length = len(df)
                df.loc[length] = row_data
                print(row_data)

            #df

            output_file = str(game_id) + '_' + game_opponent + '.csv'

            output_dir = Path('/Users/ericmerdian/Desktop/Desktop/A_Summer_Research/' + sport + '/Tables/' + str(year1) + '/')

            output_dir.mkdir(parents=True, exist_ok=True)

            df.to_csv(output_dir / output_file)


            #df.to_csv(r'/Users/ericmerdian/Desktop/Desktop/A_Summer_Research/' + sport + '/Tables/' + str(year1) + '/' + str(game_id) + '_' + game_opponent + '.csv', index = False, header=False)
        except:
            continue

def main():
	# sports = ['baseball', 'mens-basketball', 'football', 'mens-lacrosse', 'mens-soccer', 'mens-tennis', 'womens-basketball', 
    #      'field-hockey', 'womens-lacrosse', 'womens-soccer', 'softball', 'womens-tennis', 'womens-volleyball']
    # Just using field hockey for now
    sports = ['mens-lacrosse']
   
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
