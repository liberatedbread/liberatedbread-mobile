# Copyright 2026 Pigs Can Fly Labs LLC
# SPDX-License-Identifier: Apache-2.0
"""Tests for cloud.egress and scripts/generate_blocklists.py.

Three layers, because each fails differently:

* the schema — an entry a generator cannot act on (a URL where a name belongs,
  a cost with no description, an unsourced claim) is rejected at validation,
  not discovered in a blocklist someone pasted into their router;
* the policy — what each profile blocks, redirects and leaves out. These are
  the decisions that break a device if they are wrong: blocking a clock,
  blocking the vendor app for every phone in the house, or blocking a name
  whose spec says it stops the device working;
* the formats — each resolver's syntax, including the semantics the
  resolvers' documentation pins down (dnsmasq's address= always takes
  subdomains, Pi-hole rejects `|name^` and `$` modifiers, a record for one
  address family lets the other through). Where the resolver itself is
  installed, its own config checker gets the last word.
"""

from __future__ import annotations

import copy
import ipaddress
import json
import re
import shutil
import subprocess
from pathlib import Path

import pytest
import yaml
from jsonschema import Draft202012Validator

import generate_blocklists as gb

REPO_ROOT = Path(__file__).resolve().parent.parent
DEVICES_DIR = REPO_ROOT / "device-specs" / "devices"
SCHEMA = json.loads((REPO_ROOT / "device-specs" / "schema.json").read_text(encoding="utf-8"))
VALIDATOR = Draft202012Validator(SCHEMA)


# ----------------------------------------------------------------------- helpers


_BASE_SPEC = yaml.safe_load(
    (DEVICES_DIR / "tplink-kasa-smart-plug.yaml").read_text(encoding="utf-8")
)


def _spec_with(egress: list[dict]) -> dict:
    """A real, valid spec with its egress swapped for *egress*, so these tests
    exercise the egress rules and nothing else the schema requires."""
    spec = copy.deepcopy(_BASE_SPEC)
    spec["cloud"]["egress"] = egress
    return spec


def _entry(**overrides) -> dict:
    base = {
        "host": "fw.example.com",
        "contacted_by": "device",
        "roles": ["firmware_download"],
        "when_blocked": {"impact": "none"},
        "verification": "confirmed",
    }
    base.update(overrides)
    return {k: v for k, v in base.items() if v is not None}


def _errors(egress: list[dict]) -> list[str]:
    return [e.message for e in VALIDATOR.iter_errors(_spec_with(egress))]


def E(host: str | None = None, **kw) -> gb.Entry:  # noqa: N802 - reads as a constructor
    """A generator Entry with sensible defaults."""
    fields = {
        "device": "dev-a",
        "device_name": "Device A",
        "host": host,
        "address": None,
        "match": "exact",
        "ports": (),
        "contacted_by": "device",
        "roles": ("firmware_download",),
        "impact": "none",
        "effect": None,
        "verification": "reported",
        "region": None,
        "workaround": None,
    }
    fields.update(kw)
    return gb.Entry(**fields)


def _rules(text: str, comment: str = "#") -> list[str]:
    """The non-comment, non-blank lines of a rendered list."""
    return [ln for ln in text.splitlines() if ln and not ln.startswith(comment)]


_SPECS = gb.load_specs(DEVICES_DIR)
_COVERAGE = gb.coverage(specs=_SPECS)


@pytest.fixture(scope="module")
def real_entries() -> list[gb.Entry]:
    return gb.load_entries(specs=_SPECS)


@pytest.fixture(scope="module")
def site(real_entries) -> dict[str, str]:
    return gb.build_site(real_entries, covered=_COVERAGE)


# ------------------------------------------------------------------------ schema


def test_the_schema_accepts_a_complete_entry():
    assert _errors([_entry(ports=[{"port": 443, "protocol": "tcp"}], region="US")]) == []


