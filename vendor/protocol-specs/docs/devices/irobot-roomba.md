# iRobot Roomba (Wi-Fi models)

> **Status**: Local protocol documented from public reverse engineering; not replayed against hardware here
> **Protocol**: WiFi (MQTT over TLS, TCP 8883, on the robot itself)
> **Manufacturer**: iRobot — Chapter 11 filed 2025-12-14, acquired by Picea Robotics 2026-01-23
> **Manufacturer Status**: Active (company alive; the local protocol is what's endangered)

## Overview

Wi-Fi Roombas run an **MQTT broker on the robot itself** — TLS on TCP 8883,
username = the robot's BLID, password = a per-device secret you can pull off
the robot without an iRobot account. It is the same channel the vendor app uses
when the phone is on the LAN, so local control is not a scraped-together
fallback: it is the primary interface, and it keeps working with the robot
firewalled off the internet entirely.

!!! info "This is dorita980's work"
    Every byte on this page was recovered by
    [koalazak/dorita980](https://github.com/koalazak/dorita980) (Node.js, MIT) —
    the UDP-5678 discovery probe, the password-disclosure magic packet and its
    reply offsets, the MQTT-over-TLS session, the `cmd`/`delta` vocabulary and
    the account route to the credentials. Its README is the authoritative text;
    this page transcribes it into our format.
    [pschmitt/roombapy](https://github.com/pschmitt/roombapy) carries the same
    protocol into Python and backs Home Assistant's `roomba` integration. If
    you want a *supported, hardware-tested* client, use one of those — this
    document exists to describe the protocol, not to compete with the people
    who worked it out.

Covered generations: **690, 890, 960, 980, e5/e6, i3–i8, j7/j9, s9**, plus the
**Braava jet m6**.

!!! danger "The 2025 line has no local broker"
    Roomba **105 / 205 / Combo 405** — the "V4 protocol" reboot — **refuse**
    connections on 8883. Connection refused, not a timeout: there is nothing
    listening. Cloud credentials are still retrievable, but there is no local
    broker to use them against. Reported against firmware `p25-105` (Home
    Assistant community, 2026-04). If you are buying a robot to control
    locally, buy a 2024-or-earlier model.

!!! warning "One local client at a time"
    The robot accepts a single local MQTT connection, and a new one evicts the
    old. A client that holds the socket open locks the owner out of their own
    app. Connect, read, act, disconnect — that is why Home Assistant's
    integration is `iot_class: local_polling` and why dorita980 tells callers to
    `.end()` after a command.

## Discovery

Broadcast the nine ASCII bytes `irobotmcs` to `255.255.255.255:5678`. Every
iRobot robot on the segment answers to the sender's ephemeral port with a JSON
datagram:

```json
{
  "ver": "3",
  "hostname": "Roomba-3193C60472324700",
  "robotname": "Dorita",
  "ip": "192.168.1.103",
  "mac": "12:12:12:12:12:12",
  "sw": "v2.4.16-126",
  "sku": "R980020",
  "nc": 0,
  "proto": "mqtt"
}
```

`hostname` is the identity carrier: it is `Roomba-<blid>` (or `iRobot-<blid>` on
Braava), so **the BLID is the substring after the first hyphen** — and the BLID
is the MQTT username. A datagram whose hostname starts with neither prefix is
not a robot; the probe reaches every host on the segment, so filter on it.

Send the probe more than once. UDP is lossy, and a dropped datagram is a robot
never found. Robots answer the probe but do not beacon on their own, so a
consumer that only listens finds nothing — the spec's discovery method records
that as `passive_ok: false`.

!!! warning "Port 5678 is shared with MikroTik MNDP"
    MikroTik's neighbour-discovery protocol ([mikrotik-routeros](mikrotik-routeros.md))
    uses the same UDP port, so one broadcast draws replies from both and a
    consumer scanning for either will see the other's datagrams. They are told
    apart by the *shape* of the reply, not by the port: MNDP answers with
    big-endian TLV records, a Roomba with a JSON object whose `hostname` carries
    one of the two prefixes above. A parser that assumes everything arriving on
    5678 is its own protocol will report somebody's router as a robot.

!!! note "There is no mDNS entry here on purpose"
    Robots are reported to be visible on 5353, but nothing this page draws on
    names the service type they advertise — so the spec declares no `mdns`
    discovery method. An earlier revision guessed `_amzn-wplay._tcp`, which is
    Amazon's Whisperplay (Fire TV) and not iRobot at all. A wrong service type
    is worse than a missing one: it sends a client hunting on somebody else's
    protocol and reports their hardware as robots. The UDP broadcast is the
    documented path; if someone captures the real mDNS type, it can be added.

Discovery needs broadcast to reach the robot, so a client-isolated guest SSID
or a VLAN that does not forward broadcast will find nothing even though the
robot is up and its broker is answering — falling back to a known IP is always
valid.

## Getting the password

There are two routes to the same pair of values. **Do this before you firewall
the robot**: the button route is local and unaffected, but the account route
needs both the phone and iRobot's API reachable.

The password is stable — community reports have it changing only on a **factory
reset**. Write it down. It is the same BLID/password pair Home Assistant,
dorita980 and every other local client will ask you for.

### Route 1: the HOME button (no account)

dorita980's `get-roomba-password <ip>`.

1. Put the robot **on its dock**, powered on, and **close the iRobot app** on
   every phone — the robot serves one client at a time.
2. **Hold HOME for about two seconds**, until the robot plays a series of
   tones, then release. The robot is now in password-disclosure mode for a
   short window.
3. Open TLS to `<robot-ip>:8883`. The certificate is self-signed — pin it on
   first sight rather than trying to validate it against a CA.
4. Write the seven-byte probe and read one reply.

| | |
|---|---|
| **Probe** | `f0 05 ef cc 3b 29 00` |
| | `0xf0` — an MQTT reserved packet type<br>`0x05` — payload length<br>`ef cc 3b 29 00` — the payload |
| **Reply** | `[0xf0][length][payload]`. Read until you have `2 + length` bytes. |
| **Extraction** | Drop the 2-byte header, drop any remaining **leading non-printable bytes**, decode the rest as UTF-8, strip trailing NULs. That whole remaining string is the password. |
| **Not in disclosure mode** | A reply **shorter than 8 bytes**. Release, re-hold HOME, retry. |
| **Model can't disclose** | A reply equal to `f0 05 ef cc 3b 29 03`. Use the account route. |

!!! note "Why a rule and not an offset"
    Published clients each hardcode a *different* fixed offset for the same
    reply: roombapy slices at 7 of the whole reply, dorita980 at 13 when the
    socket delivers everything in one read and at 9 when the 2-byte header
    arrives separately. Scanning for the printable run is correct under all
    three, which is why that is what the spec states as the contract and the
    offsets are recorded only as evidence.

!!! warning "That rule is our hypothesis, not anyone's transcription"
    Everything else on this page came out of a working client. The extraction
    rule did not — it was derived by asking what single rule satisfies all
    three offsets, and it assumes **every byte between the header and the
    credential is non-printable**. Nobody has confirmed that against a robot,
    here or upstream. If a firmware puts a printable byte in that gap, the rule
    returns it glued to the front of the password and the only symptom is the
    broker refusing your login.

    A cautious client implements the rule *and* a fixed slice at each observed
    offset, and warns when they disagree. If you hit a robot where they
    disagree, report it to
    [dorita980](https://github.com/koalazak/dorita980) and
    [roombapy](https://github.com/pschmitt/roombapy) — they own this protocol,
    not us.

Keep the **whole** string. A Roomba password looks like
`:1:1486937829:gktkDoYpWaDxCfGh` — it starts with a colon and contains colons,
and clients that "helpfully" split on the first one break.

The reply also carries the BLID, but the UDP-5678 announcement's `hostname` is
the easier read.

!!! note "j-series TLS resets"
    j7-era firmware is reported to reset the TLS connection on the first
    attempt or two before answering. Retry inside the window rather than
    treating one reset as a refusal — the
    [homebridge-roomba](https://github.com/homebridge-plugins/homebridge-roomba)
    issue tracker is the best public record of the timings that get past it.

!!! warning "Legacy TLS ciphers"
    Older firmware negotiates only `AES128-SHA256`
    (`TLS_RSA_WITH_AES_128_CBC_SHA256`) and expects legacy renegotiation.
    Runtimes whose TLS stack has retired that suite — anything on BoringSSL,
    which includes Dart and Chromium — **cannot complete the handshake at
    all**, and fail before the probe is written. dorita980 works around it with
    the `ROBOT_CIPHERS` and `ROBOT_TLS_LEGACY` environment variables. A client
    that cannot select ciphers should say so plainly rather than reporting the
    robot as unreachable.

### Route 2: the iRobot account (credential extraction only)

dorita980's `get-roomba-password-cloud <email> <password>`. Use this when the
button handshake will not complete. It returns the **same** BLID and password
the local route would have — nothing about steady-state control needs an
account.

1. `GET https://disc-prod.iot.irobotapi.com/v1/discover/endpoints?country_code=<CC>`
   for the regional Gigya API key and the two base URLs.
2. `POST {gigyaBase}/accounts.login` with the account email and password →
   `UID`, `UIDSignature`, `signatureTimestamp`.
3. `POST {httpBase}/v2/login` with that assertion and the client's `app_id` →
   a **`robots`** map **keyed by BLID**, each entry carrying `password`,
   `name`, `sku` and `softwareVer`.

Treat the account password as write-never: use it for the one login call and
keep nothing. Store `password` against `blid`, discard the Gigya assertion.

## The local MQTT session

| | |
|---|---|
| **Transport** | MQTT 3.1.1 over TLS, TCP **8883**, on the robot |
| **Certificate** | Self-signed. Pin it; do not expect a CA chain. |
| **Client ID** | The BLID |
| **Username** | The BLID |
| **Password** | The extracted per-robot secret |
| **Ciphers** | `AES128-SHA256` on older firmware; newer firmware negotiates TLS 1.3 suites |

Subscribe to `#` after connecting: it picks up `delta` and the shadow topics in
one go, which saves guessing which topic shape a given firmware publishes
locally.

## Commands

Publish to the **`cmd`** topic. The payload is a JSON envelope:

```json
{"command":"clean","time":1755129600,"initiator":"localApp"}
```

`time` is Unix epoch seconds from **the sender's** clock at the moment of
sending — that is how every published client fills it. What the robot does with
the value is undocumented and untested here, so send a real timestamp rather
than a constant. `initiator` is `localApp` for a LAN client.

| `command` | Meaning |
|---|---|
| `clean` | Start or resume a full cleaning mission. `start` is accepted as a synonym. |
| `pause` | Pause the mission; the robot stays where it is. |
| `stop` | End the mission. The robot stops and **stays put** — it does not go home. |
| `resume` | Resume a paused mission. |
| `dock` | Return to the dock. **Only accepted from a paused or stopped state**, which is why a single "send home" button sends `stop` then `dock`. |
| `find` | Beep so you can find the robot under the sofa. Silent while docked. |

## State

The robot pushes changes to **`delta`** as `{"state":{"reported":{...}}}`, and
publishes the full shadow to an `$aws/things/<blid>/shadow/update`-shaped topic.
The fields worth binding:

| Path under `state.reported` | Type | Meaning |
|---|---|---|
| `batPct` | integer % | Battery charge |
| `cleanMissionStatus.phase` | string | `charge`, `run`, `stop`, `hmUsrDock` (going home on request), `hmMidMsn` (going home to recharge), `hmPostMsn` (going home, mission done), `evac`, `stuck` |
| `cleanMissionStatus.cycle` | string | `none`, `clean`, `spot`, `evac`, `dock` |
| `bin.full` | boolean | Bin needs emptying |
| `bin.present` | boolean | False when the bin has been removed |
| `name` / `sku` / `softwareVer` | string | Identity, model, firmware |

Newer firmware in this generation **stops reporting the robot's x/y `pose`**.
Bind mission phase, not position.

## Keep it off the internet

The single biggest risk to everything on this page is an over-the-air firmware
update that removes the local broker — which is exactly what happened to the
2025 models. dorita980's README has said so for years: block the robot's
internet access.

What you lose by blocking it: remote (off-LAN) control from the vendor app,
cloud-side scheduling, map sync on the mapping models, and OTA updates. What
keeps working: everything in this document.

The hosts to block are in the spec's `cloud.hosts`, marked `reported` rather
than `confirmed` — this project has not captured a robot's DNS traffic, so log
the robot's own lookups at your router for a day before trusting any blocklist.
A step-by-step guide for UniFi, MikroTik and the other common home platforms is
at [liberatedbread.com/firewall/](https://liberatedbread.com/firewall/).

**Order matters**: extract the credentials *first*. The account route stops
working the moment the robot or the phone is cut off.

## Setup and reset

**Initial provisioning** (getting a factory-fresh robot onto Wi-Fi) is a vendor
app job and is not documented outside iRobot. What a third-party client needs
is the credential extraction above, which applies to an already-provisioned
robot.

**Factory reset** clears the Wi-Fi credentials and the cloud registration, and
— importantly — **mints a new local password**. A robot reset since you wrote
its password down will refuse the old one. Maps and mission history are lost on
the models that keep them.

- **600/800/900 series**: hold `DOCK` + `SPOT Clean` + `CLEAN` together until
  the robot signals the reset, then release.
- **i/j/s series**: hold `HOME` + `SPOT Clean` + `CLEAN` together until the
  ring swirls clockwise, then release.

!!! warning "Holding CLEAN alone is a reboot, not a reset"
    It restarts the robot and changes nothing else. That distinction matters
    more here than it usually would: this page tells you a reset mints a new
    password, so someone who reboots believing they reset will either wait for
    a credential change that never comes, or decide their saved password is
    dead and redo the whole handshake for nothing. Both procedures above are
    multi-button holds for exactly that reason.

**Rebinding to a new router** does not need a factory reset. A provisioned
robot can be put back into Wi-Fi setup mode and pointed at the new network —
vendor-documented and widely reported, though not replayed here, so treat it as
low confidence and be ready to fall back to a reset.

The useful consequence: **if the move doesn't reset the robot, the password
survives it.** A credential you saved before changing routers keeps working —
which is why anything storing one should key it on the BLID rather than on the
address the robot happened to have.

## References

- [koalazak/dorita980](https://github.com/koalazak/dorita980) — the reference
  implementation and the origin of everything here (MIT)
- [koalazak/rest980](https://github.com/koalazak/rest980) — REST interface over
  dorita980, the easiest way to exercise the protocol by hand
- [pschmitt/roombapy](https://github.com/pschmitt/roombapy) — the Python
  implementation; backs Home Assistant's `roomba` integration
- [Home Assistant — Roomba integration](https://www.home-assistant.io/integrations/roomba/)
  (`iot_class: local_polling`)
- [NickWaterton/Roomba980-Python](https://github.com/NickWaterton/Roomba980-Python)
  — an independent reading of the same password handshake
- [homebridge-plugins/homebridge-roomba](https://github.com/homebridge-plugins/homebridge-roomba)
  — where the j-series TLS-reset behaviour is recorded

## Contributors

- Protocol: [@koalazak](https://github.com/koalazak) (dorita980),
  [@pschmitt](https://github.com/pschmitt) (roombapy) and the contributors to
  both — all of the reverse engineering
- This transcription: Liberated Bread

Machine-readable spec: `device-specs/devices/irobot-roomba.yaml`
