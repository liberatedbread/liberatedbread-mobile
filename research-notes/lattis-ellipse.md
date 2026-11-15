# Lattis Ellipse Smart Bike Lock — Research Notes

## Current finding (2026-11-01)

Already-provisioned Ellipse locks have a local BLE path for lock/unlock,
state, sensors, touchpad code and firmware information. New-phone provisioning
is the hard boundary: the normal V2 flow expects a server-signed message.
Owner export of an existing lock record is a plausible rescue route;
self-issuing that credential is not established.

The earlier draft's encryption description was wrong for this handshake:
V2 uses **MD5 and SHA-256**, not AES. A general AES helper elsewhere in the
app is not evidence for this sequence.

## GATT and V2 session

The advertised security service is
`d3995e00-fa57-11e4-ae59-0002a5d5c51b`; all custom UUIDs share the
`d3995xxx-fa57-11e4-ae59-0002a5d5c51b` base.

1. Write the account/lock public key to `e02`.
2. Write `e03`: lowercase MD5 hex of the user ID, padded with ASCII `f` to 64
   hex characters (32 bytes on wire).
3. Write the cached server-issued signed message to `e01`.
4. Read `e04`; uppercase-hex its raw challenge, append that hex to the
   64-character challenge key, hex-decode the combination and hash SHA-256.
5. Write the lowercase-hex result, hex-decoded, back to `e04`, then read
   hardware info and continue only after an owner/guest verified status.

This proves an existing account/lock relationship; it does not generate a new
signed provisioning message.

Hardware `d3995e40` carries LED `e41`, lock `e42`, five-byte info `e43`,
magnetometer `e44`, connection `e45` and accelerometer `e46`. Lock writes are
`00` unlock, `01` lock, `ff` delayed lock and `ff 00` cancel-delay. Info is
u16 LE battery/voltage (unit unknown), signed temperature (unit unknown),
signed RSSI, then position (0 unlocked, 1 locked, 2 between, 3 invalid).

Configuration `d3995e80` carries reset `e81`, adjustment `e82`, serial `e83`
and touchpad `e84`. The app defines three reset-mode values for writes to the
reset characteristic: `0xbc` shipping mode, `0xbd` factory mode and `0xbe`
development mode (from the August static triage; the exact write framing,
whether an owner session is required first, and what each mode clears are not
established). A numeric touchpad PIN is padded with ASCII `0` to 16
characters, hex-decoded to eight bytes and written to `e84`; whether this is
accepted before owner authentication is unknown. Firmware `d01-d04` resolve
through configuration service `e80` in this build; a separate `d3995d00`
service is not established.

## Safety and remaining work

Lock/unlock is property-security control and must require a validated owner
session. The shipping, factory and development reset modes above are
documented, not withheld, and any spec must flag them `advanced`. If a reset
clears the lock's owner binding (not established), a freshly reset lock is
not re-provisionable without the account backend, so the realistic
consequence is a lock no phone can open. No recovery path is established;
the owner export described above is the most plausible one and should be in
hand before any reset is tried. Freshly reset locks without a surviving account backend remain
unprovisionable on current evidence. The next useful evidence is an owner
export plus one HCI snoop of a successful session, not more guessing at keys.
