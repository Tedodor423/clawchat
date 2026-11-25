#!/bin/bash
# Offscreen renders of ChatCard in a few states (no window on screen):
#   bash ~/.config/omarchy/plugins/theo.clawchat/dev/harness.sh
# PNGs land in $CLAWCHAT_DEV_DIR/shots (default $XDG_RUNTIME_DIR/theo-clawchat-dev).
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
plugin=$(dirname "$here")
dir="${CLAWCHAT_DEV_DIR:-${XDG_RUNTIME_DIR:-/tmp}/theo-clawchat-dev}"
rm -rf "$dir"
mkdir -p "$dir/qsroot" "$dir/shots"
ln -sfn /usr/share/omarchy/shell/Commons "$dir/qsroot/Commons"
ln -sfn /usr/share/omarchy/shell/Ui "$dir/qsroot/Ui"
ln -sfn "$plugin" "$dir/qsroot/plugin"
cat > "$dir/qsroot/shell.qml" <<'QML'
//@ pragma OmarchyLoadPatch
import QtQuick
import Quickshell
import "plugin/dev" as D

ShellRoot {
  FloatingWindow {
    implicitWidth: 1500
    implicitHeight: 950
    color: "black"
    D.Harness { anchors.fill: parent }
  }
}
QML
export CLAWCHAT_DEV_DIR="$dir"
QT_QPA_PLATFORM=offscreen QT_FORCE_STDERR_LOGGING=1 timeout 60 qs -p "$dir/qsroot" 2>&1 |
  sed -e 's/\x1b\[[0-9;]*m//g' |
  grep -v -E 'WAYLAND_DISPLAY|--- WARNING|actually running wayland|window masks|Launching config|Shell ID|Saving logs|Configuration Loaded|most functionality' || true
ls "$dir/shots"
