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

        table = soup.find_all('table', {'class':"sidearm-table overall-stats highlight-hover highlight-column-hover centered-caption"})
        #print(table)
        k = 1
        max_cols = 0
        table_cols = []
        for period in table:
            for head in period.find_all('thead'):
                for row in head.find_all('tr'):
                    j = 0
                    for i in row.find_all('th'):
                        #print(i)
                        j+=1
            table_cols.append(j)
            if max_cols < j:
                max_cols = j
        print(max_cols)
        print(table_cols)
        headers = ['Doubles and Singles Results'] + [''] * (max_cols - 1)
        print(headers)
        df = pd.DataFrame(columns = headers)
        slot = 0
        for period in table:
            data = period.find_all('caption')
            row_data = [td.text.strip() for td in data]
            length=len(df)
            df.loc[length] = row_data + [''] * (max_cols - 1)
            for row in period.find_all('tr')[1:]:
                data = row.find_all(['td', 'th'])
                row_data = [td.text.strip() for td in data]
                print(row_data)                
                length=len(df)
                df.loc[length] = row_data + [''] * (max_cols - table_cols[slot])
            slot += 1
        print(df)
        # print(df)



        #     if k == 1:
        #         headers=[]
        #         data = period.find_all('caption')
        #         row_data = [td.text.strip() for td in data]
        #         headers = row_data + [''] * 2
        #         #print(headers)
        #         df = pd.DataFrame(columns = headers)
        #         print(df)
        #         # for i in period.find_all('thead'):
        #         #     for i in period.find_all('tr'):
        #         #         for i in period.find_all('th'):
        #         #             title = i.text.strip()
        #         #             headers.append(title) + [''] * 2
        #         # print(headers)
        #         # df = pd.DataFrame(columns = headers)
        #         # print(df)



        # # Print out html
        # #print(soup.prettify())
        # try:
        #     k = 1
        #     table = soup.find_all('table', {'class':"sidearm-table overall-stats highlight-hover highlight-column-hover centered-caption"})
        #     #print(table)
        #     for period in table:
        #         if k == 1:
        #             headers=[]
        #             for i in period.find_all('thead'):
        #                 for i in period.find_all('tr'):
        #                     for i in period.find_all('th'):
        #                         title = i.text.strip()
        #                         headers.append(title) + [''] * 2
        #             print(headers)
        #             df = pd.DataFrame(columns = headers)
        #             print(df)
                
        #         for row in period.find_all('tr')[1:]:
        #             data = row.find_all(['td', 'th'])
        #             row_data = [td.text.strip() for td in data]
        #             length=len(df)
        #             df.loc[length] = row_data
        #         k=k+1

        #     # print(df)

        output_file = str(game_id) + '_' + game_opponent + '.csv'

        output_dir = Path('/Users/ericmerdian/Desktop/Desktop/A_Summer_Research/' + sport + '/Tables/' + str(year1) + '/')

        output_dir.mkdir(parents=True, exist_ok=True)

        df.to_csv(output_dir / output_file)
        # except:
        #     continue

def main():
    sports = ['mens-tennis', 'womens-tennis']
   
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
