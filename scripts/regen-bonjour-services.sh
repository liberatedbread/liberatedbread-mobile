#!/usr/bin/env bash
# Rewrite ios/Runner/Info.plist's NSBonjourServices array from the mDNS service
# types the vendored catalogue names.
#
# WHAT THIS KEY ACTUALLY GOVERNS  (read this before trusting the array)
#
# NSBonjourServices constrains mDNS performed through the BONJOUR APIs —
# NWBrowser, the old NetService — where mDNSResponder does the query on the
# app's behalf and the OS filters answers by declared type.
#
# This app does not use those APIs. lib/services/real_network_scan_service.dart
# drives mDNS itself: `multicast_dns` binds UDP 5353 and joins 224.0.0.251 on a
# RawDatagramSocket, and the SSDP half sends its own M-SEARCH. Raw multicast is
# gated by the com.apple.developer.networking.multicast ENTITLEMENT, not by
# this key. ios/Runner/Runner.entitlements and
# test/platform/ios_entitlements_test.dart have always said so; the header here
# used to say the opposite, and claimed that vendoring a spec made it
# "discoverable on iOS" by virtue of landing in this array. It does not.
#
# The array is still generated and still committed, for two reasons worth
# keeping: it declares the app's intent accurately to App Review, and it is
# exactly what a move to NWBrowser would need already correct — which is the
# App-Store-friendlier path, since a Bonjour-API implementation needs no
# multicast entitlement at all. Deriving it from the catalogue means that if
# that move ever happens, the list is not fifteen spec waves out of date.
#
# WHY IT IS GENERATED AND NOT HAND-WRITTEN
#
# The array is a second copy of a fact the YAML already states. Maintained by
# hand it drifted on every `git subtree pull`: one spec wave added five Wi-Fi
# specs and the array missed all five, and a broader read found ten more that
# had been missing for longer. `update-specs.sh` runs this straight after a
# pull, and the committed diff is the point — it shows which types a wave
# added.
#
# WHAT COUNTS AS A TYPE
#
# Every `mdns_service_type:` and `service_type:` inside a spec's `device:`
# block — that is, the identification axis and each `discovery.methods[].mdns`
# entry, the two places a type is an instruction to go looking. Types in
# `evidence:` or `protocol_details:` are excluded on purpose: those are records
# of what a probe once saw and notes on superseded protocols (Caséta's
# deprecated `_lap._tcp`), not axes anything matches on. Asking iOS for
# permission to hear them would be asking on the strength of a footnote.
#
# `test/platform/ios_bonjour_catalogue_test.dart` re-derives the same set and
# fails the build if the array has drifted, so a plist edited by hand — or a
# vendor done without this step — does not get far.

