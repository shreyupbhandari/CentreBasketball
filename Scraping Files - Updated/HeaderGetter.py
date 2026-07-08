#GetHeader
#info needed:
#season, date, opponent, scores, win/lose,overtime?,
#scores through each period, attendence
'''fully functioning header getter for all sports
'''
from bs4 import BeautifulSoup as bs
#import requests
import re
import pandas as pd
from pandas import DataFrame
import os
import datetime
import shutil
import glob
import urllib
#import urllib.request
from pathlib import Path


# Config falls back to the manual defaults; the daily workflow overrides these.
main_dir = os.environ.get('PBP_ROOT', '/Users/jeff/Library/CloudStorage/OneDrive-CentreCollegeofKentucky/Research/Centre Sports Analytics/PBP Data/sports/')
#sports = ['baseball', 'mens-basketball', 'football', 'mens-lacrosse', 'mens-soccer', 'mens-tennis', 'womens-basketball',
#              'field-hockey', 'womens-lacrosse', 'womens-soccer', 'softball', 'womens-tennis', 'womens-volleyball']
sports = os.environ.get('SPORTS', 'womens-basketball').split(',')

outdoor_sports = ['baseball', 'football', 'mens-lacrosse', 'mens-soccer', 'mens-tennis',
              'field-hockey', 'womens-lacrosse', 'womens-soccer', 'softball', 'womens-tennis']
multi_year_sports = ['mens-basketball', 'womens-basketball', 'mens-tennis', 'womens-tennis']
fall_sports = ['football', 'mens-soccer', 'field-hockey', 'womens-soccer', 'womens-volleyball']
spring_sports = list(set(sports) - set(fall_sports) - set(multi_year_sports))

saa_teams = ['berry', 'birmingham-southern', 'centre', 'hendrix', 'millsaps', 'oglethorpe', 'rhodes', 'sewanee']
schools = os.environ.get('SCHOOLS', 'berryvikings,bscsports,centrecolonels,hendrixwarriors,gomajors,rhodeslynx,sewaneetigers,gopetrels').split(',')



start_year = int(os.environ.get('START_YEAR', 2010))  # fall of first year to get header data
end_year = int(os.environ.get('END_YEAR', 2021))  # fall of last year to get header data


def getBoxScore(html_file, sport):
    # read in downloaded HTML
    soup = bs(open(html_file, 'r'), 'html.parser')

    if sport =='softball':
        boxscore = soup.find('article', {'class':'box-score softball sidearm-responsive'})
        #print (boxscore)
    elif sport == 'baseball':
        boxscore = soup.find('article', {'class':'box-score baseball sidearm-responsive'})
    else:
        boxscore = soup.find('section', {'id':'box-score'})
    return boxscore


def getTeams(boxscore, sport):
    #print(boxscore)
    teams = []
    if sport == 'baseball' or sport == 'softball' or 'lacrosse' in sport:
        #headline = boxscore.find('h2', {'class': 'hide text-center text-uppercase hide-on-medium-down'})
        # print(headline)
        #headline = headline.text.strip()
        #headline = headline.lower()
        #headline = headline.split("-vs-")
        #print(headline)

        try:
            team = boxscore.find('img')
            teams.append(team['alt'].split(' logo')[0])
            team = team.find_next('img')
            teams.append(team['alt'].split(' logo')[0])
        except:
            # if there is no data in the boxscore
            teams = ''
        
        #print(teams)
        #table_body = boxscore.find('tbody')
        #for team_tag in table_body.find_all('span', {'class': 'hide-on-small-down'}):
        #    teams.append(team_tag.get_text())
        #print(teams)

        #print(boxscore.find('img')['alt'].split(' logo')[0])
    elif 'tennis' in sport:
        headline = boxscore.find('div', {'class': 'team-names'})
        headline = headline.text.strip()
        headline = headline.lower()
        headline = headline.split(" ")
    elif sport == 'football':
        headline = boxscore.find('h4', {'class': 'main-heading text-center text-uppercase'})
        headline = headline.find_all(string=True)
        teams.append(headline[0].strip())
        teams.append(headline[2][6:].strip())
        #print(teams)
    else:
        try:
            table_body = boxscore.find('tbody')
            for team_tag in table_body.find_all('span', {'class': 'hide-on-small-down'}):
                teams.append(team_tag.get_text())
        except:
            # if there is no data in the boxscore
            teams = ''

    return teams


