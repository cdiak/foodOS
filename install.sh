#!/usr/bin/env bash
# Install foodos → ~/.local/bin + orb assets → ~/.local/share/foodos
# + vault files (base, food profile) → <vault>/<folder> + login LaunchAgent
#
#   FOODOS_VAULT=~/path/to/vault ./install.sh
#   FOODOS_VAULT=~/path/to/vault FOODOS_FOLDER="Health/Nutrition" ./install.sh
#
# Without FOODOS_VAULT, the value saved by a previous install is reused. With
# neither, the script lists your Obsidian vaults and stops.
set -euo pipefail
cd "$(dirname "$0")"

BIN_DIR="${HOME}/.local/bin"
SHARE_DIR="${HOME}/.local/share/foodos"
CONFIG_DIR="${HOME}/.config/foodos"
CONFIG_FILE="${CONFIG_DIR}/config"
LAUNCH_AGENTS="${HOME}/Library/LaunchAgents"
LABEL="com.cdiak.foodos"
PLIST="${LAUNCH_AGENTS}/${LABEL}.plist"
DEST="${BIN_DIR}/foodos"

# Previous install's choices, unless overridden
saved() { [[ -f "$CONFIG_FILE" ]] && sed -n "s/^$1=//p" "$CONFIG_FILE" | tail -1 || true; }
FOODOS_VAULT="${FOODOS_VAULT:-$(saved FOODOS_VAULT)}"
FOODOS_FOLDER="${FOODOS_FOLDER:-$(saved FOODOS_FOLDER)}"
FOODOS_FOLDER="${FOODOS_FOLDER:-Nutrition}"

# Choose the vault: fail loud with the list of known vaults
if [[ -z "$FOODOS_VAULT" ]]; then
  echo "error: set FOODOS_VAULT to the Obsidian vault foodOS should write to." >&2
  OBS_JSON="${HOME}/Library/Application Support/obsidian/obsidian.json"
  if [[ -f "$OBS_JSON" ]]; then
    echo "Obsidian vaults on this Mac:" >&2
    /usr/bin/python3 -c 'import json,sys; import os; [print("  " + v["path"]) for v in json.load(open(sys.argv[1]))["vaults"].values() if os.path.isdir(v["path"])]' "$OBS_JSON" >&2 || true
  fi
  echo "Example: FOODOS_VAULT=\"\$HOME/Notes\" ./install.sh" >&2
  exit 1
fi
FOODOS_VAULT="${FOODOS_VAULT/#\~/$HOME}"
if [[ ! -d "$FOODOS_VAULT" ]]; then
  echo "error: vault folder does not exist: $FOODOS_VAULT" >&2
  exit 1
fi
if [[ ! -d "$FOODOS_VAULT/.obsidian" ]]; then
  echo "warning: $FOODOS_VAULT has no .obsidian folder — is it an Obsidian vault?" >&2
fi
FOODOS_FOLDER="${FOODOS_FOLDER%/}"
NUTRITION_DIR="${FOODOS_VAULT}/${FOODOS_FOLDER}"

mkdir -p "$BIN_DIR" "$SHARE_DIR" "$CONFIG_DIR" "$LAUNCH_AGENTS" "${NUTRITION_DIR}/Meals"

./build.sh "$DEST"

# Orb assets (vendored thinking-orbs engine + driver page)
rm -rf "${SHARE_DIR}/orb"
cp -R orb "${SHARE_DIR}/orb"

# Vault files: copy once, never overwrite (your edits and targets stay)
BASE="${NUTRITION_DIR}/Calorie Counter.base"
PROFILE="${NUTRITION_DIR}/Food profile.md"
if [[ -e "$BASE" ]]; then
  echo "kept existing: $BASE"
else
  # The base filters on the meals folder, a path relative to the vault root
  folder_sed="$(printf '%s' "$FOODOS_FOLDER" | sed -e 's/[\/&#]/\\&/g')"
  sed "s#{{FOLDER}}#${folder_sed}#" "vault-template/Calorie Counter.base" > "$BASE"
  echo "created: $BASE"
fi
if [[ -e "$PROFILE" ]]; then
  echo "kept existing: $PROFILE"
else
  cp "vault-template/Food profile.md" "$PROFILE"
  echo "created: $PROFILE"
fi

# Stop current agent
launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null || true
launchctl unload "$PLIST" 2>/dev/null || true

# Tool paths: env → previous install → auto-detect below
WHISPER_CLI="${WHISPER_CLI:-$(saved WHISPER_CLI)}"
WHISPER_MODEL="${WHISPER_MODEL:-$(saved WHISPER_MODEL)}"
CLAUDE_CLI="${CLAUDE_CLI:-$(saved CLAUDE_CLI)}"

