# Firmware Update (DFU / OTA)

A device that answers under a strange name, at an address one higher than it
had a minute ago, and offers none of its usual services is not a new device.
It is almost always the one the user just updated. It is sitting in its
bootloader, either still waiting for an image or stranded after an
interrupted update.

Of the three jobs below, only the first is optional:

1. **Recognise a device in update mode.** This is when a user is most anxious,
   and a scanner that shows "Unknown device DfuTarg" or offers the product's
   normal controls makes things worse.
2. **Keep generic controls out of the update path.** Entering the bootloader
   is one write away on most stacks. A command that does it is `advanced`, and
   a GATT explorer lists update services read-only.
3. **Say whether a replacement client can update the device at all.** A
   signed image can be delivered but not built. An unsigned one can be
   rebuilt, and can also be flashed by anyone in radio range.

This project documents update paths and does not ship vendor firmware. Where
a vendor image is public, the spec says where it is. Where an image is bundled
in an app, the spec says so and the image stays in the app.

## Where the facts live

- **`features[type: firmware_update].dfu`** in a device spec says which
  stack the device uses, how to get it into update mode, what it looks like
  once there, and what an interrupted update leaves behind. See
  [Reading a Device Spec](../api/spec-format.md#features-an-upload-is-a-control-surface-too).
- **`registries/dfu-signatures.tsv`** holds each stack's service and
  characteristic UUIDs and default bootloader names, one row per signature,
  with the source for each. A consumer loads it to recognise any bootloader,
  including devices the catalogue has no spec for.
- **This page** covers the per-stack behaviour behind both.

## Recognising update mode

A consumer checks a scan result against every spec's `dfu.dfu_mode` *before*
ordinary identification:

```yaml
features:
  - type: firmware_update
    dfu:
      mechanisms: ["nordic_secure_dfu"]
      dfu_mode:
        local_names: ["AdMore Light Bar DFU"]
```

A match there means "this product, mid-update". It gets a status line and no
controls. The ordering matters: "AdMore Light Bar DFU" also starts with the
bar's normal `local_name_prefix`, so checking identification first would offer
brake-light controls to a bootloader.

When no spec's `dfu_mode` matches, a result that advertises a `service_uuid`
or `local_name` from `dfu-signatures.tsv` is still a bootloader, just not an
identified one. Show it as "firmware update mode (Nordic)" and never match it
to a product by that signal. `address_offset` is the one link from an
anonymous bootloader back to a product. If the user tapped a device at
`…:4A` and a `DfuTarg` appears at `…:4B`, a spec with `address_offset: 1`
says they are the same unit.

`dfu.services` in normal mode are part of the device's GATT, but they are
not product identity: many unrelated products carry `fe59`. A spec must not
identify on them alone. The exception is a vendor-specific service that only
this product advertises (Schlage's firmware-transfer service).

## Stacks

Each section gives what the stack's own documentation or reference code
says. A device spec records only what it changes: a renamed bootloader, a
different address, a vendor command in place of the stack's entry.

### Nordic Secure DFU (`nordic_secure_dfu`)

nRF5 SDK 12 and later. Service `0000fe59-…`, SIG-assigned to Nordic.

- **Entry, buttonless:** the application carries `fe59` with characteristic
  `8ec90003-f315-4f60-9fb8-838830daea50` (no bond sharing) or
  `8ec90004-…` (bond sharing). Enable indications, write `01`, and the device
  replies `20 01 01`, then resets into the bootloader. Opcode `02` sets the
  name the bootloader will advertise.
- **Update mode:** advertises `DfuTarg` by default. Without bond sharing it
  uses the device address **+1** in the least-significant byte, so that
  phones with a cached GATT table don't reuse it. With bond sharing it keeps
  the device's address.
- **Transfer:** control point `8ec90001-…`, packet `8ec90002-…`. An init
  packet (`.dat`) comes first, then the image (`.bin`), both from an
  nrfutil zip.
- **Signing:** ECDSA P-256 over SHA-256, verified by the bootloader.
  Signed updates and downgrade prevention are on in the SDK example.
- **Recovery:** dual-bank when flash allows, so an interrupted transfer
  keeps the old application. After 120 s of inactivity the bootloader resets
  into a valid application, if there is one.

Sources: [Android-DFU-Library](https://github.com/NordicSemiconductor/Android-DFU-Library),
[nRF5 SDK bootloader config](https://github.com/particle-iot/nrf5_sdk/blob/master/examples/dfu/secure_bootloader/pca10056_ble/config/sdk_config.h),
[pc-nrfutil signing](https://github.com/NordicSemiconductor/pc-nrfutil/blob/master/nordicsemi/dfu/signing.py).

### Nordic legacy DFU (`nordic_legacy_dfu`)

nRF5 SDK 11 and earlier. Service `00001530-1212-efde-1523-785feabcd123`,
control point `…1531…`, packet `…1532…`, version `…1534…`. A buttonless
application carries the same service: writing `01 04` to the control point
jumps to the bootloader. The bootloader advertises `DfuTarg`. Whether it
changes address depends on the SDK version, so a spec states its own
`address_offset`. Images are unsigned; the init packet carries a CRC-16.

Source: [Android-DFU-Library legacy implementation](https://github.com/NordicSemiconductor/Android-DFU-Library/blob/main/lib/dfu/src/main/java/no/nordicsemi/android/dfu/LegacyButtonlessDfuImpl.java).

### MCUboot + SMP (`mcuboot_smp`)

Zephyr and nRF Connect SDK. The running application serves SMP on service
`8d53dc1d-1db7-4cd3-868b-8a527460aa84`, characteristic `da2e7828-…`. It
writes the image to the secondary slot without rebooting first
(`enter.how: in_place`) and keeps its identity throughout. MCUboot verifies
RSA, ECDSA P-256 or Ed25519. A test swap reverts on the next reset unless
the new image confirms itself.

Sources: [Zephyr SMP transport](https://docs.zephyrproject.org/latest/services/device_mgmt/smp_transport.html),
[MCUboot design](https://docs.mcuboot.com/design.html).

### TI OAD (`ti_oad`)

Service `f000ffc0-0451-4000-b000-000000000000`, with identify (`ffc1`),
block (`ffc2`) and extended control (`ffc5`). `ffc3` and `ffc4` are
deprecated in BLE5-Stack. Off-chip OAD is received in place by the running
application, and the old image survives. On-chip OAD reboots into a resident
OAD image. There is no standard update-mode name. Secure OAD signs with
ECDSA P-256; plain OAD is CRC-only.

Source: [TI OAD service UUIDs](https://software-dl.ti.com/lprf/simplelink_cc26x2_latest/docs/ble5stack/ble_user_guide/doxygen/ble/html/group___o_a_d___s_v_c___u_u_i_d_s.html).

### Telink OTA (`telink_ota`)

Service `00010203-0405-0607-0809-0a0b0c0d1912`, data characteristic
`…2b12`. The running application serves it in place, with no reboot first.
Each packet is a 2-byte little-endian index, 16 data bytes and a CRC-16
(MODBUS). Indexes `0xff00`–`0xff06` are commands (`ff01` start, `ff02`
end). Images are unsigned; the new image goes to the other flash bank and
the boot flag switches only on success. Default timeouts: 30 s overall,
5 s between packets.

Source: [Telink OTA header](https://android.googlesource.com/platform/hardware/telink/atv/refDesignRcu/+/refs/heads/master/stack/ble/service/ota/ota.h).

### Silicon Labs Gecko OTA (`silabs_ota`)

Service `1d14d6ee-fd63-4fa1-bfa4-8f47b42119f0`, control
`f7bf3564-fb6d-4e53-88a4-5e37e0326063`. In the application, writing `00`
to control reboots into AppLoader. There, `00` starts the upload, `03`
finishes it and `04` requests a disconnect. The data characteristic
`984227f3-…` exists only in AppLoader. The two modes have separate GATT
databases, so the client must rediscover handles. AppLoader advertises the
app-configured OTA name, or `AppLoader`, and normally keeps the device's
address, **not** +1. Signing (ECDSA P-256) and encryption (AES-CTR) of the
GBL image are optional.

Source: [AN1086](https://www.silabs.com/documents/public/application-notes/an1086-gecko-bootloader-bluetooth.pdf).

### Espressif (`espressif_ota`)

There is no standard BLE service. ESP-IDF writes the image to the
non-running `ota_0`/`ota_1` slot, so power loss keeps the current
application. With rollback enabled, an unconfirmed image is abandoned on
the next boot. ArduinoOTA listens on UDP 3232 (ESP32) or 8266 (ESP8266),
found by mDNS. Web uploads (WLED `/update`, ESPHome's web server) are
`http_upload`. Secure Boot v2 verifies RSA-PSS or ECDSA.

Source: [ESP-IDF OTA](https://docs.espressif.com/projects/esp-idf/en/stable/esp32/api-reference/system/ota.html).

### JieLi (`jieli_ota`)

Updates go over the RCSP protocol on service `0000ae00-…` (write `ae01`,
notify `ae02`). That service also carries JieLi's general device control, so
its presence means "a JieLi SoC", not "update mode". It is deliberately
absent from `dfu-signatures.tsv`. Single-backup parts reboot into a loader
and the client must reconnect; dual-backup parts update in place.

Source: [Jieli-Tech/Android-JL_OTA](https://github.com/Jieli-Tech/Android-JL_OTA).

### Others

`csr_ota` (service `00001016-d102-11e1-9b23-00025b00a5a5`), `dialog_suota`,
`freqchip_ota`, `phyplus_ota`, `realtek_ota` and `tuya_ble_ota` are
recognised mechanism names. Their public documentation is thin, so each
spec that uses one states its own details in `dfu.notes`. `vendor_ble` covers
a vendor protocol over the device's own GATT service, `http_upload` a
firmware file POSTed to a web endpoint, and `vendor_cloud` an update the
device downloads itself when its cloud tells it to.
