#!/bin/sh
# Install a LaunchAgent so toaster-face starts at login. Run ./install-login.sh uninstall to remove.
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
LABEL=com.juleah.toaster-face
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
UID_=$(id -u)
launchctl bootout "gui/$UID_/$LABEL" 2>/dev/null || true
if [ "$1" = "uninstall" ]; then rm -f "$PLIST"; echo "removed"; exit 0; fi
cat > "$PLIST" <<P
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$DIR/toaster-face</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
</dict></plist>
P
launchctl bootstrap "gui/$UID_" "$PLIST"
echo "installed, running"
