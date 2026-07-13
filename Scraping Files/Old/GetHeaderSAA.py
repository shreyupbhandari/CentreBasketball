#GetHeader
#info needed:
#season, date, opponent, scores, win/lose,overtimee?,
#scores through each period, attendence
'''this creates csv files for each game with the header info
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
import urllib.request
from pathlib import Path


def getBoxScore(game_url,sport):
    r = urllib.request.urlopen(game_url)
            # Convert to a BS object
    soup = bs(r, 'html.parser')

    boxscore = soup.find('section', {'id':'box-score'})
    
    return boxscore

def standardize_names(name):
    
    original_name = name
    name = name.lower()
    
    if "berry" in name:
        name = "Berry"
    elif "birmingham" in name:
        name = "Birmingham-Southern"
    elif "centre" in name:
        name = "Centre"
    elif "hendrix" in name:
        name = "Hendrix"
    elif "rhodes" in name:
        name = "Rhodes"
    elif "sewanee" in name:
        name = "Sewanee"
    else:
        name = original_name
    
    return name
    
    
def get_boxscore_names(boxscore,sport):
    
    
    if sport == 'field-hockey':
        headline = boxscore.find('h2', {'class':'main-heading text-center text-uppercase'})
        
        i = 0
        for thing in headline:
            if i == 0:
                num_spaces = thing.count(' ')
                for space in range(0,num_spaces-1):
                    thing = thing[1:]
                boxscore_visitor_name = thing
                if boxscore_visitor_name[0]==' ':
                    boxscore_visitor_name = boxscore_visitor_name[1:]
                if boxscore_visitor_name[0]==' ':
                    boxscore_visitor_name = boxscore_visitor_name[1:]
                if boxscore_visitor_name[-1]==' ':
                    boxscore_visitor_name = boxscore_visitor_name[:-1]
            if i == 5:
                boxscore_home_name = thing
                if boxscore_home_name[0]==' ':
                    boxscore_home_name = boxscore_home_name[1:]
                if boxscore_home_name[-1]==' ':
                    boxscore_home_name = boxscore_home_name[:-1]
            i = i+1
            
    elif (sport == 'womens-lacrosse') or (sport=='mens-lacrosse'):
        headline = boxscore.find('h4', {'class':'main-heading text-center text-uppercase'})
        
        i = 0
        for thing in headline:
            if i == 0:
                boxscore_visitor_name = thing
                if boxscore_visitor_name[0]==' ':
                    boxscore_visitor_name = boxscore_visitor_name[1:]
                if boxscore_visitor_name[0]==' ':
                    boxscore_visitor_name = boxscore_visitor_name[1:]
                if boxscore_visitor_name[-1]==' ':
                    boxscore_visitor_name = boxscore_visitor_name[:-1]
            if i == 5:
                boxscore_home_name = thing
                if boxscore_home_name[0]==' ':
                    boxscore_home_name = boxscore_home_name[1:]
                if boxscore_home_name[-1]==' ':
                    boxscore_home_name = boxscore_home_name[:-1]
            i = i+1
    elif ('basketball' in sport):
        headline=[]
        away_team = boxscore.find('div', {'class':'team away'})
        away_logo = away_team.find('img')
        home_team = boxscore.find('div',{'class':'team home'})
        home_logo= home_team.find('img')
        
        headline.append(away_logo.attrs['alt'])
        headline.append(home_logo.attrs['alt'])
       
        
        boxscore_visitor_name = away_logo.attrs['alt']
        boxscore_visitor_name = boxscore_visitor_name.replace('logo', '')
        boxscore_visitor_name = boxscore_visitor_name.strip()

        boxscore_home_name = home_logo.attrs['alt']
        boxscore_home_name = boxscore_home_name.replace('logo', '')
        boxscore_home_name = boxscore_home_name.strip()
        
        
    #print('home:', boxscore_home_name)
    #print('away:', boxscore_visitor_name)
    visitor_name = standardize_names(boxscore_visitor_name)
    home_name = standardize_names(boxscore_home_name)
    
 
    return visitor_name , home_name


def getFinalScore(boxscore, sport):
    '''Returns final score of game with visitor score
