#!/usr/bin/env python3
# Copyright 2026 Pigs Can Fly Labs LLC
# SPDX-License-Identifier: Apache-2.0
"""Generate DNS blocklists from the specs' ``cloud.egress`` entries.

A spec's ``cloud.egress`` says, per host, who contacts it (the device or only
the vendor's app), what the connection is for, and what blocking it costs. This
turns those facts into the formats people actually paste into a resolver:
hosts files, Pi-hole adlists, AdGuard Home rules, dnsmasq (OpenWrt), Unbound
(OPNsense / pfSense), RouterOS and RPZ.

Two profiles:

``updates``
    Only hosts with a ``firmware_check`` or ``firmware_download`` role. For an
    owner who still wants the vendor app away from home but not the update that
    removes the local protocol. Weaker than it sounds: it stops the update hosts
    the specs NAME, and vendors move update traffic without notice.
``cloud``
    Everything the device itself contacts. The DNS half of cutting it off.

Neither profile blocks an entry carrying the ``time`` role, whatever else it
serves. A device that loses its clock loses its schedules, so NTP hosts are
REDIRECTED to a LAN NTP server when one is given (``--time-server``) and
otherwise listed in the header, never sinkholed; any other clock (an HTTPS API
that also sets the time, a hardcoded time server's address) is left reachable
and named in the header. Hosts only the vendor's app contacts are
never listed: blocking them at the router breaks the app for every phone on
the network and does nothing to the device.
Entries whose ``when_blocked.impact`` is ``breaks`` are left out and named in
the header — and veto the name in a combined list, where another spec may list
it as safe. The veto is by DNS containment, not spelling: a ``subdomains`` rule
on a parent is dropped when a protected clock or store lives under it. Literal
addresses (which DNS cannot touch) are listed in the header as firewall rules
instead. A device whose every entry is an exclusion still gets a list: one with
no rules, whose header says what must stay reachable and why.

A DNS list is the second layer, never the only one — see
https://liberatedbread.com/firewall/ for the firewall rule it backs up.

Usage::

    python scripts/generate_blocklists.py                  # write site/api/v1/blocklists/
    python scripts/generate_blocklists.py --check          # build everything, write nothing
    python scripts/generate_blocklists.py --coverage       # cloud specs with no egress yet
    python scripts/generate_blocklists.py --format dnsmasq --profile cloud \\
        --device tplink-kasa-smart-plug --time-server 192.168.1.53   # one list to stdout

The mkdocs post-build hook runs the first form into the built site, so the
published docs carry every list at a stable URL. Output is deterministic (no
timestamps), so a rebuild with unchanged specs is byte-identical.
"""

from __future__ import annotations

import argparse
import ipaddress
import json
import re
import sys
import zlib
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable, Iterable

import yaml

REPO_ROOT = Path(__file__).resolve().parent.parent
SPECS_DIR = REPO_ROOT / "device-specs" / "devices"
DEFAULT_OUT_DIR = REPO_ROOT / "site" / "api" / "v1" / "blocklists"
SOURCE_URL = "https://github.com/liberatedbread/liberatedbread-protocol-specs"
FIREWALL_URL = "https://liberatedbread.com/firewall/"

FIRMWARE_ROLES = frozenset({"firmware_check", "firmware_download"})
TIME_ROLES = frozenset({"time"})
DEVICE_SIDE = frozenset({"device", "both"})

PROFILES = {
    "updates": (
        "Firmware update hosts only, so the rest of the vendor cloud, and the vendor app away "
        "from home, usually keeps working; where a device's update offer rides its main cloud "
        "link, that link is listed too. It stops the update hosts the specs NAME; vendors move "
        "update traffic without notice, so this is the weakest list here."
    ),
    "cloud": (
        "Every host the device itself contacts, except time sources. The DNS half of cutting "
        "the device off from its vendor; the firewall rule is the other half."
    ),
}


# --------------------------------------------------------------------------- model


