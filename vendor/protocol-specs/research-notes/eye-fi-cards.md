# Eye-Fi X2 / Mobi Wi-Fi SD Cards — Research Notes

Consolidated 2026-11-06 from public receiver implementations, mounted-card
configuration tooling, historical vendor applications and desktop utilities.
No physical card, real photograph or network capture was used by this project.
The reviewed public implementations reported 86 offline checks, including a
four-call loopback receiver session and hostile-archive cases.

## What can be rescued

An already-configured X2-era or Mobi card can push photos to a local receiver
without the retired cloud. The **card connects to the receiver**: a phone,
computer, router or NAS listens for cleartext HTTP/SOAP on **TCP 59278**. This
is not an outbound camera-control protocol and exposes no shutter, delete,
format or firmware-control operation.

This does not prove that a factory-reset card can be activated offline.
Historical X2 Utility's fresh-activation path called the vendor registration
service. Existing network/receiver configuration or working direct mode is a
prerequisite for the receiver milestone.

## Receiver contract

- SOAP operations: `POST /api/soap/eyefilm/v1`
- Media upload: `POST /api/soap/eyefilm/v1/upload`
- Match XML elements by local name, not a namespace prefix. Bound request and
  metadata sizes and reject DTDs, external entities and duplicate fields.

1. **StartSession** (`SOAPAction: "urn:StartSession"`): card supplies
   `macaddress`, `cnonce`, transfer mode and timestamp. Receiver returns a
   credential, fresh `snonce`, the transfer fields and `upsyncallowed`.
2. **GetPhotoStatus**: card supplies the second credential and file metadata.
   Receiver returns `fileid` and `offset`.
3. **UploadPhoto**: multipart fields `SOAPENVELOPE` and `FILENAME`; the latter
   is a TAR archive. Return success only after safe storage completes.
4. **MarkLastPhotoInRoll**: ends the roll. eyefiserver2 returns an empty
   success response, the reviewed Mobi server does not implement the call, and
   historical Windows receivers answer SOAP fault 2 (`Last Photo`) before
   closing. Hardware evidence is needed before choosing one compatibility
   response.

Use `upsyncallowed=false` for a local-only receiver unless a tested profile
requires otherwise. It must never authorize onward upload to a third party.

## Credentials and nonces

Concatenate the specified hexadecimal strings, **decode the hex to bytes**, then
MD5 those bytes and emit lowercase hex. Do not hash the ASCII hex text. The card
address is 12 hex characters without colons in the reviewed implementations.

| Profile | StartSession response | GetPhotoStatus expected from card |
|---|---|---|
| X2 with owner-exported upload key | `MD5_bytes(mac + cnonce + upload_key)` | `MD5_bytes(mac + upload_key + snonce)` |
| Reviewed Mobi receiver | Same, with a 32-zero-character upload-key placeholder | Same, with the same placeholder |

The Mobi placeholder represents 16 zero bytes after decoding; it is legacy
behavior, not a recommended new credential. Mobi Pro infrastructure mode can
instead use its real upload key, recoverable from an already-configured
mounted card through token `0xfd`.

StartSession alone does not authenticate the card. A replacement should verify
the second credential in constant time for both profiles, bind nonce state to
card/session/item, use single-use expiring nonces and define one outstanding
transfer policy per card. Never log upload keys, credential inputs,
direct-mode passphrases or owner MAC addresses.

Synthetic documentation vectors are in `eye-fi-cards.yaml` and checked by
`scripts/test_eye_fi_cards.py`; they identify no real card or owner.

## Resume and archive behavior

The community servers' constant `fileid=1, offset=0` is a stub, not proof of
the real protocol's limits. Vendor receiver analysis establishes:

- upload state keyed by `filesignature`, with its file ID reused;
- a new destination resuming at the spooled byte count rounded down to 4 KiB;
- `offset=filesize` for a complete item;
- `filesize` measured in TAR bytes;
- media first and an optional event log second.

