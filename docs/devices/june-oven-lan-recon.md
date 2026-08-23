# June Oven: LAN and IP-level recon

The June oven's Bluetooth path is closed — the radios exist, the intent existed,
the firmware does not (see `targets/june-oven.md`). What remains is the network.
This page is the IP-level playbook: what the oven exposes, what it can be made to
talk to, and — the part that reorders everything — which experiments are actually
racing the 2026-09-22 cloud shutdown and which are not.

## The shape of the problem

The oven is a **pure outbound client**. It is an Android appliance with Wi-Fi
only — no Ethernet jack, no external USB, soldered eMMC, and ADB and terminal
access removed in its shipped "user" mode. It dials two hosts over TLS, uploads
JPEG stills, and listens (as far as anyone knows) on nothing.

So "local Ethernet adventures" does not mean plugging into the oven. It means
**putting the oven behind a gateway you own and can tap.** That is the whole
bench rig, and it is cheap:

```
oven ──Wi-Fi──> [ Pi / OpenWRT / travel router ]──Ethernet──> your LAN ──> internet
                   ^ hostapd + dnsmasq + tcpdump
                   ^ this is where every experiment below happens
```

Anything that can be an access point and run `tcpdump` works. The oven joins
your AP instead of the house Wi-Fi (its Wi-Fi credentials are typed on its own
touchscreen), and from that moment you see every packet it sends.

## The correction that should reorder your schedule

The prevailing plan treats the certificate-pinning experiment as the urgent item,
to be run before the cloud dies. **That is backwards.** Sort the work by what
actually needs a living June server:

| Experiment | Needs a live June cloud? | Why |
|---|---|---|
| Passive capture (DNS, SNI, NTP, cadence) | **Yes** | You are recording a real session. Once the servers are gone there is no session to record |
| OTA manifest / firmware URL capture | **Yes** | The update server has to answer |
| Provisioning / first-boot flow | **Yes** | Same |
| Pairing flow, recipe catalog | **Yes** | Same |
| **Port scan** | No | The oven is the target |
| **DNS redirect + TLS presentation** | **No** | You answer the DNS query yourself; the oven never touches Weber |

The pinning experiment only needs the oven to *dial*. In a DNS-redirect bench you
are the DNS server, you are the endpoint, and Weber is not in the path at all.
An appliance that has lost its cloud keeps retrying essentially forever, and a
power cycle re-triggers it — so this experiment stays runnable in October, in
January, in 2028.

**Therefore: if you have an oven and 46 days, spend them capturing, not
pinning.** Capture is the perishable half. The one caveat worth checking rather
than assuming: confirm after the shutdown that the oven still dials — retry
backoff may lengthen, and firmware that gives up permanently after N failures
would close the window after all. Tier 0 below tells you, passively, for free.

## Tier 0 — Passive. Do this first, do it now.

Zero packets sent to the oven. Highest value per minute of anything on this page,
and the only tier with a real deadline.

```bash
tcpdump -i br0 -s0 -w june-$(date +%F).pcap host <oven-ip>
```

Leave it running for a full 24 hours, across at least one overnight window
(updates download "usually overnight"), one cook, and one reboot. What to pull
out of it:

**DNS queries — the single most valuable artifact.** The complete list of hosts
the oven contacts. This is *not* the same as the list in the companion APK, and
that difference is the point: static analysis of the app found no "firmware",
"OTA" or "amazonaws.com" strings, because firmware delivery is oven-side. The
APK cannot tell you the update host. **The oven's own DNS traffic can, and
nothing else can.** No one has ever published it.

**TLS SNI.** Cleartext in every ClientHello. Confirms the host list per
connection without decrypting anything.

**NTP — the under-appreciated one.** Watch for it, and note where it goes.
Certificate validation needs a roughly correct clock, and Weber's own FAQ says
the oven's clock is cloud-dependent (the display stays blank without Wi-Fi
rather than showing a time). Two consequences nobody has written down:

- If the oven takes time from June's cloud rather than public NTP, then after
  2026-09-22 its clock may be wrong on every boot — and TLS to *any* replacement
  server could fail with `certificate_expired` or `certificate_not_yet_valid`,
  for reasons that have nothing to do with pinning. A replacement cloud might
  need to answer NTP too.
- Conversely, a device that boots with an unset clock often skips expiry
  checking entirely, which would *help*.

Either way it is decided by one `grep` over a pcap, and it changes what a
replacement server has to implement. Do it early.

**DHCP.** The hostname the oven requests, its option-55 parameter list, and any
vendor class identifier. These are stable per-firmware fingerprints and they
belong in the spec's `device.identification`. Also record the MAC OUI — it names
the Wi-Fi module vendor and distinguishes generations.

**Cadence and sizes.** Keepalive interval, camera-upload rate and JPEG size, how
often it checks for updates, and what it does when the network is removed.
Timing is protocol evidence you can gather without breaking a single cipher.

## Tier 1 — Active scan. Cheap, safe, expected to find nothing.

```bash
python scripts/june_discover.py --address <oven-ip> --json
```

Included in this repo. It probes the ports that are here for a reason —
including **8156**, the single unverified community report that has been the only
local-path lead on record, and **5555**, ADB-over-TCP, which is reported removed
but costs one packet to check. It distinguishes *refused* from *timed out*,
because "the oven answered and is listening on nothing" is a far stronger result
than "packets vanished", and it prints the negative as a finding rather than an
error.

