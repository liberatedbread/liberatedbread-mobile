#!/usr/bin/env python3
# Copyright 2026 Pigs Can Fly Labs LLC
# SPDX-License-Identifier: Apache-2.0
#
# Exercises scripts/verify_aab.py against bundles built here, byte by byte:
# aapt2-style protobuf manifests and ELF libraries with chosen PT_LOAD
# alignments. No Android SDK is needed, so it runs in scripts/test.sh and CI's
# analyze job, and every check the release relies on is shown to be able to
# fail. It also pins verify_aab.py's permission lists to verify_apk.sh's, so
# the APK and the bundle checks cannot drift apart.

import io
import os
import re
import struct
import subprocess
import sys
import tempfile
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import verify_aab  # noqa: E402

ANDROID = verify_aab.ANDROID_NS
failures = 0


def check(label, ok, detail=""):
    global failures
    if ok:
        print(f"  ok    {label}")
    else:
        failures += 1
        print(f"  FAIL  {label}{': ' + detail if detail else ''}", file=sys.stderr)


# ── protobuf encoding ───────────────────────────────────────────────────────

def varint(n):
    if n < 0:
        n += 1 << 64
    out = bytearray()
    while True:
        b = n & 0x7F
        n >>= 7
        if n:
            out.append(b | 0x80)
        else:
            out.append(b)
            return bytes(out)


def field_bytes(num, payload):
    if isinstance(payload, str):
        payload = payload.encode()
    return varint(num << 3 | 2) + varint(len(payload)) + payload


def field_varint(num, value):
    return varint(num << 3) + varint(value)


def attribute(name, value=None, ns=ANDROID, prim_int=None):
    out = b""
    if ns:
        out += field_bytes(1, ns)
    out += field_bytes(2, name)
    if value is not None:
        out += field_bytes(3, value)
    if prim_int is not None:
        prim = field_varint(6, prim_int)
        out += field_bytes(6, field_bytes(7, prim))  # compiled_item.prim
    return out


def element(name, attrs=(), children=()):
    out = field_bytes(3, name)
    for a in attrs:
        out += field_bytes(4, a)
    for c in children:
        out += field_bytes(5, field_bytes(1, c))  # XmlNode { element = 1 }
    return out


def manifest(package="ca.pigscanfly.liberatedbread", version_code=("29912977", None),
             version_name="0.0.1", perms=None, legacy_cap="30"):
    if perms is None:
        perms = list(verify_aab.REQUIRED_PERMISSIONS)
    children = []
    for p in perms:
        attrs = [attribute("name", p)]
        if p in verify_aab.LEGACY_MAX_SDK_PERMISSIONS and legacy_cap is not None:
            attrs.append(attribute("maxSdkVersion", legacy_cap, prim_int=int(legacy_cap)))
        children.append(element("uses-permission", attrs))
    children.append(element("application", [attribute("label", "Liberated Bread")]))
    attrs = [attribute("package", package, ns="")]
    text, num = version_code
    attrs.append(attribute("versionCode", text, prim_int=num))
    attrs.append(attribute("versionName", version_name))
    return field_bytes(1, element("manifest", attrs, children))


# ── ELF ─────────────────────────────────────────────────────────────────────

def elf(bits=64, align=16384, size=70000):
    """A minimal little-endian shared object: header, two PT_LOADs, padding."""
    if bits == 64:
        ehsize, phentsize = 64, 56
        hdr = b"\x7fELF" + bytes([2, 1, 1]) + bytes(9)
        hdr += struct.pack("<HHIQQQIHHHHHH", 3, 183, 1, 0, ehsize, 0, 0,
                           ehsize, phentsize, 2, 0, 0, 0)
        ph = b""
        for flags in (4, 5):
            ph += struct.pack("<IIQQQQQQ", 1, flags, 0, 0, 0, 0x100, 0x100, align)
    else:
        ehsize, phentsize = 52, 32
        hdr = b"\x7fELF" + bytes([1, 1, 1]) + bytes(9)
        hdr += struct.pack("<HHIIIIIHHHHHH", 3, 40, 1, 0, ehsize, 0, 0,
                           ehsize, phentsize, 2, 0, 0, 0)
        ph = b""
        for flags in (4, 5):
            ph += struct.pack("<IIIIIIII", 1, 0, 0, 0, 0x100, 0x100, flags, align)
    data = hdr + ph
    return data + bytes(max(0, size - len(data)))


GOOD_LIBS = {
    "arm64-v8a": {"libliberated_bread_core.so": elf(64), "libflutter.so": elf(64)},
    "armeabi-v7a": {"libliberated_bread_core.so": elf(32, 4096), "libflutter.so": elf(32, 4096)},
    "x86_64": {"libliberated_bread_core.so": elf(64), "libflutter.so": elf(64)},
}


def bundle(path, libs=None, man=None, config=True):
    libs = GOOD_LIBS if libs is None else libs
    with zipfile.ZipFile(path, "w") as z:
        if config:
            z.writestr("BundleConfig.pb", b"")
        z.writestr("base/manifest/AndroidManifest.xml", manifest() if man is None else man)
        z.writestr("base/dex/classes.dex", b"dex\n")
        for abi, files in libs.items():
            for name, data in files.items():
                z.writestr(f"base/lib/{abi}/{name}", data)


def run(path, *extra):
    out, err = io.StringIO(), io.StringIO()
    old = sys.stdout, sys.stderr
    sys.stdout, sys.stderr = out, err
    try:
        rc = verify_aab.main([path, *extra])
    finally:
        sys.stdout, sys.stderr = old
    return rc, out.getvalue() + err.getvalue()


