#!/usr/bin/env python3
# Copyright 2026 Pigs Can Fly Labs LLC
# SPDX-License-Identifier: Apache-2.0
"""Structural checks on the vendored number registries.

These do NOT hit the network — they assert the invariants a consumer relies on,
because the consumer binary-searches the raw bytes. A file that is out of order,
or that has a key of the wrong width, silently returns wrong answers rather than
failing; that is exactly the kind of bug worth spending a test on.

Freshness against upstream is a separate, network-bound concern:
``python scripts/fetch_registries.py --check``.
"""
from __future__ import annotations

import re

import pytest

from fetch_registries import BUILDERS, MIN_ENTRIES, REGISTRY_DIR, _clean, _render

KEY_WIDTHS = {
    "ieee-oui.tsv": 6,
    "ieee-oui28.tsv": 7,
    "ieee-oui36.tsv": 9,
    "bluetooth-company-ids.tsv": 5,
    "bluetooth-service-uuids.tsv": 4,
}

IEEE_FILES = ("ieee-oui.tsv", "ieee-oui28.tsv", "ieee-oui36.tsv")


def _longest_prefix_lookup(address_hex: str) -> str | None:
    """The lookup a consumer is expected to perform: longest block first."""
    for name in sorted(IEEE_FILES, key=lambda n: -KEY_WIDTHS[n]):
        table = dict(line.split("\t", 1) for line in _lines(name))
        hit = table.get(address_hex[: KEY_WIDTHS[name]].upper())
        if hit:
            return hit
    return None


def _lines(name: str) -> list[str]:
    return (REGISTRY_DIR / name).read_text(encoding="utf-8").splitlines()


@pytest.mark.parametrize("name", sorted(KEY_WIDTHS))
def test_registry_exists_and_is_not_empty(name: str) -> None:
    assert (REGISTRY_DIR / name).exists(), f"{name} is missing; run fetch_registries.py"
    assert _lines(name), f"{name} is empty"


@pytest.mark.parametrize("name", sorted(KEY_WIDTHS))
def test_every_row_is_a_key_tab_value_pair(name: str) -> None:
    width = KEY_WIDTHS[name]
    for number, line in enumerate(_lines(name), start=1):
        key, tab, value = line.partition("\t")
        assert tab, f"{name}:{number}: no tab separator"
        assert len(key) == width, f"{name}:{number}: key {key!r} is not {width} chars"
        assert value, f"{name}:{number}: empty value"
        assert "\t" not in value, f"{name}:{number}: value contains a tab"


@pytest.mark.parametrize("name", sorted(KEY_WIDTHS))
def test_keys_are_sorted_and_unique(name: str) -> None:
    # Binary search over the raw bytes is only correct on a sorted file, and a
    # duplicate key makes the answer depend on where the search happens to land.
    keys = [line.split("\t", 1)[0] for line in _lines(name)]
    assert keys == sorted(keys), f"{name} is not sorted by key"
    assert len(keys) == len(set(keys)), f"{name} has duplicate keys"


@pytest.mark.parametrize("name", sorted(KEY_WIDTHS))
def test_file_ends_with_a_newline(name: str) -> None:
    # A consumer scanning for line boundaries would otherwise lose the last row.
    assert (REGISTRY_DIR / name).read_bytes().endswith(b"\n"), f"{name}: no trailing newline"


def test_company_id_keys_are_zero_padded_decimals() -> None:
    # Zero padding is what makes lexicographic order agree with numeric order.
    for line in _lines("bluetooth-company-ids.tsv"):
        key = line.split("\t", 1)[0]
        assert key.isdigit(), f"company id key {key!r} is not decimal"
        assert 0 <= int(key) <= 65535, f"company id {key} is out of range"


def test_oui_keys_are_uppercase_hex() -> None:
    for line in _lines("ieee-oui.tsv"):
        key = line.split("\t", 1)[0]
        assert key == key.upper(), f"OUI key {key!r} is not uppercase"
        int(key, 16)  # raises if not hex


def test_service_uuid_keys_are_lowercase_hex() -> None:
    for line in _lines("bluetooth-service-uuids.tsv"):
        key = line.split("\t", 1)[0]
        assert key == key.lower(), f"service UUID key {key!r} is not lowercase"
        int(key, 16)


@pytest.mark.parametrize("name", IEEE_FILES)
@pytest.mark.parametrize("placeholder", ["Private", "IEEE Registration Authority"])
def test_no_placeholder_organisations(name: str, placeholder: str) -> None:
    # Neither is an organisation. "Private" is a registrant who withheld their
    # name; "IEEE Registration Authority" marks a block that was subdivided,
    # and the real answer lives in one of the longer tables.
    values = {line.split("\t", 1)[1] for line in _lines(name)}
    assert placeholder not in values


def test_known_addresses_resolve_to_their_vendor() -> None:
    # Spot checks against addresses this repo's own specs document, so a mangled
    # regeneration is caught rather than merely a structurally valid one.
    assert "Philips" in _longest_prefix_lookup("001788AABBCC")   # hue-bridge BSB002
    assert "Signify" in _longest_prefix_lookup("C42996AABBCC")   # hue-bridge BSB003