@pytest.mark.parametrize(
    "host",
    [
        "https://fw.example.com",  # a URL, not a name
        "fw.example.com:443",  # a port belongs in `ports`
        "fw.example.com/firmware",  # a path
        "*.example.com",  # wildcards are `match: subdomains`
        "FW.Example.com",  # names are lowercase, like UUIDs
        "localhost",  # no dot: not a public name
    ],
)
def test_the_schema_rejects_a_host_that_is_not_a_bare_name(host):
    assert _errors([_entry(host=host)]), f"{host!r} should not validate"


def test_an_entry_is_a_host_or_an_address_never_both_never_neither():
    assert _errors([_entry(address="203.0.113.7")]), "both host and address"
    assert _errors([_entry(host=None)]), "neither host nor address"
    assert _errors([_entry(host=None, address="203.0.113.0/24")]) == []


def test_an_address_takes_no_match():
    assert _errors([_entry(host=None, address="203.0.113.7", match="subdomains")])


def test_an_unconfirmed_entry_must_cite_its_basis():
    assert _errors([_entry(verification="reported")])
    assert _errors([_entry(verification="reported", basis="python-kasa fixtures")]) == []


@pytest.mark.parametrize("impact", ["degraded", "breaks", "unknown"])
def test_a_costly_or_unknown_block_must_say_what_it_costs(impact):
    assert _errors([_entry(when_blocked={"impact": impact})])
    assert _errors([_entry(when_blocked={"impact": impact, "effect": "Schedules drift."})]) == []


def test_the_schema_rejects_an_undeclared_egress_key():
    assert _errors([_entry(blocklist=True)])


# ------------------------------------------------------------ real-spec conventions


def _egress_by_spec() -> dict[str, list[dict]]:
    return {
        device: spec["cloud"]["egress"]
        for device, spec in _SPECS.items()
        if (spec.get("cloud") or {}).get("egress")
    }


def test_egress_addresses_parse_and_hosts_fit_in_dns():
    for device, egress in _egress_by_spec().items():
        for item in egress:
            if "address" in item:
                ipaddress.ip_network(item["address"], strict=False)
            if "host" in item:
                assert len(item["host"]) <= 253, f"{device}: {item['host']} is too long for DNS"


def test_no_spec_lists_the_same_name_twice():
    for device, egress in _egress_by_spec().items():
        names = [item.get("host") or item.get("address") for item in egress]
        dupes = sorted({n for n in names if names.count(n) > 1})
        assert not dupes, f"{device}: {dupes} listed more than once; merge the roles"


def test_a_time_source_never_claims_blocking_it_is_free():
    """A device that loses its clock loses its schedules. An entry with the
    `time` role and `impact: none` is either the wrong role or the wrong impact."""
    for device, egress in _egress_by_spec().items():
        for item in egress:
            if "time" in item["roles"]:
                assert item["when_blocked"]["impact"] != "none", (
                    f"{device}: {item.get('host')} is a time source marked impact none"
                )


# ------------------------------------------------------------------------ policy


def test_updates_takes_only_firmware_roles_and_cloud_takes_everything_device_side():
    entries = [
        E("fw.example.com", roles=("firmware_download",)),
        E("check.example.com", roles=("firmware_check",)),
        E("relay.example.com", roles=("device_cloud",)),
        E("ads.example.com", roles=("advertising",)),
    ]
    updates = {r.host for r in gb.select(entries, "updates").block}
    cloud = {r.host for r in gb.select(entries, "cloud").block}
    assert updates == {"fw.example.com", "check.example.com"}
    assert cloud == {"fw.example.com", "check.example.com", "relay.example.com", "ads.example.com"}


def test_app_hosts_are_never_listed():
    """Blocking the vendor app's host at the router breaks the app for every
    phone on the network and does nothing to the device."""
    entries = [E("api.example.com", contacted_by="app", roles=("account", "firmware_check"))]
    for profile in gb.PROFILES:
        sel = gb.select(entries, profile)
        assert sel.empty and not sel.devices


def test_the_header_names_only_devices_the_list_covers():
    entries = [E("fw.example.com", device="dev-a"), E("relay.example.com", device="dev-b", roles=("device_cloud",))]
    assert [d for d, _ in gb.select(entries, "updates").devices] == ["dev-a"]
    assert [d for d, _ in gb.select(entries, "cloud").devices] == ["dev-a", "dev-b"]


