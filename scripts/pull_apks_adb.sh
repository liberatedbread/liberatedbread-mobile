#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGETS_CSV="${TARGETS_CSV:-$ROOT_DIR/targets/targets.csv}"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/workspace/apks/adb}"

mkdir -p "$OUT_DIR"

if ! command -v adb >/dev/null 2>&1; then
  echo "ERROR: adb not found. Install Android platform-tools."
  exit 1
fi

adb get-state >/dev/null 2>&1 || {
  echo "ERROR: no adb device/emulator detected."
  adb devices -l || true
  exit 1
}

# Package list: explicit args win, otherwise try every package in targets.csv.
# Placeholder package ids (TBD / N/A) can never be installed, so drop them.
if [[ "$#" -gt 0 ]]; then
  mapfile -t PKGS < <(printf "%s\n" "$@" | sort -u)
else
  if [[ ! -f "$TARGETS_CSV" ]]; then
    echo "ERROR: targets.csv not found at: $TARGETS_CSV"
    exit 1
  fi
  mapfile -t PKGS < <(
    awk -F, 'NR>1 && $1!="" && $1!="TBD" && $1!="N/A" {print $1}' "$TARGETS_CSV" | sort -u
  )
fi

if [[ "${#PKGS[@]}" -eq 0 ]]; then
  echo "ERROR: no packages to pull."
  echo "Usage: $0 [package_id ...]   # no args = every package in targets.csv"
  exit 1
fi

for pkg in "${PKGS[@]}"; do
  echo "[adb] package: $pkg"

  # pm path returns one or more APK paths (base + splits)
  mapfile -t PATHS < <(adb shell pm path "$pkg" 2>/dev/null | sed 's/^package://')

  if [[ "${#PATHS[@]}" -eq 0 ]]; then
    echo "[adb] WARN: $pkg not installed (skipping)"
    continue
  fi

  DEST="$OUT_DIR/$pkg"
  mkdir -p "$DEST"

  for p in "${PATHS[@]}"; do
    base="$(basename "$p")"
    echo "  pulling: $p -> $DEST/$base"
    adb pull "$p" "$DEST/$base" >/dev/null
  done

  if command -v sha256sum >/dev/null 2>&1; then
    (cd "$DEST" && sha256sum ./* > SHA256SUMS.txt) || true
  fi
done

echo "[adb] done. Output dir: $OUT_DIR"
