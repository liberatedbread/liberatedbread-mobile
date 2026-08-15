# Schlage Encode/Sense — WiFi Local-Surface Investigation — Research Notes

Companion note to `device-specs/devices/schlage-smart-locks.yaml`. Question posed:
the spec says the Encode family's WiFi radios have **no local-network API** — verify
that against the Android app's own logic, Schlage's published firmware/release notes,
and the live LAN. Bottom line: the spec's claim **holds for the locks**; the one
genuinely "funky" local surface found belongs to the BR400 Wi-Fi **adapter** (a
Sense accessory), not the locks themselves.

Confidence labels: **confirmed** = read in decompiled app code / directly observed;
**reported** = vendor docs / app strings / third party; **hypothesis** = reasoned,
untested.

## APKs analyzed (workspace-only, never committed)

- `com.allegion.leopard` 3.6.0, sha256 `73ad7395…48219c` → jadx → `workspace/jadx-leopard-3.6.0/`
- `com.allegion.leopard` 6.1.0, sha256 `0e87604d…31abdd` → jadx → `workspace/jadx-leopard-latest/`
  (6.1.0 app Java is DexGuard-packed — only `MainApp`/`R` decompile; findings from
  6.1.0 are resources/manifest-level only)

## 1. WiFi setup flow — how the lock actually gets on WiFi (CONFIRMED, app 3.6.0)

Provisioning is **BLE-driven, end to end**. The lock never hosts an AP and the app
never opens a socket to a lock IP:

1. App pairs to the lock over BLE uWeave (SPAKE2 + programming code, per the spec).
2. App fetches a cloud-minted JITR identity blob ("payload0"):
   `GET https://factory.allegion.yonomi.cloud/v1/devices?deviceType=<id>&physicalId=<SERIAL>`
   (`api/factory/retrofitAPI/FactoryApi.java:11-15`, caller `defpackage/lj0.java:10-36`).
   Requests carry header `x-payload0: RSA_PKCS1_PADDING`
   (`api/generic/SenseRetrofitBuilder.java:179`) — the blob is RSA-encrypted and
   opaque to the app.
3. App pushes WiFi credentials **over BLE**, CBOR trait 6:
   `{1:8, 2:4, 16:{0:6, 1:0, 2:{0:ssid, 1:password, 2:1}}}`
   (`defpackage/fj.java:94-105`, log tag `BleConfigureWiFiCredentials`). Note: the
   security enum is **hardcoded to 1** in 3.6.0 (`fj.java:102`).
4. App pushes payload0 over BLE: `{1:8, 2:4, 16:{0:6, 1:2, 2:{0:<bytes>}}}`
   (`fj.java:187-197`).
5. App polls join status over BLE: `{1:8, 2:5, 16:{0:6, 1:4}}`
   (`defpackage/pj.java:180-187`). **Correction to the current spec:** the 3.6.0
   status enum (`pj.java:46-88`) is `-1 INVALID, 0 STOPPED, 1 STARTED, 2 SUCCESS,
   3 AP_ERROR, 4 HOST_ERROR, 5 IP_ACQUIRED` — it tops out at 5; there is no state
   6 ("wrong creds").
6. Related BLE commands in the `LockAction` enum
   (`com/allegion/leopard/model/LockAction.java:183-208`): `WIFI_COMMISSIONING`,
   `READ_JITR_STATUS`, `GET_ACCESS_POINT_INFO`, `GET_LOCK_WIFI_MAC_ADDRESS`,
   `WIFI_NETWORKS_LIST` — i.e. the lock does its own AP scan and reports the list
   back over BLE.

Security footnote (confirmed): `fj.java:91` writes the home WiFi **SSID and password
in cleartext to logcat** during setup.

### Where the "joining WiFi" impression comes from

The setup UI makes it look like the lock joins WiFi on its own, but all network
selection happens phone-side (user picks an AP from the lock's BLE-reported scan
list); credentials cross to the lock only through the encrypted BLE channel. The
only `WifiNetworkSpecifier`/`WifiConfiguration` code in the app
(`defpackage/xr3.java`, `yr3.java`, `zr3.java`) targets the **BR400 adapter's**
temporary softAP, never a lock.

## 2. Local WiFi command path on the locks: NONE (confirmed as far as the app shows)

- No `ServerSocket`, `DatagramSocket`, UDP broadcast, CoAP (5683), NsdManager use
  for locks, or LAN IP literal anywhere in app code for lock control. The **only**
  local-IP literal in either app version is `http://192.168.10.1`
  (`res/values/strings.xml:1362` in 3.6.0, `:1706` in 6.1.0) — the BR400's softAP
  address.