@dataclass(frozen=True)
class Entry:
    """One ``cloud.egress`` item, flattened and tagged with its spec."""

    device: str
    device_name: str
    host: str | None
    address: str | None
    match: str
    ports: tuple[tuple[int, str], ...]
    contacted_by: str
    roles: tuple[str, ...]
    impact: str
    effect: str | None
    verification: str
    region: str | None
    workaround: str | None = None

    @property
    def name(self) -> str:
        return self.host or self.address or ""

    @property
    def is_time_only(self) -> bool:
        return set(self.roles) <= TIME_ROLES

    @property
    def is_ntp(self) -> bool:
        """A time source an NTP server can stand in for.

        Not every time source is NTP: a webOS TV takes its clock from a header
        on an HTTPS API, and pointing that name at an NTP server fixes nothing.
        With no ports recorded, NTP is the assumption the role description makes.
        """
        return self.is_time_only and (not self.ports or (123, "udp") in self.ports)

    def caution(self) -> str | None:
        """The sentence an owner reads before blocking this, if it costs anything."""
        if self.impact not in ("degraded", "unknown") or not self.effect:
            return None
        text = f"{self.name} ({self.device}, impact {self.impact}): {' '.join(self.effect.split())}"
        if self.workaround:
            text += f" Workaround: {' '.join(self.workaround.split())}"
        return text


@dataclass(frozen=True)
class Rule:
    """A DNS name to act on, merged across every spec that lists it."""

    host: str
    subdomains: bool
    devices: tuple[str, ...]
    roles: tuple[str, ...]
    verification: str  # the weakest of the merged entries
    cautions: tuple[str, ...] = ()

    def describe(self) -> str:
        return f"{', '.join(self.devices)} | {', '.join(self.roles)} | {self.verification}"


@dataclass
class Selection:
    """What one profile does with a set of entries."""

    profile: str
    scope: str
    slug: str = "all"  # machine form of the scope; tags what a RouterOS import owns
    devices: list[tuple[str, str]] = field(default_factory=list)
    block: list[Rule] = field(default_factory=list)
    time: list[Rule] = field(default_factory=list)
    firewall: list[Entry] = field(default_factory=list)
    excluded: list[Entry] = field(default_factory=list)
    # (entry, the protected entry that vetoed it): a name that would have been
    # blocked, but whose rule would answer for a name some spec needs reachable.
    vetoed: list[tuple[Entry, Entry]] = field(default_factory=list)

    @property
    def empty(self) -> bool:
        """Nothing to say at all. A list with no rules but an exclusion still
        gets published: the names that must NOT be blocked, and why, are the
        part of this a device with nothing blockable most needs written down."""
        return not (self.block or self.time or self.firewall or self.excluded)


_TRUST = {"confirmed": 0, "reported": 1, "hypothesis": 2}
# libyaml when present: this reads every spec in the tree, and the pure-Python
# loader makes that the slowest step of a docs build.
_LOADER = getattr(yaml, "CSafeLoader", yaml.SafeLoader)


def load_specs(specs_dir: Path = SPECS_DIR) -> dict[str, dict]:
    """Every spec under *specs_dir*, by id. Parsed once per build, not cached:
    ``mkdocs serve`` re-runs the hook in-process after an edit."""
    return {
        path.stem: yaml.load(path.read_text(encoding="utf-8"), Loader=_LOADER) or {}
        for path in sorted(specs_dir.glob("*.yaml"))
    }


def load_entries(specs_dir: Path = SPECS_DIR, specs: dict[str, dict] | None = None) -> list[Entry]:
    """Every ``cloud.egress`` entry in the tree, in spec order.

    Validation is validate_specs.py's job; this trusts the schema and reads.
    """
    entries: list[Entry] = []
    for stem, spec in (load_specs(specs_dir) if specs is None else specs).items():
        egress = (spec.get("cloud") or {}).get("egress") or []
        name = (spec.get("device") or {}).get("name", stem)
        for item in egress:
            blocked = item.get("when_blocked") or {}
            entries.append(
                Entry(
                    device=stem,
                    device_name=name,
                    host=item.get("host"),
                    address=item.get("address"),
                    match=item.get("match", "exact"),
                    ports=tuple((p["port"], p["protocol"]) for p in item.get("ports") or []),
                    contacted_by=item["contacted_by"],
                    roles=tuple(item["roles"]),
                    impact=blocked.get("impact", "unknown"),
                    effect=blocked.get("effect"),
                    verification=item.get("verification", "hypothesis"),
                    region=item.get("region"),
                    workaround=blocked.get("workaround"),
                )
            )
    return entries