def test_a_breaking_entry_is_left_out_and_named():
    entries = [E("store.example.com", roles=("content",), impact="breaks", effect="The store dies.")]
    sel = gb.select(entries, "cloud")
    assert sel.block == [] and [e.host for e in sel.excluded] == ["store.example.com"]
    text = gb.render_hosts(sel, gb.Options())
    assert not any("store.example.com" in ln for ln in _rules(text))
    assert "The store dies." in text


def test_ntp_is_redirected_only_when_asked_and_never_blocked():
    entries = [E("pool.ntp.org", match="subdomains", roles=("time",), ports=((123, "udp"),),
                 impact="degraded", effect="Schedules drift.")]
    sel = gb.select(entries, "cloud")
    assert sel.block == [] and [r.host for r in sel.time] == ["pool.ntp.org"]
    for _, render in gb.FORMATS.values():
        plain = render(sel, gb.Options())
        assert not any("pool.ntp.org" in ln for ln in _rules(plain, plain[0])), render.__name__
    redirected = gb.render_dnsmasq(sel, gb.Options(time_server="192.168.1.53"))
    assert "address=/pool.ntp.org/192.168.1.53" in _rules(redirected)


def test_a_clock_that_is_not_ntp_is_left_reachable():
    """A webOS TV's clock rides an HTTPS API; an NTP server cannot stand in."""
    entries = [E("clock.example.com", roles=("time",), ports=((443, "tcp"),),
                 impact="degraded", effect="The clock resets.")]
    sel = gb.select(entries, "cloud")
    assert sel.time == [] and sel.block == []
    assert [e.host for e in sel.excluded] == ["clock.example.com"]


def test_a_clock_is_never_blocked_whatever_else_it_serves():
    """The `time` role protects the whole entry: LG's SDP is the TV's clock AND
    its Content Store, and a `degraded` there must not put it on a list."""
    entries = [E("sdp.example.com", roles=("time", "content", "api"), match="subdomains",
                 impact="degraded", effect="The clock resets and the store goes.")]
    for profile in gb.PROFILES:
        sel = gb.select(entries, profile)
        assert sel.block == [] and sel.time == []
        assert [e.host for e in sel.excluded] == ["sdp.example.com"]


def test_a_hardcoded_time_server_is_left_reachable_not_firewalled():
    entries = [E(None, address="203.0.113.123", roles=("time",), ports=((123, "udp"),),
                 impact="degraded", effect="Schedules drift.")]
    sel = gb.select(entries, "cloud")
    assert sel.firewall == [] and [e.address for e in sel.excluded] == ["203.0.113.123"]


def test_a_name_one_spec_says_breaks_is_not_blocked_on_anothers_say_so():
    """In a combined list, one device's harmless block is another's broken store."""
    entries = [
        E("shared.example.com", device="dev-a", roles=("telemetry",)),
        E("shared.example.com", device="dev-b", roles=("content",), impact="breaks",
          effect="dev-b's store stops."),
        E("ntp.example.com", device="dev-a", roles=("telemetry",)),
        E("ntp.example.com", device="dev-b", roles=("time",), impact="degraded", effect="Drift."),
    ]
    sel = gb.select(entries, "cloud")
    assert sel.block == []
    assert [r.host for r in sel.time] == ["ntp.example.com"]
    # The NTP guard is explained in the time section, never also as an exclusion.
    assert [e.host for e in sel.excluded] == ["shared.example.com"]
    assert "dev-b's store stops." in gb.render_hosts(sel, gb.Options())


