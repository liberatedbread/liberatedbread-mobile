# Spotify Car Thing (`superbird`) — Research Notes

Checked 2026-10-31. Vendor status plus current Mira, Nocturne and bridgething
source/protocol review. No flashing or physical test was performed.

## What changed

The older “no documented live interface” conclusion is stale **for custom
firmware**, not for stock Spotify firmware. Spotify still says the stock
product is discontinued and will no longer operate. None of the custom paths
proves a reusable stock pairing or command protocol.

- **Mira** offers standalone open firmware after USB installation. Spotify
  sign-in and internet remain necessary; there is no companion control API.
- **Nocturne** has a companion/connector ecosystem. Mobile functionality is
  paid and its companion/backend are private; daemon wire types are open.
- **bridgething** has a versioned host protocol and stock-webapp gateway
  contract, making it the strongest documented third-party integration path.

All three require custom-firmware installation. Flashing wipes prior firmware;
this is not a non-destructive app install.

## bridgething host protocol

Gateway transports are Bluetooth Classic RFCOMM, iAP2 External Accessory and
network WebSocket port 8892. Payload is MessagePack normally, JSON accepted.
The local webapp uses WebSocket 8891, with a stock compatibility socket on
8890.

Version-2 frame:

```text
0   2  magic dead, big-endian
2   1  version = 2
3   1  compression: 0 none, 1 gzip
4   1  encoding: 0 MessagePack, 1 JSON
5   1  priority: 0 normal, 1 bulk, 2 background
6   2  reserved zero
8   8  payload length, big-endian u64
16  N  compressed or plain envelope
```

Length is the post-compression size, capped at 16 MiB. Envelopes carry a
fresh UUID, command/event/request/response metadata and typed data; responses
correlate by UUID. Network WebSocket messages carry whole frames with a 1 MiB
cap. Large resources use typed references and ordered fragments, with 4 KiB
daemon fragments and a 256 KiB in-memory transfer cap.

RFCOMM service UUID is `dead0000-854d-408e-81f0-fb6147f918fd`, channel 1.
iAP2 protocol name is `com.bridgething.gateway`. The stock-webapp contract
maps library browse, artwork, player state, queue, favorite and playback calls
onto the modern typed surfaces.

## App implications and open questions

A generic controller should target bridgething v2, not assume the dead stock
protocol. The current mobile app has no RFCOMM/iAP2 or MessagePack v2 gateway
transport, and adding one belongs with custom-firmware user onboarding and a
LAN authentication review, not a stock-device support claim. Mira is the
simplest owner rescue; Nocturne's private mobile tier and paid features need
separate evaluation.

Unverified: physical framing/reconnect/audio, network-gateway access control,
Nocturne private companion behavior and every stock-firmware protocol detail.
