from bs4 import BeautifulSoup as bs
import pandas as pd
from pandas import DataFrame
import os
import urllib
import urllib.request
from pathlib import Path
import csv
import re


userPath = '/Users/ericmerdian/Desktop/Desktop/A_Summer_Research/'

def getOfficialName(boxscore,sport):
    headline=[]
    
 
    away_team = boxscore.find('div', {'class':'team away large-3 x-small-4 columns text-center'})
    print("away team is", away_team)
    
    away_logo = away_team.find('img')
    home_team = boxscore.find('div',{'class':'team home large-3 push-4 x-small-4 columns text-center'})
    print("home team is", home_team)
    home_logo= home_team.find('img')
    headline.append(away_logo.attrs['alt'])
    headline.append(home_logo.attrs['alt'])
    centre_index = getCentreIndex(boxscore)
    if centre_index == 1:
        opponent_index = 0
    else:
        opponent_index = 1

    opponent_name = headline[opponent_index]
    opponent_name = opponent_name.replace('logo','')
    opponent_name = opponent_name.strip()
    opponent_name = opponent_name.lower()
 
    centre_name = headline[centre_index]
    centre_name = centre_name.replace('logo','')
    centre_name = centre_name.strip()
    centre_name = centre_name.lower()

    return opponent_name, centre_name
           

def getBoxScore(game_url):
    r = urllib.request.urlopen(game_url)
            # Convert to a BS object
    soup = bs(r, 'html.parser')
    boxscore = soup.find('article', {'class':'box-score baseball sidearm-responsive'})
    return boxscore
def getCentreIndex(boxscore):
    headline=[]
    away_team = boxscore.find('div', {'class':'team away large-3 x-small-4 columns text-center'})
    away_logo = away_team.find('img')
    home_team = boxscore.find('div',{'class':'team home large-3 push-4 x-small-4 columns text-center'})
    home_logo= home_team.find('img')
    
    headline.append(away_logo.attrs['alt'])
    headline.append(home_logo.attrs['alt'])
   

    if "centre" in headline[0]:
        index = 0
    else:
        index = 1
    return index




   
