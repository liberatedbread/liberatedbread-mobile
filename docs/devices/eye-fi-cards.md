# Eye-Fi X2 / Mobi / Mobi Pro Wi-Fi SD Cards

> **Status**: Spec available; source/offline validated only
> **Protocol**: Card-initiated cleartext HTTP/SOAP on TCP 59278
> **Manufacturer**: Eye-Fi (services discontinued)

## What can be rescued

An **already-configured** Eye-Fi card can push photographs to a local receiver
without the retired Eye-Fi/Keenai services. The **card connects to the
receiver**: a phone, computer, router or NAS listens on TCP 59278. This is not
an outbound camera API and exposes no shutter, delete, format or firmware
command.

A card must already know its Wi-Fi/receiver configuration or have working
direct mode. Historical first-party X2 activation called the retired vendor
registration service, so this guide does **not** promise to activate a reset
card. The mobile app currently has no secure Eye-Fi server transport; the spec
is a host-implementation contract.

## Receiver contract

| Step | Path / action | What the receiver does |
|---|---|---|
| StartSession | `POST /api/soap/eyefilm/v1`, `SOAPAction: "urn:StartSession"` | Read card MAC, client nonce and transfer fields; return credential, fresh server nonce and `upsyncallowed=false` |
| GetPhotoStatus | Same path, `SOAPAction: "urn:GetPhotoStatus"` | Verify second credential and item metadata; return `fileid` and `offset` |
| UploadPhoto | `POST /api/soap/eyefilm/v1/upload`, `SOAPAction: "urn:UploadPhoto"` | Require multipart parts in order: `SOAPENVELOPE`, `FILENAME`, `INTEGRITYDIGEST`; `FILENAME` is a TAR archive and the digest is 32 lowercase hex characters |
| MarkLastPhotoInRoll | Base path, matching SOAP action | Close/expire the roll using a capture-selected compatibility response |

Match XML elements by local name, not namespace prefix. Bound metadata and
request sizes; reject DTDs, external entities, duplicate fields, wrong-path
actions, malformed multipart bodies and replay after roll completion.

Roll completion differs by implementation: the community X2 server returns an
empty success, the reviewed Mobi server does not implement it, and historical
Windows receivers return SOAP fault 2 (`Last Photo`) before closing. Do not
choose one as universally correct without a card capture.

## Credentials and nonces

Concatenate the specified hexadecimal strings, **decode them to bytes**, MD5
those bytes and emit lowercase hex. Do not hash ASCII hex text. The card MAC is
12 hex characters without colons.

| Profile | StartSession response | GetPhotoStatus credential |
|---|---|---|
| X2 with owner upload key | `MD5_bytes(mac + cnonce + upload_key)` | `MD5_bytes(mac + upload_key + snonce)` |
| Reviewed Mobi receiver | Same, with 32 ASCII zeroes as the key | Same, with the same placeholder |

The Mobi placeholder decodes to 16 zero bytes; it is legacy behavior, not a
recommended secret. Mobi Pro infrastructure mode can use its real upload key,
exported from an already-configured mounted card through token `0xfd`.

StartSession alone does not authenticate the card. Verify the second credential
in constant time, bind state to card/session/server nonce/item, use single-use
expiring nonces and define one outstanding transfer policy per card. Never log
owner keys, credential inputs, direct-mode passphrases or real MAC addresses.

The YAML and `scripts/test_eye_fi_cards.py` carry synthetic X2/Mobi vectors
using a documentation-range MAC and invented keys.

## Uploads, resume and safe TAR handling

`filesize` is TAR bytes. Media is the first entry and an optional event log is
second. Community stubs returning `fileid=1, offset=0` do not prove the real
protocol lacks resume. Vendor receiver analysis establishes state keyed by
`filesignature`, reuse of its file ID, new-destination offsets rounded down to
4 KiB and `offset=filesize` for complete items. The `filesignature` algorithm
is unknown. Start with offset zero until an interruption capture exists.

`INTEGRITYDIGEST` is exactly 32 lowercase hexadecimal characters. The reported
algorithm covers each complete 512-byte TAR block: compute the 16-bit Internet
checksum over big-endian 16-bit words with end-around carry, invert it, and
serialize the result as two **big-endian** bytes. Concatenate those checksum
bytes in block order, append the authorized item's 16-byte upload key, then MD5
the result. A trailing partial block is not covered.

