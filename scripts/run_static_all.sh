#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APK_ROOT="${APK_ROOT:-$ROOT_DIR/workspace/apks}"
OUT_ROOT="${OUT_ROOT:-$ROOT_DIR/workspace/static}"

PARALLEL_JOBS="${PARALLEL_JOBS:-4}"

mkdir -p "$OUT_ROOT"

need_tool() {
  local t="$1"
  command -v "$t" >/dev/null 2>&1 || {
    echo "ERROR: missing tool: $t"
    exit 1
  }
}

need_tool jadx
need_tool apktool

summarize_one() {
  local apk="$1"
  local fn
  fn="$(basename "$apk")"
  local stem="${fn%.apk}"

  # Best-effort package directory name
  local pkg="$stem"
  pkg="${pkg%%_*}"

  local out_dir="$OUT_ROOT/$pkg"
  local jadx_dir="$out_dir/jadx"
  local apktool_dir="$out_dir/apktool"
  local summary_dir="$out_dir/summary"

  mkdir -p "$jadx_dir" "$apktool_dir" "$summary_dir"

  echo "[static] $pkg :: $apk"

  # jadx (code + resources decode)
  jadx -d "$jadx_dir" "$apk" >"$summary_dir/jadx.log" 2>&1 || true

  # apktool (manifest/resources decode)
  apktool d -f -o "$apktool_dir" "$apk" >"$summary_dir/apktool.log" 2>&1 || true

  # greps for likely protocol markers (derived hints only)
  if command -v rg >/dev/null 2>&1; then
    rg -n --no-heading -S \
      "bluetooth|gatt|uuid|0000[0-9a-fA-F]{4}-0000-1000-8000-00805f9b34fb|mdns|_tcp|ssdp|239\\.255\\.255\\.250|5353|mqtt|websocket|wss://|https://|http://" \
      "$jadx_dir" >"$summary_dir/rg_protocol_hints.txt" 2>/dev/null || true
  fi
}

export -f summarize_one

mapfile -t APKS < <(find "$APK_ROOT" -type f -name "*.apk" | sort)

if [[ "${#APKS[@]}" -eq 0 ]]; then
  echo "No .apk files found under $APK_ROOT"
  exit 0
fi

if command -v parallel >/dev/null 2>&1; then
  printf "%s\n" "${APKS[@]}" | parallel -j "$PARALLEL_JOBS" summarize_one {}
else
  for apk in "${APKS[@]}"; do
    summarize_one "$apk"
  done
fi

echo "[static] done. Output root: $OUT_ROOT"
