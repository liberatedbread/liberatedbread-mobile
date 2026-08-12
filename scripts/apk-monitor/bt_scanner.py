#!/usr/bin/env python3
"""Scan an APK for Bluetooth / BLE device references.

Uses jadx (if available) or apktool to decompile, then greps the output
for BLE-related patterns.  Returns structured results indicating whether
the APK is likely controlling a Bluetooth IoT device.
"""

import json
import logging
import re
import shutil
import subprocess
import tempfile
from dataclasses import dataclass, field, asdict
from pathlib import Path
from typing import Optional

log = logging.getLogger("bt_scanner")

# Canonical UUID regex — used in pattern matching and extraction
_UUID_RE = r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
_UUID_COMPILED = re.compile(_UUID_RE)

# ── Patterns that indicate Bluetooth / BLE usage ─────────
BT_PATTERNS = {
    "bluetooth_permission": re.compile(
        r"android\.permission\.BLUETOOTH|android\.permission\.BLUETOOTH_ADMIN"
        r"|android\.permission\.BLUETOOTH_CONNECT|android\.permission\.BLUETOOTH_SCAN"
        r"|android\.permission\.BLUETOOTH_ADVERTISE",
        re.IGNORECASE,
    ),
    "ble_gatt": re.compile(
        r"BluetoothGatt|BluetoothGattCallback|BluetoothGattService"
        r"|BluetoothGattCharacteristic|BluetoothGattDescriptor"
        r"|connectGatt|discoverServices|writeCharacteristic|readCharacteristic",
        re.IGNORECASE,
    ),
    "ble_uuid": re.compile(
        r"0000[0-9a-fA-F]{4}-0000-1000-8000-00805f9b34fb|" + _UUID_RE,
    ),
    "ble_scan": re.compile(
        r"BluetoothLeScanner|startLeScan|startScan|ScanFilter|ScanSettings|ScanCallback",
        re.IGNORECASE,
    ),
    "bluetooth_adapter": re.compile(
        r"BluetoothAdapter|BluetoothManager|BluetoothDevice|BluetoothSocket",
        re.IGNORECASE,
    ),
    "ble_advertising_name": re.compile(
        r"setDeviceName|getLocalName|scanRecord|advertisedServiceUuids|localName",
        re.IGNORECASE,
    ),
    "flutter_ble": re.compile(
        r"flutter_blue|flutter_reactive_ble|flutter_ble_lib"
        r"|FlutterBluePlus|flutter_blue_plus"
        r"|quick_blue|win_ble",
        re.IGNORECASE,
    ),
}

# Weights for confidence scoring — keyed by BT_PATTERNS name
_CONFIDENCE_WEIGHTS = {
    "bluetooth_permission": 0.15,
    "ble_gatt": 0.30,
    "ble_scan": 0.15,
    "bluetooth_adapter": 0.10,
    "ble_advertising_name": 0.10,
    "flutter_ble": 0.25,
}
_UUID_WEIGHT = 0.20

# Standard SIG UUIDs we can ignore (they're not custom device protocols)
SIG_BASE_UUIDS = {
    "00001800-0000-1000-8000-00805f9b34fb",  # Generic Access
    "00001801-0000-1000-8000-00805f9b34fb",  # Generic Attribute
    "0000180a-0000-1000-8000-00805f9b34fb",  # Device Information
    "0000180f-0000-1000-8000-00805f9b34fb",  # Battery Service
    "00001812-0000-1000-8000-00805f9b34fb",  # HID
}


@dataclass
class ScanResult:
    package_id: str
    apk_path: str
    has_bluetooth: bool = False
    has_ble_gatt: bool = False
    has_custom_uuids: bool = False
    is_flutter: bool = False
    confidence: float = 0.0  # 0.0 to 1.0
    uuids_found: list[str] = field(default_factory=list)
    pattern_hits: dict[str, int] = field(default_factory=dict)
    summary: str = ""
    decompile_dir: str = ""


def _decompile_apk(apk_path: Path, work_dir: Path) -> Optional[Path]:
    """Decompile an APK using jadx (preferred) or apktool as fallback."""
    jadx_out = work_dir / "jadx"
    apktool_out = work_dir / "apktool"

    # Try jadx first (produces Java source — easier to grep)
    if shutil.which("jadx"):
        log.info("Decompiling with jadx: %s", apk_path.name)
        try:
            subprocess.run(
                ["jadx", "-d", str(jadx_out), str(apk_path)],
                capture_output=True, timeout=600,
            )
            if jadx_out.exists() and any(jadx_out.rglob("*.java")):
                return jadx_out
        except (subprocess.TimeoutExpired, subprocess.CalledProcessError) as exc:
            log.warning("jadx failed: %s", exc)

    # Fallback to apktool (produces smali + resources)
    if shutil.which("apktool"):
        log.info("Decompiling with apktool: %s", apk_path.name)
        try:
            subprocess.run(
                ["apktool", "d", "-f", "-o", str(apktool_out), str(apk_path)],
                capture_output=True, timeout=600,
            )
            if apktool_out.exists():
                return apktool_out
        except (subprocess.TimeoutExpired, subprocess.CalledProcessError) as exc:
            log.warning("apktool failed: %s", exc)

    log.error("No decompiler available (need jadx or apktool)")
    return None


