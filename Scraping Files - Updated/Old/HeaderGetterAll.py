#GetHeader
#info needed:
#season, date, opponent, scores, win/lose,overtimee?,
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
import urllib.request
from pathlib import Path


def getBoxScore(game_url,sport):
    r = urllib.request.urlopen(game_url)
            # Convert to a BS object
    soup = bs(r, 'html.parser')
    if sport =='softball':
        boxscore = soup.find('article', {'class':'box-score softball sidearm-responsive'})
        #print (boxscore)
    elif sport == 'baseball':
        boxscore = soup.find('article', {'class':'box-score baseball sidearm-responsive'})
    else:
        boxscore = soup.find('section', {'id':'box-score'})
    return boxscore

def getCentreIndex(boxscore, sport):
    if sport == 'baseball' or sport == 'softball':
        headline = boxscore.find('h1', {'class':'text-center text-uppercase hide-on-medium-down'})
        headline = headline.text.strip()
        headline = headline.lower()
        headline = headline.split(" ")
    elif 'tennis' in sport:
        headline = boxscore.find('div', {'class':'team-names'})
        headline = headline.text.strip()
        headline = headline.lower()
        headline = headline.split(" ")
    elif 'basketball' in sport:
        headline=[]
        away_team = boxscore.find('div', {'class':'team away'})
        away_logo = away_team.find('img')
        home_team = boxscore.find('div',{'class':'team home'})
        home_logo= home_team.find('img')
    
        headline.append(away_logo.attrs['alt'].lower())
        headline.append(home_logo.attrs['alt'].lower())
        
    else:
        headline = boxscore.find('h2', {'class':'main-heading text-center text-uppercase'})
    #print(headline.text)
        headline = headline.text.strip()
        headline = headline.lower()
        headline = headline.split(" ")
    if "centre" in headline[0]:
        index = 0
    else:
        index = 1
    return index

def getFinalScore(boxscore, sport):
    '''Returns final score of game with Cenre score
listed first and then opponent
'''
    if getCentreIndex(boxscore,sport) == 0:
        opponent_index = 1
    else:
        opponent_index = 0

    centre_index= getCentreIndex(boxscore,sport)
    
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
        
    opponent_finalScore = scores[opponent_index].text.strip()
    centre_finalScore = scores[centre_index].text.strip()

    final_score = str(centre_finalScore)+'-'+ str(opponent_finalScore)
    #print(final_score)
    return final_score
    
def getGameScoreByPeriod(boxscore,sport):
    '''Returns a list of scores by period for both Centre and opponent
'''
    if sport == 'baseball' or sport == 'softball':
        score_body = boxscore.find('tbody')
    
    else:
        header = boxscore.find('figure', {'class':'box-score-header'})
        score_body = header.find('tbody')
        
    scores = score_body.find_all('tr')
    return scores
def getCentreScoreByPeriod(boxscore,sport):
    '''Returns list of score by period.
For example if [0,4,1,0] is returned this means
Centre didn't score in the first period
Centre scored 4 in the second
Centre scored 1 in the third
and Centred scored 0 in the fourth
for however many periods there are depending on the sport
THis also includes the final score at the end
'''
    if 'tennis' in sport:
        return "N/A"
    else:
        centre_scores = getGameScoreByPeriod(boxscore,sport)[getCentreIndex(boxscore,sport)]
        score_by_period = []
        periods = centre_scores.find_all('td')
        for score in periods:
            score_by_period.append(score.text)
        if sport == "baseball" or sport =="softball":
            for i in range(3):
                del score_by_period[len(score_by_period)-1]
        elif sport == 'mens-basketball':
            for i in range(2):
                del score_by_period[len(score_by_period)-1]
        elif sport != 'womens-volleyball':
            del score_by_period[len(score_by_period)-1]
        return score_by_period
        