def test_a_breaking_entry_outside_the_profile_still_vetoes():
    """The `updates` profile never selects a `content` host, but a `content`
    host one spec marks `breaks` still forbids blocking the same name as
    another spec's firmware host, and the header says why."""
    entries = [
        E("shared.example.com", device="dev-a", roles=("firmware_download",)),
        E("shared.example.com", device="dev-b", roles=("content",), impact="breaks",
          effect="dev-b's store stops."),
        E("fw.example.com", device="dev-a", roles=("firmware_download",)),
    ]
    sel = gb.select(entries, "updates")
    assert [r.host for r in sel.block] == ["fw.example.com"]
    assert [(e.device, guard.device) for e, guard in sel.vetoed] == [("dev-a", "dev-b")]
    assert [e.host for e in sel.excluded] == ["shared.example.com"]
    text = gb.render_hosts(sel, gb.Options())
    assert not any("shared.example.com" in ln for ln in _rules(text))
    assert "dev-b's store stops." in text
    assert [d for d, _ in sel.devices] == ["dev-a", "dev-b"]


def test_a_device_with_only_a_vetoed_entry_is_still_named_in_the_header():
    """The header explains the veto, so the vetoed device is one the list
    says something about, even with no rule of its own."""
    entries = [
        E("shared.example.com", device="dev-a", roles=("firmware_download",)),
        E("shared.example.com", device="dev-b", roles=("content",), impact="breaks",
          effect="dev-b's store stops."),
        E("fw.example.com", device="dev-b", roles=("firmware_download",)),
    ]
    sel = gb.select(entries, "updates")
    assert [d for d, _ in sel.devices] == ["dev-a", "dev-b"]


def test_a_devices_own_breaking_host_under_its_own_firmware_parent_vetoes_it():
    """The protectors are profile-independent within one spec too: a store
    the spec marks `breaks` under its own firmware `subdomains` parent keeps
    that parent off the updates list, where before only the cloud list saw it."""
    entries = [
        E("example.com", match="subdomains", roles=("firmware_download",)),
        E("store.example.com", roles=("content",), impact="breaks", effect="The store dies."),
    ]
    sel = gb.select(entries, "updates", scope="device 'dev-a'", slug="dev-a")
    assert sel.block == []
    assert [(e.host, guard.host) for e, guard in sel.vetoed] == [("example.com", "store.example.com")]
    assert [e.host for e in sel.excluded] == ["store.example.com"]


def test_a_parent_rule_is_vetoed_by_a_protected_name_under_it():
    """A `subdomains` rule on example.com answers for clock.example.com too.
    The veto is DNS containment, not spelling: one spec's clock (NTP or not)
    takes another spec's parent rule off the list, and the header says so."""
    entries = [
        E("example.com", device="dev-a", match="subdomains", roles=("telemetry",)),
        E("clock.example.com", device="dev-b", roles=("time",), ports=((443, "tcp"),),
          impact="degraded", effect="The clock resets."),
        E("example.net", device="dev-a", match="subdomains", roles=("telemetry",)),
        E("ntp.example.net", device="dev-b", roles=("time",), impact="degraded", effect="Drift."),
        E("other.example.org", device="dev-a", match="subdomains", roles=("telemetry",)),
    ]
    sel = gb.select(entries, "cloud")
    assert [r.host for r in sel.block] == ["other.example.org"]
    assert [(e.host, guard.host) for e, guard in sel.vetoed] == [
        ("example.com", "clock.example.com"),
        ("example.net", "ntp.example.net"),
    ]
    # A guard already excluded (the non-NTP clock) or redirected (the NTP
    # name) is listed once, not again for having vetoed something.
    assert [e.host for e in sel.excluded] == ["clock.example.com"]
    for _, render in gb.FORMATS.values():
        text = render(sel, gb.Options(time_server="192.168.1.53"))
        rules = _rules(text, text[0])
        assert not any("example.com" in ln or "example.net" in ln and "ntp." not in ln for ln in rules), render.__name__
        assert "example.com and subdomains (dev-a) would cover clock.example.com (dev-b)." in text


