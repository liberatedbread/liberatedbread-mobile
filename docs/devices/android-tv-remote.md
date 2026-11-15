# Android TV / Google TV — Android TV Remote Protocol v2

> **Status**: Research — documented from client source and community protocol write-ups; not replayed against live hardware
> **Protocol**: WiFi (mDNS + protobuf over TLS, TCP 6466 session / 6467 pairing); Amazon Fire TV variant: ADB over TCP 5555
> **Manufacturer**: Google (platform); Nvidia, Sony, TCL, Hisense, onn and others (devices)
> **Manufacturer Status**: Active

## Overview

Android TV OS devices (Nvidia Shield, Chromecast with Google TV, onn boxes,
TCL/Sony/Hisense sets) run the **Android TV Remote Service** system app, which
serves the same protocol the Google TV mobile app speaks — no ADB, no
developer options. It is the best local-control story of any major TV
platform after Roku's ECP: full key injection, app launching, keyboard text,
voice, and pushed power/volume/current-app state, with real pairing instead
of ECP's open port.

**Transport gap**: the protocol is protobuf messages over a mutually
authenticated TLS session — not HTTP, not SOAP. The reference app does not
implement this transport today, so the spec records the message vocabulary
and pairing flow in its `androidtv_remote_v2` extension block and declares
commands without any `transport`/`method`/`path`; nothing here can be
rendered as an HTTP request. A client must implement: TLS with peer
verification disabled plus a stored client certificate, protobuf varint
length-prefix framing, and the `polo.proto` / `remotemessage.proto`
vocabularies (androidtvremote2 is the reference implementation).

**Amazon Fire TV** ships no Remote Service and cannot be driven this way; its
local path is ADB over TCP 5555, documented in the spec's `fire_tv_adb`
extension block — a second, equally real transport gap.

## Discovery

mDNS `_androidtvremote2._tcp.local.`; the SRV target port is the 6466 session
port. The instance name is the TV's user-facing name. Model and vendor are
**not** advertised — they arrive in the session handshake's
`remote_configure.device_info`. Pre-connection identity is the mDNS hostname
(`Android-<hex>.local`, stable until factory reset).

Fire TV has no discovery protocol: finding one is a TCP 5555 port probe or a
user-supplied IP, and an open 5555 says "some Android device with ADB on",
not "Fire TV".

## Pairing (one-time, per client)

On port **6467**, TLS with a client-generated RSA-2048 self-signed
certificate (the certificate *is* the credential — nothing else is issued):

1. Client sends `PairingRequest { service_name: "atvremote", client_name }`.
2. `Options` / `Configuration` exchange fixes the code encoding (hexadecimal,
   6 symbols) and role; the TV then **shows a 6-character hex code**.
3. The user types the code into the client. The client sends
   `Secret = SHA-256(client modulus ‖ client exponent ‖ server modulus ‖
   server exponent ‖ code[2:6])` — the code itself never crosses the wire,
   and the digest binds it to both certificates' public keys. A
   `STATUS_BAD_SECRET` answer means a mistyped code.
4. Done: the TV trusts that client certificate for sessions on 6466. Clearing
   the Remote Service's storage on the TV (Settings > Apps > Show system apps
   > Android TV Remote Service > Storage > Clear storage) revokes everyone.

## Session (port 6466)

Every message on both ports is a **protobuf varint length prefix** followed by
the serialized message — that varint is the only framing rule.

The server speaks first: `remote_configure` carries the feature bitmask
(PING=1, KEY=2, IME=4, VOICE=8, POWER=32, VOLUME=64, APP_LINK=512) and
`device_info { model, vendor, app_version }`; the client answers with its own
masked features, a `remote_set_active` pair follows, and the server then
pushes state — `remote_start` (power), `remote_ime_key_inject` (foreground
app), `remote_set_volume_level` (volume/max/muted) — initially and on change.
Idle keepalive is a server `remote_ping_request` roughly every 5 s; three
unanswered pings close the connection, so command-only clients can also just
connect, send, and disconnect.

## Command surface

