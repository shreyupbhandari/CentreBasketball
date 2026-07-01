# TableGetter.py
# Reads in HTML files of specified SAA schools/sports/years.
# Writes PBP tables to files.
# Currently works for baseball, softball

import requests
from bs4 import BeautifulSoup as bs
import re
import pandas as pd
import fileinput
import os
import urllib
#import urllib.request, urllib.error
import math
from pathlib import Path


# Config falls back to the manual defaults; the daily workflow overrides these.
main_dir = os.environ.get('PBP_ROOT', '/Users/jeff/Library/CloudStorage/OneDrive-CentreCollegeofKentucky/Research/Centre Sports Analytics/PBP Data/sports/')
#sports = ['baseball', 'mens-basketball', 'football', 'mens-lacrosse', 'mens-soccer', 'mens-tennis', 'womens-basketball',
#              'field-hockey', 'womens-lacrosse', 'womens-soccer', 'softball', 'womens-tennis', 'womens-volleyball']
sports = os.environ.get('SPORTS', 'mens-basketball').split(',')

outdoor_sports = ['baseball', 'football', 'mens-lacrosse', 'mens-soccer', 'mens-tennis',
              'field-hockey', 'womens-lacrosse', 'womens-soccer', 'softball', 'womens-tennis']
multi_year_sports = ['mens-basketball', 'womens-basketball', 'mens-tennis', 'womens-tennis']
fall_sports = ['football', 'mens-soccer', 'field-hockey', 'womens-soccer', 'womens-volleyball']
spring_sports = list(set(sports) - set(fall_sports) - set(multi_year_sports))

saa_teams = ['berry', 'birmingham-southern', 'centre', 'hendrix', 'millsaps', 'oglethorpe', 'rhodes', 'sewanee']
schools = os.environ.get('SCHOOLS', 'berryvikings,bscsports,centrecolonels,hendrixwarriors,gomajors,rhodeslynx,sewaneetigers,trinitytigers,southwesternpirates,gopetrels').split(',')


start_year = int(os.environ.get('START_YEAR', 2024))  # fall of first year to get header data
end_year = int(os.environ.get('END_YEAR', 2025))  # fall of last year to get header data


