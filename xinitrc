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

# Start compositor for basic X11 window compositing,
# supporting effects such as transparency and the prevention of visual tearing
xcompmgr &

# Small delay to give the compositor time to initialize
sleep 1 &

# Set the desktop wallpaper
# --zoom scales/crops the image to fill the screen
xwallpaper --zoom /usr/local/share/wallpaper.jpg &

# Automatically detect and apply the appropriate monitor configuration
# Usefull when switching between different displays/docking stations
autorandr -c

# Continuously update the dwm status bar
while true; do
        DATE=$(date '+%a %b %d %H:%M:%S')
        BAT=$(cat /sys/class/power_supply/BAT0/capacity)
        xsetroot -name "$DATE | $BAT"
        sleep 1
done &

# Start the dwm windows manager
exec dwm
