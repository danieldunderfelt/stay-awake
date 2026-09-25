#!/bin/zsh
# Builds StayAwake.app into ~/Applications, starts it at login, and installs
# a sudoers rule allowing only `pmset -a disablesleep 0|1` and
# `pmset -a|-b|-c powermode 0|1|2` without a password.
set -euo pipefail
cd "${0:A:h}"

APP="$HOME/Applications/StayAwake.app"
AGENT="$HOME/Library/LaunchAgents/com.daniel.stayawake.plist"
SUDOERS=/etc/sudoers.d/stayawake

pkill -x StayAwake 2>/dev/null || true
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
swiftc -O main.swift -o "$APP/Contents/MacOS/StayAwake"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.daniel.stayawake</string>
  <key>CFBundleName</key><string>StayAwake</string>
  <key>CFBundleExecutable</key><string>StayAwake</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP"

cat > "$AGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.daniel.stayawake</string>
  <key>ProgramArguments</key><array><string>$APP/Contents/MacOS/StayAwake</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
</dict></plist>
PLIST
launchctl bootout "gui/$(id -u)/com.daniel.stayawake" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$AGENT"

echo "Installing sudoers rule (asks for your password)..."
RULE="$(whoami) ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep [01], /usr/bin/pmset -[abc] powermode [012]"
TMP="$(mktemp)"
echo "$RULE" > "$TMP"
visudo -cf "$TMP"
sudo install -m 0440 -o root -g wheel "$TMP" "$SUDOERS"
rm "$TMP"
sudo -n /usr/bin/pmset -a disablesleep 1
echo "StayAwake installed and running. Stay Awake is ON."
