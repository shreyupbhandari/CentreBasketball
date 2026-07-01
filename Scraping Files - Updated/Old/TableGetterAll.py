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


def getHTML(sport, years, year1, school):
    sport_schedule = open(r'/Users/ericmerdian/Desktop/Desktop/A_Summer_Research/AllTeams/' + school + '/' + sport + '/' + str(year1) + '_links.csv', 'r')
    sport_games = [line.rstrip('\n') for line in sport_schedule]
    sport_schedule.close()

    for game_url in sport_games:
        print(game_url)
        df = []
        list_game = game_url.split("/")
        try:
            game_opponent = list_game[7]
            game_id= list_game[9]
        except urllib.error.URLError:
            continue

        r = requests.get(game_url)

        soup = bs(r.content, features='lxml')

        # try:
        k = 1
        table = soup.find_all('table', attrs = {'class':'sidearm-table play-by-play'})
        # print(table)
        # except:
        #     print("Doesn't have table")
        #     continue
        try:
            #print(table)
            innings = []
            three_headers = ['softball', 'baseball']
            no_innings = ['mens-soccer', 'womens-soccer', 'field-hockey']
            for period in table:
                for i in period.find_all('caption'):
                    inning = i.text.strip()
                    innings.append(inning)
                if k == 1:
                    headers=[]
                    for i in period.find_all('thead'):
                        for i in period.find_all('th'):
                            title = i.text.strip()
                            headers.append(title)
                    if sport in three_headers:
                        headers = headers[0:3]
                    else:
                        headers = headers[0:9]
                    df = pd.DataFrame(columns = headers)
                length=len(df)
                if sport in three_headers:
                    df.loc[length] = [inning] + [''] * 2
                elif sport not in no_innings:
                    df.loc[length] = ['Start Period ' + str(k)] + [''] * 8

                for row in period.find_all('tr')[1:]:
                    j = 0
                    for data in row.find_all('td'):
                        j+= 1
                    if j == 5:
                        data = row.find_all('td', attrs = {'colspan': '5'})
                        row_data = [td.text.strip() for td in data]
                        length=len(df)
                        df.loc[length] = [''] * 3 + row_data + [''] * 5
                    else:
                        data = row.find_all(['td', 'th'])
                        row_data = [td.text.strip() for td in data]
                        length=len(df)
                        df.loc[length] = row_data
                
                k=k+1

            print(df)

            if sport == 'mens-basketball' or sport == 'womens-basketball':
                for i in df.index:
                    score = df['Game Score'][i]
                    df.at[i, 'Game Score'] = score[:score.find(' ', score.find(' ') + 1)] 

            # print(df['Game Score'])

            for i in df.index:
                if df['Period']


            output_file = str(game_id) + '_' + game_opponent + '.csv'

            output_dir = Path('/Users/ericmerdian/Desktop/Desktop/A_Summer_Research/AllTeams/'  + school + '/' + sport + '/Tables/' + str(year1) + '/')

            output_dir.mkdir(parents=True, exist_ok=True)

            df.to_csv(output_dir / output_file, index = False)
        except:
            print("Something went wrong")
            continue

def main():
    # sports = ['baseball', 'mens-basketball', 'mens-lacrosse', 'mens-soccer', 'womens-basketball', 
    #       'field-hockey', 'womens-lacrosse', 'womens-soccer', 'softball', 'womens-volleyball']

    sports = ['baseball', 'mens-soccer', 'field-hockey', 'womens-soccer', 'softball', 'womens-volleyball']
    
    # sports = ['mens-lacrosse', 'womens-lacrosse']

    sports = ['mens-basketball', 'womens-basketball']
    sports = ['mens-basketball']


    multi_year_sports = ['mens-basketball', 'womens-basketball']

    fall_sports = ['mens-basketball', 'mens-soccer', 'womens-basketball', 'field-hockey', 'womens-soccer', 'womens-volleyball']

    schools = ['berryvikings', 'bscsports', 'centrecolonels', 'hendrixwarriors', 'gomajors', 'rhodeslynx', 'sewaneetigers']
    schools = [ 'rhodeslynx', 'sewaneetigers'] 
    schools = ['bscsports']
    schools = ['gomajors']

    for school in schools:
        if school != 'bscsports':
            base_path = 'https://' + school + '.com'
        else:
            base_path = 'https://' + school + '.net'
        print(base_path)



        for sport in sports:
            if sport in fall_sports:
                year1 = 2010
            else:
                year1 = 2011

            while year1 != 2022:
                year2 = year1 + 1
                if sport in multi_year_sports:
                    years = str(year1) + '-' + str(year2)
                else:
                    years = year1
                getHTML(sport, years, year1, school)
                year1 += 1


main()