| Message (RemoteMessage field) | Purpose |
|---|---|
| `remote_key_inject` (10) | One remote key: Android `KEYCODE_*` (HOME=3, BACK=4, DPAD_UP=19…CENTER=23, VOLUME_UP=24, POWER=26, MEDIA_PLAY_PAUSE=85, CHANNEL_UP=166, TV_INPUT=178, TV_INPUT_HDMI_1=243…); `SHORT`=tap, `START_LONG`/`END_LONG`=hold |
| `remote_app_link_launch_request` (90) | Launch by deep link (`https://www.netflix.com/title`, `vnd.youtube://`) or, with Play Store, package name |
| `remote_ime_batch_edit` (21) | Keyboard text into the focused field; needs counters pushed by the server, so it needs a held session |
| `remote_voice_begin/payload/end` (30–32) | Voice: PCM 16-bit 8 kHz mono in ≤20 KB (≥8 KB on Shield) chunks after `KEYCODE_SEARCH` opens a session |

Known limits: **no installed-app enumeration** (clients keep user-configured
lists — there is no Roku-style app picker to build), **no playback state**
(pair with Google Cast for metadata), Netflix ignores injected keys even from
Google's own app, and many devices leave the network in standby (Xiaomi; TCL
without *Screenless service*; Shield without the wake-buttons setting), which
puts power-on beyond any network command.

`KEYCODE_POWER` is a toggle with no discrete pair, so the spec's stateful
**Power** `switch` entity binds it as `toggle`, gated on the
`remote_start { started }` push — the Power State reading
([Spec Evolution P13](../contributing/spec-evolution.md#p13)). The push
arrives over the session rather than any pollable binding, so a consumer
without the session sees no state and must not send blind.

## Fire TV variant — ADB over TCP 5555

Enable on the TV: *Settings > My Fire TV > Developer Options > ADB Debugging*
(Developer Options is hidden until *About* is clicked seven times on some
devices, and until an Amazon account is signed in on Fire TV Edition sets).
The first connection pops **"Allow USB debugging?"** on screen — approve with
"Always allow" to persist the client's ADB public key. Then:

- Keys: `adb shell input keyevent KEYCODE_HOME` — the same keycode table as
  above
- Text: `input text <escaped>`
- Launch/stop: `monkey -p <package> -c android.intent.category.LAUNCHER 1` /
  `am force-stop <package>`
- State: polled `dumpsys` properties (audio state, media session, wake locks)
  with per-app detection rules — richer than the Remote Service surface, at
  the cost of polling

Reference clients: `adb_shell` (pure-Python ADB wire protocol) and
`androidtv`, the backend of Home Assistant's Android Debug Bridge
integration.

Machine-readable spec: `device-specs/devices/android-tv-remote.yaml`

## References

- [AOSP google-tv-pairing-protocol (Polo)](https://android.googlesource.com/platform/external/google-tv-pairing-protocol/) — the pairing half's upstream
- [androidtvremote2](https://github.com/tronikos/androidtvremote2) — Python v2 client, Home Assistant's backend ([remotemessage.proto](https://raw.githubusercontent.com/tronikos/androidtvremote2/main/src/androidtvremote2/remotemessage.proto), [polo.proto](https://raw.githubusercontent.com/tronikos/androidtvremote2/main/src/androidtvremote2/polo.proto))
- [Google TV (aka Android TV) Remote Control (v2)](https://github.com/Aymkdn/assistant-freebox-cloud/wiki/Google-TV-(aka-Android-TV)-Remote-Control-(v2)) — byte-level community write-up
- [androidtv-remote](https://github.com/louis49/androidtv-remote) — first public reconstruction (Node.js)
- [Home Assistant Android TV Remote](https://www.home-assistant.io/integrations/androidtv_remote/) and [Android Debug Bridge](https://www.home-assistant.io/integrations/androidtv/) integrations
- [androidtv](https://github.com/JeffLIrion/python-androidtv) / [adb_shell](https://github.com/JeffLIrion/adb_shell) — ADB clients for Android/Fire TV
- [Amazon — Connect to Fire TV through ADB](https://developer.amazon.com/docs/fire-tv/connecting-adb-to-device.html)
- [Android KeyEvent reference](https://developer.android.com/reference/android/view/KeyEvent)
