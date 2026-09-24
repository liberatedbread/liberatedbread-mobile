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
  protocol: ...              # ble | wifi | lan | zigbee | zwave | obd2 | uart | can
  category: ...              # what KIND of thing it is — closed vocabulary
  type: ...                  # what the thing IS — free text
  identification: ...        # how to recognise it while scanning
  discovery: ...             # how to FIND one that is already on the network
  managed_by: ...            # driven through a controller — which spec, how to spot it
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
Everything else is optional, but the **top level and `device` are closed**:
every key written there must be one the schema declares. Bespoke,
device-specific detail — a vendor's own framing, opcode table or session dance
— goes under the top-level `protocol_details:` namespace, which accepts
anything:

```yaml
protocol_details:
  ecp2:                      # bespoke; nothing binds to it
    description: "Roku's WebSocket layer over the ECP port."
```

Closing the top level is what makes the rest of it mean something. While it was
open, a validator could not tell a bespoke block from a standard field spelled
wrong or nested one level too deep — and both had happened at scale, silently:
`local_access`, `features`, `protocol_handler` and `payload_formats` were
written inside `device:` on seventeen specs, where no consumer looks, so five
printers' `image_upload` capability was simply absent from the app. Neither
class of mistake raised a single validation error. The price is that a new
first-class key needs a schema change; that is deliberate, because a
first-class key is a contract.

Deeper objects — inside a service, an endpoint, an entity — remain open, so a
spec can still annotate freely where it is describing rather than declaring.
Consumers parse the subset they understand.

Two keys are rejected by name rather than by the closure, because the error
message matters more than the rejection:

- a top-level `references:` — reference links go in `helpful_urls` (see below),
  and "additional properties are not allowed" would not say so;
- a command's `payload:` accepts only `key` and `value_type` — a raw byte
  sequence is `value` (fixed) or `template` (parameterized), never
  `payload.bytes`;
- a BLE command carries `value` **or** `template`, never both. Declaring both
  has no defined reading: an encoder that prefers `value` sends the constant
  and ignores every parameter the spec drew a control for (xkglow-chrome's
  colour command wrote pure red whatever was picked), and one that prefers
  `template` makes the fixed bytes dead text. A fixed "on" and a
  parameterised colour are two commands, each bound to its own entity role.

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

The field is `helpful_urls`, not `references`. A top-level `references:` is
rejected by the schema rather than ignored: it reads like a spec field, it is
not one, and a spec that used it kept its links in the file and out of every
generated artifact with nothing to say so.

### Where the facts came from

`helpful_urls` points a reader onward. `evidence` says what *this document*
rests on, so a later reader can tell a byte-accurate transcription from a
plausible reconstruction — and knows which claim to re-check first when a
device stops behaving.

```yaml
evidence:
  app_static_analysis: >
    Prose: what was read, and what it established.
  open_questions: >
    Prose: what is still inference.
  artifacts:                        # the itemised half
    - type: "static_analysis"
      artifact: "com.example.app v1.2.3 (versionCode 1203)"
      sha256: "…"
      obtained_via: "third-party APK mirror, 2026-08"
      description: "What this build established, negative findings included."
```

Every section but `artifacts` is free-form: name it for what it was
(`live_lan_probe`, `documentation_review`, `app_static_analysis`) and write
prose. `artifacts` is a list and each entry needs a `type`. Record the digest
of an artifact, never the artifact — see the clean-room rules.

Provenance is spelled `evidence` and nothing else. `sources:` and `source:`
were two other spellings of the same idea and are rejected now, for the reason
`references` is: three shapes meant nothing could ask a spec where its facts
came from without already knowing which one its author had reached for.

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