def getOpponentScoreByPeriod(boxscore,sport):
    '''Returns list of score by period.
For example if [0,4,1,0] is returned this means
Centre didn't score in the first period
Centre scored 4 in the second
Centre scored 1 in the third
and Centred scored 0 in the fourth
for however many periods there are depending on the sport
THis also includes the final score at the end
'''
    if 'tennis' in sport:
        return "N/A"
    else:
        if getCentreIndex(boxscore,sport) == 0:
            index = 1
        else:
            index = 0
        opponent_scores = getGameScoreByPeriod(boxscore,sport)[index]
        score_by_period = []
        periods = opponent_scores.find_all('td')
        for score in periods:
            score_by_period.append(score.text)
        if sport == "baseball" or sport =="softball":
            for i in range(3):
                del score_by_period[len(score_by_period)-1]
        elif sport == 'mens-basketball':
            for i in range(2):
                del score_by_period[len(score_by_period)-1]
        elif sport != 'womens-volleyball':
            del score_by_period[len(score_by_period)-1]
        return score_by_period

def getRecord(boxscore,sport):
    '''Returns both team records in a list
'''
    if sport == 'baseball' or sport == 'softball':
        records = []

        headline = boxscore.find('h1', {'class':'text-center text-uppercase hide-on-medium-down'})
        headline = headline.text.replace('.',' ')
        new_headline= headline.split('(')
        
        new_headline='.'.join(new_headline)
    
        new_headline = new_headline.split(')')
        new_headline='.'.join(new_headline)
        new_headline= new_headline.split('.')
        #print(new_headline)
        records.append(new_headline[1])
        records.append(new_headline[len(new_headline)-2])
    elif 'tennis' in sport:
        #different variationss
        #(1-0)
        #(1-0, 0-2 SAA)
        #(1-0(0-2 SAA))
        records = []
        headline = boxscore.find('div',{'class':'team-names'}).text
        headline = headline.replace('.',' ')
        new_headline= headline.split('(')
        if len(new_headline) == 5:
            records.append(new_headline[1])
            records.append(new_headline[3])
        else:
            new_headline='.'.join(new_headline)
            new_headline = new_headline.split(')')
            new_headline='.'.join(new_headline)
            new_headline= new_headline.split('.')
        #print(new_headline)
            records.append(new_headline[1])
            records.append(new_headline[len(new_headline)-2])
    elif 'basketball' in sport:
        records = []
        header = boxscore.find('figure', {'class':'box-score-header'})
        score_body = header.find('tbody')
        records = score_body.find_all('td', {'class':'hide-on-small-down'})
    else:
        headline = boxscore.find('h2', {'class':'main-heading text-center text-uppercase'})
        records = headline.find_all('span')
    return records
def getCentreRecord(boxscore,sport):
    '''returns Centre's record in a list
'''
    try:
        records = getRecord(boxscore,sport)
        #print(records)
        if sport == 'baseball' or sport == 'softball' or 'tennis' in sport:
            centre_record = records[getCentreIndex(boxscore,sport)]
      #  elif 'tennis' in sport:
            
        else:
            centre_record = records[getCentreIndex(boxscore,sport)].text
        return centre_record
    except IndexError:
        return "No record reported"
    
def getOpponentRecord(boxscore,sport):
    '''Returns Opponent's record
'''
    try:
        records = getRecord(boxscore,sport)
        #print(records)
        if getCentreIndex(boxscore,sport) == 1:
            index = 0
        else:
            index = 1

        if sport == 'baseball' or sport == 'softball' or 'tennis' in sport:
            opponent_record = records[index]
        else:
            opponent_record = records[index].text
        return opponent_record

    except IndexError:
        return "No record reported"
        

def getGameDate(boxscore,sport):
    '''Returns the games date
'''
    if sport == 'baseball' or sport == 'softball' or 'basketball' in sport:
        information = boxscore.find('aside', {'class':'game-details'})
    else:
        information = boxscore.find('dl', {'class':'text-center inline'})
   
    game_date = information.find('dd').text
    #game_date = game_date.split('/')
   
    return game_date



def getWin(boxscore,sport):
    '''Returns 1 if Centre won, returns 0 if Centre lost,
or 2 if game was a tie
'''
    final_score = getFinalScore(boxscore,sport)
    final_score = final_score.split('-')
    centre_finalScore =int(final_score[0])
    opponent_finalScore= int(final_score[1])
    if centre_finalScore == opponent_finalScore:
        return "Tie"
    elif centre_finalScore > opponent_finalScore:
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
        if title.text == "Time:" or title.text == "Time":
            game_time = information.find_all('dd')[i].text
            return game_time
        i= i+1
  
    return('No Time Recorded')


    
