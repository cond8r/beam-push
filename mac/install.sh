#!/bin/bash
# Install Beam Mac menubar app as LaunchAgent
set -e

PLIST="$HOME/Library/LaunchAgents/com.fangduo.beam.plist"

echo "==> Installing Beam Mac menubar app..."
cp "$(dirname "$0")/com.fangduo.beam.plist" "$PLIST"
launchctl unload "$PLIST" 2>/dev/null || true
launchctl load "$PLIST"
echo "✓ Beam started. Look for 📡 in your menu bar."
