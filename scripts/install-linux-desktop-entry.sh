#!/usr/bin/env bash
# Copyright 2026 Pigs Can Fly Labs LLC
# SPDX-License-Identifier: Apache-2.0
#
# Liberated Bread Mobile — install a desktop entry for a built Linux bundle.
#
# WHY THIS EXISTS
#
# linux/my_application.cc sets the window icon directly, and under X11 (and
# XWayland) that is the whole story: _NET_WM_ICON is what the taskbar, the
# window list and alt-tab all read.
#
# A native Wayland session does not work that way. There are no per-window
# icons in the protocol: the compositor takes the surface's app_id, looks for a
# <app_id>.desktop file in the usual XDG directories, and draws the icon named
# in THAT. No entry, no icon — the window shows the generic placeholder in the
# alt-tab switcher no matter what the app itself sets. GNOME on Wayland is the
# default on Ubuntu, Fedora and Debian, which makes this the common case rather
# than the exotic one.
#
# So this script installs the missing half: a .desktop file whose name matches
# the app_id linux/main.cc sets (ca.pigscanfly.liberatedbread), plus the icons
# it names, into the per-user XDG directories under ~/.local/share. Nothing is
# written outside $HOME and nothing needs root.
#
# It is deliberately NOT run by scripts/run-linux.sh or by the build. Writing
# into a developer's desktop environment is not something a build should do
# behind their back, and the app is perfectly usable without it.
#
# Usage:
#   ./scripts/install-linux-desktop-entry.sh                  # newest bundle
#   ./scripts/install-linux-desktop-entry.sh <bundle-dir>     # a specific one
#   ./scripts/install-linux-desktop-entry.sh --uninstall
#
# The entry points at the bundle IN PLACE — it does not copy the app anywhere.
# Rebuilding in the same mode keeps working; `flutter clean`, or switching
# between debug and release, means re-running this against the new path.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Must match APPLICATION_ID in linux/CMakeLists.txt and the g_set_prgname() call
# in linux/main.cc. The .desktop file's BASENAME is what a Wayland compositor
# matches against the app_id, so this is not merely a label.
APP_ID="ca.pigscanfly.liberatedbread"
BINARY_NAME="liberated_bread_mobile"

# hicolor sizes, matching the PNGs tool/branding/generate_icons.mjs emits into
# linux/resources/ and CMake copies to data/resources/ in the bundle.
ICON_SIZES=(16 24 32 48 64 128 256)

DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
APPLICATIONS_DIR="$DATA_HOME/applications"
ICONS_DIR="$DATA_HOME/icons/hicolor"
DESKTOP_FILE="$APPLICATIONS_DIR/$APP_ID.desktop"

log()  { printf '\033[1;32m[desktop-entry]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[desktop-entry]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[desktop-entry]\033[0m %s\n' "$*" >&2; }

usage() {
  cat <<'EOF'
Usage: install-linux-desktop-entry.sh [<bundle-dir>] [--uninstall]

Installs a .desktop file and hicolor icons under ~/.local/share so a Wayland
compositor can find this app's icon (alt-tab, dock, window list). X11 sessions
already get the icon from the app itself and do not need this.

Arguments:
  <bundle-dir>   A built Linux bundle (build/linux/x64/<mode>/bundle).
                 Defaults to the most recently built one.

Options:
  --uninstall    Remove the entry and icons this script installed.
  -h, --help     Show this help.
EOF
}

UNINSTALL=false
BUNDLE=""

while (( $# > 0 )); do
  case "$1" in
    --uninstall) UNINSTALL=true; shift ;;
    -h|--help)   usage; exit 0 ;;
    -*)          err "Unknown option: $1"; usage >&2; exit 2 ;;
    *)
      if [[ -n "$BUNDLE" ]]; then
        err "Only one bundle path may be given."
        exit 2
      fi
      BUNDLE="$1"; shift ;;
  esac
done

