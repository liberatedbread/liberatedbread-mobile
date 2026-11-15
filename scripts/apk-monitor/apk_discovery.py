#!/usr/bin/env python3
"""Discover and download new APKs that might contain Bluetooth IoT protocols.

Searches APKPure (via apkeep) for apps matching IoT-related keywords,
compares against the known targets in targets/targets.csv, and downloads
any that are new.
"""

import csv
import json
import logging
import re
import subprocess
import urllib.request
import urllib.parse
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

log = logging.getLogger("apk_discovery")

# ── Keyword lists used to find candidate IoT apps ────────
SEARCH_TERMS = [
    "bluetooth led controller",
    "ble smart light",
    "smart home bluetooth",
    "led strip bluetooth",
    "iot bluetooth device",
    "bluetooth smart plug",
    "bluetooth thermometer",
    "bluetooth display",
    "pixel display bluetooth",
    "led glasses bluetooth",
    "led mask bluetooth",
    "led badge bluetooth",
    "bluetooth camera",
    "wifi smart camera",
    "bluetooth vape",
    "bluetooth speaker controller",
    "flutter bluetooth iot",
    "flutter ble smart home",
    "flutter led controller",
]


def load_known_packages(targets_csv: Path) -> set[str]:
    """Return the set of package IDs already tracked in targets.csv."""
    pkgs: set[str] = set()
    if not targets_csv.exists():
        return pkgs
    with open(targets_csv, newline="") as f:
        reader = csv.DictReader(f)
        for row in reader:
            pkg = row.get("package_id", "").strip()
            if pkg:
                pkgs.add(pkg)
    return pkgs


def load_seen_packages(state_file: Path) -> set[str]:
    """Load the set of packages we've already inspected (even if rejected)."""
    if not state_file.exists():
        return set()
    try:
        with open(state_file) as f:
            data = json.load(f)
        return set(data.get("seen", []))
    except (json.JSONDecodeError, KeyError, ValueError):
        log.warning("Corrupt seen-packages file %s — starting fresh", state_file)
        return set()


def save_seen_packages(state_file: Path, seen: set[str]) -> None:
    """Persist the seen-packages set so we don't re-download on every run."""
    state_file.parent.mkdir(parents=True, exist_ok=True)
    with open(state_file, "w") as f:
        json.dump({"seen": sorted(seen), "updated": datetime.now(timezone.utc).isoformat()}, f, indent=2)


def search_apkpure(query: str, limit: int = 20) -> list[str]:
    """Scrape APKPure search results for package IDs.

    This is a best-effort scraper.  APKPure's HTML changes periodically.
    Returns a list of candidate package ID strings.
    """
    encoded = urllib.parse.quote_plus(query)
    url = f"https://apkpure.com/search?q={encoded}"
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
        with urllib.request.urlopen(req, timeout=30) as resp:
            html = resp.read().decode("utf-8", errors="replace")
    except Exception as exc:
        log.warning("APKPure search failed for %r: %s", query, exc)
        return []

    # APKPure embeds package IDs in data-package or href patterns like
    # /app-name/com.example.pkg  — extract with a simple regex.
    pkg_pattern = re.compile(r'/([a-z][a-z0-9_]*(?:\.[a-z][a-z0-9_]*){2,})"', re.IGNORECASE)
    found = pkg_pattern.findall(html)
    # De-dup while preserving order
    seen: set[str] = set()
    result: list[str] = []
    for pkg in found:
        pkg = pkg.strip().lower()
        if pkg not in seen and not pkg.startswith("com.apkpure") and not pkg.startswith("com.google"):
            seen.add(pkg)
            result.append(pkg)
        if len(result) >= limit:
            break
    return result


def download_apk(package_id: str, out_dir: Path, apkeep_source: str = "apk-pure",
                 email: str = "", aas_token: str = "") -> Optional[Path]:
    """Download an APK using apkeep.  Returns the path to the downloaded file, or None."""
    out_dir.mkdir(parents=True, exist_ok=True)

    cmd = ["apkeep", "-a", package_id, "-d", apkeep_source]
    if apkeep_source == "google-play":
        if not email or not aas_token:
            log.error("google-play source requires APKEEP_EMAIL and APKEEP_AAS_TOKEN")
            return None
        cmd += ["-e", email, "-t", aas_token]
    cmd.append(str(out_dir))

    log.info("Downloading %s via apkeep (%s)", package_id, apkeep_source)
    try:
        subprocess.run(cmd, check=True, capture_output=True, timeout=300)
    except FileNotFoundError:
        log.error("apkeep not found.  Install from https://github.com/EFForg/apkeep")
        return None
    except subprocess.CalledProcessError as exc:
        log.warning("apkeep failed for %s: %s", package_id, exc.stderr.decode(errors="replace")[:500])
        return None
    except subprocess.TimeoutExpired:
        log.warning("apkeep timed out for %s", package_id)
        return None

    # Find the file that was just created
    candidates = sorted(out_dir.glob(f"*{package_id}*"), key=lambda p: p.stat().st_mtime, reverse=True)
    if not candidates:
        # apkeep sometimes uses the bare package name
        candidates = sorted(out_dir.glob("*.apk"), key=lambda p: p.stat().st_mtime, reverse=True)
    return candidates[0] if candidates else None


def discover_new_apks(
    root_dir: Path,
    workspace_dir: Path,
    max_new: int = 10,
    apkeep_source: str = "apk-pure",
    apkeep_email: str = "",
    apkeep_aas_token: str = "",
) -> list[dict]:
    """Main entry point: search, filter, download.

    Returns a list of dicts: {"package_id": str, "apk_path": str}
    """
    targets_csv = root_dir / "targets" / "targets.csv"
    state_file = workspace_dir / "apk-monitor" / "seen_packages.json"
    apk_dir = workspace_dir / "apks" / "monitor"

    known = load_known_packages(targets_csv)
    seen = load_seen_packages(state_file)

    candidates: list[str] = []
    for term in SEARCH_TERMS:
        if len(candidates) >= max_new * 5:
            break
        results = search_apkpure(term)
        for pkg in results:
            if pkg not in known and pkg not in seen and pkg not in candidates:
                candidates.append(pkg)

    log.info("Found %d candidate packages after filtering known (%d) and seen (%d)",
             len(candidates), len(known), len(seen))

    downloaded: list[dict] = []
    for pkg in candidates[:max_new * 3]:  # download extra in case some fail BT check
        if len(downloaded) >= max_new:
            break
        apk_path = download_apk(
            pkg, apk_dir,
            apkeep_source=apkeep_source,
            email=apkeep_email,
            aas_token=apkeep_aas_token,
        )
        seen.add(pkg)
        if apk_path:
            downloaded.append({"package_id": pkg, "apk_path": str(apk_path)})

    save_seen_packages(state_file, seen)
    return downloaded


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(name)s %(levelname)s %(message)s")
    root = Path(__file__).resolve().parents[2]
    ws = root / "workspace"
    results = discover_new_apks(root, ws)
    for r in results:
        print(json.dumps(r))
