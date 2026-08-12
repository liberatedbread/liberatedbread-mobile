# Frigidaire Connected Air Conditioners

> **Status**: Research
> **Protocol**: WiFi (cloud-connected; local setup only)
> **Manufacturer**: Frigidaire (Electrolux)
> **Manufacturer Status**: Unsupported (cloud-dependent — if Electrolux shuts down servers, app control is lost)

## Overview

Frigidaire sells WiFi-connected air conditioners across three product families: window units,
portable units, and wall-mounted/PTAC units. All are controlled through the Frigidaire app
(Electrolux platform) and communicate via the Electrolux cloud. This makes them vulnerable
to bricking if Electrolux discontinues the cloud service.

This is the first HVAC/climate device category in the OpenGreenIoT project. APK
static analysis has now been completed for the active Frigidaire Android app
package. The control protocol still needs authenticated traffic captures for
exact payload schemas, but local discovery is no longer open: no post-pairing
LAN control path was found.

## Hardware

### Window AC (FHWW / GHWQ Series)

| Property | Value |
|----------|-------|
| Models | FHWW082WCE (8K BTU), FHWW102WCE (10K BTU), FHWW152WCE (15K BTU) |
| Gallery Models | GHWQ083WC1 (8K BTU, adds ionizer) |
| Radio | WiFi 802.11 b/g/n (2.4 GHz) |
| Chipset | TBD |
| FCC ID | TBD |

### Portable AC (FHPC / FHPH Series)

| Property | Value |
|----------|-------|
| Models | FHPC082AC1 (8K BTU), FHPH132AB1 (13K BTU) |
| Radio | WiFi 802.11 b/g/n (2.4 GHz) |
| Chipset | TBD |
| FCC ID | TBD |

### Wall-Mounted / PTAC

| Property | Value |
|----------|-------|
| Models | TBD — specific connected model numbers need verification |
| Radio | WiFi 802.11 b/g/n (2.4 GHz, expected) |
| Chipset | TBD |
| FCC ID | TBD |

## Protocol Summary

!!! note "Static Analysis Finding"
    Frigidaire `com.electrolux.oneapp.android.frigidaire` v1.24 / versionCode
    5851, v2.0 / versionCode 6895, and v3.6 / versionCode 504110958 were pulled
    from APKPure via `apkeep` and decompiled with `jadx`. The older v1.24/v2.0
    builds contain more legacy local setup machinery than v3.6, including a
    Delta NIU TCP/TLS provisioning stack on `192.168.6.1:3002`,
    `DELTA_NIU_HTTP_REQUEST`, `LOCAL_ROBOT_PASSWORD`, and in v2.0 a cleartext
    network-security exception for `192.168.0.1`. These are still
    provisioning/enrollment paths. No mDNS, SSDP/UPnP, `.local`, AWS
    Greengrass, MQTT local proxy, static-IP REST API, or post-pairing LAN
    control path was found for AC control.

### Architecture

```
┌──────────────┐    WiFi    ┌──────────────────┐    HTTPS/WSS     ┌──────────────────┐
│  AC Unit     │◄──────────►│  Home Router     │◄───────────────►│  Electrolux OCP  │
│  (WiFi SoC)  │            │                  │                 │  Cloud           │
└──────────────┘            └──────────────────┘                 └────────┬─────────┘
                                                                         │
                                                                         │ HTTPS/WSS
                                                                         ▼
                                                                ┌──────────────────┐
                                                                │  Frigidaire App  │
                                                                │  (Mobile)        │
                                                                └──────────────────┘
```

### Discovery and Authentication

- **Device class**: WiFi cloud appliance.
- **Local discovery**: Closed as cloud-only for post-pairing control. No SSDP,
  mDNS, NSD, `.local`, UPnP, static-IP HTTP API, MQTT LAN broker, or AWS
  Greengrass/local proxy path was found in APK static analysis.
- **Local provisioning**: Present. The app references appliance SoftAP names
  beginning with `AJ`, `@E`, `IOT`, `Air_Conditioner`, or `Dehumidifier`,
  AllJoyn onboarding/enrollment, UDP broadcast on port 3000, and
  `192.168.6.1:3002`.
- **User discovery path**: Pair the AC in the Frigidaire/Electrolux app, then
  enumerate appliances from the authenticated Electrolux cloud/OCP account.
- **Replacement implication**: A local-first replacement likely needs confirmed
  cloud API behavior, DNS redirection plus protocol capture, or firmware work.
  A LAN scan alone is not expected to produce a usable post-pairing control
  endpoint.

### Transport

- **Primary**: WiFi to Electrolux OCP cloud over HTTPS REST plus websocket paths
  observed in APK strings.
- **Local API**: No steady-state LAN control API found.
- **Provisioning**: App-based pairing over SoftAP/AllJoyn/OCP provisioning.

### APK Evidence