def makeHeaderPBP(sport, year1):
    # output_dir = Path('/Users/ericmerdian/Desktop/Desktop/A_Summer_Research/' + sport + '/headers/' + str(year1) + '/')
    sport_schedule = open(userPath + sport + '/' + str(year1) + '_links.csv', 'r')
    sport_games = [line.rstrip('\n') for line in sport_schedule]
    sport_schedule.close()
    game = 1
    for game_url in sport_games:
        print(game_url)
        list_game = game_url.split("/")
        try:
            r= urllib.request.urlopen(game_url)
            game_opponent = list_game[7]
            game_id= list_game[9]
            boxScoreTab = getBoxScore(game_url)
            
            soup = bs(r, 'html.parser')
            
          
            header = open(userPath + sport + '/' + 'headers' + '/' +
                  str(year1) + '/'+ 'game' +str(game)+'_'+ game_opponent+'_'+str(game_id)+'.csv', 'r')
 
            #assigns first row of the header as list'header_titles' and second row as 'header_info'
            header_data = list(csv.reader(header))
            # print(header_data)
            header_titles = header_data[0]
            header_info = header_data[1]
            path = userPath + sport + '/' + 'Tables' + '/' + str(year1) + '/'+ str(game_id)+'_'+ game_opponent+'.csv'

            if os.path.exists(path):
                table = open(userPath + sport + '/' + 'Tables' + '/' +
                              str(year1) + '/'+ str(game_id)+'_'+ game_opponent+'.csv', 'r')

                #assigns the first row of the table as list'table_titles'
                table_data = list(csv.reader(table))
                table_titles = table_data[0]

                #puts all titles into a combined list
                all_titles = header_titles
                all_titles.extend(table_titles)

                df = pd.DataFrame(columns = all_titles)

                i = 1
                for row in range(len(table_data)-1):
                    combined = header_info[:]
                    combined.extend(table_data[i])
                    df.loc[len(df.index)] = combined
                    i+=1

                # print(df)

                df = df.drop(['centreScoreByPeriod', 'opponentScoreByPeriod', 'attendance', 'Play Team Indicator', 'Game Score', 'Team Indicator', 'Play'], axis = 1)
                                               
                df = df[df.columns.drop(list(df.filter(regex='ScorePeriod')))]

                df.columns.values[10] = "Away Team"
                df.columns.values[13] = "Home Team"

                print(df)

                for i in df.index:
                    awayScore = df['Away Team Score'][i]
                    homeScore = df['Home Team Score'][i]
                    if awayScore != '':
                        rowAwayScore = awayScore.split(' ')[0]
                        df.at[i, 'Away Team Score'] = rowAwayScore
                        # print(rowAwayScore)
                    if homeScore != '':
                        rowHomeScore = homeScore.split(' ')[0]
                        # print(rowHomeScore)
                        df.at[i, 'Home Team Score'] = rowHomeScore 

                # This fills in team scores in case there wasn't any points scored in a round
                home_team_score = 0
                visiting_team_score = 0
                period_num = 0

                point_differential = []
                period_list = []
                time_remaining_mins = []
                time_remaining_secs = []

                home_play_type = []
                away_play_type = []
                home_good_bad = []
                away_good_bad = []


                # print(df)
                home_shots_taken = 0
                home_shots_made = 0
                away_shots_taken = 0
                away_shots_made = 0


                home_3_taken = 0
                home_3_made = 0
                away_3_taken = 0
                away_3_made = 0


                home_shooting_pct = []
                away_shooting_pct = []
                home_shots_taken_tally = []
                away_shots_taken_tally = []
                home_3_shooting_pct = []
                away_3_shooting_pct = []
                home_3_shots = []
                away_3_shots = []


                for ind in df.index:
                    if df['Home Team Score'][ind] == '':
                        df['Home Team Score'][ind] = home_team_score
                    else:
                        home_team_score = df['Home Team Score'][ind]
                    if df['Away Team Score'][ind] == '':
                        df['Away Team Score'][ind] = visiting_team_score
                    else:
                        visiting_team_score = df['Away Team Score'][ind]     
                    point_differential.append(int(df['Home Team Score'][ind]) - int(df['Away Team Score'][ind]))
                    if 'Period' in df['Time Remaining'][ind]:
                        period_num += 1
                    period_list.append(period_num)
                    if '--' in df['Time Remaining'][ind]:
                        df.at[ind, 'Time Remaining'] = df['Time Remaining'][ind - 1]
                    home_play = df.iloc[ind, 10].lower()
                    away_play = df.iloc[ind, 13].lower()
                    if 'foul' in home_play:
                        home_play_type.append('foul')
                    elif 'jumper' in home_play:
                        home_play_type.append('jumper')
                    elif ' ft ' in home_play:
                        home_play_type.append('ft')
                    elif '3ptr' in home_play:
                        home_play_type.append('3ptr')
                        if 'good' in home_play:
                            home_3_made += 1
                        home_3_taken += 1
                        # print(home_3_made, home_3_taken)
                    elif 'layup' in home_play:
                        home_play_type.append('layup')
                    else:
                        home_play_type.append('')
                    if 'good' in home_play:
                        home_good_bad.append('good')
                        home_shots_made += 1
                        home_shots_taken += 1
                    elif 'miss' in home_play:
                        home_good_bad.append('miss')
                        home_shots_taken += 1         
                    else:
                        home_good_bad.append('')
                    if home_shots_taken != 0:
                        home_shooting_pct.append(round(home_shots_made / home_shots_taken, 3))
                    else:
                        home_shooting_pct.append('')
                    if home_3_taken != 0:
                        home_3_shooting_pct.append(round(home_3_made / home_3_taken, 3))
                    else:
                        home_3_shooting_pct.append('')
                    home_shots_taken_tally.append(home_shots_taken)
                    print(home_3_taken)
                    home_3_shots.append(home_3_taken)
                    if 'foul' in away_play:
                        away_play_type.append('foul')
                    elif 'jumper' in away_play:
                        away_play_type.append('jumper')
                    elif ' ft ' in away_play:
                        away_play_type.append('ft')
                    elif '3ptr' in away_play:
                        away_play_type.append('3ptr')
                        if 'good' in away_play:
                            away_3_made += 1
                        away_3_taken += 1
                    elif 'layup' in away_play:
                        away_play_type.append('layup')
                    else:
                        away_play_type.append('')
                    if 'good' in away_play:
                        away_good_bad.append('good')
                        away_shots_made += 1
                        away_shots_taken += 1

                    elif 'miss' in away_play:
                        away_good_bad.append('miss')
                        away_shots_taken += 1
                    else:
                        away_good_bad.append('')
                    if away_shots_taken != 0:
                        away_shooting_pct.append(round(away_shots_made / away_shots_taken, 3))
                    else:
                        away_shooting_pct.append('')
                    if away_3_taken != 0:
                        away_3_shooting_pct.append(round(away_3_made / away_3_taken, 3))
                    else:
                        away_3_shooting_pct.append('')
                    away_shots_taken_tally.append(away_shots_taken)
                    away_3_shots.append(away_3_taken)


                df['Point Differential'] = point_differential
                df['Period'] = period_list


                df['Home Play Type'] = home_play_type
                df['Home Shot Good'] = home_good_bad
                df['Home Shots Taken'] = home_shots_taken_tally
                df['Home 3PTRs Taken'] = home_3_shots
                df['Home Shooting PCT'] = home_shooting_pct
                df['Home 3PTRs PCT'] = home_3_shooting_pct

                df['Away Play Type'] = away_play_type
                df['Away Shot Good'] = away_good_bad
                df['Away Shots Taken'] = away_shots_taken_tally
                df['Away 3PTRs Taken'] = away_3_shots
                df['Away Shooting PCT'] = away_shooting_pct
                df['Away 3PTRs PCT'] = away_3_shooting_pct

                for ind in df.index:
                    row_time = df['Time Remaining'][ind]
                    

                    if 'Period' in df['Time Remaining'][ind]:
                        df = df.drop(ind)
                    else:
                        mins, secs = row_time.split(':')
                        if df['Period'][ind] == 1:
                            time_remaining_mins.append(int(mins) + 20)
                            time_remaining_secs.append((int(mins) + 20) * 60 + int(secs))
                        else:
                            time_remaining_mins.append(mins)
                            time_remaining_secs.append(int(mins) * 60 + int(secs))

                df['Time Remaining Mins'] = time_remaining_mins
                df['Time Remaining Secs'] = time_remaining_secs

                print(df)


                # cols = list(df.columns)
                # for i in cols:
                #     print(df[i])
                # print(cols)


                output_file = 'game'+str(game)+'_'+game_opponent+'_'+str(game_id)+'.csv'
                output_dir = Path(userPath + sport + '/CombinedHeaderTable/' + str(year1) + '/')
                output_dir.mkdir(parents=True, exist_ok=True)
                df.to_csv(output_dir / output_file, index = False)

                mins_remaining = []

                home_score = []

                away_score = []

                point_diff = []

                # possession = []

                period = []

                mbm_cols = ['opponent name', 'final score', 'gameDate', 'outcome', 'homeGame', 'Point Differential', 'Period', 'Time Remaining Mins']

                min_df = pd.DataFrame(columns = mbm_cols)

                print(len(df))

                for row in range(1, len(df) - 1):
                    # print(df['Time Remaining Mins'].iloc[row], df['Time Remaining Mins'].iloc[row + 1])
                    # print(row)
                    if row != len(df) - 2:
                        if row != 0:
                            current_minute = df['Time Remaining Mins'].iloc[row]
                            if row != 1:
                                if df['Time Remaining Mins'].iloc[row] != df['Time Remaining Mins'].iloc[row + 1]:
                                    missing_rows = int(df['Time Remaining Mins'].iloc[row]) - int(df['Time Remaining Mins'].iloc[row + 1])
                                    # If there are several minutes where we do not have a change of possession, fill in with the previous row's information
                                    if missing_rows != 1:
                                        for i in range(missing_rows):
                                            # print(int(df['Time Remaining Mins'][row]) - i)
                                            mins_remaining.append(int(df['Time Remaining Mins'][row]) - i)
                                            # possession.append(df['Team'][row])
                                            home_score.append(int(df['Home Team Score'][row]))
                                            away_score.append(int(df['Away Team Score'][row]))
                                            point_diff.append(int(df['Point Differential'][row]))
                                            period.append(int(df['Period'][row]))
                                            # final_df.append((df.iloc[row]))
                                            missing_rows -= 1
                                    # Otherwise, this is the only row with information of a minute and so is the following row
                                    else:
                                        # final_df.append(df.iloc[row])
                                        # print(df['Time Remaining Mins'][row])
                                        mins_remaining.append(int(df['Time Remaining Mins'][row]))
                                        # possession.append(df['Team'][row])
                                        home_score.append(int(df['Home Team Score'][row]))
                                        away_score.append(int(df['Away Team Score'][row]))
                                        point_diff.append(int(df['Point Differential'][row]))
                                        period.append(int(df['Period'][row]))
                                else:
                                    if row == 0 and df['Time Remaining Mins'].loc[row] != 60:
                                        additional_row = 60 - int(df['Time Remaining Mins'].loc[row])
                                

                    # If this is the last row in the dataframe, check remaining minutes and fill in the remaining time
                    else:
                        # print(df['Drive Result'][row])
                        if int(df['Time Remaining Mins'].iloc[row]) != 0:
                            remaining_rows = int(df['Time Remaining Mins'][row])
                            print(remaining_rows)
                            for i in range(remaining_rows + 1):
                                # print(remaining_rows)
                                mins_remaining.append(remaining_rows)
                                # possession.append(df['Team'][row])
                                home_score.append(int(df['Home Team Score'][row]))
                                away_score.append(int(df['Away Team Score'][row]))
                                point_diff.append(int(df['Point Differential at End of Drive'][row]))
                        else:
                            mins_remaining.append(0)
                            home_score.append(int(df['Home Team Score'][row]))
                            away_score.append(int(df['Away Team Score'][row]))
                            point_diff.append(int(df['Point Differential'][row]))
                            period.append(int(df['Period'][row]))
                print(len(mins_remaining))
                print(len(away_score))
                print(len(home_score))
                print(len(point_diff))
                print(len(period))
                print(mins_remaining)
                print(away_score)
                print(home_score)
                print(point_diff)
                print(period)

                df_len = len(period)

                # min_df['opponent name'] = [game_opponent_team] * df_len




                
            else:
                print("Play by play does not exist for that game, but a header does")
                
            game= game +1
        except urllib.error.HTTPError:
            continue
 
 
  
 
def main():
   
    # makeHeaderPBP('mens-basketball', '2012')

    sports = ['mens-basketball', 'womens-basketball']


    multi_year_sports = ['mens-basketball', 'womens-basketball']

    fall_sports = ['mens-basketball', 'mens-soccer', 'womens-basketball', 'field-hockey', 'womens-soccer', 'womens-volleyball']

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
            # getHTML(sport, years, year1)
            makeHeaderPBP(sport, year1)
            year1 += 1
   
   
 

main()