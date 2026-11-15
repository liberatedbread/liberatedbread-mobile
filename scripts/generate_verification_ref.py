#!/usr/bin/env python3
# Copyright 2026 Pigs Can Fly Labs LLC
# SPDX-License-Identifier: Apache-2.0
"""Generate VERIFICATION_REFERENCE.md from the per-target research docs.

Reads every target .md file in targets/ (excluding TEMPLATE.md) plus
targets/targets.csv, then writes a comprehensive VERIFICATION_REFERENCE.md at
the repo root with:
  1. APK Source Index
  2. Reference URL Catalog
  3. Evidence Gap Analysis
  4. APK Acquisition Quick-Reference
  5. Protocol Maturity Heatmap
  6. App Family Clusters
  7. Targets with Missing APKs

The script lives in scripts/ but reads targets/ and writes
VERIFICATION_REFERENCE.md at the repo root (one level up), so all paths are
anchored to REPO_ROOT rather than the script directory.

Usage:
    python scripts/generate_verification_ref.py           # write the reference
    python scripts/generate_verification_ref.py --check   # verify freshness only

--check regenerates the report in memory and compares it to the committed file,
exiting non-zero if they differ, without writing anything. The volatile
``Generated:`` timestamp line is ignored in that comparison so a stale verdict
means the target docs actually drifted, not merely that the clock moved. See
the NOT REPRODUCIBLE note in the generated file: the "APK collected?" column
probes the gitignored workspace/ directory. When that directory is absent the
committed column values are carried forward rather than recomputed, so a regen
(or --check) on a workspace-less clone no longer downgrades rows another
machine verified — but only a machine with the workspace can truly refresh
them.
"""
from __future__ import annotations

import argparse
import csv
import re
import sys
from collections import defaultdict
from datetime import datetime
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
TARGETS_DIR = REPO_ROOT / "targets"
OUTPUT_PATH = REPO_ROOT / "VERIFICATION_REFERENCE.md"
APKEEP_DIR = REPO_ROOT / "workspace" / "apks" / "apkeep"

# Regex for valid Android package names: at least 2 dot-separated segments,
# each starting with a letter/underscore, containing alphanumeric/underscore.
# Use non-capturing groups so findall() returns the full match.
# The lookbehind keeps the match anchored to a token boundary: without it,
# "far-driver.com" (a vendor download domain in prose) yields the fragment
# "driver.com" as though it were a standalone package id.
ANDROID_PKG_RE = re.compile(
    r"(?<![a-zA-Z0-9_.-])[a-zA-Z_][a-zA-Z0-9_]*(?:\.[a-zA-Z_][a-zA-Z0-9_]*)+"
)

# A real package id starts with a reverse-domain TLD segment: 2-6 lowercase
# letters (com, org, io, de, ...). A fixed prefix allowlist was tried first and
# silently dropped `de.wgsoft.motoscan` — every ccTLD it had not thought of
# made the committed reference report a declared package id as unknown. The
# shape check still rejects what the allowlist was for: prose abbreviations
# ("e.g."), capitalised words, and vendor domains written forwards
# ("motoscan.de" — first segment too long to be a TLD).
VALID_TLD_SEGMENT_RE = re.compile(r"[a-z]{2,6}")


def is_valid_reverse_domain_pkg(text: str) -> bool:
    """Return True if text looks like a real reverse-domain package ID (not speculative text)."""
    first_segment, dot, _ = text.partition(".")
    return (
        bool(dot)
        and VALID_TLD_SEGMENT_RE.fullmatch(first_segment) is not None
        and len(text) >= 8
    )


def extract_valid_package_ids(text: str) -> list[str]:
    """Extract valid Android package names from a text string.
    Filters out version numbers, transport names, and other false positives.
    Uses findall with non-capturing groups to get full match strings.
    """
    raw_matches = ANDROID_PKG_RE.findall(text)
    seen: set[str] = set()
    result: list[str] = []
    for p in raw_matches:
        p_clean = p.strip().rstrip(",")
        if p_clean and p_clean not in seen:
            segments = p_clean.split(".")
            first_seg = segments[0]
            if not first_seg.isdigit() and len(p_clean) >= 5 and is_valid_reverse_domain_pkg(p_clean):
                seen.add(p_clean)
                result.append(p_clean)
    return result