An `initialization` step names a `characteristic` and is *executable* when it
carries at least one of `write` (bytes), `read` (`true`) or `subscribe`
(`true` — open notifications on it, which SmartDawn needs before anything is
sent). `when` states the cadence: `connect` (the default, once per
connection) or `before_each_command` for the devices that demand a preamble
before every write — KingSmith's MC-21 answers `CONTROL_NOT_PERMITTED` to any
control-point write not immediately preceded by its ODM frame. A step with
only a `description` is documentation of a handshake a client must implement
itself (Schlage's per-session SPAKE2 exchange has no fixed bytes to state);
a consumer reports it and does not pretend to have run it. `notes` sits
beside an executable step. The step object is closed — an undeclared key
is an error, because every key here changes what the step *is*.

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
    zigbee_model_id: "TS0601"               # Zigbee Basic cluster
    zigbee_manufacturer_names: [...]        # the key a Tuya DP map is chosen by
    zwave_manufacturer_id: "0x0175"         # Z-Wave, hex
    notes: >                                # prose beside the keys, never instead
      ...
```

Everything here should also be derivable from `discovery`, which carries the
evidence and the payload-level matching rules. The duplication is deliberate:
`identification` is the part a consumer can act on cheaply, and it is what the
mobile app's spec matcher reads.

The block is **closed**: a key not listed above fails validation. It has to be,
because a scanner reads it by key and a signal filed under a key nothing reads
never fires — three specs kept their advertised names under
`advertisement_names`, `local_name` and `local_name_contains` and validated
while matching nothing. Exact names are `local_names`; several prefixes are
`local_name_prefixes`; a substring or regex test has no identification form
and belongs in `discovery.methods[].ble.local_name`; a hostname pattern or a
cloud endpoint is `notes` or `protocol_details`. The convention test names the
key you probably meant.

#### One probe, a whole product line: `platform_prefixes` and `managed_by`

Some vendors answer one discovery protocol with everything they make.
Ubiquiti's UDP-10001 probe draws a reply from every access point, switch,
console, NVR and camera on the link, and the only thing that tells them apart
is the platform string in the reply (`UNVR`, `UCKP`, `UFP-UAP-B`, `UVC G4
Pro`). `identification.platform_prefixes` is the table that turns that string
into something a consumer can draw — and, where a prefix belongs to a device
another spec documents, hands the scan result to that spec:

```yaml
identification:
  lan_protocols: ["ubiquiti-discovery"]
  platform_prefixes:                    # match by prefix, longest wins
    - prefix: "UNVR"
      pictogram: "nvr"
      verification: "confirmed"         # read in a live reply
    - prefix: "UVC"
      pictogram: "ip-camera"
      spec: "unifi-protect-camera"      # that spec's device, not this one's
    - prefix: "UCG"
      pictogram: "router"
      verification: "hypothesis"        # public product code, spelling unread
```

`pictogram` uses the `device.pictogram` vocabulary and overrides the spec-level
token for a matching device. A row's `verification` says whether the prefix
was read off the wire or taken from the vendor's public naming; keep the
unread ones in, marked, so a new console degrades to a sensible glyph rather
than the category icon. `ubiquiti-unifi-device.yaml` is the worked example.

The other half is the device that is *driven through* one of those rows. A
Protect camera is adopted to an NVR, configured there and streamed from there;
a bulb behind a Zigbee hub has the same shape. `device.managed_by` says so,
names the controller's spec, and says how to pick the controller out of the
scan results:

```yaml
device:
  managed_by:
    spec: "ubiquiti-unifi-device"       # the controller's spec id
    discovery:                          # at least one signal, matched against
      platform_prefixes: ["UNVR", "UDM", "UCKP"]   #   the CONTROLLER's replies
      # ssdp_search_target: "urn:..."   # or an SSDP target
      # mdns_service_type: "_x._tcp.local."   # or an mDNS service type
    notes: "What the controller does for this device, and what it still answers itself."
```

A consumer answers "is this managed elsewhere, and where is elsewhere" from
these two blocks and holds no vendor list of its own. `spec` must resolve and
every prefix must be a row of that spec's table; `scripts/test_device_specs.py`
checks both. This is distinct from `camera.feed_host_source` (where a stream is
served from) and from `instances` (the controller's own view of its children).

#### A service type is often a platform, not a product

`mdns_service_type` looks like a strong signal and frequently is not.
`_esphomelib._tcp` is every ESPHome node ever flashed; `_hap._tcp` is every
HomeKit accessory; `_http._tcp` is every web server on the link. A matcher that
resolves a service type to a spec labels the whole platform with whichever spec
claimed the type first — which is not hypothetical: while `ratgdo` was the only
spec claiming `_esphomelib._tcp`, every ESPHome device on the LAN rendered as a
garage-door opener.

`mdns_txt_match` is how a spec narrows a platform service type to its product.
Entries are **ANDed** — all must hold — and each says where its value comes
from:

```yaml
identification:
  mdns_service_type: "_esphomelib._tcp.local."
  mdns_txt_match:
    - key: "project_name"        # TXT key, spelled as the device publishes it
      match: "prefix"            # exact (default) | prefix | contains | regex
      value: "ratgdo."           #                 | present | absent
      description: >
        ESPHome publishes `esphome: project: name:` here; every ratgdo board
        config sets it to `ratgdo.<board>`.
```

`present`/`absent` take no `value` — use them when the existence of a key is
itself the signal (ESPHome publishes `config_hash`, and nothing else on
`_http._tcp` does). `case_sensitive` defaults to true, which is what the wire
does.

The full conditions, with their evidence, belong in the matching
`discovery.methods[].mdns.txt_match`; the identification copy is the cheap one.
A spec whose discovery method narrows a service type but whose identification
block does not is over-matching, and `scripts/test_esphome_spec.py` fails on it.

The other half of the contract is the catch-all. One spec per platform service
type may declare `platform_fallback: true` on its discovery method, meaning
"use me only when no spec matched this service type with a narrower
`txt_match`":

```yaml
discovery:
  methods:
    - type: "mdns"
      mdns:
        service_type: "_esphomelib._tcp.local."
        platform_fallback: true
```

That is what makes an unrecognised node render as **itself** — its own name and
its own entities — instead of as whichever product got there first.
`esphome-device.yaml` is the worked example, and it deliberately declares no
`entities`: it cannot know what a node has, so it documents how to ask.

**The two keys are exclusive.** `txt_match` is a *precondition* — a method
carrying one may only ever claim what the condition proves. `platform_fallback`
is what a consumer reaches for when no precondition was met. A method with both
has no single reading, and read the wrong way it rebuilds the bug one service
type over: an ESPHome spec that is also the catch-all for `_http._tcp` claims
every printer and router that fails its TXT condition. Set `platform_fallback`
only on a service type the firmware actually owns.

**Which types are shared is a registry, not a judgement call.**
`registries/shared-service-types.tsv` lists the mDNS types and SSDP search
targets that prove nothing on their own — `_hap._tcp.local.`,
`_http._tcp.local.`, `_googlecast._tcp.local.`, `upnp:rootdevice`,
`urn:schemas-upnp-org:device:MediaRenderer:1` and the rest — with a reason
for each. A consumer never promotes a match on one of them alone, so a spec
whose only axis is in that table matches nothing until it adds one that is
its own. Adding a type there is a spec-pack refresh, not an app release; the
file's README says how to.

#### An SSDP target is often a device class, not a product

The same problem one protocol over. `urn:schemas-upnp-org:device:MediaRenderer:1`
is every DLNA renderer on the link, and the vendor's name lives not in the
M-SEARCH reply but in the description document its LOCATION header points at.
`ssdp_match` is the SSDP twin of `mdns_txt_match` — conditions on that
document's `<device>` elements, ANDed, that narrow a shared target to this
product:

```yaml
identification:
  ssdp_search_targets:
    - "urn:schemas-upnp-org:device:MediaRenderer:1"
  ssdp_match:
    - field: "manufacturer"      # manufacturer | modelName | modelNumber |
      match: "exact"             #   modelDescription | friendlyName | deviceType | UDN
      value: "Hisense"
      description: "<manufacturer>Hisense</manufacturer> in the port-38400 descriptor."
```

`discovery.methods[].ssdp.match` carries the same narrowing with its evidence
(`manufacturer_exact`, the prose `rule`); the identification copy is the
cheap one a matcher reads first. `hisense-vidaa.yaml` is the worked example.

#### Probes that are neither SSDP nor mDNS

Two more discovery methods exist for hardware that is found by asking on a
port of its own, and both are declared in the shape a consumer executes
rather than described in prose:

- **`udp_broadcast`** — send `probe_hex` to `port`, read replies in
  `response_format`. Two keys cover the protocols a plain broadcast does not:
  `multicast_group` sends the probe to a group instead of a broadcast address
  (Yeelight's port-1982 search and Govee's LAN API both use
  `239.255.255.250`), and `listen_port` is where replies arrive when that is
  not the probe's source port (Govee sends to 4001 and answers to 4002 — bind
  it before you send). `identity_mapping.stable_keys[].source` is prefixed by
  the dialect it is read with: `tlv:0x0005` a TLV record by type,
  `json:msg.data.device` a path into a JSON reply, `header:id` an HTTP-style
  header line. A device that answered is tagged with the spec's
  `identification.lan_protocols` token (`govee-lan`, `yeelight-ssdp`,
  `tplink-smarthome`), which is the strong identification: only something
  that speaks the protocol replies at all. When two specs send the same
  probe, the narrower one states what its product's reply must carry in
  `response_match` (`source`/`match`/`value`, ANDed, the udp_broadcast twin
  of `scope_match`). The broader one declares `platform_fallback: true`,
  which `ssdp` now also accepts. Yeelight's cube lists `set_segment_rgb` in
  the reply's `support` header, and `yeelight-wifi` is the fallback for
  every other Yeelight.
- **`ws_discovery`** — the OASIS WS-Discovery Probe ONVIF cameras answer, a
  SOAP-over-UDP multicast to `239.255.255.250:3702` with `probe_types`
  (`dn:NetworkVideoTransmitter`), whose ProbeMatch carries a `urn:uuid`
  endpoint, Scopes and the device-service URL. It is not SSDP and an ONVIF
  device answers no SSDP target; four camera specs used to claim one. The
  generic `onvif.yaml` declares the method with `platform_fallback: true`,
  exactly as an mDNS platform spec does; a vendor spec that can narrow the
  Scopes declares its own with `scope_match`, and one that cannot identifies
  itself by what it volunteers on its own (`mac_prefixes`, an HTTP probe).

#### When one device family has two paths for the same thing

`commands[].path_fallback` and `entities[].state_topic_fallback` are the HTTP
siblings of `fallback_characteristic` and of `state_mapping`'s `<role>_fallback`:
a second address for the *same* invocation or reading, for a family whose
firmware generations name entities differently.

```yaml
commands:
  door_open:
    path: "/cover/Door/open"           # ESPHome >= 2026.1 (name-addressed)
    path_fallback: "/cover/door/open"  # <= 2025.12 (object_id-addressed)
```

The contract is narrow on purpose: send `path`, and fall back **only** on an
unambiguous "no such entity" answer from the device (an HTTP 404) — never on a
timeout or a 5xx, and never as a blind second send. A command that fires twice
because the first request was merely slow is a worse failure than the 404, and
on a garage door it is a moving one. Two genuinely different actions are two
commands, not a fallback.

**The four BLE signals are not equally strong, and a consumer should not treat
them as if they were:**

| Signal | Strength | Why |
|---|---|---|
| `service_uuids` | Strongest | A vendor-allocated 128-bit UUID in an advertisement is close to proof |
| `local_name_prefix` | Strong | Distinctive prefixes rarely collide, but users rename devices and some vendors ship a generic default |
| `manufacturer_data.company_id` | Medium | Identifies an advertisement shape, not a vendor — squatting is rampant (see `shining-glasses`, whose 21076 is just "TR" in little-endian) |
| `mac_prefixes` | Weakest | An OUI belongs to a vendor, not a product |

Where a company id is shared, the payload behind it is the discriminator, and
`discovery.methods[].ble.manufacturer_data.pattern` is where it is stated.
The pattern is hex matched against the manufacturer-specific payload **after**
the two little-endian company-id bytes, which `company_id` has already
matched: an advertisement reading `54 52 00 61` on the air under company id
21076 (`0x5254`) has the pattern `0061`, never `54520061`. `match` is `prefix`
(the default), `exact`, or `masked` — in which case `mask` is the same length
as `pattern` and the comparison is `payload & mask == pattern & mask`. The five
"TR" specs (ideal-led `0061`, magic-display `0027`, shining-glasses `0041`,
shining-mask `004a`, led-helmet-display `0074`) differ in nothing but those
two bytes, so the origin is what makes them five devices rather than one.

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
| `lock` | `motor` | `personal_care` | `printer` | `reference` |
| `robot` | `scale` | `sensor` | `speaker` | `switch` |
| `tool` | `tracker` | `tv` | `vehicle` | `wearable` |
| `other` | | | | |

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
- an IPL hair-removal handset or a microcurrent face toner is `personal_care`
  (grooming/cosmetic); `health` is for medical-adjacent devices (oximeters,
  blood-pressure monitors)
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
    methods: [...]          # ordered for a reader; see below
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

Each method has a `type` from a fixed set:

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

#### `name` and `role` — which one am I supposed to do?

`type` is the mechanism, not a label, and it was never enough to read a list
by. Two methods on one device routinely share it: both Rachio generations are
`softap_http`. Worse, a bare list reads as *pick one* — so a reader picks the
flow that has not worked since the cloud shut down.

So once a spec lists **two or more** methods, every entry carries both fields
(the schema requires them at that point):

| Field | What it answers |
|---|---|
| `name` | What a person chooses by — "Gen 3 setup AP: HTTPS JSON under a pinned CA", "HOME-button handshake, no account". Say what makes this one different from its siblings; don't restate the `type`, and never write "Method 2". |
| `role` | What kind of choice this entry is |

`role` is one of:

| Role | Meaning |
|---|---|
| `primary` | The route to recommend. At most one method per device may claim it, and it comes first |
| `alternative` | Another independent route to the same finished state — pick this **or** the primary |
| `variant` | Which one applies is decided by the hardware or firmware in hand, not by preference. Say which units it covers in `description` |
| `historical` | Cannot be completed today — the cloud is gone, the app release that spoke it is retired. Kept so a reader who finds it referenced elsewhere knows why it fails |

**Every entry in `methods` is a route the reader chooses.** If two entries are
things they must *both* do, in order, they were never two methods — see
`stages` below.

#### `stages` — a route that takes more than one phase

"Plug in the Ethernet" and "press the link button" are both required and
happen in that order. Side by side in `methods` they read as a choice, and a
reader does one of them and stops. A route with more than one phase is **one**
method carrying `stages`:

```yaml
methods:
  - type: "button_pairing"        # the route's defining act
    name: "Ethernet, then the link button"
    role: "primary"
    verified: false
    description: >
      Two things have to happen and neither is a choice...
    stages:
      - type: "wired"             # the phase keeps its own type
        name: "Get the bridge onto the LAN"
        verified: false
        description: >
          Plug the bridge into the router with Ethernet and power it...
        steps: [...]
      - type: "button_pairing"
        name: "Authorize this client at the link button"
        verified: false
        description: >
          The bridge issues an API username to any client that asks within
          roughly 30 seconds of the link button being pressed...
        issues_credentials:       # and its own detail block
          username: {...}
        steps: [...]
```

A stage is a method in miniature — same shape, so it keeps its own `type`,
prose, detail block (`softap`, `ble`, `cloud`, `issues_credentials`, `timing`,
`troubleshooting`) and `steps`. That is the point: flattening the Hue route
into one step list would force it to be *either* `wired` or `button_pairing`,
and "this bridge has no Wi-Fi radio" is a fact worth keeping.

Stages do not nest, they carry no `role` (there is no choice inside a route),
and a method has `steps` **or** `stages`, never both.

#### Ordering

The order is an instruction, so it has to hold when someone reads down the
list with the device in their hands:

1. `primary`, then `alternative` entries **easiest first**
2. `variant`
3. `historical` — last, or it gets tried first

*Easiest* means fewest obstacles for the reader, not fewest packets: no vendor
account beats an account, no extra hardware beats a hub or a second radio, and
a flow this project has actually replayed beats one nobody has. Which of two
alternatives is easier is a judgement call; the mechanical parts of the rule
above are enforced by `scripts/test_device_specs.py`.

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

Where the payload is an **outcome envelope** — the transport status says
nothing and success or failure is read from the body — add `envelope:` beside
the prose, so a decoder follows data rather than a paragraph. Hue's CLIP v1
answers HTTP 200 to everything and puts the verdict in a JSON array:

```yaml
payload_formats:
  V1Envelope:
    envelope:
      container: "array"              # array | object
      success_key: "success"          # element carrying this = one attribute acknowledged
      error_key: "error"              # element carrying this = an error object ...
      error_type_path: "type"         #   ... whose type code is here (inside the error)
      error_description_path: "description"
      error_types:                    # keyed by the code as a string
        "101": { class: "retry",        description: "link button not pressed" }
        "1":   { class: "repair",       description: "unauthorized user" }
        "201": { class: "precondition", description: "parameter not modifiable",
                 remedy: "carry \"on\": true in the same write" }
```

A body that is not the declared `container` is not an envelope (a bare object
answering a CLIP GET is a plain success). Walk every element — a mixed
envelope can succeed on one attribute and fail on another. `class` is what a
client *does*: `retry` is the expected answer while something the user
controls is pending, so keep polling and say nothing; `repair` means a stored
credential or pairing is gone, so retrying cannot succeed and the client
surfaces re-pairing; `precondition` is a well-formed request that needs
something else sent first or alongside, and `remedy` says what; `terminal` —
the default for any code not listed — fails the request and shows the
description. `hue-bridge.yaml` is the worked example; its six `parse_rules`
stay as the readable form of the same facts.

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
  applicable: true              # false = none at all; "unknown" = not established
  confidence: "medium"
  effect: "What is actually cleared — and what survives."
  description: |
    Prose for a person: which part is established, which is inferred, and
    what to watch for. `effect` is the one-liner; this is the context.
  procedures:
    - name: "Restore button held while power is applied"
      verified: true                     # false = a candidate, and `basis` is required
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
- **`factory_reset.applicable: "unknown"`** — nobody has established a reset on
  this hardware. It is a different claim from `false`: one says there is
  nothing to find, the other says nobody has looked hard enough yet.

  An unknown reset may still list what to try. Dropping a likely procedure
  throws away real knowledge — it is the first thing someone holding the device
  should attempt — so the rule is not silence but labelling: every procedure
  under an unknown reset must say `verified: false` and cite a **`basis`**.
  Whether a candidate came from the vendor's manual or from "every other bulb
  in this family works this way" changes how much a reader should trust it, and
  a candidate nobody can weigh is indistinguishable from a guess.

  `verified` is about the *procedure*; `applicable` is about the *device*. They
  move independently: a device can plainly have a reset whose exact sequence
  nobody has pinned down.
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
  device_class: "temperature"   # what kind of reading — BLE format fields only
```

The transform is linear on purpose: it runs backwards, so the same declaration
that decodes a reading also encodes a command parameter
(`raw = round((value − value_offset) / scale)`). Enumerated numbers carry a
`values` code table instead (`{0: "low", 1: "medium", 2: "high"}`). Raw
`min`/`max` on a parameter bound the bytes; `min`/`max`/`step` on a `number`
entity describe the decoded control.

A BLE characteristic's `format` field may also state its **`device_class`**
— the class of the reading (`battery`, `temperature`, `humidity`, `voltage`,
`current`, `power`, `speed`, `distance`, `weight`, …), in the same vocabulary
as `entities[].device_class` (both `$ref` `$defs/device_class`). It is there
so a consumer registering or drawing a reading does not have to guess the
class from substrings of the field's name. State it where it is obvious, omit
it for a raw code or flag byte, and keep it equal to the class of any entity
that binds the field through `state_mapping.value` — the test suite checks
the pair agree.

**`unit` answers C-vs-F — but read `unit_source` before trusting it**,
because temperature devices come in two shapes that look alike and decode
differently:

| Shape | `unit_source` | Example | What a client does |
|---|---|---|---|
| Wire unit is a protocol constant; any C/F toggle is display-only | `fixed` (default) | Ember Mug: always centi-°C on the wire; `fc540004` changes the mug's screen, nothing else | Decode with `scale`/`unit` and never look back |
| Wire unit follows a device setting | `device_setting` | Inkbird iBBQ: the same raw 165 is 165 °C or 165 °F depending on state | Read the setting named in `unit_reference`, map it through `unit_values`, only then decode |

When the setting changes the resolution as well as the unit, add
`unit_scales`, a scale per unit, keyed by what `unit_values` yields. A Mi
Scale reports kilograms at raw/200 but pounds and jin at raw/100:
`unit_scales: {kg: 0.005, lb: 0.01, jin: 0.01}`, with `scale` as the
fallback for any unit not listed.

A unit setting, or any other reading, often lives in a few bits of a packed
byte. `mask` picks them out before anything else applies: the value becomes
`(raw & mask) >> (trailing zero bits of mask)`, and several fields may share
one `offset` with different masks. Hotwired's battery byte is `mask: 0x07`
for its gauge step and `mask: 0xF0` for its present flag. The Mi Scale v2's
two unit bits sit in different control bytes, so its `unit_flags` field
reads both bytes as one little-endian word under `mask: 0x4001`.

Some characteristics carry more than one kind of frame. `format_match:
{offset, value}` on the characteristic says which frames `format`
describes: any notification without `value` at `offset` is not decoded, and
entities bound to it keep their last state. Hotwired's status notifications
are CC reports interleaved with AA echoes of the last write; without the
match, every echo would be published as a status.

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

One role deserves its own sentence: **`toggle`** declares that the bound
command *flips* power rather than setting it, so a consumer must establish
the current state before sending — a blind toggle turns a sleeping device on.
It exists for the sets whose only power channel is a flip (a TV remote's one
power key); where a device has discrete commands, `turn_on`/`turn_off` are
the honest bindings and `toggle` at most rides alongside for consumers that
have read the state. An entity that resolves *no* roles a consumer knows must
be hidden, not rendered as a dead control. The reasoning is worked through in
[Spec Evolution P13](../contributing/spec-evolution.md#p13).

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

One spelling difference between the two command families is deliberate. A
network parameter's code table is `values: { "51": "low" }`, as above. A BLE
command parameter states the same enumeration as `allowed: [0, 1]` plus
`labels: ["off", "on"]`, paired by index — and the schema rejects `values`
there, because on the BLE side `values` is the decode-side code table of a
`format` field and has no meaning on something a client *writes*. Nine
parameters wrote it anyway and a consumer implementing the declared vocabulary
drew a 0–255 slider over a two-position switch.

The two keys are **mutually exclusive**, and the schema enforces it, because
they answer "the caller supplied nothing" with opposite instructions: `default`
says substitute the constant, `source` says the truth lives on the device and a
send without it must *fail visibly*. A parameter carrying both lets a renderer
paper over a failed read-back with the constant — on the Crock-Pot, a cleared
timer or a cooker stopped mid-run, with nothing on screen saying so. The first
published Wemo spec made exactly this mistake and review caught it.

The same division carries to a REST-shaped device unchanged; only the address
changes spelling. A `transport: "http"` command pairs `method` with `path` the
way SOAP pairs `service` with `action` — and needs both halves, because REST
APIs answer GET and PUT on one path with different operations. Its `path` may
carry `{name}` placeholders that substitute from `parameters` exactly as
`arguments` values do:

```yaml
commands:
  light_set_brightness:
    transport: "http"
    method: "PUT"
    path: "/api/{username}/lights/{id}/state"
    arguments: { on: true, bri: "{bri}" }
    parameters:
      bri:      { type: "integer", required: true, min: 1, max: 254 }
      username: { type: "string", source: "credential:username" }
      id:       { type: "string", source: "instance:id" }
```

That example uses the other two `source` schemes, siblings of `state:`.
`credential:<name>` is a per-device secret the client stored when it paired —
the Hue bridge's link-button flow issues a `username` that every later path
embeds — and `instance:<key>` is the identifier of the child currently being
addressed. Both keep `source`'s contract: no default, and a renderer holding
no value must fail the send visibly. An unpaired client that errors at
`credential:username` is behaving correctly; one that quietly sends without it
is the bug.

Three more keys on a network command close the gaps that used to leave a
declared command unsendable:

- **`headers`** — request headers this command sends, name → value, with the
  same `{name}` substitution as `body` and `path`. This is where a bearer
  credential rides (`AUTH: "{auth_token}"` on every Vizio key, from a
  `source: "credential:auth_token"` parameter) and where a REST API's
  insisted-on `Content-Type` is stated. A placeholder the consumer cannot
  fill fails the send; it never goes out empty.
- **`auth`, naming entries of the root `auth_schemes`**, for a device that
  accepts more than one credential on the same commands. Sony Bravia takes
  either a pre-shared key (`X-Auth-PSK`) or the cookie a PIN pairing
  issued. Pinning one of them as a fixed header locked out every client that
  took the other route. Each scheme is `type: header` (its `headers` merge
  over the command's) or `type: http_basic` (`username`/`password`, which
  the client base64-encodes), and names the stored `credential` it needs. A
  command lists the schemes it accepts, in order of preference, and the
  client uses the first one it holds a credential for. Placeholders fill
  from the command's parameters first, then from that credential. Sony's
  `act_register` authenticates with `pin_basic`, whose password is its own
  `pin` parameter.
- **A literal `body` for an HTTP command whose wire shape is not a flat
  object.** `arguments` renders a flat JSON object; Vizio's
  `{"KEYLIST":[{...}]}` and Sony's JSON-RPC envelope are not one, so those
  commands declare the document itself as a `body` template. Where the
  template has no blanks, `example_body` must be the same document —
  `scripts/test_device_specs.py` diffs every http/websocket command's pair —
  so a worked example belongs only on a command with parameters to fill.
- **`auto` on a parameter**, with `checksum_start`/`checksum_xor` — the same
  encoder-filled roles a BLE parameter may carry (`checksum`, `xor_checksum`,
  `subtract_checksum`, `crc8`, `crc16_modbus`, `sequence`, `packet_length`),
  for byte-framed socket
  protocols such as Magic Home's TCP frames. The enum is closed on both
  sides and a test keeps the two identical.

And one rule on the entity side: **`state_command` is a name.** It resolves
to a key of `commands`, the `name` of an `http_endpoints` entry, or (on a BLE
spec) a characteristic command — never a wire token. A one-path-POST API
therefore declares its state read as a command carrying the body
(`get_all_conf: {path: /post, body: '{"Command": "Channel/GetAllConf"}'}`)
and points `state_command` at that key; the test suite fails a value that
resolves to nothing, because that was a card whose buttons worked and whose
value never arrived.

`instance:` exists because of hubs. A hub is one network presence fronting a
population the spec cannot enumerate — which lights sit behind a bridge is the
owner's business, not the spec's — so the entity describes the *shape* of one
child and declares `instances:`:

```yaml
entities:
  - platform: "light"
    name: "Hue Light"
    instances: { keyed_by: "id", label_path: "name" }
    state_command: "Lights"
    state_mapping: { is_on: "state.on", brightness: "state.bri" }
    commands:
      turn_on: "light_turn_on"
      turn_off: "light_turn_off"
      set_brightness: "light_set_brightness"
```

The `state_command` reply is a JSON object keyed by child id — enumeration and
every child's state in one request, which matters on bridges that throttle
chatty clients. A client walks the keys; for each child the `state_mapping`
paths resolve *inside that child's object*, `label_path` names it for the
human, and the id fills the `instance:` placeholder of every command the
entity binds. `device-specs/devices/hue-bridge.yaml` is the worked example.

#### A role that binds a command *and* an argument

A role's value is normally the command's name. It may instead be an object
that names the command and fixes some of its parameters, for a device whose
verbs are one opcode and a selector byte. FTMS stops and pauses with the same
control-point write, op `0x08`, told apart only by its `control` parameter:

```yaml
entities:
  - platform: "button"
    name: "Stop"
    key: "stop"
    commands:
      press: { command: "stop_or_pause", values: { control: 1 } }
  - platform: "button"
    name: "Pause"
    key: "pause"
    commands:
      press: { command: "stop_or_pause", values: { control: 2 } }
```

`values` keys must be parameters the named command declares (the convention
test checks), and the literal is in the parameter's own type and wire scale —
it substitutes exactly as a caller-supplied value would. Any parameter the
binding does not fix is filled the way it always is: the control's own value,
a `default`, or a `source` read-back. Before this form existed the two bytes
lived in a consumer's widget, or a spec declared a constant-value twin of the
parameterized command for each selector value (`stop_belt_ftms`,
`pause_belt_ftms`); both still validate, and the object form is the shape to
reach for next time. `ftms-fitness-machine-service.yaml` is the worked example.

#### `bands` — the vendor's own verdict thresholds

A reading a device *judges* — an air-quality monitor's ring, a radon
detector's green/yellow/red — can carry the thresholds the vendor ships, so a
consumer draws the verdict the device's own app would, rather than applying
one vendor's numbers to every device with a matching unit:

```yaml
entities:
  - platform: "sensor"
    name: "Radon 24h Average"
    unit: "Bq/m³"
    bands:
      - { level: "good", below: 100 }
      - { level: "fair", above: 100, below: 150 }
      - { level: "poor", above: 150 }
  - platform: "sensor"
    name: "Humidity"
    unit: "%"
    bands:                                     # two-sided: good in the middle
      - { level: "poor", below: 25 }
      - { level: "fair", above: 25, below: 30 }
      - { level: "good", above: 30, below: 60 }
      - { level: "fair", above: 60, below: 70 }
      - { level: "poor", above: 70 }
```

Bounds are in the entity's `unit`; `above` is inclusive, `below` exclusive, so
adjacent bands partition cleanly. Three levels only — `good`, `fair`, `poor` —
because that is what every vendor UI draws. A reading matching no band has no
verdict. These are the vendor's numbers, not this project's: say in `notes`
where they came from, and where the device reports its own thresholds (the
Airthings family does, over a UI-settings command) a consumer that can read
them live should prefer them. `airthings-wave-family.yaml` is the worked
example.

### `features` — an upload is a control surface too

A printer or a pixel display has, most of the time, no switch and no sensor
to bind: its whole surface is "take this bitmap". `features` is where that is
declared, and the keys on an `image_upload` entry are the facts an editor and
an uploader need without reading the notes:

```yaml
features:
  - type: "image_upload"
    format: "1bit-bitmap"
    max_width: 96
    max_height: 65535
    max_palette_colors: 2          # absent = no constraint
    print_density:                 # a code set, same shape as a parameter
      allowed: [0, 1, 2]
      labels: ["light", "medium", "thick"]
      default: 1
      command: "set_density"       # which declared command carries the byte
    paper_type: { allowed: [0, 1, 2], labels: [...], default: 0, command: "set_paper_type" }
    print_geometry: { dpi: 300, bytes_per_row: 162, head_dots: 1296, ... }
    media:                         # the roll table a mm*dpi guess approximates
      - { name: "62mm continuous (DK-2205)", kind: "continuous", width_mm: 62,
          print_width_dots: 696, right_margin_dots: 12, media_type_code: 10 }
  - type: "raster_print"           # the upload IS the device
```

- **`max_palette_colors`** is the ceiling of the device's *format*, not of the
  editor: 2 for a 1-bit head, 16 for a codec that packs a palette index into
  a nibble, absent for a device that decodes PNG/GIF itself. Stated because
  the mobile editor quantized thirteen devices to one codec's sixteen.
- **`max_payload_bytes`** bounds the whole transfer (the LED badge's 8192-byte
  flash); `framing.max_chunk_size` on the characteristic bounds one write.
- **`print_density` / `paper_type`** are code sets in the `allowed`/`labels`
  shape a command parameter uses, plus `command` so a picker knows what to
  send through.
- **`print_geometry`** and **`media[]`** hold a raster printer's head numbers
  and roll table in the units a job builder needs — dots, at
  `print_geometry.dpi`. Every key is described in `schema.json`.
- **`raster_print`** is a marker declared *beside* `image_upload`, never
  instead of it: it says the device's control surface is the byte stream and
  resolves no entities, so a consumer keeps the printer rather than dropping
  it as empty. The five raster printers in the catalogue declare both.

Three smaller keys belong to the same wave. A characteristic may carry
**`role: command | bulk | stream | notify`** so a consumer picks the upload
channel by contract rather than by the word "WRITE2" in its `name`; a
`framing.scheme` of **`length_prefixed_le16`** is a two-byte little-endian
length then the packet, split into `max_chunk_size` writes (Rabbit Air); and
a parameter's **`auto: crc8`** is CRC-8 poly 0x07 / init 0x00 over the
`checksum_start` span (the cat printers, over the payload only, so
`checksum_start: 6`).

#### `firmware_update` and its `dfu` block

A device that takes new firmware declares a `firmware_update` feature with a
`dfu` block. The schema requires the block, so the facts cannot live only
in prose:

```yaml
features:
  - type: "firmware_update"
    dfu:
      mechanisms: ["nordic_secure_dfu"]       # stack(s); closed enum
      transport: "ble"
      image: { signing: "signed", algorithm: "ecdsa_p256", source: "bundled_in_app" }
      enter: { how: "command", command: "enter_dfu" }   # must be `advanced`
      dfu_mode:                               # checked BEFORE identification
        local_names: ["AdMore Light Bar DFU"]
        address_offset: 1
      services: ["0000fe59-0000-1000-8000-00805f9b34fb"]
      recovery: { interrupted: "keeps_old_image", inactivity_timeout_s: 120 }
      verification: "reported"
```

A consumer matches `dfu_mode` before ordinary identification and shows a hit
as "this product, mid-update", with no controls. `services` are listed
read-only by a GATT explorer and never identify the product on their own.
`image.signing` tells a user whether a replacement client could build an
image or only deliver the vendor's. What each stack does by default (UUIDs,
the `DfuTarg` name, the +1 address, timeouts) is in
[Firmware Update](../protocols/firmware-update.md) and
`registries/dfu-signatures.tsv`. A spec records only what its device
changes.

When the stack depends on the board, declare one `firmware_update` entry per
group and scope each with `variants`: names from `device.variants[].model`,
as on an entity. hello-fairy's ST17H66, ESP32 and Bluetrum boards each get
their own entry. No variant may be covered by two entries of the same
`type`.

### One spec, several models

A spec usually covers a family, not a single unit, and the family is rarely
uniform. Two keys keep that from turning into controls that never work, and
both are machine-readable on purpose — a caveat in `notes` is read by people,
and the client drawing the dead tile is not a person.

**`device.variants` + `entities[].variants`** — when a model *lacks the
hardware*. The Kasa plugs all speak the same port-9999 protocol, but only the
HS110 and KP115 have an energy meter; on an HS100 `get_emeter` answers with an
error, so four unscoped sensors are four tiles that are permanently
unavailable. The device block lists the models with something a client can
match on, and the entity names the ones that have it:

```yaml
device:
  variants:
    - model: "HS100"
      identification: { model_prefix: "HS100" }   # get_sysinfo `model` is "HS100(US)"
    - model: "HS110"
      identification: { model_prefix: "HS110" }
entities:
  - platform: "sensor"
    name: "Power"
    variants: ["HS110", "KP115"]                  # drop me on the others
```

`model_prefix` is matched as a prefix because vendors suffix region and
hardware-revision codes onto an otherwise stable model name. Where the device
reports its own capabilities, prefer that at runtime — Kasa's `get_sysinfo`
answers a `feature` list, and `"ENE"` in it means *this unit* has the meter, a
statement that stays true when a new model ships and a hand-written table does
not.

**`state_mapping.<role>_fallback`** — when a revision *renames* a field.
HS110 hardware v1 reports the same four readings as `voltage_mv`,
`current_ma`, `power_mw`, `total_wh`, in milli-units. Telling a consumer in
prose to "divide by 1000" does not help: the key the primary path names is
simply absent from that reply, so a dotted-path reader renders nothing.

```yaml
    state_mapping:
      value: "emeter.get_realtime.voltage"
      value_fallback:
        path: "emeter.get_realtime.voltage_mv"    # hw v1 spelling
        scale: 0.001                              # → the entity's `unit`
```

Read the primary first; fall back only when that key is absent. Note this is
*not* a variant split: two entities, one per spelling, would make a consumer
that ignores `variants` draw the tile twice, whereas a consumer that ignores
`value_fallback` keeps working on current firmware and loses only the old
hardware. Both paths must name fields the bound command declares in `returns`,
so the legacy field family belongs in the spec too, not only in a sentence.

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

CI runs this on every push and re-validates every published spec before building
the docs. `device-specs/index.json` is rebuilt and committed by CI on main —
never carry it in a branch.

## Writing one

See [How to Contribute](../contributing/index.md) and the
[Documentation Guide](../contributing/documentation-guide.md). `schema.json` is
the source of truth for field names and enums; `device-specs/README.md` is the
in-repo reference.

The rule of thumb for a `setup` block: write it for someone who has your
hardware and none of your context. If they would have to guess, add the field.
