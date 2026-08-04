#!/usr/bin/env python3
# Copyright 2026 Pigs Can Fly Labs LLC
# SPDX-License-Identifier: Apache-2.0
#
# Host-side screenshot endpoint for the scripted simulator walkthrough
# (integration_test/e2e_walkthrough_test.dart).
#
# The walkthrough runs inside the app on the iOS Simulator, so it cannot shell
# out to `xcrun simctl`. Instead it issues a blocking HTTP request to this
# server between steps; the server captures the simulator's framebuffer while
# the app is paused, so every PNG is the exact frame the assertion just checked.
#
# Usage:
#   E2E_SHOT_DIR=~/e2e_jun24 E2E_UDID=<udid> python3 scripts/e2e_shot_server.py
#
#
# It also serves a small device-spec pack under /pack/, so the walkthrough can
# exercise a *successful* remote spec-pack install without depending on any
# third-party host being up.
#
# Environment:
#   E2E_SHOT_DIR   output directory for PNGs (default: ./e2e-shots)
#   E2E_UDID       simulator UDID, or "booted" (default: booted)
#   E2E_SHOT_PORT  listen port on 127.0.0.1 (default: 8099)

import os
import re
import subprocess
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs, urlparse

OUT_DIR = os.path.expanduser(os.environ.get("E2E_SHOT_DIR", "./e2e-shots"))
UDID = os.environ.get("E2E_UDID", "booted")
PORT = int(os.environ.get("E2E_SHOT_PORT", "8099"))

# Smallest byte count we will accept as a real frame of app UI.
#
# `simctl screenshot` exits 0 and writes a perfectly valid PNG even when the
# window is blank, black, or has not composited a frame yet — so "the file
# exists" proves nothing. Size is the discriminator: a flat-colour 1170x2532
# PNG compresses to a few KB, while real frames from this app run 100-300 KB.
# 20 KB sits an order of magnitude below every real frame and an order of
# magnitude above any blank one.
MIN_FRAME_BYTES = int(os.environ.get("E2E_MIN_FRAME_BYTES", "20000"))

# Wall-clock ceiling for one `simctl screenshot`. This server is single
# threaded and the walkthrough blocks on each request, so an unbounded capture
# against a wedged simulator would hang the whole run with no diagnostic. A
# real capture takes well under a second; 30 s is "something is broken".
CAPTURE_TIMEOUT_S = 30

# Screenshot names come from the test and are pasted straight into a filesystem
# path, so keep them to a boring alphabet.
SAFE_NAME = re.compile(r"^[A-Za-z0-9_.-]{1,80}$")

# A tiny but complete spec pack, served from /pack/ so the walkthrough can
# install one for real. Mirrors assets/device_specs/example-bulb.yaml's shape.
PACK_MANIFEST = (
    '{"name": "E2E Demo Pack", "version": "1.0.0", "specs": ["demo-plug.yaml"]}'
)

PACK_SPEC = """\
device:
  name: "E2E Demo Plug"
  manufacturer: "Walkthrough Fixtures"
  manufacturer_status: "abandoned"
  protocol: "ble"
  identification:
    local_name_prefix: "E2EPLUG_"
    service_uuids:
      - "0000fe10-0000-1000-8000-00805f9b34fb"

services:
  - uuid: "0000fe10-0000-1000-8000-00805f9b34fb"
    name: "Plug Control"
    characteristics:
      - uuid: "0000fe11-0000-1000-8000-00805f9b34fb"
        name: "Relay"
        properties: ["write"]
        commands:
          relay_on:
            description: "Close the relay"
            value: [0x10, 0x01]
          relay_off:
            description: "Open the relay"
            value: [0x10, 0x00]
      - uuid: "0000fe12-0000-1000-8000-00805f9b34fb"
        name: "Power"
        properties: ["read", "notify"]
        format:
          - offset: 0
            length: 1
            name: "relay_state"
            type: "bool"
          - offset: 1
            length: 1
            name: "watts"
            type: "uint8"
"""


class ShotHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_GET(self):  # noqa: N802 (http.server API)
        parsed = urlparse(self.path)
        if parsed.path == "/pack/pack.json":
            self._reply(200, PACK_MANIFEST.encode(), "application/json")
            return
        if parsed.path == "/pack/demo-plug.yaml":
            self._reply(200, PACK_SPEC.encode(), "text/yaml")
            return
        if parsed.path != "/shot":
            self._reply(404, b"no")
            return

        name = (parse_qs(parsed.query).get("name") or ["shot"])[0]
        if not SAFE_NAME.match(name):
            self._reply(400, b"no")
            return

        path = os.path.join(OUT_DIR, name + ".png")

        # Drop any PNG left by an earlier run *before* capturing. `simctl` does
        # not truncate the target when it fails, so a stale file would still be
        # sitting there at full size and would pass every check below as if it
        # were the frame we just asked for.
        try:
            os.unlink(path)
        except FileNotFoundError:
            pass

        try:
            proc = subprocess.run(
                ["xcrun", "simctl", "io", UDID, "screenshot", "--type=png", path],
                capture_output=True,
                timeout=CAPTURE_TIMEOUT_S,
            )
        except subprocess.TimeoutExpired:
            # 500, not 422: a wedged simctl means *this server* can no longer
            # do its job, which is a different failure from a bad frame. The
            # timeout is what keeps that from hanging the walkthrough forever,
            # since this server handles one request at a time.
            reason = f"capture timed out after {CAPTURE_TIMEOUT_S}s (simctl hung?)"
            print(f"[shot] {name} BAD bytes=0 -- {reason}", flush=True)
            self._reply(500, reason.encode())
            return

        size = os.path.getsize(path) if os.path.exists(path) else 0

        if proc.returncode != 0 or size == 0:
            detail = proc.stderr.decode().strip() or "no file written"
            reason = f"capture failed ({detail})"
        elif size < MIN_FRAME_BYTES:
            # A PNG of a blank, black, or not-yet-composited frame is a valid
            # PNG — returncode 0, non-zero size — so size is the only cheap
            # signal that the capture is real. Rejecting here is the point:
            # a harness that accepts a blank frame proves nothing.
            reason = (
                f"frame too small: {size} bytes < {MIN_FRAME_BYTES} floor "
                f"(blank/black screen?)"
            )
        else:
            reason = None

        print(
            "[shot] {} {} bytes={}{}".format(
                name,
                "ok" if reason is None else "BAD",
                size,
                "" if reason is None else f" -- {reason}",
            ),
            flush=True,
        )
        if reason is None:
            self._reply(200, b"ok")
        else:
            # 422, not 500: the server is healthy, the *frame* is not. The
            # walkthrough treats this as a hard failure, whereas a connection
            # error (server not running) is tolerated.
            self._reply(422, reason.encode())

    def _reply(self, code, body, content_type="text/plain"):
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args):  # noqa: A002 — http.server API
        pass  # silence per-request access logging


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    print(f"[shot] serving on 127.0.0.1:{PORT}, writing to {OUT_DIR} "
          f"(device {UDID})", flush=True)
    try:
        HTTPServer(("127.0.0.1", PORT), ShotHandler).serve_forever()
    except KeyboardInterrupt:
        print("[shot] stopped", flush=True)
        sys.exit(0)


if __name__ == "__main__":
    main()