def check_apk_on_disk(package_ids: list[str]) -> str | None:
    """Cross-reference workspace/apks/apkeep/ — return YES if an artifact exists for any pkg.

    apkeep filenames vary by source and version: a bare ``<pkg>.apk``, a split
    bundle ``<pkg>.apks``/``<pkg>.xapk``, or a version-bearing name such as
    ``<pkg>@1.2.3.apk`` or ``<pkg>_1.2.3.apks``. Match any of these, not just the
    two exact paths, or a populated workspace is wrongly reported as NO and that
    error propagates into the APK index and maturity-tier counts.
    """
    if not APKEEP_DIR.is_dir():
        return None  # can't check
    exts = (".apk", ".apks", ".xapk")
    on_disk = [f.name for f in APKEEP_DIR.iterdir() if f.is_file() and f.name.endswith(exts)]
    for pid in package_ids:
        if pid in ("TBD", "N/A"):
            continue
        for name in on_disk:
            stem = next((name[: -len(e)] for e in exts if name.endswith(e)), name)
            # Exact, or the package id followed by a version separator — but not
            # a longer package (com.foo must not match com.foobar).
            if stem == pid or stem.startswith((f"{pid}@", f"{pid}_", f"{pid}-")):
                return "YES"
    return "NO"


def parse_metadata_section(text: str) -> dict:
    """Extract key-value pairs from '## Target metadata' section.

    Returns:
      target_ids: list[str]
      package_ids: list[str]  — valid Android package names only
      device_class: str
      transport: str
      local_only_viability: str
    """
    meta: dict = {
        "target_ids": [],
        "package_ids": [],
        "device_class": "",
        "transport": "",
        "local_only_viability": "",
    }

    m = re.search(r"## Target metadata\s*\n(.*?)(?=\n## |\Z)", text, re.DOTALL)
    if not m:
        return meta
    block = m.group(1)

    # target_id — one or comma-separated values
    m_id = re.search(r"-\s*target_id\s*:\s*(.+)", block, re.IGNORECASE)
    if m_id:
        raw = m_id.group(1).strip()
        meta["target_ids"] = [t.strip() for t in raw.split(",") if t.strip()]

    # ── package_id(s) parsing ────────────────────────────────────────
    # Find the package_id(s) line and collect all subsequent sub-bullets until
    # the next top-level metadata field (a line that starts with "- " at column 0
    # and has a word followed by colon — but NOT a sub-bullet continuation).

    lines = block.split("\n")
    pkg_content_lines: list[str] = []
    in_pkg_section = False

    for line in lines:
        stripped = line.strip()

        # Detect top-level metadata headers: lines starting with "- " at col 0
        # followed by a field name (allowing multi-word like "device class" and
        # parens like "package_id(s)") then ":".
        is_field_header = bool(re.match(r"-\s+.+?:", line))

        if not in_pkg_section:
            # Check if this line contains any package_id(s) label. Both the
            # plural ``package_id(s):`` and the singular ``package_id:`` are in
            # use across targets (astral-hoops, aurora-led-shoes, banlanx-sp6xxe,
            # hello-fairy, …), each optionally prefixed with ``app`` /
            # ``controlling app``, so the ``(s)`` is optional.
            pkg_match = re.match(
                r"-\s*(?:(?:controlling\s+)?app\s+)?package_id(?:\(s\))?\s*:\s*(.*)",
                stripped, re.IGNORECASE
            )
            if pkg_match:
                in_pkg_section = True
                val = pkg_match.group(1).strip()
                if val:
                    pkg_content_lines.append(val)
                continue
        else:
            # We are collecting package_id content
            # Stop at the next top-level metadata field (non-empty, starts with "- " at col 0)
            # But NOT a sub-bullet (which is indented)
            if is_field_header and line[0] == "-":
                # Only break if this field name is NOT a continuation of sub-bullets
                # Sub-bullets have preceding whitespace; we checked line[0] == "-"
                break
            # Collect any non-empty content
            if stripped:
                pkg_content_lines.append(stripped)

    # Now process the collected content
    if pkg_content_lines:
        full_text = " ".join(pkg_content_lines)

        # Check for TBD marker at start of the FIRST content line
        first_val = pkg_content_lines[0] if pkg_content_lines else ""
        if re.match(r"^\s*TBD\b", first_val, re.IGNORECASE):
            meta["package_ids"] = ["TBD"]
        elif first_val.strip() == "N/A":
            meta["package_ids"] = ["N/A"]
        else:
            # Single-line with parenthetical notes (e.g. frigidaire):
            # "com.electrolux.oneapp.android.frigidaire (verified ... older guessed IDs ...)"
            # Strip the parenthetical so only the first/active package_id is kept.
            if len(pkg_content_lines) == 1 and "(" in first_val:
                concise = first_val.split("(")[0].strip().rstrip(",")
                ids = extract_valid_package_ids(concise)
            else:
                # Multi-sub-bullet case: scan all lines for valid package names
                ids = extract_valid_package_ids(full_text)

            if ids:
                meta["package_ids"] = ids
            elif "N/A" in first_val or "no companion app" in first_val.lower():
                meta["package_ids"] = ["N/A"]
            elif "TBD" in first_val:
                meta["package_ids"] = ["TBD"]

    # device class
    m_dc = re.search(r"-\s*device\s+class\s*:\s*(.+)", block, re.IGNORECASE)
    if m_dc:
        meta["device_class"] = m_dc.group(1).strip()

    # transport
    m_tr = re.search(r"-\s*transport\(s\)\s*:\s*(.+)", block, re.IGNORECASE)
    if m_tr:
        meta["transport"] = m_tr.group(1).strip()

    # local-only viability
    m_lo = re.search(r"-\s*local-only\s+viability\s*:\s*(.+)", block, re.IGNORECASE)
    if m_lo:
        meta["local_only_viability"] = m_lo.group(1).strip()

    return meta


