#!/usr/bin/env python3
# Copyright 2026 Pigs Can Fly Labs LLC
# SPDX-License-Identifier: Apache-2.0
#
# Verify the CONTENTS of the Android App Bundle that goes to Google Play.
#
# WHY THIS EXISTS
#
# The guided release checked the AAB's signature (jarsigner) and nothing else,
# while the iOS half runs verify_ios_app.sh over the exact IPA it uploads. The
# APK checks in scripts/verify_apk.sh only ever ran on CI's debug and release
# APKs, which are not the artifact Play receives. So the regressions that
# script exists for (a Rust library cargokit failed to package, a manifest
# merge that dropped a Bluetooth permission or changed the applicationId)
# could reach Play in the one build nobody inspected.
#
# This reads the bundle itself, with the standard library only: no bundletool
# (its runnable jar is a GitHub download), no aapt2. It checks:
#
#   1. Native libraries, per ABI under base/lib/: the same rules as
#      verify_apk.sh (the Rust core next to every libflutter.so, above a size
#      floor, every required ABI present).
#   2. 16 KB page alignment. Google Play requires apps that target Android 15+
#      to run on devices with 16 KB memory pages, which needs every 64-bit .so
#      to be linked with PT_LOAD segments aligned to at least 16 KB. A library
#      linked for 4 KB pages installs and runs on today's phones and fails on
#      16 KB ones, so nothing but reading the ELF headers shows it. 32-bit ABIs
#      have no 16 KB devices and are not checked.
#   3. The merged manifest (base/manifest/AndroidManifest.xml, which in a bundle
#      is aapt2's protobuf XML, not the binary XML of an APK): the package id,
#      the permissions verify_apk.sh requires (and the maxSdkVersion cap on the
#      legacy Bluetooth ones), and, when asked, versionCode / versionName, so
#      the record and the bundle cannot disagree about which build this is.
#
# Usage:
#   ./scripts/verify_aab.py build/app/outputs/bundle/release/app-release.aab \
#       [--require-abis arm64-v8a,armeabi-v7a,x86_64] [--min-so-bytes 65536] \
#       [--expect-version-code N] [--expect-version-name X.Y.Z]
#
# Exit codes: 0 every check passed; 1 a check failed; 2 bad usage or not a
# bundle at all.
#
# Python 3.9+ (macOS's system python3), standard library only.

import argparse
import struct
import sys
import zipfile

RUST_LIB = "libliberated_bread_core.so"
EXPECTED_PACKAGE = "ca.pigscanfly.liberatedbread"
ANDROID_NS = "http://schemas.android.com/apk/res/android"

# Kept identical to scripts/verify_apk.sh's lists; verify_aab_selftest.py
# reads that script and fails if the two drift apart.
REQUIRED_PERMISSIONS = [
    "android.permission.INTERNET",
    "android.permission.BLUETOOTH_SCAN",
    "android.permission.BLUETOOTH_CONNECT",
    "android.permission.ACCESS_FINE_LOCATION",
    "android.permission.ACCESS_COARSE_LOCATION",
    "android.permission.CHANGE_WIFI_MULTICAST_STATE",
    "android.permission.BLUETOOTH",
    "android.permission.BLUETOOTH_ADMIN",
]
LEGACY_MAX_SDK_PERMISSIONS = [
    "android.permission.BLUETOOTH",
    "android.permission.BLUETOOTH_ADMIN",
]
LEGACY_MAX_SDK = "30"

# ABIs whose devices can have 16 KB pages.
SIXTEEN_KB_ABIS = {"arm64-v8a", "x86_64"}
PAGE_16K = 16384

GREEN, YELLOW, RED, RESET = "\033[1;32m", "\033[1;33m", "\033[1;31m", "\033[0m"


class Report:
    def __init__(self):
        self.failures = 0

    def log(self, msg):
        print(f"{GREEN}[verify-aab]{RESET} {msg}")

    def warn(self, msg):
        print(f"{YELLOW}[verify-aab]{RESET} {msg}")

    def fail(self, msg):
        print(f"{RED}[verify-aab] FAIL:{RESET} {msg}", file=sys.stderr)
        self.failures += 1


