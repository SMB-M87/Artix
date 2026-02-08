# Source .zshrc if it exists
[[ -f ~/.zshrc ]] && source ~/.zshrc

# Automatically start X on TTY1
if [[ -z $DISPLAY ]] && [[ $(tty) == /dev/tty1 ]]; then
    exec startx
fi