def coverage(specs_dir: Path = SPECS_DIR, specs: dict[str, dict] | None = None) -> tuple[list[str], list[str]]:
    """(specs with egress, specs with a cloud block but no egress yet)."""
    with_egress: list[str] = []
    without: list[str] = []
    for stem, spec in (load_specs(specs_dir) if specs is None else specs).items():
        cloud = spec.get("cloud")
        if not cloud:
            continue
        (with_egress if cloud.get("egress") else without).append(stem)
    return with_egress, without


def _covers(rule: Entry, name: str) -> bool:
    """Whether a DNS rule written for *rule* answers for *name*."""
    assert rule.host
    return name == rule.host or (rule.match == "subdomains" and name.endswith("." + rule.host))


def _protector(candidate: Entry, protected: list[Entry]) -> Entry | None:
    """The protected entry that forbids blocking *candidate*, if any.

    Two shapes. The candidate's rule would answer for a protected name (the
    same name, or a `subdomains` parent above it): vetoed, because the rule
    takes the protected name with it. Or the candidate sits under a protected
    `subdomains` parent: vetoed when another spec wrote the parent, since that
    spec said everything under it must stay reachable, but allowed when the
    same spec wrote both, because a more specific entry from the same hand is
    a deliberate carve-out (LG's rdx2.lgtvsdp.com telemetry under the
    lgtvsdp.com clock), and the resolver's most-specific-wins makes it one.
    """
    assert candidate.host
    for p in protected:
        if _covers(candidate, p.host or ""):
            return p
        if (
            p.match == "subdomains"
            and p.device != candidate.device
            and _covers(p, candidate.host)
        ):
            return p
    return None


def _merge(entries: Iterable[Entry]) -> list[Rule]:
    by_host: dict[str, list[Entry]] = {}
    for e in entries:
        by_host.setdefault(e.host or "", []).append(e)
    rules = []
    for host in sorted(by_host):
        group = by_host[host]
        rules.append(
            Rule(
                host=host,
                subdomains=any(e.match == "subdomains" for e in group),
                devices=tuple(sorted({e.device for e in group})),
                roles=tuple(sorted({r for e in group for r in e.roles})),
                verification=max((e.verification for e in group), key=_TRUST.__getitem__),
                cautions=tuple(dict.fromkeys(c for e in group if (c := e.caution()))),
            )
        )
    return rules


