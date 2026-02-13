#!/bin/sh

prefix="/usr"
exec_prefix="${prefix}"
xrdb="xrdb"
xinitdir="/etc/X11/xinit"
xclock="xclock"
xterm="xterm"
twm="twm"
xmodmap="xmodmap"

userresources="$HOME/.Xresources"
usermodmap="$HOME/.Xmodmap"
sysresources="$xinitdir/.Xresources"
sysmodmap="$xinitdir/.Xmodmap"

# merge in defaults and keymaps

if [ -f "$sysresources" ]; then
    if [ -x /usr/bin/cpp ] ; then
        "$xrdb" -merge "$sysresources"
    else
        "$xrdb" -nocpp -merge "$sysresources"
    fi
fi

if [ -f "$sysmodmap" ]; then
    "$xmodmap" "$sysmodmap"
fi

if [ -f "$userresources" ]; then
    if [ -x /usr/bin/cpp ] ; then
        "$xrdb" -merge "$userresources"
    else
        "$xrdb" -nocpp -merge "$userresources"
    fi
fi

if [ -f "$usermodmap" ]; then
    "$xmodmap" "$usermodmap"
fi

# start some nice programs

if [ -d "$xinitdir"/xinitrc.d ] ; then
        for f in "$xinitdir/xinitrc.d"/?*.sh ; do
                [ -x "$f" ] && . "$f"
        done
        unset f
fi

xcompmgr &
sleep 1 &
xwallpaper --zoom /usr/local/share/wallpaper.jpg &

autorandr -c

while true; do
        DATE=$(date '+%a %b %d %H:%M:%S')
        BAT=$(cat /sys/class/power_supply/BAT0/capacity)
        xsetroot -name "$DATE | $BAT"
        sleep 1
done &

while ! xinput list --short | grep -q "slave\s\+pointer"; do 
	sleep 0.5;
done; 

xinput list --short | grep -E "slave\s+pointer" | while read -r l; do 
	id=$(echo "$l" | sed -n 's/.*id=\([0-9]\+\).*/\1/p');
	xinput set-button-map "$id" 3 2 1; 
done;

exec dwm