def extract_apk_method(text: str) -> str:
    """Look in 'First experiments' section for APK acquisition method keywords."""
    m = re.search(r"## First experiments\s*\n(.*?)(?=\n## |\Z)", text, re.DOTALL)
    if not m:
        return "?"
    block = m.group(1).lower()

    # Check for "N/A" or "not required" patterns first (they take priority)
    if re.search(r"not (?:required|needed)", block):
        if re.search(r"protocol\s+documented|no\s+reverse|documented\s+by|fully\s+documented", block):
            return "N/A (protocol documented)"
        return "N/A"

    if re.search(r"no companion app|no apk to", block):
        return "N/A (no companion app)"

    # Build list of clues
    clues = []
    if "apkeep" in block:
        clues.append("apkeep")
    if "adb pull" in block or "pull_apks_adb" in block:
        clues.append("ADB pull")
    if "adb install" in block:
        clues.append("ADB")

    # Check if it says "identify" or "scan for" the app (package unknown)
    if re.search(r"identify\s+actual|scan\s+play\s+store|package\s+id\s+not", block):
        clues.append("TBD (package unknown)")

    if clues:
        return " + ".join(clues)

    return "apkeep (assumed)"


def extract_apk_collected(text: str, package_ids: list[str]) -> str:
    """Determine if APK has been collected.

    Priority:
    1. Filesystem check: if .apk/.xapk exists in apkeep dir → YES
    2. Evidence checklist: if [x] with APK-related content → YES
    3. Fallback: filesystem check again → NO if not found, ? if can't check
    """
    # Filesystem check first — most reliable
    disk_result = check_apk_on_disk(package_ids)
    if disk_result == "YES":
        return "YES"

    m = re.search(r"## Evidence checklist\s*\n(.*?)(?=\n## |\Z)", text, re.DOTALL)
    if not m:
        return disk_result if disk_result else "?"
    block = m.group(1)

    # If the checklist just says "TBD" for APK
    if re.search(r"APK.*?:?\s*TBD", block, re.IGNORECASE):
        if not re.search(r"\[x\]", block, re.IGNORECASE):
            return "NO"

    # Look for [x] anywhere in block with APK-related content nearby
    if re.search(r"\[x\]", block, re.IGNORECASE):
        # Check if there's any APK-related text
        if re.search(r"(?:APK|apk|package|hash|version\s*code|decompil|jadx|apktool|acquired|fetched)", block, re.IGNORECASE):
            return "YES"
        # If there are [x] items but none mention APK, APK might not be listed
        if re.search(r"(?:APK|apk|hash)", block, re.IGNORECASE):
            return "NO"

    # Specific check for APK-related [x] lines
    if re.search(r"\[x\]\s*.*?(?:APK|acquired|fetched|version)", block, re.IGNORECASE):
        return "YES"

    # Filesystem fallback
    return disk_result if disk_result else "?"


def extract_hci_exists(text: str) -> str:
    """Check Evidence checklist for HCI snoop log status."""
    m = re.search(r"## Evidence checklist\s*\n(.*?)(?=\n## |\Z)", text, re.DOTALL)
    if not m:
        return "?"
    block = m.group(1)
    if re.search(r"\[x\]\s*.*?HCI", block, re.IGNORECASE):
        return "YES"
    if re.search(r"\[ \]\s*.*?HCI", block, re.IGNORECASE):
        return "NO"
    return "?"


def extract_pcap_exists(text: str) -> str:
    """Check Evidence checklist for PCAP/network capture status."""
    m = re.search(r"## Evidence checklist\s*\n(.*?)(?=\n## |\Z)", text, re.DOTALL)
    if not m:
        return "?"
    block = m.group(1)
    if re.search(r"\[x\]\s*.*?(?:PCAP|network.capture|mitmproxy|Wireshark)", block, re.IGNORECASE):
        return "YES"
    if re.search(r"\[ \]\s*.*?(?:PCAP|network.capture|mitmproxy|Wireshark)", block, re.IGNORECASE):
        return "NO"
    return "?"


