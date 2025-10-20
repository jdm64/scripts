#!/usr/bin/env bash

BITRATE=$1
OUTPUT=$2

#ffmpeg -f image2 -i %04d.png -c:v libx264 -preset placebo -qp 0 video.mkv
ffmpeg -f image2 -r 24 -i %04d.png -c:v libx264 -preset placebo -b:v $BITRATE -pass 1 -pix_fmt yuv420p -f mp4 -y /dev/null
ffmpeg -f image2 -r 24 -i %04d.png -c:v libx264 -preset placebo -b:v $BITRATE -pass 3 -pix_fmt yuv420p -y $OUTPUT
ffmpeg -f image2 -r 24 -i %04d.png -c:v libx264 -preset placebo -b:v $BITRATE -pass 3 -pix_fmt yuv420p -y $OUTPUT
ffmpeg -f image2 -r 24 -i %04d.png -c:v libx264 -preset placebo -b:v $BITRATE -pass 2 -pix_fmt yuv420p -y $OUTPUT
