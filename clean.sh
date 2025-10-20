#!/usr/bin/env bash

chown root:root "$1"
chmod u=rwx,go=rx "$1"
find "$1" -type f -exec chown root:root {} \;
find "$1" -type d -exec chown root:root {} \;
find "$1" -type f -exec chmod u=rw,go=r {} \;
find "$1" -type d -exec chmod u=rwx,go=rx {} \;