# ── protobuf, just enough of aapt2's Resources.proto ────────────────────────
#
#   XmlNode      { XmlElement element = 1; string text = 2; ... }
#   XmlElement   { ... string namespace_uri = 2; string name = 3;
#                  repeated XmlAttribute attribute = 4;
#                  repeated XmlNode child = 5; }
#   XmlAttribute { string namespace_uri = 1; string name = 2;
#                  string value = 3; ...; Item compiled_item = 6; }
#   Item         { ...; Primitive prim = 7; }
#   Primitive    { ...; int32 int_decimal_value = 6; ... }
#
# aapt2 keeps an attribute's source text in `value`; a compiled integer (such
# as versionCode) may carry only compiled_item.prim, so both are read.


def _varint(buf, pos):
    result = shift = 0
    while True:
        if pos >= len(buf):
            raise ValueError("truncated varint")
        b = buf[pos]
        pos += 1
        result |= (b & 0x7F) << shift
        if not b & 0x80:
            return result, pos
        shift += 7


def pb_fields(buf):
    """Yields (field_number, wire_type, value) for one protobuf message.
    value is an int for varints and fixed widths, bytes for length-delimited."""
    pos = 0
    while pos < len(buf):
        key, pos = _varint(buf, pos)
        field, wire = key >> 3, key & 7
        if wire == 0:
            value, pos = _varint(buf, pos)
        elif wire == 1:
            value = struct.unpack_from("<Q", buf, pos)[0]
            pos += 8
        elif wire == 2:
            length, pos = _varint(buf, pos)
            value = bytes(buf[pos:pos + length])
            if len(value) != length:
                raise ValueError("truncated field")
            pos += length
        elif wire == 5:
            value = struct.unpack_from("<I", buf, pos)[0]
            pos += 4
        else:
            raise ValueError(f"unsupported wire type {wire}")
        yield field, wire, value


class Element:
    def __init__(self, name, attrs, children):
        self.name = name
        self.attrs = attrs  # {(namespace_uri, name): (value_text, int_or_None)}
        self.children = children

    def attr(self, name, ns=ANDROID_NS):
        return self.attrs.get((ns, name), (None, None))


def _prim_int(item_bytes):
    for field, _, value in pb_fields(item_bytes):
        if field == 7:  # prim
            for pfield, _, pvalue in pb_fields(value):
                if pfield == 6:  # int_decimal_value: a negative int32 is a 64-bit varint
                    return pvalue - (1 << 64) if pvalue >= (1 << 63) else pvalue
                if pfield == 7:  # int_hexadecimal_value
                    return pvalue
    return None


def _attribute(buf):
    ns = name = ""
    text = None
    number = None
    for field, _, value in pb_fields(buf):
        if field == 1:
            ns = value.decode()
        elif field == 2:
            name = value.decode()
        elif field == 3:
            text = value.decode()
        elif field == 6:
            number = _prim_int(value)
    return (ns, name), (text, number)


def _element(buf):
    name = ""
    attrs = {}
    children = []
    for field, _, value in pb_fields(buf):
        if field == 3:
            name = value.decode()
        elif field == 4:
            key, val = _attribute(value)
            attrs[key] = val
        elif field == 5:
            child = parse_xml_node(value)
            if child is not None:
                children.append(child)
    return Element(name, attrs, children)


def parse_xml_node(buf):
    """The element an XmlNode holds, or None for a text node."""
    for field, _, value in pb_fields(buf):
        if field == 1:
            return _element(value)
    return None


# ── ELF ─────────────────────────────────────────────────────────────────────

PT_LOAD = 1


