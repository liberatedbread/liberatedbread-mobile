# FC SmartHome / Fingerchip BLE locks (Yi-Lock, eApartment, K3) — target spec starter

## Target metadata
- target_id: fc-smarthome-lock
- app package_id(s): TBD — the vendor ships the same client under several
  names ("FC SmartHome", "Yi-Lock", "eApartment", "K3"); the package ids
  have not been collected yet
- device class: fingerprint / keypad door locks and gun safes from Shenzhen
  Fingerchip (Fingercrystal); one lock model confirmed by the community author
- transport(s): BLE GATT (phone-direct) and a raw TCP socket the lock opens
  to its cloud (port 4067) when woken
- local-only viability: **medium**. The BLE path is phone-direct and needs
  no cloud once a client holds the per-device key, and the TCP channel can be
  redirected on the LAN (NAT or DNS rewrite), but the per-device key comes
  from the vendor's account service today and nobody has shown the redirect
  working end to end.

## Known facts (public; community HA integration, MIT, 2026-09)
- One framing is used on both BLE and TCP: packets delimited by a start
  byte 0xfc and an end byte 0xfe, carrying a category byte, a command byte
  and data (remote unlock is category 0x02, command 0x0e, one data byte
  0x01).
- Payloads are AES-128-ECB, no padding, under a per-device key; the BLE
  handshake takes a bind-user identity and produces a session key. How an
  owner obtains the per-device key without the vendor cloud is **unknown**
  and is the question that decides whether this becomes a spec.
- Remote actions never use HTTP, HTTPS or MQTT: the lock dials TCP 4067
  when it wakes. The integration documents an OpenWrt NAT redirect / DNS
  rewrite of that port to a LAN host, but states it as documented, not
  verified.
- BLE service and characteristic UUIDs are not published in the thread or
  README; the integration treats them as overridable values.
- Source: [HA community thread](https://community.home-assistant.io/t/custom-integration-fc-smarthome-fingerchip-fingercrystal-yi-lock-eapartment-full-reverse-engineering-hacs-release/1025721)
  (2026-09-19, replies to 2026-10-11) and
  [JuanmanDev/fc-smart-home-assistant](https://github.com/JuanmanDev/fc-smart-home-assistant)
  (MIT). The author worked from the vendor APK (v4.6.6) and the vendor's web
  bundle — restate facts, never copy the constants.

## Device discovery signals
- BLE: advertised name pattern unknown; service UUIDs unknown (not in the
  public sources). Live scan needed.
- Wi-Fi: the lock itself is BLE-only; a vendor gateway bridges to TCP 4067.

## Threat model + guardrails
- Owned locks only. **This is a lock**: an unlock command is `advanced`,
  attended, and never a one-tap entity without confirmation.
- The cloud AES-ECB key the integration extracted from the vendor web bundle
  is a vendor secret, not a protocol fact: never commit it. The per-device
  key is the owner's and is placeholdered in every example.
- Do not document anything that bypasses the key (brute force, downgrade).

## First experiments (do these first)
1) Collect the package ids of the four vendor apps and fetch one APK.
2) Static: recover the GATT UUIDs and the handshake message set.
3) Dynamic: HCI snoop of one pair + one unlock on an owned lock; confirm the
   0xfc/0xfe framing and the ECB block alignment on the wire.
4) Establish how the per-device key is issued (account API call? printed?
   derived?) — this gates the spec.

## Protocol hypotheses (to validate)
- Pairing/bonding: application-layer key, probably no link-layer bond.
- Session: handshake → session AES key → framed commands; reply framing
  mirrors request.
- Commands: unlock, lock state, battery, user/fingerprint management (the
  last is out of scope for a first spec).

## Control surface inventory (replacement app MVP)
- unlock (confirmed, attended) · lock state · battery · event log (read)

## References (URLs only)
- https://community.home-assistant.io/t/custom-integration-fc-smarthome-fingerchip-fingercrystal-yi-lock-eapartment-full-reverse-engineering-hacs-release/1025721
- https://github.com/JuanmanDev/fc-smart-home-assistant