def getTable(school, sport, year):
    SAA_dir = main_dir + sport + '/SAA/'
    if school in os.listdir(SAA_dir):
        # Folders on disk are `HTML` and `Tables` (capitals) — required on Linux CI.
        html_dir = main_dir + sport + '/SAA/' + school + '/HTML/' + year + '/'
    else:
        html_dir = main_dir + sport + '/Other/' + school + '/HTML/' + year + '/'

    header_dir = html_dir.replace('HTML', 'headers')
    table_dir = html_dir.replace('HTML', 'Tables')

    # if HTML directory exists for that year, create header directory if it doesn't already exist
    if os.path.exists(html_dir):
        header_files = sorted(os.listdir(header_dir))
        if not os.path.exists(table_dir):
            os.mkdir(table_dir)
    else: # otherwise, there is no data for this year
        return None

    #game = 1
    for html_file in sorted(os.listdir(html_dir)):
        if html_file.startswith('.'): # skips .DS_Store file
            continue

        print(html_file)
        soup = bs(open(html_dir + html_file, 'r'), 'html.parser')

        if sport == 'football':
            i = 0 # counter for df location
            quarter = 1
            away_score = 0
            home_score = 0
            poss_start_quarter = ''
            poss_start_time = ''
            headers = ['Team', 'DDY', 'Play', 'Quarter', 'AwayScore', 'HomeScore', 'StartPossQuarter', 'StartPossClock']
            df = pd.DataFrame(columns=headers)
            for quarter_data in soup.select('section[aria-label*="Quart"]'):
                #tables = quarter_data.find_all('table',
                #                      attrs={'class': 'sidearm-table overall-stats highlight-hover collapse-on-small'})
                tables = quarter_data.find_all('table',
                                      attrs={'class': 'sidearm-table overall-stats highlight-hover collapse-on-small'})
                #num_tables = length(tables)
                for table in tables:
                    cap = table.find('caption').text
                    if 'Start' not in cap and 'Halftime' not in cap:
                        cap_fields = cap.split(' at ')
                        team = cap_fields[0]
                        poss_start_quarter = quarter
                        poss_start_time = cap_fields[1]
                    elif '#2' in cap or '#4' in cap: # do not adjust team at start of 2nd or 4th Quarter
                        pass
                    else: # team resets at start of half or OT
                        team = ''
                        poss_start_quarter = ''
                        poss_start_time = ''
                    th = table.find('thead')
                    for row in th.find_all('tr'):
                        data = row.find_all('th')
                        start_data = [th.text.strip() for th in data]
                        if 'Start' in start_data[0]:
                            length = len(df)
                            df.loc[length] = ['']*2 + start_data + [quarter, away_score, home_score] + ['']*2

                    # for each row in the box score
                    for row in table.find('tbody').find_all('tr'):
                        row_data = [td.text.strip() for td in row.find_all('td')]
                        #print(row_data)

                        if row_data[0] != '': # assuming there is data
                            df.loc[i] = [team] + ['']*(2-len(row_data)) + row_data + [quarter, away_score, home_score, poss_start_quarter, poss_start_time]  # some rows don't have DDY
                            i += 1 # increment counter

                    #print(table.next_sibling.next_sibling)
                    #print(table)
                    score_update = table.next_sibling.next_element.find('dd')
                    #print(score_update)
                    if score_update != None and score_update != -1:
                        score_fields = score_update.text.split(' ')
                        if '-' in score_fields[1]:
                            away_score = score_fields[1].split('-')[0]
                            home_score = score_fields[1].split('-')[1]
                        elif '-' in score_fields[2]:
                            away_score = score_fields[2].split('-')[0]
                            home_score = score_fields[2].split('-')[1]
                        elif '-' in score_fields[3]:
                            away_score = score_fields[3].split('-')[0]
                            home_score = score_fields[3].split('-')[1]
                        else:
                            away_score = score_fields[4].split('-')[0]
                            home_score = score_fields[4].split('-')[1]
                        #print(away_score)

                quarter += 1 # increment quarter

            # Get Final score in last row
            try:
                score = quarter_data.find_all('dl', attrs={'class': 'special-stats emphasize primary inline text-center'})[-1]
                data = score.find_all('dd')
                row_data = [dl.text.strip() for dl in data]
                df.loc[i] = [''] + ['Final Score: ' + row_data[0]] + [quarter - 1]
            except:
                pass
             
        elif sport == 'baseball' or sport == 'softball':
            k = 1
            all_innings = soup.find_all('div', attrs= {'id': 'inning-all'})
            for i in all_innings:
                panels = i.find_all('div', attrs={'class': 'panel relative'})
                for panel in panels:
                    rows = panel.find_all('div', attrs= {'class': 'row pad'})
                    # print(rows)
                    for row in rows:   
                        table = row.find_all('table', attrs= {'class': 'sidearm-table play-by-play'})
                        # print(table)
                        dl = row.find_all('dl', attrs= {'class': 'special-stats emphasize inline text-right'})
                        # print(dl)
                        #print(table)
                        innings = []
                        summary = ''
                        for period in table: # for the table for each half inning 
                            for i in period.find_all('caption'):
                                inning = i.text.strip()
                                innings.append(inning)
                            
                            # get the header info for the first row
                            if k == 1:
                                headers=[]
                                for i in period.find_all('thead'):
                                    for i in period.find_all('th'):
                                        title = i.text.strip()
                                        headers.append(title)
                                headers = headers[0:3]
                                #print(headers)
                                df = pd.DataFrame(columns = ['Play Description', 'Away', 'Home'])
                            length=len(df)
                            df.loc[length] = [inning, '-', '-']

                            for row in period.find_all('tr')[1:]:
                                data = row.find_all(['td', 'th'])
                                row_data = [td.text.strip() for td in data]
                                length=len(df)
                                df.loc[length] = row_data
                                #print(row_data)
                            
                            k += 1

                        # get end of innings summary (# runs, hits, errors, LOB)
                        for item in dl:
                            dl_data = item.find_all(['dd', 'dt'])
                            dl_row_data = [td.text.strip() for td in dl_data]
                            for word in dl_row_data:
                                summary = summary + word + ' '
                        length=len(df)
                        df.loc[length] = [summary, '-', '-']  

        else: # for all other sports
            i = 0 # counter for df location
            period = 1
            first_iter = True
            tables = soup.find_all('table', attrs = {'class':'sidearm-table play-by-play'})

            if tables == []: # this is rare. Typically only occurs for earlier seasons.
                print('No pbp')
                continue

            for table in tables: # for each period/inning/half
                period_title = table.findNext('caption').text


                # get table headers (only need to do this in first iteration)
                if first_iter == True:
                    headers = []
                    away = True
                    for th in table.findNext('thead').find_all('th'):
                        th = th.text.strip()
                        if '- Play Description' in th:
                            if away == True:
                                th = 'Away Play'
                                away = False
                            else:
                                th = 'Home Play'
                        headers.append(th)
                    #print(headers)
                    headers.append('Period')
                    df = pd.DataFrame(columns = headers)
                    len_headers = len(headers)
                    first_iter = False

                # print period/inning/half title, along with blank spaces for the rest of the row
                #df.loc[i] = [period_title] + [''] * (len_headers-1)
                #i += 1

                # for each play within the table body, store all the fields in a data frame
                for row in table.findNext('tbody').find_all('tr'):
                    data = []
                    th_data = row.find('th') # some sports have first piece of play data in a table header
                    if th_data != None:
                        data.append(th_data.text) # store the data in the table header
                    for td in row.find_all('td'): # get all the other fields stored in table data
                        data.append(td.text.strip())
                    data.append(period)
                    if sport == 'womens-volleyball' and len(data) < len_headers: # volleyball subs are weird, need to compensate for fewer # of fields
                        df.loc[i] = data + [''] * (len_headers - len(data)) # now add volleyball subs data to df
                    else: # for all other sports, add the play data to the df
                        df.loc[i] = data
                    i += 1
                period += 1
            #print(df)

        # now print df to file
        file_info = html_file.rstrip('.html')
        for header_file in header_files:
            if file_info in header_file:
                fields = header_file.split('_header_')
                output_file = fields[0] + '_table_' + fields[1]
                df.to_csv(table_dir + output_file, index = False)
                break
        #game += 1

def main(schools, sports, start_year, end_year):
    multi_year_sports = ['mens-basketball', 'womens-basketball']
    fall_sports = ['football', 'mens-soccer', 'field-hockey', 'womens-soccer', 'womens-volleyball']

    for sport in sports:
        for school in schools:
            if sport in ['mens-tennis', 'womens-tennis']: # SAA tennis data begins in 2018
                year = max(start_year, 2018)
            else:
                year = max(start_year, 2010)

            while year <= end_year:
                if sport in multi_year_sports:
                    next_year = year + 1
                    year_str = str(year) + '-' + str(next_year)[-2:]
                elif sport in fall_sports:
                    year_str = str(year)
                else: # spring sport
                    year_str = str(year+1)

                getTable(school, sport, year_str)
                year += 1

main(schools, sports, start_year, end_year)
