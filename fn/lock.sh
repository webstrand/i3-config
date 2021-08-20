#!/bin/bash
cd $HOME/.i3
trezorctl clear-session &

revert() {
  xset dpms 300 300 300
}
trap revert SIGHUP SIGINT SIGTERM
xset +dpms dpms 15 15 15
i3lock -i $(readlink -f ~/.i3/xinerama.png)  -f -e -n -t
#i3lock -i <(import -window root miff:- | convert miff:- -scale 10% -scale $(xwininfo -root | grep -oP "(?<=geometry )(\d+x\d+)")\! png:-) -f -e -n
revert

