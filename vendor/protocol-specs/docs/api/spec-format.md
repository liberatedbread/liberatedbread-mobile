# Reading a Device Spec

Every device in this project has a YAML spec under `device-specs/devices/`.
The prose pages explain a device; the spec **is** the device, in the form a
program can act on. It is also what the [Data API](index.md) publishes as JSON.

This page is about reading one — particularly the `device.setup` block, which
carries the most detail and the most traps.

!!! info "Normative vs narrative"
    Where a device page and its spec disagree, **the spec wins**. The prose is
    written for a human deciding whether to bother; the spec is written for
    someone implementing. A spec that cannot be implemented without also
    reading the prose is a spec with a bug in it.

## Anatomy

```yaml
device:              # identity, discovery, and one-time setup
  name: ...
  manufacturer: ...
  manufacturer_status: ...   # abandoned | shutdown | unsupported | active
  protocol: ...              # ble | wifi | zigbee | zwave
  identification: ...        # how to recognise it while scanning
  discovery: ...             # how to FIND one that is already on the network
  setup: ...                 # how to GET one onto the network
  variants: ...              # models that share a protocol but differ in detail

services: ...        # BLE GATT services and characteristics
http_endpoints: ...  # REST/SOAP endpoints for WiFi devices
mqtt_topics: ...     # MQTT topics
entities: ...        # how capabilities map to Home Assistant entities
helpful_urls: ...    # optional human references: docs, write-ups, forums, repos
helpful_videos: ...  # optional human video references: teardown/setup/capture walkthroughs
```

A spec must have `device` plus at least one transport block such as `services`,
`http_endpoints`, `mqtt_topics`, `obd`, `bus` or `cloud`. Everything else is optional, and the schema is deliberately
permissive — unknown keys are allowed so device-specific detail can travel
alongside the standard fields. Consumers parse the subset they understand.

### Further reading and watch links

Use top-level `helpful_urls` and `helpful_videos` for human-oriented reference
material that helps someone understand or reproduce the spec work. Put these
beside `device`, `services` and `features`, not inside `device`: they describe
the document's evidence trail and learning material, not device identity.

```yaml
helpful_urls:
  - title: "Reverse-engineering the Mi Scale protocol"
    url: "https://github.com/oliexdev/openScale"
    description: "Production Android app; source of the weight frame format."

helpful_videos:
  - title: "Mi Scale teardown"
    url: "https://video.example.com/watch/mi-scale-teardown"
    description: "Shows the board and load-cell wiring."
```

Both arrays are optional. Each entry requires `title` and `url`; `description`
is optional but strongly preferred when the title alone does not say why the
link matters. URLs must be HTTP or HTTPS. Do not invent links, and verify that
they resolve before adding them. A dead or wrong reference is worse than an
absent one. Videos are not YouTube-only; PeerTube, Vimeo, Invidious and direct
video files are valid when they resolve and are relevant.

### Three things that sound alike

Keeping these apart is the single most useful thing to know when reading a spec:

| Block | Answers | When it runs |
|---|---|---|
| `device.discovery` | "Where is it?" | Every time you look for the device |
| `device.setup` | "How did it get on the network?" | Once, at onboarding — or again after a reset |
| `initialization` (top level or per-service) | "What handshake does a connection need?" | Every single connection |

A BLE device with an encrypted command channel has an `initialization` block
and a `setup` block saying `required: false`. Those are not in tension: there
is nothing to provision, but every connection still needs a handshake.

## The `setup` block

```yaml
device:
  setup:
    required: true          # false for devices usable straight out of the box
    confidence: "high"      # how well is this verified? see below
    notes: >
      Prose overview, including what is and isn't confirmed.
    methods: [...]          # ordered; first is preferred
    factory_reset: {...}    # how to return it to unprovisioned
    rejoin: {...}           # moving it to a different network
    credentials: {...}      # what secrets move, and how they are protected
```

### Confidence and `verified`

Two separate claims, and reading them wrong wastes time:

| Field | Question | Values |
|---|---|---|
| `setup.confidence` | How well is this flow understood? | `high` — replayed against hardware, or there is a working open implementation. `medium` — from public source or vendor docs. `low` — inferred; go and capture it. |
| `methods[].verified` | Has *this project* run this exact flow against hardware? | Currently `false` everywhere. |

`verified: false` is not a warning label — it is the honest default, and it
tells you what to go and confirm. A `low`-confidence block naming its gaps is
far more useful than an absent one; "the onboarding exchange has not been
captured" is information, silence is not.

### Methods

`methods` is ordered, preferred first. Each has a `type` from a fixed set:

