# Furbo Dog Camera

> **Status**: Spec Available
> **Protocol**: WiFi (ThroughTek TUTK/Kalay P2P over UDP); BLE for Wi-Fi onboarding
> **Manufacturer**: Tomofun Co., Ltd.
> **Manufacturer Status**: Active (cloud-dependent; alerts and clips need a Furbo Nanny subscription)

## Overview

Furbo is a Wi-Fi pet camera with two-way audio and a treat launcher. The 360
models also pan. Tomofun sells a Furbo Nanny subscription for cloud alerts,
clips, captions and daily summaries.

Current models use **ThroughTek TUTK/Kalay P2P** for video, microphone,
talkback, settings, pan and treat toss; the app exposes no RTSP or ONVIF
client. Independently published hardware research did establish RTSP on the
older Furbo 2, so there is no family-wide "no RTSP" rule. A client on the
camera's subnet finds it
by UDP broadcast and gets a LAN-mode session. Otherwise the session goes direct
P2P through NAT, or through a Kalay relay. The catch is the credential: a
client must log in to the Furbo cloud to get one. The cloud issues a new key on
every fetch, and each new key stops the previous one working.

Setup is a BLE flow in the vendor app. It is not just a Wi-Fi handover: once
the camera is on the network it asks for registration data and registers
itself with the Furbo cloud.

