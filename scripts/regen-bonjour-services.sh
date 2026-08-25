#!/usr/bin/env bash
# Rewrite ios/Runner/Info.plist's NSBonjourServices array from the mDNS service
# types the vendored catalogue names.
#
# WHY THIS IS GENERATED AND NOT HAND-WRITTEN
#
# iOS 14+ withholds mDNS answers for a service type not declared in
# NSBonjourServices, and it does it SILENTLY: no error, no log, the device
# simply never appears. The array was therefore a second copy of a fact the
# YAML already states, maintained by hand, updated only when somebody
# remembered — and the catalogue arrives by `git subtree pull`, so it drifted
# on every spec wave. The last one added five Wi-Fi specs and the array missed
# all five; a broader read of the same catalogue found ten more that had been
# missing for longer, including the two legacy printer types the scan already
# draws a printer glyph for.
#
# So it is derived. `update-specs.sh` runs this straight after a pull, which
# makes "a new Wi-Fi spec is discoverable on iOS" a property of vendoring the
# spec rather than of a reviewer noticing. Unlike index-temp.json this output IS
# committed: it is part of the iOS bundle, and the diff is the point — it shows
# which types a spec wave added.
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

# Regenerate the array in place. Expects PROJECT_DIR and a `log` function (both
# provided by the caller). No-op without python3. Set LB_BONJOUR=0 to skip.
regen_bonjour_services() {
  [[ "${LB_BONJOUR:-1}" == "0" ]] && return 0
  local project="${PROJECT_DIR:-$(pwd)}"
  local devices="$project/vendor/protocol-specs/device-specs/devices"
  local plist="$project/ios/Runner/Info.plist"
  [[ -d "$devices" && -f "$plist" ]] || return 0
  command -v python3 >/dev/null 2>&1 || return 0

  log "Rebuilding the iOS Bonjour service list from the vendored specs..."
  python3 - "$devices" "$plist" << 'PY'
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
    open(plist_path, 'w', encoding='utf-8').write(updated)
    print(f'  {len(wanted)} service types (updated)')
PY
}
