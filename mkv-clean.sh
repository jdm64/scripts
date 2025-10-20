#!/usr/bin/env bash

find "$1" -name "*.mkv" | while read file; do
	if [ -s "$file" ]; then
		echo -n "$file  "
		mkvalidator --quiet "$file" &> /dev/null
		case $? in
		0)
			echo "ok"
			;;
		190|191)
			echo "zeroing"
			true > "$file"
			;;
		253)
			echo "empty"
			;;
		*)
			echo "remuxing"
			filename=$(basename "$file")
			mkclean --remux --optimize "$file" "/tmp/$filename"
			mv "/tmp/$filename" "$file"
			;;
		esac
	fi
done
