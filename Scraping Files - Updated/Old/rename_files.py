# added opponent name to HTML filename
# this file should be unnecessary after the change, and also now that the HTMLGetter.py file
# automatically adds the opponent name.

import os
import re

main_dir = '/Users/jeffrey.heath/Library/CloudStorage/OneDrive-CentreCollegeofKentucky/Research/Centre Sports Analytics/PBP Data/SAA/'

sports = ['baseball', 'mens-basketball', 'football', 'mens-lacrosse', 'mens-soccer', 'mens-tennis', 'womens-basketball',
          'field-hockey', 'womens-lacrosse', 'womens-soccer', 'softball', 'womens-tennis', 'womens-volleyball']

multi_year_sports = ['mens-basketball', 'womens-basketball', 'mens-tennis', 'womens-tennis']
fall_sports = ['football', 'mens-soccer', 'field-hockey', 'womens-soccer', 'womens-volleyball']
spring_sports = list(set(sports) - set(fall_sports) - set(multi_year_sports))

# Oglethorpe data not accessible via scraping
schools = ['berryvikings', 'bscsports', 'centrecolonels', 'gomajors', 'hendrixwarriors', 'rhodeslynx', 'sewaneetigers']

for school in schools:

    # match school:
    #     case 'berryvikings':
    #         team = 'berry'
    #     case 'bscsports':
    #         team = 'birmingham-southern'
    #     case 'centrecolonels':
    #         team = 'centre'
    #     case 'hendrixwarriors':
    #         team = 'hendrix'
    #     case 'gomajors':
    #         team = 'millsaps'
    #     case 'rhodeslynx':
    #         team = 'rhodes'
    #     case 'sewaneetigers':
    #         team = 'sewanee'

    for sport in sports:
        link_dir = main_dir + school + '/' + str(sport) + '/links/'
        html_dir = main_dir + school + '/' + str(sport) + '/HTML/'

        # create HTML directory if it doesn't already exist
        #if not os.path.exists(html_dir):
        #    os.mkdir(html_dir)


        ### This loop added the opponent name to the HTML files. ###
        # for filename in os.listdir(link_dir):
        #
        #     year = filename.split('_')[0]
        #
        #     html_year_dir = html_dir + year + '/'
        #
        #     # create HTML year directory if it doesn't already exist
        #     #if not os.path.exists(html_year_dir):
        #     #    os.mkdir(html_year_dir)
        #
        #     os.chdir(html_year_dir)
        #
        #     with open(os.path.join(link_dir,filename), 'r') as links:
        #         for link in links:
        #             link = link.rstrip()
        #             print(link)
        #
        #             link_fields = link.split('/')
        #
        #             opponent = link_fields[7]
        #             opponent = re.sub(r'\d+', '', opponent)
        #             opponent = opponent.rstrip('-')
        #             opponent = opponent.lstrip('-')
        #
        #             game_id = link_fields[9]
        #
        #             oldname = school + '_' + sport + '_' + year + '_' + game_id + '.html'
        #             newname = school + '_' + sport + '_' + year + '_' + opponent + '_' + game_id + '.html'
        #
        #             os.rename(oldname, newname)

        ### This loop changed team name from website name (e.g., berryvikings) to just the school (e.g., berry). ###
        # for year in os.listdir(html_dir):
        #     html_year_dir = html_dir + year + '/'
        #
        #     try:
        #         os.chdir(html_year_dir)
        #     except:
        #         print(html_year_dir)
        #         continue
        #
        #     for filename in os.listdir(html_year_dir):
        #         fields = filename.split('_')
        #         school = fields[0]
        #         opponent = fields[3]
        #         game_id = fields[4].rstrip('.html')
        #
        #         oldname = school + '_' + sport + '_' + year + '_' + opponent + '_' + game_id + '.html'
        #         newname = team + '_' + sport + '_' + year + '_' + opponent + '_' + game_id + '.html'
        #
        #         os.rename(oldname, newname)

        ### This loop makes game_id a 4 digit number, e.g., changes 647 to 0647, so that they remain in alphanumeric order. ###
        for year in os.listdir(html_dir):
            html_year_dir = html_dir + year + '/'

            try:
                os.chdir(html_year_dir)
            except:
                print(html_year_dir)
                continue

            for filename in os.listdir(html_year_dir):
                fields = filename.split('_')
                team = fields[0]
                game_id = fields[3]
                opponent = fields[4].split('.')[0]

                num_digits = len(game_id)
                old_game_id = game_id

                for i in range(0,4-num_digits):
                    game_id = '0' + game_id

                oldname = team + '_' + sport + '_' + year + '_' + old_game_id + '_' + opponent + '.html'
                newname = team + '_' + sport + '_' + year + '_' + game_id + '_' + opponent + '.html'

                os.rename(oldname, newname)