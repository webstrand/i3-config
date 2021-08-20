#!/bin/bash

BRIGHTNESS="$1"
MOD="$2"
MAX_BRIGHTNESS="$(</sys/class/backlight/intel_backlight/max_brightness)"

if [[ $2 == '+' ]]; then
    BRIGHTNESS=$[ $(</sys/class/backlight/intel_backlight/brightness) + BRIGHTNESS ]
elif [[ $2 == '-' ]]; then
    BRIGHTNESS=$[ $(</sys/class/backlight/intel_backlight/brightness) - BRIGHTNESS ]
fi
echo "calc $BRIGHTNESS"

if (( $BRIGHTNESS < 3 )); then BRIGHTNESS=3; fi
if (( $BRIGHTNESS > $MAX_BRIGHTNESS )); then BRIGHTNESS="$MAX_BRIGHTNESS"; fi
echo "Set $BRIGHTNESS"
echo "$BRIGHTNESS" > /sys/class/backlight/intel_backlight/brightness