listed first and then home
'''


    information = boxscore.find('div',{'class':'box-score-graphic'})
    if 'basketball' in sport:
        scores = information.find_all('span')
        del scores[1]
    else:            
        scores= information.find_all('span',{'class':'score'})
        
    visitor_finalScore = scores[0].text.strip()
    home_finalScore = scores[1].text.strip()

    final_score = str(visitor_finalScore)+'-'+ str(home_finalScore)
    #print(final_score)
    return final_score, visitor_finalScore, home_finalScore
    
def getGameScoreByPeriod(boxscore,sport):
    '''Returns a list of scores by period for both Centre and opponent
'''
    header = boxscore.find('figure', {'class':'box-score-header'})
    score_body = header.find('tbody')
        
    scores = score_body.find_all('tr')
    
    return scores

def getVisitorScoreByPeriod(boxscore,sport):
    '''Returns list of score by period.
For example if [0,4,1,0] is returned this means
Centre didn't score in the first period
Centre scored 4 in the second
Centre scored 1 in the third
and Centred scored 0 in the fourth
for however many periods there are depending on the sport
THis also includes the final score at the end
'''

    visitor_scores = getGameScoreByPeriod(boxscore,sport)[0]
    score_by_period = []
    periods = visitor_scores.find_all('td')
    for score in periods:
        score_by_period.append(score.text)

    if sport == 'mens-basketball':
        for i in range(2):
            del score_by_period[len(score_by_period)-1]
    else:
        del score_by_period[len(score_by_period)-1]
    return score_by_period
        
def getHomeScoreByPeriod(boxscore,sport):
    '''Returns list of score by period.
For example if [0,4,1,0] is returned this means
Centre didn't score in the first period
Centre scored 4 in the second
Centre scored 1 in the third
and Centred scored 0 in the fourth
for however many periods there are depending on the sport
THis also includes the final score at the end
'''

    home_scores = getGameScoreByPeriod(boxscore,sport)[1]
    score_by_period = []
    periods = home_scores.find_all('td')
    for score in periods:
        score_by_period.append(score.text)
    
    if sport == 'mens-basketball':
        for i in range(2):
            del score_by_period[len(score_by_period)-1]
    else:
        del score_by_period[len(score_by_period)-1]
    return score_by_period

def getRecord(boxscore,sport):
    '''Returns both team records in a list
'''
  
    if 'basketball' in sport:
        records = []
        header = boxscore.find('figure', {'class':'box-score-header'})
        score_body = header.find('tbody')
        records = score_body.find_all('td', {'class':'hide-on-small-down'})
    elif 'lacrosse' in sport:
        headline = boxscore.find('h4', {'class':'main-heading text-center text-uppercase'})
        records = headline.find_all('span')
    else:
        headline = boxscore.find('h2', {'class':'main-heading text-center text-uppercase'})
        records = headline.find_all('span')
    return records 

def getVisitorRecord(boxscore,sport):
    '''returns Centre's record in a list
'''
    try:
        records = getRecord(boxscore,sport)
        #print(records)
    
        visitor_record = records[0].text
        
        return visitor_record
    except IndexError:
        return "No record reported"
    
def getHomeRecord(boxscore,sport):
    '''Returns Opponent's record
