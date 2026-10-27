#!/usr/bin/env bash
# Installs the mclean CLI in ~/.local/bin and an hourly launchd agent that records free space
# (`mclean status`), so the history/forecast has data even when the app stays closed.
# Usage: scripts/install-cli.sh [--uninstall]
set -euo pipefail
label=dev.lellis.mclean.sample
plist="$HOME/Library/LaunchAgents/$label.plist"
domain="gui/$(id -u)"

if [[ "${1:-}" == "--uninstall" ]]; then
  launchctl bootout "$domain/$label" 2>/dev/null || true
  rm -f "$plist"
  echo "agente removido (a CLI em ~/.local/bin/mclean fica)"
  exit 0
fi

cd "$(dirname "$0")/.."
swift build -c release --product mclean
mkdir -p "$HOME/.local/bin" "$HOME/Library/LaunchAgents"
install -m 0755 .build/release/mclean "$HOME/.local/bin/mclean"

cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key><array>
    <string>$HOME/.local/bin/mclean</string><string>status</string><string>--json</string>
  </array>
  <key>StartInterval</key><integer>3600</integer>
  <key>RunAtLoad</key><true/>
  <key>LowPriorityIO</key><true/>
  <key>ProcessType</key><string>Background</string>
  <key>StandardOutPath</key><string>/dev/null</string>
  <key>StandardErrorPath</key><string>/dev/null</string>
</dict></plist>
PLIST

launchctl bootout "$domain/$label" 2>/dev/null || true
launchctl bootstrap "$domain" "$plist"
echo "ok: ~/.local/bin/mclean + agente $label (a cada hora)"