# Renders a path as a Desktop Entry `Exec` value.
#
# WHY THIS IS NOT JUST THE PATH. Exec is a command line, not a filename: it is
# split on whitespace, so a bundle under "~/My Projects/..." installs an entry
# that tries to run ~/My with "Projects/..." as its first argument. Clicking it
# does nothing and says nothing, which is the failure mode this whole script
# exists to avoid. A repo path with a space is ordinary, not exotic.
#
# TWO LAYERS OF ESCAPING, applied in this order because a launcher undoes them
# in the opposite one:
#
#   1. The desktop-file "string" layer. The value is read by a key-file parser
#      that turns \\ into \, and \s \n \t \r into whitespace.
#   2. The Exec argument layer. What survives layer 1 is then parsed shell-like:
#      double-quoted arguments, inside which \" \` \$ \\ unescape.
#
# So a literal backslash in the path has to reach layer 2 as \\, which means
# writing \\\\ into the file. Same reasoning gives \\" for a quote.
#
# Reserved characters (space among them) are handled by quoting the whole value
# rather than escaping each one, which the spec allows and which keeps the
# common case readable in the installed file.
#
# A literal % is NOT escaped here, because it cannot be — see the guard below.
#
# https://specifications.freedesktop.org/desktop-entry-spec/latest/exec-variables.html
desktop_exec_escape() {
  local s="$1"
  s="${s//\\/\\\\\\\\}"   # \ -> \\\\   (must come first, or it re-escapes the below)
  s="${s//\"/\\\\\"}"     # " -> \\"
  s="${s//\`/\\\\\`}"     # ` -> \\`
  s="${s//\$/\\\\\$}"     # $ -> \\$
  printf '"%s"' "$s"
}

# Refreshes the desktop's caches. Both tools are optional — a session that has
# neither picks the change up on next login — so a missing one is not an error.
refresh_caches() {
  if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database "$APPLICATIONS_DIR" 2>/dev/null || true
  fi
  if command -v gtk-update-icon-cache >/dev/null 2>&1; then
    gtk-update-icon-cache -f -t "$ICONS_DIR" 2>/dev/null || true
  fi
}

# ── uninstall ────────────────────────────────────────────────────────────────

if [[ "$UNINSTALL" == "true" ]]; then
  removed=0
  if [[ -f "$DESKTOP_FILE" ]]; then
    rm -f "$DESKTOP_FILE"
    log "Removed $DESKTOP_FILE"
    removed=1
  fi
  for size in "${ICON_SIZES[@]}"; do
    icon="$ICONS_DIR/${size}x${size}/apps/$APP_ID.png"
    if [[ -f "$icon" ]]; then
      rm -f "$icon"
      removed=1
    fi
  done
  if (( removed == 0 )); then
    warn "Nothing to remove — no entry was installed for $APP_ID."
    exit 0
  fi
  refresh_caches
  log "Uninstalled. Log out and back in if the icon lingers in a running session."
  exit 0
fi

# ── locate the bundle ────────────────────────────────────────────────────────

if [[ -z "$BUNDLE" ]]; then
  # Newest first, so someone who just ran a release build gets the release
  # bundle without having to name it. Release is not preferred over debug on
  # principle: whichever was built last is the one being worked on.
  while IFS= read -r candidate; do
    BUNDLE="$candidate"
    break
  done < <(find "$PROJECT_DIR/build/linux" -maxdepth 3 -type d -name bundle \
             -printf '%T@ %p\n' 2>/dev/null | sort -rn | cut -d' ' -f2-)
fi

if [[ -z "$BUNDLE" ]]; then
  err "No built bundle found under build/linux/. Build one first:"
  err "  flutter build linux --release      (or ./scripts/run-linux.sh once)"
  exit 1
fi

BUNDLE="$(cd "$BUNDLE" && pwd)"
EXE="$BUNDLE/$BINARY_NAME"

if [[ ! -x "$EXE" ]]; then
  err "No executable at $EXE — that directory is not a finished Linux bundle."
  exit 1
fi