def test_an_oui_names_the_chip_vendor_not_the_product_vendor() -> None:
    # The captured Lutron Caseta bridge advertises b8:94:d9:aa:bb:cc, and that
    # block belongs to Texas Instruments -- it is the bridge's radio module, not
    # Lutron. This is why lutron-caseta-smart-bridge.yaml deliberately carries no
    # mac_prefixes, and why an OUI can never identify a product.
    assert "Texas Instruments" in _longest_prefix_lookup("B894D9AABBCC")


def test_a_subdivided_block_resolves_to_the_real_vendor() -> None:
    # The case that justifies shipping three tables. C4:7C:8D is a subdivided
    # MA-L block, so a 24-bit-only lookup finds nothing usable -- but the Mi
    # Flora's own 28-bit block names the company that actually builds it.
    assert "HHCC" in _longest_prefix_lookup("C47C8D6A1B2C")

    ma_l = dict(line.split("\t", 1) for line in _lines("ieee-oui.tsv"))
    assert "C47C8D" not in ma_l, (
        "the subdivided parent block must not carry a placeholder name"
    )


def test_an_unassigned_address_resolves_to_nothing() -> None:
    # Better silence than a confident wrong answer.
    assert _longest_prefix_lookup("020000AABBCC") is None


def test_known_company_ids_resolve() -> None:
    table = dict(line.split("\t", 1) for line in _lines("bluetooth-company-ids.tsv"))
    assert "Ember" in table["00961"]        # ember-mug
    assert "Airthings" in table["00820"]    # airthings-wave-family


def test_render_collapses_duplicate_keys_keeping_the_first() -> None:
    assert _render([("b", "second"), ("a", "first"), ("b", "ignored")]) == (
        "a\tfirst\nb\tsecond\n"
    )


def test_clean_flattens_upstream_whitespace() -> None:
    # Upstream organisation names contain stray tabs and newlines; a tab would
    # corrupt the file format outright.
    assert _clean("  Acme\tCorp\n Ltd  ") == "Acme Corp Ltd"


def test_every_builder_has_a_sanity_floor() -> None:
    # The floors are what stop a silent upstream format change from overwriting
    # a good registry with an empty file. A builder added without one would be
    # unguarded, and the failure mode is invisible: the fetch prints "0 entries"
    # and exits 0.
    assert set(MIN_ENTRIES) == set(BUILDERS)
    for name, floor in MIN_ENTRIES.items():
        assert floor > 0, f"{name}: a floor of 0 guards nothing"


@pytest.mark.parametrize("filename", sorted(BUILDERS))
def test_committed_registry_clears_its_floor(filename: str) -> None:
    # The committed data must itself satisfy the floor the fetch enforces —
    # otherwise the guard is calibrated against nothing and the next refresh
    # either always fails or never fires.
    rows = len(_lines(REGISTRY_DIR / filename))
    assert rows >= MIN_ENTRIES[filename], (
        f"{filename}: {rows} committed rows is below the {MIN_ENTRIES[filename]} "
        "floor fetch_registries.py enforces"
    )


def test_committed_registries_use_lf_endings() -> None:
    # These files are binary-searched by byte offset; a CR before each newline
    # shifts every offset and puts a stray \r on the end of every value. The
    # fetch writes with newline="\n" for this reason, and splitlines() in the
    # helpers above would hide a regression.
    for filename in BUILDERS:
        raw = (REGISTRY_DIR / filename).read_bytes()
        assert b"\r" not in raw, f"{filename} contains CR bytes"


# ---------------------------------------------------------------------------
# shared-service-types.tsv -- hand-maintained, not fetched
# ---------------------------------------------------------------------------
#
# The mDNS types and SSDP targets that prove nothing on their own (every
# HomeKit accessory, every web server, every DLNA renderer). It is the Wi-Fi
# twin of "a SIG-assigned service UUID never identifies a BLE product", and it
# is a file rather than a list in consumer code so that a new ecosystem type is
# a registry refresh, not an app release. Different shape from the fetched
# tables (a header row, three columns), so it gets its own checks.

SHARED_SERVICE_TYPES = "shared-service-types.tsv"
SHARED_SERVICE_TYPES_HEADER = ["type", "kind", "reason"]
# One or more underscore-led labels before the protocol: the enumeration
# meta-type `_services._dns-sd._udp.local.` has two.
MDNS_TYPE = re.compile(r"^(_[A-Za-z0-9_-]+\.)+_(tcp|udp)\.local\.$")


def _shared_service_rows() -> list[tuple[str, str, str]]:
    lines = _lines(SHARED_SERVICE_TYPES)
    assert lines, f"{SHARED_SERVICE_TYPES} is empty"
    assert lines[0].split("\t") == SHARED_SERVICE_TYPES_HEADER, (
        f"{SHARED_SERVICE_TYPES}: first line must be the header "
        f"{chr(9).join(SHARED_SERVICE_TYPES_HEADER)!r}"
    )
    rows = []
    for number, line in enumerate(lines[1:], start=2):
        parts = line.split("\t")
        assert len(parts) == 3, (
            f"{SHARED_SERVICE_TYPES}:{number}: expected 3 tab-separated "
            f"columns, got {len(parts)}"
        )
        rows.append((parts[0], parts[1], parts[2]))
    return rows


