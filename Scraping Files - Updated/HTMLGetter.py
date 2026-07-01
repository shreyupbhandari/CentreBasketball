# HTMLGetter.py
# Once the links have been created using LinkCreatorAll.py, this file will traverse the files containing
# the links to the schools/sports/years specified in this file, scrape the HTML from those URL's, and
# write all of the HTML code to file.

import requests
from bs4 import BeautifulSoup as bs
import re
# import pandas as pd
# from csv import reader
import os

# This base directory just uses field-hockey, but it would eventually be able to look through the
# folders for each sport we're scraping
#base_dir = '/Users/ericmerdian/Desktop/Desktop/A_Summer_Research/field-hockey/'
main_dir = '/Users/jeff/Library/CloudStorage/OneDrive-CentreCollegeofKentucky/Research/Centre Sports Analytics/PBP Data/sports/'

#sports = ['baseball', 'mens-basketball', 'football', 'mens-lacrosse', 'mens-soccer', 'mens-tennis', 'womens-basketball',
#          'field-hockey', 'womens-lacrosse', 'womens-soccer', 'softball', 'womens-tennis', 'womens-volleyball']
sports = ['baseball']

multi_year_sports = ['mens-basketball', 'womens-basketball', 'mens-tennis', 'womens-tennis']
fall_sports = ['football', 'mens-soccer', 'field-hockey', 'womens-soccer', 'womens-volleyball']
spring_sports = list(set(sports) - set(fall_sports) - set(multi_year_sports))

# LIST of all SAA schools (Oglethorpe data not accessible via scraping)
#schools = ['berryvikings', 'bscsports', 'centrecolonels', 'gomajors', 'hendrixwarriors', 'rhodeslynx', 'sewaneetigers']
schools = ['berryvikings', 'centrecolonels', 'gomajors', 'hendrixwarriors', 'rhodeslynx', 'sewaneetigers','gopetrels']
#schools = ['hanover', 'mcscots']
#schools = ['hscathletics', 'trinitytigers', 'southwesternpirates']
#schools = ['trinitytigers', 'southwesternpirates']
schools = ['berryvikings', 'centrecolonels', 'gomajors', 'hendrixwarriors', 'rhodeslynx', 'sewaneetigers', 'trinitytigers', 'southwesternpirates']



start_year = 2025 # fall of first year to pull data
end_year = 2026 # fall of last year to pull data


for sport in sports:
    year = start_year
    while year <= end_year:
        print(year)
        if sport in spring_sports:
            year = year + 1
        elif sport in multi_year_sports:
                next_year = year + 1
                year_ext = str(next_year)[-2:]
                multi_year_string = str(year) + '-' + year_ext

        for school in schools:
            print(school)

            SAA_dir = main_dir + sport + '/SAA/'
            if school in os.listdir(SAA_dir):
                school_dir = main_dir + sport + '/SAA/' + school
                link_dir = school_dir + '/links/'
            else:
                school_dir = main_dir + sport + '/Other/' + school
                link_dir = school_dir + '/links/'

            match school:
                case 'berryvikings':
                    team = 'berry'
                case 'bscsports':
                    team = 'birmingham-southern'
                case 'centrecolonels':
                    team = 'centre'
                case 'hendrixwarriors':
                    team = 'hendrix'
                case 'gomajors':
                    team = 'millsaps'
                case 'rhodeslynx':
                    team = 'rhodes'
                case 'sewaneetigers':
                    team = 'sewanee'
                case 'gopetrels':
                    team = 'oglethorpe' #SB: Added a case for Oglethorpe.
                case _: # default
                    team = school

            # open file with links for given year
            if sport in multi_year_sports:
                filename = multi_year_string + '_links.csv'
            else:
                filename = str(year) + '_links.csv'

            with open(os.path.join(link_dir, filename), 'r') as links:
                for link in links:
                    link = link.rstrip()
                    print(link)
                    r = requests.get(link)

                    soup = bs(r.content, features='lxml')

                    # Print out html
                    # print(soup.prettify())

                    link_fields = link.split('/')

                    opponent = link_fields[7]
                    opponent = re.sub(r'\d+', '', opponent)
                    opponent = opponent.rstrip('-')
                    opponent = opponent.lstrip('-')

                    game_id = link_fields[-1].rstrip()

                    html_dir = school_dir + '/HTML/'
                    
                    # create HTML directory if it doesn't already exist
                    if not os.path.exists(html_dir):
                        os.mkdir(html_dir)

                    # add year to directory
                    if sport in multi_year_sports:
                        html_dir = html_dir + multi_year_string + '/'    
                    else:
                        html_dir = html_dir + str(year) + '/'
                    
                    # create HTML/year/ directory if it doesn't already exist
                    if not os.path.exists(html_dir):
                        os.mkdir(html_dir)

                    if sport in multi_year_sports:
                        outfile = team + '_' + sport + '_' + multi_year_string + '_' + game_id + '_' + opponent + '.html'
                    else:
                        outfile = team + '_' + sport + '_' + str(year) + '_' + game_id + '_' + opponent + '.html'
                    
                    with open(os.path.join(html_dir, outfile), 'w') as g:
                        g.write(str(soup))

        year += 1