The YAML and `scripts/test_eye_fi_cards.py` carry a reproducible synthetic
vector: bytes `00` through `ff` repeated twice produce block checksum `7f80`
and, with the invented X2 key, digest `9190630d60a776ce999f3e1563172826`.
This checks the transcription only; the wire algorithm remains capture-unverified.

Before returning success, match the upload metadata and TAR size to the item
authorized by GetPhotoStatus for this card/session, then recompute and compare
`INTEGRITYDIGEST` using that authorized item's upload key. Reject a mismatch;
do not reuse a key selected only from unverified upload metadata.

**Do not deploy the old extraction code on an untrusted network.** A first
receiver should be single-card and JPEG-only:

- Spool to a bounded temporary file and validate the entire archive before
  extracting anything.
- Accept only regular files/harmless directories. Reject absolute, traversal
  and backslash paths, links, devices, FIFOs, unknown types and normalized or
  case-folded collisions.
- Bound compressed request, expanded total, member count and member size.
  Require consistent JPEG size/start/end markers.
- Use exclusive creation in a controlled destination, never overwrite different
  content, and remove partial output on failure.
- Skip historical geolocation/log sidecars and do not invoke external services.

Return success only after complete safe storage.

## Setup and direct mode

For an already-configured card, back it up and read its existing receiver and
network configuration. X2 and Mobi Pro infrastructure profiles need the owner
upload key. A historical `O 0x06` mounted-card record may allow listener
provisioning, but it is not first-party or hardware-verified; the spec does not
automate it.

Mobi direct mode uses SSID `Eye-Fi Card ` (trailing space included) plus the
last six card-MAC hex digits, WPA2 with the card activation code and DHCP from
the card. Join that existing network and run the restricted receiver. Listener
hints followed by bounded subnet candidates are reported, but the selected
receiver IP after DHCP is not established; do not scan indefinitely.

Changing routers/receivers may require mounted-card reconfiguration, not a
factory reset. No reset procedure or offline reactivation path is established;
do not erase a working card to test the retired cloud flow.

## Mounted-card configuration

The public configuration utility uses four 16384-byte zero-padded files under
`EyeFi/`, not one XML file:

| Record | Role |
|---|---|
| `reqm` | Host request buffer |
| `reqc` | Request sequence |
| `rspm` | Card response buffer |
| `rspc` | Response sequence/status |

An information request is ASCII `o` plus a one-byte subcommand. A one-byte write
is ASCII `O`, subcommand, length `01`, value. Increment the previous response
sequence (seed `0x1234` if zero), write `reqc`, poll `rspc` up to 50 times at
300 ms intervals and accept only a fresh matching response. The reference Linux
utility treats sequence values as native u32/little-endian; do not generalize
that without checking the card representation.

Read tokens include MAC `01`, firmware `02`, upload API `04`, transfer mode
`11`, direct-mode SSID/passphrase `22`/`23`, timers `24`/`25`, and owner-only
upload key `fd`. Network changes, AP start and reboot are unverified writes;
back up and obtain owner consent. The utility also has a compiler-reported
mount-path lifetime warning.

## Security and firmware boundaries

Use an isolated direct-mode network or trusted segmented LAN. Never expose TCP
59278 publicly. Photographs are private: avoid content logs, onward sync and
unbounded retention. Set `upsyncallowed=false` for a local-only receiver.

A receiver can reportedly offer `fwversion`, after which the card requests
`GET /api/firmware/<MAC>`. Signed-image enforcement is reported but untested;
no image, compatibility or recovery claim is made. This is an advanced card-pull
mechanism, not a generic update command.

Remaining evidence needed: real X2/Mobi/Mobi Pro sessions, roll completion,
receiver-IP selection, `filesignature`, nonzero resume, concurrent cards,
RAW/video variants and reset-card activation.

## References

- [Archived Eye-Fi Mobi quick guide](https://archive.org/download/manualzilla-id-6177979/6177979.pdf)
- [Eye-Fi Pro X2 manual](https://www.manualslib.com/manual/1565254/Eyefi-Pro-X2.html)
- [`eyefiserver2`](https://github.com/dgrant/eyefiserver2)
- [`node-eyefimobiserver`](https://github.com/michaelbrandt/node-eyefimobiserver)
- [`eyefi-config`](https://github.com/hansendc/eyefi-config)
