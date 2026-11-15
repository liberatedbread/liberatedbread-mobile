#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGETS_CSV="${TARGETS_CSV:-$ROOT_DIR/targets/targets.csv}"
APK_ROOT="${APK_ROOT:-$ROOT_DIR/workspace/apks}"
OUT_ROOT="${OUT_ROOT:-$ROOT_DIR/workspace/static}"

TARGET_ID="${1:-${TARGET_ID:-}}"

if [[ -z "$TARGET_ID" ]]; then
  echo "Usage: $0 <target_id>"
  echo "Example: $0 pax-vape"
  exit 1
fi

if [[ ! -f "$TARGETS_CSV" ]]; then
  echo "ERROR: targets.csv not found at: $TARGETS_CSV"
  exit 1
fi

need_tool() {
  local t="$1"
  command -v "$t" >/dev/null 2>&1 || {
    echo "ERROR: missing tool: $t"
    exit 1
  }
}

need_tool jadx
need_tool apktool

mapfile -t PKGS < <(awk -F, -v tid="$TARGET_ID" 'NR>1 && $2==tid {print $1}' "$TARGETS_CSV")
if [[ "${#PKGS[@]}" -eq 0 ]]; then
  echo "ERROR: no packages mapped to target_id=$TARGET_ID in $TARGETS_CSV"
  exit 1
fi

mkdir -p "$OUT_ROOT/$TARGET_ID"
TARGET_SUMMARY="$OUT_ROOT/$TARGET_ID/summary.md"

{
  echo "# Static decompile summary: $TARGET_ID"
  echo
  echo "Generated: $(date -Is)"
  echo
  echo "## Packages"
  for p in "${PKGS[@]}"; do
    echo "- \\`$p\\`"
  done
  echo
  echo "## APK scan results"
} > "$TARGET_SUMMARY"

found_any=0

scan_apk() {
  local pkg="$1"
  local apk="$2"
  local apk_name
  apk_name="$(basename "$apk")"
  local pkg_out="$OUT_ROOT/$TARGET_ID/$pkg"
  local jadx_dir="$pkg_out/jadx"
  local apktool_dir="$pkg_out/apktool"
  local summary_dir="$pkg_out/summary"

  mkdir -p "$jadx_dir" "$apktool_dir" "$summary_dir"

  echo "[static-target] $TARGET_ID :: $pkg :: $apk_name"
  jadx -d "$jadx_dir" "$apk" >"$summary_dir/jadx.log" 2>&1 || true
  apktool d -f -o "$apktool_dir" "$apk" >"$summary_dir/apktool.log" 2>&1 || true

  if command -v rg >/dev/null 2>&1; then
    rg -n --no-heading -S \
      "bluetooth|gatt|uuid|0000[0-9a-fA-F]{4}-0000-1000-8000-00805f9b34fb|mdns|_tcp|ssdp|239\\.255\\.255\\.250|5353|mqtt|websocket|wss://|https://|http://" \
      "$jadx_dir" >"$summary_dir/rg_protocol_hints.txt" 2>/dev/null || true
  fi

  {
    echo "### $pkg"
    echo "- APK: \\`$apk\\`"
    echo "- jadx log: \\`$summary_dir/jadx.log\\`"
    echo "- apktool log: \\`$summary_dir/apktool.log\\`"
    echo "- protocol hints: \\`$summary_dir/rg_protocol_hints.txt\\`"
    echo
  } >> "$TARGET_SUMMARY"
}

for pkg in "${PKGS[@]}"; do
  mapfile -t APKS < <(find "$APK_ROOT" -type f -name "*.apk" | rg "/${pkg}([_/.-]|$)" || true)

  if [[ "${#APKS[@]}" -eq 0 ]]; then
    {
      echo "### $pkg"
      echo "- No APK found under \\`$APK_ROOT\\`"
      echo "- Next: run \\`./scripts/fetch_apks_apkeep.sh\\` or \\`./scripts/pull_apks_adb.sh\\`"
      echo
    } >> "$TARGET_SUMMARY"
    continue
  fi

  found_any=1
  for apk in "${APKS[@]}"; do
    scan_apk "$pkg" "$apk"
  done
done

echo "[static-target] summary: $TARGET_SUMMARY"
if [[ "$found_any" -eq 0 ]]; then
  echo "[static-target] WARNING: no APKs found for target $TARGET_ID"
fi