def _grep_dir(directory: Path, pattern: re.Pattern, max_matches: int = 500) -> list[str]:
    """Recursively grep a directory for a regex pattern.  Returns matching lines."""
    matches: list[str] = []
    try:
        for fpath in directory.rglob("*"):
            if len(matches) >= max_matches:
                break
            if not fpath.is_file():
                continue
            # Skip binary files and large files
            if fpath.suffix in (".png", ".jpg", ".gif", ".webp", ".so", ".dex", ".arsc", ".ogg", ".mp3"):
                continue
            if fpath.stat().st_size > 5_000_000:
                continue
            try:
                text = fpath.read_text(errors="replace")
                for line in text.splitlines():
                    if pattern.search(line):
                        matches.append(f"{fpath.relative_to(directory)}:{line.strip()[:200]}")
                        if len(matches) >= max_matches:
                            break
            except (OSError, UnicodeDecodeError):
                continue
    except Exception as exc:
        log.warning("grep_dir error: %s", exc)
    return matches


def _detect_flutter(decompile_root: Path) -> bool:
    """Check if the decompiled APK is a Flutter app."""
    markers = ["libapp.so", "libflutter.so", "flutter_assets"]
    for marker in markers:
        if any(decompile_root.rglob(marker)):
            return True
    return False


def _extract_uuids(matches: list[str]) -> list[str]:
    """Extract unique UUIDs from match lines."""
    uuids: set[str] = set()
    for line in matches:
        for m in _UUID_COMPILED.finditer(line):
            u = m.group(0).lower()
            if u not in SIG_BASE_UUIDS:
                uuids.add(u)
    return sorted(uuids)


def _compute_confidence(result: ScanResult) -> None:
    """Compute confidence score and set boolean flags on a ScanResult in place."""
    score = 0.0
    for key, weight in _CONFIDENCE_WEIGHTS.items():
        if result.pattern_hits.get(key, 0) > 0:
            score += weight
    if result.pattern_hits.get("bluetooth_permission", 0) > 0:
        result.has_bluetooth = True
    if result.pattern_hits.get("flutter_ble", 0) > 0:
        result.has_bluetooth = True
    if result.pattern_hits.get("ble_gatt", 0) > 0:
        result.has_ble_gatt = True
    if len(result.uuids_found) > 0:
        result.has_custom_uuids = True
        score += _UUID_WEIGHT
    result.confidence = min(score, 1.0)


def scan_apk(package_id: str, apk_path: Path, work_dir: Optional[Path] = None) -> ScanResult:
    """Scan a single APK for Bluetooth/BLE device control patterns.

    Args:
        package_id: Android package identifier.
        apk_path: Path to the .apk file.
        work_dir: Where to put decompiled output.  Uses a temp dir if None.

    Returns:
        ScanResult with confidence score and details.
    """
    result = ScanResult(package_id=package_id, apk_path=str(apk_path))

    if work_dir is None:
        work_dir = Path(tempfile.mkdtemp(prefix=f"bt_scan_{package_id}_"))

    decompile_root = _decompile_apk(apk_path, work_dir)
    if decompile_root is None:
        result.summary = "Failed to decompile APK"
        return result

    result.decompile_dir = str(decompile_root)
    result.is_flutter = _detect_flutter(decompile_root)

    # Run all pattern checks
    for name, pattern in BT_PATTERNS.items():
        hits = _grep_dir(decompile_root, pattern, max_matches=200)
        result.pattern_hits[name] = len(hits)

        if name == "ble_uuid":
            uuids = _extract_uuids(hits)
            result.uuids_found.extend(uuids)

    result.uuids_found = sorted(set(result.uuids_found))
    _compute_confidence(result)

    # Build summary
    parts = []
    if result.has_bluetooth:
        parts.append("BT permissions")
    if result.has_ble_gatt:
        parts.append("GATT usage")
    if result.has_custom_uuids:
        parts.append(f"{len(result.uuids_found)} custom UUIDs")
    result.summary = f"confidence={result.confidence:.2f}: {', '.join(parts) or 'no BT signals'}"

    log.info("[%s] %s", package_id, result.summary)
    return result


def is_interesting(result: ScanResult, threshold: float = 0.3) -> bool:
    """Return True if the APK looks like it controls a Bluetooth device."""
    return result.confidence >= threshold and result.has_bluetooth


if __name__ == "__main__":
    import sys
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(name)s %(levelname)s %(message)s")
    if len(sys.argv) < 3:
        print("Usage: bt_scanner.py <package_id> <apk_path>")
        sys.exit(1)
    r = scan_apk(sys.argv[1], Path(sys.argv[2]))
    print(json.dumps(asdict(r), indent=2))