def isHomeGame(boxscore,sport):
    '''Returns true if home game(for centre) and false if away game
'''
    if sport == 'baseball' or sport == 'softball' or 'basketball' in sport:
        information = boxscore.find('aside', {'class':'game-details'})
    else:
        information = boxscore.find('dl', {'class':'text-center inline'})

    titles = information.find_all('dt')
    i=0
    
    for title in titles:
        if title.text == "Site:" or title.text=="Site":
            game_site= information.find_all('dd')[i].text
            if "Danville, KY" in game_site or "Danville, Ky" in game_site:
                return True
            else:
                return False
        i= i+1
    return "No Site Listed"


    
def makeHeaders(sport, year1):
    sport_schedule = open(r'/Users/ericmerdian/Desktop/Desktop/A_Summer_Research/' + sport + '/' + str(year1) + '_links.csv', 'r')
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
            
            opponentName = game_opponent
            finalScore = getFinalScore(boxscore_tab, sport)
            centreScoreByPeriod = getCentreScoreByPeriod(boxscore_tab,sport)
            csbp_together = ', '.join([str(item) for item in centreScoreByPeriod]) #puts the list of score by period into a string
        
            opponentScoreByPeriod = getOpponentScoreByPeriod(boxscore_tab,sport)
            osbp_together = ', '.join([str(item) for item in opponentScoreByPeriod])
        
            centreRecord = getCentreRecord(boxscore_tab,sport)
            opponentRecord = getOpponentRecord(boxscore_tab,sport)
            gameDate = getGameDate(boxscore_tab,sport)
            outcome = getWin(boxscore_tab,sport)
            overtime = isOvertime(boxscore_tab,sport)
            attendance = getAttendance(boxscore_tab,sport)
            gameLocation = getLocation(boxscore_tab, sport)
            gameTime = getGameTime(boxscore_tab, sport)
            homeGame = isHomeGame(boxscore_tab, sport)

           
            
            header = pd.DataFrame({'opponent name': [opponentName], 'final score': [finalScore], 'centreScoreByPeriod': [csbp_together],
                              'opponentScoreByPeriod': [osbp_together], 'centreRecord': [centreRecord], 'opponentRecord': [opponentRecord],
                              'gameDate': [gameDate], 'gameTime': [gameTime], 'gameLocation': [gameLocation], 'outcome': [outcome], 'attendance': [attendance], 'homeGame': [homeGame]})
            
            i=1
            for score in centreScoreByPeriod:
                header['centreScorePeriod'+ str(i)] = centreScoreByPeriod[i-1]
                i+=1
            i=1
            for score in opponentScoreByPeriod:
                header['opponentScorePeriod'+ str(i)] = opponentScoreByPeriod[i-1]
                i+=1

            print(header)


            output_file = 'game'+str(game)+'_'+opponentName+'_'+game_id+'.csv'
            output_dir = Path('/Users/ericmerdian/Desktop/Desktop/A_Summer_Research/' + sport + '/headers/' + str(year1) + '/')
            output_dir.mkdir(parents=True, exist_ok=True)
            header.to_csv(output_dir / output_file, index = False)

            game = game +1
           
        except urllib.error.HTTPError:
            print('hi')
            continue


        
def main():
    
    #use this to test each sport
    # makeHeaders('mens-basketball', 2010)
    
    
    #game_url='https://centrecolonels.com/sports/softball/stats/2016/adrian/boxscore/1846'
    #boxscore_tab= getBoxScore(game_url,'softball')
    #print(getFinalScore(boxscore_tab,'softball'))

    #game_url='https://centrecolonels.com/sports/football/stats/2013/rose-hulman/boxscore/437'
    #boxscore_tab= getBoxScore(game_url,'football')
    #print(getFinalScore(boxscore_tab, 'football'))
    #print(isHomeGame(boxscore_tab,'football'))
    

    # sports = ['baseball', 'mens-basketball', 'football', 'mens-lacrosse', 'mens-soccer', 'mens-tennis', 'womens-basketball', 
    #       'field-hockey', 'womens-lacrosse', 'womens-soccer', 'softball', 'womens-tennis', 'womens-volleyball']
    sports = ['womens-lacrosse']   
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

main()
          
