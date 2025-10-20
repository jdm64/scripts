#!/usr/bin/env bash

case $1 in
"start")
	./blender/blender -b master.blend -a &> /dev/null &
	sleep 5
	./blender/blender -b slave.blend -a &> /dev/null &
	;;
"stop")
	killall -9 blender
	;;
*)
	echo "must provide either start or stop"
esac