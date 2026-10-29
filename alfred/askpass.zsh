#!/bin/zsh
# SUDO_ASKPASS helper: sudo -A runs this and reads the password from stdout.
# Cancelling the dialog exits non-zero, which sudo treats as no password.
/usr/bin/osascript \
    -e 'display dialog "Patchy needs your password to update /etc/hosts." with title "Patchy" default answer "" with hidden answer with icon caution' \
    -e 'text returned of result' 2>/dev/null