def select(
    entries: list[Entry], profile: str, scope: str = "all devices", slug: str = "all"
) -> Selection:
    """Apply a profile: which names to block, redirect, leave out or firewall."""
    if profile not in PROFILES:
        raise ValueError(f"unknown profile {profile!r}; expected one of {sorted(PROFILES)}")
    device_side = [e for e in entries if e.contacted_by in DEVICE_SIDE]
    sel = Selection(profile=profile, scope=scope, slug=re.sub(r"[^a-z0-9,-]", "-", slug))

    wanted: list[Entry] = []
    time: list[Entry] = []
    for e in device_side:
        if "time" in e.roles:
            # Never blocked, whatever else the entry serves: a device that loses
            # its clock loses its schedules. Plain NTP by name can be pointed at
            # a LAN NTP server; any other clock (an HTTPS API that also sets the
            # time, a hardcoded server's address) is left reachable, and said so.
            (time if e.is_ntp and e.host else sel.excluded).append(e)
        elif profile == "cloud" or FIRMWARE_ROLES & set(e.roles):
            wanted.append(e)

    for e in wanted:
        if e.impact == "breaks":
            sel.excluded.append(e)
        elif e.address:
            sel.firewall.append(e)
    # A name some spec says must stay reachable is not blocked on another
    # spec's say-so: in a combined list, one device's harmless block is
    # another's broken clock or store. The protectors are EVERY device-side
    # entry that breaks or keeps time, whatever the profile and whichever
    # spec: an `updates` list never selects a `content` host, but a `content`
    # host marked `breaks` (by another spec, or by this one) still forbids
    # blocking a firmware rule that would answer for it. The comparison is
    # DNS containment, not string equality: a `subdomains` rule on a parent
    # answers for every name under it, so it is vetoed by a protected child
    # it would cover.
    protected = [e for e in device_side if e.host and (e.impact == "breaks" or "time" in e.roles)]
    blockable: list[Entry] = []
    held: list[tuple[Entry, Entry]] = []
    for e in wanted:
        if not e.host or e.impact == "breaks":
            continue
        guard = _protector(e, protected)
        if guard is None:
            blockable.append(e)
        else:
            held.append((e, guard))
    for e, guard in held:
        # A veto is moot when the same name is blocked anyway, by a carve-out
        # the protector's own spec wrote: the rule goes out whatever this
        # entry says, so it joins that rule rather than be reported as "not
        # listed" above a line that lists it. Only when the carve-out answers
        # for everything this entry would: an exact carve-out does not block
        # the subdomains a `subdomains` entry asks for.
        if any(
            b.host == e.host and (b.match == "subdomains" or e.match != "subdomains")
            for b in blockable
        ):
            blockable.append(e)
            continue
        sel.vetoed.append((e, guard))
        # The header explains every name it keeps reachable, so a protector
        # the profile would otherwise never have mentioned is listed too.
        if guard not in sel.excluded and guard not in time:
            sel.excluded.append(guard)
    sel.block = _merge(blockable)
    sel.time = _merge(time)
    # Name only the devices this list actually says something about: a header
    # claiming a device the rules never touch reads as coverage it lacks.
    involved = {d for r in sel.block + sel.time for d in r.devices}
    involved |= {e.device for e in sel.firewall + sel.excluded}
    involved |= {e.device for e, _ in sel.vetoed}
    sel.devices = sorted({(e.device, e.device_name) for e in device_side if e.device in involved})
    return sel


# ------------------------------------------------------------------------ rendering


@dataclass(frozen=True)
class Options:
    """Per-render choices a user makes; the published lists use the defaults."""

    time_server: str | None = None  # redirect time hosts here
    sinkhole: str | None = None  # answer blocked names with this address instead of NXDOMAIN/null


def _family(addr: str) -> str:
    return "AAAA" if ipaddress.ip_address(addr).version == 6 else "A"


def _header(sel: Selection, opts: Options, c: str, fmt: str, caveat: str | None = None) -> list[str]:
    out = [
        f"{c} Liberated Bread DNS blocklist: profile '{sel.profile}', {sel.scope}, format '{fmt}'",
        f"{c} Generated from cloud.egress in {SOURCE_URL}",
        f"{c} by scripts/generate_blocklists.py. Do not edit this file; fix the spec.",
        c,
    ]
    out += [f"{c} {line}" for line in _wrap(PROFILES[sel.profile])]
    out += [
        c,
        f"{c} A DNS list is the second layer. A device that ignores your resolver walks",
        f"{c} straight past it, so firewall the device as well: {FIREWALL_URL}",
    ]
    if caveat:
        out += [c] + [f"{c} {line}" for line in _wrap(caveat)]
    out += [c, f"{c} Devices:"]
    out += [f"{c}   {name} ({dev})" for dev, name in sel.devices] or [f"{c}   (none)"]
    if sel.time:
        out += [c]
        if opts.time_server:
            out.append(f"{c} Time sources, redirected to {opts.time_server} (do not block these):")
        else:
            out += [
                f"{c} Time sources. NOT blocked: a device that loses its clock loses its schedules.",
                f"{c} Point these at a LAN NTP server (your router, or chrony on any always-on host),",
                f"{c} or regenerate with --time-server <address> to have the redirect written for you:",
            ]
        out += [f"{c}   {r.host}{' (and subdomains)' if r.subdomains else ''}  [{r.describe()}]" for r in sel.time]
    if sel.firewall:
        out += [c, f"{c} Hardcoded addresses. DNS cannot block these; add a firewall rule:"]
        for e in sel.firewall:
            ports = ", ".join(f"{proto}/{port}" for port, proto in e.ports) or "any port"
            out.append(f"{c}   {e.address} {ports}  [{e.device} | {', '.join(e.roles)} | {e.verification}]")
    if sel.excluded:
        out += [c, f"{c} Left out, because blocking them breaks the device or its clock:"]
        for e in sel.excluded:
            out += _bullet(c, f"{e.name} ({e.device}): {' '.join((e.effect or 'see the spec').split())}")
    if sel.vetoed:
        out += [c, f"{c} Not listed, because of a name listed above as one to keep reachable:"]
        for e, guard in sel.vetoed:
            sub = " and subdomains" if e.match == "subdomains" else ""
            if _covers(e, guard.host or ""):
                why = f"would cover {guard.name} ({guard.device})"
            else:
                why = f"sits under {guard.name} and subdomains, which {guard.device} keeps reachable"
            out += _bullet(c, f"{e.name}{sub} ({e.device}) {why}.")
    cautions = [text for r in sel.block for text in r.cautions]
    if cautions:
        out += [c, f"{c} Read before applying. Blocking these has a cost on some units:"]
        for text in cautions:
            out += _bullet(c, text)
    out += [
        c,
        f"{c} Each rule below is preceded by: devices | roles | verification.",
        f"{c} 'reported' and 'hypothesis' entries have not been observed by this project.",
        "",
    ]
    return out


