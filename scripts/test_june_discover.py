#!/usr/bin/env python3
# Copyright 2026 Pigs Can Fly Labs LLC
# SPDX-License-Identifier: Apache-2.0
"""Tests for scripts/june_discover.py.

The interesting logic here is interpretation, not I/O: this script's job is to
turn a scan of a device that listens on nothing into sentences a spec author can
use, and to tell a strong negative (refused) apart from a weak one (timed out).
"""

import socket
import sys
import threading
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import june_discover  # noqa: E402


def _result(*ports: tuple[int, str]) -> june_discover.ReconResult:
    return june_discover.ReconResult(
        address="192.0.2.10",
        ports=[june_discover.PortResult(port=p, state=s, reason="") for p, s in ports],
    )


def test_all_refused_is_a_strong_negative():
    notes = june_discover.interpret(_result((80, "closed"), (443, "closed")))
    joined = " ".join(notes)
    assert "STRONG negative" in joined
    assert "none_known" in joined


def test_all_timed_out_is_only_a_weak_negative():
    notes = june_discover.interpret(_result((80, "filtered"), (443, "filtered")))
    joined = " ".join(notes)
    assert "weak negative" in joined
    assert "STRONG negative" not in joined


def test_port_8156_open_is_called_out():
    notes = june_discover.interpret(_result((8156, "open")))
    joined = " ".join(notes)
    assert "8156 is OPEN" in joined


def test_port_8156_closed_is_reported_without_overclaiming():
    notes = june_discover.interpret(_result((8156, "closed"), (80, "closed")))
    joined = " ".join(notes)
    # A single unit not answering does not disprove the community report.
    assert "not reproduced" in joined
    assert "One host is not the whole fleet" in joined


def test_open_adb_is_flagged_against_the_documented_claim():
    notes = june_discover.interpret(_result((5555, "open")))
    joined = " ".join(notes)
    assert "ADB over TCP is OPEN" in joined
    assert "contradicting" in joined


def test_open_ports_property():
    result = _result((80, "closed"), (8156, "open"), (443, "filtered"))
    assert result.open_ports == [8156]


def test_empty_scan_produces_no_notes():
    assert june_discover.interpret(june_discover.ReconResult()) == []


def test_probe_port_detects_an_open_port_and_reads_a_banner():
    """A real loopback listener, so the socket path itself is covered."""
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(("127.0.0.1", 0))
    server.listen(1)
    port = server.getsockname()[1]

    def serve() -> None:
        conn, _ = server.accept()
        conn.sendall(b"JUNE-TEST\r\n")
        conn.close()

    thread = threading.Thread(target=serve, daemon=True)
    thread.start()

    result = june_discover.probe_port("127.0.0.1", port, timeout=3.0)
    thread.join(timeout=5)
    server.close()

    assert result.state == "open"
    assert result.banner == "JUNE-TEST"


def test_probe_port_reports_a_refused_port_as_closed():
    """Bind and immediately close, so the port is reachable but unserved."""
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.bind(("127.0.0.1", 0))
    port = sock.getsockname()[1]
    sock.close()

    result = june_discover.probe_port("127.0.0.1", port, timeout=3.0)
    assert result.state == "closed"


def test_default_ports_cover_the_leads_that_motivated_the_script():
    assert 8156 in june_discover.DEFAULT_PORTS
    assert 5555 in june_discover.DEFAULT_PORTS


def test_unrelated_mdns_records_are_withheld():
    """The browse has to be unfiltered; the output must not be.

    A meta-query returns every service type on the segment, so the raw result is
    an inventory of the operator's LAN — hostnames, DHCP addresses, serial-shaped
    TXT keys. This script's output is meant to be publishable verbatim, so only
    oven candidates may survive.
    """
    printer = {
        "name": "Brother HL-L2350DW",
        "service_type": "_ipp._tcp.local.",
        "hostname": "BRW001122334455.local.",
        "address": "192.0.2.31",
        "txt": {"UUID": "e3248000-80ce-11db-8000-001122334455"},
    }
    assert not june_discover.looks_like_oven(printer, address="192.0.2.10")


def test_the_scanned_host_always_qualifies():
    """Whatever the target announces is the finding, named like an oven or not."""
    record = {"name": "unnamed-thing", "service_type": "_http._tcp.local.", "address": "192.0.2.10"}
    assert june_discover.looks_like_oven(record, address="192.0.2.10")


def test_a_named_oven_qualifies_without_a_target_address():
    """--mdns-only has no address to match on, so the name has to carry it."""
    record = {"name": "June Oven 1234", "service_type": "_http._tcp.local.", "address": "192.0.2.77"}
    assert june_discover.looks_like_oven(record, address="")


def test_a_mixed_scan_is_a_weak_negative_not_a_strong_one():
    """Nine refusals and one timeout is not "every port timed out"."""
    ports = [(p, "closed") for p in (22, 23, 53, 80, 443, 1883, 5683, 8080, 8443)]
    notes = june_discover.interpret(_result(*ports, (9009, "filtered")))
    joined = " ".join(notes)
    assert "Every port timed out" not in joined
    assert "STRONG negative" not in joined
    assert "1 of 10 ports timed out" in joined


def test_all_timed_out_still_reads_as_the_weak_negative():
    notes = june_discover.interpret(_result((80, "filtered"), (443, "filtered")))
    assert "Every port timed out" in " ".join(notes)


def test_a_browse_that_never_ran_is_not_a_protocol_negative():
    """The distinction MdnsOutcome exists for.

    An absent zeroconf package used to arrive at main() as an empty list and get
    printed as "the oven has never been observed to announce itself".
    """
    outcome = june_discover.MdnsOutcome(status="unavailable", detail="no zeroconf")
    assert outcome.records == []
    assert outcome.status != "ok"
