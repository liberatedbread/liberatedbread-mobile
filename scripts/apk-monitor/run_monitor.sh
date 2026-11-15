#!/usr/bin/env bash
# APK Monitoring Agent — cron entry point.
#
# This script is designed to be called from a crontab entry.
# It loads config, activates a virtualenv if present, and runs the
# Python orchestrator.
#
# Usage:
#   ./run_monitor.sh              # full pipeline
#   ./run_monitor.sh --scan-only  # discover + scan only
#   ./run_monitor.sh --target X   # run RE on specific target
#   ./run_monitor.sh --vote X     # vote on existing candidates

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Load config.env if present
if [[ -f "$SCRIPT_DIR/config.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/config.env"
  set +a
fi

# Activate virtualenv if present
for venv_dir in "$ROOT_DIR/venv" "$ROOT_DIR/.venv" "$SCRIPT_DIR/venv"; do
  if [[ -f "$venv_dir/bin/activate" ]]; then
    # shellcheck disable=SC1091
    source "$venv_dir/bin/activate"
    break
  fi
done

# Ensure workspace dirs exist
export WORKSPACE_DIR="${WORKSPACE_DIR:-$ROOT_DIR/workspace}"
mkdir -p "$WORKSPACE_DIR/apk-monitor/runs"
mkdir -p "$WORKSPACE_DIR/apk-monitor/scans"

# Log file for this run
TS="$(date +"%Y%m%d_%H%M%S")"
LOG_FILE="$WORKSPACE_DIR/apk-monitor/runs/cron_${TS}.log"

# Run the monitor
echo "[$(date -Is)] Starting APK monitor run" | tee "$LOG_FILE"
python3 "$SCRIPT_DIR/monitor.py" "$@" 2>&1 | tee -a "$LOG_FILE"
EXIT_CODE=${PIPESTATUS[0]}

echo "[$(date -Is)] Monitor exited with code $EXIT_CODE" | tee -a "$LOG_FILE"
exit "$EXIT_CODE"