def getTeamAbbrevs(boxscore):
    abbrevs = []
    abbrev_tags = boxscore.find_all('th', {'class': 'text-right'})
    for abbrev in abbrev_tags:
        abbrevs.append(abbrev.text)
    return abbrevs

def getFinalScore(boxscore, sport):
    # Returns string of final score of game, e.g. '13-8', with team score listed first and then opponent score.

    #opp_index = 1 - team_index
    
    if sport == 'baseball' or sport == 'softball':
        information= boxscore.find('div',{'class':'row pad no-print'})
        scores= information.find_all('span',{'class':'hide-on-large'})
    else:
        information = boxscore.find('div',{'class':'box-score-graphic'})
        if 'basketball' in sport:
            scores = information.find_all('span')
            del scores[1]
        else:            
            scores= information.find_all('span',{'class':'score'})
        
    #opp_finalScore = scores[opp_index].text.strip()
    #team_finalScore = scores[team_index].text.strip()

    #final_score = str(team_finalScore)+'-'+ str(opp_finalScore)
    final_score = '-'.join([str(item.text.strip()) for item in scores])
    #print(final_score)
    return final_score

def getScoreByPeriod(boxscore, sport, year):
    '''Returns list of score by period. For example, [0,4,1,0] means team scored 0, 4, 1, and 0
    points in the four periods. Number of periods depends on the sport.
    This also includes the final score at the end???'''
    # index = team index (0 or 1, depending on if they are the first or second team listed in box score)
    if 'tennis' in sport:
        return "N/A"
    elif sport == 'baseball' or sport == 'softball':
        score_body = boxscore.find('tbody')
    else:
        header = boxscore.find('figure', {'class':'box-score-header'})
        score_body = header.find('tbody')
    score_lists = score_body.find_all('tr')
    sbp_lists = []

    for scores in score_lists: # for each team's list of scores
        score_by_period = []
        periods = scores.find_all('td')
        for score in periods:
            score_by_period.append(score.text)
            #print(score_by_period)
        if sport == "baseball" or sport =="softball":
            # last three entries are total runs, hits, and errors
            #for i in range(3):
            #    del score_by_period[len(score_by_period)-1]
            score_by_period = score_by_period[:-3]

            # first entry is team info, not the inning score
            del score_by_period[0]
        elif sport == 'mens-basketball':
            if not score_by_period[0].isnumeric():
                del(score_by_period[0]) # remove team name if in list
            if '-' in score_by_period[-1]: # remove record if in list
                del score_by_period[-1]
            del score_by_period[-1] # remove final score
        elif sport != 'womens-volleyball':
            del score_by_period[len(score_by_period)-1]
        if (sport == 'football' or 'soccer' in sport) and int(year) >= 2022: # remove first entry for 2022 because HTML encoding included team name in list
            del score_by_period[0]
        sbp_lists.append(score_by_period)

    #print(sbp_lists)
    return sbp_lists

