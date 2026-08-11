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
  openness: ...              # was this protocol published, or did we recover it?
  protocol: ...              # ble | wifi | zigbee | zwave | obd2 | uart | can
  category: ...              # what KIND of thing it is — closed vocabulary
  type: ...                  # what the thing IS — free text
  identification: ...        # how to recognise it while scanning
  discovery: ...             # how to FIND one that is already on the network
  setup: ...                 # how to GET one onto the network
  variants: ...              # models that share a protocol but differ in detail

services: ...        # BLE GATT services and characteristics
http_endpoints: ...  # REST/SOAP endpoints for WiFi devices
mqtt_topics: ...     # MQTT topics
commands: ...        # named invocations, for devices with no GATT to hang them on
entities: ...        # how capabilities map to Home Assistant entities
helpful_urls: ...    # optional human references: docs, write-ups, forums, repos
helpful_videos: ...  # optional human video references: teardown/setup/capture walkthroughs
```

A spec must have `device` plus at least one transport block such as `services`,
`http_endpoints`, `mqtt_topics`, `obd`, `bus` or `cloud`. The one exception is a
**reference spec** — a `device.type` beginning `reference-` (SAE J1979 PIDs, ISO
14229 UDS services, ISO 15765-2 framing) documents a published standard that
other specs cite instead of restating, so it carries protocol tables rather than
an access surface of its own and is exempt from the transport requirement.
Everything else is optional, and the schema is deliberately
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

### `identification` — what a scanner sees before connecting

`device.discovery` says how to go looking. `device.identification` is the
narrower question a scanner asks of every advertisement it receives, thousands
of times a minute, before it has connected to anything: *is this one of ours?*

```yaml
device:
  identification:
    local_name_prefix: "Ember"          # BLE advertised name
    service_uuids: [...]                # advertised GATT service UUIDs
    manufacturer_data:
      company_id: 961                   # decimal, AD type 0xFF header
      company_id_hex: "0x03C1"          # same value, for readers
      # Only the same vendor's other allocations — 224 "Google" and 398
      # "Google LLC" are the shape this key is for. Never an SoC vendor's ID
      # (89 Nordic, 741 Espressif): thousands of unrelated products ship those
      # in their advertisement, and listing one claims every last one of them.
      additional_company_ids: [398]     # older firmware, rebadged models
    mac_prefixes:                       # IEEE OUI, most-significant octet first
      - prefix: "00:17:88"
        confidence: "medium"            # low (default) | medium | high
        notes: "Philips Lighting's own block, but it covers their whole catalogue."
      - "C4:7C:8D"                      # bare string == confidence: low
    mdns_service_type: "_hue._tcp.local."   # WiFi
    ssid_prefix: "..."                      # WiFi, AP mode
    default_port: 80                        # WiFi
```

Everything here should also be derivable from `discovery`, which carries the
evidence and the payload-level matching rules. The duplication is deliberate:
`identification` is the part a consumer can act on cheaply, and it is what the
mobile app's spec matcher reads.

**The four BLE signals are not equally strong, and a consumer should not treat
them as if they were:**

| Signal | Strength | Why |
|---|---|---|
| `service_uuids` | Strongest | A vendor-allocated 128-bit UUID in an advertisement is close to proof |
| `local_name_prefix` | Strong | Distinctive prefixes rarely collide, but users rename devices and some vendors ship a generic default |
| `manufacturer_data.company_id` | Medium | Identifies an advertisement shape, not a vendor — squatting is rampant (see `shining-glasses`, whose 21076 is just "TR" in little-endian) |
| `mac_prefixes` | Weakest | An OUI belongs to a vendor, not a product |

`mac_prefixes` earns its place by ranking rather than by deciding. An OUI never
justifies claiming a device is supported — `C4:7C:8D` matches every Xiaomi
radio ever built, not just the plant monitor — but an otherwise-anonymous
device carrying a known vendor's OUI is worth putting above one carrying an
unknown OUI in a list a human has to read. Two further limits are worth knowing
before relying on it: Apple platforms never expose it at all (CoreBluetooth
hands out a per-host UUID in place of the hardware address), and any device
using BLE privacy mode advertises a rotating random address with no OUI in it.

Record prefixes and company IDs that a source actually documents or that we
actually observed. Do not fill `mac_prefixes` in by looking the vendor's name
up in the IEEE registry: the registry says which OUIs a company holds, not
which one this product shipped with.

#### `mac_prefixes` entries carry their own confidence

Not every OUI is weak in the same way, and a spec that says so lets a consumer
rank them apart instead of flattening the lot. An entry is either a bare string
or a map:

```yaml
mac_prefixes:
  - "C4:7C:8D"                      # bare string, treated as confidence: low
  - prefix: "00:17:88"
    confidence: "medium"
    notes: >
      Free text. Say how you established this, so the next person can disagree
      with you on the evidence rather than on the verdict.
