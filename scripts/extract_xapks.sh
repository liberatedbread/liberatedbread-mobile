#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APK_ROOT="${APK_ROOT:-$ROOT_DIR/workspace/apks}"

mapfile -t XAPKS < <(find "$APK_ROOT" -type f -name "*.xapk" | sort)

if [[ "${#XAPKS[@]}" -eq 0 ]]; then
  echo "[extract-xapks] No .xapk files found under $APK_ROOT"
  exit 0
fi

for xapk in "${XAPKS[@]}"; do
  dir="$(dirname "$xapk")"
  stem="$(basename "$xapk" .xapk)"
  base_apk="$dir/${stem}.apk"

  if [[ -f "$base_apk" ]]; then
    echo "[extract-xapks] SKIP (already exists): $(basename "$base_apk")"
    continue
  fi

  echo "[extract-xapks] extracting: $(basename "$xapk") -> $(basename "$base_apk")"
  unzip -j -o "$xapk" "${stem}.apk" -d "$dir" || {
    echo "[extract-xapks] WARN: failed to extract base APK from $(basename "$xapk")"
    continue
  }
done

echo "[extract-xapks] done."
