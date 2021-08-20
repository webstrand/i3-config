#!/bin/bash
if [ ! -e "$HOME/.config/pmenu_ignore" ]; then
    touch "$HOME/.config/pmenu_ignore"
fi

shopt -s lastpipe

{
    tac "$HOME/.config/pmenu_history";
    compgen -ac | sort -u;
} |
perl -nE '$seen{$_}++ or $ARGV[0] or print' "$HOME/.config/pmenu_ignore" - |
dmenu -i -f "$@" |
tee -a "$HOME/.config/pmenu_history" |
tr '\n' ' ' |
xargs -0 -n1 -I{} "${SHELL:-"/bin/sh"}" -c '{} & disown'
