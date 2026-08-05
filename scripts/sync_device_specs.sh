#!/usr/bin/env bash
# Copyright 2026 Pigs Can Fly Labs LLC
# SPDX-License-Identifier: Apache-2.0
#
# Vendor device specs from a liberatedbread-protocol-specs checkout into
# assets/device_specs/.
#
# The specs are authored in the protocol-specs repo and vendored here so the app
# ships a working catalogue offline. Adding or updating a device is then a
# data-only refresh: run this script, run the Rust tests, commit. No Dart edit is
# required, because the loader is manifest-driven (see manifest.json below).
#
# Usage:
#   ./scripts/sync_device_specs.sh [path-to-protocol-specs-checkout]
#
# Defaults to ../liberatedbread-protocol-specs.

set -euo pipefail

SRC="${1:-$(dirname "$0")/../../liberatedbread-protocol-specs}"
DEST="$(dirname "$0")/../assets/device_specs"

if [[ ! -d "$SRC/device-specs/devices" ]]; then
  echo "error: no device-specs/devices in '$SRC'" >&2
  echo "Pass the path to a liberatedbread-protocol-specs checkout." >&2
  exit 1
fi

mkdir -p "$DEST"

# Drop previously vendored specs so a device removed upstream doesn't linger
# here forever. manifest.json is rewritten below.
find "$DEST" -maxdepth 1 -name '*.yaml' -delete

# Both directories are vendored: `devices/` is the real catalogue, and
# `examples/` holds example-bulb.yaml, which mock mode and the widget tests
# depend on. The upstream index.json lists entries from both, so copying only
# devices/ would leave a manifest entry with no file behind it.
count=0
for spec in "$SRC"/device-specs/devices/*.yaml "$SRC"/device-specs/examples/*.yaml; do
  [[ -e "$spec" ]] || continue
  cp "$spec" "$DEST/"
  count=$((count + 1))
done

# The upstream index.json is the source of truth for the catalogue. It is copied
# to manifest.json because that is the name the Dart loader looks for, and the
# `path` fields are rewritten to bare filenames: upstream paths are relative to
# the specs repo root, but these files are flattened into a single asset folder.
python3 - "$SRC/device-specs/index.json" "$DEST/manifest.json" <<'PY'
import json
import sys

src, dest = sys.argv[1], sys.argv[2]

with open(src) as handle:
    entries = json.load(handle)

for entry in entries:
    path = entry.get("path", "")
    entry["file"] = path.rsplit("/", 1)[-1]

with open(dest, "w") as handle:
    json.dump(entries, handle, indent=2)
    handle.write("\n")

print(f"manifest: {len(entries)} devices")
PY

echo "vendored $count spec file(s) into $DEST"
echo "now run: (cd rust && cargo test)   # vendored_assets parses every spec"
