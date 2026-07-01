# LinkCreatorAll.py
# For specified schools, sports, and years, this file will scrape all of the box score url's from the
# schedule webpages, and write those url's to folders within each school/sport/year.

import requests
from bs4 import BeautifulSoup as bs
import re
import pandas as pd
from pandas import DataFrame
import os
import shutil
import glob

main_dir = '/Users/jeff/Library/CloudStorage/OneDrive-CentreCollegeofKentucky/Research/Centre Sports Analytics/PBP Data/sports/'

# These were the sports that have box scores on their schedule pages.
# Not all sports would have them, such as track and field, cheer, etc.
#sports = ['baseball', 'mens-basketball', 'football', 'mens-lacrosse', 'mens-soccer', 'mens-tennis', 'womens-basketball', 
#          'field-hockey', 'womens-lacrosse', 'womens-soccer', 'softball', 'womens-tennis', 'womens-volleyball']
sports = ['baseball']


multi_year_sports = ['mens-basketball', 'womens-basketball', 'mens-tennis', 'womens-tennis']
fall_sports = ['football', 'mens-soccer', 'field-hockey', 'womens-soccer', 'womens-volleyball']
spring_sports = list(set(sports) - set(fall_sports) - set(multi_year_sports))

#schools = ['berryvikings', 'bscsports', 'centrecolonels', 'hendrixwarriors', 'gomajors', 'rhodeslynx', 'sewaneetigers']
#schools = ['hanover', 'mcscots']
#schools = ['hscathletics', 'trinitytigers', 'southwesternpirates']
#schools = ['berryvikings', 'centrecolonels', 'hendrixwarriors', 'gomajors', 'rhodeslynx', 'sewaneetigers']
#schools = ['trinitytigers', 'southwesternpirates']
schools = ['berryvikings', 'centrecolonels', 'gomajors', 'hendrixwarriors', 'rhodeslynx', 'sewaneetigers', 'trinitytigers', 'southwesternpirates' , 'gopetrels']



start_year = 2025 # fall of first year to pull data
end_year = 2026 # fall of last year to pull data

for school in schools:
    if school == 'hanover':
        base_path = 'https://athletics.hanover.edu'
    elif school == 'bscsports':
        base_path = 'https://' + school + '.net'
    else:
        base_path = 'https://' + school + '.com' #SB: This base case should work for Oglethorpe as well.
    print(base_path)
    # if school == 'gopetrels': # Oglethorpe doesn't work. Oh well, I guess!
    #     sports = ['bsb', 'mbkb', 'football', 'mlax', 'msoc', 'mten', 'wbkb', 'field-hockey', 'wlax', 'wsoc', 'softball', 'wten', 'wvball']

    #for ind, sport in enumerate(sports):
    for sport in sports:
        year = start_year

        # start of SAA tennis box score data online begins in 2018-19 (Is this consistent across all schools???)
        if sport == 'mens-tennis' or sport == 'womens-tennis':
            if year < 2018:
                year = 2018

        SAA_dir = main_dir + sport + '/SAA/'
        if school in os.listdir(SAA_dir):
            school_dir = main_dir + sport + '/SAA/' + school
            present_dir = main_dir + sport + '/SAA/' + school + '/links/'
        else:
            school_dir = main_dir + sport + '/Other/' + school
            present_dir = main_dir + sport + '/Other/' + school + '/links/'        

        if not os.path.exists(school_dir):
            os.mkdir(school_dir)

        if not os.path.exists(present_dir):
            os.mkdir(present_dir)

        while year <= end_year: # keep pulling data for all years (falls) between start_year and end_year
            # increment year by 1 for spring sports
            if sport in spring_sports:
                year = year + 1

            # these school, fall sport combinations used 2020-21 as the year as opposed to 2020
            covid = 0
            if year == 2020:
                if [school, sport]  in [['berryvikings', 'mens-soccer'], ['bscsports', 'womens-volleyball'],
                    ['bscsports', 'womens-soccer'],['gomajors','football'],
                    ['hendrixwarriors', 'football'], ['hendrixwarriors', 'mens-soccer'], ['hendrixwarriors', 'womens-soccer'],
                    ['hendrixwarriors', 'womens-volleyball'], ['sewaneetigers', 'field-hockey'], ['sewaneetigers', 'mens-soccer'],
                    ['sewaneetigers', 'womens-soccer']]:
                    covid = 1

            # Berry tennis started to not use hyphenated years in spring 2021
            if 'tennis' in sport and school == 'berryvikings' and year >= 2020:
                url = base_path + '/sports/' + str(sport) + '/schedule/' + str(year+1)
                next_year = year + 1
                year_ext = str(next_year)[-2:]
                multi_year_string = str(year) + '-' + year_ext
            # multi-year sports and certain fall 2020 sports/schools use hyphenated years
            elif sport in multi_year_sports or covid == 1:
                next_year = year + 1
                year_ext = str(next_year)[-2:]
                multi_year_string = str(year) + '-' + year_ext
                url = base_path + '/sports/' + str(sport) + '/schedule/' + multi_year_string
                print( url)
            # all other sports just use the calendar year
            else:
                url = base_path + '/sports/' + str(sport) + '/schedule/' + str(year)
            # if school == 'gopetrels':
            #     next_year = year + 1
            #     year_ext = str(next_year)[-2:]
            #     url = base_path + '/sports/' + str(sport) + '/' + str(year) + '-' + year_ext + '/schedule/' 

            print(url)
            r = requests.get(url)

            # Convert to a BS object
            #soup = bs(r.content, features='lxml')
            soup = bs(r.content, features='html.parser')

            # Print out html
            # print(soup.prettify())

            links = []
            # SB: Oglethorpe (gopetrels) migrated to Sidearm, so it now uses the
            # same box-score markup as every other school.
            for li in soup.find_all(class_="sidearm-schedule-game-links-boxscore"):
                links.append(li.a.get('href'))

            # print(links)


            full_link_list = []

            for index, link in enumerate(links):
                full_path = base_path + link
                
                full_link_list.append(full_path)

            # Many schools have double links. This line gets a unique list.
            full_link_list = list(dict.fromkeys(full_link_list))

            df = DataFrame (full_link_list, columns=['Links'])

            print(df)

            if sport in multi_year_sports:
                filename = present_dir + multi_year_string + '_links.csv'
            else:
                filename = present_dir + str(year) + '_links.csv'
            df.to_csv(filename, index = False, header=False)

            # increment to next year (except for spring sports, which were already incremented when loop began)
            if sport not in spring_sports:
                year = year + 1

        # After all the links have been put in for each year's file, we can then combine them into a merged file

        # allFiles = glob.glob(present_dir + "/*.csv")
        # allFiles.sort()
        # os.chdir(present_dir)
        # with open('merged' + sport + '.csv', 'wb') as outfile:
        #     for i, fname in enumerate(allFiles):
        #         with open(fname, 'rb') as infile:
        #             shutil.copyfileobj(infile, outfile)
        #             print(fname + " has been imported.")

        # if not os.path.exists(present_dir + '/HTML'):
        #     os.mkdir(present_dir + '/HTML')
        # if not os.path.exists(present_dir + '/Tables'):
        #     os.mkdir(present_dir + '/Tables')
        year = start_year