def libs_with(abi, name, data):
    libs = {a: dict(f) for a, f in GOOD_LIBS.items()}
    if data is None:
        libs[abi].pop(name, None)
    else:
        libs[abi][name] = data
    return libs


def main():
    tmp = tempfile.mkdtemp()
    p = os.path.join(tmp, "app.aab")

    bundle(p)
    rc, out = run(p, "--expect-version-code", "29912977", "--expect-version-name", "0.0.1")
    check("a good bundle passes", rc == 0, out)
    check("it reports the 16 KB alignment", "16 KB-aligned" in out, out)

    bundle(p, man=manifest(version_code=(None, 29912977)))
    rc, out = run(p, "--expect-version-code", "29912977")
    check("versionCode read from compiled_item alone", rc == 0, out)

    bundle(p)
    rc, out = run(p, "--expect-version-code", "1")
    check("versionCode mismatch fails", rc == 1 and "versionCode is 29912977" in out, out)
    rc, out = run(p, "--expect-version-name", "0.0.2")
    check("versionName mismatch fails", rc == 1, out)

    bundle(p, libs=libs_with("arm64-v8a", "libliberated_bread_core.so", elf(64, 4096)))
    rc, out = run(p)
    check("a 4 KB-aligned arm64 library fails", rc == 1 and "below 16 KB" in out, out)
    bundle(p, libs=libs_with("x86_64", "libflutter.so", elf(64, 4096)))
    rc, out = run(p)
    check("any 64-bit library is held to 16 KB, not only ours", rc == 1, out)
    rc, out = run(os.path.join(tmp, "missing.aab"))
    check("an unreadable path is exit 2", rc == 2, out)

    bundle(p, libs=libs_with("arm64-v8a", "libliberated_bread_core.so", b"not an elf" + bytes(70000)))
    rc, out = run(p)
    check("an unparseable 64-bit library fails", rc == 1 and "ELF" in out, out)

    bundle(p, libs=libs_with("arm64-v8a", "libliberated_bread_core.so", None))
    rc, out = run(p)
    check("Rust library missing beside libflutter.so fails", rc == 1 and "cargokit" in out, out)

    bundle(p, libs=libs_with("arm64-v8a", "libliberated_bread_core.so", elf(64, size=1000)))
    rc, out = run(p)
    check("a stub Rust library fails", rc == 1 and "only 1000 bytes" in out, out)

    libs = {a: f for a, f in GOOD_LIBS.items() if a != "x86_64"}
    bundle(p, libs=libs)
    rc, out = run(p)
    check("a required ABI absent fails", rc == 1 and "Required ABI 'x86_64'" in out, out)
    rc, out = run(p, "--require-abis", "arm64-v8a")
    check("--require-abis sets the floor", rc == 0, out)

    libs = dict(GOOD_LIBS, x86={"libplugin.so": elf(32, 4096)})
    bundle(p, libs=libs)
    rc, out = run(p)
    check("a plugin-only 32-bit slice is a warning, not a failure", rc == 0 and "plugin-only" in out, out)

    bundle(p, man=manifest(package="com.example.other"))
    rc, out = run(p)
    check("a changed package id fails", rc == 1 and "orphans" in out, out)

    perms = [x for x in verify_aab.REQUIRED_PERMISSIONS if x != "android.permission.BLUETOOTH_SCAN"]
    bundle(p, man=manifest(perms=perms))
    rc, out = run(p)
    check("a dropped permission fails", rc == 1 and "BLUETOOTH_SCAN" in out, out)

    bundle(p, man=manifest(legacy_cap=None))
    rc, out = run(p)
    check("a dropped maxSdkVersion cap fails", rc == 1 and "dropped the cap" in out, out)

    bundle(p, config=False)
    rc, out = run(p)
    check("a zip without BundleConfig.pb is exit 2", rc == 2, out)

    bundle(p, man=b"\x0a\xff")
    rc, out = run(p)
    check("a corrupt manifest fails cleanly", rc == 1 and "protobuf" in out, out)

    # The CLI itself, as release-android.sh calls it.
    bundle(p)
    cli = subprocess.run([sys.executable, os.path.join(HERE, "verify_aab.py"), p],
                         capture_output=True, text=True)
    check("the CLI exits 0 on a good bundle", cli.returncode == 0, cli.stdout + cli.stderr)

    # The permission lists must match verify_apk.sh's.
    with open(os.path.join(HERE, "verify_apk.sh")) as f:
        sh = f.read()

    def sh_array(name):
        m = re.search(rf"^{name}=\((.*?)^\)", sh, re.S | re.M)
        return re.findall(r'"([^"]+)"', m.group(1)) if m else None

    check("REQUIRED_PERMISSIONS match verify_apk.sh",
          sh_array("REQUIRED_PERMISSIONS") == verify_aab.REQUIRED_PERMISSIONS,
          str(sh_array("REQUIRED_PERMISSIONS")))
    check("LEGACY_MAX_SDK_PERMISSIONS match verify_apk.sh",
          sh_array("LEGACY_MAX_SDK_PERMISSIONS") == verify_aab.LEGACY_MAX_SDK_PERMISSIONS,
          str(sh_array("LEGACY_MAX_SDK_PERMISSIONS")))
    m = re.search(r'^EXPECTED_PACKAGE="([^"]+)"', sh, re.M)
    check("EXPECTED_PACKAGE matches verify_apk.sh",
          m is not None and m.group(1) == verify_aab.EXPECTED_PACKAGE)

    if failures:
        print(f"verify_aab selftest: {failures} failure(s)", file=sys.stderr)
        return 1
    print("verify_aab selftest: all passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