'''
    try:
        records = getRecord(boxscore,sport)
        #print(records)

        home_record = records[1].text
        
        return home_record

    except IndexError:
        return "No record reported"
    
def cleanRecord(boxscore, record):
    print(record)
    if record[0]=='(':
        if record[1]==')' or record[1]==',':
            num_wins = ''
            num_losses = ''
            num_ties = ''
            percent_win = ''
        else:
            first_dash_index = record.find('-')
            
            second_dash_index = record.find('-', first_dash_index+1)
            
            end_parenth_index = record.find(')')
            
            #if there's a comma first, that is end of record
            if ',' in record:
                comma_index = record.find(',')
                if comma_index < end_parenth_index:
                    end_index = comma_index
            elif ';' in record:
                semicolon_index = record.find(';')
                if semicolon_index < end_parenth_index:
                    end_index = semicolon_index
            else:
                end_index = end_parenth_index
                            
            
            if first_dash_index != 2:
                num_wins = int(record[1:(first_dash_index-1)])
            else:
                num_wins = int(record[1])
                
            #if there are no ties        
            if second_dash_index == -1 or second_dash_index > end_index:  
                
                if end_index - first_dash_index != 2:
                    num_losses = int(record[(first_dash_index+1):(end_index-1)])
                else:
                    num_losses = int(record[first_dash_index+1])
                    
                num_ties = 0
                
            else:
                if(first_dash_index+1==second_dash_index -1):
                     num_losses = int(record[first_dash_index+1])
                        
                else:
                    num_losses = int(record[(first_dash_index+1):(second_dash_index -1)])
                
                num_ties = int(record[second_dash_index+1])
    else:
        if record == 'No record reported' or record == 'NA' or record == '0':
            num_wins = ''
            num_losses = ''
            num_ties = ''
            percent_win = ''
        else:
            if ',' in record:
                record = record.split(',')[0]
            if ' ' in record:
                record = record.split(' ')[0]
            if ';' in record:
                record = record.split(';')[0]
            record = record.split('-')
            num_wins = int(record[0])
            # print("Num wins:" , num_wins)
            num_losses = int(record[1])
            # print("Num losses:" ,num_losses)
            num_ties = 0
            
    
    
            #percent_win = num_wins/(num_wins+num_losses)
    if num_ties != '' and num_ties > 0:
        print('ties')
        
    return num_wins, num_losses, num_ties

def recordBeforeGame(num_wins, num_losses, num_ties, home_or_away, win_or_lose):
    # print("Num wins:" , num_wins)
    # print("Num losses:" ,num_losses)
    
    if num_wins != '' and num_losses != '':
        if home_or_away == "Home":
            
            if win_or_lose == "Win":
                num_wins = num_wins - 1
            elif win_or_lose == "Lose":
                num_losses = num_losses - 1
            else:
                num_ties = num_ties - 1
        else:
            if win_or_lose == "Win":
                num_losses = num_losses - 1
            elif win_or_lose == "Lose":
                num_wins = num_wins -1
            else:
                num_ties = num_ties - 1
            
        if num_wins + num_losses+num_ties != 0:
            percent_win = round(num_wins/(num_wins+num_losses+num_ties), 3)
        else:
            percent_win = 0
    else:
        print('look')
        num_wins = 0
        num_losses =0
        percent_win = 0
    
    
    #if the team has only played 4 games, make the win percentage 50%.
    #CHANGE THIS LATER
    if int(num_wins) + int(num_losses) < 5:
        percent_win = .5
        
    return num_wins, num_losses, percent_win

def getGameDate(boxscore,sport):
    '''Returns the games date
'''
    if sport == 'baseball' or sport == 'softball' or 'basketball' in sport:
        information = boxscore.find('aside', {'class':'game-details'})
    else:
        information = boxscore.find('dl', {'class':'text-center inline'})
   
    game_date = information.find('dd').text
    #game_date = game_date.split('/')
    game_date_split = game_date.split('/')
    
    game_month = game_date_split[0]
    game_day = game_date_split[1]
    game_year = game_date_split[2][-2:]
    
    #make sure there are two digits for month and day
    if len(game_month)==1:
        game_month = '0' + game_month
    
    if len(game_day)==1:
        game_day = '0' + game_day
    
   
    return game_date, game_month, game_day, game_year

def getWin(boxscore,sport):
    '''Returns 'win' if home team won, returns 'lose' if home team lost,
or 2 if game was a tie
'''
    final_score, visitor_score, home_score = getFinalScore(boxscore,sport)
    final_score = final_score.split('-')
    visitor_finalScore =int(final_score[0])
    home_finalScore= int(final_score[1])
    if visitor_finalScore == home_finalScore:
        return "Tie"
    elif home_finalScore > visitor_finalScore:
        return "Win"
    else:
        return "Lose"
def isOvertime(boxscore,sport):
    '''Returns True if overtime, false if not
'''
 
    table_head = boxscore.find_all('th', {'scope':'col'})
    for heading in table_head:
        if 'OT' in heading.text:
            return True
        else:
            i =1
    return False
    
def getAttendance(boxscore,sport): 
    '''Returns the games attendance