def test_a_name_under_another_specs_protected_parent_is_vetoed_but_a_carve_out_stands():
    """LG lists lgtvsdp.com (clock, breaks) and rdx2.lgtvsdp.com (telemetry,
    safe) side by side: the same spec's more specific entry is a deliberate
    carve-out. Another spec's name under that parent is not."""
    entries = [
        E("sdp.example.com", device="dev-a", match="subdomains", roles=("time", "content"),
          impact="breaks", effect="The clock resets."),
        E("rdx2.sdp.example.com", device="dev-a", match="subdomains", roles=("telemetry",)),
        E("us.sdp.example.com", device="dev-b", roles=("telemetry",)),
    ]
    sel = gb.select(entries, "cloud")
    assert [r.host for r in sel.block] == ["rdx2.sdp.example.com"]
    assert [(e.host, guard.host) for e, guard in sel.vetoed] == [("us.sdp.example.com", "sdp.example.com")]
    # The header wraps long bullets, so compare against the unwrapped text.
    header = " ".join(ln.lstrip("# ") for ln in gb.render_hosts(sel, gb.Options()).splitlines())
    assert "us.sdp.example.com (dev-b) sits under sdp.example.com and subdomains, which dev-a keeps reachable." in header


def test_a_name_another_spec_carved_out_is_blocked_not_reported_as_vetoed():
    """When the protector's own spec carves a name out, the name is blocked
    whoever else lists it: the header must not call it "not listed" above a
    rule that lists it, and the rule names every device that asked."""
    entries = [
        E("sdp.example.com", device="dev-a", match="subdomains", roles=("time", "content"),
          impact="breaks", effect="The clock resets."),
        E("us.sdp.example.com", device="dev-a", roles=("telemetry",)),
        E("us.sdp.example.com", device="dev-b", device_name="Device B", roles=("telemetry",)),
    ]
    sel = gb.select(entries, "cloud")
    assert [(r.host, r.devices) for r in sel.block] == [("us.sdp.example.com", ("dev-a", "dev-b"))]
    assert sel.vetoed == []
    header = " ".join(ln.lstrip("# ") for ln in gb.render_hosts(sel, gb.Options()).splitlines())
    assert "sits under" not in header


def test_an_exact_carve_out_does_not_answer_for_a_subdomains_entry():
    """The carve-out blocks one name; the other spec asked for everything
    under it too, which the protector still forbids."""
    entries = [
        E("sdp.example.com", device="dev-a", match="subdomains", roles=("time", "content"),
          impact="breaks", effect="The clock resets."),
        E("us.sdp.example.com", device="dev-a", roles=("telemetry",)),
        E("us.sdp.example.com", device="dev-b", match="subdomains", roles=("telemetry",)),
    ]
    sel = gb.select(entries, "cloud")
    assert [(r.host, r.subdomains, r.devices) for r in sel.block] == [("us.sdp.example.com", False, ("dev-a",))]
    assert [(e.device, guard.host) for e, guard in sel.vetoed] == [("dev-b", "sdp.example.com")]


def test_a_device_with_only_exclusions_still_publishes_a_header_only_list():
    """The names that must NOT be blocked are the whole message for a device
    with nothing blockable; an empty selection would never publish them."""
    entries = [E("clock.example.com", roles=("time",), ports=((443, "tcp"),),
                 impact="degraded", effect="The clock resets.")]
    sel = gb.select(entries, "cloud")
    assert not sel.empty and sel.block == [] and sel.time == []
    text = gb.render_pihole(sel, gb.Options())
    assert _rules(text) == [] and "The clock resets." in text
    site = gb.build_site(entries, covered=([], []))
    assert "devices/dev-a/cloud.pihole.txt" in site


def test_a_literal_address_becomes_a_firewall_note_not_a_dns_line():
    entries = [E(None, address="203.0.113.7", ports=((8080, "tcp"),))]
    sel = gb.select(entries, "updates")
    assert sel.block == [] and len(sel.firewall) == 1
    text = gb.render_unbound(sel, gb.Options())
    assert "203.0.113.7 tcp/8080" in text
    assert not any("203.0.113.7" in ln for ln in _rules(text))


def test_a_name_in_two_specs_is_one_rule_with_the_broader_match_and_weaker_trust():
    entries = [
        E("shared.example.com", device="dev-a", verification="confirmed"),
        E("shared.example.com", device="dev-b", match="subdomains", verification="hypothesis"),
    ]
    (rule,) = gb.select(entries, "updates").block
    assert rule.devices == ("dev-a", "dev-b")
    assert rule.subdomains and rule.verification == "hypothesis"


