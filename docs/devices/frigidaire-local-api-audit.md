# Frigidaire APK and Local API Evidence Report

Date: 2026-07-15

Package: `com.electrolux.oneapp.android.frigidaire`

## Summary

Older Frigidaire APKs were found and downloaded: `1.24`, `2.0`, and `3.6`.
The older `1.24` and `2.0` builds contain more legacy local provisioning code
than the current `3.6` build, including a Delta NIU TCP/TLS setup channel,
`DELTA_NIU_HTTP_REQUEST`, `LOCAL_ROBOT_PASSWORD`, and a cleartext exception for
`192.168.0.1` in `2.0`.

No evidence was found for a steady-state post-pairing LAN control API for
Frigidaire AC/dehumidifier devices in `1.24`, `2.0`, or `3.6`. The local code
found is setup/enrollment only. App control paths remain Electrolux OCP cloud
REST/websocket paths.

## APK Hunt Results

Play metadata for the current release was read with `google-play-scraper`
(version `4.26`, release date Mar 27 2023, 18 declared permissions); it exposes
no historical APK list. Three older builds were located and archived through
public APK mirrors — `1.24`, `2.0` and `3.6`. Nothing below `3.0` exists on the
mirrors that still list the package, in the Internet Archive's Wayback CDX for
the APKPure landing page, or in GitHub code search.

Archived builds (XAPK bundles):

| Version | versionCode | SHA-256 |
|---|---|---|
| 1.24 | 5851 | `67e79350b1e39d1b084b6578d5a46925db3fc06ba7b9dbb35a46775c0862f3cf` |
| 2.0 | 6895 | `032e869b706275e94dd1fa2b3222e6d4e8a5d2591d7344f95bd7147869170f66` |
| 3.6 | 504110958 | `0fa212791d3f488eaffbbb1dbc628b7c988d786e1546be32fcc297795a6c99aa` |

The binaries and the raw search transcripts are kept in the local, gitignored
research workspace — see [the clean-room rules](../CLEANROOM_RULES.md).

## Decompilation

The old XAPKs were extracted and their base APKs decompiled for static
analysis; the decompiler output is kept out of the repo per
[the clean-room rules](../CLEANROOM_RULES.md).

Each XAPK contained a base `com.electrolux.oneapp.android.frigidaire.apk` plus
resource/config split APKs. Static analysis used the base APK.

## Local API Sweep Results

### v3.6

Requested pattern results:

```text
192.168.x patterns             1
localhost patterns             2
local HTTP server patterns     0
mDNS / NSD patterns            1
SSDP / UPnP patterns           0
local REST / WebSocket         0
local feature flags            0
AWS IoT patterns               0
provisioning patterns       1739
cloud endpoint patterns      466
```

Key evidence:

- A socket class connects to `192.168.6.1` port `3002`.
- A URL builder constructs `http://` or `https://` URLs from a discovered setup
  server IP during provisioning.
- No `http://192...`, `ws://192...`, mDNS, SSDP, UPnP, Greengrass, local MQTT
  broker, or `local_control`/`lan_control` feature flag was found.

### v1.24

Key counts:

```text
local HTTP/IP patterns          2
discovery/mDNS/SSDP patterns    6
local/AWS flag patterns         0
provisioning patterns        2470
cloud endpoint patterns       249
```

Key evidence:

- A caller of the TCP socket service passes `192.168.6.1`.
- The socket class opens a TCP/TLS channel to port `3002`.
- A command-constant class declares `DELTA_NIU_HTTP_REQUEST`,
  `DELTA_NIU_COOKIE_SIGN`, `DELTA_NIU_SET_CLOUD_PASSWORD`,
  `DELTA_CLOUD_POST_APPLIANCE`, and `DELTA_NIU_UAR`.
- Another declares `SET_LOCAL_ROBOT_PASSWORD_REQUEST` and
  `LOCAL_ROBOT_PASSWORD`.
- The cloud command path `appliance/api/v2/appliances/{applianceId}/command`
  is present.
- `LOCAL_NETWORK` appears, but its usage is tied to the provisioning flow and
  permissions, not AC command dispatch.

### v2.0

Key counts:

```text
local HTTP/IP patterns          2
discovery/mDNS/SSDP patterns    9
local/AWS flag patterns         0
provisioning patterns        2705
cloud endpoint patterns       272
```

Key evidence:

- A caller of the TCP socket service passes `192.168.6.1`.
- The socket class opens a TCP/TLS channel to port `3002`.
- The app's network security configuration permits cleartext traffic for
  `192.168.0.1`.
- A command-constant class declares `DELTA_NIU_HTTP_REQUEST`, `OCP_NIU_UAR`,
  `OCP_CLOUD_POST_APPLIANCE`, and the AllJoyn setup commands
  `AJ_NIU_CONNECT_AND_DISCOVER`, `AJ_NIU_WIFI_SCAN`, `AJ_NIU_ONBOARD`.
- Another declares `SET_LOCAL_ROBOT_PASSWORD_REQUEST` and
  `LOCAL_ROBOT_PASSWORD`.
- The cloud command path `appliance/api/v2/appliances/{applianceId}/command`
  is present.
- `LOCAL_NETWORK` appears, but its usage is tied to the provisioning flow and
  permissions, not AC command dispatch.

## Interpretation

The older versions support the hypothesis that early Frigidaire/Electrolux apps
had more local-first setup machinery. However, the local code found is not a
post-pairing LAN API:

- The hard-coded local endpoints are setup SoftAP IPs (`192.168.6.1`, and a
  v2.0 security exception for `192.168.0.1`).
- The local transport is a provisioning socket on port `3002`, not a REST
  appliance-control API.
- Local commands are NIU setup/enrollment operations: WiFi scan/connect, cookie
  signing, cloud password, cloud post appliance, UAR, AllJoyn onboard.
- AC control commands in all inspected versions route through OCP cloud API
  paths such as `/appliance/api/v2/appliances/{applianceId}/command`.
- No mDNS/Bonjour, SSDP/UPnP, static LAN REST endpoint, local websocket, AWS
  Greengrass proxy, or LAN MQTT broker pattern was found.

## Home Assistant / PyPI Check

Findings:

- Home Assistant core `homeassistant/components/electrolux` path returned 404
  from GitHub at the requested `dev` URL.
- `bm1549/home-assistant-frigidaire` describes itself as using the
  "Frigidaire 2.0 (Electrolux) cloud API".
- `TTLucian/ha-electrolux` uses the official Electrolux Group Developer API and
  SSE.
- `sanchosk/electrolux_status` describes the Electrolux Connectivity Platform
  and previously used `pyelectroluxconnect`.
- `pyelectroluxconnect` summary: "Interface for Electrolux Connectivity
  Platform API".
- `pyelectroluxgroup` summary: "Python client for the Electrolux Group API" and
  depends on `aiohttp-sse-client`.
- `pyelectrolux` is not present on PyPI.
- `pyhOn` is for hOn/Haier-family devices and depends on `awsiotsdk`; it is not
  evidence of a Frigidaire local API.

No Home Assistant or PyPI project found in this pass documented a Frigidaire
local LAN control endpoint.

## Conclusion

Older APKs below `3.0` were found and decompiled. They contain local
provisioning transports and stronger setup hints than v3.6, but no usable
post-pairing local HTTP/LAN control API was found. The replacement path remains
cloud API reverse engineering, setup-flow capture on `192.168.6.1:3002` or
`192.168.0.1`, or firmware/device-side work.
