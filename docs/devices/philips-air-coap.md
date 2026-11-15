# Philips Wi-Fi Air Purifiers and Humidifiers (encrypted CoAP)

> **Status**: Spec Available (unverified)
> **Protocol**: WiFi (CoAP over UDP 5683, AES-128-CBC payload envelope)
> **Manufacturer**: Philips (Versuni, formerly Philips Domestic Appliances)
> **Manufacturer Status**: Active. Local access is unofficial, and some firmware updates are reported to remove it.

## Overview

Philips connected purifiers, 2-in-1 purifier/humidifiers, humidifiers, fan
heaters and fans have model numbers starting AC, AMF, CX and HU. Many of them
run a small CoAP server on UDP port 5683. Any host on the home network can use
it, with no Philips account and no pairing. Three resources carry the whole
API:

| Path | Method | Purpose |
|------|--------|---------|
| `/sys/dev/sync` | POST | Swap a random 8-hex-digit value for the device's counter |
| `/sys/dev/status` | GET + Observe 0 | Full status, pushed again on every change |
| `/sys/dev/control` | POST | Write desired state; replies `{"status":"success"}` |

Status and control bodies are wrapped in an envelope. The AES key comes from
the counter and a fixed string, `JiangPan`, which is published as a constant
in every open-source client. The key is the same on every unit, so the
encryption hides traffic from a casual look but protects nothing.

