# D-Link DSP-W215 (and DSP-W110) mydlink Smart Plug — Research Notes

## What it is
D-Link mydlink-era Wi-Fi smart plugs: DSP-W215 (2014, switching + energy +
thermal cutoff) and older DSP-W110 (switching only). D-Link is alive, but the
mydlink app dropped support for the DSP-W215 in the 2023 app version (per the
Node-RED `dsp-w215` node README) — the local HNAP API is the rescue path.

## Local protocol — confirmed
The plugs speak **HNAP** (Home Network Administration Protocol: SOAP/XML over
HTTP) on port 80, the same stack as D-Link routers of the era. Famously
reverse engineered by Craig Heffner /dev/ttyS0 (2014, "hacking the
D-Link DSP-W215" series) and implemented in:

- [LinuxChristian/pyW215](https://github.com/LinuxChristian/pyW215) — Python 3
  library (inspired by @bikerp's JS `dsp-w215-hnap`)
- `dsp-w215-hnap` (node.js) and its Node-RED wrapper
- Domoticz bundled plugin `examples/Dlink DSP-W215.py`

HNAP details:
- **Endpoint**: `POST http://<plug-ip>/HNAP1/` with `SOAPAction` headers such
  as `"http://purenetworks.com/HNAP1/SetSocketSettings"` (relay on/off),
  `GetSocketSettings`, `GetCurrentPowerConsumption` /
  `GetCurrentPowerState` (W215 metering), `GetDeviceSettings`.
- **Auth**: HNAP challenge/response login — client requests
  `Login` with Action `request`, receives Challenge/Cookie/PublicKey, then
  proves knowledge of the admin password via HMAC-MD5. The device admin
  password defaults to the **PIN printed on the plug's label/card** (set
  during mydlink-era onboarding); it is a device-local secret, not a cloud
  credential.

## Cloud dependency
- Control: 100% local once the plug is on the LAN and you know the admin
  PIN/password. WAN can be blocked.
- Provisioning: historically the mydlink app (account optional for local
  onboarding? — the app used a local Wi-Fi handshake to the plug's setup AP;
  the account was only for remote access). Caveat worth verifying per unit.
- Firmware note: the W215 had serious HNAP auth-bypass CVEs (devttys0 2014;
  unpatched for years) — another reason to keep it on a segmented LAN.

## DSP-W110 status
Same mydlink generation and HNAP-based local control per community reports,
but less thoroughly documented than W215 — treat W110 as hypothesis, W215 as
confirmed.

## APK
Not fetched — mydlink is a large multi-device app and the protocol is already
documented by pyW215 + devttys0.

## Safety
LOW (mains relay; W215 adds over-temperature cutoff). Unpatched HNAP
vulnerabilities make LAN segmentation strongly advised.