def test_a_costly_block_is_explained_before_the_rules():
    entries = [E("relay.example.com", roles=("device_cloud",), impact="degraded",
                 effect="It reconnects every 10 minutes.", workaround="Unbind it first.")]
    text = gb.render_hosts(gb.select(entries, "cloud"), gb.Options())
    header, _, body = text.partition("0.0.0.0 relay.example.com")
    assert "It reconnects every 10 minutes." in header and "Unbind it first." in header


# ----------------------------------------------------------------------- formats


@pytest.fixture
def mixed() -> gb.Selection:
    """One exact name, one with subdomains, one NTP host."""
    return gb.select(
        [
            E("exact.example.com"),
            E("tree.example.com", match="subdomains"),
            E("time.example.com", roles=("time",), impact="degraded", effect="Drift."),
        ],
        "updates",
    )


REDIRECT = gb.Options(time_server="192.168.1.53")


def test_hosts_blocks_both_families_and_cannot_do_subdomains(mixed):
    lines = _rules(gb.render_hosts(mixed, REDIRECT))
    assert "0.0.0.0 exact.example.com" in lines and ":: exact.example.com" in lines
    assert "0.0.0.0 tree.example.com" in lines  # the name itself, at least
    assert "192.168.1.53 time.example.com" in lines


def test_pihole_uses_only_syntax_gravity_accepts(mixed):
    """Gravity rejects `|name^` and any `$modifier`, and v5 keeps only the last
    name on a line: one plain name or one `||name^` per line, nothing else."""
    lines = _rules(gb.render_pihole(mixed, REDIRECT))
    assert lines == ["exact.example.com", "||tree.example.com^"]
    assert not any("$" in ln or ln.startswith("|") and not ln.startswith("||") for ln in lines)


def test_adguard_distinguishes_exact_from_subdomains_and_rewrites_time(mixed):
    lines = _rules(gb.render_adguard(mixed, REDIRECT), "!")
    assert lines == [
        "|exact.example.com^",
        "||tree.example.com^",
        "|time.example.com^$dnsrewrite=192.168.1.53",
    ]


def test_dnsmasq_exact_names_do_not_take_their_subdomains(mixed):
    lines = _rules(gb.render_dnsmasq(mixed, REDIRECT))
    assert lines == [
        "host-record=exact.example.com,0.0.0.0,::",
        "address=/tree.example.com/",
        "host-record=time.example.com,192.168.1.53",
    ]


def test_unbound_gives_each_redirect_its_own_zone(mixed):
    lines = _rules(gb.render_unbound(mixed, REDIRECT))
    assert lines == [
        'local-data: "exact.example.com. A 0.0.0.0"',
        'local-data: "exact.example.com. AAAA ::"',
        'local-zone: "tree.example.com." always_nxdomain',
        'local-zone: "time.example.com." transparent',
        'local-data: "time.example.com. A 192.168.1.53"',
    ]


def test_routeros_replaces_its_previous_import(mixed):
    lines = _rules(gb.render_routeros(mixed, REDIRECT))
    assert lines[:2] == ["/ip dns static", 'remove [find where comment~"^liberatedbread:all:"]']
    assert lines[2].startswith("add name=exact.example.com type=NXDOMAIN ")
    assert lines[3].startswith("add name=tree.example.com match-subdomain=yes type=NXDOMAIN ")
    assert lines[4].startswith("add name=time.example.com type=A address=192.168.1.53 ")
    assert all('comment="liberatedbread:all: ' in ln for ln in lines[2:])


def test_routeros_imports_for_different_devices_leave_each_other_alone():
    """Per-device lists are the recommended ones, so importing Kasa's and then
    LG's must not delete Kasa's -- including when one id prefixes another."""
    def script(device: str) -> list[str]:
        sel = gb.select([E("fw.example.com", device=device)], "updates", slug=device)
        return _rules(gb.render_routeros(sel, gb.Options()))

    def remove_pattern(lines: list[str]) -> str:
        return re.search(r'comment~"([^"]+)"', lines[1]).group(1)

    def comments(lines: list[str]) -> list[str]:
        return [re.search(r'comment="([^"]+)"', ln).group(1) for ln in lines[2:]]

    short, long = script("lg-webos"), script("lg-webos-2019")
    for own, other in ((short, long), (long, short)):
        assert all(re.search(remove_pattern(own), c) for c in comments(own))
        assert not any(re.search(remove_pattern(own), c) for c in comments(other))