def extract_reference_urls(text: str) -> list[str]:
    """Extract all URLs from 'References (URLs only)' or 'References' section."""
    m = re.search(r"## References\s*(?:\(URLs only\))?\s*\n(.*?)(?=\n## |\Z)", text, re.DOTALL)
    if not m:
        return []
    block = m.group(1)
    urls = re.findall(r"https?://[^\s\)\|]+", block)
    cleaned: list[str] = []
    for u in urls:
        u = u.rstrip(".,;:)'\"")
        if u not in cleaned:
            cleaned.append(u)
    return cleaned


def count_occurrences(text: str, word: str) -> int:
    """Count occurrences of a word (case-insensitive whole word)."""
    return len(re.findall(rf"(?<![a-zA-Z])(?:{re.escape(word)})(?![a-zA-Z])", text, re.IGNORECASE))


def extract_evidence_stats(text: str) -> tuple[int, int]:
    """Return (checked_count, unchecked_count) from Evidence checklist."""
    m = re.search(r"## Evidence checklist\s*\n(.*?)(?=\n## |\Z)", text, re.DOTALL)
    if not m:
        return (0, 0)
    block = m.group(1)
    checked = len(re.findall(r"\[x\]", block, re.IGNORECASE))
    unchecked = len(re.findall(r"\[ \]", block))
    return (checked, unchecked)