| Item | Finding |
|------|---------|
| Active Android package | `com.electrolux.oneapp.android.frigidaire` |
| Analyzed app versions | v1.24 / versionCode 5851; v2.0 / versionCode 6895; v3.6 / versionCode 504110958 |
| Fetch result | `apkeep --list-versions` exposed APKPure versions `1.24`, `2.0`, and `3.6`; APKCombo currently lists only newer `4.24`-`4.26` old-version pages |
| Legacy XAPK SHA-256 | v1.24 `67e79350b1e39d1b084b6578d5a46925db3fc06ba7b9dbb35a46775c0862f3cf`; v2.0 `032e869b706275e94dd1fa2b3222e6d4e8a5d2591d7344f95bd7147869170f66` |
| XAPK SHA-256 | `0fa212791d3f488eaffbbb1dbc628b7c988d786e1546be32fcc297795a6c99aa` |
| Decompiler | `jadx` completed with recoverable errors |
| Local setup endpoints | `192.168.6.1:3002`; v2.0 also allows cleartext to `192.168.0.1` |
| Local provisioning broadcast | UDP port 3000 |
| Provisioning frameworks | Delta NIU TCP/TLS setup, AllJoyn onboarding/enrollment, ECP/OCP provisioning models |
| Post-pairing LAN discovery | Not found |

Older-version local setup strings and enums include:

- `DELTA_NIU_HTTP_REQUEST`
- `DELTA_NIU_COOKIE_SIGN`
- `DELTA_NIU_SET_CLOUD_PASSWORD`
- `DELTA_CLOUD_POST_APPLIANCE`
- `OCP_CLOUD_POST_APPLIANCE`
- `AJ_NIU_CONNECT_AND_DISCOVER`
- `AJ_NIU_WIFI_SCAN`
- `AJ_NIU_ONBOARD`
- `SET_LOCAL_ROBOT_PASSWORD_REQUEST`
- `LOCAL_ROBOT_PASSWORD`

These are provisioning/setup operations, not discovered AC runtime control
endpoints.

Observed cloud/OCP strings include:

- `https://api.ocp-dev.electrolux.one`
- `https://api.ocp-staging.electrolux.one`
- `https://frigidaire.app.electrolux.one/`
- `wss://ws.eu.ocp-dev.electrolux.one`
- `wss://ws.eu.ocp-staging.electrolux.one`
- `/appliance/api/v2/appliances?includeMetadata=true`
- `/appliance/api/v2/appliances/{applianceId}/command`
- `/appliance/api/v3/appliances/info`
- `/remote-control/api/v1/appliances/`

### Authentication

- Electrolux/Frigidaire user account (OAuth2/OCP flow expected)
- Device-to-cloud authentication (certificate or token-based, still needs traffic capture)

## Commands

### Power

| Command | Description |
|---------|-------------|
| `set_power_on` | Turn AC on |
| `set_power_off` | Turn AC off |

### Mode

| Command | Value | Description |
|---------|-------|-------------|
| `set_mode` | `cool` | Cooling mode |
| `set_mode` | `eco` | Energy saver / eco mode |
| `set_mode` | `fan_only` | Fan only (no compressor) |
| `set_mode` | `dehumidify` | Dehumidify mode (portable only) |

### Temperature

| Command | Range | Description |
|---------|-------|-------------|
| `set_temperature` | 60-90°F (16-32°C) | Set target temperature |

### Fan Speed

| Command | Value | Description |
|---------|-------|-------------|
| `set_fan_speed` | `auto` | Automatic fan speed |
| `set_fan_speed` | `low` | Low speed |
| `set_fan_speed` | `medium` | Medium speed |
| `set_fan_speed` | `high` | High speed |

### Other Controls

| Command | Description |
|---------|-------------|
| `set_timer` | Set on/off timer (0.5-24 hours) |
| `set_sleep_on/off` | Enable/disable sleep mode |
| `set_display_on/off` | Toggle display |
| `set_clean_air_on/off` | Toggle ionizer (Gallery models only) |
| `reset_filter` | Reset filter alert after cleaning |

## Home Assistant Entities

| Entity | Platform | Device Class | Notes |
|--------|----------|-------------|-------|
| Air Conditioner | `climate` | — | Main control: power, mode, temp, fan |
| Room Temperature | `sensor` | `temperature` | Current room temperature |
| Filter Alert | `binary_sensor` | `problem` | Needs cleaning indicator |
| Sleep Mode | `switch` | — | Sleep mode toggle |
| Display | `switch` | — | Display on/off |
| Clean Air | `switch` | — | Ionizer (Gallery window models only) |
| Drain Full | `binary_sensor` | `problem` | Tank full (portable models only) |

## Tools Used

- [ ] mitmproxy — HTTPS/websocket traffic capture between app and cloud
- [ ] Wireshark — network packet analysis
- [x] jadx — APK decompilation and static analysis
- [x] apkeep — APK retrieval from APKPure using the active package ID
- [ ] nmap — local network scan for device services
- [ ] Frida — runtime app instrumentation (if needed for certificate pinning bypass)

## Next Steps

1. **Network capture**: Set up mitmproxy or equivalent to capture app-to-cloud HTTPS/websocket traffic during control operations
2. **Confirm production base URL selection**: Determine how the app selects production versus dev/staging OCP hosts at runtime
3. **Validate payload schemas**: Compare actual traffic against the observed REST paths and AC capability JSON assets
4. **Optional device-side scan**: During setup, inspect the SoftAP at `192.168.6.1:3002`; after pairing, verify the device does not expose unexpected LAN services on the home network

## References

- Frigidaire Connected Products: https://www.frigidaire.com/owner-center/connect/
- Frigidaire App on Google Play: https://play.google.com/store/apps/details?id=com.electrolux.oneapp.android.frigidaire
- Home Assistant custom component using Frigidaire/Electrolux cloud API: https://github.com/bm1549/home-assistant-frigidaire
- Electrolux official API portal: https://portal-eu-prod.electrolux.com/

## Contributors

- OpenGreenIoT community — initial target spec and hypothesized protocol documentation