'''
    if sport == 'baseball' or sport == 'softball' or 'basketball' in sport:
        information = boxscore.find('aside', {'class':'game-details'})
    else:
        information = boxscore.find('dl', {'class':'text-center inline'})

    titles = information.find_all('dt')
    i=0
    
    for title in titles:
        if title.text == "Attendance:" or title.text=="Attendance":
            game_attendance= information.find_all('dd')[i].text
            return game_attendance
        i= i+1
  
    return('No Attendence Recorded')
 
def getLocation(boxscore,sport): 
    '''Returns the games attendance
'''
    if sport == 'baseball' or sport == 'softball' or 'basketball' in sport:
        information = boxscore.find('aside', {'class':'game-details'})
    else:
        information = boxscore.find('dl', {'class':'text-center inline'})

    titles = information.find_all('dt')
    i=0
    
    for title in titles:
        if title.text == "Location:" or title.text=="Location":
            game_location= information.find_all('dd')[i].text
            return game_location
        i= i+1
  
    return('No Location Recorded')

def getGameTime(boxscore,sport): 
    '''Returns the games attendance
'''
    if sport == 'baseball' or sport == 'softball' or 'basketball' in sport:
        information = boxscore.find('aside', {'class':'game-details'})
    else:
        information = boxscore.find('dl', {'class':'text-center inline'})

    titles = information.find_all('dt')
    i=0
    
    for title in titles:
        if 'basketball' in sport:
            if title.text == "Time:" or title.text == "Time":
                game_time = information.find_all('dd')[i].text
                return game_time
        elif 'lacrosse' in sport:
            if title.text == "Start:" or title.text == "Start":
                game_time = information.find_all('dd')[i].text
                return game_time
        i= i+1
  
    return('No Time Recorded')

    
    
def create_game_id(school_list,game_year,game_month,game_day,school,game_number):
    
    #make sure there are two didgits in game number
    game_number = str(game_number)
    if len(game_number) == 1:
        game_number = '0'+game_number
    #the index of the school in the list of schools is the school id
    school_id = str(school_list.index(school) + 1) 
    game_id = game_year +'_'+ game_month+'_' + game_day+'_' + school_id+'_' + game_number
    
    return game_id


    
def makeHeaders(sport,school_list, year1,school):
    sport_schedule = open(r'/Users/ericmerdian/Desktop/Desktop/A_Summer_Research/AllTeams/' + school+'/'+ sport + '/' + str(year1) + '_links.csv', 'r')
    sport_games = [line.rstrip('\n') for line in sport_schedule]
    sport_schedule.close()
    
    game =1
    for game_url in sport_games:
        print(game_url)
        list_game = game_url.split("/")
        try:
            game_opponent = list_game[7]
            game_id= list_game[9]
      
            boxscore_tab = getBoxScore(game_url, sport)
            #print(boxscore_tab)
            boxscore_visitor_name , boxscore_home_name = get_boxscore_names(boxscore_tab,sport)
            #print(boxscore_visitor_name)
            #print(boxscore_home_name)
            
            opponentName = game_opponent
            outcome = getWin(boxscore_tab,sport)
            
            finalScore, visitor_finalScore, home_finalScore = getFinalScore(boxscore_tab, sport)
            
            visitorScoreByPeriod = getVisitorScoreByPeriod(boxscore_tab,sport)
            vsbp_together = ', '.join([str(item) for item in visitorScoreByPeriod]) #puts the list of score by period into a string
        
            homeScoreByPeriod = getHomeScoreByPeriod(boxscore_tab,sport)
            hsbp_together = ', '.join([str(item) for item in homeScoreByPeriod])
        
            visitorRecord = getVisitorRecord(boxscore_tab,sport)
            print(visitorRecord)
            homeRecord = getHomeRecord(boxscore_tab,sport)
            print(homeRecord)
            
            visitor_wins_after, visitor_losses_after, visitor_ties_after = cleanRecord(boxscore_tab,visitorRecord)
            home_wins_after, home_losses_after, home_ties_after = cleanRecord(boxscore_tab, homeRecord)
            
            visitor_wins_before, visitor_losses_before, visitor_percent_win = recordBeforeGame(visitor_wins_after, visitor_losses_after, visitor_ties_after, "Away", outcome)
            home_wins_before, home_losses_before, home_percent_win = recordBeforeGame(home_wins_after, home_losses_after, home_ties_after, "Home", outcome)
            
            game_date, game_month, game_day, game_year = getGameDate(boxscore_tab,sport)
            
            overtime = isOvertime(boxscore_tab,sport)
            attendance = getAttendance(boxscore_tab,sport)
            gameLocation = getLocation(boxscore_tab, sport)
            gameTime = getGameTime(boxscore_tab, sport)
            
            unique_game_id = create_game_id(school_list,game_year,game_month,game_day,school,game)
            
            
            header = pd.DataFrame({'GameID':[unique_game_id],
                                   #'Game': [game],
                                   'VisitorName':[boxscore_visitor_name],
                                   'HomeName':[boxscore_home_name],
                                   # 'FinalScore': [finalScore],
                                   'VisitorFinalScore': [visitor_finalScore], 'HomeFinalScore': [home_finalScore]})
            

            # header['VisitorRecord']= [visitorRecord]
            header['VisitorNumWins'] = [visitor_wins_before]
            header['VisitorNumLosses'] = [visitor_losses_before]
            header['VisitorWinPercent'] = [visitor_percent_win]
        
            # header['HomeRecord']= [homeRecord]
            header['HomeNumWins'] = [home_wins_before]
            header['HomeNumLosses'] = [home_losses_before]
            header['HomeWinPercent'] = [home_percent_win]
            
           # header['Date']= [game_date]
            header['Outcome']= [outcome] 
          #  header['Attendance']= [attendance] 
           # header['Location'] = [gameLocation]
           # header['GameTime'] = [gameTime]
            
            
            output_file = 'game'+str(game)+'_'+opponentName+'_'+game_id+'.csv'
            output_dir = Path('/Users/ericmerdian/Desktop/Desktop/A_Summer_Research/AllTeams/' +school+ '/'+ sport + '/headers/' + str(year1) + '/')
            output_dir.mkdir(parents=True, exist_ok=True)
            header.to_csv(output_dir / output_file, index = False)
            
            game = game +1
           
        except urllib.error.HTTPError:
            print('hi')
            game = game + 1
            continue
            
    return visitor_percent_win, home_percent_win

def main():
    
    
    #use this to test each sport
    lacrosse_schools = ['berryvikings', 'bscsports','centrecolonels', 'hendrixwarriors', 'rhodeslynx', 'sewaneetigers']
    #lacrosse_schools = ['centrecolonels', 'hendrixwarriors', 'rhodeslynx', 'sewaneetigers']
    
    basketball_schools = ['berryvikings', 'bscsports','centrecolonels', 'hendrixwarriors', 'gomajors','rhodeslynx', 'sewaneetigers']
    # basketball_schools = ['sewaneetigers']
    
    initial_win_percent = .5
    

    for school in basketball_schools: #change based on sport
        print('school: ', school)
        
        for year in range(2018,2019):
            makeHeaders('mens-basketball',basketball_schools, year, school)
    
    
    #game_url='https://centrecolonels.com/sports/softball/stats/2016/adrian/boxscore/1846'
    #boxscore_tab= getBoxScore(game_url,'softball')
    #print(getFinalScore(boxscore_tab,'softball'))

    #game_url='https://centrecolonels.com/sports/football/stats/2013/rose-hulman/boxscore/437'
    #boxscore_tab= getBoxScore(game_url,'football')
    #print(getFinalScore(boxscore_tab, 'football'))
    #print(isHomeGame(boxscore_tab,'football'))
    
    '''
    sports = ['baseball', 'mens-basketball', 'football', 'mens-lacrosse', 'mens-soccer', 'mens-tennis', 'womens-basketball', 
          'field-hockey', 'womens-lacrosse', 'womens-soccer', 'softball', 'womens-tennis', 'womens-volleyball']
   
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
            #year2 = year1 + 1
            #if sport in multi_year_sports:
                #years = str(year1) + '-' + str(year2)
            #else:
                #years = year1
            makeHeaders(sport,year1)
            year1 += 1
    '''


main()