#!/usr/bin/env python3
# Copyright 2026 Pigs Can Fly Labs LLC
# SPDX-License-Identifier: Apache-2.0
"""Regenerate ``registries/`` from the published upstream number registries.

The registries answer one question the device specs cannot: *who made this
thing?*, for hardware that is not in the catalogue at all. A scanner sees an
anonymous BLE device with no name, no service UUID and no manufacturer data —
all it has is an address, and the first three octets of that address were
assigned to somebody. Saying "Espressif Inc." beats saying nothing.

Five files are produced, all sorted, tab-separated and newline-terminated so
a consumer can binary-search the raw bytes without parsing or allocating a map:

    registries/ieee-oui.tsv                 AABBCC     <tab> organisation
    registries/ieee-oui28.tsv               AABBCCD    <tab> organisation
    registries/ieee-oui36.tsv               AABBCCDEF  <tab> organisation
    registries/bluetooth-company-ids.tsv    <decimal>  <tab> company
    registries/bluetooth-service-uuids.tsv  <4 hex>    <tab> service name

The three IEEE tables must be consulted LONGEST FIRST. IEEE subdivides some
24-bit blocks into 28-bit (MA-M) and 36-bit (MA-S) assignments, and leaves the
parent 24-bit row pointing at itself. `C4:7C:8D` is the instructive case: MA-L
says only "IEEE Registration Authority", while MA-M says `C47C8D6` belongs to
HHCC Plant Technology — the company that actually makes the Mi Flora this repo
documents. A 24-bit-only lookup gets the useless answer for precisely the small
vendors worth naming, because a small vendor buys a small block.

None of this is our data and none of it is device knowledge — it is third-party
reference material, vendored so the app works offline and so a lookup cannot
quietly change under a released build. See registries/SOURCES.md for provenance
and licensing.

Network access is required; this is a maintenance script, not part of the build.

Usage:
    python scripts/fetch_registries.py            # rewrite the files
    python scripts/fetch_registries.py --check    # fail if they would change
"""
from __future__ import annotations

import argparse
import csv
import io
import json
import sys
import urllib.request
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
REGISTRY_DIR = REPO_ROOT / "registries"

# The three IEEE MAC address block registries, in the three sizes a vendor can
# buy. Kept in separate files rather than merged, so each stays fixed-width and
# binary-searchable; the consumer tries them longest-first.
IEEE_URLS = {
    # MA-L, 24-bit.
    "ieee-oui.tsv": ("https://standards-oui.ieee.org/oui/oui.csv", 6),
    # MA-M, 28-bit.
    "ieee-oui28.tsv": ("https://standards-oui.ieee.org/oui28/mam.csv", 7),
    # MA-S, 36-bit.
    "ieee-oui36.tsv": ("https://standards-oui.ieee.org/oui36/oui36.csv", 9),
}

# Organisation names that are not organisations. "Private" is a registrant who
# paid to withhold their name; the IEEE Registration Authority rows are
# placeholders standing in for a block that has been subdivided into MA-M/MA-S
# assignments. Shipping either would have the app announce a device as made by
# "Private" or by the standards body, both of which are worse than silence —
# and in the IEEE-RA case the real answer is in one of the longer tables.
NON_ORGANISATIONS = frozenset(
    {"Private", "IEEE Registration Authority"}
)

# Nordic's transcription of the Bluetooth SIG Assigned Numbers. Used rather
# than scraping the SIG's own YAML because it is already the citation in
# docs/protocols/standards-and-references.md, and because it is a stable,
# versioned, machine-readable snapshot of a document the SIG publishes as prose.
NORDIC_BASE = (
    "https://raw.githubusercontent.com/NordicSemiconductor/"
    "bluetooth-numbers-database/master/v1"
)
COMPANY_IDS_URL = f"{NORDIC_BASE}/company_ids.json"
SERVICE_UUIDS_URL = f"{NORDIC_BASE}/service_uuids.json"


# Both hosts reject urllib's default "Python-urllib/x.y" agent, and IEEE in
# particular rate-limits unidentified clients. Say who we are.
USER_AGENT = (
    "opengreeniot-protocol-docs/1.0 (+https://github.com/PigsCanFlyLabs/"
    "opengreeniot-protocol-docs) registry-sync"
)


def _fetch(url: str) -> bytes:
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(request, timeout=120) as response:  # noqa: S310
        return response.read()


def _render(rows: list[tuple[str, str]]) -> str:
    """Sorted, deduplicated, tab-separated text.

    Sorted because the consumer binary-searches it. Deduplicated on the key
    because a duplicate key would make which of the two answers you get depend
    on where the search happened to land.
    """
    seen: dict[str, str] = {}
    for key, value in rows:
        seen.setdefault(key, value)
    return "".join(f"{k}\t{seen[k]}\n" for k in sorted(seen))