Follow with a full sweep if you have nmap, which is better at this than we are:

```bash
nmap -p- -sV --reason <oven-ip>
sudo nmap -sU --top-ports 200 <oven-ip>
```

Also worth ten minutes: browse mDNS (`--mdns`), and watch during a factory reset
for a SoftAP appearing — June's own open-source-licenses page lists an Android
`accesspoint` library, which hints the firmware *can* raise an AP even though no
provisioning flow uses one. SSDP is not covered by this script: TCP 1900 is in
the port list, but a UDP multicast announcement will not show up in a connect
scan, so use `sudo nmap -sU -p1900` or a passive listener for that.

**Publish whatever you get, including nothing.** A documented negative from a
named generation and firmware version is a real contribution here; the current
state of the art is one person's unverified recollection of a port number.

**Sanitize first — the output is not publishable verbatim.** The scan emits the
address you gave it and the target's reverse-DNS name, both of which are yours
rather than June's. Replace them with the placeholders in
[`docs/CLEANROOM_RULES.md`](../CLEANROOM_RULES.md) before pasting the result
anywhere. The mDNS browse deliberately withholds records that are not oven
candidates — an unfiltered browse returns every printer, TV and speaker on your
segment, complete with hostnames and serial-shaped TXT keys — so publish the
withheld *count*, never the records themselves.

## Tier 2 — DNS redirect and the TLS ladder

The decisive experiment, and per the correction above, the one that can wait.

Point the oven's DNS at your own resolver and answer `messaging.junelife.com`
and `api.junelife.com` with your bench box:

```
# dnsmasq
address=/junelife.com/192.168.8.1
log-queries
```

Then present certificates in increasing order of plausibility and record what
happens at each step. **Log the TLS alert, not just "it failed"** — the alert
distinguishes the failure modes, and they lead to different projects:

| Step | Present | If accepted | If rejected |
|---|---|---|---|
| 0 | Plain TCP, no TLS | It does not use TLS at all (implausible, but it is one line to rule out) | Expected |
| 1 | Self-signed cert for the June names | No validation whatsoever | Expected |
| 2 | Private-CA chain minted for the June names | Validates a chain but not against a public root — **a community CA works**, redirect is viable | Continue |
| 3 | Publicly trusted cert for a domain **you** control | No hostname enforcement — any trusted cert works | Continue |
| 4 | Both rejected | — | Pinning confirmed. Falls back to a local channel (Tier 1's 8156) or firmware, which is a much harder project |

Read the alerts: `unknown_ca` means chain validation, `bad_certificate` or
`handshake_failure` after a good chain suggests pinning, and
`certificate_expired` points at the clock problem from Tier 0 rather than at
trust. Note also that whether a confirmed pin is leaf- or CA-anchored is **not**
decidable from outside — both look identical from the client side — and it does
not change what you do next, so do not spend time on it.

No public certificate authority will ever issue for `junelife.com` to the
community, because Weber controls the domain. Step 2's private CA is the
realistic best case, not a publicly trusted cert for the real names.

## Tier 3 — What a redirect buys before it buys control

Even with pinning confirmed and no path to control, the redirect is not wasted:

- **Sinkhole.** Pointing `junelife.com` at a black hole stops the oven burning
  cycles on a dead endpoint, and — the thing several owners actually want — stops
  it taking any further firmware update. Before recommending this to anyone,
  check how the oven degrades when it can reach nothing at all: an appliance that
  retries politely is fine, one that reboots in a loop is not.
- **Behavioural baseline.** How the oven acts against a server that accepts TCP
  but speaks nonsense tells you about its error handling and retry policy, which
  a replacement server has to survive.

## What this does not touch

Firmware. Every tier above is observation and redirection of network traffic to a
device the operator owns, on a network they own. Nothing here modifies the oven,
and nothing here goes near the 1 Hz cook-control loop or its temperature-limiting
hardware, which stay sovereign on the device. The `10020` ack vocabulary
(`door-open`, `not-ready`, `cleaning`) is the protocol's own safety channel and
is reimplemented verbatim, never loosened. See `docs/CLEANROOM_RULES.md`.

Do not publish captures without sanitizing them: a pcap of a pairing session
contains a bearer token and, potentially, key material. The same applies to
anything else a recon session produces — scan output, mDNS records, screenshots,
DHCP lease tables — which carry your addresses, hostnames and serials rather than
the device's. Scrub before pushing; see [`docs/CLEANROOM_RULES.md`](../CLEANROOM_RULES.md).

## Consequences for the device spec

Whatever the scan returns, it lands in `device-specs/devices/june-oven.yaml`:

- `device.discovery` should state, machine-readably, that there is **nothing to
  find on the LAN**, so consumers stop probing for it.
- `device.identification` carries the DHCP hostname pattern and MAC OUI from
  Tier 0 — real identification signals, unlike the speculative port 8156, which
  belongs in `notes` as a hypothesis until Tier 1 settles it.
- `local_access.status` stays `none_known` until something answers. If Tier 1
  finds an open port that speaks anything useful, that is the finding that
  changes this device's story — and the mobile app's plan along with it.