def test_rpz_is_a_loadable_zone(mixed):
    lines = _rules(gb.render_rpz(mixed, REDIRECT), ";")
    assert lines[0] == "$TTL 300" and lines[1].startswith("@ SOA ") and lines[2] == "@ NS localhost."
    assert lines[3:] == [
        "exact.example.com CNAME *.",
        "tree.example.com CNAME .",
        "*.tree.example.com CNAME .",
        "time.example.com A 192.168.1.53",
    ]


def test_a_sinkhole_address_answers_both_families_in_every_format(mixed):
    opts = gb.Options(sinkhole="192.168.1.52")
    assert "host-record=exact.example.com,192.168.1.52,::" in _rules(gb.render_dnsmasq(mixed, opts))
    assert _rules(gb.render_dnsmasq(mixed, opts))[1:3] == [
        "address=/tree.example.com/192.168.1.52",
        "address=/tree.example.com/::",
    ]
    assert 'local-data: "tree.example.com. AAAA ::"' in _rules(gb.render_unbound(mixed, opts))
    assert "|exact.example.com^$dnsrewrite=192.168.1.52" in _rules(gb.render_adguard(mixed, opts), "!")


# ----------------------------------------------------------- the published set


def test_the_published_set_is_deterministic(real_entries):
    assert gb.build_site(real_entries, covered=_COVERAGE) == gb.build_site(real_entries, covered=_COVERAGE)


def test_kasa_updates_list_stops_the_image_and_keeps_the_app(site):
    updates = _rules(site["devices/tplink-kasa-smart-plug/updates.pihole.txt"])
    cloud = _rules(site["devices/tplink-kasa-smart-plug/cloud.pihole.txt"])
    assert "download.tplinkcloud.com" in updates
    assert "n-devs.tplinkcloud.com" not in updates, "the updates profile must keep the relay"
    assert "n-devs.tplinkcloud.com" in cloud
    for listed in (updates, cloud):
        assert "wap.tplinkcloud.com" not in listed, "an app host reached a router list"
        assert not any("ntp.org" in ln or "nist.gov" in ln for ln in listed), "a clock was blocked"


def test_webos_lists_never_block_the_tvs_clock(site):
    for path, text in site.items():
        if path.endswith(".json"):
            continue
        comment = {"adguard": "!", "rpz": ";"}.get(path.rsplit(".", 2)[-2], "#")
        for line in _rules(text, comment):
            for name in ("lgtvsdp.com", "nextlgsdp.com", "ngfts.lge.com"):
                if name in line:
                    assert "rdx2.lgtvsdp.com" in line, f"{path}: {line!r} blocks a clock or the store"


def test_a_spec_whose_hosts_are_all_the_apps_publishes_no_list(site):
    """Roomba's published names are the account route's: listing them would
    break the password route and leave the robot untouched."""
    assert not any(p.startswith("devices/irobot-roomba/") for p in site)


def test_the_index_accounts_for_every_file_and_the_coverage_gap(site):
    index = json.loads(site["index.json"])
    listed = {p for paths in index["files"].values() for p in paths}
    assert listed == set(site) - {"index.json"}
    assert "tplink-kasa-smart-plug" in index["coverage"]["with_egress"]
    assert not set(index["coverage"]["with_egress"]) & set(index["coverage"]["cloud_without_egress"])


def test_write_site_writes_what_build_site_builds(tmp_path, real_entries):
    count = gb.write_site(tmp_path)
    built = gb.build_site(real_entries, covered=_COVERAGE)
    assert count == len(built)
    for rel, content in built.items():
        assert (tmp_path / rel).read_text(encoding="utf-8") == content


