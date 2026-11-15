# Edimax SP-1101W / SP-2101W Smart Plug — Research Notes

## What it is
Edimax (Taiwan, alive as a networking company) SP-1101W (switching) and
SP-2101W (switching + power metering) Wi-Fi smart plugs, ~2014-2018, managed
by the EdiPlug app. The app and Edimax's remote-access cloud are legacy, but
the plug's local HTTP API works regardless.

## Local protocol — confirmed
Community libraries: [wendlers/ediplug-py](https://github.com/wendlers/ediplug-py)
(Python), [Wandmalfarbe/Edimax-Smart-Plug-Java](https://github.com/Wandmalfarbe/Edimax-Smart-Plug-Java),
plus the Home Assistant `edimax` integration (`iot_class: local_polling`).

- **HTTP POST** to `http://<plug-ip>:10000/smartplug.cgi`
- **Auth**: HTTP Basic, default credentials `admin` / `1234`
  (user-changeable via the plug's own web UI).
- **Payload**: XML documents describing the command. The `ediplug-py` source
  contains the full XML templates: switching (`NOW_POWER` with
  `Device.System.Power.State` ON/OFF), power-meter readout
  (`NOW_POWER` returning current power W / energy Wh on SP-2101W), schedule
  read/write (`SCHEDULE`), and system info (`SYSTEM_INFO`).
- The plug also runs a plain web interface (port 80) with the same
  credentials for manual control/config.

## Cloud dependency: none
Local control uses only the LAN HTTP endpoint. The EdiPlug app's cloud is only
needed for out-of-home access; the plug keeps working with WAN blocked.
Provisioning is via the plug's setup AP + app or WPS; credentials (admin/1234
defaults) are local-only. No account is tied to the device.

## APK
EdiPlug (`com.edimax.ediplug`) fetch via apkeep attempted 2026-08-07:
Google Play source rejected with auth error; retried via apk-pure (result
recorded in YAML if successful). Not required — protocol fully documented by
ediplug-py XML templates.

## Safety
LOW. Mains relay (SP-2101W rated 15 A region-dependent). HTTP Basic with a
well-known default password — change it or LAN-segment.
