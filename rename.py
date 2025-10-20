#!/usr/bin/env python3

import os, fnmatch

def getFiles():
	files = []
	for root, dirnames, filenames in os.walk('.'):
		for filename in fnmatch.filter(filenames, '*.mkv'):
			files.append(filename)
	files.sort()
	return files

def getNames():
	names = []
	with open('list') as fileNames:
		for line in fileNames.readlines():
			names.append(line.strip())
	return names

def rename(files, names):
	if len(files) != len(names):
		print("size miss match")
		return
	for i in range(len(files)):
		end = files[i].rfind('.')
		newname = names[i] + '.mkv'
#		newname = files[i][0:end] + ' ' + names[i] + '.mkv'
#		print newname
		os.rename(files[i], newname)

rename(getFiles(), getNames())