def getTeamRecords(boxscore, sport):
    # Returns record of both teams and whether the game was an SAA game
    saa_game = 0

    if sport in ['baseball', 'softball']:
        records = boxscore.find('h2', {'class':'hide text-center text-uppercase hide-on-medium-down'}).text
    elif 'tennis' in sport:
        headline = boxscore.find('div', {'class': 'team-names'}).text
    elif 'basketball' in sport:
        header = boxscore.find('figure', {'class': 'box-score-header'})
        score_body = header.find('tbody')
        records = score_body.find_all('td', {'class': 'hide-on-small-down'})
    elif 'lacrosse' in sport or sport == 'football':
        records = boxscore.find('h4', {'class': 'main-heading text-center text-uppercase'})
        records = records.find_all('span')
    else:
        records = boxscore.find('h2', {'class': 'main-heading text-center text-uppercase'})
        records = records.find_all('span')

    if 'basketball' in sport or 'lacrosse' in sport or sport == 'football' or sport == 'field-hockey' or 'soccer' in sport:
        if len(records) == 2:
            record1 = records[0].text.strip('()')
            record2 = records[1].text.strip('()')
            #print(record1)
            [record1, confRecord1, saa_team1] = getConfRecord(record1)
            [record2, confRecord2, saa_team2] = getConfRecord(record2)
            saa_game = saa_team1 * saa_team2
        else:
            [record1, record2, confRecord1, confRecord2] = ['N/A', 'N/A', 'N/A', 'N/A']
    else:
        print(records)
        if 'vs' in records:
            [headline1, headline2] = records.split('vs')
        elif ' at ' in records:
            [headline1, headline2] = records.split(' at ')
        elif ' v ' in records:
            [headline1, headline2] = records.split(' v ')
        [record1, confRecord1, saa_game] = getOneRecord(headline1)
        [record2, confRecord2, saa_game] = getOneRecord(headline2)
    return [record1, record2, confRecord1, confRecord2, saa_game]

def getOneRecord(headline):
    # returns the record for one string

    # get indices of last occurences of parantheses to get the record
    index1 = headline.rfind('(')
    index2 = headline.rfind(')')

    if 'SAA' not in headline and 'SCAC' not in headline:
        saa_game = 0
        confRecord = 'N/A'
        record = headline[index1 + 1:index2].strip()
    else:
        saa_game = 1

        # contains both overall record and conference record
        records = headline[index1 + 1:index2].strip()

        fields = records.split(',')
        record = fields[0].strip()
        confRecord = fields[1].strip().split(' ')[0]

    return [record, confRecord, saa_game]

def getConfRecord(record):
    ## comment....
    saa_team = 0
    if ',' in record:
        fields = record.split(',')
        record = fields[0].strip()
        if 'SAA' in fields[1] or 'SCAC' in fields[1]:
            saa_team = 1
        confRecord = re.sub("[^0-9,-]","",fields[1]) # removes any conference name
    else:
        record = record.strip()
        confRecord = 'N/A'

    return [record, confRecord, saa_team]


def getWin(final_score):
    # Returns string if home team won, lost, or tied
    #final_score = getFinalScore(boxscore,sport,team_index)
    final_score = final_score.split('-')
    away_finalScore =int(final_score[0])
    home_finalScore= int(final_score[1])
    if away_finalScore == home_finalScore:
        return "Tie"
    elif home_finalScore > away_finalScore:
        return "Win"
    else:
        return "Lose"

def isOvertime(boxscore):
    # Returns True if overtime, False if not
    table_head = boxscore.find_all('th', {'scope':'col'})
    for heading in table_head:
        if 'OT' in heading.text:
            return True
    return False

def getGameInfo(boxscore,sport):
    # Returns the game's date, start time, elapsed time, and location
    if sport == 'baseball' or sport == 'softball' or 'basketball' in sport:
        information = boxscore.find('aside', {'class':'game-details'})
    else:
        information = boxscore.find('dl', {'class':'text-center inline'})

    titles = information.find_all('dt')
    #print(titles)

    [game_date, start_time, elapsed_time, game_loc, attendance, weather, temp, wind] = ['N/A', 'N/A', 'N/A', 'N/A', 'N/A', 'N/A', 'N/A', 'N/A']

    for title in titles:
        if 'Date' in title.text:
            game_date = title.findNext("dd").text
        elif 'Duration' in title.text or ('Time' in title.text and start_time != 'N/A'):
            elapsed_time = title.findNext("dd").text
        elif 'Start' in title.text or 'Kickoff' in title.text or 'Time' in title.text:
            start_time = title.findNext("dd").text
        elif 'Location' in title.text or 'Site' in title.text:
            game_loc = title.findNext("dd").text
        elif 'Attendance' in title.text:
            attendance = title.findNext("dd").text
        elif 'Weather' in title.text:
            weather = title.findNext("dd").text
        elif 'Temperature' in title.text:
            temp = title.findNext("dd").text
        elif 'Wind' in title.text:
            wind = title.findNext("dd").text
        elif 'VIEW' in title.text:
            continue
        else:
            print(title.text)

    return [game_date, start_time, elapsed_time, game_loc, attendance, weather, temp, wind]