def _bullet(c: str, text: str) -> list[str]:
    lines = _wrap(text, width=82)
    return [f"{c}   - {lines[0]}"] + [f"{c}     {line}" for line in lines[1:]]


def _wrap(text: str, width: int = 86) -> list[str]:
    lines, line = [], ""
    for word in text.split():
        if line and len(line) + 1 + len(word) > width:
            lines.append(line)
            line = word
        else:
            line = f"{line} {word}" if line else word
    return lines + ([line] if line else [])


def _null_pair(sinkhole: str | None) -> tuple[str, str]:
    """(IPv4, IPv6) answers for a blocked exact name.

    Both families, always: a record for one family alone lets the other's query
    through to the real resolver, and an IPv6-capable device then connects to
    the real host.
    """
    if not sinkhole:
        return "0.0.0.0", "::"
    return (sinkhole, "::") if _family(sinkhole) == "A" else ("0.0.0.0", sinkhole)


def render_hosts(sel: Selection, opts: Options) -> str:
    """/etc/hosts and every tool that reads it. Exact names only."""
    v4, v6 = _null_pair(opts.sinkhole)
    out = _header(
        sel, opts, "#", "hosts",
        "A hosts file matches exact names only. Rules marked (and subdomains) cover only the "
        "name shown here; use the dnsmasq, Unbound, AdGuard or RPZ list to catch the rest.",
    )
    for r in sel.block:
        out += [f"# {r.describe()}{' (and subdomains)' if r.subdomains else ''}", f"{v4} {r.host}", f"{v6} {r.host}"]
    if opts.time_server:
        for r in sel.time:
            out += [f"# {r.describe()} (time: redirected)", f"{opts.time_server} {r.host}"]
    return "\n".join(out) + "\n"


def render_pihole(sel: Selection, opts: Options) -> str:
    """A Pi-hole adlist: plain names (exact) and ||name^ (with subdomains)."""
    out = _header(
        sel, opts, "#", "pihole",
        "Add as an adlist (Pi-hole FTL 5.22+ or v6 for the ||name^ lines). An adlist can only "
        "block, and what a blocked name answers is your Pi-hole's blocking mode, not this file. "
        "It cannot redirect: for the time sources below, add each as a local DNS record "
        "(v6: dns.hosts; v5: Local DNS > DNS Records) pointing at your NTP server.",
    )
    for r in sel.block:
        out += [f"# {r.describe()}", f"||{r.host}^" if r.subdomains else r.host]
    return "\n".join(out) + "\n"


def render_adguard(sel: Selection, opts: Options) -> str:
    """AdGuard Home filter rules: |name^ (exact), ||name^ (with subdomains), $dnsrewrite."""
    out = _header(
        sel, opts, "!", "adguard",
        "Add as a blocklist by URL, or paste into Custom filtering rules: AdGuard Home honours "
        "$dnsrewrite in both (Private AdGuard DNS only in custom rules). Not for Pi-hole, "
        "which rejects |name^ and $ modifiers; use the pihole list there.",
    )

    def pattern(r: Rule) -> str:
        return f"||{r.host}^" if r.subdomains else f"|{r.host}^"

    for r in sel.block:
        rule = pattern(r) + (f"$dnsrewrite={opts.sinkhole}" if opts.sinkhole else "")
        out += [f"! {r.describe()}", rule]
    if opts.time_server:
        for r in sel.time:
            out += [f"! {r.describe()} (time: redirected)", f"{pattern(r)}$dnsrewrite={opts.time_server}"]
    return "\n".join(out) + "\n"


