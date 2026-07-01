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
# Config falls back to the manual defaults; the daily workflow overrides these.
main_dir = os.environ.get('PBP_ROOT', '/Users/jeff/Library/CloudStorage/OneDrive-CentreCollegeofKentucky/Research/Centre Sports Analytics/PBP Data/sports/')

#sports = ['baseball', 'mens-basketball', 'football', 'mens-lacrosse', 'mens-soccer', 'mens-tennis', 'womens-basketball',
#          'field-hockey', 'womens-lacrosse', 'womens-soccer', 'softball', 'womens-tennis', 'womens-volleyball']
sports = os.environ.get('SPORTS', 'baseball').split(',')

multi_year_sports = ['mens-basketball', 'womens-basketball', 'mens-tennis', 'womens-tennis']
fall_sports = ['football', 'mens-soccer', 'field-hockey', 'womens-soccer', 'womens-volleyball']
spring_sports = list(set(sports) - set(fall_sports) - set(multi_year_sports))

# LIST of all SAA schools (Oglethorpe data not accessible via scraping)
schools = os.environ.get('SCHOOLS', 'berryvikings,centrecolonels,gomajors,hendrixwarriors,rhodeslynx,sewaneetigers,trinitytigers,southwesternpirates').split(',')



start_year = int(os.environ.get('START_YEAR', 2025)) # fall of first year to pull data
end_year = int(os.environ.get('END_YEAR', 2026)) # fall of last year to pull data


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

            links_path = os.path.join(link_dir, filename)
            if not os.path.exists(links_path):
                print('  no links file for ' + school + ' (' + filename + '), skipping')
                continue

            with open(links_path, 'r') as links:
                for link in links:
                    link = link.rstrip()
                    if not link:
                        continue

                    # Everything needed to name the output file comes from the
                    # link string itself, so we can decide whether to download
                    # BEFORE making any network request.
                    link_fields = link.split('/')

                    opponent = link_fields[7]
                    opponent = re.sub(r'\d+', '', opponent)
                    opponent = opponent.rstrip('-')
                    opponent = opponent.lstrip('-')

                    game_id = link_fields[-1].rstrip()

                    html_dir = school_dir + '/HTML/'
                    # create HTML directory if it doesn't already exist
                    os.makedirs(html_dir, exist_ok=True)

                    # add year to directory
                    if sport in multi_year_sports:
                        html_dir = html_dir + multi_year_string + '/'
                    else:
                        html_dir = html_dir + str(year) + '/'
                    # create HTML/year/ directory if it doesn't already exist
                    os.makedirs(html_dir, exist_ok=True)

                    if sport in multi_year_sports:
                        outfile = team + '_' + sport + '_' + multi_year_string + '_' + game_id + '_' + opponent + '.html'
                    else:
                        outfile = team + '_' + sport + '_' + str(year) + '_' + game_id + '_' + opponent + '.html'

                    outpath = os.path.join(html_dir, outfile)

                    # INCREMENTAL: if this game's HTML is already on disk, skip
                    # it. This is what makes the daily run only fetch new games.
                    if os.path.exists(outpath):
                        continue

                    print('  downloading ' + link)
                    try:
                        r = requests.get(link, timeout=30, headers={'User-Agent': 'Mozilla/5.0 (research data collection)'})
                        r.raise_for_status()
                    except Exception as exc:
                        print('  skip ' + link + ': ' + str(exc))
                        continue

                    soup = bs(r.content, features='lxml')

                    with open(outpath, 'w') as g:
                        g.write(str(soup))

        year += 1