The protocol was reverse engineered by Radoslav Gerganov
([py-air-control](https://github.com/rgerganov/py-air-control)).
[aioairctrl](https://github.com/betaboon/aioairctrl) re-implemented it, and the
[kongo09 Home Assistant integration](https://github.com/kongo09/philips-airpurifier-coap)
keeps the per-model key tables.

### Which units this covers

Philips has shipped three local protocols. This spec covers only the third:

1. **HTTP generation**: older Wi-Fi units. They use HTTP on port 80 under
   `/di/v1/products/...`, with a Diffie-Hellman key exchange, AES and SSDP
   discovery. They are out of scope here.
2. **Plain CoAP**: unencrypted JSON on 5683, sent after an ICMP "hello". This
   is also out of scope.
3. **Encrypted CoAP**: every model the Home Assistant integration supports.

Inside generation 3 the JSON keys come in three dialects. The spec treats them
as `device.variants`:

| Key set | How to tell | Example models |
|---------|-------------|----------------|
| `classic-keys` | status has `modelid` | AC2729, AC2889, AC3829, AC3033, AC4236, AC5659 |
| `dashed-keys` | status has `D01-05` | AC1715, AC0850 (Wi-Fi string `AWS_Philips_AIR`) |
| `compact-keys` | status has `D01S05` | AC0850 Combo, AC0950, AC22xx, AC3420, AMF765, CX3120, HU4209, HU5710 |

The compact set needs JSON integers for every `D03…` value.

### Local access is fragile

The integration's README warns about two problems. Some models have newer
firmware that no longer allows local connections. Units that do work can also
drop the CoAP session until they are power-cycled. No source names the
firmware version that removed access. The AC0651 has never been made to
answer, and some AC1715/11 units refuse the connection. Owners keep working
firmware by blocking the purifier's internet access. Do this before an update
arrives, not after.

## Initial Setup

| Property | Value |
|----------|-------|
| Setup required | Yes. Wi-Fi is provisioned by the Philips app with a Philips account |
| Method | `cloud_account` (pairing-mode hold on the unit, then the app) |
| Setup AP | `PHILIPS Setup` (open), while the Wi-Fi light blinks orange |
| Passphrase protection | unknown |
| Confidence | low |

To enter pairing mode, power the unit on and hold its pairing button (or
button pair) for about 3 seconds until it beeps. The button differs by model:
the AC2729 uses power plus child lock together, and the AC0850/20 manual
describes a single 3-second hold. Philips requires a 2.4 GHz network. No
open-source client provisions this generation's Wi-Fi without the app.

After the unit is on the LAN, a local client only needs its address. The unit
advertises no mDNS or SSDP service. Home Assistant finds it from DHCP: MAC
prefixes 68:79:C4, B0:F8:93, 04:78:63, 84:9D:C2 and 80:A0:36, or a hostname
starting with `mxchip`. Reserve the address in DHCP, and key a stored unit by
the `DeviceId` in its status.

**Factory reset**: Philips support gives a general procedure. Hold power and
mode together for 10 seconds until the unit beeps. It is meant for a unit that
was registered to a different Philips account. This has not been verified per
model. It is a different action from the 3-second Wi-Fi re-pair hold and from
the 5-second mode hold that resets the filter counter (AC0850/20 manual).

**Rebinding to a new network**: enter pairing mode and provision the unit again
from the app. No local command changes Wi-Fi on this generation.

## Pairing

| Property | Value |
|----------|-------|
| Pairing required | No |
| Security mode | `none` (the shared-key envelope is public) |
| Bonding | `none` |
| One client at a time | Unknown. The clients open independent sessions |
| Confidence | medium (three clients agree) |

## Protocol Summary

### Session

1. `POST /sys/dev/sync` with 8 random uppercase hex digits, for example
   `1A2B3C4D`. The unit replies with its counter, for example `6D2C0F41`.
2. Before each envelope it sends, the client adds one to the counter. The first
   control write after that sync is sealed under `6D2C0F42`. The counter is
   32-bit, written as exactly 8 uppercase hex digits. aioairctrl wraps
   `FFFFFFFF` to `00000000`.
3. `GET /sys/dev/status` with Observe 0. Every notification is a full status.
   Home Assistant reconnects after three missed Max-Age periods; Max-Age
   defaults to 60 s.
4. Write with `POST /sys/dev/control`. If the reply is anything other than
   `{"status":"success"}`, sync again and retry.

### Envelope

```
H       = upper(hex(MD5("JiangPan" + counter)))      # 32 ASCII chars
key, iv = ascii(H[0:16]), ascii(H[16:32])            # AES-128-CBC, PKCS#7
C       = upper(hex(AES_CBC(key, iv, json_plaintext)))
D       = upper(hex(SHA256(counter + C)))            # plain hash, not HMAC
wire    = counter + C + D
```

The key and IV are the hex characters themselves. Do not hex-decode them.
`protocol_details.envelope.test_vectors` in the spec carries three worked
envelopes built from invented counters, and
`scripts/test_philips_air_coap_spec.py` rebuilds each of them.

### Control document

```json
{"state": {"desired": {"CommandType": "app", "DeviceId": "", "EnduserId": "", "pwr": "1"}}}
```

The three fixed members are always sent empty. You can set several keys in one
write.

### Main keys

| Function | classic | dashed | compact |
|----------|---------|--------|---------|
| Power | `pwr` `"1"`/`"0"` | `D03-02` `"ON"`/`"OFF"` | `D03102` 1/0 |
| Mode | `mode` P/A/S/M/B/N/T/GT | `D03-12` "Auto General", "Sleep", "Turbo", … | `D0310C` 0 auto, 1-5, 17 sleep, 18 turbo, 19 medium, 65 high |
| Fan speed | `om` 1/2/3/t with mode M; silent is `om` s with mode S | n/a | inside `D0310C`; AC0950 and AC3420 also need `D0310D` in the same write |
| Child lock | `cl` true/false | n/a | `D03103` 1/0 |
| Display light | `aqil` 0-100, `uil` "1"/"0" | `D03-05` 100/0 | `D0312D` / `D03105` |
| Timer | `dt` hours 0-12 | n/a | `D03110` code 0-13 |
| Target humidity | `rhset` 40/50/60/70 | n/a | `D03128` |
| Function | `func` P/PH | n/a | `D0310A` |
| PM2.5 | `pm25` | `D03-33` | `D03221` |
| Allergen index | `iaql` | `D03-32` | `D03120` |
| Humidity / temp | `rh` / `temp` | n/a | `D03125` / `D03224` (tenths of °C) |
| Filters (hours left) | `fltsts0/1/2`, `wicksts` | `D05-13`, `D05-14` | `D0520D`, `D0540E` |
| Water / errors | `wl`, `err` | n/a | `D03240` |

"n/a" means no source documents that key for the set. The full tables, value
meanings and per-model notes are in `protocol_details.key_sets`.

## Tools Used

- Source reading only: py-air-control, aioairctrl (master and the 0.3.1 PyPI
  release) and the kongo09 integration. Nothing was run against hardware.

## References

- [rgerganov/py-air-control](https://github.com/rgerganov/py-air-control)
- [betaboon/aioairctrl](https://github.com/betaboon/aioairctrl) and its
  maintained fork [kongo09/aioairctrl](https://github.com/kongo09/aioairctrl)
- [kongo09/philips-airpurifier-coap](https://github.com/kongo09/philips-airpurifier-coap)
- [Philips: I cannot connect my Philips Air Purifier with the App](https://www.usa.philips.com/c-t/XC000019027/i-cannot-connect-my-philips-air-purifier-with-the-app)
- [Philips AC0850/20 user manual (manualsnet)](https://manualsnet.com/philips/ac0850-20-ac0850)

## Contributors

- Spec drafted from the open-source clients above (clean-room, no vendor app
  internals).