| Type | Meaning |
|---|---|
| `none`, `ble_direct` | Nothing to provision — power on, scan, connect |
| `softap_http`, `softap_soap` | Device hosts a temporary AP; credentials go over HTTP or SOAP |
| `ble_provisioning` | Credentials pushed over GATT |
| `wps`, `smartconfig` | Credentials delivered at the WiFi layer |
| `wired` | Ethernet only; no wireless credentials exist |
| `device_ui` | Configured on the device's own screen |
| `button_pairing` | A physical button authorizes a client and issues it a credential |
| `hub_pairing` | Joins a bridge, not WiFi |
| `cloud_account` | Onboarding exists only inside the vendor cloud — the failure case |

Alongside `type` a method carries whichever detail blocks apply: `softap`,
`ble`, `cloud`, and the shared blocks below.

### Steps

`steps` is the flow itself, in order. Each step says who acts and what success
looks like:

```yaml
- action: "Ask the device to scan for nearby access points."
  actor: "client"           # user | client | device
  request:
    protocol: "soap"        # soap | http | ble_gatt | udp | mqtt | mdns | ssdp
    service: "urn:Belkin:service:WiFiSetup:1"
    action: "GetApList"
    arguments: [...]        # name, type, required, description
  response_fields: [...]    # what comes back, by name
  expect: "ApList string. The first line is a header and is skipped..."
  timeout_seconds: 20
```

`actor` matters more than it looks. A step marked `user` cannot be automated —
someone has to hold a button — so a client rendering these as a wizard knows
where to stop and prompt. `expect` is the success signal: an LED pattern, a
response value, a state transition.

### The blocks that make a spec implementable

These are optional, but a `setup` block that omits them usually is not
implementable on its own.

**`payload_formats`** — how to parse response values that are not
self-describing, keyed by the value's name. Allowed on a setup method and at
the top level next to the control surface. Use it rather than inventing a
per-device key, so a consumer finds payload documentation the same way for
every device:

```yaml
payload_formats:
  ApList:
    description: "The device's scan results, newline-separated."
    parse_rules:
      - "Split on newline. SKIP THE FIRST LINE — it is a header/count."
      - "The LAST column is 'AUTHMODE/CIPHER'. Do not assume a fixed index."
    example: |
      3
      HomeNet|6|WPA2PSK|blah|WPA2PSK/AES,
```

`parse_rules` should spell out the traps — header lines, trailing separators,
columns that must be found from the end. The `example` should be real enough to
test against; it is what an implementer will parse first.

**`timing`** — constants that look arbitrary but are not. Minimum poll
timeouts, deliberate duplicate sends, how long a reboot takes. Recording them
saves the next person from rediscovering each one by failing.

**`troubleshooting`** — symptom/causes pairs. Onboarding fails for a small
number of recurring reasons, and naming them is often the difference between a
working implementation and an abandoned one.

**`credential_encryption`** — where a device obfuscates the WiFi passphrase.
Prose like "AES-128-CBC with a key from device metadata" is *not*
implementable. What is:

```yaml
credential_encryption:
  algorithm: "aes-128-cbc"
  padding: "pkcs7"
  algorithm_steps:
    - "2. salt = the first 8 characters of keydata, as UTF-8 bytes (NOT hex-decoded)."
    - "4. aes_key = MD5(utf8(keydata) || salt)[0:16]. One MD5 round only."
    ...
  variants: [...]              # where firmware generations differ, and how to tell
  openssl_equivalent: {...}    # for implementations without a crypto library
  password_constraints: {...}
  test_vectors: {...}
```

**Test vectors are the highest-value thing a spec can carry.** They let you
verify your crypto against known-good values before you go anywhere near
hardware, which turns "it doesn't work and I don't know which half is wrong"
into a single answerable question:

```yaml
test_vectors:
  input:
    meta_info: "00005E00530A|229999K9999999|Wemo_WW|..."
    passphrase: "correct horse battery staple"
  vectors:
    - method: 1
      keydata: "00005E229999K999999900530A"
      aes_key_hex: "6d27765d242fa465ae5ee33a671d7714"
      password_argument: "mKUXMHrq3r71VIBnALtgaQH/iTpWEZSSMVizvzMXrVM=2c1c"
```

Vectors use a documentation-range MAC and an invented serial, so they identify
no real device.

`scripts/test_wemo_spec.py` is how the claim is kept honest: it transcribes the
published algorithm using nothing but `hashlib`, `base64` and `openssl` —
importing none of our own code — and asserts the transcription reproduces the
spec's own vectors. If that cannot be written, the spec is underspecified and
CI fails, regardless of whether anything else still works.

That test is also why this repository has no supported client surface.
Existing libraries already do discovery, control and provisioning, and are
tested against far more hardware than we are; a second implementation from us
would be a worse copy of the thing we tell people to use. The spec is the
contribution, and proving it implementable is the test.