def elf_load_alignments(data):
    """The p_align of every PT_LOAD segment, or raises ValueError."""
    if data[:4] != b"\x7fELF":
        raise ValueError("not an ELF file")
    cls, endian = data[4], data[5]
    if endian not in (1, 2):
        raise ValueError("unknown ELF byte order")
    e = "<" if endian == 1 else ">"
    if cls == 2:  # ELF64
        phoff, = struct.unpack_from(e + "Q", data, 0x20)
        phentsize, phnum = struct.unpack_from(e + "HH", data, 0x36)
        fmt, align_at = e + "I", 0x30
    elif cls == 1:  # ELF32
        phoff, = struct.unpack_from(e + "I", data, 0x1C)
        phentsize, phnum = struct.unpack_from(e + "HH", data, 0x2A)
        fmt, align_at = e + "I", 0x1C
    else:
        raise ValueError("unknown ELF class")
    aligns = []
    for i in range(phnum):
        base = phoff + i * phentsize
        p_type, = struct.unpack_from(fmt, data, base)
        if p_type != PT_LOAD:
            continue
        if cls == 2:
            p_align, = struct.unpack_from(e + "Q", data, base + align_at)
        else:
            p_align, = struct.unpack_from(e + "I", data, base + align_at)
        aligns.append(p_align)
    if not aligns:
        raise ValueError("no PT_LOAD segments")
    return aligns


# ── checks ──────────────────────────────────────────────────────────────────


def check_libs(zf, names, required_abis, min_so_bytes, r):
    libs = {}  # abi -> {name: size}
    for info in zf.infolist():
        parts = info.filename.split("/")
        if len(parts) == 4 and parts[0] == "base" and parts[1] == "lib" and parts[3].endswith(".so"):
            libs.setdefault(parts[2], {})[parts[3]] = info.file_size

    r.log("Native libraries in the bundle:")
    if not libs:
        print("  (none)")
        r.fail("The bundle has no base/lib/<abi>/ directory at all — the native build produced nothing.")
    for abi in sorted(libs):
        for name in sorted(libs[abi]):
            print(f"  {libs[abi][name]:10d}  base/lib/{abi}/{name}")

    for abi in sorted(libs):
        rust = libs[abi].get(RUST_LIB)
        flutter = libs[abi].get("libflutter.so")
        if rust is None:
            if flutter is not None:
                r.fail(f"base/lib/{abi}/{RUST_LIB} is MISSING while libflutter.so is present — cargokit did not package the Rust library for {abi}.")
            elif abi in required_abis:
                r.fail(f"base/lib/{abi}/{RUST_LIB} is MISSING (and so is libflutter.so), yet {abi} is required.")
            else:
                # A plugin's prebuilt x86 .so makes a slice with no engine in it;
                # verify_apk.sh explains why that is not a failure.
                r.warn(f"base/lib/{abi}/ has neither {RUST_LIB} nor libflutter.so — a plugin-only ABI slice, not a Flutter target.")
        elif rust < min_so_bytes:
            r.fail(f"base/lib/{abi}/{RUST_LIB} is only {rust} bytes (floor {min_so_bytes}) — a stub or truncated link output.")
        else:
            r.log(f"  ok  base/lib/{abi}/{RUST_LIB} ({rust} bytes)")
        if rust is not None and flutter is None:
            r.warn(f"base/lib/{abi}/libflutter.so is missing — is {abi} a real Flutter ABI slice?")

    for abi in required_abis:
        if abi not in libs:
            r.fail(f"Required ABI '{abi}' is absent from the bundle (found: {' '.join(sorted(libs)) or 'none'}).")

    for abi in sorted(set(libs) & SIXTEEN_KB_ABIS):
        for name in sorted(libs[abi]):
            path = f"base/lib/{abi}/{name}"
            try:
                aligns = elf_load_alignments(zf.read(path))
            except ValueError as e:
                r.fail(f"{path}: cannot read its ELF program headers ({e}).")
                continue
            low = min(aligns)
            if low < PAGE_16K:
                r.fail(f"{path}: a PT_LOAD segment is aligned to {low} bytes, below 16 KB — it fails on 16 KB-page devices, which Play requires support for. Relink with -Wl,-z,max-page-size=16384 (NDK r28+ does it by default).")
            else:
                r.log(f"  ok  {path} 16 KB-aligned (PT_LOAD align {low})")