# A literal % in the path has no working spelling in an Exec value, so refuse
# rather than install something that fails silently. Both candidates were tried
# against GLib's own launcher (g_desktop_app_info_new_from_filename + launch):
#
#   %   the spec's field-code introducer, so "/one%20two/app" is read as %2
#       (an unknown code, dropped) and GIO tries to run "/one0two/app"
#   %%  the spec's escape for a literal %, but GLib's binary-existence check at
#       load time does NOT expand field codes, so it looks for a path that
#       still contains %% , fails to find it, and refuses the entry outright
#
# Every other awkward character round-trips fine through desktop_exec_escape —
# spaces, quotes, backslashes, $, backticks, semicolons, ampersands, parens —
# so this guard is deliberately narrow. Moving the bundle is a one-line fix and
# a loud refusal beats a desktop entry that does nothing when clicked.
case "$BUNDLE" in
  *%*)
    err "The bundle path contains a '%' character:"
    err "  $BUNDLE"
    err "A literal % cannot be represented in a .desktop Exec value — GIO either"
    err "reads it as a field code and mangles the path, or rejects the entry."
    err "Move or copy the bundle somewhere without a % and re-run, e.g.:"
    err "  cp -r \"$BUNDLE\" ~/liberated-bread-bundle"
    err "  $0 ~/liberated-bread-bundle"
    exit 1 ;;
esac

ICON_SRC_DIR="$BUNDLE/data/resources"
if [[ ! -d "$ICON_SRC_DIR" ]]; then
  err "No data/resources/ in the bundle — it predates the app icon, or the"
  err "resources install() in linux/CMakeLists.txt was dropped. Rebuild."
  exit 1
fi

# ── install ──────────────────────────────────────────────────────────────────

log "Bundle:  $BUNDLE"

installed_icons=0
for size in "${ICON_SIZES[@]}"; do
  src="$ICON_SRC_DIR/app_icon_${size}.png"
  if [[ ! -f "$src" ]]; then
    warn "Missing $src — skipping the ${size}px icon."
    continue
  fi
  dest_dir="$ICONS_DIR/${size}x${size}/apps"
  mkdir -p "$dest_dir"
  cp -f "$src" "$dest_dir/$APP_ID.png"
  installed_icons=$((installed_icons + 1))
done

if (( installed_icons == 0 )); then
  err "No icons were installed — $ICON_SRC_DIR has none of the expected files."
  exit 1
fi

log "Icons:   $installed_icons size(s) under $ICONS_DIR"

mkdir -p "$APPLICATIONS_DIR"

# StartupWMClass is the X11 half of the same matching problem: an X11 session
# ties a window to this entry by WM_CLASS, which GTK takes from the process
# name that linux/main.cc sets. Naming it here means a launcher shows one
# highlighted entry rather than a second anonymous window tile.
#
# Icon= is the icon NAME, not a path: the desktop resolves it through the
# hicolor theme the loop above just populated, and so picks the right size for
# each surface.
cat > "$DESKTOP_FILE" <<EOF
[Desktop Entry]
Type=Application
Name=Liberated Bread
GenericName=IoT Device Control
Comment=Discover and control local IoT devices without the vendor cloud
Exec=$(desktop_exec_escape "$EXE")
Icon=$APP_ID
Terminal=false
Categories=Utility;
StartupWMClass=$APP_ID
StartupNotify=true
EOF

log "Entry:   $DESKTOP_FILE"

# Non-fatal: the entry is already written and valid, and desktop-file-validate
# is not installed everywhere. It is worth running when present because a
# malformed entry is silently ignored by the desktop rather than reported.
if command -v desktop-file-validate >/dev/null 2>&1; then
  if desktop-file-validate "$DESKTOP_FILE"; then
    log "Validated with desktop-file-validate."
  else
    warn "desktop-file-validate reported problems with the entry above."
  fi
fi

refresh_caches

log "Done. Windows already open keep the icon they started with — restart the"
log "app to see it. Undo with: $0 --uninstall"