It covers all three client jobs: it reconstructs the M-SEARCH datagram from
`discovery...ssdp.request` and diffs it against the published example, parses
the published SSDP reply and description (including with the UPnP namespace
stripped), applies the `match` rule to a Wemo and to a printer, builds a SOAP
request from `soap_common.request_format` and diffs *that* against its example,
and parses the published `InsightParams` string into named fields.

!!! note "The Wemo scripts under `scripts/` are not a counterexample"
    `wemo_discover.py`, `wemo_control.py` and `wemo_setup.py` exist to check
    this spec against hardware, since every `verified` flag in it is still
    `false`. They are scaffolding with a deletion date — see
    [issue #16](https://github.com/PigsCanFlyLabs/opengreeniot-protocol-docs/issues/16).

### Factory reset, rejoin, credentials

```yaml
factory_reset:
  applicable: true                     # false when the device has none at all
  confidence: "medium"
  effect: "What is actually cleared — and what survives."
  procedures:
    - name: "Restore button held while power is applied"
      applies_to: ["F7C063", "WSP080"]   # omit when it applies to all variants
      hold_seconds: 5
      indicator: "Status LED blinks, then the setup AP reappears."
      steps: [...]

rejoin:
  in_place_supported: true       # accepts new credentials while still reachable
  requires_factory_reset: false
  steps: [...]

credentials:
  wifi_passphrase_protection: "device_encrypted"
    # plaintext | device_encrypted | tls | unknown | not_applicable
  stored_on_device: [...]
  issued_to_client: [...]        # what YOU must keep: tokens, certs, usernames
```

Two fields deserve a second look:

- **`factory_reset.effect`** — the blast radius. Clearing a WiFi credential is
  cheap; clearing a bridge's ZigBee network orphans every device paired to it.
  Read this before telling a user to hold a button for ten seconds.
- **`factory_reset.applicable: false`** — some devices have no reset to
  document. A motorcycle reached over its diagnostic connector holds no pairing
  state, and ECU resets are dealer-tool operations rather than a setup step.
  Saying so beats inventing a procedure, which on safety-relevant hardware is
  worse than an admission of nothing to document.
- **`credentials.wifi_passphrase_protection: device_encrypted`** — treat with
  scepticism. When the key is derived from data the device hands out
  unauthenticated, it stops an opportunistic listener and nothing else. It is
  obfuscation you must implement exactly, not a security control.

## A worked example

`device-specs/devices/wemo-devices.yaml` is the reference for how complete a
`setup` block can be. It is written so a Wemo device can be provisioned **from
that file alone** — SOAP wire format, payload layouts, the encryption algorithm
step by step with test vectors, status codes, timing, and troubleshooting.

Reading it in implementation order:

| Question | Where to look |
|---|---|
| How do I find one on the network? | `discovery.methods[].ssdp` — the M-SEARCH datagram, response headers, deduplication, and the `match` rule that separates it from every other UPnP responder |
| How do I read its description? | `discovery...parse.parse_rules` and `example` |
| How do I control it? | `soap_common.request_format` and `http_endpoints` |
| What does a returned value mean? | top-level `payload_formats` |
| How do I get the device into setup mode? | `setup.factory_reset.procedures`, or `setup.rejoin` to do it over the LAN |
| What is it called, and where does it answer? | `setup.methods[0].softap` — SSID prefix, gateway IP, port probe list |
| How do I build a request? | `soap_common.request_format` — template, headers, and the unqualified-arguments rule |
| How do I read a response? | `soap_common.response_format` |
| What does `GetApList` return? | `setup.methods[0].payload_formats.ApList` |
| How do I encrypt the passphrase? | `setup.methods[0].softap.credential_encryption.algorithm_steps` |
| Did I get the crypto right? | `...credential_encryption.test_vectors` |
| What order do the calls go in? | `setup.methods[0].steps` |
| How long should I wait? | `setup.methods[0].timing` |
| It failed — now what? | `setup.methods[0].troubleshooting` |

If you find yourself needing a source outside that file to finish an
implementation, that is a bug worth filing.

## Validating a spec

```bash
pip install -r requirements.txt
python scripts/validate_specs.py     # PASS/FAIL per file, with the failing JSON path
```

CI runs this on every push, regenerates `device-specs/index.json` and fails if
it is stale, and re-validates every published spec before building the docs.

## Writing one

See [How to Contribute](../contributing/index.md) and the
[Documentation Guide](../contributing/documentation-guide.md). `schema.json` is
the source of truth for field names and enums; `device-specs/README.md` is the
in-repo reference.

The rule of thumb for a `setup` block: write it for someone who has your
hardware and none of your context. If they would have to guess, add the field.
