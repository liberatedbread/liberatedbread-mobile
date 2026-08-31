#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SESSION="${SESSION:-ogiot}"

if ! command -v tmux >/dev/null 2>&1; then
  echo "ERROR: tmux not found."
  exit 1
fi

# If session exists, attach
if tmux has-session -t "$SESSION" 2>/dev/null; then
  tmux attach -t "$SESSION"
  exit 0
fi

tmux new-session -d -s "$SESSION" -n "overview" -c "$ROOT_DIR"
tmux send-keys -t "$SESSION:overview" "cd \"$ROOT_DIR\" && echo 'Open Green IoT RE session' && ls" C-m

new_agent_window() {
  local name="$1"
  local hint="$2"
  tmux new-window -t "$SESSION" -n "$name" -c "$ROOT_DIR"
  tmux send-keys -t "$SESSION:$name" "cd \"$ROOT_DIR\" && echo \"$hint\" && bash" C-m
}

# Existing targets (examples)
new_agent_window "agent-magic"      "Target: magic-display (com.tirohk.magicdisplay)"
new_agent_window "agent-glasses"    "Target: shining-glasses (com.icwork.shiningglass)"
new_agent_window "agent-mask"       "Target: shining-mask (cn.com.heaton.shiningmask)"
new_agent_window "agent-badge"      "Target: bluetooth-led-name-badge (com.yannis.ledcard)"
new_agent_window "agent-idot"       "Target: idotmatrix (com.tech.idotmatrix)"
new_agent_window "agent-cams"       "Targets: roadcam / goplus-cam / sports-dv / dvrunning2"

# New targets requested
new_agent_window "agent-pax"        "Target: pax-vape (com.pax.app) — allowed exception"
new_agent_window "agent-lunchbox"   "Target: leds2rave4-lunchbox-led (LED Chord / SpotLED / iledcolor)"
new_agent_window "agent-chefiq"     "Target: chef-iq-sense (com.chefman.chefiq.prod)"
new_agent_window "agent-autobaba"   "Target: autobaba-led-backpack (LOY SPACE ecosystem)"
new_agent_window "agent-nyan"       "Target: nyan-bt-image-controller (com.nyan.gear)"

tmux select-window -t "$SESSION:overview"
tmux attach -t "$SESSION"