- Runtime WiFi traffic is a cloud relay, as the spec says: REST
  `https://api.allegion.yonomi.cloud/v1/` plus realtime over MQTT-in-WebSocket
  where the broker URL itself is server-supplied (`GET wss?deviceId=…` →
  `{wssUri, clientId, topics}`, `api/lock/retrofitAPI/DeviceApi.java:64-65`;
  Eclipse Paho `MqttAndroidClient`, MQTT 3.1.1, keepalive 1800 s, cleanSession=false,
  `defpackage/uo3.java:267-317`). No hardcoded AWS IoT ATS endpoint and no literal
  `$aws/things` in the APK — topic strings arrive from the server.
- Feature toggles embedded in the app config (`defpackage/zl.java:5`) are only
  `firmwareList, fileLogging, showCase, encode_lever, ring_features` — **no
  local/LAN/direct-control flag exists**.
- No telnet/ssh/dropbear/httpd/adb/serial/debug-port references anywhere in either
  tree (searched both).
- 6.1.0 resources add Matter/Thread **UI** (drawable `icon_works_with_matter.png`,
  `matter_lock_setup` string directing the user to finish in the Google Home app,
  `thread_connect/disconnect` strings) but the manifest declares no Matter
  commissioning components and no GMS Thread/CHIP code decompiles — commissioning
  is delegated to Google Home (confirmed at resource level; packed dex could hide
  more).

## 3. Firmware: origins, format, and the commercial release-notes page

### Residential (Encode/Sense) firmware flow (confirmed from 3.6.0 app code)

- Metadata: `GET https://api.allegionengage.com/api/firmware/{platformType}` with
  header `Accept: application/json; version=3`
  (`api/firmware/retrofitAPI/FirmwareApi.java:12-18`,
  `FirmwareRetrofitBuilder.java:35,80-87`). Platform strings include `sense2`
  (BE479), `sensegateway` (BR400), and per-family device-type IDs for Denali /
  Jackalope / Encode Lever (+ `_MCKINLEY_` hardware-rev variants)
  (`FirmwareApiService.endpointOf`, `FirmwareApiService.java:142-175`).
- Response model (`api/firmware/model/Firmware.java:26-45,106-148`):
  description / deviceType / extendedVersion (`M`=mandatory, `O`=optional) /
  isPublic / links / name / version. The binary URL is the `links[rel=self]` href —
  **server-supplied**, no CDN hostname hardcoded.
- Download (`FirmwareApiService.downloadRx`, `FirmwareApiService.java:225-257`)
  streams to `files/firmware_files/<version>.bin` and checks **content-length
  only — no hash, no signature verification in app code** (searched; hits only in
  TLS/AWS SDK library code). Image validation must happen on-lock (unknown how).
- Delivery to the lock, two paths:
  - **BLE push** (phone-side): `UPDATE_FIRMWARE` LockAction with the file URI,
    chunked through the DataTransfer GATT service with per-chunk CRC + ACK/NAK
    (UI strings say 17–40 min).
  - **Lock self-download over WiFi** (reported, vendor support doc): Schlage's
    Zendesk article "Schlage Encode Series: Firmware Update" states Encode locks
    "download and install the latest firmware from the cloud" automatically over
    home Wi-Fi; manual trigger = **press the interior button 5× rapidly**; app
    "Update Now" completes with no phone in range. The 6.1.0 lock-log map
    (`res/raw/wifi_lock_log_messages.json`) corroborates lock-side WiFi events:
    `firmware_download_failed`, `bluetooth_firmware_download_failed`,
    `wifi_ap_connect/disconnect`, `wifi_host_connect/_error/_disconnect`,
    `wifi_enter/exit_roaming`, `wifi_power_policy_updated`.
    → The WiFi lock **pulls firmware itself**; the app never sees the URL in that
    path (it is delivered via cloud/shadow).

### Commercial release-notes page (what it covers; residential firmware NOT obtainable there)

`https://commercial.schlage.com/en/resources/troubleshooting-maintenance/release-notes.html`
is the **commercial** catalog. Product families with firmware release notes there
(all fetched 2026-08-15):

- **AD-Series** (AD-200/250/300/302/400/402, PIM400, WPR400/WRI400, CT5000…) —
  release-note PDFs **plus actual firmware ZIPs**, latest `AD.A.146.3` (May 2026).
- **NDE / NDEB** (ENGAGE-platform commercial wireless locks) — release-note PDFs
  only, latest NDE `02.22.01` (Mar 2026), NDEB `03.20.02` (Apr 2026). No binaries.
- **Schlage Control** (BE467F mobile-enabled) — PDFs only, latest `04.18.02` (Feb 2026).
- **XE360, LE/NDE Reader Controller, CL/CM legacy, ISONAS** — PDFs; CL/CM also ship
  Motorola `.S19` files; ISONAS ships an updater ZIP.