def test_the_cli_renders_one_list_with_a_time_redirect(capsys):
    assert gb.main(["--format", "hosts", "--device", "tplink-kasa-smart-plug",
                    "--time-server", "192.168.1.53"]) == 0
    out = capsys.readouterr().out
    assert "192.168.1.53 time.nist.gov" in _rules(out)


def test_the_cli_refuses_an_unknown_device_and_a_bad_address(capsys):
    assert gb.main(["--format", "hosts", "--device", "no-such-device"]) == 2
    with pytest.raises(SystemExit):
        gb.main(["--format", "hosts", "--time-server", "not-an-ip"])


# -------------------------------------------- the resolvers' own checkers, if present


def _render_real(fmt: str, opts: gb.Options) -> str:
    return gb.FORMATS[fmt][1](gb.select(gb.load_entries(specs=_SPECS), "cloud"), opts)


@pytest.mark.skipif(shutil.which("dnsmasq") is None, reason="dnsmasq not installed")
@pytest.mark.parametrize("opts", [gb.Options(), REDIRECT, gb.Options(sinkhole="192.168.1.52")])
def test_dnsmasq_accepts_the_generated_config(tmp_path, opts):
    conf = tmp_path / "blocklist.conf"
    conf.write_text(_render_real("dnsmasq", opts), encoding="utf-8")
    result = subprocess.run(["dnsmasq", "--test", "--conf-file=" + str(conf)],
                            capture_output=True, text=True)
    assert result.returncode == 0, result.stderr


@pytest.mark.skipif(shutil.which("unbound-checkconf") is None, reason="unbound not installed")
@pytest.mark.parametrize("opts", [gb.Options(), REDIRECT, gb.Options(sinkhole="192.168.1.52")])
def test_unbound_accepts_the_generated_config(tmp_path, opts):
    conf = tmp_path / "unbound.conf"
    conf.write_text("server:\n" + _render_real("unbound", opts), encoding="utf-8")
    result = subprocess.run(["unbound-checkconf", str(conf)], capture_output=True, text=True)
    assert result.returncode == 0, result.stdout + result.stderr


@pytest.fixture
def nested() -> gb.Selection:
    """An exact name under another spec's subdomains block, and an exact
    carve-out under a time redirect: both put a name below a zone's apex."""
    return gb.select(
        [
            E("vendor.example.com", match="subdomains"),
            E("fw.vendor.example.com", device="other-device"),
            E("ntp.example.com", match="subdomains", roles=("time",), impact="degraded", effect="Drift."),
            E("rdx.ntp.example.com"),
        ],
        "updates",
    )


def test_unbound_gives_a_name_under_a_zone_its_own_zone(nested):
    lines = _rules(gb.render_unbound(nested, gb.Options(sinkhole="192.168.1.52", time_server="192.168.1.53")))
    for host in ("fw.vendor.example.com", "rdx.ntp.example.com"):
        zone = lines.index(f'local-zone: "{host}." redirect')
        assert lines[zone + 1] == f'local-data: "{host}. A 192.168.1.52"'


@pytest.mark.skipif(shutil.which("unbound-checkconf") is None, reason="unbound not installed")
@pytest.mark.parametrize("opts", [gb.Options(), REDIRECT, gb.Options(sinkhole="192.168.1.52"),
                                  gb.Options(sinkhole="192.168.1.52", time_server="192.168.1.53")])
def test_unbound_accepts_names_nested_under_a_zone(tmp_path, nested, opts):
    conf = tmp_path / "unbound.conf"
    conf.write_text("server:\n" + gb.render_unbound(nested, opts), encoding="utf-8")
    result = subprocess.run(["unbound-checkconf", str(conf)], capture_output=True, text=True)
    assert result.returncode == 0, result.stdout + result.stderr


@pytest.mark.skipif(shutil.which("named-checkzone") is None, reason="bind9-utils not installed")
def test_bind_accepts_the_generated_rpz_zone(tmp_path):
    zone = tmp_path / "rpz.zone"
    zone.write_text(_render_real("rpz", REDIRECT), encoding="utf-8")
    result = subprocess.run(["named-checkzone", "rpz.local", str(zone)], capture_output=True, text=True)
    assert result.returncode == 0, result.stdout + result.stderr