# Resolve whisper-cli: env → PATH → common Homebrew location
if [[ -z "${WHISPER_CLI:-}" ]]; then
  if command -v whisper-cli >/dev/null 2>&1; then
    WHISPER_CLI="$(command -v whisper-cli)"
  else
    WHISPER_CLI="/opt/homebrew/bin/whisper-cli"
  fi
fi

# Resolve a whisper model: env → saved config → common locations
if [[ -z "${WHISPER_MODEL:-}" ]]; then
  for candidate in \
    "${HOME}/.cache/whisper/ggml-base.en.bin" \
    "${HOME}/models/whisper/ggml-base.en.bin" \
    "/opt/homebrew/share/whisper-cpp/ggml-base.en.bin"
  do
    if [[ -f "$candidate" ]]; then
      WHISPER_MODEL="$candidate"
      break
    fi
  done
fi
WHISPER_MODEL="${WHISPER_MODEL:-}"
WHISPER_LANGUAGE="${WHISPER_LANGUAGE:-en}"

if [[ -z "$WHISPER_MODEL" ]]; then
  echo "warning: no whisper model found. Set WHISPER_MODEL to a ggml model path." >&2
fi

# Resolve claude CLI: env → PATH → common locations
if [[ -z "${CLAUDE_CLI:-}" ]]; then
  if command -v claude >/dev/null 2>&1; then
    CLAUDE_CLI="$(command -v claude)"
  elif [[ -x "${HOME}/.local/bin/claude" ]]; then
    CLAUDE_CLI="${HOME}/.local/bin/claude"
  elif [[ -x "${HOME}/.claude/local/claude" ]]; then
    CLAUDE_CLI="${HOME}/.claude/local/claude"
  else
    CLAUDE_CLI="/opt/homebrew/bin/claude"
  fi
fi
FOODOS_MODEL="${FOODOS_MODEL:-$(saved FOODOS_MODEL)}"
FOODOS_MODEL="${FOODOS_MODEL:-sonnet}"
FOODOS_TIMEOUT="${FOODOS_TIMEOUT:-$(saved FOODOS_TIMEOUT)}"
FOODOS_TIMEOUT="${FOODOS_TIMEOUT:-120}"

if [[ ! -x "$CLAUDE_CLI" ]]; then
  echo "warning: claude CLI not found at $CLAUDE_CLI. Set CLAUDE_CLI and re-run." >&2
fi

# One config file serves both the LaunchAgent and `foodos --log` in a shell
cat > "$CONFIG_FILE" <<CONFIG
# foodOS settings — written by install.sh. Environment variables override.
FOODOS_VAULT=${FOODOS_VAULT}
FOODOS_FOLDER=${FOODOS_FOLDER}
FOODOS_MODEL=${FOODOS_MODEL}
FOODOS_TIMEOUT=${FOODOS_TIMEOUT}
FOODOS_ORB_DIR=${SHARE_DIR}/orb
WHISPER_CLI=${WHISPER_CLI}
WHISPER_MODEL=${WHISPER_MODEL}
WHISPER_LANGUAGE=${WHISPER_LANGUAGE}
CLAUDE_CLI=${CLAUDE_CLI}
CONFIG

# Escape XML special chars in paths for plist
xml_escape() {
  printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'
}

DEST_XML="$(xml_escape "$DEST")"
HOME_XML="$(xml_escape "$HOME")"

cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${DEST_XML}</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
  </dict>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>${HOME_XML}/Library/Logs/foodos.log</string>
  <key>StandardErrorPath</key>
  <string>${HOME_XML}/Library/Logs/foodos.log</string>
  <key>ProcessType</key>
  <string>Interactive</string>
</dict>
</plist>
PLIST

launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null \
  || launchctl load "$PLIST"

echo
echo "Installed foodos"
echo "  binary:  $DEST"
echo "  config:  $CONFIG_FILE"
echo "  orb:     ${SHARE_DIR}/orb"
echo "  agent:   $PLIST"
echo "  log:     $HOME/Library/Logs/foodos.log"
echo "  whisper: $WHISPER_CLI"
echo "  model:   ${WHISPER_MODEL:-(not set)}"
echo "  claude:  $CLAUDE_CLI"
echo "  vault:   $FOODOS_VAULT"
echo "  folder:  $FOODOS_FOLDER  (meals in $FOODOS_FOLDER/Meals)"
echo
echo "Hotkey: Option+Shift+F  (record → stop+log; press while logging to cancel)"
echo
echo "Permissions (first run):"
echo "  System Settings → Privacy & Security → Microphone → foodos"
echo "  No Accessibility grant is needed — foodos never pastes or taps keys."
echo "  If missing from the list, run once: $DEST"
echo
echo "Menu bar: \"F\" idle · \"●\" recording · \"…\" transcribing · \"◍\" estimating"
echo "Orb: listening wave while you speak · composing ribbon while the meal is estimated"
echo "Uninstall: ./uninstall.sh"
