#!/bin/sh

STATUS=
if [[ $( synclient -l | grep -F "TouchpadOff" | cut -d "=" -f 2 | bc ) == "0" ]]; then
    STATUS=1
else
    STATUS=0
fi

echo "status will be $STATUS"

synclient "TouchpadOff=$STATUS"