def getBaseballStarters(boxscore_tab):
    """
    Parse a box‑score HTML file to extract the pitcher for each team and position suffix.

    Steps:
      1. Open and parse the HTML file using BeautifulSoup.
      2. Locate the “home” and “away” pitcher tables in the page:
         - For each side, we look under the box‑score section and grab the appropriate <table>.
      3. Iterate through each table row (skipping the header row):
         a. Read the first cell to get the defensive position prefix (e.g., 'p', 'c', '1b', etc.).
         b. Read the second cell to get the player’s name.
         c. If the position matches one of the valid prefixes and hasn’t already been recorded:
            • Use a regex to find the first capitalized sequence in the cell (the pitcher’s name).
            • Store it in a dictionary under a key like "p-home" or "p-away".
      4. After processing both tables, determine the maximum length of any column list
         (in practice, always one), and pad shorter lists with empty strings so all columns align.
      5. Return a pandas DataFrame with one row, where each column is named "<position>-<home|away>"
         and contains the extracted pitcher name (or '' if none was found).
         ON THE CLEANBASEBALL FILE IS WHERE WE START TO ALTER THE PLAYERS AT EACH POSITION (Substitution Logic)
    """
    # Define the list of position prefixes we care about
    valid_prefixes = ['1b', '2b', '3b', 'ss', 'cf', 'lf', 'rf', 'dh', 'p', 'c']
    # Open the HTML file and parse it with BeautifulSoup
    #with open(html_file_path, 'r') as f:
    #    soup = bs(f, 'html.parser')
     # Select the home team's box-score table by CSS selector
    home_table = boxscore_tab.select_one("#box-score > section:nth-child(3) > div > div:nth-child(2) > table")
     # Select the away team's box-score table by CSS selector
    away_table = boxscore_tab.select_one("#box-score > section:nth-child(3) > div > div:nth-child(1) > table")
    # Initialize a dict to collect pitcher names per position
    dynamic_columns = {}
    # Helper to process one table (home or away)
    def process_table(table, suffix):
        # Iterate rows, skipping the header row (index 0)
        for row in table.find_all('tr')[1:]:  # Skip the header row
            cells = row.find_all('td')
            if len(cells) > 1:
                position = cells[0].get_text(strip=True).lower()
                data = cells[1].get_text(strip=True)
                if position in valid_prefixes and f"{position}-{suffix}" not in dynamic_columns:
                    match = re.search(r'[A-Z].*', data)  # Match from first capital letter onward
                    if match:
                        value = match.group(0).strip()
                        dynamic_columns[f"{position}-{suffix}"] = [value]

    # Process home and away tables
    process_table(home_table, "home")
    process_table(away_table, "away")

    # Ensure columns are filled consistently
    max_length = max((len(v) for v in dynamic_columns.values()), default=0)
    starter_data = {column: values + [''] * (max_length - len(values)) for column, values in dynamic_columns.items()}

    return pd.DataFrame(starter_data)