```

| `confidence` | Means | A consumer should |
|---|---|---|
| `low` (default) | The block is shared: subdivided into MA-M/MA-S slices held by unrelated companies, or belonging to a radio module vendor rather than the product's maker | Rank on it, never promote on it |
| `medium` | The block really is this manufacturer's, but covers their whole catalogue — "something this vendor made", not "this device" | Rank on it, and let it corroborate another signal |
| `high` | The block is this device family's and effectively nothing else's | Treat as evidence in its own right |

The default is `low` because that is what an unchecked block is worth, and
omitting the field is not a claim about it. Reach for `high` only with evidence
in `notes`; it is rare, and getting it wrong turns a hint into a confident lie.

`C4:7C:8D` (Mi Flora) is the worked example of `low`: IEEE subdivided it into
fifteen 28-bit assignments held by unrelated companies, and the one Mi Flora
comes from is `C4:7C:8D:6x`. A whole-octet prefix cannot express that, so it
also matches the other fourteen vendors. `00:17:88` (Hue) is the worked example
of `medium` — genuinely Philips Lighting's, and on their lamps and switches
too, not just bridges.

### `category` and `type` — what kind of thing is this?

Both name the device class, and the difference between them is who reads them.

`type` is free text for a human: `smart-scale`, `ebike-controller`,
`electronic_door_lock`. Write whatever is most precise.

`category` is a **closed vocabulary** for a program. It is required, and a
value outside the list is rejected:

| | | | | |
|---|---|---|---|---|
| `appliance` | `camera` | `climate` | `display` | `energy` |
| `fitness` | `health` | `hub` | `irrigation` | `light` |
| `lock` | `motor` | `printer` | `reference` | `robot` |
| `scale` | `sensor` | `speaker` | `switch` | `tool` |
| `tracker` | `tv` | `vehicle` | `wearable` | `other` |

The closed list is what makes the field useful downstream. The mobile app
draws an icon beside every scan result from this value, so it needs the three
specs that say `smart-scale`, `kitchen-scale` and `body-composition-scale` to
agree on one word (`scale`) — and a typo'd or invented category is
indistinguishable at the consumer from a device nobody has documented at all.
Both fall back to the same anonymous radio icon, which is the outcome the
field exists to prevent.

Pick the word someone would use to describe the device from across the room,
not the most precise one available:

- an LED strip controller is a `light`; an LED matrix panel is a `display`
- an e-bike mid-drive is a `motor`; the bike's diagnostic connector is `vehicle`
- a BBQ probe is a `sensor`, whatever the kitchen has to do with it
- a bridge or gateway you talk to *instead of* the device is a `hub`

Two rules that are not judgement calls: reference specs (a `type` starting
`reference-`) take `category: reference`, and the schema enforces that the two
fields agree. `other` is for a device the list genuinely cannot describe —
reach for it as a prompt to propose a new value, not as somewhere to leave it.

### `openness` — did we have to recover this?

`manufacturer_status` says what the vendor is doing. `openness` says something
different and easy to conflate with it: whether the protocol was ever
published. A vendor can be very much in business and completely open, and a
vendor can be long gone having never documented a byte.

| Status | Means | Read this spec as |
|---|---|---|
| `open_by_design` | Published by the people who build it; third-party clients are the point | A summary of upstream — go read upstream |
| `documented_api` | Official interface exists, product otherwise closed | Part citation, part reconstruction |
| `undocumented` | Nothing published; worked out by observation | Our best reconstruction, and it can be wrong |
| `hostile` | Vendor actively fights third-party clients | Documented anyway; expect deliberate breakage |

Omitting the block means `undocumented`, which is the default because it is
what nearly every spec here is. State it explicitly when it is anything else.

```yaml
openness:
  status: "open_by_design"
  reverse_engineered: false
  source_code: "https://github.com/wled/WLED"
  license: "EUPL-1.2"
  upstream_docs:
    - url: "https://kno.wled.ge/interfaces/json-api/"
      covers: "Endpoint paths and the state/info objects."
```

`reverse_engineered` is tracked separately from `status` because the two come
apart in practice: a vendor with a documented API usually leaves the
interesting half undocumented, so a `documented_api` spec is commonly both
cited and reconstructed. On an `open_by_design` spec it should be `false` —
that is the whole point of the field. It marks the spec as interoperability
work rather than liberation, and it keeps the registry from taking credit for
prising open a door that was never locked.

`license` is worth stating separately from the rest. An open protocol lets you
talk to the device; an open licence on its firmware lets you replace what is
running on it. The second is the larger freedom, and it is the one that means
a device can outlive anybody's interest in supporting it.

[`wled-controller`](../devices/wled-controller.md) is the worked example.

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
| `methods[].verified` | Has *this project* run this exact flow against hardware? | `false` on nearly every spec; set `true` only when the flow was actually replayed on the device. |

`verified: false` is not a warning label — it is the honest default, and it
tells you what to go and confirm. A `low`-confidence block naming its gaps is
far more useful than an absent one; "the onboarding exchange has not been
captured" is information, silence is not. Reserve `verified: true` for a flow
run against real hardware here: a fact recovered from an APK or a community
repository is `false` no matter how sure the source seems, the same way
`verification: reported` — not `confirmed` — is the label for a byte sequence
that was read out of someone else's code rather than off the wire.

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

## Numbers: units, scaling and C-vs-F

A numeric wire value carries more than a width. Command `parameters`,
characteristic `format` fields, `bus` message fields and `payload_formats`
fields share one vocabulary (`$defs/number_semantics` in `schema.json`) for
saying what the number *means*:

```yaml
- offset: 0
  length: 2
  name: "target_temp_raw"
  type: "uint16"
  scale: 0.01        # value = raw × scale + value_offset
  unit: "C"          # unit of the DECODED value — what is on the wire
