from bs4 import BeautifulSoup as bs
import pandas as pd
from pandas import DataFrame
import os
import shutil
import glob
import urllib
import urllib.request
from pathlib import Path
import csv
import re

schools = ['berryvikings', 'bscsports', 'centrecolonels', 'hendrixwarriors', 'gomajors', 'rhodeslynx', 'sewaneetigers']

for school in schools:
	A = sorted(os.listdir('/Users/ericmerdian/Desktop/Desktop/A_Summer_Research/AllTeams/'+ school +'/mens-basketball/ModelDF/2018/'), key=lambda x:float(re.findall("(\d+)",x)[0]))
	B = A[:len(A)//2]
	C = A[len(A)//2:]
	print(A)
	print(B)
	print(C)
	os.chdir('/Users/ericmerdian/Desktop/Desktop/A_Summer_Research/AllTeams/'+ school +'/mens-basketball/ModelDF/2018/')
	df_Train = pd.concat((pd.read_csv(f, header = 0, float_precision='round_trip') for f in B))
	print(df_Train)
	df_Test= pd.concat((pd.read_csv(f, header = 0, float_precision='round_trip') for f in C))
	print(df_Test)
	os.chdir('/Users/ericmerdian/Desktop/Desktop/A_Summer_Research/AllTeams/Training/')
	df_Train.to_csv(school + "Training.csv", index=False)
	os.chdir('/Users/ericmerdian/Desktop/Desktop/A_Summer_Research/AllTeams/Testing/')
	df_Test.to_csv(school + "Testing.csv", index=False)


train_test = ['Training', 'Testing']
for element in train_test:
	os.chdir('/Users/ericmerdian/Desktop/Desktop/A_Summer_Research/AllTeams/'+ element +'/')
	extension = 'csv'
	all_filenames = [i for i in glob.glob('*.{}'.format(extension))]
	#combine all files in the list
	combined_csv = pd.concat([pd.read_csv(f, float_precision='round_trip') for f in all_filenames])
	print(combined_csv)
	#export to csv
	os.chdir('/Users/ericmerdian/Desktop/Desktop/A_Summer_Research/AllTeams/')
	combined_csv.to_csv(element + ".csv", index=False, encoding='utf-8-sig')