def makeHeaders(main_dir, school, sport, year):
    if school in os.listdir(main_dir + sport + '/SAA/'):
        # Folder on disk is `HTML` (capital) — required for case-sensitive Linux CI.
        html_dir = main_dir + sport + '/SAA/' + school + '/HTML/' + year + '/'
        header_dir = html_dir.replace('HTML', 'headers')
    else:
        html_dir = main_dir + sport + '/Other/' + school + '/HTML/' + year + '/'
        header_dir = html_dir.replace('HTML', 'headers')

    # create header directory if it doesn't already exist
    if os.path.exists(html_dir):
        if not os.path.exists(header_dir):
            os.mkdir(header_dir)
    else: # otherwise, there is no data for this year
        return None

    game = 1
    for html_file in sorted(os.listdir(html_dir)):
        if html_file.startswith('.'): # skips .DS_Store file
            continue

        print(html_file)

        fields = html_file.split("_")

        team = fields[0]
        game_id = fields[3]
        opponent = fields[4].split('.')[0]

        boxscore_tab = getBoxScore(html_dir + html_file, sport)
        teams = getTeams(boxscore_tab, sport)
        
        # a few files have no data
        if teams == '':
            continue

        if sport == 'football':
            abbrevs = getTeamAbbrevs(boxscore_tab)

        finalScore = getFinalScore(boxscore_tab, sport)
        [awayScoreByPeriod, homeScoreByPeriod] = getScoreByPeriod(boxscore_tab, sport, year)
        hsbp = ','.join([str(item) for item in homeScoreByPeriod]) #puts the list of score by period into a string
        asbp = ','.join([str(item) for item in awayScoreByPeriod])

        [awayRecord, homeRecord, awayConfRecord, homeConfRecord, saa_game] = getTeamRecords(boxscore_tab, sport)
        if team in saa_teams and opponent in saa_teams: # ensuring that SAA game is signified (this wouldn't catch non-traditional SAA teams)
            saa_game = 1

        homeWin = getWin(finalScore)
        overtime = isOvertime(boxscore_tab)
        [game_date, start_time, game_length, game_loc, attendance, weather, temp, wind] = getGameInfo(boxscore_tab, sport)

        isNeutral = False ### NEED TO UPDATE!!!!
        #isHome = isHomeGame(boxscore_tab, sport)

        header = pd.DataFrame({'gameID': [game_id], 'homeTeam': [teams[1]], 'awayTeam': [teams[0]]})

        if sport == 'football':
            header['home_abbrev'] = abbrevs[1]
            header['away_abbrev'] = abbrevs[0]

        header['saaGame'] = saa_game
        header['finalScore'] = finalScore
        header['homeScoreByPeriod'] = hsbp
        header['awayScoreByPeriod'] = asbp
        header['homeRecord'] = homeRecord
        header['awayRecord'] = awayRecord
        header['homeConfRecord'] = homeConfRecord
        header['awayConfRecord'] = awayConfRecord
        header['gameDate'] = game_date
        header['startTime'] = start_time
        header['gameLength'] = game_length
        header['gameLocation'] = game_loc
        header['homeWin'] = homeWin
        header['numPeriods'] = len(homeScoreByPeriod)
        header['isOvertime'] = overtime
        header['attendance'] = attendance
        header['isNeutral'] = isNeutral

        if sport in outdoor_sports:
            header['weather'] = weather
            header['temp'] = temp
            header['wind'] = wind
        if saa_game == 1:
            header['homeConfRecord'] = homeConfRecord
            header['awayConfRecord'] = awayConfRecord

        if sport == 'baseball': 
            starter_data = getBaseballStarters(boxscore_tab)
            header = pd.concat([header, starter_data],axis=1)
                           
        #for i in range(0,len(homeScoreByPeriod)):
        #    header['homeScorePeriod'+ str(i+1)] = homeScoreByPeriod[i]

        #for i in range(0,len(awayScoreByPeriod)):
        #    header['awayScorePeriod'+ str(i+1)] = awayScoreByPeriod[i]

        #print(header)

        output_file = html_file.removesuffix('.html') + '_header_' + str(game) + '.csv'
        header.to_csv(header_dir + output_file, index = False)

        game += 1


def main(main_dir, schools, sports, start_year, end_year):
    #use this to test each sport
    # makeHeaders('mens-basketball', 2010)

    for sport in sports:
        for school in schools:
            if sport in ['mens-tennis', 'womens-tennis']:
                year = max(start_year, 2018)
            else: #sport in fall_sports:
                year = max(start_year, 2010)
            #else: # for spring sports
            #    start_year += 1
            #    year = max(start_year, 2011)

            while year <= end_year:
                #year2 = year + 1
                #if sport in multi_year_sports:
                    #years = str(year) + '-' + str(year2)
                #else:
                    #years = year
                if sport in multi_year_sports:
                    next_year = year + 1
                    year_str = str(year) + '-' + str(next_year)[-2:]
                elif sport in fall_sports:
                    year_str = str(year)
                else: # spring sport
                    year_str = str(year+1)

                makeHeaders(main_dir, school, sport, year_str)

                year += 1

main(main_dir, schools, sports, start_year, end_year)
          
