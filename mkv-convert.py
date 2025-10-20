#!/usr/bin/env python3

import os

tmp_files = "/tmp/mkv-convert-files"

os.system('find ./ -name "*.avi" -o -name "*.mp4" -o -name "*.mov" -o -name "*.mpg" -o -name "*.mpeg" -o -name "*.divx" -o -name "*.m4v" > ' + tmp_files)

for file in open(tmp_files, "r"):
	file = file[:-1]
	filename = os.path.splitext(file)
	os.system('mkvmerge -o "' + filename[0] + '.mkv" "' + file + '"')
	os.system('rm "' + file + '"')

os.system("rm " + tmp_files)