- **Nothing for residential Sense/Encode (BE479/BE489/BE499/FE789).** Residential
  firmware is distributed only via the ENGAGE/Yonomi cloud endpoints above
  (auth-gated by the app's Cognito login + API key; not anonymously fetchable —
  not attempted, vendor client credentials deliberately unused).

### Commercial firmware sample analysis (AD.A.146.3, downloaded to `workspace/schlage-fw/`)

- ZIP contains a release-note PDF and one `AD.A.146.3.ffp` (~4.6 MB). `.ffp` is an
  Allegion firmware-package container: header is a table of 32-bit offset/length-ish
  pairs, and `strings` reveals embedded per-board image names (`AD-200_2.56.0.hex`,
  `AD-400_2.56.0.hex`, `PIM400-485-RSI_2.32.3.hex`, `CT5000_2.9.0.hex`, …).
  `binwalk` finds no standard filesystems/streams; the bulk is obfuscated/encrypted
  (head entropy ~7.1 bits/byte). The file tail is a repeated 16-byte block
  (`34d5cc9c3842cab3…` ×N) — the classic signature of **AES-ECB-encrypted padding**,
  i.e. the package (or its last segment) is ECB-encrypted. No httpd/telnet strings.
- NDEB release note `03.20.02` shows the multi-processor update model shared with
  the residential line: Main Application / Reader Application / BLE Application /
  **Wi-Fi Application** versioned separately, updates staged from the ENGAGE cloud
  "during the next scheduled WiFi connection", or pushed **locally over BLE** from
  the ENGAGE mobile app — same architecture as leopard's BLE-push/WiFi-pull duality.

## 4. Live LAN observations (2026-08-15, 192.168.1.0/24, from 192.168.1.180)

- `nmap -sn` ping sweep of the full /16: **51 hosts up** (of 65536), ~225 s.
- ARP + OUI resolution against `registries/ieee-oui.tsv` for all 51: no Allegion
  OUI exists (confirmed again; the lock BLE MAC OUI B7:AC:C2 is unregistered), so
  locks can only be found as "unidentified" hosts. Vendors seen: Ubiquiti (many),
  Routerboard (gateway), Apple ×3, TP-Link ×6, Espressif ×2, FN-LINK ×2, Murata,
  High-Flying, TCL ×2, Brother ×2, Synology, Philips Lighting (Hue), Amazon,
  Raspberry Pi, Intel, one locally-administered MAC.
- Light port scan (22/23/53/80/443/1883/5683/8080/8443/9009) of the plausible
  IoT-module candidates, then HTTP identification of anything listening:
  - `192.168.1.104` (FN-LINK, port 80): **myQ Wi-Fi Hub** (Chamberlain garage)
    in provisioning mode — "Wi-Fi Setup" page, myQ logo. Not Schlage.
  - `192.168.1.198` (FN-LINK, 443): ancient **Boa/0.94** webserver, GB2312 404 —
    some Chinese IoT gadget, unidentified, not Schlage-like.
  - `192.168.1.2` (Murata, 80+443): `470 Connection Authorization Required` —
    unidentified proprietary device.
  - `192.168.1.48` (Espressif, 80): hobbyist ESP web UI (dark theme). Not Schlage.
  - `192.168.1.31` (Espressif), `192.168.1.194` (High-Flying): all ports closed.
  - `192.168.1.33` (LAA MAC): SSH open — a Linux box, not a lock.
- **No host was positively identifiable as a Schlage lock.** If the locks are on
  WiFi they present zero listening ports among the common set and answer nothing on
  HTTP — consistent with the app evidence (outbound-only cloud relay). Passive
  confirmation (watching for TLS/DNS to `*.allegion.yonomi.cloud`) was not possible:
  no capture privileges on this machine (tcpdump needs root; sudo unavailable).
- A prior session already found no Schlage mDNS/SSDP announcements; this sweep adds
  that nothing lock-like listens on the common service ports either.

## 5. Assessment: is there a viable "funky" local-control angle?

1. **Setup-mode listener on the locks — ruled out (confirmed).** The lock is a WiFi
   *station* only; all commissioning flows in the app push credentials over BLE.
   There is no code path where the lock hosts an AP, opens a port, or receives IP
   traffic from the app. During setup the app talks to the lock exclusively via
   GATT.
