#!/bin/sh
# Runs as root. The helper returns the fans to automatic when launchd stops it.
LABEL=com.arterialist.coolantd
/bin/launchctl bootout system/$LABEL 2>/dev/null || true
/bin/rm -f /Library/PrivilegedHelperTools/$LABEL /Library/LaunchDaemons/$LABEL.plist
