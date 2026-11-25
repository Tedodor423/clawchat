#!/bin/bash
# Sets up clawchat on an Omarchy machine. Run it from the plugin folder:
#
#   git clone https://github.com/Tedodor423/clawchat ~/.config/omarchy/plugins/theo.clawchat
#   ~/.config/omarchy/plugins/theo.clawchat/install.sh
#
# It installs the gateway client library, writes a settings file, pairs this
# device with your OpenClaw gateway, enables the plugin and binds the key.
# Safe to run again. Options:
#   --key F8        key to bind (default F8)
#   --no-bind       leave ~/.config/hypr/bindings.lua alone
set -euo pipefail

key=F8
bind=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --key) key="$2"; shift 2 ;;
    --no-bind) bind=0; shift ;;
    -h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 64 ;;
  esac
done

id=theo.clawchat
here=$(cd "$(dirname "$0")" && pwd)
plugins="$HOME/.config/omarchy/plugins"
lib="$HOME/.local/share/$id/bridge"
state="$HOME/.local/state/omarchy/$id"
config="$state/config.json"

for tool in node npm omarchy-shell; do
  command -v "$tool" >/dev/null || { echo "Missing: $tool" >&2; exit 1; }
done
command -v voxtype >/dev/null || echo "Note: voxtype is not installed, so hold-to-talk won't work (typing will). Omarchy: omarchy install dictation"

if [[ $here != "$plugins/$id" ]]; then
  echo "This folder must be $plugins/$id (it is $here)." >&2
  exit 1
fi

# 1. Gateway client library, kept outside the plugin folder (the shell reloads
#    the plugin whenever a file in it changes).
mkdir -p "$lib"
if [[ ! -f $lib/node_modules/@openclaw/gateway-client/dist/index.mjs ]]; then
  echo "Installing @openclaw/gateway-client..."
  [[ -f $lib/package.json ]] || echo '{"name":"clawchat-bridge","private":true,"type":"module"}' > "$lib/package.json"
  npm install --prefix "$lib" --no-fund --no-audit --silent @openclaw/gateway-client
fi

# 2. Settings
mkdir -p "$state"
if [[ ! -f $config ]]; then
  url="${OPENCLAW_GATEWAY_URL:-}"
  if [[ -z $url && -t 0 ]]; then
    read -r -p "Gateway URL (for example wss://myserver.my-tailnet.ts.net): " url
  fi
  name=""
  [[ -t 0 ]] && read -r -p "Your agent's name [OpenClaw]: " name
  CLAWCHAT_URL="$url" CLAWCHAT_NAME="${name:-OpenClaw}" CLAWCHAT_KEY="$key" node -e '
    const fs = require("fs");
    fs.writeFileSync(process.argv[1], JSON.stringify({
      gatewayUrl: process.env.CLAWCHAT_URL, agentName: process.env.CLAWCHAT_NAME,
      channel: "telegram", deliver: false, keyLabel: process.env.CLAWCHAT_KEY }, null, 2) + "\n");' "$config"
  echo "Wrote $config"
fi

# 3. Pairing
bridge="$here/bridge/clawchat-bridge.mjs"
if node "$bridge" whoami | grep -q '"deviceToken":true'; then
  echo "Already paired with the gateway."
else
  token="${OPENCLAW_GATEWAY_TOKEN:-}"
  if [[ -z $token && -t 0 ]]; then
    read -r -s -p "Gateway token (used once to pair, not stored): " token; echo
  fi
  if [[ -n $token ]]; then
    OPENCLAW_GATEWAY_TOKEN="$token" node "$bridge" pair || {
      echo "Pairing did not complete. If the gateway wants the device approved, approve it there" >&2
      echo "and run this script again." >&2
    }
  else
    echo "Not paired: run  OPENCLAW_GATEWAY_TOKEN=... node $bridge pair"
  fi
fi

# 4. Plugin
omarchy plugin enable "$id" >/dev/null 2>&1 || omarchy-shell shell setPluginEnabled "$id" true >/dev/null 2>&1 || true
echo "Plugin enabled."

# 5. Key
bindings="$HOME/.config/hypr/bindings.lua"
if [[ $bind == 1 && -f $bindings ]]; then
  if grep -q -- "-- BEGIN clawchat" "$bindings"; then
    echo "Key binding already present in $bindings."
  else
    cp "$bindings" "$bindings.bak.$(date +%s)"
    cat >> "$bindings" <<LUA

-- BEGIN clawchat
-- Hidden: hold $key = window + dictation. Open: hold = dictate more, tap = send
-- the draft, or close when it is empty.
o.bind_hold("$key", "Clawchat: talk (hold), send or close (tap)", "omarchy-shell -q $id press", "Clawchat: key released", "omarchy-shell -q $id release")
-- END clawchat
LUA
    hyprctl reload >/dev/null 2>&1 || true
    echo "Bound $key in $bindings."
  fi
fi

echo "Done. Hold $key and speak."