2. **BR400 Wi-Fi adapter local HTTP API — real, but accessory-scoped (confirmed).**
   The BR400 bridge (Sense accessory) hosts a softAP at `192.168.10.1` and, once
   commissioned, an **unauthenticated plain-HTTP API on the LAN**, discovered via
   mDNS `_http._tcp.` (`defpackage/cn0.java:183`, `qh.java:45`, `np2.java`,
   `uo3.java:384-391`; base URL `http://<resolved-host>` falling back to
   `<name>.local`, `qh.java:49-52`, `bm0.java:124-127`). Endpoints
   (`com/allegion/leopard/api/bridge/commission/retrofitApi/BridgeApi.java:17-41`):
   - `GET bridge/info`, `GET bridge/v1/commission/status` (model/firmware/serial/uptime)
   - `GET v1/prov/networks` (adapter-side WiFi scan, with rssi)
   - `POST v2/prov/registration` (push encrypted home-WiFi creds)
   - `GET bridge/ble/scan` (adapter scans for BLE locks — a remote BLE recon primitive)
   - `POST bridge/v2/commission/start` (push payload0)
   - `POST bridge/update_mcu` with body `{"url": <firmware URL>}` — the adapter
     then **pulls and flashes firmware from an arbitrary URL supplied over
     unauthenticated local HTTP** (`uo3.java:363-368`). Hypothesis (untested
     against hardware): anyone on the LAN can likely hit these endpoints — the app
     sends no auth headers — making `bridge/update_mcu` a firmware-injection point
     *if* the adapter doesn't signature-check the image (unknown). Only relevant
     where a BR400 is installed; the user's site has Encode-family locks with
     built-in WiFi, no BR400.
   - Legacy commissioning crypto quirk (confirmed, `WifiPayload.java:26-55`):
     AES/CBC/NoPadding, **zero IV**, key = SHA-256(bridgePassword + "|" +
     bridgeSsid[6:]), and the caller retries with every letter of the password
     case-swapped (`defpackage/rh.java:26-46`).
3. **Firmware-update interception on Encode-family WiFi OTA — hypothesis, untested.**
   The lock self-downloads firmware over WiFi from a cloud-delivered URL. If the
   lock's TLS validation or image-signature check is weak, DNS/URL redirection on
   the LAN could feed it an image. Unknowns: whether the lock validates the server
   certificate (likely — the platform pins Amazon roots on the app side), whether
   images are signed and checked on-lock (the app checks only length; the BLE-push
   path leaves validation to the lock too, suggesting the lock does verify
   something). Do not pursue without hardware-sacrifice authorization; observe-only
   mission.
4. **MQTT/WSS relay spoofing — blocked by design (confirmed).** Broker URI, client
   ID and topics are minted per-device by the cloud after Cognito auth; nothing
   about the relay is reachable without the account.
5. **Matter/Thread on Encode Plus — separate, legitimate local surface (reported).**
   The 6.1.0 app delegates Matter commissioning to Google Home. Matter-over-Thread
   is a standards-based local-control path for the BE499 (via any Matter
   controller), and the spec's opMode property (trait 5 prop 27: simultaneous
   BLE+Matter) already hints at it — but it is not a Schlage-protocol surface and
   doesn't extend to BE489/BE479.

**Bottom line:** for the Encode/Sense locks themselves, the spec's statement stands —
no local WiFi API, no setup-mode listener, no diagnostic port; WiFi is purely a
cloud relay plus a lock-initiated firmware fetch. The one exploitable-looking local
surface in the whole ecosystem is the BR400 adapter's unauthenticated HTTP
commissioning API (especially `POST bridge/update_mcu`), which only exists in Sense
deployments with that accessory.

## Suggested spec corrections (for the orchestrator's merge)

- JITR status enum: 3.6.0 app shows 0..5 (`IP_ACQUIRED` max), no state 6 —
  `pj.java:46-88`. The spec's "0..6 … wrong creds" is not in the app.
- `set_wifi_credentials`: security enum hardcoded to `1` in 3.6.0 (`fj.java:102`).
- Firmware section can add: metadata `GET api.allegionengage.com/api/firmware/
  {platformType}` (Accept version=3); binary URL is server-supplied
  (`links[rel=self]`); app verifies content-length only; WiFi locks self-download
  (interior-button ×5 manual trigger per vendor support doc) — the "image bytes
  come from the vendor cloud" note applies to both delivery paths.
- The `evidence.lan_observations` section can add the /16 census result (51 hosts,
  no lock-like listener) once merged.

## Sources

- jadx 1.5.1 decompiles of `com.allegion.leopard` 3.6.0 / 6.1.0 (workspace-only).
- [Schlage commercial release-notes catalog](https://commercial.schlage.com/en/resources/troubleshooting-maintenance/release-notes.html)
- [Schlage Encode Series: Firmware Update (vendor support)](https://schlage-res.zendesk.com/hc/en-us/articles/37643505610516-Schlage-Encode-Series-Firmware-Update)
- NDEB firmware 03.20.02 release note (commercial.schlage.com DAM PDF, Apr 2026).
- AD-Series `AD.A.146.3.ffp` firmware package (commercial.schlage.com DAM ZIP, May 2026) — analyzed in `workspace/schlage-fw/`.
- LAN: nmap ping sweep + ARP/OUI resolution + bounded port scan, 2026-08-15.
