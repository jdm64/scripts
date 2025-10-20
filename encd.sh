#!/usr/bin/env bash

ffmpeg -y -i "$1" -threads 2 -vcodec libx264 -vprofile high -b:v 2048k -preset ultrafast -f matroska -pass 1 /dev/null
ffmpeg -y -i "$1" -threads 2 -vcodec libx264 -vprofile high -b:v 2048k -preset ultrafast -acodec copy -f matroska -pass 2 "$2"

# ffmpeg -y -i "$1" -threads 2 -vcodec libx264 -b 1024k -profile baseline -preset ultrafast -vf 'scale=640:-1' -f mp4 -pass 1 /dev/null
# ffmpeg -y -i "$1" -threads 2 -vcodec libx264 -b 1024k -profile baseline -preset ultrafast -vf 'scale=640:-1' -acodec libfaac -ab 128 -f mp4 -pass 2 "$2"
