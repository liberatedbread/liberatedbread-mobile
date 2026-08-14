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

### Google Play scraper

`google-play-scraper` was installed and queried successfully. It returned only
current public Play metadata, not a historical APK list:

- Current Play version observed: `4.26`
- Updated timestamp reported by scraper: `1783938039`
- Release date: `Mar 27, 2023`
- Reviews fetched: 752; recent reviews reported app versions `4.25` and `4.26`
- Permissions endpoint returned 18 permission strings

Evidence: `workspace/frigidaire/evidence/google_play_scraper.txt`

### apkeep / APKPure

`apkeep --list-versions` was the useful source. It exposed:

- `1.24`
- `2.0`
- `3.6`

Downloaded files:

- `workspace/frigidaire/old_apks/com.electrolux.oneapp.android.frigidaire@1.24.xapk`
- `workspace/frigidaire/old_apks/com.electrolux.oneapp.android.frigidaire@2.0.xapk`
- `workspace/frigidaire/old_apks/com.electrolux.oneapp.android.frigidaire@3.6.xapk`

SHA-256:

```text
67e79350b1e39d1b084b6578d5a46925db3fc06ba7b9dbb35a46775c0862f3cf  com.electrolux.oneapp.android.frigidaire@1.24.xapk
032e869b706275e94dd1fa2b3222e6d4e8a5d2591d7344f95bd7147869170f66  com.electrolux.oneapp.android.frigidaire@2.0.xapk
0fa212791d3f488eaffbbb1dbc628b7c988d786e1546be32fcc297795a6c99aa  com.electrolux.oneapp.android.frigidaire@3.6.xapk
```

Manifest versions:

```text
1.24 versionCode 5851
2.0  versionCode 6895
3.6  versionCode 504110958
```

### APKCombo

The requested APKCombo grep found only:

- `download/apk`
- `download/phone-4.26-apk`
- `download/phone-4.25-apk`
- `download/phone-4.24-apk`

The `old-versions` page currently lists only `4.24`, `4.25`, and `4.26`.
No pre-3.0 APKCombo entry was found.

Evidence:

- `workspace/frigidaire/evidence/apkcombo_frigidaire.html`
- `workspace/frigidaire/evidence/apkcombo_old_versions.html`
- `workspace/frigidaire/evidence/apkcombo_download_paths.txt`
- `workspace/frigidaire/evidence/apkcombo_old_versions_lines.txt`

### APKSupport

The requested APKSupport grep returned no `variant...` matches. The fetched
page was saved for provenance.

Evidence:

- `workspace/frigidaire/evidence/apksupport_download_app.html`
- `workspace/frigidaire/evidence/apksupport_variants.txt`

### GitHub

The installed `gh` binary does not support `gh search code`; it returned
`unknown command "search"`. GitHub's unauthenticated code-search API returned
`Requires authentication`.

Web search found Home Assistant/custom integrations, but no archived APK URL or
hash below `3.0`.

Evidence:

- `workspace/frigidaire/evidence/gh_search_package.txt`
- `workspace/frigidaire/evidence/github_api_search_package.json`

### Internet Archive

Wayback CDX for APKPure returned one archived URL for the package landing page:

```text
20250726080124 https://apkpure.com/frigidaire/com.electrolux.oneapp.android.frigidaire 200 text/html
```

No archived APK download artifacts were found from that CDX query.

Evidence:

- `workspace/frigidaire/evidence/wayback_apkpure_cdx.json`
- `workspace/frigidaire/evidence/wayback_apkpure_summary.txt`

### Aurora Store / F-Droid

No F-Droid package is expected for this proprietary app. No usable Aurora API
endpoint was available in this workspace. Google Play metadata was checked with
`google-play-scraper` instead.

## Decompilation

The old XAPKs were extracted and base APKs were decompiled:

- `workspace/frigidaire/jadx_1_24/`
- `workspace/frigidaire/jadx_2_0/`
- Existing current build: `workspace/frigidaire/jadx/`

Each XAPK contained a base `com.electrolux.oneapp.android.frigidaire.apk` plus
resource/config split APKs. Static analysis used the base APK.

## Local API Sweep Results

### v3.6

Requested pattern results:

```text
rg_192_168.txt                 1
rg_localhost.txt               2
rg_http_server_local.txt       0
rg_mdns_nsd.txt                1
rg_ssdp_upnp.txt               0
rg_local_rest_ws.txt           0
rg_feature_flags_local.txt     0
rg_aws_iot.txt                 0
rg_provisioning.txt         1739
rg_cloud_endpoints.txt       466
```

Key evidence:

- `Im/V.java` connects to `192.168.6.1` port `3002`.
- `Im/C0447t.java` builds `http://` or `https://` URLs from a discovered setup
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

- `zo/l.java` calls the TCP socket service with `192.168.6.1`.
- `zo/b.java` opens a TCP/TLS channel to port `3002`.
- `cn/l.java` includes `DELTA_NIU_HTTP_REQUEST`, `DELTA_NIU_COOKIE_SIGN`,
  `DELTA_NIU_SET_CLOUD_PASSWORD`, `DELTA_CLOUD_POST_APPLIANCE`, and
  `DELTA_NIU_UAR`.
- `ln/g.java` includes `SET_LOCAL_ROBOT_PASSWORD_REQUEST` and
  `LOCAL_ROBOT_PASSWORD`.
- `im/w1.java` contains the cloud command path
  `appliance/api/v2/appliances/{applianceId}/command`.
- `on/r.java` contains `LOCAL_NETWORK`, but usage is tied to provisioning flow
  and permissions, not AC command dispatch.

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

- `gs/l.java` calls the TCP socket service with `192.168.6.1`.
- `gs/b.java` opens a TCP/TLS channel to port `3002`.
- `resources/res/xml/network_security_config.xml` permits cleartext traffic
  for `192.168.0.1`.
- `iq/l.java` includes `DELTA_NIU_HTTP_REQUEST`, `OCP_NIU_UAR`,
  `OCP_CLOUD_POST_APPLIANCE`, and AllJoyn setup commands
  `AJ_NIU_CONNECT_AND_DISCOVER`, `AJ_NIU_WIFI_SCAN`, `AJ_NIU_ONBOARD`.
- `rq/g.java` includes `SET_LOCAL_ROBOT_PASSWORD_REQUEST` and
  `LOCAL_ROBOT_PASSWORD`.
- `pp/w1.java` contains the cloud command path
  `appliance/api/v2/appliances/{applianceId}/command`.
- `tq/o.java` contains `LOCAL_NETWORK`, but usage is tied to provisioning flow
  and permissions, not AC command dispatch.

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
