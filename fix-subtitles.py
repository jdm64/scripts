#!/usr/bin/env python3

import re
import subprocess
import sys
import os

NUM_KEY = 'Track number'
DEF_KEY = '"Default track" flag'
NAM_KEY = 'Name'
TYP_KEY = 'Track type'
LAN_KEY = 'Language'
FORCE_KEY = '"Forced display" flag'

def runCmd(args):
	return subprocess.run(args, capture_output=True, text=True)

def checkHasCmds():
	r = runCmd(['mkvinfo', '-V'])
	if r.returncode != 0:
		return 1
	r = runCmd(['mkvpropedit', '-V'])
	if r.returncode != 0:
		return 1
	r = runCmd(['mkvmerge', '-V'])
	if r.returncode != 0:
		return 1
	return 0

def parseTracks(text):
	tracks = []
	current_track = {}
	in_track = False

	for line in text.split('\n'):
		if line.startswith('| + Track'):
			if current_track:
				tracks.append(current_track)
			current_track = {}
			in_track = True
			continue
		elif line.startswith('|+ ') and in_track:
			in_track = False
			continue
		elif not line.startswith('|  + '):
			continue
		elif line.find(':') == -1:
			continue

		if not in_track:
			continue

		line = line[5:]
		name = line[ : line.find(':')].strip()
		value = line[line.find(':') + 1 : ].strip()

		if name == NUM_KEY:
			value = value.split(' ')[0]
		current_track[name] = value

	if current_track:
		tracks.append(current_track)

	return tracks

def printFileInfo(fileName):
	r = runCmd(['mkvinfo', fileName])
	if r.returncode != 0:
		return 0

	print()
	print('File:', fileName)
	print('Tracks:')

	data = parseTracks(r.stdout)
	if not data:
		return 0

	count = 0
	for track in data:
		langKeys = [key for key in track.keys() if key.startswith(LAN_KEY)]
		if not langKeys:
			lang = '-'
		else:
			lang = track[langKeys[0]]
		lang = lang.ljust(3)

		isDef = '*' if DEF_KEY in track and track[DEF_KEY] == '1' else ' '
		typ = track[TYP_KEY].ljust(9) if TYP_KEY in track else ''.ljust(9)
		name = track[NAM_KEY] if NAM_KEY in track else ''
		print("", track['Track number'], '|', isDef, '|', lang, '|', typ, '|', name)
		count += 1
	return count

def remuxFile(fileName, data):
	if not data:
		return

	cmd = ['mkvmerge', '-o', 'tmp.mkv', fileName]
	print("Remux:", ' '.join(cmd))
	runCmd(cmd)
	runCmd(['mv', 'tmp.mkv', fileName])

	r = runCmd(['mkvinfo', fileName])
	t = parseTracks(r.stdout)
	edits = []
	for i in t:
		n = i[NUM_KEY]
		if FORCE_KEY in i:
			edits.extend(['-e', 'track:' + n, '-d', 'flag-forced'])

		if n in data:
			edits.extend(['-e', 'track:' + n, '-s', 'flag-default=1'])
		elif ('!' + n) in data:
			edits.extend(['-e', 'track:' + n, '-s', 'flag-default=0'])
		elif DEF_KEY in i:
			edits.extend(['-e', 'track:' + n, '-d', 'flag-default'])

	cmd = ['mkvpropedit', fileName]
	cmd.extend(edits)
	print("Set Flags:", ' '.join(cmd))
	runCmd(cmd)

def parseDefaults(line, count):
	marks = []
	for v in line.split(' '):
		if not v:
			continue
		try:
			x = int(v if v[0] != '!' else v[1:])
			if x < 1 or x > count:
				print('Track number out of range:', v)
				marks = []
				break
			else:
				marks.append(v)
		except ValueError:
			print('Invalid number:', v)
			marks = []
			break
	return marks

def findFiles(paths):
	fileNames = []
	toSearch = []
	for f in paths:
		if os.path.isfile(f):
			fileNames.append(f)
		elif os.path.isdir(f):
			toSearch.append(f)

	for d in toSearch:
		for root, dirs, files in os.walk(d):
			for f in files:
				if f.endswith('.mkv'):
					fileNames.append(os.path.join(root, f))

	return fileNames

def printHelp():
	print()
	print('# - List of track numbers to mark default. Use !# to unmark')
	print('a - Mark all remaining files using last options')
	print('l - mark this file using last options')
	print("n - skip to next file")
	print("p - Print current file and track data again")
	print("? - help")
	print('q - quit')

def getCommand(filename, lastMark):
	maxNum = printFileInfo(filename)

	while True:
		i = input('Mark default tracks (last = ' + str(lastMark) + ' ) {? = help}: ')

		if i == 'n' or i == 'q':
			return i, None
		elif i == 'p':
			printFileInfo(filename)
			continue
		elif i == 'h' or i == '?':
			printHelp()
			continue
		elif i == 'a' or i == 'l':
			if not lastMark:
				m = parseDefaults(input('Set last mark options: '), maxNum)
				if not m:
					continue
				lastMark = m
			return i, lastMark

		m = parseDefaults(i, maxNum)
		if m:
			return 'm', m

def main(paths):
	files = findFiles(paths)
	lastMark = []
	isBatch = False
	batch = []

	print()
	print("Processing", str(len(files)), 'file(s)...')

	for f in files:
		if isBatch:
			batch.append(f)
			continue

		c, d = getCommand(f, lastMark)
		if c == 'n':
			continue
		elif c == 'q':
			return
		elif c == 'a':
			lastMark = d
			batch.append(f)
			isBatch = True
		elif c == 'm' or c == 'l':
			lastMark = d
			remuxFile(f, d)

	if batch:
		print()
		print('Running batch mode:', lastMark)
		for f in batch:
			print()
			remuxFile(f, lastMark)


if __name__ == "__main__":
	if checkHasCmds():
		print("Error: install mkvtoolnix to get mkvinfo/mkvpropedit/mkvmerge programs")
		exit(1)

	if len(sys.argv) == 1:
		paths = '.'
	else:
		paths = sys.argv[1:]

	main(paths)