def render_dnsmasq(sel: Selection, opts: Options) -> str:
    """dnsmasq, and so OpenWrt: a file in /etc/dnsmasq.d/ (or the conf-dir your build uses)."""
    v4, v6 = _null_pair(opts.sinkhole)
    out = _header(
        sel, opts, "#", "dnsmasq",
        "Exact names use host-record= and answer a null address; names with subdomains use "
        "address=/name/, which answers NXDOMAIN for the name and everything under it. A time "
        "redirect answers A only, so an AAAA lookup for that name still goes upstream: an "
        "IPv6-capable device can still find the real server, and reaches yours over IPv4.",
    )
    for r in sel.block:
        out.append(f"# {r.describe()}")
        if not r.subdomains:
            out.append(f"host-record={r.host},{v4},{v6}")
        elif opts.sinkhole:
            out += [f"address=/{r.host}/{v4}", f"address=/{r.host}/{v6}"]
        else:
            out.append(f"address=/{r.host}/")
    if opts.time_server:
        for r in sel.time:
            out.append(f"# {r.describe()} (time: redirected)")
            if r.subdomains:
                out.append(f"address=/{r.host}/{opts.time_server}")
            else:
                out.append(f"host-record={r.host},{opts.time_server}")
    return "\n".join(out) + "\n"


def render_unbound(sel: Selection, opts: Options) -> str:
    """Unbound server: clauses (OPNsense / pfSense custom options)."""
    v4, v6 = _null_pair(opts.sinkhole)
    out = _header(
        sel, opts, "#", "unbound",
        "Paste under a server: clause. Exact names get local-data (a null address, or your "
        "--sinkhole); names with subdomains get a local-zone, which covers everything under "
        "them. Each time redirect carries its own local-zone, because Unbound ignores a bare "
        "local-data that sits under a blocking zone.",
    )
    # Every zone this list opens. Unbound refuses a whole config holding a
    # local-data below the apex of a redirect zone, so an exact name that
    # falls under one -- a carve-out under a time redirect, or another spec's
    # name under a --sinkhole parent -- gets a zone of its own.
    zones = [r.host for r in sel.block if r.subdomains]
    if opts.time_server:
        zones += [r.host for r in sel.time if r.subdomains]
    for r in sel.block:
        out.append(f"# {r.describe()}")
        if r.subdomains and not opts.sinkhole:
            out.append(f'local-zone: "{r.host}." always_nxdomain')
            continue
        if r.subdomains or any(r.host.endswith("." + z) for z in zones):
            out.append(f'local-zone: "{r.host}." redirect')
        out += [f'local-data: "{r.host}. A {v4}"', f'local-data: "{r.host}. AAAA {v6}"']
    if opts.time_server:
        for r in sel.time:
            kind = "redirect" if r.subdomains else "transparent"
            out += [
                f"# {r.describe()} (time: redirected)",
                f'local-zone: "{r.host}." {kind}',
                f'local-data: "{r.host}. {_family(opts.time_server)} {opts.time_server}"',
            ]
    return "\n".join(out) + "\n"


ROUTEROS_TAG = "liberatedbread"


