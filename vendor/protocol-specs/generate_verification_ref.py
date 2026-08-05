#!/usr/bin/env python3
"""
generate_verification_ref.py

Reads all target .md files in targets/ (excluding TEMPLATE.md) and targets/targets.csv,
then generates a comprehensive VERIFICATION_REFERENCE.md with:
  1. APK Source Index
  2. Reference URL Catalog
  3. Evidence Gap Analysis
  4. APK Acquisition Quick-Reference
  5. Protocol Maturity Heatmap
  6. App Family Clusters
  7. Targets with Missing APKs
"""

import csv
import re
from collections import defaultdict
from datetime import datetime
from pathlib import Path

TARGETS_DIR = Path(__file__).resolve().parent / "targets"
OUTPUT_PATH = Path(__file__).resolve().parent / "VERIFICATION_REFERENCE.md"
APKEEP_DIR = Path(__file__).resolve().parent / "workspace" / "apks" / "apkeep"

# Regex for valid Android package names: at least 2 dot-separated segments,
# each starting with a letter/underscore, containing alphanumeric/underscore.
# Use non-capturing groups so findall() returns the full match.
ANDROID_PKG_RE = re.compile(r"[a-zA-Z_][a-zA-Z0-9_]*(?:\.[a-zA-Z_][a-zA-Z0-9_]*)+")

# Valid reverse-domain prefixes for filtering out false-positives
VALID_PKG_PREFIXES = ("com.", "org.", "cn.", "co.", "io.", "net.", "edu.", "gov.", "uk.")


def is_valid_reverse_domain_pkg(text: str) -> bool:
    """Return True if text looks like a real reverse-domain package ID (not speculative text)."""
    return text.startswith(VALID_PKG_PREFIXES) and len(text) >= 8


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


def check_apk_on_disk(package_ids: list[str]) -> str:
    """Cross-reference workspace/apks/apkeep/ — return YES if .apk/.xapk exists for any pkg."""
    if not APKEEP_DIR.is_dir():
        return None  # can't check
    for pid in package_ids:
        if pid in ("TBD", "N/A"):
            continue
        for ext in (".apk", ".xapk"):
            if (APKEEP_DIR / f"{pid}{ext}").exists():
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
            # Check if this line contains any package_id(s) label
            pkg_match = re.match(
                r"-\s*(?:(?:controlling\s+)?app\s+)?package_id\(s\)\s*:\s*(.*)",
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
        if "obd" in t or "iso 15765" in t or "can bus" in t:
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
            key = t.capitalize() if len(t) < 30 else t[:30]
        counts[key] += 1
    return dict(counts)


def compute_maturity_counts(records: list[dict]) -> dict[str, int]:
    """Count targets by maturity group."""
    groups: dict[str, list[dict]] = {"COMPLETE": [], "PARTIAL": [], "EARLY": [], "STUB": []}
    for rec in records:
        groups[rec["group"]].append(rec)
    return {k: len(v) for k, v in groups.items()}


# ── main ─────────────────────────────────────────────────────────────────

def main() -> None:
    md_files = sorted([
        f for f in TARGETS_DIR.iterdir()
        if f.suffix == ".md" and f.name not in ("TEMPLATE.md",)
    ])

    csv_path = TARGETS_DIR / "targets.csv"
    csv_data = read_csv_data(csv_path)

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
    lines.append("Auto-generated by `generate_verification_ref.py` — do not edit manually.")
    lines.append("")
    # A reader has no way to tell which rows reflect evidence and which
    # reflect one working copy's download cache, so say so here.
    lines.append(
        "> **NOT REPRODUCIBLE**: the \"APK collected?\" column probes the "
        "gitignored `workspace/` directory, so regenerating this file "
        "elsewhere rewrites rows and shifts the maturity counts. It cannot "
        "be CI-checked the way `device-specs/index.json` is. Tracked in "
        "issue #18."
    )
    lines.append("")
    lines.append(f"Generated: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
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

    # ── Write output ────────────────────────────────────────────────
    OUTPUT_PATH.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"✅ Generated: {OUTPUT_PATH}")
    print(f"   {len(doc_records)} target docs processed")
    print(f"   {len(url_refs)} unique reference URLs")
    for gname in ("COMPLETE", "PARTIAL", "EARLY", "STUB"):
        print(f"   {gname}: {len(groups[gname])} targets")

    # Summary stats for the Heatmap
    total_verified = sum(r["verified_count"] for r in doc_records)
    total_tbd = sum(r["tbd_count"] for r in doc_records)
    total_checked = sum(r["evidence_checked"] for r in doc_records)
    total_unchecked = sum(r["evidence_unchecked"] for r in doc_records)
    print(f"   Total VERIFIED: {total_verified}, Total TBD: {total_tbd}")
    print(f"   Evidence checklist: {total_checked} [x] / {total_unchecked} [ ]")


if __name__ == "__main__":
    main()