# Runnable two ways, because both are documented and one of them silently did
# nothing: `update-specs.sh` SOURCES this file and calls the function, while
# the test's remediation line tells a human to run the script. Defining the
# function and stopping there made that second route exit 0 having changed
# nothing, leaving the plist untouched and the test still red — with the error
# message pointing at the command that had just "worked".
#
# Regenerate the array in place. Expects PROJECT_DIR and a `log` function when
# sourced; supplies both when run directly. No-op without python3. Set
# LB_BONJOUR=0 to skip.
regen_bonjour_services() {
  [[ "${LB_BONJOUR:-1}" == "0" ]] && return 0
  local project="${PROJECT_DIR:-$(pwd)}"
  local devices="$project/vendor/protocol-specs/device-specs/devices"
  local plist="$project/ios/Runner/Info.plist"
  [[ -d "$devices" && -f "$plist" ]] || return 0
  command -v python3 >/dev/null 2>&1 || return 0

  log "Rebuilding the iOS Bonjour service list from the vendored specs..."
  # `|| return 1` because neither caller runs under `set -e`: without it a
  # traceback from the heredoc scrolls past inside a `git subtree pull`, the
  # success trailer prints, the run exits 0 — and the plist is silently behind
  # the catalogue, which is the exact iOS invisibility this whole mechanism
  # exists to prevent.
  python3 - "$devices" "$plist" << 'PY' || return 1
import glob, os, re, sys

devices, plist_path = sys.argv[1], sys.argv[2]

# The `device:` block: the key at column 0 and everything indented under it.
DEVICE_BLOCK = re.compile(r'^device:\n(?:[ \t].*\n|\n)*', re.M)
# `mdns_service_type:` (the identification axis) and `service_type:` (each
# discovery method's mdns entry). Same value, two spellings, both operative.
SERVICE_TYPE = re.compile(
    r'''^\s*(?:mdns_)?service_type:\s*["']?([^"'\n#]+)''', re.M)

# Types the app browses that no device spec names, each here for a stated
# reason. This is the whole hand-maintained remainder.
APP_OWNED = {
    # The DNS-SD meta-query the scan enumerates unknown service types with
    # (`_serviceEnumerationQuery` in lib/services/real_network_scan_service.dart).
    '_services._dns-sd._udp',
    # Home Assistant is a server the app integrates with, not a catalogue
    # device, so no spec declares it.
    '_home-assistant._tcp',
}


def normalize(raw):
    """The form NSBonjourServices wants, and the form the matcher folds to.

    Mirrors `normalize_service_type` in rust/src/spec/types.rs: a mismatch
    in either direction is a device that never appears.
    """
    lower = raw.strip().rstrip('.').lower()
    return lower[:-len('.local')] if lower.endswith('.local') else lower


wanted = set(APP_OWNED)
for path in sorted(glob.glob(os.path.join(devices, '*.yaml'))):
    block = DEVICE_BLOCK.search(open(path, encoding='utf-8').read())
    if not block:
        continue
    for match in SERVICE_TYPE.finditer(block.group(0)):
        service_type = normalize(match.group(1))
        # A DNS-SD type starts with an underscore; anything else in these keys
        # is a UPnP URN (wemo, viera write one under the same name).
        if service_type.startswith('_'):
            wanted.add(service_type)

text = open(plist_path, encoding='utf-8').read()
anchor = '<key>NSBonjourServices</key>'
# Raise something a reader can act on. `str.index` raises a bare
# `ValueError: substring not found`, which says nothing about which file or
# which key — and this runs inside a subtree pull, where it has to compete
# with a screen of git output to be noticed at all.
if anchor not in text:
    raise SystemExit(
        f'{plist_path} has no {anchor} array. It is the iOS allow-list this '
        'script generates; if it was renamed or removed, this script and '
        'test/platform/ios_bonjour_catalogue_test.dart both need to follow.')
start = text.index(anchor)
open_at = text.index('<array>', start)
close_at = text.index('</array>', open_at)

# Match the file's tabs rather than assuming: the plist is tab-indented, and a
# space-indented array would be a diff on every line of an unrelated review.
indent = text[text.rindex('\n', 0, open_at) + 1:open_at]
body = ''.join(f'{indent}\t<string>{t}</string>\n' for t in sorted(wanted))
updated = f'{text[:open_at]}<array>\n{body}{indent}{text[close_at:]}'

if updated == text:
    print(f'  {len(wanted)} service types (unchanged)')
else:
    # Written whole, then moved into place. `open(path, 'w')` truncates first,
    # so an interrupt mid-write leaves a half-written Info.plist — and a
    # truncated bundle plist is an app that does not launch, which is a long
    # way to fall for a convenience script.
    temporary = plist_path + '.tmp'
    with open(temporary, 'w', encoding='utf-8') as handle:
        handle.write(updated)
    os.replace(temporary, plist_path)
    print(f'  {len(wanted)} service types (updated)')
PY
}

# Run directly: stand up what the sourcing caller would have provided, then do
# the work. `BASH_SOURCE[0] == $0` is false when sourced, so `update-specs.sh`
# still just gets the definition.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -uo pipefail
  PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  log() { printf '\033[1;32m[bonjour]\033[0m %s\n' "$*"; }
  regen_bonjour_services
fi
