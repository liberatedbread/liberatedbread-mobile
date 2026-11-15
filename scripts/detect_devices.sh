#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_ROOT="$ROOT_DIR/workspace/logs"
TS="$(date +"%Y%m%d_%H%M%S")"
OUT="$LOG_ROOT/detect_$TS"

mkdir -p "$OUT"

log() { echo "[$(date +"%H:%M:%S")] $*" | tee -a "$OUT/run.log" >/dev/null; }

log "Starting device detection. Output: $OUT"

# Environment snapshot
{
  echo "date: $(date -Is)"
  echo "uname: $(uname -a 2>/dev/null || true)"
  echo "whoami: $(whoami 2>/dev/null || true)"
} > "$OUT/env.txt" 2>&1

########################################
# Host BLE scan
########################################
if command -v bluetoothctl >/dev/null 2>&1; then
  log "Host BLE scan via bluetoothctl --timeout 20 scan on"
  bluetoothctl --timeout 20 scan on > "$OUT/bluetoothctl_scan.txt" 2>&1 || true
  bluetoothctl devices > "$OUT/bluetoothctl_devices.txt" 2>&1 || true
else
  log "bluetoothctl not found; skipping host BLE scan"
fi

if command -v hcitool >/dev/null 2>&1; then
  log "Host BLE scan via hcitool lescan (deprecated; best-effort)"
  timeout 20s hcitool lescan --duplicates > "$OUT/hcitool_lescan.txt" 2>&1 || true
fi

########################################
# Host Wi-Fi scan
########################################
if command -v nmcli >/dev/null 2>&1; then
  log "Host Wi-Fi scan via nmcli"
  nmcli -f SSID,BSSID,CHAN,FREQ,SIGNAL,SECURITY dev wifi list > "$OUT/nmcli_wifi.txt" 2>&1 || true
else
  log "nmcli not found; skipping host Wi-Fi scan"
fi

########################################
# mDNS browse
########################################
if command -v avahi-browse >/dev/null 2>&1; then
  log "mDNS browse via avahi-browse -a -t (10s)"
  timeout 10s avahi-browse -a -t > "$OUT/avahi_browse.txt" 2>&1 || true
else
  log "avahi-browse not found; skipping mDNS browse"
fi

########################################
# SSDP / UPnP probe (M-SEARCH)
########################################
if command -v python3 >/dev/null 2>&1; then
  log "SSDP M-SEARCH probe (3s listen)"
  python3 - <<'PY' > "$OUT/ssdp_msearch.txt" 2>&1 || true
import socket, time

MCAST_GRP = "239.255.255.250"
MCAST_PORT = 1900

msg = "\r\n".join([
  "M-SEARCH * HTTP/1.1",
  f"HOST: {MCAST_GRP}:{MCAST_PORT}",
  'MAN: "ssdp:discover"',
  "MX: 2",
  "ST: ssdp:all",
  "", ""
]).encode("utf-8")

s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
s.settimeout(0.5)
s.sendto(msg, (MCAST_GRP, MCAST_PORT))

t_end = time.time() + 3.0
seen = set()
while time.time() < t_end:
  try:
    data, addr = s.recvfrom(65535)
    key = (addr, data[:80])
    if key in seen:
      continue
    seen.add(key)
    print(f"--- reply from {addr} ---")
    print(data.decode("utf-8", errors="replace"))
  except socket.timeout:
    pass
PY
else
  log "python3 not found; skipping SSDP probe"
fi

########################################
# Android device (adb) probes
########################################
if command -v adb >/dev/null 2>&1; then
  log "adb devices -l"
  adb devices -l > "$OUT/adb_devices.txt" 2>&1 || true

  if adb get-state >/dev/null 2>&1; then
    log "ADB connected; collecting dumpsys bluetooth_manager and wifi"
    adb shell dumpsys bluetooth_manager > "$OUT/adb_dumpsys_bluetooth_manager.txt" 2>&1 || true
    adb shell dumpsys wifi > "$OUT/adb_dumpsys_wifi.txt" 2>&1 || true

    log "Checking for /sdcard/btsnoop_hci.log"
    adb shell ls -l /sdcard/btsnoop_hci.log > "$OUT/adb_ls_btsnoop.txt" 2>&1 || true
    if adb shell '[ -f /sdcard/btsnoop_hci.log ]' >/dev/null 2>&1; then
      log "Pulling btsnoop_hci.log"
      adb pull /sdcard/btsnoop_hci.log "$OUT/btsnoop_hci.log" > "$OUT/adb_pull_btsnoop.txt" 2>&1 || true
    fi
  else
    log "No adb device in 'device' state; skipping adb shell probes"
  fi
else
  log "adb not found; skipping Android probes"
fi

########################################
# Highlight likely target fingerprints
########################################
log "Extracting highlights for known target strings"
{
  echo "=== Known device name / prefix hints ==="
  echo "SP107e"
  echo "LBXDRMSKIN_LED_"
  echo "PAX"
  echo "LOY"
  echo "NYAN"
  echo ""
  echo "=== Matches in scan outputs ==="
  grep -RInE "SP107e|LBXDRMSKIN_LED_|PAX|LOY|NYAN" "$OUT" || true
} > "$OUT/highlights.txt" 2>&1

log "Done."
