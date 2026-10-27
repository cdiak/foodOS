#!/usr/bin/env bash
set -euo pipefail
LABEL="com.cdiak.foodos"
PLIST="${HOME}/Library/LaunchAgents/${LABEL}.plist"
DEST="${HOME}/.local/bin/foodos"
SHARE_DIR="${HOME}/.local/share/foodos"

launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null || true
launchctl unload "$PLIST" 2>/dev/null || true
rm -f "$PLIST"
rm -f "$DEST"
rm -rf "$SHARE_DIR"
rm -rf "${HOME}/.config/foodos"
echo "Removed foodos (binary, orb assets, config, LaunchAgent). Your meal notes stay in place."