def check_manifest(zf, args, r):
    try:
        raw = zf.read("base/manifest/AndroidManifest.xml")
    except KeyError:
        r.fail("No base/manifest/AndroidManifest.xml — this is not an app bundle's base module.")
        return
    try:
        root = parse_xml_node(raw)
    except (ValueError, UnicodeDecodeError, struct.error) as e:
        r.fail(f"The manifest is not aapt2 protobuf XML ({e}).")
        return
    if root is None or root.name != "manifest":
        r.fail("The manifest's root element is not <manifest>.")
        return

    package = root.attr("package", ns="")[0]
    if package != EXPECTED_PACKAGE:
        r.fail(f"Package id is '{package or '<none>'}', expected '{EXPECTED_PACKAGE}' — an applicationId change orphans every existing install.")
    else:
        r.log(f"  ok  package id {package}")

    code_text, code_num = root.attr("versionCode")
    version_code = code_num if code_num is not None else code_text
    version_name = root.attr("versionName")[0]
    r.log(f"versionCode {version_code}, versionName {version_name}")
    if args.expect_version_code is not None and str(version_code) != str(args.expect_version_code):
        r.fail(f"versionCode is {version_code}, but this build was recorded as {args.expect_version_code}.")
    if args.expect_version_name is not None and version_name != args.expect_version_name:
        r.fail(f"versionName is {version_name}, expected {args.expect_version_name}.")

    perms = {}
    for child in root.children:
        if child.name == "uses-permission":
            name = child.attr("name")[0]
            if name:
                max_text, max_num = child.attr("maxSdkVersion")
                perms[name] = max_text if max_text is not None else (str(max_num) if max_num is not None else None)
    r.log("Merged manifest permissions:")
    for name in sorted(perms):
        cap = f" (maxSdkVersion {perms[name]})" if perms[name] else ""
        print(f"  {name}{cap}")
    for perm in REQUIRED_PERMISSIONS:
        if perm in perms:
            r.log(f"  ok  {perm}")
        else:
            r.fail(f"Merged manifest does not declare {perm} — the app will fail at runtime, not at build time.")
    for perm in LEGACY_MAX_SDK_PERMISSIONS:
        if perm not in perms:
            continue  # reported above
        if perms[perm] == LEGACY_MAX_SDK:
            r.log(f"  ok  {perm} capped at maxSdkVersion {LEGACY_MAX_SDK}")
        else:
            r.fail(f"Merged manifest declares {perm} without maxSdkVersion='{LEGACY_MAX_SDK}' — the manifest merge dropped the cap.")


def main(argv=None):
    p = argparse.ArgumentParser(description="Verify the contents of a release .aab.")
    p.add_argument("aab")
    p.add_argument("--require-abis", default="arm64-v8a,armeabi-v7a,x86_64")
    p.add_argument("--min-so-bytes", type=int, default=65536)
    p.add_argument("--expect-version-code")
    p.add_argument("--expect-version-name")
    args = p.parse_args(argv)

    r = Report()
    try:
        zf = zipfile.ZipFile(args.aab)
    except (OSError, zipfile.BadZipFile) as e:
        r.fail(f"Not a readable bundle: {args.aab} ({e})")
        return 2
    with zf:
        names = set(zf.namelist())
        if "BundleConfig.pb" not in names:
            r.fail(f"No BundleConfig.pb — {args.aab} is not an Android App Bundle.")
            return 2
        r.log(f"Verifying {args.aab}")
        required = [a for a in args.require_abis.split(",") if a]
        check_libs(zf, names, required, args.min_so_bytes, r)
        check_manifest(zf, args, r)

    if r.failures:
        print(f"{RED}[verify-aab] {r.failures} check(s) FAILED for {args.aab}{RESET}", file=sys.stderr)
        return 1
    r.log(f"All bundle content checks passed for {args.aab}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
