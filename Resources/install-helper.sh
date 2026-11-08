#!/bin/sh
# Runs as root. Arguments: path to coolantd, uid allowed to control the fans.
set -eu
LABEL=com.arterialist.coolantd
BIN=/Library/PrivilegedHelperTools/$LABEL
PLIST=/Library/LaunchDaemons/$LABEL.plist
case "$2" in ''|*[!0-9]*) echo "bad uid" >&2; exit 2;; esac

/bin/launchctl bootout system/$LABEL 2>/dev/null || true
/usr/bin/install -o root -g wheel -m 755 "$1" "$BIN"
cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array><string>$BIN</string><string>--uid</string><string>$2</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardErrorPath</key><string>/var/log/coolantd.log</string>
</dict>
</plist>
PLIST
/usr/sbin/chown root:wheel "$PLIST"
/bin/chmod 644 "$PLIST"
/bin/launchctl bootstrap system "$PLIST"