```

The transform is linear on purpose: it runs backwards, so the same declaration
that decodes a reading also encodes a command parameter
(`raw = round((value − value_offset) / scale)`). Enumerated numbers carry a
`values` code table instead (`{0: "low", 1: "medium", 2: "high"}`). Raw
`min`/`max` on a parameter bound the bytes; `min`/`max`/`step` on a `number`
entity describe the decoded control.

**`unit` answers C-vs-F — but read `unit_source` before trusting it**,
because temperature devices come in two shapes that look alike and decode
differently:

| Shape | `unit_source` | Example | What a client does |
|---|---|---|---|
| Wire unit is a protocol constant; any C/F toggle is display-only | `fixed` (default) | Ember Mug: always centi-°C on the wire; `fc540004` changes the mug's screen, nothing else | Decode with `scale`/`unit` and never look back |
| Wire unit follows a device setting | `device_setting` | Inkbird iBBQ: the same raw 165 is 165 °C or 165 °F depending on state | Read the setting named in `unit_reference`, map it through `unit_values`, only then decode |

Getting the second case wrong is not an error you notice: every reading stays
plausible and is simply in the wrong unit. That is why `unit_source:
device_setting` requires a `unit_reference` — "it depends" without "on what"
would document the trap without the exit.

Worked examples: `ember-mug.yaml` (fixed wire unit, display-unit select,
`values` tables), `inkbird-bbq-thermometer.yaml` (device-setting units),
`gerbing-thermogauge.yaml` (`value = raw × 0.5 + 85` — the `value_offset`
case), `wemo-devices.yaml` (mW / mW·min `payload_formats` columns).

## Controls: `entities`, and `commands` for a device with no GATT

`entities` is the block a client draws from: one entry per control or reading,
each saying what platform it is, where it reads its state, and which command
each of its roles sends. On a BLE device the bindings are characteristics
(`state_characteristic`, `command_characteristic`) and the commands live on
the characteristic. A WiFi device has neither, so the same entity binds
`state_endpoint` + `state_command`, and its roles name entries in a top-level
`commands` block.

That block exists because of one thing an entity cannot say. `commands:
{turn_on: plug_turn_on}` carries a *name*; turning a Wemo plug on is
`SetBinaryState` **with `BinaryState` = 1**, and the `1` has nowhere else to
live. So the two blocks divide as:

| Block | Answers | Example |
|---|---|---|
| `http_endpoints` | What actions exist, what they take, what they return | `SetBinaryState` takes a `BinaryState` of 0 or 1 |
| `commands` | One invocation of one action, arguments already chosen | `plug_turn_on` is that action with `1` |

```yaml
commands:
  set_cook_mode:
    description: "Set the Crock-Pot's cooking mode, carrying the cook time along unchanged."
    transport: "soap"
    service: "urn:Belkin:service:basicevent:1"
    action: "SetCrockpotState"
    arguments:
      mode: "{mode}"
      time: "{time}"
    parameters:
      mode: { type: "integer", required: true, values: { "51": "low" } }
      time:
        type: "integer"
        unit: "minutes"
        source: "state:GetCrockpotState.time"   # read it back, then send it
        default: 0
    example_body: |                              # what the above renders to
      ...
```

Two keys there earn their place:

- **`source`** — where a client gets a value it is *not* the one setting.
  `SetCrockpotState` carries mode and cook time together, so changing the mode
  alone means reading the time back and sending it along. Leave that implicit
  and the spec produces a client that clears the timer every time somebody
  switches to Warm.
- **`default`** — a genuine constant, for protocol filler. The rule a consumer
  applies before drawing a control is that every parameter must be the value
  the control owns, a spec constant (`default`), or a declared read-back
  (`source`); a parameter that is none of the three means the control cannot
  send the command at all.

The two keys are **mutually exclusive**, and the schema enforces it, because
they answer "the caller supplied nothing" with opposite instructions: `default`
says substitute the constant, `source` says the truth lives on the device and a
send without it must *fail visibly*. A parameter carrying both lets a renderer
paper over a failed read-back with the constant — on the Crock-Pot, a cleared
timer or a cooker stopped mid-run, with nothing on screen saying so. The first
published Wemo spec made exactly this mistake and review caught it.

`example_body`, and the `example` on an `http_endpoints` request or response,
do for control what test vectors do for crypto: they turn "the device rejects
this and I cannot tell which half is wrong" into a diff.
`device-specs/devices/wemo-devices.yaml` is the worked example — a smart plug
and a Crock-Pot, where the Crock-Pot answers `GetBinaryState` with `0`
whatever it is doing, so the entity that would have been obvious is the one
that lies.

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