def render_routeros(sel: Selection, opts: Options) -> str:
    """MikroTik RouterOS 7 /ip dns static script. Re-importing replaces, not duplicates."""
    tag = f"{ROUTEROS_TAG}:{sel.slug}:"
    out = _header(
        sel, opts, "#", "routeros",
        f"RouterOS 7.5 or later (match-subdomain). Import with /import. Every entry is tagged "
        f"'{tag}' and the first command removes that tag's previous import, so re-running "
        "this list replaces it, and lists for different devices coexist. A time redirect "
        "answers A only; AAAA still comes from upstream.",
    )
    # The tag ends in a delimiter, so one device's id that prefixes another's
    # (lg-webos, lg-webos-2019) can never remove the other's entries.
    out += ["/ip dns static", f'remove [find where comment~"^{tag}"]']

    def add(host: str, subdomains: bool, kind: str, note: str) -> str:
        sub = " match-subdomain=yes" if subdomains else ""
        return f'add name={host}{sub} {kind} comment="{tag} {note}"'

    for r in sel.block:
        note = ", ".join(r.devices)
        if opts.sinkhole:
            v4, v6 = _null_pair(opts.sinkhole)
            out += [
                add(r.host, r.subdomains, f"type=A address={v4}", note),
                add(r.host, r.subdomains, f"type=AAAA address={v6}", note),
            ]
        else:
            out.append(add(r.host, r.subdomains, "type=NXDOMAIN", note))
    if opts.time_server:
        for r in sel.time:
            kind = f"type={_family(opts.time_server)} address={opts.time_server}"
            out.append(add(r.host, r.subdomains, kind, "time, " + ", ".join(r.devices)))
    return "\n".join(out) + "\n"


def render_rpz(sel: Selection, opts: Options) -> str:
    """A Response Policy Zone: BIND, Unbound (rpz:), PowerDNS Recursor, Knot Resolver."""
    body: list[str] = []
    for r in sel.block:
        body.append(f"; {r.describe()}")
        if opts.sinkhole:
            names = [r.host] + ([f"*.{r.host}"] if r.subdomains else [])
            body += [f"{n} {_family(opts.sinkhole)} {opts.sinkhole}" for n in names]
        elif r.subdomains:
            body += [f"{r.host} CNAME .", f"*.{r.host} CNAME ."]
        else:
            # NODATA, not NXDOMAIN: an NXDOMAIN on a name tells a cache
            # (RFC 8020) that everything under it is gone too, which is more
            # than an exact rule means.
            body.append(f"{r.host} CNAME *.")
    if opts.time_server:
        for r in sel.time:
            body.append(f"; {r.describe()} (time: redirected)")
            for n in [r.host] + ([f"*.{r.host}"] if r.subdomains else []):
                body.append(f"{n} {_family(opts.time_server)} {opts.time_server}")
    serial = zlib.crc32("\n".join(body).encode()) % 2**31 or 1
    out = _header(
        sel, opts, ";", "rpz",
        "Load as a response-policy zone. Exact names answer NODATA; names with subdomains "
        "answer NXDOMAIN for the name and a wildcard below it.",
    )
    out += [
        "$TTL 300",
        f"@ SOA localhost. root.localhost. {serial} 3600 600 86400 300",
        "@ NS localhost.",
        "",
    ]
    return "\n".join(out + body) + "\n"


FORMATS: dict[str, tuple[str, Callable[[Selection, Options], str]]] = {
    "hosts": ("hosts.txt", render_hosts),
    "pihole": ("pihole.txt", render_pihole),
    "adguard": ("adguard.txt", render_adguard),
    "dnsmasq": ("dnsmasq.conf", render_dnsmasq),
    "unbound": ("unbound.conf", render_unbound),
    "routeros": ("routeros.rsc", render_routeros),
    "rpz": ("rpz.zone", render_rpz),
}


# ------------------------------------------------------------------------- output


def _entry_json(e: Entry) -> dict:
    d = {
        "device": e.device,
        "contacted_by": e.contacted_by,
        "roles": list(e.roles),
        "impact": e.impact,
        "verification": e.verification,
    }
    if e.host:
        d["host"] = e.host
        d["match"] = e.match
    if e.address:
        d["address"] = e.address
    if e.ports:
        d["ports"] = [{"port": p, "protocol": proto} for p, proto in e.ports]
    if e.effect:
        d["effect"] = e.effect
    if e.workaround:
        d["workaround"] = e.workaround
    if e.region:
        d["region"] = e.region
    return d


def build_index(entries: list[Entry], files: dict[str, list[str]], covered: tuple[list[str], list[str]]) -> dict:
    """The machine-readable companion: every entry, and which list files exist."""
    with_egress, without = covered
    return {
        "source": SOURCE_URL,
        "profiles": PROFILES,
        "formats": {name: ext for name, (ext, _) in FORMATS.items()},
        "files": files,
        "entries": [_entry_json(e) for e in entries],
        "coverage": {"with_egress": with_egress, "cloud_without_egress": without},
    }