The spec, [`device-specs/devices/furbo-dog-camera.yaml`](https://github.com/liberatedbread/liberatedbread-protocol-specs/blob/main/device-specs/devices/furbo-dog-camera.yaml),
records three things:

- the P2P session, both IOCTRL opcode sets and the audio/video formats, from the
  MIT-licensed [ha-furbo](https://github.com/willbeeching/ha-furbo) project,
  which verified them on a Furbo 360 (FB0030, firmware 108)
- how the cloud issues the P2P credential, from the same project
- the BLE onboarding protocol, from our own static analysis of the vendor app
  (7.83.1)

Nobody on this project has driven a Furbo from the spec. The research store
holds no capture and no firmware. The spec is `identify_only`: the schema has no
transport for TUTK IOCTRL yet, so the opcode tables live in `protocol_details`
rather than as executable `commands`. The TUTK transport itself needs the
vendor SDK or a clean reimplementation such as go2rtc's
[pure-Go TUTK package](https://pkg.go.dev/github.com/AlexxIT/go2rtc/pkg/tutk).
The [Wyze Cam page](wyze-bridge-camera.md) covers the same transport family.

**Out of scope:** the cloud REST API beyond the credential flow, the cloud
treat-toss endpoint, AI, alert and Nanny features, and OTA updates.

!!! warning "The treat launcher dispenses real food"
    One toss fires one treat across the room. The vendor app sends one toss per
    button press, and that is all the spec documents. If you script tossing,
    rate-limit it and keep a person watching the live view. Repeated tossing can
    overfeed a pet, and a jam or an empty hopper is not reported reliably enough
    to trust an unattended loop.

!!! note "Privacy"
    This is an always-on camera and microphone. Barking, crying, person, smoke
    alarm and activity alerts, clips, captions and summaries all come from the
    vendor's cloud, so the audio and video they are built from leave the house.
    The app also asks the owner to label its detections, which trains the
    vendor's models. At setup it writes the phone's latitude and longitude to
    the camera.

## Hardware

| Property | Value |
|----------|-------|
| Model Number | Sticker models (vendor table): `Furbo2`, `Furbo2.5` (Furbo Dog Camera), `Furbo3` (Dog Camera 360), `FurboCat` (Cat Camera 360), `FurboMini`. Cloud ProductIds: FB001, FB002, FB0025, FB0030, FB0035, FBC0030, FBC0035, MC0010, MC0020, MC0030. Only FB0030 = Furbo 360 is established; every other mapping is a hypothesis |
| Chipset | Furbo 2: Ambarella S2Lm. Furbo Mini: Augentix. Both from Somerset Recon's teardowns, not checked here. Furbo 360: not identified |
| Radio | 2.4 GHz Wi-Fi (802.11b/g/n, US channels 1–11) and BLE. The Mini shares one dipole antenna between them (FCC leaflet) |
| Power | 5 V 2 A (Furbo2.5T label) |
| FCC ID | [`2AIBVTFFBV3`](https://fccid.co/fcc/2AIBVTFFBV3) (Furbo Dog Camera, model Furbo2.5T, granted 2020-07-30); [`2AIBV-MINICAM`](https://fccid.co/fcc/2AIBV-MINICAM) (Furbo Mini, granted 2020-09-15). No grant is indexed for the original 2016 Furbo or the 360 models |

## Initial Setup

| Property | Value |
|----------|-------|
| Setup required | Yes |
| Method | `ble_provisioning` (vendor app), which also registers the camera with the cloud |
| Advertised name | Current generation: the name contains `-S3`. Families: `Furbo3…`, `Furbo3C…`, `Furbo4…`, `M2-…`, `M3-…`, `M4-…`, `…MINICAM…`, `F2…` |
| Passphrase protection | `device_encrypted`: AES-256-CBC under a key that is the same in every copy of the app |
| Network | 2.4 GHz only, WPA2 (the vendor says WPA3 does not work). A hidden SSID can be typed in by hand |
| Confidence | low (static analysis of the app; nothing replayed) |

The camera shows setup mode on its status light: blinking yellow on the 360
and Mini models, green on the original Furbo. The app scans for it, connects
without bonding, and follows the camera's status code. The code is an ASCII
number on a read/indicate characteristic.

1. Read the status. `2` or `4` means ready.
2. Trigger a Wi-Fi scan and read the AP list back in up to four chunks.
3. Write the SSID and passphrase, then set the "details ready" flag.
4. The camera joins Wi-Fi (status 8, 9, 10, 12).
5. On status `20`, write the account, a cloud endpoint and a short-lived
   registration token. The camera registers itself (13, 14).
6. On status `21`, write the phone's longitude and latitude, the country code,
   speaker volume `60` and the time zone.
7. The camera starts P2P (22, 15) and reports `0` when a session is possible.

The per-status timeouts, the status table and every characteristic are in the
spec's `setup.methods` and `protocol_details.ble_onboarding_v4`.

**Factory reset** (vendor help centre; not run by this project):

| Model | Button | Hold | Confirms |
|-------|--------|------|----------|
| Furbo 360 / 360 Cat | Under the camera | about 5–10 s (one vendor article says 30 s) | Light blinks yellow |
| Original Furbo (2 / 2.5T) | Pinhole on the back, pin or paper clip, plugged in | about 20 s | Light changes, then turns green |
| Furbo Mini | Pinhole, plugged in | 5–10 s | Light blinks yellow |
| Furbo Mini 360 | Under the device | until it changes | Light blinks yellow |

A hard reset clears Wi-Fi but **not the cloud binding**. Remove the camera from
the old account in the app ("Remove Device"), or the next setup fails. The P2P
opcode set also has a remote reset request. The spec marks it advanced and does
not document it further.

**Rebinding to a new network**: done in place. The app's "Reset Wi-Fi" menu
item re-runs the BLE flow on a bound camera, whose light blinks blue when it
has lost its network. The vendor says not to press the reset button for this.
Over BLE the app writes `2` to the reset-setup characteristic and adds an
encrypted ownership proof. If the proof is missing the camera reports `-101`;
if it is wrong, `-102`. The P2P UID belongs to the camera, not the network, so
sessions need no change afterwards.

## Pairing

| Property | Value |
|----------|-------|
| Pairing required | No |
| Security mode | `none` |
| Bonding | `none` |
| PIN source | not applicable |
| One central at a time | Unknown |
| One bond at a time | No (nothing bonds) |
| Confidence | low (from the app) |

**Entering pairing mode**: nothing to pair. Setup mode (above) is what makes
the camera advertise.

**Unpairing**: nothing bonds. Ownership lives in the cloud account; "Remove
Device" in the app clears it.

**Recovery**: the conflict that bites is on the P2P side. Each cloud fetch of
the P2P credential makes the key every other client holds stop working. If the
vendor app and a bridge fetch on their own, they knock each other off, and the
AV channel fails with `-20011`. Use one shared session per camera.

## Protocol Summary

### P2P session (TUTK/Kalay)

Per ha-furbo:

| Step | What happens |
|------|--------------|
| SDK init | Set the SDK licence string, which the vendor app embeds and which is not reproduced here. Initialise IOTC on a random local UDP port, then initialise AV |
| Credential | Cloud login, then one P2P credential fetch per camera, just before connecting |
| Connect | Connect by the camera's 20-character UID with its 8-character AuthKey (auth type 0). Session mode: 0 P2P, 1 relay, 2 LAN |
| AV channel | AV client on channel 0: identity P2PAccountId, password P2PAccountKey, security mode 1 (DTLS, PSK-AES128-CBC-SHA256) |
| Legacy (FB002) | The cloud returns no AuthKey. Use the plain connect by UID, then the AV client with the account id and the device record's P2PAccessToken, security mode 0 |
| Register | V2 cameras only: send the account's DeviceToken |

LAN mode needs one broadcast domain. The SDK only offers broadcast search, with
no connect-by-IP. Across VLANs, allow UDP both ways between the hosts (the
session then comes up as direct P2P) or relay the broadcast.

### Getting the credential (cloud)

All calls are JSON POSTs to `product.furbo.co`.

1. `/v5/account/read/login` with the email, the RSA-encrypted password and a
   client-chosen MobileId.
2. If the reply is `12101`, an emailed code is needed:
   `/v4/account/mfa/login/send-code`, then `/v4/account/mfa/verify`, then
   `/v2/account/login`.
3. `/v2/account/{AccountId}/device` lists the cameras, with their UIDs.
4. `/v5/device/p2p_connection/get` returns AuthKey, P2PAccountId and a fresh
   P2PAccountKey.

Keep the MobileId and the MFA proof to avoid a new code on every login. The
login token lasts about a day and cannot be refreshed. All of these values are
per-owner secrets.

**Offline recovery is a candidate, not a promise.** Owner-exported account
fields and the on-camera `p2p_auth.json` state are two plausible ways to
preserve an existing credential across reboots. Reset or regeneration
invalidates it. Nobody has yet shown a session with both the Furbo cloud and
TUTK relays blocked, so this is not cloud-free first-time adoption. Furbo 2
RTSP uses different credentials again: do not substitute the TUTK key for its
Digest password.

### IOCTRL messages (V3: Furbo 360, 360 Cat, Mini 2/3)

A reply's opcode is the request's plus one, and its payload starts with a
status byte (`0` = OK). A refused request comes back as `0x40001` with
`[status, opcode low byte, opcode high byte, 0, 0]`. Only the low 16 bits of
the opcode are echoed, so `0x10009` and `0x20009` look alike in a refusal.

| Opcode | Our name | Request | Reply |
|--------|----------|---------|-------|
| `0x10001` | get device info | 4 × `00` | status, camera on at [1], volume at [5], four NUL-padded version fields from [9] |
| `0x10009` / `0x1000b` | get / set camera on | `[on,0,0,0]` | `[status, on]` |
| `0x10013` / `0x10015` | get / set night vision | `[mode,0,0,0]`: 0 auto, 1 on, 2 off | `[status, mode]` |
| `0x10017` / `0x10019` | get / set sound sensitivity | `[level,0,0,0]`: 0 off, 1 low, 2 medium, 3 high | `[status, level]` |
| `0x1001b` / `0x1001d` | get / set speaker volume | `[0–100 %,0,0,0]` | `[status, volume, muted]` |
| `0x10023` / `0x10025` | get / set treat size | `[0 large / 1 small,0,0,0]` | `[status, size]` |
| `0x10027` / `0x10029` | get / set auto tracking | `[cruise, live, live zoom, 0]` | `[status, cruise, live]` |
| `0x10011` | get upgrade info | 4 × `00` | four ASCII version fields from [2] |
| `0x20007` | **toss treat** | 4 × `00` | status, then notification `0x30005` |
| `0x20009` | **pan** | `[1 left / 2 right, degrees, 0, 0, 0, 0]` | status, then notification `0x30007` |
| `0x2000d` | play treat sound | 4 × `00` | status |

The spec lists all 45 V3 entries (requests, notifications and the refusal), the older V2 set in the `0x900` range (Furbo
2 / 2.5T, first Mini; no pan), and the advanced ones (upgrade, reboot, upload
logs, remote reset). The app turns 60° per pan press, or 50° on a Mini 3.
ha-furbo verified these on hardware: the state read, setting the volume, a pan,
and one treat toss.

### Audio and video

| Stream | Format |
|--------|--------|
| Video | Start with standard opcode `0x1ff` and an int32 LE quality number. V3 numbers: 0 = 1080p, 1 = 720p, 2 = 360p, 3 = 1440p. The FB0030 gives H.264 1920×1080 at 25 fps for quality 0, after one 640×360 preview frame, and 640×360 for qualities 1–3 |
| Microphone | Start with `0x300`. The FB0030 labels its frames codec id 135; the format is not established |
| Talkback | G.711 µ-law, 16 kHz, mono, 320-byte frames (20 ms). Send speaker-start `0x350` with the channel number, then open an AV **server** on that channel with DTLS (security mode 3). Each frame has a 16-byte header: codec id 137, flags `14` |

### BLE onboarding (current generation)

The service UUID is not established; the app matches characteristics by UUID
alone. Values are ASCII text, written with response.

| UUID | Role |
|------|------|
| `02435612-dc14-423f-bd4f-a6a12e567e90` | Setup status (read, indicate) |
| `2c259f9c-4a57-4c74-830e-2013e4466c2c` | Reset setup: `1` new setup, `2` Wi-Fi change; indicates `0` when done |
| `3c2c5dea-35aa-4540-94be-0bd5d9e72793` | Scan ready: write `0` to scan, reads `1` when done |
| `e92543cb-08c6-4b2b-a395-1824cdbd4417` … `76e415d0-9e94-4979-aaa2-54d8489f7456` | AP list chunks 1–4 (JSON array; SSIDs are hex) |
| `233d5fb2-f565-4fef-832a-983d6c362f36` | SSID (lowercase hex) |
| `f72deed1-3198-4df6-b0d7-e472cea7885f` / `ac075b73-2424-4e7a-9fe2-62cbf19e7e89` | Passphrase, encrypted / plain hex |
| `2474cee2-379d-4a0c-b630-37dd53965ca2` | Wi-Fi details ready (`1`) |
| `cb04b5ee-4c79-4316-a50e-8cc4a2067840`, `81f6f485-eae6-41cc-8a2f-e11a5844a114`, `e42de30f-a772-43fe-b216-ca5b78db4d82` | Account, cloud endpoint, registration token |
| `fb6dfec1-257c-4d58-9eed-6f79599919f0` | Registration data ready (`1`) |
| `00002aaf-…`, `00002aae-…`, `f34375ad-c23c-4bb5-bbfe-13d624741757`, `1a19aaae-094a-47aa-aaa3-1d66bd08ab1a`, `00002a0e-…` | Longitude, latitude, country, volume, time zone (SIG UUIDs used for text) |
| `3c2fb8ce-49b9-4e1c-848f-8a26740e7c8c` | Settings ready (`1`) |
| `0000180a-0000-1000-8000-00805f9b34fb` | Device Information (model, firmware, software strings) |

Status codes: `2` advertising, `4` waiting for Wi-Fi details, `8` joining,
`9` DHCP, `10` DNS, `12` cloud check, `20` waiting for registration, `13`/`14`
registering, `21` waiting for settings, `22` applying, `15` starting P2P, `0`
done. Failures: `-1` wrong passphrase, `-2` cannot join, `-3` no IP, `-4` no
DNS, `-20` cloud unreachable, `-8`/`-21` registration failed, `-30` system
error.

### BLE onboarding (older generations)

Service `77f9a069-2ff9-4ff9-93b7-4db9689f4b53`, write
`026048ab-fafc-48e5-9db0-a9bc46368055`, notify
`30c95538-58f8-4db4-a62e-08af4bae4cb0`. Requests are JSON:
`{"c":"0001", …}` for the AP list, and `"0002"` for the Wi-Fi and registration
details. Each request ends with an `ENM` marker write. The app runs the JSON
through a transform in its native library, which we have not analysed, so no
byte-exact example exists.

## Troubleshooting

- **Video or controls die, with `-20011` on the AV channel.** Another client
  fetched a P2P credential, often the phone app. Hold one session per camera
  and share it.
- **The session reports `relay`.** Client and camera are on different subnets,
  or UDP between them is blocked. See the LAN mode note above.
- **Setup fails for a camera that was set up before.** A hard reset does not
  unbind it. Remove it from the old account first.
- **The network is missing from the scan.** It is 5 GHz-only, hidden or weak.
  Furbo joins 2.4 GHz WPA2 networks only.
- **Two vendor articles disagree on the Furbo 360 reset hold** (5–10 s against
  30 s). Hold until the light blinks yellow.
- **The cloud treat toss is no proof.** It answers success for any action
  string (ha-furbo's negative finding), so do not treat its reply as a toss.
- **App defects seen in the decompile (not tested on hardware).** The older
  setup controllers set the notification descriptor value but never write it,
  so whether those cameras notify without a CCCD write is open. The phone's
  latitude and longitude are formatted in the phone's locale, so a
  comma-decimal locale may send `51,5074000`.

## Security

Somerset Recon published root exploits against older models, 2021–2022. None
has been checked here, and the Furbo 360 is not named in any of them.

- **Furbo 2:** RTSP on TCP 554 with an authentication-parser overflow
  ([CVE-2020-24918](https://nvd.nist.gov/vuln/detail/cve-2020-24918)).
- **Furbo 2.5T:** a root command injection behind its web server.
- **Furbo Mini:** unsigned firmware fetched without certificate checks.

The spec carries these as a `reported` security advisory. Somerset's Furbo 2
research establishes RTSP at `/stream` on TCP 554, with Digest authentication
after an update/reset; an early unmodified unit allowed unauthenticated
viewing. This does not establish RTSP on Furbo 3/4 or Mini, so the spec does
not expose a generic camera stream. No exploit or owner credential was used
for this research.

## Tools Used

- [x] Static analysis of the Furbo Android app 7.83.1 (BLE onboarding, opcode
  cross-check)
- [x] Published sources: ha-furbo (code, DOCS.md, HARDWARE_VERIFICATION.md,
  issue 3), go2rtc `pkg/tutk`, Somerset Recon's posts
- [x] Vendor help centre and FCC exhibits
- [ ] nRF Connect against a setup-mode camera, to find the GATT service and
  confirm the flow: **still needed**
- [ ] A LAN capture of a P2P session, and a WAN-cut test of a stored
  credential: **still needed**

## References

- [Furbo Dog Camera 2.5T regulatory leaflet (FCC exhibit, PDF)](https://fccid.co/api/files/s1/2aibvtffbv3_usersmanual_4835149_9a990778a6.pdf)
- [Furbo Mini warnings leaflet (FCC exhibit, PDF)](https://fccid.co/api/files/s1/2aibv_minicam_usersmanual_4905810_8c8bbd4f18.pdf)
- [Furbo help: Hard reset your Furbo (original)](https://help.furbo.com/hc/en-us/articles/17472773095833-Hard-reset-your-Furbo)
- [Furbo help: Hard Reset Your Furbo (360)](https://help.furbo.com/hc/en-us/articles/17465539176985-Hard-Reset-Your-Furbo)
- [Furbo help: Hard Reset Your Furbo Mini and Mini 360°](https://help.furbo.com/hc/en-us/articles/17538149642649-Hard-Reset-Your-Furbo-Mini-and-Furbo-Mini-360)
- [Furbo help: Change Your Home Wi-Fi Network](https://help.furbo.com/hc/en-us/articles/17465377871129-Change-Your-Home-Wi-Fi-Network-on-Furbo)
- [Furbo help: Can't find my Wi-Fi network in the App](https://help.furbo.com/hc/en-us/articles/17465472455961-Can-t-find-my-Wi-Fi-network-in-the-App)
- [Furbo help: WPA3 Router Security Compatibility](https://help.furbo.com/hc/en-us/articles/4412618937357-WPA3-Router-Security-Compatibility)
- [willbeeching/ha-furbo](https://github.com/willbeeching/ha-furbo)
- [ha-furbo: Furbo Bridge DOCS.md](https://github.com/willbeeching/ha-furbo/blob/main/furbo-bridge/DOCS.md)
- [ha-furbo: HARDWARE_VERIFICATION.md](https://github.com/willbeeching/ha-furbo/blob/main/HARDWARE_VERIFICATION.md)
- [ha-furbo: furbo_p2p.py (pinned)](https://github.com/willbeeching/ha-furbo/blob/b2a65be1c73862c7799d8403be084109bab66547/furbo-bridge/src/furbo_p2p.py)
- [ha-furbo issue 3: FB002 legacy authentication](https://github.com/willbeeching/ha-furbo/issues/3)
- [go2rtc pkg/tutk](https://pkg.go.dev/github.com/AlexxIT/go2rtc/pkg/tutk)
- [Somerset Recon: Hacking the Furbo, Part I](https://www.somersetrecon.com/blog/2021/hacking-the-furbo-part-1)
- [Somerset Recon: Part II](https://www.somersetrecon.com/blog/2021/hacking-the-furbo-dog-camera-part-ii)
- [Somerset Recon: Part III](https://www.somersetrecon.com/blog/2022/hacking-the-furbo-dog-camera-part-iii)
- [FCC ID 2AIBVTFFBV3](https://fccid.co/fcc/2AIBVTFFBV3) · [FCC ID 2AIBV-MINICAM](https://fccid.co/fcc/2AIBV-MINICAM)
- [Pairing, Bonding and Unpairing](../protocols/pairing.md) · [Initial Device Setup](../protocols/device-setup.md)

## Contributors

- Claude Code agent: spec written from published sources and static analysis
  of the vendor app (desk research; no hardware)