def test_shared_service_types_parses_with_every_row_filled() -> None:
    for service_type, kind, reason in _shared_service_rows():
        assert service_type, "empty type"
        assert kind in {"mdns", "ssdp"}, f"{service_type}: kind {kind!r} is not mdns|ssdp"
        assert reason.strip(), f"{service_type}: a shared type needs a reason"


def test_shared_service_types_are_fully_qualified() -> None:
    # An mDNS type spelled `_http._tcp` never compares equal to a spec's
    # `_http._tcp.local.` -- the same silent miss the schema's pattern on
    # `identification.mdns_service_type` exists to prevent. SSDP targets are
    # the ST header as the wire carries it.
    for service_type, kind, _ in _shared_service_rows():
        if kind == "mdns":
            assert MDNS_TYPE.match(service_type), (
                f"{service_type!r} is not a fully qualified, trailing-dotted "
                "DNS-SD type (`_name._tcp.local.`)"
            )
        else:
            assert service_type in {"upnp:rootdevice", "ssdp:all"} or (
                service_type.startswith("urn:") and service_type.count(":") >= 4
            ), f"{service_type!r} is not a search target as an ST header spells it"


def test_shared_service_types_are_unique_and_sorted() -> None:
    rows = _shared_service_rows()
    keys = [(kind, service_type) for service_type, kind, _ in rows]
    assert len(keys) == len(set(keys)), "duplicate shared service type"
    assert keys == sorted(keys), "rows must be sorted by kind, then type"


def test_shared_service_types_carries_the_types_the_catalogue_leans_on() -> None:
    # The entries that exist because a spec got it wrong once: a Hisense set
    # is a MediaRenderer, an ESPHome node is an _http server, and neither may
    # promote a match by itself.
    types = {service_type for service_type, _, _ in _shared_service_rows()}
    assert "urn:schemas-upnp-org:device:MediaRenderer:1" in types
    assert "_http._tcp.local." in types
    assert "_hap._tcp.local." in types


def test_shared_service_types_ends_with_lf_newline() -> None:
    raw = (REGISTRY_DIR / SHARED_SERVICE_TYPES).read_bytes()
    assert raw.endswith(b"\n") and b"\r" not in raw


# ---------------------------------------------------------------------------
# dfu-signatures.tsv -- hand-maintained, not fetched
# ---------------------------------------------------------------------------
#
# The per-stack signatures of a firmware-update path: service and
# characteristic UUIDs and default bootloader names. A scanner uses it to
# recognise ANY device in its bootloader (an anonymous "DfuTarg"), and to keep
# update services out of product identification. The `mechanism` column is
# the schema's features[].dfu.mechanisms vocabulary, so the two cannot drift.

DFU_SIGNATURES = "dfu-signatures.tsv"
DFU_SIGNATURES_HEADER = ["signature", "kind", "mechanism", "meaning", "source"]
UUID128 = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")


def _dfu_rows() -> list[list[str]]:
    lines = _lines(DFU_SIGNATURES)
    assert lines and lines[0].split("\t") == DFU_SIGNATURES_HEADER, (
        f"{DFU_SIGNATURES}: first line must be the header"
    )
    rows = []
    for number, line in enumerate(lines[1:], start=2):
        parts = line.split("\t")
        assert len(parts) == 5, f"{DFU_SIGNATURES}:{number}: expected 5 columns"
        rows.append(parts)
    return rows


def _dfu_mechanisms() -> set[str]:
    import json

    schema_path = REGISTRY_DIR.parent / "device-specs" / "schema.json"
    schema = json.loads(schema_path.read_text(encoding="utf-8"))
    dfu = schema["properties"]["features"]["items"]["properties"]["dfu"]
    return set(dfu["properties"]["mechanisms"]["items"]["enum"])


def test_dfu_signatures_rows_are_well_formed() -> None:
    mechanisms = _dfu_mechanisms()
    for signature, kind, mechanism, meaning, source in _dfu_rows():
        assert kind in {"service_uuid", "characteristic_uuid", "local_name"}, (
            f"{signature}: kind {kind!r}"
        )
        if kind != "local_name":
            assert UUID128.match(signature), (
                f"{signature!r} is not a lowercase 128-bit UUID"
            )
        assert mechanism in mechanisms, (
            f"{signature}: mechanism {mechanism!r} is not in the schema's "
            "features[].dfu.mechanisms enum"
        )
        assert meaning.strip(), f"{signature}: needs a meaning"
        assert source.startswith("https://"), f"{signature}: needs a source URL"


def test_dfu_signatures_are_unique_and_sorted() -> None:
    keys = [(kind, signature) for signature, kind, *_ in _dfu_rows()]
    assert len(keys) == len(set(keys)), "duplicate DFU signature"
    assert keys == sorted(keys), "rows must be sorted by kind, then signature"
