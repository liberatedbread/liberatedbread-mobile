# Wemo Setup, Factory Reset and Rebinding

> **Status**: In Progress — flow documented from public implementations, not yet replayed against hardware
> **Applies to**: every Wemo device family in [the catalog](wemo-devices.md)
> **Prerequisite**: none — the Belkin cloud is not involved at any point

[Discovery and control](wemo-devices.md) assume a Wemo device is already on your
WiFi. This page covers how it got there, and — the case that matters now that
the Wemo cloud is gone — how to move a device to a *different* network without
the vendor app.

The good news: Wemo provisioning is entirely local. The device hosts its own
access point and takes credentials over the same SOAP 1.1 stack it uses for
normal control. Nothing in the flow requires Belkin's servers, which is why
Wemo hardware remains recoverable after the January 2026 shutdown.

!!! info "Confidence and provenance"
    This page and `device-specs/devices/wemo-devices.yaml` follow
    [pywemo](https://github.com/pywemo/pywemo)'s implementation
    (`pywemo/ouimeaux_device/__init__.py`, Apache 2.0), which is the maintained
    reference and has been exercised against real hardware across several
    device generations. pywemo in turn credits Vadim Kantorov's
    [wemosetup](https://github.com/vadimkantorov/wemosetup) for the encryption
    derivation.

    The spec is checked by implementing it: `scripts/test_wemo_spec.py`
    transcribes the published algorithm using nothing but `hashlib`, `base64`
    and `openssl`, and asserts it reproduces the spec's own test vectors. If
    that transcription cannot be written, the spec is underspecified and CI
    fails.

    What has *not* happened is a run against real hardware in this project. If
    you hit something this page gets wrong, that is worth filing.

## When you need this

| Situation | What to do |
|---|---|
| New or factory-reset device | Full provisioning flow below |
| Moving to a new router, old network still up | [`ReSetup`](#rebinding-to-a-new-network) — no physical reset needed |
| Moving to a new router, old network already gone | Factory reset, then full provisioning |
| Device stuck on an SSID you no longer control | Factory reset, then full provisioning |
| Device works but you want a different name | `basicevent#ChangeFriendlyName` — not a setup operation |

The one piece of timing advice worth acting on: **if you are replacing a
router, re-provision your Wemo devices before the old SSID goes away.**
`ReSetup` needs the device to still be reachable. Once the old network is down,
every device drops to a physical factory reset, which for in-wall switches
means getting at the Restore button behind the faceplate.

## Factory reset

A reset clears the stored WiFi credentials, the friendly name, and any local
rules or timers, then reboots the device into setup mode. The UDN, serial
number and MAC address are hardware identity and survive — so a device keeps
its stable discovery keys across reprovisioning, and anything storing per-device
state will still recognise it afterwards.

### Plug-style devices (Mini, Smart Plug, Insight, Outdoor)

The Restore button must be held **while power is applied**. Pressing it on a
running device does not reset it, which is the usual reason people conclude
their device is dead.

1. Unplug the device from the outlet.
2. Press and hold the Restore button.
3. Plug the device back in, still holding.
4. Keep holding for about 5 seconds after power is applied, then release.
5. Wait up to 90 seconds for the reboot to finish.

### In-wall devices (Light Switch, Dimmer)

Power stays on at the breaker; the button does the work.

1. Leave the switch powered.
2. Press and hold the Restore button on the device body for about 10 seconds,
   until the status LED changes pattern.
3. Wait up to 90 seconds for the reboot.

### Confirming it worked

Do not trust the stopwatch — hold times vary by generation and vendor
documentation is inconsistent. The reliable confirmation is that an **open
`Wemo.*` WiFi network reappears** in a scan:

```bash
# Linux
nmcli device wifi rescan && nmcli -f SSID,SECURITY device wifi list | grep -i wemo

# macOS
/System/Library/PrivateFrameworks/Apple80211.framework/Versions/Current/Resources/airport -s | grep -i wemo
```

Observed names follow `<Family>.<Class>.<3 chars>`, with the case of the first
token varying across firmware: `WeMo.Switch.A1B`, `Wemo.Mini.4A2`,
`WeMo.Insight.7C4`. Match case-insensitively on `wemo.` rather than on any
single spelling.

!!! tip "Implementing this yourself?"
    Work from `device-specs/devices/wemo-devices.yaml` rather than this page.
    Its `device.setup` block is written to be complete on its own, and it
    publishes **test vectors** so you can verify your passphrase encryption
    against known-good values before you go near hardware:

    ```yaml
    # device.setup.methods[0].softap.credential_encryption.test_vectors
    input:
      meta_info: "00005E00530A|229999K9999999|Wemo_WW|WeMo_US_2.00.11408|Wemo.Mini.4A2|Socket"
      passphrase: "correct horse battery staple"
    vectors:
      - method: 1
        keydata: "00005E229999K999999900530A"
        aes_key_hex: "6d27765d242fa465ae5ee33a671d7714"
        password_argument: "mKUXMHrq3r71VIBnALtgaQH/iTpWEZSSMVizvzMXrVM=2c1c"
    ```

    If your implementation reproduces all three vectors, the crypto is right
    and any remaining failure is elsewhere in the flow.

## Provisioning flow

Once the setup AP is up, the device is at **`10.22.22.1`**, serving HTTP on the
usual Wemo port range (49152–49153 in setup mode).

```text
  ┌────────────┐   join open AP    ┌──────────────┐
  │  client    │ ────────────────▶ │ Wemo in      │  10.22.22.1:49153
  │            │                   │ setup mode   │
  └────────────┘                   └──────────────┘
        │ 1. GET /setup.xml                  → identity + service control URLs
        │ 2. metainfo#GetMetaInfo            → key material for the passphrase
        │ 3. WiFiSetup#GetApList             → networks the device can see
        │ 4. WiFiSetup#ConnectHomeNetwork    → SSID + encrypted passphrase
        │ 5. WiFiSetup#GetNetworkStatus      → poll until connected
        │ 6. WiFiSetup#CloseSetup            → leave setup mode
        ▼
   rejoin your own network, rediscover by SSDP
```

### 1. Read the device description

```bash
curl -s http://10.22.22.1:49153/setup.xml
```

Take the control URLs from the `serviceList` rather than hardcoding them. Both
`/upnp/control/WiFiSetup1` and `/upnp/control/wifi1` have been reported for
`urn:Belkin:service:WiFiSetup:1` across firmware generations; `setup.xml` is
authoritative for the device in front of you.

### 2. Read the metadata that keys the passphrase encryption

`urn:Belkin:service:metainfo:1#GetMetaInfo` returns a pipe-delimited
`MetaInfo` string of six fields:

| # | Field | Used for |
|---|---|---|
| 0 | MAC address | Key material |
| 1 | Serial number | Key material |
| 2 | Device SKU | — |
| 3 | Firmware version | Diagnostics |
| 4 | **Setup AP SSID** | The device tells you its own AP name |
| 5 | Model name | — |

Note the order: field 0 is the **MAC**, field 1 the **serial**. Swapping them
produces a valid-looking blob that the device silently rejects.

Three key layouts exist, and which one a device wants depends on its firmware
(see [Encryption variants](#encryption-variants)):

```text
method 1:  keydata = mac[0:6] + serial + mac[6:12]
method 2:  keydata = mac[0:6] + serial + mac[6:12] + "b3{8t;80dIN{ra83eC1s?M70?683@2Yf"
method 3:  keydata = mac[0:3] + mac[9:12] + serial
                     + "b2Ujb3Rtb24mY3ZEbmlhaXBBZGFiT25v" + mac[6:9] + mac[3:6]

salt = keydata[0:8]      # first 8 bytes
iv   = keydata[0:16]     # first 16 bytes
```

### 3. Ask the device what it can see

`urn:Belkin:service:WiFiSetup:1#GetApList` returns an `ApList` string, one
entry per line. **The first line is a header and must be skipped.** Each
remaining line is pipe-delimited, may have a trailing comma, and is laid out
with the SSID first, the channel second, and the auth mode and cipher joined by
a slash in the **last** column:

```text
3
HomeNet|6|WPA2PSK|...|WPA2PSK/AES,
OpenGuest|1|OPEN|...|OPEN/NONE,
NewFangled|1|SAE|...|Unknown,
```

Split the last column on `/` to get the `auth` and `encrypt` arguments. Two
things to check before going further:

- The device only accepts ciphers `NONE`, `AES` and `TKIPAES`.
- An auth mode of `Unknown` means the device cannot express that network's
  security — **WPA3 shows up this way**, and no amount of retrying will help.
  Add a WPA2 compatibility SSID for the duration of setup.

Use the device's own strings verbatim in the next step. A network the device
can see will still be rejected if the auth string does not match its vocabulary.

### 4. Encrypt the passphrase and send the credentials

The passphrase is AES-128-CBC encrypted with a key derived from the device
metadata:

1. Derive the key as `MD5(keydata + salt)[:16]`, with the IV taken from
   `keydata[0:16]`. This is exactly what OpenSSL's legacy `EVP_BytesToKey`
   produces for AES-128 when the IV is supplied explicitly, so
   `openssl enc -aes-128-cbc -md md5 -S <salt> -iv <iv> -pass pass:<keydata>`
   reproduces it byte for byte.
2. PKCS#7-pad and encrypt.
3. Base64-encode the ciphertext.
4. For methods 1 and 3, append four hex digits: the length of that base64
   string, then the length of the plaintext passphrase, **each zero-padded to
   exactly two digits**. Method 2 appends nothing.

!!! warning "Two easy ways to get this wrong"
    - **Zero-pad the lengths.** A passphrase of 8 characters contributes `08`,
      not `8`. A single digit produces a blob the device rejects without
      explanation.
    - **Strip the OpenSSL header conditionally.** OpenSSL 1.x writes a
      `Salted__` + 8-byte-salt header even when the salt is given with `-S`;
      OpenSSL 3.x does not. Slicing 16 bytes unconditionally — as the older
      published scripts do — corrupts the credential on any modern system.

Then call `ConnectHomeNetwork` with `ssid`, `auth`, `password` (the blob above),
`encrypt` and `channel`. **Send it twice**, about 100 ms apart: pywemo notes
the success rate is markedly higher, and the reason is not understood.

For an open network, skip the encryption entirely: send `auth=OPEN`,
`encrypt=NONE` and an empty `password`.

Wemo rejects passphrases shorter than 8 characters (reported as network
status 2).

#### Encryption variants

Three encryption methods exist across firmware generations. Pick one from the
non-standard elements Belkin adds to `setup.xml`:

| `setup.xml` contains | Method | Append lengths |
|---|---|---|
| `rtos=1` and not `iot=1` | 2 | No |
| anything else | 1 | Yes |

pywemo notes that the Wemo app's own logic (`binaryOption=1` → method 3,
`new_algo=1` → method 2) matches real hardware *less* often than keying off
`rtos`/`iot`, so the table above is what to implement.

If a connect attempt fails, the variant is the first thing to vary — there are
six combinations, and pywemo exposes them as `_encrypt_method` and
`_add_password_lengths`.

!!! danger "This is obfuscation, not encryption"
    Every input to the key derivation comes from `GetMetaInfo`, which the
    device serves to anyone on its open setup AP without authentication. The
    scheme stops a passive listener from lifting your passphrase off the air;
    it provides no protection against anyone who bothered to read this page.
    Implement it exactly — the device rejects anything else — and do not treat
    it as a security boundary.

### 5. Poll the result

`ConnectHomeNetwork` returns a `PairingStatus`, but the outcome comes from
polling `GetNetworkStatus`:

| `NetworkStatus` | Meaning |
|---|---|
| `0` | Still trying to connect |
| `1` | Connected |
| `2` | Rejected — passphrase shorter than 8 characters |
| `3` | Handshaking; usually becomes `1` within a few seconds |

Poll rather than assuming. Without this step you cannot tell a wrong passphrase
from a slow DHCP lease, and the device is about to become unreachable either
way. Status `3` is not a failure — give it a few more seconds before retrying.

### 6. Close setup and rediscover

`CloseSetup` drops the setup AP and moves the device onto your network; it
returns `status`, which should be `success`. On devices that have it, follow
with `basicevent#SetSetupDoneStatus` — it is absent on some firmware, and its
absence is not an error.

Rejoin your own WiFi and rediscover by SSDP. The device now has a completely
different address, so match on UDN, serial or MAC, never on IP —
`device.discovery` in the spec covers the M-SEARCH datagram and the description
parse rules.

## Doing it

Use [pywemo](https://github.com/pywemo/pywemo). It does all of this, is
maintained, and is tested against far more hardware
than we have; a second implementation from us would be a worse copy of the
thing we tell people to use. Our contribution is the spec.

!!! warning "The scripts under `scripts/` are not that client"
    `wemo_discover.py`, `wemo_control.py` and `wemo_setup.py` exist to check
    this spec against real hardware, since every `verified` flag in it is still
    `false`. They are scheduled for deletion once that is done — see
    [issue #16](https://github.com/PigsCanFlyLabs/opengreeniot-protocol-docs/issues/16),
    which lists what needs confirming. If you are provisioning a device rather
    than verifying a document, use pywemo.

```bash
pip install pywemo
python - <<'EOF'
import pywemo

# Joined to the device's open Wemo.* setup AP:
url = pywemo.setup_url_for_address("10.22.22.1")
device = pywemo.discovery.device_from_description(url)
print(device)
print(device.setup(ssid="HomeNetwork", password="secret"))   # ('1', 'success')
EOF
```

If a connect attempt fails, the encryption variant is the first thing to vary.
pywemo exposes the same six combinations this page documents:

```python
device.setup(ssid="HomeNetwork", password="secret",
             _encrypt_method=1, _add_password_lengths=True)   # default for most
device.setup(ssid="HomeNetwork", password="secret",
             _encrypt_method=2, _add_password_lengths=False)
device.setup(ssid="HomeNetwork", password="secret",
             _encrypt_method=3, _add_password_lengths=True)
# then the remaining three combinations
```

Resets are `device.reset(data=..., wifi=...)` — see
[Rebinding to a new network](#rebinding-to-a-new-network) for what each scope
clears.

### Predicting the encryption variant

Before trying combinations, read the device's own description — the flags that
decide the variant are in it. `scripts/wemo_discover.py` prints them, or:

```bash
curl -s http://10.22.22.1:49153/setup.xml | grep -E "rtos|iot|firmwareVersion"
#   <firmwareVersion>WeMo_US_2.00.11408</firmwareVersion>
#   <rtos>1</rtos>
#   <iot>0</iot>
#   ^ rtos=1 without iot=1 means encryption method 2, no length suffix
```

### Implementing it yourself

Work from `device-specs/devices/wemo-devices.yaml`. Its `device.setup` block is
written to be complete on its own and publishes test vectors so you can verify
your encryption before going near hardware — see
[Reading a Device Spec](../api/spec-format.md).

## Rebinding to a new network

`urn:Belkin:service:basicevent:1#ReSetup` pushes a provisioned device back into
setup mode over the LAN, without a physical reset. This is the answer to "my
router changed and my Wemo is in the ceiling".

It takes a `Reset` argument that selects the scope, matching the three options
the Wemo app used to offer:

| `Reset` | Clears | Wemo app wording | Tool flag |
|---:|---|---|---|
| `1` | Name, icon and rules | Clear Personalized Info | `--data` |
| `2` | Everything, including WiFi | Factory Restore | `--factory` |
| `5` | WiFi credentials only | Change Wi-Fi | `--wifi` |

```python
import pywemo

device = pywemo.discovery.device_from_description(
    pywemo.setup_url_for_address("192.168.1.42")
)
device.reset(data=False, wifi=True)   # "Change Wi-Fi"
```

A successful reset returns `success`; at least one device is reported to return
`reset_remote` instead and still reset correctly.

Two caveats worth stating plainly:

- **It clears the stored credentials immediately** (with `--wifi` or
  `--factory`). If the reprovisioning that follows fails, the device is sitting
  in setup mode, not back on the old network. Have the new SSID and passphrase
  to hand before you run it.
- **It only works while the device is reachable.** It is a LAN call. Once the
  old network is gone, so is this option.

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| No `Wemo.*` network after a reset | Button was not held *through* power-on (plug devices), or the hold was too short. Watch the LED, not the clock. |
| `ConnectHomeNetwork` accepted, `GetNetworkStatus` never reaches 1 | Wrong passphrase, or the SSID is 5 GHz-only. Every Wemo radio is 2.4 GHz. |
| `NetworkStatus` returns 2 | Passphrase is shorter than 8 characters — a firmware limit, not a bug. |
| `NetworkStatus` sits at 3 | Handshaking. Wait a few more seconds before retrying; 3 usually precedes success. |
| Target network shows `Unknown` auth in `list-aps` | The device cannot express that security mode. WPA3 is the usual cause; add a WPA2 SSID for setup. |
| Everything looks right but the join always fails | Wrong encryption variant. Work through the six `--encrypt-method` / `--add-lengths` combinations. |
| Join fails on a network the device listed | `auth`/`encrypt`/`channel` do not match the `ApList` entry — send back the device's own strings verbatim. |
| Fails repeatedly for no clear reason | Genuinely try again — pywemo's own docs list this first. Move the device closer to the AP; some units need a strong signal to complete setup even though they run fine on a weak one. |
| Setup AP visible but HTTP times out | Client fell back to cellular or another interface. Pin the route to the 10.22.22.0/24 subnet. |
| Device joins, then never appears in SSDP | Client AP isolation, or a router that blocks multicast between wireless clients. |
| Device appears, then disappears, on a different port | Normal. Wemo ports move across 49152–49159; rediscover rather than caching the port. |
| Everything works, then breaks after a power cut | Also normal, same cause. Never store the port as identity. |

## References

- [pywemo](https://github.com/pywemo/pywemo) — device classes and SSDP handling
- [pywemo `wifi_setup.py`](https://github.com/pywemo/pywemo/blob/main/pywemo/ouimeaux_device/api/wifi_setup.py) — WiFiSetup service surface
- [wemosetup](https://github.com/vadimkantorov/wemosetup) — the public implementation of the passphrase encryption
- [ouimeaux](https://github.com/iancmcc/ouimeaux) — pywemo's lineage
- [Wemo device catalog and control](wemo-devices.md)
- [Initial Device Setup](../protocols/device-setup.md) — the cross-device patterns
- **Machine-readable spec: `device-specs/devices/wemo-devices.yaml`** — this
  page is the narrative; `device.setup` there is the normative version and is
  written to be implementable on its own. It carries the SOAP wire format, the
  `MetaInfo` and `ApList` layouts, the full encryption algorithm with
  reproducible test vectors, the status codes, timing constants and a
  troubleshooting table.
