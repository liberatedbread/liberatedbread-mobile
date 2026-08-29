#!/usr/bin/env python3
# Copyright 2026 Pigs Can Fly Labs LLC
# SPDX-License-Identifier: Apache-2.0
"""Check that every `helpful_urls` entry in the catalogue still resolves.

The schema says a link must be verified before it is added, because "a dead
link is worse than no link". This is the thing that checks it, and it is
deliberately NOT part of CI: it talks to the open internet, so it is slow, it
is flaky, and a third-party site having a bad afternoon must not turn a spec
PR red. Run it by hand when adding links, and periodically to catch rot.

Two failure modes it is careful to tell apart:

* **Gone** — 404, or the host no longer resolves. The link is dead and needs
  replacing, ideally with an Internet Archive snapshot (`--wayback` will look
  one up for you).
* **Blocked** — 403, or a timeout, from a site that is alive but refuses
  anything without a browser fingerprint. manuals.plus, fcc.report and most
  Zendesk-hosted vendor portals do this. The link works for a human. Reported
  separately so it does not get "fixed" by deleting a good link.

Usage:
    python scripts/check_links.py                  # check everything
    python scripts/check_links.py --kind manual    # only the manual links
    python scripts/check_links.py --wayback        # suggest archive snapshots
    python scripts/check_links.py --spec hue-bridge
"""
from __future__ import annotations

import argparse
import json
import urllib.error
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import yaml

REPO_ROOT = Path(__file__).resolve().parent.parent
DEVICE_SPECS_DIR = REPO_ROOT / "device-specs"

# Sites answer a bare urllib request with a 403 far more often than they answer
# a browser. Presenting as one is not a trick here: we are checking whether a
# human following this link would get a page.
UA = (
    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
)
TIMEOUT = 45
# Wayback replays a snapshot on first request and can take a minute over it.
# A short timeout there reports a perfectly good archive link as unreachable,
# which is the one class of link we most want to keep.
ARCHIVE_TIMEOUT = 180
WAYBACK_API = "https://archive.org/wayback/available?url="


def collect_links(kind: str | None, only_spec: str | None) -> list[tuple[str, str, str, str]]:
    """Return (spec_id, kind, title, url) for every helpful_urls entry."""
    found = []
    for path in sorted(DEVICE_SPECS_DIR.rglob("*.yaml")):
        spec_id = path.stem
        if only_spec and spec_id != only_spec:
            continue
        doc = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
        for entry in doc.get("helpful_urls") or []:
            entry_kind = entry.get("kind", "")
            if kind and entry_kind != kind:
                continue
            found.append((spec_id, entry_kind, entry.get("title", ""), entry["url"]))
    return found


# RFC 2606 reserves these for documentation. device-specs/examples/ uses one
# deliberately, and it is supposed to 404 — flagging it would leave the checker
# permanently red and therefore ignored.
PLACEHOLDER_HOSTS = ("example.com", "example.org", "example.net")


def probe(url: str) -> tuple[str, str]:
    """Return (verdict, detail). Verdict is ok / blocked / gone."""
    if any(host in url for host in PLACEHOLDER_HOSTS):
        return "ok", "placeholder"
    request = urllib.request.Request(url, headers={"User-Agent": UA})
    timeout = ARCHIVE_TIMEOUT if "web.archive.org" in url else TIMEOUT
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return "ok", str(response.status)
    except urllib.error.HTTPError as exc:
        # 403 and 429 are "alive but not talking to us"; 404 and 410 are gone.
        if exc.code in (401, 403, 429):
            return "blocked", str(exc.code)
        if exc.code in (404, 410):
            return "gone", str(exc.code)
        return "blocked", str(exc.code)
    except Exception as exc:  # timeouts, DNS, TLS
        return "blocked", type(exc).__name__


def wayback(url: str) -> str | None:
    api = WAYBACK_API + urllib.parse.quote(url, safe="")
    try:
        request = urllib.request.Request(api, headers={"User-Agent": UA})
        with urllib.request.urlopen(request, timeout=TIMEOUT) as response:
            doc = json.load(response)
    except Exception:
        return None
    snap = (doc.get("archived_snapshots") or {}).get("closest") or {}
    if snap.get("available") and snap.get("url"):
        return snap["url"].replace("http://", "https://", 1)
    return None


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--kind", help="only check entries with this `kind`")
    parser.add_argument("--spec", help="only check one spec, by id")
    parser.add_argument(
        "--wayback",
        action="store_true",
        help="look up an Internet Archive snapshot for anything not OK",
    )
    parser.add_argument("--jobs", type=int, default=8)
    args = parser.parse_args()

    links = collect_links(args.kind, args.spec)
    if not links:
        print("no matching helpful_urls entries found")
        return 0

    print(f"checking {len(links)} link(s)...\n")
    with ThreadPoolExecutor(max_workers=args.jobs) as pool:
        verdicts = list(pool.map(lambda row: probe(row[3]), links))

    gone, blocked = [], []
    for (spec_id, kind, title, url), (verdict, detail) in zip(links, verdicts, strict=True):
        if verdict == "ok":
            continue
        (gone if verdict == "gone" else blocked).append((spec_id, kind, title, url, detail))

    ok_count = len(links) - len(gone) - len(blocked)
    print(f"{ok_count}/{len(links)} resolved.")

    if blocked:
        print(f"\n{len(blocked)} blocked or slow — alive, but refusing us. Usually fine:")
        for spec_id, kind, _title, url, detail in blocked:
            print(f"  [{detail}] {spec_id} ({kind}): {url}")

    if gone:
        print(f"\n{len(gone)} GONE — these need replacing:")
        for spec_id, kind, _title, url, detail in gone:
            print(f"  [{detail}] {spec_id} ({kind}): {url}")

    if args.wayback and (gone or blocked):
        print("\nInternet Archive snapshots:")
        for spec_id, _kind, _title, url, _detail in gone + blocked:
            snap = wayback(url)
            print(f"  {spec_id}: {snap or 'no snapshot'}\n    <- {url}")

    # Only a genuinely dead link is a failure. A blocked one is the normal
    # state of half the vendor internet and must not gate anything.
    return 1 if gone else 0


if __name__ == "__main__":
    raise SystemExit(main())
