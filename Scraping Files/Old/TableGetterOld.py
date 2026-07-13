import requests
from bs4 import BeautifulSoup as bs
import re
import pandas as pd
from csv import reader
import os
# This base directory just uses field-hockey, but it would eventually be able to look through the
# folders for each sport we're scraping
base_directory = '/Users/ericmerdian/Desktop/Desktop/A_Summer_Research/field-hockey/'

os.chdir(base_directory)

# Instead of links, we can now use the downloaded html files that we got from the get_centre_html script
with open('mergedfield-hockey.csv', 'r') as links:
    csv_reader = reader(links)
    i = 0
    for link in links:
        print(link)
        r = requests.get(link)

        # Convert to a BS object
        soup = bs(r.content, features='lxml')

        # Print out html
        print(soup.prettify())

        # This currently only gets the first table from each webpage, so it needs some adjusting to take the
        # header from the first table, but not from the tables that follow
        table = soup.find('table', {'class':'sidearm-table play-by-play'})
        #print(table)

        headers = []

        for i in table.find_all('thead'):
            for i in table.find_all('th'):
                title = i.text.strip()
                headers.append(title)

        #print(headers)

        df = pd.DataFrame(columns = headers)

        #print(df)

        for row in table.find_all('tr')[1:]:
            data = row.find_all('td')
            row_data = [td.text.strip() for td in data]
            length = len(df)
            df.loc[length] = row_data

        #print(df)

        df.to_csv(r'/Users/ericmerdian/Desktop/Desktop/A_Summer_Research/field-hockey/' + str(i) + '.csv', index = False, header=False)
        i = i + 1

