# Meross MSG100 Smart Garage Door Opener — Research Notes

## What it is
Meross MSG100 (and MSG100HK HomeKit variant): WiFi add-on garage door
controller, relay output + wired door sensor, ESP8266-class hardware.
Meross (Chengdu) is **active** — meross.com reachable 2026-08-07, app
v3.41.1 current.

## Local path (confirmed)
Every Meross appliance speaks the same local protocol: **plain HTTP POST
`http://<ip>/config`** with a signed JSON envelope. Fully documented in
[arandall/meross doc/protocol.md](https://github.com/arandall/meross/blob/main/doc/protocol.md)
and implemented by the HA integration
[krahabb/meross_lan](https://github.com/krahabb/meross_lan) (iot_class:
local_polling / local push via own MQTT broker).

Envelope:
```json
{"header":{"from":"/config","messageId":"<32 hex>","method":"SET",
 "namespace":"Appliance.GarageDoor.State","payloadVersion":1,
 "sign":"md5(messageId+key+timestamp)","timestamp":<epoch>},
 "payload":{"state":{"channel":0,"open":1}}}
```
- MSG100 namespaces: `Appliance.GarageDoor.State` (GET status / SET
  `{"state":{"channel":0,"open":1|0}}`), plus the common
  `Appliance.System.*` set. Confirmed on-device by openHAB users and the
  rm-it.de MSG100 teardown (2021-06-18).
- `sign = md5(messageId + key + timestamp)`; `key` is a per-device pre-shared
  key normally assigned by the Meross cloud at bind time.
- **Cloud-free provisioning workaround**: an *unconfigured* device does not
  validate the signature, and the whole setup (WiFi via `Appliance.Config.*`,
  then `Appliance.Config.Key` to point at your own key / local MQTT broker)
  can be done locally against the device's AP — see meross_lan discussion #63
  and creatingsmarthome.com local-MQTT guide (2022-08-28). Devices already
  cloud-bound need either the cloud key (extractable from app/account) or a
  factory reset into the unsigned-config path.

## Discovery
No mDNS/SSDP. Devices appear as DHCP clients (MAC prefixes 34:29:8f,
48:e1:e9, ...); meross_lan locates them by IP/DHCP sniffing. Out of the box
the device hosts AP `Meross_XX` for provisioning.

## Cloud status
Optional. App onboarding normally registers a Meross account (email+password)
and binds the device to `iot.meross.com` MQTT (ports 2001/8883/443); all of
that is bypassable as above.

## APK
- Package `com.meross.meross`, v3.41.1 (versionCode 1025), apkeep (APKPure)
  2026-08-07 → `workspace/apks/com.meross.meross.xapk`
- XAPK SHA-256: `0820b48a766a40d61ce74891835b71c15cf47d749cb03fc5aeda8d4c3f55da87`
- Not decompiled — protocol is publicly documented.

## Rating
**Confirmed** — multiple independent implementations (meross_lan,
python-merossio, openHAB binding, rm-it.de analysis).

## Safety
MEDIUM — relay pulse actuates the door with no position supervision of its
own (wired sensor only reports state). Unattended close carries the usual
entrapment caveat.
