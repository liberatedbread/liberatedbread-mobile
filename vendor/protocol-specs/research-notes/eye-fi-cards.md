# Eye-Fi Wi-Fi SD Cards — Research Notes

Checked 2026-10-31. Source review of `dgrant/eyefiserver2`,
`michaelbrandt/node-eyefimobiserver` and `hansendc/eyefi-config`; no card or
network capture was used.

## Local rescue shape

Already-configured X2-era and Mobi-family cards can push photographs to a
receiver on the LAN over cleartext HTTP/SOAP on **TCP 59278**. The card
initiates the connection, so a replacement phone app needs a receiver/server,
not an outbound camera-control client. Setup and recovery are separate from
receiving uploads.

SOAP calls use `/api/soap/eyefilm/v1`; upload uses
`/api/soap/eyefilm/v1/upload`.

1. StartSession supplies MAC, client nonce, transfer mode and timestamp. The
   receiver computes a credential and returns a fresh server nonce.
2. GetPhotoStatus supplies a second credential and file metadata. The
   receiver returns a file id and upload offset.
3. UploadPhoto posts multipart `SOAPENVELOPE` and `FILENAME`; `FILENAME` is a
   tar archive containing the image and possibly a log.
4. MarkLastPhotoInRoll ends the roll.

Credential formulas concatenate **hex strings**, hex-decode, then MD5 and
return lowercase hex. X2 StartSession uses `MD5_bytes(mac + cnonce +
upload_key)` and GetPhotoStatus uses `MD5_bytes(mac + upload_key + snonce)`.
The reviewed Mobi server substitutes 32 ASCII zeroes for the upload key.
These are legacy wire requirements, not a recommendation for new credentials.
Resume, deduplication and file-signature semantics need captures.

## Mounted-card configuration

`eyefi-config` uses an `EyeFi/` directory with `reqm`, `reqc`, `rspm` and
`rspc` records, not one XML settings file. It can read identity and existing
keys, manage networks and logs, and inspect direct-mode SSID/passphrase and
timing. Owner keys stay secret. Direct-mode discovery/addressing and coverage
across Mobi firmware are not established.

## Security and app implications

The old servers are protocol evidence, not safe applications. A new receiver
must reject absolute paths, `..`, links, special files, oversized archives
and filename collisions, and should bind nonces per card/session and verify
file size/signature. Cleartext reusable credential hashes restrict use to a
trusted LAN or isolated direct-mode network. Geolocation sidecar uploads are
unnecessary for photo rescue and should be off.

The useful first implementation is a modern receiver on Android, a router,
NAS or computer. No generic mobile app support is added until that server
lifecycle, discovery and safe archive handling are designed and tested.