def _clean(text: str) -> str:
    """Collapse whitespace. Upstream organisation names contain stray tabs,
    newlines and runs of spaces; a tab would corrupt the file format outright.
    """
    return " ".join(text.split()).strip()


def build_ieee(url: str, key_width: int) -> str:
    raw = _fetch(url).decode("utf-8", errors="replace")
    rows: list[tuple[str, str]] = []
    for record in csv.DictReader(io.StringIO(raw)):
        assignment = (record.get("Assignment") or "").strip().upper()
        organisation = _clean(record.get("Organization Name") or "")
        if (
            len(assignment) != key_width
            or not organisation
            or organisation in NON_ORGANISATIONS
        ):
            continue
        rows.append((assignment, organisation))
    return _render(rows)


def build_company_ids() -> str:
    entries = json.loads(_fetch(COMPANY_IDS_URL))
    rows = [
        (str(int(e["code"])), _clean(e["name"]))
        for e in entries
        if e.get("name") and e.get("code") is not None
    ]
    # Numeric keys in a text file that gets binary-searched must sort the way
    # the search compares them, so pad to a fixed width.
    return _render([(key.zfill(5), value) for key, value in rows])


def build_service_uuids() -> str:
    entries = json.loads(_fetch(SERVICE_UUIDS_URL))
    rows = []
    for entry in entries:
        uuid = (entry.get("uuid") or "").strip().lower()
        name = _clean(entry.get("name") or "")
        # Only the 16-bit SIG-allocated shorthand is useful here: a full 128-bit
        # vendor UUID is matched against the device specs, not this table.
        if len(uuid) == 4 and name:
            rows.append((uuid, name))
    return _render(rows)


BUILDERS = {
    **{
        filename: (lambda url=url, width=width: build_ieee(url, width))
        for filename, (url, width) in IEEE_URLS.items()
    },
    "bluetooth-company-ids.tsv": build_company_ids,
    "bluetooth-service-uuids.tsv": build_service_uuids,
}


# Sanity floors for the row counts above: far enough below today's real counts
# (39k / 6.4k / 7k / 4k / 75) that legitimate upstream churn never trips them,
# and far enough above zero to catch a format change that silently yields
# nothing. Only the magnitude matters.
MIN_ENTRIES = {
    "ieee-oui.tsv": 20000,
    "ieee-oui28.tsv": 3000,
    "ieee-oui36.tsv": 3000,
    "bluetooth-company-ids.tsv": 2000,
    "bluetooth-service-uuids.tsv": 40,
}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--check",
        action="store_true",
        help="Do not write; exit non-zero if any file would change.",
    )
    args = parser.parse_args()

    REGISTRY_DIR.mkdir(exist_ok=True)
    stale = []
    for filename, build in BUILDERS.items():
        path = REGISTRY_DIR / filename
        content = build()
        entries = content.count("\n")
        # A parse that produced nothing is the dangerous case, not the loud one:
        # the builders key off literal upstream column headers, so a renamed
        # column (or an HTML maintenance page served with a 200) makes every row
        # fail its width check, _render returns "", and this would cheerfully
        # overwrite a good registry with an empty file and exit 0. --check would
        # then report STALE and tell the operator to run exactly this command.
        if entries < MIN_ENTRIES[filename]:
            raise SystemExit(
                f"{filename}: upstream produced {entries} usable rows, expected "
                f"at least {MIN_ENTRIES[filename]}. Refusing to overwrite the "
                "vendored copy — the source format has probably changed."
            )
        if args.check:
            # newline="" so a CRLF file compares as the CRLF it is; universal
            # newlines would translate it back to LF and report OK. Spelled as
            # open().read() rather than Path.read_text(newline=...) because that
            # keyword only exists on 3.13+, and this project targets 3.12 — the
            # short spelling made --check die with a TypeError on every run.
            existing = None
            if path.exists():
                with open(path, encoding="utf-8", newline="") as handle:
                    existing = handle.read()
            if existing != content:
                stale.append(filename)
                print(f"STALE {filename} ({entries} entries upstream)")
            else:
                print(f"OK    {filename} ({entries} entries)")
            continue
        # newline="\n" explicitly: these files are binary-searched by byte
        # offset, and Python's default translation would write CRLF on Windows,
        # putting a stray \r on the end of every value.
        path.write_text(content, encoding="utf-8", newline="\n")
        print(f"wrote {filename} ({entries} entries, {len(content.encode())} bytes)")

    if stale:
        print(
            f"\n{len(stale)} registry file(s) differ from upstream. "
            "Run scripts/fetch_registries.py to refresh.",
            file=sys.stderr,
        )
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