def read_csv_data(csv_path: Path) -> dict[str, list[dict]]:
    """Read targets.csv and return dict mapping target_id -> list of row dicts."""
    data: dict[str, list[dict]] = defaultdict(list)
    with open(csv_path, newline="", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        for row in reader:
            tid = row.get("target_id", "").strip()
            if tid:
                data[tid].append(row)
    return dict(data)


def determine_group(apk_collected: str, hci: str, pcap: str, verified_count: int) -> str:
    """Classify into COMPLETE, PARTIAL, EARLY, or STUB."""
    has_apk = apk_collected == "YES"
    has_hci_or_pcap = hci == "YES" or pcap == "YES"
    has_spec_evidence = verified_count >= 3

    if has_apk and has_hci_or_pcap and has_spec_evidence:
        return "COMPLETE"
    elif has_apk:
        return "PARTIAL"
    elif has_hci_or_pcap or has_spec_evidence:
        return "EARLY"
    else:
        return "STUB"


def fmt_pkg(ids: list[str]) -> str:
    """Format package_id list for display."""
    if not ids:
        return "?"
    if len(ids) == 1:
        return ids[0]
    return ", ".join(ids)


# ── Summary stats helpers ────────────────────────────────────────────

def compute_transport_counts(records: list[dict]) -> dict[str, int]:
    """Count targets by transport category."""
    counts: dict[str, int] = defaultdict(int)
    for rec in records:
        t = rec["transport"].strip().lower() if rec["transport"] else "unknown"
        # Collapse similar transports. OBD is checked first: vehicle targets are reached
        # through a Bluetooth dongle, so they would otherwise land in BLE / Bluetooth.
        # \bcan\b catches a bare "CAN, 500 kbit/s" (bosch-ebike) as well as
        # "CAN bus" without matching the letters inside "scan" or "American".
        if "obd" in t or "iso 15765" in t or re.search(r"\bcan\b", t):
            key = "OBD-II / CAN"
        elif "ble" in t and "wi-fi" in t:
            key = "BLE + Wi-Fi"
        elif "ble" in t or "bluetooth" in t:
            key = "BLE / Bluetooth"
        elif "wi-fi" in t or "wifi" in t or "lan" in t:
            key = "Wi-Fi / LAN"
        elif "bluetooth classic" in t or "bt" in t:
            key = "Bluetooth Classic"
        else:
            # An uncategorised transport is keyed by its first clause — a raw
            # 30-char truncation committed labels like "uart (9600 baud ttl,
            # 6-pin ton" to the reference. Short leading tokens are acronyms
            # (UART, SPI, I2C); longer ones are words.
            key = re.split(r"[,(]", t, maxsplit=1)[0].strip()
            if not key:
                key = "Unknown"
            elif len(key) <= 4:
                key = key.upper()
            else:
                key = key.capitalize()
        counts[key] += 1
    return dict(counts)


def compute_maturity_counts(records: list[dict]) -> dict[str, int]:
    """Count targets by maturity group."""
    groups: dict[str, list[dict]] = {"COMPLETE": [], "PARTIAL": [], "EARLY": [], "STUB": []}
    for rec in records:
        groups[rec["group"]].append(rec)
    return {k: len(v) for k, v in groups.items()}


# ── record collection ─────────────────────────────────────────────────────

def read_previous_apk_collected(path: Path | None = None) -> dict[str, str]:
    """Map target_id -> the "APK collected?" cell of the committed reference.

    The disk probe behind that column reads the gitignored ``workspace/``
    directory, so a clone without it cannot recompute the column. Regenerating
    there must not silently downgrade rows another machine verified against
    its workspace — the committed values are the only record of those probes,
    so they are read back here and carried forward (see the NOT REPRODUCIBLE
    note in the generated file).
    """
    if path is None:
        path = OUTPUT_PATH
    if not path.exists():
        return {}
    text = path.read_text(encoding="utf-8")
    m = re.search(r"## 1\. APK Source Index\s*\n(.*?)(?=\n## |\Z)", text, re.DOTALL)
    if not m:
        return {}
    previous: dict[str, str] = {}
    for line in m.group(1).splitlines():
        if not line.startswith("|"):
            continue
        cells = [c.strip() for c in line.split("|")]
        # cells[0] is the empty string before the leading pipe; the header row
        # and the |---| separator row are not data.
        if len(cells) < 6 or cells[1] in ("", "target_id") or set(cells[1]) <= {"-"}:
            continue
        previous[cells[1]] = cells[4]
    return previous


def collect_records() -> tuple[list[dict], dict[str, list[dict]]]:
    """Scan every target doc + targets.csv, touching no output files.

    Returns ``(doc_records, csv_data)``. Splitting this from rendering lets
    ``--check`` build the report in memory without writing anything.
    """
    md_files = sorted([
        f for f in TARGETS_DIR.iterdir()
        if f.suffix == ".md" and f.name not in ("TEMPLATE.md",)
    ])

    csv_path = TARGETS_DIR / "targets.csv"
    csv_data = read_csv_data(csv_path)

    # Without workspace/ the disk probe returns None for every target; fall
    # back on what the committed reference already says rather than
    # downgrading disk-verified rows (empty when the workspace IS present —
    # then the live probe governs).
    previous_collected: dict[str, str] = {}
    if not APKEEP_DIR.is_dir():
        previous_collected = read_previous_apk_collected()

    doc_records: list[dict] = []

    for mdf in md_files:
        text = mdf.read_text(encoding="utf-8")
        meta = parse_metadata_section(text)
        primary_id = meta["target_ids"][0] if meta["target_ids"] else mdf.stem

        if not meta["target_ids"]:
            meta["target_ids"] = [primary_id]

        package_ids = meta["package_ids"]
        apk_method = extract_apk_method(text)
        apk_collected = extract_apk_collected(text, package_ids)
        prev_collected = previous_collected.get(primary_id)
        if prev_collected == "YES":
            # A committed YES came from a machine that had the artifact on
            # disk; with workspace/ absent nothing here can re-prove OR refute
            # it, so it stands.
            apk_collected = "YES"
        elif apk_collected == "?" and prev_collected:
            apk_collected = prev_collected
        hci_exists = extract_hci_exists(text)
        pcap_exists = extract_pcap_exists(text)
        urls = extract_reference_urls(text)
        verified_count = count_occurrences(text, "VERIFIED")
        tbd_count = count_occurrences(text, "TBD")
        checked, unchecked = extract_evidence_stats(text)
        device_class = meta["device_class"]
        transport = meta["transport"]
        local_only = meta["local_only_viability"]

        # Cross-reference CSV
        csv_notes_parts: list[str] = []
        csv_rating_parts: list[str] = []
        for tid in meta["target_ids"]:
            if tid in csv_data:
                for row in csv_data[tid]:
                    n = row.get("notes", "").strip()
                    r = row.get("rating", "").strip()
                    if n and n not in csv_notes_parts:
                        csv_notes_parts.append(n)
                    if r and r not in csv_rating_parts:
                        csv_rating_parts.append(r)

        csv_notes = "; ".join(csv_notes_parts).strip("; ,")
        csv_rating = ", ".join(csv_rating_parts).strip(" ,")

        # Group determination
        group = determine_group(apk_collected, hci_exists, pcap_exists, verified_count)

        rec = {
            "primary_id": primary_id,
            "target_ids": meta["target_ids"],
            "package_ids": package_ids,
            "device_class": device_class,
            "transport": transport,
            "local_only": local_only,
            "apk_method": apk_method,
            "apk_collected": apk_collected,
            "hci_exists": hci_exists,
            "pcap_exists": pcap_exists,
            "urls": urls,
            "verified_count": verified_count,
            "tbd_count": tbd_count,
            "evidence_checked": checked,
            "evidence_unchecked": unchecked,
            "csv_notes": csv_notes,
            "csv_rating": csv_rating,
            "group": group,
            "filename": mdf.name,
        }
        doc_records.append(rec)

    return doc_records, csv_data


# ── rendering ──────────────────────────────────────────────────────────────

def render_report(
    doc_records: list[dict],
    csv_data: dict[str, list[dict]],
    generated_at: str,
) -> str:
    """Build the full VERIFICATION_REFERENCE.md text and return it.

    Pure function of the scanned records — writes nothing — so ``--check`` can
    compare its output against the committed file.
    """
    # ── Compute summary stats ────────────────────────────────────────
    total_targets = len(doc_records)
    transport_counts = compute_transport_counts(doc_records)
    maturity_counts = compute_maturity_counts(doc_records)

    # All unique URLs across targets
    all_urls: set[str] = set()
    for rec in doc_records:
        for url in rec["urls"]:
            all_urls.add(url)

    # ── Build output ──────────────────────────────────────────────────

    lines: list[str] = []
    lines.append("# VERIFICATION REFERENCE")
    lines.append("")
    lines.append("Auto-generated by `scripts/generate_verification_ref.py` — do not edit manually.")
    lines.append("")
    # A reader has no way to tell which rows reflect evidence and which
    # reflect one working copy's download cache, so say so here.
    lines.append(
        "> **NOT REPRODUCIBLE**: the \"APK collected?\" column probes the "
        "gitignored `workspace/` directory. Where that directory is absent "
        "the generator carries the previously committed value forward "
        "instead of downgrading it, but only a machine with the workspace "
        "can genuinely refresh the column — it cannot be CI-checked the way "
        "`device-specs/index.json` is. Tracked in issue #18."
    )
    lines.append("")
    lines.append(f"Generated: {generated_at}")
    lines.append("")
    lines.append("## Summary")
    lines.append("")
    lines.append(f"- **Total targets scanned:** {total_targets}")
    lines.append(f"- **Unique reference URLs discovered:** {len(all_urls)}")
    lines.append("")

    # Transport breakdown
    lines.append("### By Transport")
    lines.append("")
    lines.append("| Transport | Count |")
    lines.append("|---|---|")
    for ttype in sorted(transport_counts):
        lines.append(f"| {ttype} | {transport_counts[ttype]} |")
    lines.append("")

    # Maturity tier breakdown
    lines.append("### By Maturity Tier")
    lines.append("")
    lines.append("| Tier | Count |")
    lines.append("|---|---|")
    for tier in ("COMPLETE", "PARTIAL", "EARLY", "STUB"):
        lines.append(f"| {tier} | {maturity_counts.get(tier, 0)} |")
    lines.append("")

    lines.append("---")
    lines.append("")

    # ══════════════════════════════════════════════════════════════════
    # 1. APK Source Index
    # ══════════════════════════════════════════════════════════════════
    lines.append("## 1. APK Source Index")
    lines.append("")
    lines.append("| target_id | package_id(s) | APK method | APK collected? | CSV notes |")
    lines.append("|---|---|---|---|---|")
    for rec in doc_records:
        pkg_str = fmt_pkg(rec["package_ids"])
        note = rec["csv_notes"] or "—"
        lines.append(
            f"| {rec['primary_id']} | {pkg_str} | {rec['apk_method']} | {rec['apk_collected']} | {note} |"
        )
    lines.append("")

    # ══════════════════════════════════════════════════════════════════
    # 2. Reference URL Catalog
    # ══════════════════════════════════════════════════════════════════
    lines.append("## 2. Reference URL Catalog")
    lines.append("")

    # Collect all URLs with their source targets
    url_sources: list[tuple[str, str]] = []
    for rec in doc_records:
        for url in rec["urls"]:
            url_sources.append((url, rec["primary_id"]))

    # Deduplicate by URL, keep list of referencing targets
    url_refs: dict[str, set[str]] = defaultdict(set)
    for url, tid in url_sources:
        url_refs[url].add(tid)

    github_urls = {u: refs for u, refs in url_refs.items() if "github.com" in u}
    other_urls = {u: refs for u, refs in url_refs.items() if "github.com" not in u}

    lines.append(f"**Total unique URLs:** {len(url_refs)} ({len(github_urls)} GitHub, {len(other_urls)} other)")
    lines.append("")

    lines.append("### GitHub")
    lines.append("")
    lines.append("| URL | Referenced by |")
    lines.append("|---|---|")
    for url in sorted(github_urls):
        refs = ", ".join(sorted(github_urls[url]))
        lines.append(f"| {url} | {refs} |")
    lines.append("")

    lines.append("### Non-GitHub")
    lines.append("")
    lines.append("| URL | Referenced by |")
    lines.append("|---|---|")
    for url in sorted(other_urls):
        refs = ", ".join(sorted(other_urls[url]))
        lines.append(f"| {url} | {refs} |")
    lines.append("")

    # ══════════════════════════════════════════════════════════════════
    # 3. Evidence Gap Analysis
    # ══════════════════════════════════════════════════════════════════
    lines.append("## 3. Evidence Gap Analysis")
    lines.append("")
    groups: dict[str, list[dict]] = {"COMPLETE": [], "PARTIAL": [], "EARLY": [], "STUB": []}
    for rec in doc_records:
        groups[rec["group"]].append(rec)

    for gname in ("COMPLETE", "PARTIAL", "EARLY", "STUB"):
        items = groups[gname]
        lines.append(f"### {gname} ({len(items)})")
        lines.append("")
        if not items:
            lines.append("*None*")
            lines.append("")
            continue
        lines.append("| target_id | APK | HCI | PCAP | transport | device class |")
        lines.append("|---|---|---|---|---|---|")
        for rec in items:
            lines.append(
                f"| {rec['primary_id']} | {rec['apk_collected']} | {rec['hci_exists']} | {rec['pcap_exists']} | {rec['transport']} | {rec['device_class']} |"
            )
        lines.append("")

    # ══════════════════════════════════════════════════════════════════
    # 4. APK Acquisition Quick-Reference
    # ══════════════════════════════════════════════════════════════════
    lines.append("## 4. APK Acquisition Quick-Reference")
    lines.append("")
    lines.append("```bash")
    lines.append("# apkeep / ADB commands for each known package_id")
    lines.append("")

    # Collect unique package->target mappings (only valid reverse-domain names)
    pkg_cmd_map: dict[str, str] = {}
    for rec in doc_records:
        for pid in rec["package_ids"]:
            if pid and is_valid_reverse_domain_pkg(pid) and pid not in ("TBD", "N/A"):
                method = rec["apk_method"]
                if "ADB" in method:
                    cmd = f"pull_apks_adb.sh {pid}  # or: adb shell pm path {pid} && adb pull"
                else:
                    cmd = f"apkeep -a {pid}"
                if pid not in pkg_cmd_map:
                    pkg_cmd_map[pid] = cmd

    for pid in sorted(pkg_cmd_map):
        # Find which target(s) this belongs to
        targets_for_pkg = [r["primary_id"] for r in doc_records if pid in r["package_ids"]]
        target_tag = ", ".join(sorted(set(targets_for_pkg)))
        lines.append(f"# {target_tag}")
        lines.append(pkg_cmd_map[pid])
    lines.append("```")
    lines.append("")

    # Shared package_id targets (multi-target app families)
    pkg_to_targets: dict[str, list[str]] = defaultdict(list)
    for rec in doc_records:
        for pid in rec["package_ids"]:
            if pid and pid not in ("TBD", "N/A"):
                pkg_to_targets[pid].append(rec["primary_id"])
    shared = {p: t for p, t in sorted(pkg_to_targets.items()) if len(t) > 1}
    if shared:
        lines.append("**Shared package_ids (one app covers multiple targets):**")
        lines.append("")
        for pkg, targets in shared.items():
            lines.append(f"- `{pkg}` → {', '.join(sorted(set(targets)))}")
        lines.append("")

    # ══════════════════════════════════════════════════════════════════
    # 5. Protocol Maturity Heatmap
    # ══════════════════════════════════════════════════════════════════
    lines.append("## 5. Protocol Maturity Heatmap")
    lines.append("")
    lines.append("| target_id | transport | VERIFIED count | TBD count | Rating | Refs count |")
    lines.append("|---|---|---|---|---|---|")
    sorted_recs = sorted(doc_records, key=lambda r: (-r["verified_count"], r["tbd_count"]))
    for rec in sorted_recs:
        rating = rec["csv_rating"] or "—"
        refs_count = len(rec["urls"])
        lines.append(
            f"| {rec['primary_id']} | {rec['transport']} | {rec['verified_count']} | {rec['tbd_count']} | {rating} | {refs_count} |"
        )
    lines.append("")

    # ══════════════════════════════════════════════════════════════════
    # 6. App Family Clusters
    # ══════════════════════════════════════════════════════════════════
    lines.append("## 6. App Family Clusters")
    lines.append("")
    lines.append("Targets that share a package_id form an app family. These share a companion app and likely a common protocol (or at least overlapping transport/device class).")
    lines.append("")

    # Real shared package IDs (from the target docs)
    if shared:
        for pkg, targets in sorted(shared.items()):
            recs = [r for r in doc_records if r["primary_id"] in targets]
            classes = "; ".join(sorted(set(r["device_class"] for r in recs if r["device_class"])))
            transports = "; ".join(sorted(set(r["transport"] for r in recs if r["transport"])))
            lines.append(f"- **`{pkg}`** ({len(targets)} targets): {', '.join(sorted(set(targets)))}")
            if classes:
                lines.append(f"  - Device classes: {classes}")
            if transports:
                lines.append(f"  - Transports: {transports}")
            lines.append("")

    # Additional families from CSV that aren't yet reflected in doc metadata
    csv_families: dict[str, list[str]] = defaultdict(list)
    for tid, rows in csv_data.items():
        for row in rows:
            pid = row.get("package_id", "").strip()
            if pid and pid not in ("TBD", "") and is_valid_reverse_domain_pkg(pid):
                csv_families[pid].append(tid)
    for pkg, targets in sorted(csv_families.items()):
        if len(targets) >= 2 and pkg not in shared:
            lines.append(f"- **`{pkg}`** ({len(targets)} targets in CSV): {', '.join(sorted(targets))}")
            lines.append("  - (Not yet captured as shared package_id in target doc metadata)")
            lines.append("")

    lines.append("")

    # ══════════════════════════════════════════════════════════════════
    # 7. Targets with Missing APKs
    # ══════════════════════════════════════════════════════════════════
    lines.append("## 7. Targets with Missing APKs")
    lines.append("")
    lines.append("Targets where package_id is TBD/N/A or APK has not been collected.")
    lines.append("")

    missing = [
        r for r in doc_records
        if r["apk_collected"] != "YES"
        or any(p in ("TBD", "N/A") for p in r["package_ids"])
    ]
    if missing:
        lines.append("| target_id | package_id(s) | APK method | CSV notes |")
        lines.append("|---|---|---|---|")
        for rec in missing:
            pkg_str = fmt_pkg(rec["package_ids"])
            note = rec["csv_notes"] or "—"
            lines.append(
                f"| {rec['primary_id']} | {pkg_str} | {rec['apk_method']} | {note} |"
            )
    else:
        lines.append("*All targets have known package IDs and collected APKs.*")
    lines.append("")

    # ── Return output ────────────────────────────────────────────────
    return "\n".join(lines) + "\n"


# ── freshness + entry point ──────────────────────────────────────────────────

_GENERATED_RE = re.compile(r"^Generated: .*$", re.MULTILINE)


def normalize(text: str) -> str:
    """Blank the volatile ``Generated:`` timestamp so freshness compares content.

    Two runs against identical target docs differ only in that line; ignoring it
    means ``--check`` reports staleness for real drift, not the passing clock.
    """
    return _GENERATED_RE.sub("Generated: <timestamp>", text)


def print_summary(doc_records: list[dict]) -> None:
    """Print the post-generation stats block to stdout."""
    maturity = compute_maturity_counts(doc_records)
    unique_urls = {url for rec in doc_records for url in rec["urls"]}
    print(f"   {len(doc_records)} target docs processed")
    print(f"   {len(unique_urls)} unique reference URLs")
    for gname in ("COMPLETE", "PARTIAL", "EARLY", "STUB"):
        print(f"   {gname}: {maturity.get(gname, 0)} targets")
    total_verified = sum(r["verified_count"] for r in doc_records)
    total_tbd = sum(r["tbd_count"] for r in doc_records)
    total_checked = sum(r["evidence_checked"] for r in doc_records)
    total_unchecked = sum(r["evidence_unchecked"] for r in doc_records)
    print(f"   Total VERIFIED: {total_verified}, Total TBD: {total_tbd}")
    print(f"   Evidence checklist: {total_checked} [x] / {total_unchecked} [ ]")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Generate VERIFICATION_REFERENCE.md from the target research docs.",
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help=(
            "verify VERIFICATION_REFERENCE.md is up to date and exit non-zero "
            "if stale, without writing the file (the Generated: timestamp is "
            "ignored in the comparison)"
        ),
    )
    args = parser.parse_args(argv)

    doc_records, csv_data = collect_records()
    rel = OUTPUT_PATH.relative_to(REPO_ROOT)
    generated_at = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    new_text = render_report(doc_records, csv_data, generated_at)

    if args.check:
        current = (
            OUTPUT_PATH.read_text(encoding="utf-8") if OUTPUT_PATH.exists() else None
        )
        if current is None:
            print(
                f"ERROR: {rel} does not exist; run without --check to create it.",
                file=sys.stderr,
            )
            return 1
        if normalize(current) == normalize(new_text):
            print(f"{rel} is up to date ({len(doc_records)} target doc(s)).")
            return 0
        print(
            f"ERROR: {rel} is stale ({len(doc_records)} target doc(s) on disk). "
            "Run `python scripts/generate_verification_ref.py` to regenerate it.",
            file=sys.stderr,
        )
        return 1

    OUTPUT_PATH.write_text(new_text, encoding="utf-8")
    print(f"✅ Generated: {OUTPUT_PATH}")
    print_summary(doc_records)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