The `filesignature` algorithm is still unknown. Offset zero is the safe first
implementation; nonzero resume needs an interruption capture. Do not
deduplicate on the stub file ID or filename alone.

A separate integrity digest is documented: invert the 16-bit Internet checksum
of each 512-byte TAR block, concatenate the two-byte values, then MD5 them with
the 16-byte upload key. This needs a capture before being presented as a
hardware-verified requirement.

**Do not deploy the old extraction code on an untrusted network.** A new
receiver should stream to a bounded temporary file, validate the whole archive
before extracting, accept only regular files and harmless directories, reject
absolute/traversal/backslash paths, links, devices, FIFOs and collisions, use
exclusive creation and remove partial output on failure. Start with JPEG only;
quarantine unsupported media rather than invoking external services. Skip the
historical geolocation sidecar.

## Direct mode and receiver selection

Vendor-app analysis establishes a Mobi direct-mode SSID of `Eye-Fi Card ` plus
the last six MAC hex digits, WPA2 using the card activation code, and DHCP from
the card. Do not publish an owner's activation code, SSID suffix or key.

Thumb-mode firmware analysis indicates active/profile and global listener
hints followed by a bounded subnet-candidate loop. A historical `O 0x06` frame
may permit manual listener provisioning, but it is not a first-party or
hardware-verified recipe. Reset-card upload-key creation remains unsolved.
Legacy Eye-Fi Center contains multicast/UDP configuration, but no proven
Bonjour service or card-discovery exchange.

## Mounted-card configuration

`eyefi-config` uses files under `EyeFi/` on a mounted FAT card, not one XML
settings file: `reqm`, `reqc`, `rspm`, `rspc`. Records are 16,384-byte
zero-padded buffers.

- Information request: ASCII `o`, one-byte subcommand.
- One-byte configuration write: ASCII `O`, subcommand, length `01`, value.
- Increment the previous response sequence (seed `0x1234` if zero), write it
  to `reqc`, then poll `rspc` up to 50 times at 300 ms intervals.
- The reference utility treats sequence values as native unsigned 32-bit,
  little-endian on its Linux host. Do not generalize that without checking.

Read-side tokens include MAC `0x01`, firmware `0x02`, upload API `0x04`,
transfer mode `0x11`, direct-mode SSID/passphrase `0x22`/`0x23`, direct-mode
timers `0x24`/`0x25`, and owner-only upload-key export `0xfd`. Network scans,
network changes, AP start and reboot are writes with no hardware validation
here. Back up the card and obtain owner consent before using them. The utility
built, but GCC warned about a possible use-after-free in its mount-path
handling; that is another reason not to run it blindly.

## Deployment boundary

This is cleartext HTTP with reusable legacy credentials and, in one reviewed
Mobi path, a predictable key input. Use an isolated direct-mode network or a
trusted segmented LAN. Never expose TCP 59278 to the internet or public
Wi-Fi. Restrict listener interfaces and accepted card identities. Photos are
private: avoid image/content logging, cloud/geolocation side effects and
unbounded retention.

## Remaining evidence needed

1. Sanitized X2 and separate Mobi/Mobi Pro sessions, including roll completion.
2. Receiver-IP selection after DHCP in direct and infrastructure modes.
3. RAW/video/log variants, `filesignature`, and remaining transfer-mode bits.
4. Real interruption/resume and multiple-card behavior.
5. Mounted-utility coverage across Mobi firmware and a reset-card provisioning
   route that does not depend on retired activation services.

The sensible first milestone is a **single-card, JPEG-only, read-only-network
receiver** with strict session and archive handling, not a universal Eye-Fi
activation replacement.

## Sources

- [dgrant/eyefiserver2](https://github.com/dgrant/eyefiserver2)
- [michaelbrandt/node-eyefimobiserver](https://github.com/michaelbrandt/node-eyefimobiserver)
- [hansendc/eyefi-config](https://github.com/hansendc/eyefi-config)
- [ShutterSnitch](https://apps.apple.com/us/app/shuttersnitch/id364176211), a
  current third-party receiver listing; not tested here
