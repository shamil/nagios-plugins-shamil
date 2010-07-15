#!/bin/sh
#
# Tiny plugin to check Winbind
# by Alex Simenduev
##

OUTPUT=`wbinfo -t 2>&1 /dev/null`

if [ $? != 0 ]; then
    echo "[wbinfo -t] CRITICAL: $OUTPUT"
    exit 2
else 
    echo "[wbinfo -t] OK: $OUTPUT"
    exit 0
fi
