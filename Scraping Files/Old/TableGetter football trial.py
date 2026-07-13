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
        quarters = soup.find_all('section', attrs={"id": "1st"})

        dls = soup.find_all('dl')
        table = soup.find_all('table')

        num_periods = 1
        for tag in soup.contents:
            #print(tag)
            if tag in table:
                print(tag)
            # new_data = period.find_all('dl', attrs={'class': 'special-stats emphasize primary inline text-center'})
            # print(new_data)
            # num_periods+=1
            # print(num_periods)

        # score = soup.find_all('dl', attrs= {'class': 'special-stats emphasize primary inline text-center'})
        # for pd in score:
        #     for row in pd.find_all('dd'):
        #         row_data = row.text.strip()
        #         print(row_data)
        # sections = soup.find_all('section', {'class': 'ui-tabs-panel ui-corner-bottom ui-widget-content'})
        # # for div in sections:
        # #     section = sections.find_all('div', {'class': 'sidearm-responsive-tabs ui-tabs ui-corner-all ui-widget ui-widget-content'})
        # print(sections)

        # Print out html
        #print(soup.prettify())
        try:
            # work on fixing the quarters
            # quarter = soup.find_all('section', {'role':'tabpanel'})
            # print(quarter)
            k = 1
            table = soup.find_all('table', attrs = {'class':'sidearm-table overall-stats highlight-hover collapse-on-small'})
            #print(table)
            for period in table:
                if k == 1:
                    headers=['Down & Distance', 'Play']
                    # for i in period.find_all('thead'):
                    #     for i in period.find_all('th'):
                    #         title = i.text.strip()
                    #         headers.append(title)
                    df = pd.DataFrame(columns = headers)
                length=len(df)
                #print(k)
                df.loc[length] = ['Start Period ' + str(k)] + ['']
                #print(df)
                for row in period.find_all('tr')[1:]:
                    j = 0
                    #print(row)
                    for skiprow in row.find_all('th', attrs = {'scope':'col'}):
                        #print("This row should be skipped")
                        continue
                    for data in row.find_all(['td', 'th']):
                        j+= 1
                    if j == 1:
                        # Come back later to try and figure this out
                        data = row.find_all(['td', 'th'])
                        row_data = [td.text.strip() for td in data]
                        #print(row_data)
                        # length=len(df)
                        # df.loc[length] = [''] + row_data
                        # print(df)
                        # print("This is a row with one column")
                        continue
                    data = row.find_all(['td', 'th'])
                    row_data = [td.text.strip() for td in data]
                    #print(row_data)
                    length=len(df)
                    df.loc[length] = row_data








                # try:
                #     score = soup.find_all('dl', attrs= {'class': 'special-stats emphasize primary inline text-center'})
                #     for pd in score:
                #         for row in pd.find_all('dd'):
                #             row_data = row.text.strip()
                #             print(row_data)
                #             # length=len(df)
                #             # df.loc[length] = row_data + ['']
                #             # print(df)
                # except:
                #     continue

                # for row in period.find_all('tr')[2:]:
                #     data = row.find_all(['td', 'th'])
                #     row_data = [td.text.strip() for td in data]
                #     print(row_data)
                #     length=len(df)
                #     df.loc[length] = row_data
                #print(df)
                k=k+1
            # try:
            #     print("This is a row")
            #     score = soup.find_all('dl', attrs= {'class': 'special-stats emphasize primary inline text-center'})
            #     for pd in score:
            #         for row in pd.find_all('dd'):
            #             row_data = row.text.strip()
            #             length=len(df)
            #             df.loc[length] = row_data + ['']
            #             print(df)
            # except:
            #     continue

            print(df)

            df = df[df.Play != 'Play']

            print(df)

        #     output_file = str(game_id) + '_' + game_opponent + '.csv'

        #     output_dir = Path('/Users/ericmerdian/Desktop/Desktop/A_Summer_Research/' + sport + '/Tables/' + str(year1) + '/')

        #     output_dir.mkdir(parents=True, exist_ok=True)

        #     df.to_csv(output_dir / output_file)
        except:
            continue

def main():
    # sports = ['mens-basketball', 'football', 'mens-lacrosse', 'mens-soccer', 'mens-tennis', 'womens-basketball', 
    #       'field-hockey', 'womens-lacrosse', 'womens-soccer', 'softball', 'womens-tennis', 'womens-volleyball']

    sports = ['football']
   
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
