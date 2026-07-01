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


def getHTML(sport, year1):
    sport_schedule = open(r'/Users/ericmerdian/Desktop/Desktop/A_Summer_Research/' + str(sport) + '/' + str(year1) + '_links.csv', 'r')
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

        try:
            # section = soup.find_all('section', attrs = {'id': 'play-by-play'})
            # div = section.find_all('div')
            # sidearm_table = soup.find('div', class_ = 'row pad')
            # div = soup.find('div')
            k = 1
            per_num = []
            headers=['Down & Distance', 'Play', 'Quarter']
            df = pd.DataFrame(columns = headers)    
            for part in soup.select('section[aria-label*="Quart"]'):
                table = part.find_all('table', attrs = {'class':'sidearm-table overall-stats highlight-hover collapse-on-small'})
                #print(table)
                for period in table:
                    #print(df)

                    for head in period.find_all('thead'):
                        for row in head.find_all('tr'):
                            data = row.find_all('th')
                            row_data = [th.text.strip() for th in data]
                            if len(row_data) == 1:
                                for i in row_data:
                                    if 'Start' in i:
                                        length=len(df)
                                        df.loc[length] = [''] + row_data + [k]
                                        # print(row_data + [k])
                            else:
                                continue
                    

                    for row in period.find_all('tr')[1:]:
                        j = 0
                        #print(row)
                        for skiprow in row.find_all('th', attrs = {'scope':'col'}):
                            continue
                        for data in row.find_all(['td', 'th']):
                            j+= 1
                        if j == 1:
                            data = row.find_all(['td', 'th'])
                            row_data = [td.text.strip() for td in data]
                            #print(row_data)
                            length=len(df)
                            df.loc[length] = [''] + row_data + [k]
                            continue
                        data = row.find_all(['td', 'th'])
                        row_data = [td.text.strip() for td in data]
                        print(row_data[1].lower())
                        #print(row_data)
                        length=len(df)
                        df.loc[length] = row_data + [k]
                        # print(k)
                per_num.append(k)
                k += 1

            # print(per_num)

            print(df)

            try:
                score = part.find_all('dl', attrs = {'class': 'special-stats emphasize primary inline text-center'})[-1]
                data = score.find_all('dd')
                row_data = [dl.text.strip() for dl in data]
                length=len(df)
                df.loc[length] = ['Final Score'] + row_data + [k-1]
                # print(df.loc[length])
            except:
                print("There was a problem")
                continue

            print('hi')


            df = df[df.Play != 'Play']

            print(df)

            # output_file = str(game_id) + '_' + game_opponent + '.csv'

            # output_dir = Path('/Users/ericmerdian/Desktop/Desktop/A_Summer_Research/' + sport + '/Tables/' + str(year1) + '/')

            # output_dir.mkdir(parents=True, exist_ok=True)

            # df.to_csv(output_dir / output_file, index=False)
        except:
            continue

def main():
    sport = 'football'
    year1 = 2010

    while year1 != 2022:
        year2 = year1 + 1
        getHTML(sport, year1)
        year1 += 1

main()