def build_site(
    entries: list[Entry],
    specs_dir: Path = SPECS_DIR,
    covered: tuple[list[str], list[str]] | None = None,
) -> dict[str, str]:
    """Every published file, as {relative path: content}. Pure; writes nothing."""
    out: dict[str, str] = {}
    files: dict[str, list[str]] = {}
    scopes: list[tuple[str, str, str, list[Entry]]] = [("", "all devices", "all", entries)]
    for dev in sorted({e.device for e in entries}):
        scopes.append((f"devices/{dev}/", f"device '{dev}'", dev, [e for e in entries if e.device == dev]))
    opts = Options()
    for prefix, scope, slug, subset in scopes:
        for profile in PROFILES:
            sel = select(subset, profile, scope, slug)
            if sel.empty:
                continue
            for _fmt, (ext, render) in FORMATS.items():
                path = f"{prefix}{profile}.{ext}"
                out[path] = render(sel, opts)
                files.setdefault(prefix.rstrip("/") or "all", []).append(path)
    covered = coverage(specs_dir) if covered is None else covered
    out["index.json"] = json.dumps(build_index(entries, files, covered), indent=2, sort_keys=True) + "\n"
    return out


def write_site(out_dir: Path = DEFAULT_OUT_DIR, specs_dir: Path = SPECS_DIR) -> int:
    """Write every list under *out_dir*. Returns the number of files written."""
    specs = load_specs(specs_dir)
    site = build_site(load_entries(specs=specs), covered=coverage(specs=specs))
    for rel, content in site.items():
        path = out_dir / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8")
    return len(site)


def _address(value: str) -> str:
    try:
        return str(ipaddress.ip_address(value))
    except ValueError as exc:
        raise argparse.ArgumentTypeError(f"not an IP address: {value!r}") from exc


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--out", type=Path, default=DEFAULT_OUT_DIR, help="output directory for the full set")
    parser.add_argument("--check", action="store_true", help="build every list, write nothing")
    parser.add_argument("--coverage", action="store_true", help="list cloud specs that have no egress yet")
    parser.add_argument("--format", choices=sorted(FORMATS), help="print one list to stdout in this format")
    parser.add_argument("--profile", choices=sorted(PROFILES), default="updates")
    parser.add_argument("--device", action="append", help="with --format: limit to this spec id (repeatable)")
    parser.add_argument("--time-server", type=_address, help="redirect time hosts to this LAN address")
    parser.add_argument(
        "--sinkhole", type=_address,
        help="answer blocked names with this address instead of NXDOMAIN (see the docs before "
        "pointing it at a real host: nothing there speaks the vendor's protocol)",
    )
    args = parser.parse_args(argv)

    specs = load_specs()
    entries = load_entries(specs=specs)
    if args.device:
        known = {e.device for e in entries}
        unknown = sorted(set(args.device) - known)
        if unknown:
            print(f"no cloud.egress entries for: {', '.join(unknown)}", file=sys.stderr)
            return 2
        entries = [e for e in entries if e.device in args.device]

    if args.coverage:
        with_egress, without = coverage(specs=specs)
        print(f"{len(with_egress)} spec(s) with cloud.egress: {', '.join(with_egress) or '-'}")
        print(f"{len(without)} spec(s) with a cloud block but no egress yet:")
        for dev in without:
            print(f"  {dev}")
        return 0

    if args.format:
        scope = f"device(s) {', '.join(args.device)}" if args.device else "all devices"
        slug = ",".join(sorted(set(args.device))) if args.device else "all"
        sel = select(entries, args.profile, scope, slug)
        _, render = FORMATS[args.format]
        sys.stdout.write(render(sel, Options(time_server=args.time_server, sinkhole=args.sinkhole)))
        return 0

    if args.check:
        site = build_site(entries, covered=coverage(specs=specs))
        print(f"blocklists OK: {len(site)} file(s) from {len(entries)} egress entr(y/ies)")
        return 0

    count = write_site(args.out)
    print(f"wrote {count} file(s) to {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
