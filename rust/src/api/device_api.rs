// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
//! Public API exposed to Flutter via flutter_rust_bridge.
//! This module defines the FFI boundary — keep types simple and serializable.

use std::collections::HashMap;

use flutter_rust_bridge::frb;

use crate::codec::types::DecodedValue;
use crate::protocol::dispatch::select_protocol;
use crate::protocol::profiles;
use crate::protocol::traits::DeviceProtocol;
use crate::spec::bindings;
use crate::spec::parser::parse_device_spec;
use crate::spec::types::{
    Characteristic, CharacteristicProperty, Command, DeviceSpec, Entity, FormatField,
    Identification, MacPrefix, MacPrefixConfidence, Parameter, Service,
};

// ── DTO types for the FFI boundary ──────────────────────────────────────────
// These are simpler, FRB-friendly versions of the internal types.

/// A parsed device specification, ready for use by the Flutter app.
#[derive(Debug, Clone)]
pub struct DeviceSpecDto {
    pub device_name: String,
    pub manufacturer: String,
    pub manufacturer_status: String,
    pub protocol: String,
    /// Broad device class from the spec schema's closed vocabulary (`light`,
    /// `display`, `sensor`, `motor`, `switch`, `tv`, …), which the app maps to
    /// the icon it draws for the device. Carried across as the raw string so a
    /// category added upstream after this build still reaches Dart, which
    /// decides what to do with a value it does not recognise.
    pub category: Option<String>,
    pub notes: Option<String>,
    /// Every BLE local name prefix this device family advertises under, in
    /// spec order. Plural because a family sold as several rebadged models has
    /// several -- the Inkbird thermometer ships under eight names with no
    /// shared prefix. Empty when the spec declares none.
    pub local_name_prefixes: Vec<String>,
    pub service_uuids: Vec<String>,
    /// Bluetooth SIG company IDs this device family advertises in its
    /// manufacturer-specific data, primary first. Empty when the spec declares
    /// none.
    pub company_ids: Vec<u16>,
    /// IEEE OUI prefixes seen on this device's MAC address, e.g. `C4:7C:8D`.
    /// Empty when the spec declares none. See [`MatchConfidence`] for why these
    /// only ever rank a device rather than identify one, and
    /// [`MacPrefixConfidence`] for how much any one of them is worth.
    pub mac_prefixes: Vec<MacPrefixDto>,
    /// mDNS/DNS-SD service type this device announces itself under, e.g.
    /// `_hue._tcp`. The network counterpart of a vendor service UUID.
    pub mdns_service_type: Option<String>,
    /// SSDP/UPnP search targets this device answers to.
    pub ssdp_search_targets: Vec<String>,
    /// Vendor LAN protocols this device is identified by answering (Kasa's
    /// `tplink-smarthome`). A strong network identifier for hardware with no
    /// mDNS/SSDP presence.
    pub lan_protocols: Vec<String>,
    /// Default TCP port for the device's local API.
    pub default_port: Option<u16>,
    pub services: Vec<ServiceDto>,
    /// Declared sensor/control surfaces that resolve to a real characteristic,
    /// in spec order. This is what lets the app render named readings with
    /// units instead of a raw GATT browser.
    pub entities: Vec<EntityDto>,
    /// The spec's `image_upload` feature, when it declares one — pixel
    /// displays (LED matrices, curtain lights, badges, printers) that accept
    /// a raster image and possibly animations. Drives the app's generic LED
    /// image widget; `None` for devices without a pixel surface.
    pub image_upload: Option<ImageUploadDto>,
    /// The spec's `stored_upload` feature, when it declares one — device-side
    /// storage of a picture that plays standalone after disconnect. Drives the
    /// LED editor's "Save to device" action; `None` for devices that only take
    /// live frames.
    pub stored_upload: Option<StoredUploadDto>,
}

/// A spec's declared image/animation capability, plus whether this crate can
/// actually encode uploads for it.
///
/// The split matters: the capability is *declarative* (any spec may carry
/// it), while encoding needs a named `protocol_handler` implemented in
/// `crate::protocol`. The UI renders the full editor when [`Self::encodable`]
/// and an honest "not wired up yet" state otherwise, so new specs light up by
/// data alone once their handler lands.
#[derive(Debug, Clone)]
pub struct ImageUploadDto {
    /// The spec's `protocol_handler` name, e.g. `daniao_ddp`.
    pub handler: Option<String>,
    /// True when [`Self::handler`] names a handler this crate implements —
    /// i.e. `encode_image_frame` will succeed rather than error.
    pub encodable: bool,
    /// Wire pixel format the device expects (e.g. `rgb888`, `gif`).
    pub format: Option<String>,
    pub max_width: Option<u32>,
    pub max_height: Option<u32>,
    /// True when max_width/max_height are platform bounds and the panel's
    /// real resolution is reported by the device at runtime (so the editor
    /// should let the user set the canvas size).
    pub resolution_device_reported: bool,
    /// Whether multi-frame sequences (animations) are supported.
    pub animation: bool,
    pub max_frames: Option<u32>,
    /// Fastest supported frame flip in milliseconds, when the spec knows it.
    pub min_frame_interval_ms: Option<u32>,
    pub default_frame_interval_ms: Option<u32>,
}

/// A spec's declared device-side STORAGE capability: whether this device can
/// persist content that plays standalone after disconnect, and whether this
/// build can encode the container it wants.
///
/// The split mirrors [`ImageUploadDto`]: storing is *declarative* (a spec says
/// it can), while encoding needs a `container_format` this crate implements.
/// The UI offers "Save to device" only when [`Self::encodable`].
#[derive(Debug, Clone)]
pub struct StoredUploadDto {
    /// The spec's `container_format` name, e.g. `daniao_amx`.
    pub container_format: Option<String>,
    /// True when [`Self::container_format`] names a container encoder this crate
    /// implements — i.e. `encode_stored_image` will succeed rather than error.
    pub encodable: bool,
}

/// One BLE write of an image frame: the bytes and the characteristic they go
/// to. Per-write targets because the doodle flow spans channels (session-open
/// on the command characteristic, pixels on the bulk one).
#[derive(Debug, Clone)]
pub struct ImageWriteDto {
    pub characteristic_uuid: String,
    pub bytes: Vec<u8>,
}

/// The BLE writes that persist one image on the device, in send order, plus the
/// optional command that plays it immediately after.
#[derive(Debug, Clone)]
pub struct StoredUploadPlanDto {
    /// The GATT service every write's characteristic belongs to.
    pub service_uuid: String,
    /// Writes to the Uploader characteristic: a START packet then DATA packets.
    /// The caller sends them back-to-back to the one characteristic.
    pub upload_writes: Vec<ImageWriteDto>,
    /// The play-by-id command, fragment-framed and ready to write, when the
    /// spec declares a `play_command`. Sent once the upload completes so the
    /// stored item shows immediately (it also persists without this).
    pub play_write: Option<ImageWriteDto>,
    /// Where the device answers the upload, when the spec names it. Subscribe
    /// here before the first upload write and hold `play_write` until
    /// [`decode_stored_upload_event`] reports completion — the device plays a
    /// cid only once it has committed it, so an early play is a silent no-op.
    pub response_characteristic_uuid: Option<String>,
    /// The id the stored item now lives under; the device can be told to play
    /// it again by this later.
    pub cid: u32,
}

/// What one notification on the stored-upload response characteristic said.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StoredUploadEventKind {
    /// The device accepts the transfer; `resume_offset` says where to start.
    StartAccepted,
    /// The device refuses the transfer (`code` is its error).
    StartRejected,
    /// Transfer progress (`progress` is the device's counter).
    Progress,
    /// The item is committed and playable — safe to send the play write now.
    Complete,
    /// The transfer failed device-side (`code` is its error).
    Failed,
}

/// A decoded stored-upload response. Fields not named by [`kind`] are 0.
#[derive(Debug, Clone)]
pub struct StoredUploadEventDto {
    pub kind: StoredUploadEventKind,
    /// Device error code, for `StartRejected` / `Failed`.
    pub code: u64,
    /// Byte offset to resume from, for `StartAccepted` (0 = fresh).
    pub resume_offset: u64,
    /// The device's progress counter, for `Progress`.
    pub progress: u64,
}

/// The single play-by-cid write for RE-triggering an already stored item.
#[derive(Debug, Clone)]
pub struct StoredPlayDto {
    /// The GATT service the write's characteristic belongs to.
    pub service_uuid: String,
    /// The framed play command, ready to write.
    pub write: ImageWriteDto,
}

/// The framed writes that set a looping playlist of stored effects — the
/// set-playlist command then loop mode. Written in order to the command
/// characteristic; this is how a multi-frame animation plays (each frame a
/// stored microapp, looped).
#[derive(Debug, Clone)]
pub struct PlaylistWritesDto {
    pub service_uuid: String,
    pub writes: Vec<ImageWriteDto>,
}

/// One entry of the device's stored-effect list: a stored item's id, its
/// device-assigned slot, the `type` the firmware filed it under, and whether it
/// is a user "DIY" effect. `type`/`diy` are diagnostic: they reveal which
/// family the device accepted an upload as (e.g. a `.eff` we sent as `type = 0`
/// versus the `type = 3` AMX microapps the captures show playing).
#[derive(Debug, Clone)]
pub struct EffectEntryDto {
    pub cid: u32,
    pub slot: u32,
    pub type_: u32,
    pub diy: u32,
}

/// The BLE writes that push one image frame to a device, in send order.
#[derive(Debug, Clone)]
pub struct ImageWritePlanDto {
    /// The GATT service every write's characteristic belongs to.
    pub service_uuid: String,
    /// Ordered writes. The caller sends them back-to-back, each to its own
    /// characteristic; ordering is part of the protocol (fragment reassembly).
    pub writes: Vec<ImageWriteDto>,
    /// The frame index to pass for the NEXT frame. A frame spanning P wire
    /// packets consumes P sequence numbers, so advancing by 1 would make the
    /// next frame's serials collide with this one's and corrupt fragment
    /// reassembly on the device — always continue from this value.
    pub next_frame_index: u32,
}

/// A spec-declared sensor or control surface: what to call it, which
/// characteristic carries its state, and which commands drive it.
#[derive(Debug, Clone)]
pub struct EntityDto {
    pub name: String,
    /// e.g. "sensor". Absent in some hand-written specs.
    pub platform: Option<String>,
    /// e.g. "temperature", "battery". Drives icon/formatting choices.
    pub device_class: Option<String>,
    /// Material Design Icons name the spec asks for (`mdi:heat-wave`), when
    /// `device_class` does not already imply the right picture. Advisory: a
    /// UI that cannot draw the named icon falls back to what it derives from
    /// `device_class`, so nothing depends on it resolving.
    pub icon: Option<String>,
    /// Display rounding as the smallest increment worth showing (`0.1` = one
    /// decimal). `None` means the number's own transform decides, which is
    /// the right answer whenever the device's resolution and its encoding
    /// agree.
    pub precision: Option<f64>,
    /// e.g. "F", "%". Rendered next to the value.
    pub unit: Option<String>,
    /// UUID of the characteristic carrying this value. When present it is
    /// guaranteed to resolve to a characteristic in this spec. `None` for
    /// command-only entities (govee's plug declares on/off commands and no
    /// state at all) — an entity crosses the FFI when *either* its state
    /// resolves or at least one action does; with neither it is dropped.
    pub state_characteristic: Option<String>,
    /// Whether the bound characteristic supports notifications, i.e. whether
    /// this reading can stream rather than being polled by read.
    pub can_notify: bool,
    /// Whether the bound characteristic declares a `format:` block. False means
    /// the value cannot be decoded yet — a spec gap, not an app failure.
    pub has_format: bool,
    /// Name of the decoded field carrying this entity's value, when the spec
    /// declares one. `None` means "use the first decoded field".
    pub value_field: Option<String>,
    /// Multiplier for the decoded value, e.g. 0.01 when a device reports
    /// centidegrees. `None` means the decoded value is already in `unit`.
    pub value_scale: Option<f64>,
    /// The decoded value that means "on" for a switch/binary_sensor, from
    /// `state_mapping.on_value` (ember's charging base reads 1 when docked).
    pub on_value: Option<i64>,
    /// True when `state_mapping.on_when: nonzero` — any nonzero reading is
    /// "on".
    pub on_when_nonzero: bool,
    /// Decoded field carrying a light's power state (`state_mapping.is_on`).
    pub is_on_field: Option<String>,
    /// Decoded field carrying a light's brightness
    /// (`state_mapping.brightness`).
    pub brightness_field: Option<String>,
    /// Decoded fields carrying a light's color channels
    /// (`state_mapping.color_rgb`). Either all three are present or none.
    pub color_red_field: Option<String>,
    pub color_green_field: Option<String>,
    pub color_blue_field: Option<String>,
    /// Sendable control actions resolved from the spec (`turn_on`,
    /// `set_brightness`, ...), in role order. Empty for sensors. Every entry
    /// is ready to send: encode the named command with the listed user
    /// parameters and the spec's declared defaults fill the rest.
    pub actions: Vec<EntityActionDto>,
    /// Bounds and granularity of a `number`/`climate` setpoint control, in
    /// DECODED units (what the user sees and picks), not raw bytes. Taken
    /// from the entity's own `min`/`max`/`step` — or the `climate` spelling
    /// `min_temp`/`max_temp`/`temp_step` — falling back to what the bound
    /// parameter or field can physically hold.
    pub setpoint_min: Option<f64>,
    pub setpoint_max: Option<f64>,
    pub setpoint_step: Option<f64>,
}

/// One resolved control action: which command a role sends and what the UI
/// supplies.
#[derive(Debug, Clone)]
pub struct EntityActionDto {
    /// `turn_on` | `turn_off` | `press` | `set_brightness` | `set_color` |
    /// `set_value`.
    pub role: String,
    /// GATT service/characteristic the encoded command is written to.
    pub service_uuid: String,
    pub characteristic_uuid: String,
    /// The command this action sends. `None` for a `set_value` action that
    /// writes the encoded value directly to the characteristic — send those
    /// through [`encode_entity_value`], which handles both shapes.
    pub command_name: Option<String>,
    /// Template parameters the UI owns for this role (e.g. `brightness`;
    /// `red`/`green`/`blue`). Extra card state sent alongside is harmless —
    /// the encoder only reads what the template references.
    pub user_params: Vec<String>,
    /// Declared bounds of the role's primary numeric parameter, so a
    /// brightness slider matches the device's real range (elk-bledom tops out
    /// at 100, not 255). `f64` for the same reason as [`ParameterDto`]'s
    /// bounds: sliders consume doubles.
    pub min: Option<f64>,
    pub max: Option<f64>,
}

#[derive(Debug, Clone)]
pub struct ServiceDto {
    pub uuid: String,
    pub name: String,
    pub characteristics: Vec<CharacteristicDto>,
}

#[derive(Debug, Clone)]
pub struct CharacteristicDto {
    pub uuid: String,
    pub name: String,
    pub can_read: bool,
    pub can_write: bool,
    pub can_notify: bool,
    /// Commands in the order the spec declares them. Meaningful — do not sort.
    pub commands: Vec<CommandDto>,
    /// Format fields in the order the spec declares them, which is also how the
    /// device packs the value. Meaningful — consumers must not sort this; the
    /// UI lists decoded values in exactly this order.
    pub format_fields: Vec<FormatFieldDto>,
}

#[derive(Debug, Clone)]
pub struct CommandDto {
    pub name: String,
    pub description: String,
    /// Parameters in the order the spec declares them. Meaningful — do not sort.
    pub parameters: Vec<ParameterDto>,
    /// true if this is a fixed-value command (no parameters needed).
    pub is_fixed: bool,
    /// true when this command can be encoded to bytes.
    pub is_encodable: bool,
    /// Human-readable encoding name when is_encodable is false.
    pub unsupported_encoding: Option<String>,
    /// `sound` | `flash` | `both` when the spec declares this command a
    /// locator — its whole effect is to make the device noticeable. `None`
    /// for every other command, including one whose *name* sounds like a
    /// locator.
    pub locate: Option<String>,
    /// The spec flags this opcode as able to damage hardware or carry other
    /// consequences (a treadmill's calibration, a factory reset). A signpost
    /// for a UI confirmation, NOT a gate: the command still encodes, the app
    /// decides how to ask.
    pub advanced: bool,
    /// The text to show at the opt-in point when `advanced` is set. Free text
    /// from the spec, because the right warning is device-specific.
    pub advanced_reason: Option<String>,
}

#[derive(Debug, Clone)]
pub struct ParameterDto {
    pub name: String,
    pub value_type: String,
    pub min: Option<f64>,
    pub max: Option<f64>,
    /// Enumerated set of allowed values. When present (and non-empty) the
    /// device accepts only these values, so the UI should offer a choice
    /// among them instead of a free min..max range.
    pub allowed: Option<Vec<i64>>,
    /// Human-readable labels for `allowed`, paired 1:1 by index (the upstream
    /// spec-format contract). Only present when `allowed` is present and the
    /// lengths match exactly — a mismatched spec keeps its `allowed` values
    /// but has its labels dropped rather than mispaired (see the `From`
    /// conversion below).
    pub labels: Option<Vec<String>>,
    /// Multiplier of the parameter's linear transform, when the spec declares
    /// one. A treadmill's `speed` is wire-units with `scale: 0.1` and
    /// `unit: km/h`: the UI works in km/h and the encoder inverts the
    /// transform. Same semantics as [`DecodedValueDto::scale`].
    pub scale: Option<f64>,
    /// Additive term completing the parameter's transform,
    /// `value = raw * scale + value_offset`. Same semantics as
    /// [`DecodedValueDto::value_offset`].
    pub value_offset: Option<f64>,
    /// Unit symbol the parameter's value is expressed in after the transform
    /// (`km/h`, `%`, ...), so the UI can label a slider without hardcoding
    /// per-device knowledge.
    pub unit: Option<String>,
    /// Value the encoder substitutes when the caller supplies nothing — the
    /// reason a speed slider does not need to know the protocol's `flag`
    /// byte. Surfaced so the UI can pre-fill or omit the control entirely.
    pub default: Option<i64>,
    /// Transport role the encoder fills rather than the caller
    /// (`packet_length` | `sequence` | `checksum`), rendered as the spec's
    /// snake_case wire string. When set, the UI must NOT offer a control for
    /// this parameter — a "checksum" slider is nonsense, and that exact bug
    /// is why this field exists. `None` for ordinary caller-owned parameters.
    pub auto: Option<String>,
}

#[derive(Debug, Clone)]
pub struct FormatFieldDto {
    pub name: String,
    pub field_type: String,
    pub offset: u32,
    pub length: u32,
}

/// A decoded value from a characteristic read.
#[derive(Debug, Clone)]
pub struct DecodedValueDto {
    pub name: String,
    pub value_type: String,
    pub display: String,
    pub bool_value: Option<bool>,
    pub int_value: Option<i64>,
    pub uint_value: Option<i64>, // FRB doesn't support u64, use i64
    pub string_value: Option<String>,
    /// Multiplier from the spec's `format:` block, when it declares one. The
    /// decoded value stays raw so the caller keeps both halves; applying this
    /// is what turns a SIG temperature's 2350 into 23.5.
    pub scale: Option<f64>,
    /// Additive term completing the spec's linear transform,
    /// `value = raw * scale + value_offset`. Gerbing's thermometer is
    /// `raw * 0.5 + 85` °F, and dropping the offset makes every reading wrong
    /// by 85 degrees.
    pub value_offset: Option<f64>,
    /// Unit symbol from the spec's `format:` block, used when the entity
    /// surfacing this reading does not name one.
    pub unit: Option<String>,
    /// Human name for this value when the field declares a `values:` code
    /// table, already resolved for the value decoded — Ember's liquid state
    /// 5 arrives as "heating".
    pub value_label: Option<String>,
    /// The spec's `unit_source` (`fixed` | `device_setting`). The Inkbird
    /// iBBQ sends whichever unit the device is currently set to, so a UI must
    /// not present [`Self::unit`] as fact when this reads `device_setting`.
    pub unit_source: Option<String>,
}

/// One match returned by [`match_device_to_spec`]. Callers pick whichever
/// match suits them — sort by `matched_service_uuids.len()`, prefer name-prefix
/// matches, etc.
#[derive(Debug, Clone)]
pub struct MatchResult {
    pub spec: DeviceSpecDto,
    pub matched_by_name_prefix: bool,
    /// The advertised service UUIDs (lowercased) that intersect with the
    /// spec's identification. Empty when no UUIDs matched.
    pub matched_service_uuids: Vec<String>,
    /// How much this match is worth. See [`MatchConfidence`].
    pub confidence: MatchConfidence,
}

/// How much weight a match carries.
///
/// The four things a scanner can see about a BLE device before it connects are
/// not equally telling, and collapsing them into one boolean is what makes a
/// device list either miss real devices or confidently mislabel them. Ordered
/// weakest to strongest so callers can compare and sort directly.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum MatchConfidence {
    /// Only the MAC OUI matched. An OUI is assigned to a vendor, not a product
    /// — `C4:7C:8D` is every Xiaomi radio ever built, not just the plant
    /// monitor — so this is a hint worth ranking on and nothing more. Never
    /// bind a spec's characteristics to a device on this alone.
    Possible,
    /// The local name prefix matched, or a manufacturer-data company ID did.
    /// Both are good evidence and neither is proof: users rename devices, and
    /// vendors routinely squat on company IDs they were never assigned.
    Likely,
    /// An advertised service UUID matched, or two or more of the weaker signals
    /// agreed. A vendor-allocated 128-bit UUID in an advertisement is about as
    /// close to proof as pre-connect scanning gets.
    Strong,
}

/// One MAC prefix a spec declares, and how much of the block is really this
/// device's.
///
/// Two prefixes of the same length are not worth the same thing. `C4:7C:8D` is
/// an IEEE Registration Authority block that fifteen unrelated companies hold
/// 28-bit slices of, while `00:17:88` is Philips Lighting's own. Both are three
/// octets; only one of them tells you anything. Carrying the spec author's
/// verdict alongside the prefix is what lets the matcher rank them differently
/// instead of treating every OUI as equally weak — or, worse, equally strong.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MacPrefixDto {
    /// The prefix as the spec wrote it, e.g. `C4:7C:8D`.
    pub prefix: String,
    pub confidence: MacPrefixConfidence,
}

impl From<&MacPrefix> for MacPrefixDto {
    fn from(prefix: &MacPrefix) -> Self {
        Self {
            prefix: prefix.prefix().to_string(),
            confidence: prefix.confidence(),
        }
    }
}

/// What a scanner saw about one device, before connecting to it.
#[derive(Debug, Clone)]
pub struct ScannedDeviceDto {
    /// Advertised local name. Empty when the device advertises none.
    pub name: String,
    /// Service UUIDs carried in the advertisement — NOT the GATT services
    /// discovered after connecting, which is a much richer list.
    pub service_uuids: Vec<String>,
    /// Company IDs from the manufacturer-specific data (AD type 0xFF). A
    /// device may advertise several records.
    pub company_ids: Vec<u16>,
    /// The hardware address, when the platform reports one.
    ///
    /// `None` on Apple platforms: CoreBluetooth substitutes a per-host UUID for
    /// the address, so there is no OUI to read. Also useless — though not
    /// absent — for a peripheral in BLE privacy mode, which advertises a
    /// rotating random address that matches no OUI.
    pub mac_address: Option<String>,
}

/// What a scanner saw about one device on the local network.
///
/// The Wi-Fi counterpart of [`ScannedDeviceDto`]. Separate because the signals
/// genuinely differ: there is no RSSI, no manufacturer data, and the address is
/// a DHCP lease rather than a hardware identity.
#[derive(Debug, Clone)]
pub struct NetworkDeviceDto {
    /// Service instance name (mDNS) or friendly name (SSDP). Empty when the
    /// device advertised none.
    pub name: String,
    /// Hostname the device claims, e.g. `Lutron-083e013d.local`.
    pub hostname: Option<String>,
    /// mDNS/DNS-SD service types it advertises.
    pub service_types: Vec<String>,
    /// SSDP search targets it answered to.
    pub ssdp_targets: Vec<String>,
    /// Vendor LAN protocols this device *answered* during discovery — Kasa's
    /// `tplink-smarthome`, set when a get_sysinfo probe got a reply. Matched
    /// against a spec's `lan_protocols`; the strong identifier for hardware
    /// that advertises no mDNS/SSDP.
    pub answered_lan_protocols: Vec<String>,
    /// Port the advertised service listens on.
    pub port: Option<u16>,
}

/// The identifying fields of a spec, without the services, characteristics and
/// entities that make a [`DeviceSpecDto`] large.
///
/// Exists so the scan path can ask about the whole catalogue on every newly
/// seen device without pushing the full catalogue across the FFI boundary each
/// time. Dart builds these once from its parsed specs and reuses them.
#[derive(Debug, Clone)]
pub struct SpecIdentityDto {
    pub device_name: String,
    pub manufacturer: String,
    /// Broad device class, carried so a caller can say what kind of thing a
    /// scan result is without fetching the whole spec back. Alongside
    /// `manufacturer` rather than behind `spec_index` because it is answering
    /// the same question that field does — who/what is this — and a caller
    /// that has to index back into its own list to draw an icon will sooner or
    /// later index into a stale one.
    pub category: Option<String>,
    pub local_name_prefixes: Vec<String>,
    pub service_uuids: Vec<String>,
    pub company_ids: Vec<u16>,
    pub mac_prefixes: Vec<MacPrefixDto>,
    /// mDNS service type, for the Wi-Fi scan path. Absent on a BLE-only spec.
    pub mdns_service_type: Option<String>,
    /// SSDP search targets, for the Wi-Fi scan path.
    pub ssdp_search_targets: Vec<String>,
    /// Vendor LAN protocols this device is identified by answering (Kasa). A
    /// strong signal: matched against the protocols a discovered device
    /// actually answered.
    pub lan_protocols: Vec<String>,
    /// Default TCP port. The weakest network signal by far -- port 80 says
    /// nothing -- so it only ever ranks, never identifies.
    pub default_port: Option<u16>,
}

/// One spec that a scanned device might be, and why we think so.
#[derive(Debug, Clone)]
pub struct ScanMatch {
    /// Position of the matched identity in the list that was passed in, so the
    /// caller can recover the full spec it built the identity from.
    pub spec_index: u32,
    pub device_name: String,
    pub manufacturer: String,
    /// The matched spec's device class, copied through from
    /// [`SpecIdentityDto::category`]. `None` when the spec states none.
    pub category: Option<String>,
    pub confidence: MatchConfidence,
    pub matched_by_name_prefix: bool,
    /// Matched advertised service UUIDs, lowercased.
    pub matched_service_uuids: Vec<String>,
    pub matched_company_ids: Vec<u16>,
    /// The spec MAC prefix that the device's address starts with, as the spec
    /// wrote it, with the spec's verdict on how much that block is worth.
    /// `None` when the address did not match (or was not available).
    pub matched_mac_prefix: Option<MacPrefixDto>,
    /// mDNS service types and SSDP search targets that matched, on the Wi-Fi
    /// path. Always empty for a BLE match.
    pub matched_service_types: Vec<String>,
}

// ── Conversions from internal types ─────────────────────────────────────────
// All conversions go through `From` for symmetry. The tuple impls
// (`From<(&str, ...)>`) carry a HashMap key into the DTO.

/// Build the image-upload DTO from a spec's `features` + `protocol_handler`.
///
/// Only the first `image_upload` feature is used — the schema models one
/// pixel surface per device. `encodable` is the registry check: it is what
/// keeps the app generic, asking "can this spec's uploads be encoded" instead
/// of matching device names.
fn image_upload_dto(spec: &DeviceSpec) -> Option<ImageUploadDto> {
    let feature = spec
        .features
        .iter()
        .find(|f| f.feature_type == "image_upload")?;
    let handler = spec.protocol_handler.clone();
    // Same registry encode_image_frame dispatches on, so a handler can never
    // be advertised as encodable without an encoder (or vice versa).
    let encodable = handler
        .as_deref()
        .is_some_and(|name| crate::protocol::image_upload_handler(name).is_some());
    Some(ImageUploadDto {
        handler,
        encodable,
        format: feature.format.clone(),
        max_width: feature.max_width,
        max_height: feature.max_height,
        resolution_device_reported: feature.resolution_source.as_deref() == Some("device_reported"),
        animation: feature.animation.unwrap_or(false),
        max_frames: feature.max_frames,
        min_frame_interval_ms: feature.min_frame_interval_ms,
        default_frame_interval_ms: feature.default_frame_interval_ms,
    })
}

/// Build the stored-upload DTO from a spec's `stored_upload` feature.
///
/// `encodable` is the same registry check `encode_stored_image` dispatches on,
/// so a container format can never be advertised as storable without an encoder
/// behind it.
fn stored_upload_dto(spec: &DeviceSpec) -> Option<StoredUploadDto> {
    let feature = crate::protocol::stored_upload::stored_feature(spec)?;
    let container_format = feature.container_format.clone();
    let encodable = container_format
        .as_deref()
        .is_some_and(crate::protocol::stored_container_encodable);
    Some(StoredUploadDto {
        container_format,
        encodable,
    })
}

impl From<&DeviceSpecDto> for SpecIdentityDto {
    fn from(spec: &DeviceSpecDto) -> Self {
        Self {
            device_name: spec.device_name.clone(),
            manufacturer: spec.manufacturer.clone(),
            category: spec.category.clone(),
            local_name_prefixes: spec.local_name_prefixes.clone(),
            service_uuids: spec.service_uuids.clone(),
            company_ids: spec.company_ids.clone(),
            mac_prefixes: spec.mac_prefixes.clone(),
            mdns_service_type: spec.mdns_service_type.clone(),
            ssdp_search_targets: spec.ssdp_search_targets.clone(),
            lan_protocols: spec.lan_protocols.clone(),
            default_port: spec.default_port,
        }
    }
}

impl From<&DeviceSpec> for DeviceSpecDto {
    fn from(spec: &DeviceSpec) -> Self {
        let ident = spec.device.identification.as_ref();
        Self {
            image_upload: image_upload_dto(spec),
            stored_upload: stored_upload_dto(spec),
            device_name: spec.device.name.clone(),
            manufacturer: spec.device.manufacturer.clone(),
            manufacturer_status: spec.device.manufacturer_status.to_string(),
            protocol: spec.device.protocol.to_string(),
            category: spec.device.category.clone(),
            notes: spec.device.notes.clone(),
            local_name_prefixes: ident
                .map(Identification::local_name_prefixes)
                .unwrap_or_default(),
            service_uuids: ident
                .and_then(|i| i.service_uuids.clone())
                .unwrap_or_default(),
            company_ids: ident.map(Identification::company_ids).unwrap_or_default(),
            mac_prefixes: ident
                .and_then(|i| i.mac_prefixes.as_ref())
                .map(|prefixes| prefixes.iter().map(MacPrefixDto::from).collect())
                .unwrap_or_default(),
            mdns_service_type: ident.and_then(|i| i.mdns_service_type.clone()),
            ssdp_search_targets: ident
                .and_then(|i| i.ssdp_search_targets.clone())
                .unwrap_or_default(),
            lan_protocols: ident
                .and_then(|i| i.lan_protocols.clone())
                .unwrap_or_default(),
            default_port: ident.and_then(|i| i.default_port),
            services: spec.services.iter().map(ServiceDto::from).collect(),
            // Only entities with something real behind them cross the FFI
            // boundary: a resolvable state characteristic, at least one
            // sendable action, or both. An entity with neither (its UUID is
            // absent from `services` and no command qualifies) would put a
            // permanently dead tile in the UI, so it is dropped.
            entities: spec
                .entities
                .iter()
                .filter_map(|entity| entity_dto(spec, entity))
                .collect(),
        }
    }
}

/// Build the DTO for one entity, or `None` when neither its state nor any
/// control action resolves against this spec.
fn entity_dto(spec: &DeviceSpec, entity: &Entity) -> Option<EntityDto> {
    // The state binding keeps the historical resolution: prefer a declaration
    // of the UUID that carries a `format:` block, fall back to any
    // declaration (has_format then reports the gap).
    let state = entity
        .state_characteristic
        .as_deref()
        .and_then(|uuid| spec.find_decodable_characteristic(uuid));

    let resolved = bindings::resolve_entity_actions(spec, entity);

    // Setpoint bounds are shown to the user, so they are in decoded units.
    // The entity's own declarations win; otherwise the action's raw bounds
    // (the parameter's, or what the field type can hold) are mapped through
    // the same transform the value itself uses. A negative scale flips which
    // raw bound is the larger decoded one, so the pair is re-ordered rather
    // than assumed.
    // The entity's own declarations always stand — they describe the quantity,
    // not the write, so they are worth carrying even for a read-only setpoint
    // whose command never resolved. Only the fallback needs an action.
    let action_bounds = resolved
        .iter()
        .find(|a| a.role == "set_value")
        .and_then(|action| {
            let transform = bindings::setpoint_transform(spec, entity, action);
            let (min, max) = (action.min?, action.max?);
            let (a, b) = (transform.decode(min as f64), transform.decode(max as f64));
            Some((a.min(b), a.max(b)))
        });
    let setpoint = (
        entity.setpoint_min().or(action_bounds.map(|(lo, _)| lo)),
        entity.setpoint_max().or(action_bounds.map(|(_, hi)| hi)),
        entity.setpoint_step(),
    );

    let actions: Vec<EntityActionDto> = resolved
        .iter()
        .map(|action| EntityActionDto {
            role: action.role.to_string(),
            service_uuid: action.service.uuid.clone(),
            characteristic_uuid: action.characteristic.uuid.clone(),
            command_name: action.command_name.map(str::to_owned),
            user_params: action.user_params.iter().map(|p| p.to_string()).collect(),
            min: action.min.map(|v| v as f64),
            max: action.max.map(|v| v as f64),
        })
        .collect();

    if state.is_none() && actions.is_empty() {
        return None;
    }

    let color_fields = entity.color_rgb_fields();
    Some(EntityDto {
        name: entity.name.clone(),
        platform: entity.platform.clone(),
        device_class: entity.device_class.clone(),
        icon: entity.icon.clone(),
        precision: entity.precision,
        unit: entity.unit.clone(),
        state_characteristic: state
            .is_some()
            .then(|| entity.state_characteristic.clone())
            .flatten(),
        can_notify: state.is_some_and(|(_, characteristic)| {
            characteristic
                .properties
                .contains(&CharacteristicProperty::Notify)
        }),
        // Whether the bound characteristic declares a byte layout. Without
        // one there is nothing to decode the payload with, so the UI shows
        // the entity as awaiting a spec update rather than rendering a raw
        // blob under a friendly name.
        has_format: state.is_some_and(|(_, characteristic)| {
            characteristic
                .format
                .as_ref()
                .is_some_and(|f| !f.is_empty())
        }),
        value_field: entity.value_field().map(str::to_owned),
        value_scale: entity.value_scale(),
        on_value: entity.on_value(),
        on_when_nonzero: entity.on_when_nonzero(),
        is_on_field: entity.is_on_field().map(str::to_owned),
        brightness_field: entity.brightness_field().map(str::to_owned),
        color_red_field: color_fields.as_ref().map(|[r, _, _]| r.clone()),
        color_green_field: color_fields.as_ref().map(|[_, g, _]| g.clone()),
        color_blue_field: color_fields.as_ref().map(|[_, _, b]| b.clone()),
        actions,
        setpoint_min: setpoint.0,
        setpoint_max: setpoint.1,
        setpoint_step: setpoint.2,
    })
}

impl From<&Service> for ServiceDto {
    fn from(service: &Service) -> Self {
        Self {
            uuid: service.uuid.clone(),
            name: service.name.clone(),
            characteristics: service
                .characteristics
                .iter()
                .map(CharacteristicDto::from)
                .collect(),
        }
    }
}

impl From<&Characteristic> for CharacteristicDto {
    fn from(c: &Characteristic) -> Self {
        Self {
            uuid: c.uuid.clone(),
            name: c.name.clone(),
            can_read: c.properties.contains(&CharacteristicProperty::Read),
            can_write: c.properties.contains(&CharacteristicProperty::Write)
                || c.properties
                    .contains(&CharacteristicProperty::WriteWithoutResponse),
            can_notify: c.properties.contains(&CharacteristicProperty::Notify)
                || c.properties.contains(&CharacteristicProperty::Indicate),
            // Straight iteration: `commands` is an IndexMap, so this is the
            // spec's declaration order.
            commands: c
                .commands
                .as_ref()
                .map(|cmds| {
                    cmds.iter()
                        .map(|(name, cmd)| CommandDto::from((c, name.as_str(), cmd)))
                        .collect()
                })
                .unwrap_or_default(),
            format_fields: c
                .format
                .as_ref()
                .map(|fields| fields.iter().map(FormatFieldDto::from).collect())
                .unwrap_or_default(),
        }
    }
}

impl From<&FormatField> for FormatFieldDto {
    fn from(f: &FormatField) -> Self {
        Self {
            name: f.name.clone(),
            field_type: f.field_type.to_string(),
            // Lossless: the parser caps offset+length at MAX_FIELD_EXTENT
            // (64 KiB, spec/parser.rs), so both always fit in u32.
            offset: f.offset as u32,
            length: f.length as u32,
        }
    }
}

/// Built from the characteristic as well as the command: whether a command can
/// be sent depends on the transform its characteristic declares, not only on
/// the command's own encoding. See `unsupported_write_kind`.
impl From<(&Characteristic, &str, &Command)> for CommandDto {
    fn from((characteristic, name, cmd): (&Characteristic, &str, &Command)) -> Self {
        let enc = crate::codec::types::unsupported_write_kind(characteristic, cmd);
        Self {
            name: name.to_string(),
            description: cmd.description.clone(),
            is_fixed: cmd.value.is_some(),
            is_encodable: enc.is_none(),
            unsupported_encoding: enc,
            // Normalized through `locate_kind` rather than forwarded raw, so
            // a spelling this build does not understand crosses the FFI as
            // "not a locator" instead of as a string the Dart side would have
            // to re-validate.
            locate: cmd.locate_kind().map(|kind| kind.as_str().to_string()),
            advanced: cmd.advanced,
            advanced_reason: cmd.advanced_reason.clone(),
            // Same as commands: `params` is an IndexMap, so plain iteration
            // yields the spec's declaration order.
            parameters: cmd
                .parameters
                .as_ref()
                .map(|params| {
                    params
                        .params
                        .iter()
                        .map(|(pname, p)| ParameterDto::from((pname.as_str(), p)))
                        .collect()
                })
                .unwrap_or_default(),
        }
    }
}

impl From<(&str, &Parameter)> for ParameterDto {
    fn from((name, p): (&str, &Parameter)) -> Self {
        // Labels pair with `allowed` 1:1 by index. Specs are loaded from
        // untrusted packs, so a mismatch must not panic; and mispairing
        // (zipping short, or padding) would silently attach the wrong label
        // to a value the device really acts on. Decision: keep `allowed`
        // (it is what the device accepts) and drop `labels` entirely unless
        // both are present with exactly equal lengths. Labels without
        // `allowed` have nothing to pair with and are dropped for the same
        // reason.
        let labels = match (&p.allowed, &p.labels) {
            (Some(allowed), Some(labels)) if allowed.len() == labels.len() => Some(labels.clone()),
            _ => None,
        };
        Self {
            name: name.to_string(),
            value_type: p.value_type.to_string(),
            min: p.min.map(|v| v as f64),
            max: p.max.map(|v| v as f64),
            allowed: p.allowed.clone(),
            labels,
            scale: p.scale,
            value_offset: p.value_offset,
            unit: p.unit.clone(),
            default: p.default,
            // Rendered through Display, which spells the role exactly as the
            // spec's snake_case wire string — Dart pattern-matches on it.
            auto: p.auto.map(|role| role.to_string()),
        }
    }
}

impl From<(&str, &DecodedValue)> for DecodedValueDto {
    fn from((name, value): (&str, &DecodedValue)) -> Self {
        let mut dto = Self {
            name: name.to_string(),
            value_type: match value {
                DecodedValue::Bool(_) => "bool",
                DecodedValue::Int(_) => "int",
                DecodedValue::Uint(_) => "uint",
                DecodedValue::Bytes(_) => "bytes",
                DecodedValue::String(_) => "string",
            }
            .to_string(),
            display: value.display(),
            bool_value: None,
            int_value: None,
            uint_value: None,
            string_value: None,
            scale: None,
            value_offset: None,
            unit: None,
            value_label: None,
            unit_source: None,
        };
        match value {
            DecodedValue::Bool(v) => dto.bool_value = Some(*v),
            DecodedValue::Int(v) => dto.int_value = Some(*v),
            DecodedValue::Uint(v) => {
                // FRB lacks u64 support; clamp into i64 and, when the
                // clamp actually fired, also surface the truthful value
                // as a string so the UI doesn't silently see i64::MAX.
                if *v > i64::MAX as u64 {
                    dto.string_value = Some(v.to_string());
                }
                dto.uint_value = Some((*v).min(i64::MAX as u64) as i64);
            }
            DecodedValue::Bytes(_) => dto.string_value = Some(value.display()),
            DecodedValue::String(v) => dto.string_value = Some(v.clone()),
        }
        dto
    }
}

// ── Public API functions (exposed to Dart via FRB) ──────────────────────────

/// Parse a device spec from a YAML string and return a DTO.
pub fn load_device_spec(yaml: String) -> anyhow::Result<DeviceSpecDto> {
    let spec = parse_device_spec(&yaml)?;
    Ok(DeviceSpecDto::from(&spec))
}

/// The bytes that set a `number`/`climate` entity to a value, and where to
/// write them.
#[derive(Debug, Clone)]
pub struct EntityWriteDto {
    pub service_uuid: String,
    pub characteristic_uuid: String,
    pub bytes: Vec<u8>,
}

/// Encode a setpoint the user picked into the write that applies it.
///
/// `value` is in DECODED units — degrees, percent, whatever the entity's
/// `unit` says — because that is what the user chose. Converting to the raw
/// wire value happens here rather than in the UI so the rule lives in one
/// place: the spec's linear transform is inverted
/// (`raw = round((value - value_offset) / scale)`), which is exactly why the
/// schema keeps that transform linear.
///
/// Both `set_value` shapes are handled: a command carrying the value in its
/// single un-defaulted parameter, and a direct write of the encoded value to
/// a characteristic the entity explicitly nominates.
pub fn encode_entity_value(
    spec_yaml: String,
    entity_name: String,
    value: f64,
) -> anyhow::Result<EntityWriteDto> {
    let spec = parse_device_spec(&spec_yaml)?;
    let entity = spec
        .entities
        .iter()
        .find(|e| e.name == entity_name)
        .ok_or_else(|| anyhow::anyhow!("no entity named '{entity_name}' in this spec"))?;

    let actions = bindings::resolve_entity_actions(&spec, entity);
    let action = actions
        .iter()
        .find(|a| a.role == "set_value")
        .ok_or_else(|| anyhow::anyhow!("entity '{entity_name}' has no settable value"))?;

    // The entity's declared bounds are in decoded units, the same units
    // `value` arrives in. The UI slider clamps too, but this is the API
    // surface: Gerbing's spec says values above its max are untested on the
    // firmware and must be treated as unsafe, so the refusal belongs here,
    // not one caller up.
    if let Some(min) = entity.setpoint_min() {
        if value < min {
            anyhow::bail!("entity '{entity_name}' declares min {min}, refusing {value}");
        }
    }
    if let Some(max) = entity.setpoint_max() {
        if value > max {
            anyhow::bail!("entity '{entity_name}' declares max {max}, refusing {value}");
        }
    }

    let transform = bindings::setpoint_transform(&spec, entity, action);
    let raw = transform.encode(value).ok_or_else(|| {
        anyhow::anyhow!("entity '{entity_name}' declares scale 0, which cannot be inverted")
    })?;
    let value_type = bindings::setpoint_value_type(action)
        .ok_or_else(|| anyhow::anyhow!("entity '{entity_name}' does not declare a value type"))?;

    let bytes = match action.command_name {
        // The command owns the byte layout; hand it the raw value for its one
        // un-defaulted parameter and let the encoder place it, defaults and
        // all.
        Some(command_name) => {
            let command = action
                .characteristic
                .commands
                .as_ref()
                .and_then(|cmds| cmds.get(command_name))
                .ok_or_else(|| {
                    anyhow::anyhow!("command '{command_name}' vanished from the spec")
                })?;
            let params = action
                .user_params
                .first()
                .map(|name| HashMap::from([((*name).to_string(), raw)]))
                .unwrap_or_default();
            crate::codec::types::encode_command(command, &params)?
        }
        // Direct write: the value IS the payload, at the width — and byte
        // order — the single format field declares.
        None => {
            let big_endian = action
                .characteristic
                .format
                .as_ref()
                .and_then(|fields| fields.first())
                .is_some_and(|f| f.is_big_endian());
            crate::codec::types::encode_scalar(raw, &value_type, &entity_name, big_endian)?
        }
    };

    // Wrap in the characteristic's framing when it declares an implemented
    // scheme, matching the generic command path. A one-shot setpoint uses
    // fragment serial 0.
    let bytes = crate::protocol::image_upload::frame_command(action.characteristic, bytes, 0);

    Ok(EntityWriteDto {
        service_uuid: action.service.uuid.clone(),
        characteristic_uuid: action.characteristic.uuid.clone(),
        bytes,
    })
}

// ── Network (SOAP) control ──────────────────────────────────────────────────
//
// The same three jobs the BLE surface does — list the controls, encode a
// write, decode a reading — for a device whose control surface is SOAP
// actions rather than GATT characteristics. The split with Dart mirrors the
// BLE one exactly: Dart owns the I/O (fetch setup.xml, resolve the control
// URL from the device's own service list, POST, parse the reply into
// name→value pairs) and this side owns everything the spec knows.

/// One option of a network `select` control: the raw wire value and the label
/// a user sees. `raw` is a string because that is how it goes on the wire —
/// the Crock-Pot's `51` is SOAP text, not a byte.
#[derive(Debug, Clone)]
pub struct NetworkOptionDto {
    pub raw: String,
    pub label: String,
}

/// A defaulted command parameter whose real value the client must read from
/// the device before sending — parsed out of the spec's
/// `source: "state:<command>.<field>"` so Dart never parses that string.
///
/// This is the Crock-Pot rule: `SetCrockpotState` carries mode and cook time
/// together, so a control changing one must fetch the other and send it back,
/// or the write clears a setting the user never touched.
#[derive(Debug, Clone)]
pub struct NetworkReadBackDto {
    /// Parameter of the command being sent that this value fills.
    pub param: String,
    /// State command whose reply carries the current value.
    pub command: String,
    /// Name of the returned value to read.
    pub field: String,
}

/// One resolved control action on a network entity.
#[derive(Debug, Clone)]
pub struct NetworkActionDto {
    /// `turn_on` | `turn_off` | `press` | `set_value` | `select_option` | …
    pub role: String,
    /// Name in the spec's top-level `commands` block; what
    /// [`render_network_command`] takes.
    pub command_name: String,
    /// `soap` | `http` — which renderer and which wire client the send goes
    /// through. Carried per action rather than per device because one spec
    /// may mix transports; the caller dispatches on this instead of
    /// rediscovering it from a failed render.
    pub transport: String,
    /// The parameters the UI supplies — at most one today (the picked option,
    /// the chosen number). Empty for a fixed action.
    pub user_params: Vec<String>,
    /// Values to read from the device and pass along with the send. Not
    /// optional bookkeeping: skipping these clears settings.
    pub read_back: Vec<NetworkReadBackDto>,
    /// Parameters filled from stored pairing credentials (`credential:` on an
    /// http command). Sending without one must fail visibly — an unpaired
    /// client improvising a request is the bug the spec's no-default rule
    /// exists to prevent.
    pub credentials: Vec<NetworkSourceParamDto>,
    /// Parameters filled with the addressed child's id (`instance:`), for
    /// actions bound by an instanced entity.
    pub instance_params: Vec<NetworkSourceParamDto>,
    /// Declared bounds of the value parameter, in the wire's own units.
    pub min: Option<f64>,
    pub max: Option<f64>,
}

/// A command parameter filled from a client-held value rather than the UI:
/// `credential:<name>` (a per-device secret stored at pairing) or
/// `instance:<key>` (the id of the child a hub command addresses). Parsed
/// out of the spec's `source` so Dart never parses that string.
#[derive(Debug, Clone)]
pub struct NetworkSourceParamDto {
    /// Parameter of the command being sent that this value fills.
    pub param: String,
    /// The credential's name (`username`) or the instance key (`id`).
    pub name: String,
}

/// A resolved XML query source: the request to make and how to read entries
/// out of its response.
///
/// The spec's `options_source`/`state_source` with the endpoint join already
/// done — the entity names an endpoint, this carries that endpoint's method
/// and path so Dart never joins the two blocks by name. The contract for the
/// response is the schema's: every element whose local name is [`Self::item`]
/// is one entry, the attribute named [`Self::value_attribute`] is its raw
/// value, the element's trimmed text is its label.
#[derive(Debug, Clone)]
pub struct QuerySourceDto {
    pub method: String,
    pub path: String,
    pub item: String,
    pub value_attribute: String,
}

/// A spec-declared control or reading on a network device: what to draw,
/// where its state comes from, and what each role sends.
#[derive(Debug, Clone)]
pub struct NetworkEntityDto {
    pub name: String,
    pub platform: Option<String>,
    pub device_class: Option<String>,
    pub icon: Option<String>,
    pub unit: Option<String>,
    /// Conventional path of the state endpoint. A fallback for display and
    /// for a client that has not fetched the description yet — the real
    /// address comes from the device's own service list.
    pub state_endpoint: Option<String>,
    /// Action whose reply carries this entity's state. Pass to
    /// [`render_network_state_request`]; one call serves every entity bound
    /// to the same command.
    pub state_command: String,
    /// The one transport this entity's actions ride (`soap` | `http`), or
    /// `None` for a pure reading with no actions. Surfaced at entity level
    /// because it is what routes the whole device screen — a hub gets a
    /// different screen from a Wemo plug.
    pub transport: Option<String>,
    /// True when the entity is a template stamped out per child behind a
    /// hub: enumerate with [`list_network_instances`], read each child with
    /// [`read_network_instance`], and fill each action's `instance_params`
    /// with the child's id when sending.
    pub is_instanced: bool,
    /// Name of the returned value carrying the reading.
    pub value_field: Option<String>,
    /// Option table for a `select`, in declaration order. Empty otherwise.
    pub options: Vec<NetworkOptionDto>,
    /// Where a `select` fetches options the spec could not enumerate (the
    /// installed-channel list). None for statically-optioned entities.
    pub options_source: Option<QuerySourceDto>,
    /// Where such a select reads which option is current. None means the
    /// control launches without showing a current selection.
    pub state_source: Option<QuerySourceDto>,
    /// Sendable actions, role order. Empty for a pure reading.
    pub actions: Vec<NetworkActionDto>,
    pub setpoint_min: Option<f64>,
    pub setpoint_max: Option<f64>,
    pub setpoint_step: Option<f64>,
}

/// A rendered SOAP request, ready for Dart to POST.
#[derive(Debug, Clone)]
pub struct SoapRequestDto {
    /// serviceType URN — the key the control URL is resolved by from the
    /// device's own serviceList. Never trust a path over this.
    pub service: String,
    pub action: String,
    /// The SOAPACTION header value, quotes included (they are part of it).
    pub soap_action: String,
    /// Conventional control path, when the spec states one.
    pub path: Option<String>,
    /// The exact request body to send.
    pub body: String,
}

/// What kind of value a network entity reading is.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NetworkReadingKind {
    /// A switch/binary sensor; `is_on` carries the answer.
    OnOff,
    /// A `select` whose raw value matched its option table; `label` is what
    /// to show.
    Option,
    /// A `select` whose raw value matched nothing. Shown as unknown, never
    /// folded into the first option — on the Crock-Pot that fold reads "off"
    /// while the thing is heating.
    UnknownOption,
    Number,
    Text,
}

/// One entity's decoded state.
#[derive(Debug, Clone)]
pub struct NetworkReadingDto {
    pub kind: NetworkReadingKind,
    pub is_on: Option<bool>,
    pub label: Option<String>,
    pub number: Option<f64>,
    /// The raw value the reading came from, always present — it is what an
    /// unknown option displays, and what a bug report needs.
    pub raw: String,
}

impl NetworkActionDto {
    fn from(action: &bindings::NetworkAction<'_>) -> Self {
        use crate::protocol::http::SourceScheme;
        let mut read_back = Vec::new();
        let mut credentials = Vec::new();
        let mut instance_params = Vec::new();
        for (param, source) in &action.read_back {
            // The three source schemes, each to its own surface. A source in
            // a shape this does not understand is dropped rather than guessed
            // at: the caller then cannot pre-fill that parameter, and the
            // spec's `default` carries the send (or, on http, resolution
            // already declined the command).
            match crate::protocol::http::parse_source(source) {
                Some(SourceScheme::State { command, field }) => {
                    read_back.push(NetworkReadBackDto {
                        param: (*param).to_string(),
                        command: command.to_string(),
                        field: field.to_string(),
                    });
                }
                Some(SourceScheme::Credential(name)) => credentials.push(NetworkSourceParamDto {
                    param: (*param).to_string(),
                    name: name.to_string(),
                }),
                Some(SourceScheme::Instance(key)) => instance_params.push(NetworkSourceParamDto {
                    param: (*param).to_string(),
                    name: key.to_string(),
                }),
                None => {}
            }
        }
        Self {
            role: action.role.to_string(),
            command_name: action.command_name.to_string(),
            transport: action
                .command
                .transport
                .clone()
                .unwrap_or_else(|| crate::protocol::soap::TRANSPORT.to_string()),
            user_params: action.user_params.iter().map(|p| p.to_string()).collect(),
            read_back,
            credentials,
            instance_params,
            min: action.min,
            max: action.max,
        }
    }

    /// A LIFX control as a network action. LIFX actions are synthesised from the
    /// entity's `features` rather than resolved from spec `commands`, so they
    /// carry no read-back and always the `lifx` transport — the UI dispatches on
    /// that to the UDP client and calls [`render_lifx_command`] rather than
    /// rendering a SOAP/HTTP request.
    fn from_lifx(control: &crate::protocol::lifx::LifxControl) -> Self {
        Self {
            role: control.role.to_string(),
            command_name: control.command_name.to_string(),
            transport: crate::protocol::lifx::TRANSPORT.to_string(),
            user_params: control
                .user_params
                .iter()
                .map(|p| (*p).to_string())
                .collect(),
            read_back: Vec::new(),
            // LIFX is unauthenticated and single-device: no paired credential
            // to fill, no hub child to address.
            credentials: Vec::new(),
            instance_params: Vec::new(),
            min: control.min,
            max: control.max,
        }
    }
}

/// The controllable LIFX entities of a spec, as network entity DTOs. LIFX has
/// no `commands`/`services` the generic resolver could execute, so its `light`
/// entities are synthesised directly from `features` — see
/// [`crate::protocol::lifx::network_entities`]. State is not polled through a
/// SOAP `state_command` (there is none); the UI reads it live with
/// [`build_lifx_state_request`] + [`decode_lifx_state`], so `state_command` is
/// left empty and the entity survives on its actions alone.
fn lifx_network_entities(spec: &DeviceSpec) -> Vec<NetworkEntityDto> {
    crate::protocol::lifx::network_entities(spec)
        .into_iter()
        .map(|entity| NetworkEntityDto {
            name: entity.name,
            platform: Some("light".to_string()),
            // The whole device screen routes on this: a lifx entity gets the
            // LIFX light card and the UDP client, not a SOAP/HTTP path.
            transport: Some(crate::protocol::lifx::TRANSPORT.to_string()),
            // A strip is one device, not a hub of children.
            is_instanced: false,
            device_class: None,
            icon: None,
            unit: None,
            state_endpoint: None,
            state_command: String::new(),
            value_field: None,
            options: Vec::new(),
            options_source: None,
            state_source: None,
            actions: entity
                .controls
                .iter()
                .map(NetworkActionDto::from_lifx)
                .collect(),
            setpoint_min: None,
            setpoint_max: None,
            setpoint_step: None,
        })
        .collect()
}

/// Resolve an entity's query source against the spec's endpoint catalogue.
///
/// None when the entity declares none, and also when the named endpoint is
/// missing or sunset — the same rule the admission gate applies, so a source
/// this returns is always fetchable as declared.
fn resolve_query_source(
    spec: &crate::spec::types::DeviceSpec,
    source: Option<&crate::spec::types::QuerySource>,
) -> Option<QuerySourceDto> {
    let source = source?;
    let (method, path) = crate::protocol::http::endpoint_request(spec, &source.command)?;
    Some(QuerySourceDto {
        method,
        path,
        item: source.item.clone(),
        value_attribute: source.value.clone(),
    })
}

/// The controls a spec declares for one discovered network device.
///
/// `ssdp_targets` is what the device itself answered to — it is how a family
/// spec's variant-scoped entities are narrowed to the model actually found.
/// A Wemo plug must not grow a Cook Mode picker because its spec also covers
/// a slow cooker; when the model cannot be identified at all, scoped entities
/// are dropped rather than guessed.
pub fn network_entities_for_device(
    spec_yaml: String,
    ssdp_targets: Vec<String>,
) -> anyhow::Result<Vec<NetworkEntityDto>> {
    let spec = parse_device_spec(&spec_yaml)?;
    // LIFX is driven by a dedicated binary-UDP handler, not the generic
    // command resolver (which rejects a non-SOAP/HTTP transport). Its light
    // entities are synthesised from `features` before the generic path runs.
    if spec.protocol_handler.as_deref() == Some(crate::protocol::lifx::HANDLER_NAME) {
        return Ok(lifx_network_entities(&spec));
    }
    Ok(bindings::network_entities_for_targets(&spec, &ssdp_targets)
        .into_iter()
        .map(|entity| {
            let actions = bindings::resolve_network_actions(&spec, entity);
            NetworkEntityDto {
                name: entity.name.clone(),
                platform: entity.platform.clone(),
                device_class: entity.device_class.clone(),
                icon: entity.icon.clone(),
                unit: entity.unit.clone(),
                state_endpoint: entity.state_endpoint.clone(),
                // Present for every stateful entity —
                // `network_entities_for_targets` requires it of them. Empty
                // for a `button`, which has no state to poll; a caller
                // gathering state commands must skip the empty string rather
                // than render a request from it.
                state_command: entity.state_command.clone().unwrap_or_default(),
                // Every resolved action on one entity rides one transport —
                // a spec binding a light's toggle to SOAP and its slider to
                // HTTP would be describing two devices — so the first
                // action's answer is the entity's.
                transport: actions.first().map(|a| {
                    a.command
                        .transport
                        .clone()
                        .unwrap_or_else(|| crate::protocol::soap::TRANSPORT.to_string())
                }),
                is_instanced: entity.instances.is_some(),
                value_field: entity.value_field().map(str::to_string),
                options: entity
                    .options()
                    .into_iter()
                    .map(|(raw, label)| NetworkOptionDto { raw, label })
                    .collect(),
                options_source: resolve_query_source(&spec, entity.options_source.as_ref()),
                state_source: resolve_query_source(&spec, entity.state_source.as_ref()),
                actions: actions.iter().map(NetworkActionDto::from).collect(),
                setpoint_min: entity.setpoint_min().or_else(|| {
                    actions
                        .iter()
                        .find(|a| a.role == "set_value")
                        .and_then(|a| a.min)
                }),
                setpoint_max: entity.setpoint_max().or_else(|| {
                    actions
                        .iter()
                        .find(|a| a.role == "set_value")
                        .and_then(|a| a.max)
                }),
                setpoint_step: entity.setpoint_step(),
            }
        })
        // A stateless entity that resolved no sendable action is nothing at
        // all — no reading to show, no button to press. A stateful one still
        // renders as a reading, so only the stateless kind is dropped.
        .filter(|entity| !entity.state_command.is_empty() || !entity.actions.is_empty())
        .collect())
}

/// Render a named command from the spec's `commands` block into a POSTable
/// request. `values` supplies the parameters the caller owns plus any
/// read-back values it fetched; the spec's defaults fill the rest.
pub fn render_network_command(
    spec_yaml: String,
    command_name: String,
    values: HashMap<String, String>,
) -> anyhow::Result<SoapRequestDto> {
    let spec = parse_device_spec(&spec_yaml)?;
    let request =
        crate::protocol::soap::render_request(&spec, &command_name, &values.into_iter().collect())?;
    Ok(SoapRequestDto::from(request))
}

/// A rendered plain-HTTP request, ready for Dart to send.
///
/// The sibling of [`SoapRequestDto`] for transports where the method and the
/// path ARE the request — Roku ECP's keypresses. The address is the caller's:
/// discovery already knows the host and port.
#[derive(Debug, Clone)]
pub struct HttpRequestDto {
    /// `GET` | `POST` | …, as the spec spelled it.
    pub method: String,
    /// Path with every placeholder substituted, starting with `/`.
    pub path: String,
    /// Request body — empty for the ECP style, carried for the day a spec
    /// declares one.
    pub body: String,
}

impl From<crate::protocol::http::HttpRequest> for HttpRequestDto {
    fn from(request: crate::protocol::http::HttpRequest) -> Self {
        Self {
            method: request.method,
            path: request.path,
            body: request.body,
        }
    }
}

/// Render a named `transport: http` command from the spec's `commands` block
/// into a sendable request — [`render_network_command`]'s sibling for the
/// transport with no envelope. A SOAP command handed here is declined, and
/// vice versa; the action's `transport` field says which to call.
pub fn render_network_http_command(
    spec_yaml: String,
    command_name: String,
    values: HashMap<String, String>,
) -> anyhow::Result<HttpRequestDto> {
    let spec = parse_device_spec(&spec_yaml)?;
    let request =
        crate::protocol::http::render_request(&spec, &command_name, &values.into_iter().collect())?;
    Ok(HttpRequestDto::from(request))
}

/// A rendered Kasa request: the JSON to send, before the cipher and framing.
///
/// The third transport's sibling of [`SoapRequestDto`] / [`HttpRequestDto`].
/// The whole invocation is this JSON; the caller turns it into wire bytes with
/// [`kasa_encode_frame`] (TCP control) or [`kasa_encrypt_datagram`] (UDP
/// discovery), and the address is the one discovery established.
#[derive(Debug, Clone)]
pub struct KasaRequestDto {
    pub json: String,
}

impl From<crate::protocol::kasa::KasaRequest> for KasaRequestDto {
    fn from(request: crate::protocol::kasa::KasaRequest) -> Self {
        Self { json: request.json }
    }
}

/// Render a named `transport: tcp-json` command into the JSON to send — the
/// Kasa sibling of [`render_network_command`] / [`render_network_http_command`].
/// A command for another transport is declined; the action's `transport` says
/// which renderer to call.
pub fn render_network_kasa_command(
    spec_yaml: String,
    command_name: String,
    values: HashMap<String, String>,
) -> anyhow::Result<KasaRequestDto> {
    let spec = parse_device_spec(&spec_yaml)?;
    let request =
        crate::protocol::kasa::render_request(&spec, &command_name, &values.into_iter().collect())?;
    Ok(KasaRequestDto::from(request))
}

/// Render the JSON that polls a Kasa state command (`get_sysinfo`). The Kasa
/// counterpart of [`render_network_state_request`]; the poll is a first-class
/// command with a `body`, so it renders the same way a control does.
pub fn render_network_kasa_state_request(
    spec_yaml: String,
    state_command: String,
) -> anyhow::Result<KasaRequestDto> {
    let spec = parse_device_spec(&spec_yaml)?;
    let request = crate::protocol::kasa::render_state_request(&spec, &state_command)?;
    Ok(KasaRequestDto::from(request))
}

/// Encrypt and length-frame a Kasa JSON request for the TCP control socket
/// (port 9999). Dart writes the returned bytes and reads the reply back through
/// [`kasa_decode_frame`]; the cipher stays in one tested place rather than
/// re-implemented in Dart.
pub fn kasa_encode_frame(json: String) -> Vec<u8> {
    crate::protocol::kasa::encode_frame(json.as_bytes())
}

/// Decode a length-framed Kasa TCP reply back to its JSON text, for Dart to
/// parse with `dart:convert`. Errors on a short/truncated frame or non-UTF-8
/// payload rather than returning garbage.
pub fn kasa_decode_frame(frame: Vec<u8>) -> anyhow::Result<String> {
    let plaintext = crate::protocol::kasa::decode_frame(&frame)?;
    String::from_utf8(plaintext).map_err(|e| anyhow::anyhow!("Kasa reply is not UTF-8: {e}"))
}

/// Encrypt a Kasa JSON request as a UDP discovery datagram — the same cipher
/// as [`kasa_encode_frame`] but with no length prefix, which is how the
/// broadcast probe and its replies are framed.
pub fn kasa_encrypt_datagram(json: String) -> Vec<u8> {
    crate::protocol::kasa::encrypt(json.as_bytes())
}

/// Decode a Kasa UDP reply datagram (no length prefix) back to its JSON text.
pub fn kasa_decode_datagram(datagram: Vec<u8>) -> anyhow::Result<String> {
    let plaintext = crate::protocol::kasa::decrypt(&datagram);
    String::from_utf8(plaintext).map_err(|e| anyhow::anyhow!("Kasa datagram is not UTF-8: {e}"))
}

/// Render the argument-less request that reads a state command's values —
/// what a client sends to poll `GetCrockpotState` or `GetBinaryState`.
pub fn render_network_state_request(
    spec_yaml: String,
    state_command: String,
) -> anyhow::Result<SoapRequestDto> {
    let spec = parse_device_spec(&spec_yaml)?;
    let request = crate::protocol::soap::render_state_request(&spec, &state_command)?;
    Ok(SoapRequestDto::from(request))
}

impl From<crate::protocol::soap::SoapRequest> for SoapRequestDto {
    fn from(request: crate::protocol::soap::SoapRequest) -> Self {
        Self {
            service: request.service,
            action: request.action,
            soap_action: request.soap_action,
            path: request.path,
            body: request.body,
        }
    }
}

/// Decode one entity's state from the name→value pairs a state call
/// returned. `None` when the reply did not carry the entity's value — which
/// renders as unknown, never as a fabricated zero.
pub fn read_network_entity(
    spec_yaml: String,
    entity_name: String,
    returned: HashMap<String, String>,
) -> anyhow::Result<Option<NetworkReadingDto>> {
    let spec = parse_device_spec(&spec_yaml)?;
    let entity = spec
        .entities
        .iter()
        .find(|e| e.name == entity_name)
        .ok_or_else(|| anyhow::anyhow!("no entity named '{entity_name}' in this spec"))?;
    let returned = returned.into_iter().collect();
    Ok(crate::protocol::soap::read_entity(&spec, entity, &returned).map(reading_to_dto))
}

/// One [`EntityReading`] as the DTO Dart draws — shared by the SOAP and HTTP
/// read paths so a reading means the same thing whichever transport carried
/// it.
fn reading_to_dto(reading: crate::protocol::soap::EntityReading) -> NetworkReadingDto {
    use crate::protocol::soap::EntityReading;
    match reading {
        EntityReading::OnOff(on) => NetworkReadingDto {
            kind: NetworkReadingKind::OnOff,
            is_on: Some(on),
            label: None,
            number: None,
            raw: if on { "1" } else { "0" }.to_string(),
        },
        EntityReading::Option { raw, label } => NetworkReadingDto {
            kind: NetworkReadingKind::Option,
            is_on: None,
            label: Some(label),
            number: None,
            raw,
        },
        EntityReading::UnknownOption { raw } => NetworkReadingDto {
            kind: NetworkReadingKind::UnknownOption,
            is_on: None,
            label: None,
            number: None,
            raw,
        },
        EntityReading::Number(n) => NetworkReadingDto {
            kind: NetworkReadingKind::Number,
            is_on: None,
            label: None,
            number: Some(n),
            raw: format_number(n),
        },
        EntityReading::Text(raw) => NetworkReadingDto {
            kind: NetworkReadingKind::Text,
            is_on: None,
            label: None,
            number: None,
            raw,
        },
    }
}

/// A number as its shortest honest string: `240` not `240.0`, `53.2` intact.
fn format_number(n: f64) -> String {
    if n.fract() == 0.0 && n.abs() < 1e15 {
        format!("{}", n as i64)
    } else {
        n.to_string()
    }
}

// ── Network (HTTP) hub control ──────────────────────────────────────────────
//
// A hub is a population rather than a device, so two jobs join the render
// side (`render_network_http_command`, above): enumerating the children one
// state reply carries, and reading one child's roles out of it. Dart owns the
// I/O (TLS, the credential store, the socket); this side owns everything the
// spec knows.

/// One child behind a hub, as enumerated from a state reply.
#[derive(Debug, Clone)]
pub struct NetworkInstanceDto {
    /// The hub's own id for the child — what fills each action's
    /// `instance_params` when sending.
    pub id: String,
    /// The child's human-facing name, falling back to the id.
    pub label: String,
}

/// One role's reading on one child — `is_on`, `brightness`, … paired with
/// its decoded value.
#[derive(Debug, Clone)]
pub struct NetworkRoleReadingDto {
    pub role: String,
    pub reading: NetworkReadingDto,
}

/// Render the request that reads a state command's values over HTTP — on an
/// instanced entity, the one GET that enumerates every child and carries all
/// their state. `values` fills the path's placeholders (the pairing
/// credential, on the Hue bridge); a missing one fails the render, the same
/// visible failure a credential-less write gets.
pub fn render_network_http_state_request(
    spec_yaml: String,
    state_command: String,
    values: HashMap<String, String>,
) -> anyhow::Result<HttpRequestDto> {
    let spec = parse_device_spec(&spec_yaml)?;
    let request = crate::protocol::http::render_state_request(
        &spec,
        &state_command,
        &values.into_iter().collect(),
    )?;
    Ok(HttpRequestDto::from(request))
}

/// Enumerate the children an instanced entity's state reply carries, in the
/// hub's own order (numeric ids numerically, so light 2 lists before 10).
pub fn list_network_instances(
    spec_yaml: String,
    entity_name: String,
    state_reply: String,
) -> anyhow::Result<Vec<NetworkInstanceDto>> {
    let spec = parse_device_spec(&spec_yaml)?;
    let entity = find_entity(&spec, &entity_name)?;
    Ok(crate::protocol::http::list_instances(entity, &state_reply)?
        .into_iter()
        .map(|instance| NetworkInstanceDto {
            id: instance.id,
            label: instance.label,
        })
        .collect())
}

/// Read one child's roles out of an instanced entity's state reply. Empty
/// for a child the reply no longer carries — which renders as unknown, never
/// as a fabricated "off".
pub fn read_network_instance(
    spec_yaml: String,
    entity_name: String,
    state_reply: String,
    instance_id: String,
) -> anyhow::Result<Vec<NetworkRoleReadingDto>> {
    let spec = parse_device_spec(&spec_yaml)?;
    let entity = find_entity(&spec, &entity_name)?;
    Ok(
        crate::protocol::http::read_instance_entity(entity, &state_reply, &instance_id)?
            .into_iter()
            .map(|(role, reading)| NetworkRoleReadingDto {
                role,
                reading: reading_to_dto(reading),
            })
            .collect(),
    )
}

fn find_entity<'a>(
    spec: &'a crate::spec::types::DeviceSpec,
    entity_name: &str,
) -> anyhow::Result<&'a crate::spec::types::Entity> {
    spec.entities
        .iter()
        .find(|e| e.name == entity_name)
        .ok_or_else(|| anyhow::anyhow!("no entity named '{entity_name}' in this spec"))
}

// ── LIFX (binary UDP) ───────────────────────────────────────────────────────
// LIFX speaks a binary LAN protocol over UDP unicast, not text-over-TCP like
// SOAP/HTTP. So instead of a rendered request DTO the caller POSTs, these return
// the datagram *bytes* the caller sends over its own UDP socket, and take the
// reply bytes back to decode — the byte-in/byte-out shape of the BLE codec, one
// transport over. See `crate::protocol::lifx`.

/// The UDP port every LIFX device listens on. Exposed so the Dart client need
/// not hardcode it separately from the protocol module.
pub fn lifx_port() -> u16 {
    crate::protocol::lifx::PORT
}

/// Render one LIFX control action into the datagram bytes to send.
///
/// `action` is a `command_name` from [`network_entities_for_device`] on a LIFX
/// spec (`turn_on`, `set_color`, `set_zone_color`, …); `params` carries the
/// UI-owned values (`red`/`green`/`blue`/`brightness` on 0..=255, `kelvin` on
/// 1500..=9000, `zone` a zone index). `target_mac` is `d0:73:d5:…` or empty for
/// a device not yet identified (the all-zero target unicast firmware accepts).
/// `sequence` is the caller's counter, echoed in any reply for correlation.
pub fn render_lifx_command(
    action: String,
    params: HashMap<String, f64>,
    target_mac: String,
    sequence: u8,
) -> anyhow::Result<Vec<u8>> {
    let target = crate::protocol::lifx::parse_mac(&target_mac);
    Ok(crate::protocol::lifx::render_command(
        &action, &params, target, sequence,
    )?)
}

/// The tagged-broadcast `GetService` datagram — the discovery probe every LIFX
/// device answers with a `StateService`.
pub fn build_lifx_discovery_probe(sequence: u8) -> Vec<u8> {
    crate::protocol::lifx::get_service(sequence)
}

/// The `LightGet` datagram that asks a device for its current colour and power.
pub fn build_lifx_state_request(target_mac: String, sequence: u8) -> Vec<u8> {
    crate::protocol::lifx::get_color(crate::protocol::lifx::parse_mac(&target_mac), sequence)
}

/// The `GetColorZones` datagram asking for the colours of zones `start..=end`.
pub fn build_lifx_zones_request(target_mac: String, start: u8, end: u8, sequence: u8) -> Vec<u8> {
    crate::protocol::lifx::get_color_zones(
        crate::protocol::lifx::parse_mac(&target_mac),
        start,
        end,
        sequence,
    )
}

/// A decoded `StateService` reply: which device answered (MAC), on which
/// service (1 = UDP) and port. The IP is the datagram's source address, which
/// the socket already knows.
#[derive(Debug, Clone)]
pub struct LifxServiceDto {
    pub mac: String,
    pub service: u8,
    pub port: u32,
}

/// A decoded light `State` reply, in the units the UI works in: RGB and
/// brightness on 0..=255 for the colour swatch and slider, plus the raw HSBK
/// channels and the device's label.
#[derive(Debug, Clone)]
pub struct LifxStateDto {
    pub power_on: bool,
    pub red: u8,
    pub green: u8,
    pub blue: u8,
    pub brightness: u8,
    pub hue: u16,
    pub saturation: u16,
    pub kelvin: u16,
    pub label: String,
}

/// One zone's colour, RGB + brightness on 0..=255.
#[derive(Debug, Clone)]
pub struct LifxZoneColorDto {
    pub red: u8,
    pub green: u8,
    pub blue: u8,
    pub brightness: u8,
}

/// A decoded multizone reply: the strip's total zone count, the index this
/// batch starts at, and the colours it carries.
#[derive(Debug, Clone)]
pub struct LifxZonesDto {
    pub zones_count: u8,
    pub zone_index: u8,
    pub colors: Vec<LifxZoneColorDto>,
}

/// Format a 6-byte MAC as the `d0:73:d5:00:04:a3` string the UI and discovery
/// key on.
fn format_mac(mac: [u8; 6]) -> String {
    mac.iter()
        .map(|b| format!("{b:02x}"))
        .collect::<Vec<_>>()
        .join(":")
}

fn brightness_to_byte(brightness: u16) -> u8 {
    (f64::from(brightness) / f64::from(u16::MAX) * 255.0).round() as u8
}

/// Decode a `StateService` datagram (the discovery reply).
pub fn parse_lifx_state_service(bytes: Vec<u8>) -> anyhow::Result<LifxServiceDto> {
    let s = crate::protocol::lifx::parse_state_service(&bytes)?;
    Ok(LifxServiceDto {
        mac: format_mac(s.mac),
        service: s.service,
        port: s.port,
    })
}

/// Decode a light `State` (107) datagram into a UI-facing reading.
pub fn decode_lifx_state(bytes: Vec<u8>) -> anyhow::Result<LifxStateDto> {
    let s = crate::protocol::lifx::parse_state(&bytes)?;
    let (red, green, blue) = crate::protocol::lifx::hsbk_to_rgb(&s.color);
    Ok(LifxStateDto {
        power_on: s.power_on,
        red,
        green,
        blue,
        brightness: brightness_to_byte(s.color.brightness),
        hue: s.color.hue,
        saturation: s.color.saturation,
        kelvin: s.color.kelvin,
        label: s.label,
    })
}

/// Decode a `StateMultiZone` (506) or `StateZone` (503) datagram into per-zone
/// colours. Routed by the datagram's own message type.
pub fn decode_lifx_zones(bytes: Vec<u8>) -> anyhow::Result<LifxZonesDto> {
    use crate::protocol::lifx::{decode_reply, Reply};
    let mz = match decode_reply(&bytes)? {
        Reply::Zones(mz) => mz,
        other => anyhow::bail!("expected a zone reply, got {other:?}"),
    };
    Ok(LifxZonesDto {
        zones_count: mz.zones_count,
        zone_index: mz.zone_index,
        colors: mz
            .colors
            .iter()
            .map(|c| {
                let (red, green, blue) = crate::protocol::lifx::hsbk_to_rgb(c);
                LifxZoneColorDto {
                    red,
                    green,
                    blue,
                    brightness: brightness_to_byte(c.brightness),
                }
            })
            .collect(),
    })
}

// ── LIFX SoftAP provisioning ─────────────────────────────────────────────────
// The legacy access-point family that onboards an unprovisioned strip onto WiFi,
// spoken over the device's own setup AP. The exchange is unauthenticated and the
// passphrase is plaintext (the setup AP is the only transport protection), so the
// caller must send it once and never persist it. Unverified against hardware and
// legacy-firmware only — Matter-era units onboard over BLE and ignore these.

/// One network an unprovisioned device reported it can see (a `StateAccessPoint`
/// reply), for the user to pick from.
#[derive(Debug, Clone)]
pub struct LifxAccessPointDto {
    pub ssid: String,
    /// The `SECURITY_PROTOCOL` byte (1 OPEN, 3 WPA-TKIP, 5 WPA2-AES, …), passed
    /// straight back in the `SetAccessPoint` for the chosen network.
    pub security: u8,
    /// Signal strength as the device reported it (higher is stronger).
    pub strength: i32,
    pub channel: u16,
}

/// The default `SECURITY_PROTOCOL` (WPA2-AES) to try for a manually-typed SSID
/// that never appeared in a scan.
pub fn lifx_default_security() -> u8 {
    crate::protocol::lifx::SECURITY_WPA2_AES
}

/// The `GetAccessPoints` datagram that asks an unprovisioned device to scan.
pub fn build_lifx_get_access_points(sequence: u8) -> Vec<u8> {
    crate::protocol::lifx::get_access_points(sequence)
}

/// The `SetAccessPoint` datagram handing the device its home-network
/// credentials. `password` is sent in plaintext (the legacy exchange has no
/// credential encryption) — do not persist it.
pub fn render_lifx_set_access_point(
    ssid: String,
    password: String,
    security: u8,
    sequence: u8,
) -> Vec<u8> {
    crate::protocol::lifx::set_access_point(&ssid, &password, security, sequence)
}

/// Decode a `StateAccessPoint` (0x132) scan-result datagram.
pub fn decode_lifx_access_point(bytes: Vec<u8>) -> anyhow::Result<LifxAccessPointDto> {
    let ap = crate::protocol::lifx::parse_state_access_point(&bytes)?;
    Ok(LifxAccessPointDto {
        ssid: ap.ssid,
        security: ap.security,
        strength: i32::from(ap.strength),
        channel: ap.channel,
    })
}

/// The axes on which one spec identity matched one observation. Every field is
/// empty/false when nothing matched at all.
///
/// `frb(ignore)` because this is internal bookkeeping between the two public
/// matchers: without it flutter_rust_bridge sees a struct in an `api` module
/// and generates Dart bindings that reach for its private fields.
#[frb(ignore)]
#[derive(Default)]
struct MatchAxes {
    by_name_prefix: bool,
    /// Strong tier: a vendor-allocated identifier the device volunteered.
    /// Only UUIDs [`is_sig_assigned_service`] rejects land here.
    service_uuids: Vec<String>,
    /// The BLE counterpart of [`shared_service_types`](Self::shared_service_types):
    /// services the Bluetooth SIG defined for everyone, which say what a device
    /// can do and never who made it. Reported, never promoting.
    shared_service_uuids: Vec<String>,
    /// Strong tier, network side: mDNS service types and SSDP search targets
    /// that identify a vendor. Only ones [`is_shared_service_type`] rejects
    /// land here.
    service_types: Vec<String>,
    /// The network counterpart of a low-confidence OUI: identifiers a whole
    /// category of hardware answers to, like `upnp:rootdevice` or `_hap._tcp`.
    /// Reported so the caller can say what matched, but never promoting.
    shared_service_types: Vec<String>,
    /// Likely tier.
    company_ids: Vec<u16>,
    /// Identifies a vendor, not a product — except where the spec says
    /// otherwise. Worth what its [`MacPrefixConfidence`] says it is.
    mac_prefix: Option<MacPrefixDto>,
    // There is deliberately no port axis. A matched `default_port` used to sit
    // here and count towards `is_empty`, which made it *admitting*: the two
    // specs whose only network signal is a port claimed every host answering on
    // it, so any router admin page or NAS on the link came back "Possibly
    // Rachio". A port is not a weak identifier, it is not an identifier —
    // nothing about port 80 distinguishes one listener from the next. The
    // declaration still gates a spec into the network path (see
    // [`match_network_axes`]) so its name prefix gets a hearing; it just cannot
    // be the evidence itself.
}

impl MatchAxes {
    fn is_empty(&self) -> bool {
        !self.by_name_prefix
            && self.service_uuids.is_empty()
            && self.shared_service_uuids.is_empty()
            && self.service_types.is_empty()
            && self.shared_service_types.is_empty()
            && self.company_ids.is_empty()
            && self.mac_prefix.is_none()
    }

    /// Every network identifier that matched, shared ones last. What the UI
    /// reports; the confidence rule reads the two lists separately.
    fn all_service_types(&self) -> Vec<String> {
        let mut all = self.service_types.clone();
        all.extend(self.shared_service_types.iter().cloned());
        all
    }

    /// The same, for BLE service UUIDs. A user asking why a device was flagged
    /// wants to see every UUID that matched, including the standard ones — it
    /// is only the confidence verdict that has to tell them apart.
    fn all_service_uuids(&self) -> Vec<String> {
        let mut all = self.service_uuids.clone();
        all.extend(self.shared_service_uuids.iter().cloned());
        all
    }

    /// How much the matched OUI is worth, or `Low` when none matched. `Low` is
    /// also what an unannotated prefix is worth, so the two are deliberately
    /// indistinguishable here: neither one may promote a match on its own.
    fn mac_prefix_confidence(&self) -> MacPrefixConfidence {
        self.mac_prefix
            .as_ref()
            .map(|p| p.confidence)
            .unwrap_or_default()
    }

    /// How many distinct axes agreed. Used to promote a pile of weak signals:
    /// a name prefix on its own is ordinary, a name prefix on a device whose
    /// OUI also belongs to that vendor is not.
    ///
    /// Three axes deliberately do not count, because each can match by
    /// coincidence rather than by design, and letting one be half of an
    /// "everything agrees" verdict is exactly how a scanner ends up confidently
    /// naming the wrong product:
    ///
    /// - a low-confidence OUI (a block IEEE subdivided among fifteen companies,
    ///   or a radio module vendor's block carried by every product using the
    ///   chip);
    /// - a SIG-assigned service UUID (0x180F Battery, 0x181A Environmental
    ///   Sensing — services the specification defines for everyone, so matching
    ///   one says what the device does and nothing about who built it);
    /// - a shared service type or search target (`upnp:rootdevice` is answered
    ///   by every router, printer and NAS on the link);
    ///
    /// A default port does not appear at all — not because it cannot promote,
    /// but because it is not an axis; see the note on [`MatchAxes`].
    fn agreeing(&self) -> usize {
        usize::from(self.by_name_prefix)
            + usize::from(!self.service_uuids.is_empty())
            + usize::from(!self.service_types.is_empty())
            + usize::from(!self.company_ids.is_empty())
            + usize::from(self.mac_prefix_confidence() >= MacPrefixConfidence::Medium)
    }

    fn confidence(&self) -> MatchConfidence {
        // Both lists here are only the vendor-specific half. A match on
        // `_hue._tcp` is proof-shaped, a match on `upnp:rootdevice` is not, and
        // before that split every UPnP root device on the link was reported as
        // a Strong "Philips Hue Bridge". A SIG-assigned UUID is the same thing
        // one axis over: 0x181A is the Environmental Sensing service every
        // thermometer on the market exposes, and matching it was reporting each
        // of them as a Strong "Xiaomi LYWSD03MMC".
        if !self.service_uuids.is_empty() || !self.service_types.is_empty() || self.agreeing() >= 2
        {
            MatchConfidence::Strong
        } else if self.by_name_prefix
            || !self.company_ids.is_empty()
            // A block a spec author checked and found to be this device family's
            // and effectively nothing else's is evidence in its own right —
            // the same standing as a local name, which users can rename anyway.
            || self.mac_prefix_confidence() >= MacPrefixConfidence::High
        {
            MatchConfidence::Likely
        } else {
            MatchConfidence::Possible
        }
    }
}

/// Reduce a MAC address to its bare lowercase hex digits, or `None` when the
/// string is not one.
///
/// The length check is what keeps Apple platforms out: CoreBluetooth reports a
/// per-host UUID in place of the address, and a UUID's hex digits strip to 32
/// rather than 12. Without it, every iOS device would be compared against the
/// OUI list as though its address meant something.
fn normalize_mac(raw: &str) -> Option<String> {
    strip_hex(raw).filter(|hex| hex.len() == 12)
}

/// Reduce a spec's MAC prefix to bare lowercase hex digits, or `None` when it
/// is not a usable 3-to-5-octet OUI. Deliberately stricter than "any hex":
/// a one-octet prefix would match a sixteenth of all hardware.
fn normalize_mac_prefix(raw: &str) -> Option<String> {
    strip_hex(raw).filter(|hex| (6..=10).contains(&hex.len()))
}

/// Drop `:`/`-` separators and lowercase, or `None` when what remains is not
/// pure hex. The shared step of both MAC normalizers; the length rule is what
/// distinguishes an address from a prefix, so it stays at each call site.
fn strip_hex(raw: &str) -> Option<String> {
    let hex: String = raw
        .chars()
        .filter(|c| *c != ':' && *c != '-')
        .map(|c| c.to_ascii_lowercase())
        .collect();
    hex.chars().all(|c| c.is_ascii_hexdigit()).then_some(hex)
}

/// Whether `value` starts with `prefix`, ASCII-case-insensitively.
///
/// The one prefix test both matchers use. Case-insensitive because BLE local
/// names and DNS names are ASCII and vendors are not consistent about casing
/// across firmware revisions (SmartDawn units advertise DN*-style names and the
/// vendor app itself filters them case-insensitively) — and DNS names are
/// case-insensitive by definition anyway. `get(..len)` rather than slicing so a
/// multi-byte value can't panic mid-char; a `None` there cannot equal an ASCII
/// prefix.
///
/// An empty prefix is treated as absent, not as a wildcard: an empty prefix
/// matches every name, so a spec carrying `local_name_prefix: ""` would
/// otherwise claim every scanned device.
fn name_has_prefix(value: &str, prefix: &str) -> bool {
    !prefix.is_empty()
        && value
            .get(..prefix.len())
            .is_some_and(|head| head.eq_ignore_ascii_case(prefix))
}

/// Compare one spec identity against one observation. The single place the
/// matching rules live — both public matchers go through it, so the post-connect
/// path and the scan path can never disagree about what "matched" means.
/// `device_mac` is the device's address already through [`normalize_mac`],
/// computed once by the caller: this runs per identity, and re-normalizing the
/// same address ~70 times per scanned device is the kind of waste a scan tick
/// notices.
fn match_axes(
    identity: &SpecIdentityDto,
    device: &ScannedDeviceDto,
    device_mac: Option<&str>,
) -> MatchAxes {
    // Any prefix matching is a match: the list holds the names one family ships
    // under, not names a device must carry all of.
    let by_name_prefix = identity
        .local_name_prefixes
        .iter()
        .any(|prefix| name_has_prefix(&device.name, prefix));

    // Return the lowercased intersection. Matches the docstring's contract and
    // gives Dart callers a predictable casing. We only allocate the lowercased
    // copy when a spec UUID actually matches; the per-element compare uses
    // `eq_ignore_ascii_case`.
    // Split as they are collected, on the same principle as the network side's
    // shared search targets: a UUID the SIG allocated identifies a capability
    // that any vendor may implement, so it belongs in the report but not in the
    // promotion rule.
    let mut service_uuids: Vec<String> = Vec::new();
    let mut shared_service_uuids: Vec<String> = Vec::new();
    for spec_uuid in &identity.service_uuids {
        let matched = device
            .service_uuids
            .iter()
            .any(|adv| adv.eq_ignore_ascii_case(spec_uuid));
        if !matched {
            continue;
        }
        let lowered = spec_uuid.to_ascii_lowercase();
        if is_sig_assigned_service(spec_uuid) {
            shared_service_uuids.push(lowered);
        } else {
            service_uuids.push(lowered);
        }
    }

    let company_ids: Vec<u16> = identity
        .company_ids
        .iter()
        .copied()
        .filter(|id| device.company_ids.contains(id))
        .collect();

    let mac_prefix = device_mac.and_then(|address| {
        // Best-first rather than first-declared: a spec listing both a
        // vetted block and a shared one should be judged on the vetted one
        // when the address is in it, regardless of declaration order.
        identity
            .mac_prefixes
            .iter()
            .filter(|entry| {
                normalize_mac_prefix(&entry.prefix)
                    .is_some_and(|normalized| address.starts_with(&normalized))
            })
            // `min_by_key` on the reversed key rather than `max_by_key`:
            // both pick the best, but only this one keeps the first of
            // several equally-good prefixes, so declaration order still
            // breaks ties deterministically.
            .min_by_key(|entry| std::cmp::Reverse(entry.confidence))
            .cloned()
    });

    MatchAxes {
        by_name_prefix,
        service_uuids,
        shared_service_uuids,
        company_ids,
        mac_prefix,
        ..MatchAxes::default()
    }
}

/// The Bluetooth SIG's GATT service registry, as vendored by the specs repo:
/// one `<short-uuid>\t<name>` line per assignment, sorted.
///
/// Compiled in rather than loaded, because this is consulted inside the match
/// loop and the answer can never depend on runtime state. Dart reads the same
/// file as an asset for its *naming* lookups; here only the key set matters.
const SIG_SERVICE_UUIDS: &str =
    include_str!("../../../vendor/protocol-specs/registries/bluetooth-service-uuids.tsv");

/// Whether `uuid` is a service the Bluetooth SIG defined, rather than one a
/// vendor allocated for its own product.
///
/// The BLE half of the rule [`is_shared_service_type`] states for the network.
/// A SIG service is a *capability*: 0x180F means the device reports a battery
/// level, 0x181A that it reports environmental readings, 0x1802 that it can be
/// told to beep. Every vendor implementing that capability advertises the same
/// UUID, so a spec declaring one is describing what its device does — useful to
/// report, worthless as proof of what it is. Left unsplit, three specs in the
/// catalogue turned it into a confident lie: any thermometer exposing 0x181A
/// was a Strong "Xiaomi LYWSD03MMC", any scale exposing 0x181D a Strong
/// "Xiaomi Mi Scale", any tag exposing 0x1802 a Strong "iTag BLE Key Finder".
///
/// Membership of the SIG registry is the test, not membership of the base UUID
/// range: 0xFFF0-0xFFFF sit in that range and are the unassigned values cheap
/// modules squat on, which are weak for a different reason (collision, not
/// standardisation) and are still the only identifier those devices have.
fn is_sig_assigned_service(uuid: &str) -> bool {
    let short = crate::protocol::profiles::normalize_uuid(uuid);
    // Only the 16-bit forms can be SIG assignments; anything else cannot
    // collide with a registry key, and skipping them keeps the scan short.
    if short.len() > 4 {
        return false;
    }
    let padded = format!("{:0>4}", short);
    SIG_SERVICE_UUIDS
        .lines()
        .any(|line| line.split('\t').next() == Some(padded.as_str()))
}

/// Compare one spec identity against one device seen on the local network.
///
/// Deliberately the same [`MatchAxes`] and therefore the same confidence rule
/// as the BLE path: an mDNS service type or an SSDP search target is a
/// vendor-specific identifier the device volunteered, which is the network
/// equivalent of a vendor service UUID. A declared `default_port` gates a spec
/// into this path but never becomes evidence within it -- port 80 tells you
/// nothing about who is listening on it.
/// `device_types` is `device.service_types` already through
/// [`normalize_service_type`], computed once by the caller for the same reason
/// [`match_axes`] takes the MAC pre-normalized: this runs per identity.
fn match_network_axes(
    identity: &SpecIdentityDto,
    device: &NetworkDeviceDto,
    device_types: &[String],
) -> MatchAxes {
    // A spec that declares nothing about the network cannot match a host on it.
    // Without this, any BLE spec whose local_name_prefix happened to prefix an
    // mDNS instance name would surface on the Wi-Fi tab -- the network analogue
    // of treating an empty prefix as a wildcard. The name prefix is a
    // corroborating signal here, never an admitting one.
    let declares_mdns = identity
        .mdns_service_type
        .as_ref()
        .is_some_and(|t| !t.is_empty());
    if !declares_mdns
        && identity.ssdp_search_targets.is_empty()
        && identity.lan_protocols.is_empty()
        && identity.default_port.is_none()
    {
        return MatchAxes::default();
    }

    let mut service_types: Vec<String> = Vec::new();
    let mut shared_service_types: Vec<String> = Vec::new();
    // Sorted into the bucket its genericness earns: a vendor's own type proves
    // a lot, one a whole category answers to proves nothing on its own.
    let mut record = |declared: &str, normalized: &str| {
        if is_shared_service_type(normalized) {
            shared_service_types.push(declared.to_string());
        } else {
            service_types.push(declared.to_string());
        }
    };

    if let Some(declared) = identity
        .mdns_service_type
        .as_ref()
        .filter(|t| !t.is_empty())
    {
        // Specs write `_hue._tcp.local.`, `_hue._tcp.local` and `_hue._tcp`
        // interchangeably, and so do devices. Compare on the trimmed stem so a
        // trailing-dot difference is not a missed device.
        let wanted = normalize_service_type(declared);
        if device_types.contains(&wanted) {
            record(declared, &wanted);
        }
    }
    for target in &identity.ssdp_search_targets {
        if device
            .ssdp_targets
            .iter()
            .any(|t| t.eq_ignore_ascii_case(target))
        {
            record(target, &normalize_service_type(target));
        }
    }

    // A vendor LAN protocol the device actually ANSWERED is a strong,
    // never-shared identifier — only a Kasa plug replies to the
    // tplink-smarthome probe — so it rides the same Strong tier a vendor
    // service type does, rather than needing its own axis.
    for protocol in &identity.lan_protocols {
        if device
            .answered_lan_protocols
            .iter()
            .any(|p| p.eq_ignore_ascii_case(protocol))
        {
            service_types.push(protocol.clone());
        }
    }

    // The spec's local name prefixes do double duty here: on the network side a
    // device's instance name or hostname is what carries the vendor's branding
    // (`Lutron-083e013d.local`), the same way a BLE local name does.
    let by_name_prefix = identity.local_name_prefixes.iter().any(|prefix| {
        name_has_prefix(&device.name, prefix)
            || device
                .hostname
                .as_deref()
                .is_some_and(|h| name_has_prefix(h, prefix))
    });

    MatchAxes {
        by_name_prefix,
        service_types,
        shared_service_types,
        ..MatchAxes::default()
    }
}

/// Whether a network identifier is answered by a whole category of hardware
/// rather than by one vendor's product.
///
/// The network counterpart of [`MacPrefixConfidence::Low`], and it exists for
/// the same reason: an identifier that many unrelated devices volunteer ranks a
/// device, it does not name one. Without this, a spec declaring
/// `upnp:rootdevice` matched every router, printer and NAS on the link at the
/// top confidence tier, and the Wi-Fi tab badged them with that spec's product
/// name.
///
/// A fixed list rather than a spec-declared flag, deliberately: these are
/// published, standard identifiers whose generic-ness is a property of the
/// protocol and not of any one device, so it should not be restated (or
/// forgotten) per spec. Compared on the [`normalize_service_type`] stem, so
/// `_hap._tcp.local.` and `_hap._tcp` are the same entry.
fn is_shared_service_type(normalized: &str) -> bool {
    matches!(
        normalized,
        // UPnP boilerplate: the root-device and basic-device announcements
        // every SSDP responder sends, plus the wildcard search target.
        "upnp:rootdevice"
            | "ssdp:all"
            | "urn:schemas-upnp-org:device:basic:1"
            // Whole-ecosystem DNS-SD types. HomeKit and AirPlay in particular
            // cover hundreds of unrelated products.
            | "_hap._tcp"
            | "_airplay._tcp"
            | "_raop._tcp"
            | "_companion-link._tcp"
            | "_googlecast._tcp"
            // "It speaks HTTP" and "it is a printer" are categories, not
            // products.
            | "_http._tcp"
            | "_https._tcp"
            | "_ipp._tcp"
            | "_ipps._tcp"
            | "_printer._tcp"
            | "_pdl-datastream._tcp"
            | "_workstation._tcp"
            | "_device-info._tcp"
            | "_services._dns-sd._udp"
    )
}

/// Reduce a DNS-SD service type to a comparable stem: lowercase, no trailing
/// dot, no `.local` suffix.
fn normalize_service_type(raw: &str) -> String {
    let lower = raw.trim().trim_end_matches('.').to_ascii_lowercase();
    lower
        .strip_suffix(".local")
        .map(str::to_owned)
        .unwrap_or(lower)
}

/// Find every spec matching a device we are already talking to, with the
/// reasons it matched.
///
/// This is the post-connect path: `advertised_service_uuids` is expected to
/// carry the GATT services actually discovered on the device, which is a far
/// richer list than anything an advertisement fits in. For ranking devices
/// during a scan, use [`match_scanned_device`] instead — it takes the weaker
/// pre-connect signals too, and does not need the whole catalogue pushed across
/// the FFI boundary.
///
/// Returns `vec![]` when nothing matches. A spec matches when:
/// - its `local_name_prefix` is a prefix of `device_name`, **or**
/// - any of its `service_uuids` (case-insensitive) appears in `advertised_service_uuids`.
///
/// Both axes are reported separately so the caller can decide how to rank.
pub fn match_device_to_spec(
    specs: Vec<DeviceSpecDto>,
    device_name: String,
    advertised_service_uuids: Vec<String>,
) -> Vec<MatchResult> {
    let device = ScannedDeviceDto {
        name: device_name,
        service_uuids: advertised_service_uuids,
        // Neither is observable on this path — it runs against a connected
        // device, where the advertisement is long gone.
        company_ids: Vec::new(),
        mac_address: None,
    };
    specs
        .into_iter()
        .filter_map(|spec| {
            let axes = match_axes(&SpecIdentityDto::from(&spec), &device, None);
            // Built before the struct moves the axes apart.
            let matched_service_uuids = axes.all_service_uuids();
            (!axes.is_empty()).then(|| MatchResult {
                spec,
                matched_by_name_prefix: axes.by_name_prefix,
                confidence: axes.confidence(),
                matched_service_uuids,
            })
        })
        .collect()
}

/// Rank the catalogue against a single device found on the local network, best
/// match first.
///
/// The Wi-Fi counterpart of [`match_scanned_device`], sharing its confidence
/// rule so a "Likely supported" badge means the same thing on both tabs.
/// Returns `vec![]` when nothing matches.
pub fn match_network_device(
    identities: Vec<SpecIdentityDto>,
    device: NetworkDeviceDto,
) -> Vec<ScanMatch> {
    // Normalized once here, not per identity — see match_network_axes.
    let device_types: Vec<String> = device
        .service_types
        .iter()
        .map(|t| normalize_service_type(t))
        .collect();
    rank_matches(&identities, |identity| {
        match_network_axes(identity, &device, &device_types)
    })
}

/// The shared tail of both scan matchers: run the axes function over the
/// catalogue, keep what matched, and sort best-first — confidence, then how
/// many volunteered identifiers (service UUIDs on BLE, service types on the
/// network; each path only ever populates its own) agreed, then spec order so
/// the result is stable for a given catalogue rather than depending on sort
/// implementation details.
fn rank_matches(
    identities: &[SpecIdentityDto],
    axes_for: impl Fn(&SpecIdentityDto) -> MatchAxes,
) -> Vec<ScanMatch> {
    let mut matches: Vec<ScanMatch> = identities
        .iter()
        .enumerate()
        .filter_map(|(index, identity)| {
            let axes = axes_for(identity);
            // Built before the struct moves the axes apart.
            let matched_service_types = axes.all_service_types();
            let matched_service_uuids = axes.all_service_uuids();
            (!axes.is_empty()).then(|| ScanMatch {
                spec_index: index as u32,
                device_name: identity.device_name.clone(),
                manufacturer: identity.manufacturer.clone(),
                category: identity.category.clone(),
                confidence: axes.confidence(),
                matched_by_name_prefix: axes.by_name_prefix,
                matched_service_uuids,
                matched_company_ids: axes.company_ids,
                matched_mac_prefix: axes.mac_prefix,
                matched_service_types,
            })
        })
        .collect();

    matches.sort_by(|a, b| {
        let volunteered =
            |m: &ScanMatch| m.matched_service_uuids.len() + m.matched_service_types.len();
        b.confidence
            .cmp(&a.confidence)
            .then(volunteered(b).cmp(&volunteered(a)))
            .then(a.spec_index.cmp(&b.spec_index))
    });
    matches
}

/// Rank the catalogue against a single device seen during a scan, best match
/// first.
///
/// Takes identities rather than whole specs because this runs per newly-seen
/// device during a scan: sending 70-odd fully parsed specs across the FFI
/// boundary each time would cost far more than the matching itself.
///
/// Returns `vec![]` when nothing matches. Read `confidence` before doing
/// anything with a result — a [`MatchConfidence::Possible`] match is one shared
/// OUI and says only that the device is worth a human's attention, not that the
/// spec describes it.
pub fn match_scanned_device(
    identities: Vec<SpecIdentityDto>,
    device: ScannedDeviceDto,
) -> Vec<ScanMatch> {
    // Normalized once here, not per identity — see match_axes.
    let device_mac = device.mac_address.as_deref().and_then(normalize_mac);
    rank_matches(&identities, |identity| {
        match_axes(identity, &device, device_mac.as_deref())
    })
}

/// Encode a named command into bytes for a BLE write.
///
/// Provide either `spec_yaml` (custom device) or `service_uuid` (standard
/// profile — though standard profiles are read-only). When both are supplied,
/// the spec wins — see [`select_protocol`].
pub fn encode_command(
    spec_yaml: Option<String>,
    service_uuid: Option<String>,
    char_uuid: String,
    command_name: String,
    params: HashMap<String, f64>,
) -> anyhow::Result<Vec<u8>> {
    // With a spec AND a service, the lookup is confined to that service:
    // characteristic UUIDs repeat across services with different command
    // tables, and a caller naming both halves of the pair (the group runner)
    // must get the pair it named. Spec-only keeps the historical whole-spec
    // search; service-only still selects a standard profile.
    if let (Some(yaml), Some(service)) = (spec_yaml.as_deref(), &service_uuid) {
        let spec = crate::protocol::dispatch::parse_or_cached(yaml)?;
        let proto = crate::protocol::generic::GenericProtocol::scoped(spec, Some(service.clone()));
        return Ok(proto.encode_command(&char_uuid, &command_name, &params)?);
    }
    let proto = select_protocol(spec_yaml.as_deref(), service_uuid.as_deref())?;
    Ok(proto.encode_command(&char_uuid, &command_name, &params)?)
}

/// Encode one RGB888 frame into the ordered BLE writes that display it,
/// dispatched on the spec's `protocol_handler`.
///
/// `rgb` is row-major, length `width * height * 3`. `frame_index` sequences
/// consecutive frames of an animation (wire serials derive from it), and
/// `max_payload_per_write` is the usable bytes per BLE write (negotiated ATT
/// MTU - 3; pass 20 when the MTU is unknown). Errors are typed and
/// user-presentable: an unknown or missing handler says so instead of
/// producing bytes that were never going to work.
pub fn encode_image_frame(
    spec_yaml: String,
    width: u32,
    height: u32,
    rgb: Vec<u8>,
    frame_index: u32,
    max_payload_per_write: u32,
) -> anyhow::Result<ImageWritePlanDto> {
    // Streaming calls this once per frame with the same YAML, so parse
    // through the same bounded cache encode_command/decode_value use — a
    // cache hit instead of a full re-parse per frame.
    let spec = crate::protocol::dispatch::parse_or_cached(&spec_yaml)?;
    let Some(handler_name) = spec.protocol_handler.as_deref() else {
        return Err(crate::error::ProtocolError::ImageUploadUnsupported {
            reason: "the device spec declares no protocol_handler".to_string(),
        }
        .into());
    };
    let Some(handler) = crate::protocol::image_upload_handler(handler_name) else {
        return Err(crate::error::ProtocolError::ImageUploadUnsupported {
            reason: format!("protocol handler '{handler_name}' has no encoder in this build"),
        }
        .into());
    };
    let frame = (handler.encode)(
        &spec,
        &rgb,
        width,
        height,
        frame_index,
        max_payload_per_write as usize,
    )?;
    Ok(ImageWritePlanDto {
        service_uuid: handler.service_uuid.to_string(),
        next_frame_index: frame_index.wrapping_add(frame.packets),
        writes: frame
            .writes
            .into_iter()
            .map(|w| ImageWriteDto {
                characteristic_uuid: w.characteristic_uuid,
                bytes: w.bytes,
            })
            .collect(),
    })
}

/// Encode the BLE writes that PERSIST a picture on the device so it plays
/// standalone after disconnect, dispatched on the spec's `stored_upload`
/// feature.
///
/// `rgb` is the canvas, row-major `width * height * 3`, already reduced to at
/// most 16 distinct colours (the editor quantises before calling). `name` is
/// the label stored on the device, `cid` the id it is stored under (novel ids
/// are accepted), `time_secs` the run/scroll duration, `scroll` one of
/// `none`/`left`/`right`/`up`/`down`, and `speed` the scroll-speed byte.
///
/// Returns the ordered Uploader-characteristic writes plus, when the spec
/// declares a `play_command`, a fragment-framed write that plays the item
/// immediately. Errors are typed and user-presentable.
// The flat argument list is the FFI surface flutter_rust_bridge exposes to
// Dart; grouping into a struct would churn the generated bindings.
#[allow(clippy::too_many_arguments)]
pub fn encode_stored_image(
    spec_yaml: String,
    width: u32,
    height: u32,
    rgb: Vec<u8>,
    name: String,
    cid: u32,
    time_secs: u32,
    scroll: String,
    speed: u32,
    sequence: u32,
) -> anyhow::Result<StoredUploadPlanDto> {
    use crate::protocol::daniao_store::{ImageLayer, StoredProgram};
    let spec = crate::protocol::dispatch::parse_or_cached(&spec_yaml)?;
    let program = StoredProgram {
        name: &name,
        cid,
        time_secs,
        scroll: scroll_from_str(&scroll),
        // The scroll-speed byte is a small slider value; clamp defensively so a
        // stray large value can't wrap when narrowed to the wire's u8.
        speed: speed.min(u8::MAX as u32) as u8,
        image: ImageLayer {
            width,
            height,
            rgb: &rgb,
        },
    };
    let plan =
        crate::protocol::stored_upload::encode_stored_image(&spec, &program, sequence as u16)?;
    Ok(stored_plan_to_dto(plan))
}

/// Encode the BLE writes that PERSIST a scrolling-text marquee on the device.
///
/// `bits` is the rendered text bitmap — one byte per pixel (`0` off, non-zero
/// lit), row-major, `text_width * text_height` bytes. The width is usually
/// wider than the panel so the text scrolls. The caller (the UI) rasterises the
/// string; everything else matches [`encode_stored_image`].
#[allow(clippy::too_many_arguments)]
pub fn encode_stored_text(
    spec_yaml: String,
    text_width: u32,
    text_height: u32,
    bits: Vec<u8>,
    name: String,
    cid: u32,
    time_secs: u32,
    scroll: String,
    speed: u32,
    sequence: u32,
) -> anyhow::Result<StoredUploadPlanDto> {
    use crate::protocol::daniao_store::{StoredText, TextContent};
    let spec = crate::protocol::dispatch::parse_or_cached(&spec_yaml)?;
    let program = StoredText {
        name: &name,
        cid,
        time_secs,
        scroll: scroll_from_str(&scroll),
        speed: speed.min(u8::MAX as u32) as u8,
        text: TextContent {
            width: text_width,
            height: text_height,
            bits: &bits,
        },
    };
    let plan =
        crate::protocol::stored_upload::encode_stored_text(&spec, &program, sequence as u16)?;
    Ok(stored_plan_to_dto(plan))
}

/// Encode the BLE writes that PERSIST a multi-frame animation as a single
/// `.eff` container.
///
/// UNTESTED / DORMANT on the JY25CUT curtain: hardware confirms a `.eff`
/// commits but never registers as a playable effect there (see
/// `daniao_store::build_animation_container`). Kept for the vendor's matrix
/// panels and a future dedicated capture; the curtain's animation path is the
/// cycling-stills loop (`encode_stored_image` per frame + `encode_set_playlist`
/// + `play_next`), NOT this.
///
/// `frames` are the screens in play order, each row-major RGB888
/// `width * height * 3` bytes.
pub fn encode_stored_animation(
    spec_yaml: String,
    width: u32,
    height: u32,
    frames: Vec<Vec<u8>>,
    name: String,
    cid: u32,
    frame_ms: u32,
    sequence: u32,
) -> anyhow::Result<StoredUploadPlanDto> {
    use crate::protocol::daniao_store::StoredAnimation;
    let spec = crate::protocol::dispatch::parse_or_cached(&spec_yaml)?;
    let frame_refs: Vec<&[u8]> = frames.iter().map(Vec::as_slice).collect();
    // The container carries a fixed cadence constant (see `build_animation_container`),
    // so `frame_ms` no longer feeds the header. It is retained on the FFI so the
    // caller can drive a separate `set_play_speed` command without a signature
    // churn once that path is wired.
    let _ = frame_ms;
    // The DNMX header stamps wall-clock seconds; the device appears to key on a
    // non-zero value. Fall back to 0 only if the clock is somehow before the
    // epoch (it never is), which the builder tolerates.
    let timestamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as u32)
        .unwrap_or(0);
    let anim = StoredAnimation {
        name: &name,
        cid,
        width,
        height,
        frames: &frame_refs,
        timestamp,
    };
    let plan =
        crate::protocol::stored_upload::encode_stored_animation(&spec, &anim, sequence as u16)?;
    Ok(stored_plan_to_dto(plan))
}

/// Decode one notification from the stored-upload response characteristic.
///
/// Returns `None` for anything that is not an upload event — other state
/// pushes share the channel, and a caller filters by just ignoring `None`.
/// The spec is taken so this dispatches like the encoders do; today the one
/// implemented response format is Daniao's.
pub fn decode_stored_upload_event(
    spec_yaml: String,
    bytes: Vec<u8>,
) -> anyhow::Result<Option<StoredUploadEventDto>> {
    use crate::protocol::daniao_upload::{parse_upload_event, UploadEvent};
    let spec = crate::protocol::dispatch::parse_or_cached(&spec_yaml)?;
    if crate::protocol::stored_upload::stored_feature(&spec).is_none() {
        anyhow::bail!("spec declares no stored_upload feature");
    }
    Ok(parse_upload_event(&bytes).map(|event| match event {
        UploadEvent::StartAccepted { resume_offset } => StoredUploadEventDto {
            kind: StoredUploadEventKind::StartAccepted,
            code: 0,
            resume_offset,
            progress: 0,
        },
        UploadEvent::StartRejected { code } => StoredUploadEventDto {
            kind: StoredUploadEventKind::StartRejected,
            code,
            resume_offset: 0,
            progress: 0,
        },
        UploadEvent::Progress { value } => StoredUploadEventDto {
            kind: StoredUploadEventKind::Progress,
            code: 0,
            resume_offset: 0,
            progress: value,
        },
        UploadEvent::Complete => StoredUploadEventDto {
            kind: StoredUploadEventKind::Complete,
            code: 0,
            resume_offset: 0,
            progress: 0,
        },
        UploadEvent::Failed { code } => StoredUploadEventDto {
            kind: StoredUploadEventKind::Failed,
            code,
            resume_offset: 0,
            progress: 0,
        },
    }))
}

/// Encode the play-by-cid command for RE-triggering a previously stored item
/// — the replay path, no upload involved. `sequence` is a per-connection
/// rolling counter (Dart owns it); a distinct value each press keeps two
/// replays of the same cid from colliding on the wire and being de-duped.
pub fn encode_stored_play(
    spec_yaml: String,
    cid: u32,
    sequence: u32,
) -> anyhow::Result<StoredPlayDto> {
    let spec = crate::protocol::dispatch::parse_or_cached(&spec_yaml)?;
    let (service_uuid, write) =
        crate::protocol::stored_upload::encode_stored_play(&spec, cid, sequence as u16)?;
    Ok(StoredPlayDto {
        service_uuid,
        write: ImageWriteDto {
            characteristic_uuid: write.characteristic_uuid,
            bytes: write.bytes,
        },
    })
}

/// Encode the global play-speed command (M_SET_PLAY_SPEED, `{i1: speed}`) —
/// how fast the device advances the playlist. `speed` is the vendor's slider
/// value (default 100). Returns the framed write to send.
pub fn encode_play_speed(
    spec_yaml: String,
    speed: u32,
    sequence: u32,
) -> anyhow::Result<StoredPlayDto> {
    let spec = crate::protocol::dispatch::parse_or_cached(&spec_yaml)?;
    let (service_uuid, write) =
        crate::protocol::stored_upload::encode_play_speed(&spec, speed, sequence as u16)?;
    Ok(StoredPlayDto {
        service_uuid,
        write: ImageWriteDto {
            characteristic_uuid: write.characteristic_uuid,
            bytes: write.bytes,
        },
    })
}

/// Encode the play/loop-mode command (M_SET_AUTORUN_MODE). `mode` is
/// `fixed(0) | repeat(1) | random(2)`. Sending fixed after playing a design
/// pins the device to it across disconnect.
pub fn encode_autorun_mode(
    spec_yaml: String,
    mode: u32,
    sequence: u32,
) -> anyhow::Result<StoredPlayDto> {
    let spec = crate::protocol::dispatch::parse_or_cached(&spec_yaml)?;
    let (service_uuid, write) =
        crate::protocol::stored_upload::encode_autorun_mode(&spec, mode, sequence as u16)?;
    Ok(StoredPlayDto {
        service_uuid,
        write: ImageWriteDto {
            characteristic_uuid: write.characteristic_uuid,
            bytes: write.bytes,
        },
    })
}

/// Encode M_BOOKMARK_ENABLE — activate bookmark/playlist `list_id` so the device
/// plays only its items (without this, playback stays over the whole stored set).
pub fn encode_bookmark_enable(
    spec_yaml: String,
    list_id: u32,
    sequence: u32,
) -> anyhow::Result<StoredPlayDto> {
    let spec = crate::protocol::dispatch::parse_or_cached(&spec_yaml)?;
    let (service_uuid, write) =
        crate::protocol::stored_upload::encode_bookmark_enable(&spec, list_id, sequence as u16)?;
    Ok(StoredPlayDto {
        service_uuid,
        write: ImageWriteDto {
            characteristic_uuid: write.characteristic_uuid,
            bytes: write.bytes,
        },
    })
}

/// Encode M_BOOKMARK_CLEAR — empty bookmark/playlist `list_id` before a re-save.
pub fn encode_bookmark_clear(
    spec_yaml: String,
    list_id: u32,
    sequence: u32,
) -> anyhow::Result<StoredPlayDto> {
    let spec = crate::protocol::dispatch::parse_or_cached(&spec_yaml)?;
    let (service_uuid, write) =
        crate::protocol::stored_upload::encode_bookmark_clear(&spec, list_id, sequence as u16)?;
    Ok(StoredPlayDto {
        service_uuid,
        write: ImageWriteDto {
            characteristic_uuid: write.characteristic_uuid,
            bytes: write.bytes,
        },
    })
}

/// Encode the delete-one-stored-design command (M_REMOVE_APP) by cid.
pub fn encode_remove_app(
    spec_yaml: String,
    cid: u32,
    sequence: u32,
) -> anyhow::Result<StoredPlayDto> {
    let spec = crate::protocol::dispatch::parse_or_cached(&spec_yaml)?;
    let (service_uuid, write) =
        crate::protocol::stored_upload::encode_remove_app(&spec, cid, sequence as u16)?;
    Ok(StoredPlayDto {
        service_uuid,
        write: ImageWriteDto {
            characteristic_uuid: write.characteristic_uuid,
            bytes: write.bytes,
        },
    })
}

/// Encode the clear-all-stored-designs command (M_REMOVE_ALL_APPS).
pub fn encode_remove_all_apps(
    spec_yaml: String,
    sequence: u32,
) -> anyhow::Result<StoredPlayDto> {
    let spec = crate::protocol::dispatch::parse_or_cached(&spec_yaml)?;
    let (service_uuid, write) =
        crate::protocol::stored_upload::encode_remove_all_apps(&spec, sequence as u16)?;
    Ok(StoredPlayDto {
        service_uuid,
        write: ImageWriteDto {
            characteristic_uuid: write.characteristic_uuid,
            bytes: write.bytes,
        },
    })
}

/// Decode one M_EFFECT_LIST notification into its `{cid, slot}` entries.
///
/// The device answers a list request with several framed notifications; the
/// caller decodes each and merges them to map a stored frame's cid to the slot
/// a playlist must use. A notification that is not an effect list yields an
/// empty list.
pub fn decode_effect_list(spec_yaml: String, bytes: Vec<u8>) -> anyhow::Result<Vec<EffectEntryDto>> {
    let spec = crate::protocol::dispatch::parse_or_cached(&spec_yaml)?;
    // Taken for symmetry with the other decoders and to fail loudly on a spec
    // that could never produce this notification.
    if crate::protocol::stored_upload::stored_feature(&spec).is_none() {
        anyhow::bail!("spec declares no stored_upload feature");
    }
    Ok(crate::protocol::daniao_upload::parse_effect_list(&bytes)
        .into_iter()
        .map(|e| EffectEntryDto {
            cid: e.cid,
            slot: e.slot,
            type_: e.type_,
            diy: e.diy,
        })
        .collect())
}

/// Encode the writes that loop a set of stored frames as an animation: the
/// set-playlist command then loop mode. `cids` and `slots` are the stored
/// frames in play order (paired by index); `slots` are the device-assigned
/// slots (pass 0 when unknown — play addresses customs by cid). `sequence` is
/// the rolling counter's next value.
pub fn encode_set_playlist(
    spec_yaml: String,
    cids: Vec<u32>,
    slots: Vec<u32>,
    sequence: u32,
) -> anyhow::Result<PlaylistWritesDto> {
    use crate::protocol::stored_upload::{encode_set_playlist, PlaylistItem};
    let spec = crate::protocol::dispatch::parse_or_cached(&spec_yaml)?;
    let items: Vec<PlaylistItem> = cids
        .iter()
        .enumerate()
        .map(|(i, &cid)| PlaylistItem {
            cid,
            slot: slots.get(i).copied().unwrap_or(0),
        })
        .collect();
    let (service_uuid, writes) = encode_set_playlist(&spec, &items, sequence as u16)?;
    Ok(PlaylistWritesDto {
        service_uuid,
        writes: writes
            .into_iter()
            .map(|w| ImageWriteDto {
                characteristic_uuid: w.characteristic_uuid,
                bytes: w.bytes,
            })
            .collect(),
    })
}

/// Parse the FFI `scroll` string into the codec's enum (unknown -> no scroll).
fn scroll_from_str(scroll: &str) -> crate::protocol::daniao_store::Scroll {
    use crate::protocol::daniao_store::Scroll;
    match scroll {
        "left" => Scroll::Left,
        "right" => Scroll::Right,
        "up" => Scroll::Up,
        "down" => Scroll::Down,
        _ => Scroll::None,
    }
}

/// Map a protocol-layer stored-upload plan onto its FFI DTO.
fn stored_plan_to_dto(
    plan: crate::protocol::stored_upload::StoredUploadPlan,
) -> StoredUploadPlanDto {
    let to_dto = |w: crate::protocol::EncodedWrite| ImageWriteDto {
        characteristic_uuid: w.characteristic_uuid,
        bytes: w.bytes,
    };
    StoredUploadPlanDto {
        service_uuid: plan.service_uuid,
        upload_writes: plan.upload_writes.into_iter().map(to_dto).collect(),
        play_write: plan.play_write.map(to_dto),
        response_characteristic_uuid: plan.response_characteristic_uuid,
        cid: plan.cid,
    }
}

/// Decode raw bytes from a BLE read/notify into named values.
///
/// Provide either `spec_yaml` (custom device) or `service_uuid` (standard
/// profile). When both are supplied, the spec wins — see [`select_protocol`].
pub fn decode_value(
    spec_yaml: Option<String>,
    service_uuid: Option<String>,
    char_uuid: String,
    bytes: Vec<u8>,
) -> anyhow::Result<Vec<DecodedValueDto>> {
    let proto = select_protocol(spec_yaml.as_deref(), service_uuid.as_deref())?;
    let decoded = proto.decode_value(&char_uuid, &bytes)?;
    // Presentation metadata is looked up by field name rather than by position:
    // `decode_all_fields` collapses a repeated field name into one entry, so the
    // two lists are not guaranteed to line up index for index.
    let meta = proto.field_meta_for_characteristic(&char_uuid);
    Ok(decoded
        .iter()
        .map(|(name, value)| {
            let mut dto = DecodedValueDto::from((name.as_str(), value));
            if let Some(m) = meta.iter().find(|m| &m.name == name) {
                dto.scale = m.scale;
                dto.value_offset = m.value_offset;
                dto.unit = m.unit.clone();
                dto.unit_source = m.unit_source.clone();
                // Enumerated fields are looked up by the raw integer the
                // device sent, rendered decimal to match the normalized
                // table keys.
                dto.value_label = m.values.as_ref().and_then(|table| {
                    let raw = dto.int_value.or(dto.uint_value)?;
                    table.get(&raw.to_string()).cloned()
                });
            }
            dto
        })
        .collect())
}

// ── Standard profile types and API ─────────────────────────────────────────

/// Info about a recognized standard Bluetooth profile.
#[derive(Debug, Clone)]
pub struct ProfileInfoDto {
    pub service_uuid: String,
    pub profile_name: String,
    pub characteristics: Vec<ProfileCharacteristicDto>,
}

/// A characteristic within a standard profile.
#[derive(Debug, Clone)]
pub struct ProfileCharacteristicDto {
    pub uuid: String,
    pub name: String,
    pub can_read: bool,
    pub can_write: bool,
    pub can_notify: bool,
}

/// Given a list of discovered service UUIDs, return info about any that
/// match recognized standard Bluetooth profiles (Battery, Device Info, etc.).
///
/// Services that don't match a standard profile are omitted from the result.
pub fn identify_standard_profiles(service_uuids: Vec<String>) -> Vec<ProfileInfoDto> {
    service_uuids
        .iter()
        .filter_map(|uuid| {
            profiles::lookup(uuid).map(|profile| ProfileInfoDto {
                // Lowercased for the same reason `match_device_to_spec`
                // lowercases its matched UUIDs: Dart callers get one
                // predictable casing regardless of what the platform's
                // scanner reported.
                service_uuid: uuid.to_ascii_lowercase(),
                profile_name: profile.name().to_string(),
                characteristics: profile
                    .characteristics()
                    .into_iter()
                    .map(|c| ProfileCharacteristicDto {
                        uuid: c.uuid,
                        name: c.name,
                        can_read: c.can_read,
                        can_write: c.can_write,
                        can_notify: c.can_notify,
                    })
                    .collect(),
            })
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    const TEST_YAML: &str = r#"
device:
  name: "Test Bulb"
  manufacturer: "Test"
  manufacturer_status: "abandoned"
  protocol: "ble"
  identification:
    local_name_prefix: "TEST_"
    service_uuids:
      - "0000fff0-0000-1000-8000-00805f9b34fb"
services:
  - uuid: "0000fff0-0000-1000-8000-00805f9b34fb"
    name: "Control"
    characteristics:
      - uuid: "0000fff1-0000-1000-8000-00805f9b34fb"
        name: "Command"
        properties: ["write"]
        commands:
          power_on:
            description: "Turn on"
            value: [0x01, 0x01]
      - uuid: "0000fff2-0000-1000-8000-00805f9b34fb"
        name: "Status"
        properties: ["read", "notify"]
        format:
          - offset: 0
            length: 1
            name: "power_state"
            type: "bool"
          - offset: 1
            length: 1
            name: "brightness"
            type: "uint8"
"#;

    /// Spec commands/parameters are stored in IndexMaps that preserve YAML
    /// declaration order, and the DTO boundary must carry that order through
    /// to the UI untouched — the assertions below check declaration order,
    /// nothing sorted and nothing reconstructed from the template.
    /// Deliberately adversarial ordering, and deliberately wide.
    ///
    /// The six commands are declared in an order that is neither alphabetical
    /// nor reverse-alphabetical, and set_color's five parameters are declared
    /// blue, red, green, unused, gamma — NOT the order the template references
    /// them, and including two the template never mentions. Anything that
    /// sorts, or that reconstructs order from the template, gets a different
    /// answer than the spec author wrote.
    ///
    /// The width matters as much as the shuffle: with two or three entries a
    /// regression to `HashMap` would still land on the expected order often
    /// enough to flake rather than fail. Six commands is 720 permutations and
    /// five parameters is 120, so losing document order fails every run.
    const ORDERING_YAML: &str = r#"
device:
  name: "Ordering"
  manufacturer: "Test"
  manufacturer_status: "abandoned"
  protocol: "ble"
services:
  - uuid: "0000fff0-0000-1000-8000-00805f9b34fb"
    name: "Control"
    characteristics:
      - uuid: "0000fff1-0000-1000-8000-00805f9b34fb"
        name: "Command"
        properties: ["write"]
        commands:
          set_color:
            description: "Set RGB"
            template: [0x03, "{red}", "{green}", "{blue}"]
            parameters:
              blue: { type: "uint8", min: 0, max: 255 }
              red: { type: "uint8", min: 0, max: 255 }
              green: { type: "uint8", min: 0, max: 255 }
              unused: { type: "uint8", min: 0, max: 255 }
              gamma: { type: "uint8", min: 0, max: 255 }
          power_on:
            description: "On"
            value: [0x01, 0x01]
          power_off:
            description: "Off"
            value: [0x01, 0x00]
          zone_reset:
            description: "Reset zones"
            value: [0x04, 0x00]
          alarm_test:
            description: "Test the alarm"
            value: [0x05, 0x01]
          fade_stop:
            description: "Stop fading"
            value: [0x06, 0x00]
"#;

    #[test]
    fn commands_and_parameters_keep_declaration_order() {
        let dto = load_device_spec(ORDERING_YAML.into()).unwrap();
        let commands = &dto.services[0].characteristics[0].commands;

        let names: Vec<&str> = commands.iter().map(|c| c.name.as_str()).collect();
        assert_eq!(
            names,
            [
                "set_color",
                "power_on",
                "power_off",
                "zone_reset",
                "alarm_test",
                "fade_stop"
            ],
            "commands must come back in the order the YAML declares them"
        );

        let set_color = commands.iter().find(|c| c.name == "set_color").unwrap();
        let params: Vec<&str> = set_color
            .parameters
            .iter()
            .map(|p| p.name.as_str())
            .collect();
        assert_eq!(
            params,
            ["blue", "red", "green", "unused", "gamma"],
            "parameters must come back in declaration order — not sorted, and \
             not reconstructed from the template (which would say red, green, \
             blue and could not place `unused`/`gamma` at all)"
        );
    }

    /// Order has to be stable across processes too, not just within one: the
    /// bug this guards against was a hash seed leaking into the UI, which only
    /// shows up as a *different* order on the next launch.
    #[test]
    fn ordering_is_stable_across_repeated_parses() {
        let baseline = load_device_spec(ORDERING_YAML.into()).unwrap();
        let expected: Vec<String> = baseline.services[0].characteristics[0]
            .commands
            .iter()
            .map(|c| c.name.clone())
            .collect();

        for _ in 0..16 {
            let again = load_device_spec(ORDERING_YAML.into()).unwrap();
            let names: Vec<String> = again.services[0].characteristics[0]
                .commands
                .iter()
                .map(|c| c.name.clone())
                .collect();
            assert_eq!(names, expected);
        }
    }

    /// The bundled spec the mock devices match, read from the app's real asset
    /// directory. A synthetic YAML can drift from what actually ships; this
    /// pins the order a user sees on the device screen.
    #[test]
    fn bundled_example_bulb_keeps_declaration_order() {
        let path = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .expect("rust crate should have a parent repo dir")
            .join("vendor/protocol-specs/device-specs/examples/example-bulb.yaml");
        let yaml = std::fs::read_to_string(&path)
            .unwrap_or_else(|e| panic!("reading {}: {e}", path.display()));

        let dto = load_device_spec(yaml).unwrap();
        let control = dto
            .services
            .iter()
            .find(|s| s.name == "Control Service")
            .expect("example-bulb declares a Control Service");
        let command_char = control
            .characteristics
            .iter()
            .find(|c| c.name == "Command")
            .expect("Control Service declares a Command characteristic");

        let names: Vec<&str> = command_char
            .commands
            .iter()
            .map(|c| c.name.as_str())
            .collect();
        assert_eq!(
            names,
            ["power_on", "power_off", "set_brightness", "set_color"],
            "must match the order example-bulb.yaml declares"
        );

        let set_color = command_char
            .commands
            .iter()
            .find(|c| c.name == "set_color")
            .unwrap();
        let params: Vec<&str> = set_color
            .parameters
            .iter()
            .map(|p| p.name.as_str())
            .collect();
        assert_eq!(params, ["red", "green", "blue"]);

        // Format fields are a Vec in the spec, so they were already ordered;
        // assert it so a future refactor cannot quietly reorder them either.
        let status = control
            .characteristics
            .iter()
            .find(|c| c.name == "Status")
            .expect("Control Service declares a Status characteristic");
        let fields: Vec<&str> = status
            .format_fields
            .iter()
            .map(|f| f.name.as_str())
            .collect();
        assert_eq!(
            fields,
            ["power_state", "brightness", "red", "green", "blue"]
        );
    }

    #[test]
    fn load_spec_dto() {
        let dto = load_device_spec(TEST_YAML.into()).unwrap();
        assert_eq!(dto.device_name, "Test Bulb");
        assert_eq!(dto.manufacturer_status, "abandoned");
        assert_eq!(dto.protocol, "ble");
        assert_eq!(dto.services.len(), 1);
        assert_eq!(dto.services[0].characteristics.len(), 2);

        let cmd_char = &dto.services[0].characteristics[0];
        assert!(cmd_char.can_write);
        assert!(!cmd_char.can_read);
        assert_eq!(cmd_char.commands.len(), 1);
        assert_eq!(cmd_char.commands[0].name, "power_on");
        assert!(cmd_char.commands[0].is_fixed);
        // A command that declares neither key is not advanced, and its
        // parameters carry no transform/auto metadata.
        assert!(!cmd_char.commands[0].advanced);
        assert_eq!(cmd_char.commands[0].advanced_reason, None);
    }

    /// The new parameter/command semantics must cross the DTO boundary
    /// verbatim: the UI renders a speed slider in km/h and hides the
    /// checksum byte from the user entirely based on these fields.
    const TREADMILL_YAML: &str = r#"
device:
  name: "Test Treadmill"
  manufacturer: "Test"
  manufacturer_status: "active"
  protocol: "ble"
services:
  - uuid: "0000fff0-0000-1000-8000-00805f9b34fb"
    name: "Control"
    characteristics:
      - uuid: "0000fff1-0000-1000-8000-00805f9b34fb"
        name: "Command"
        properties: ["write"]
        commands:
          set_speed:
            description: "Set belt speed"
            template: [0xF7, 0xA2, 0x01, "{speed}", "{checksum}", 0xFD]
            parameters:
              speed:
                type: "uint8"
                min: 0
                max: 60
                scale: 0.1
                unit: "km/h"
              checksum:
                type: "uint8"
                auto: "checksum"
          calibrate:
            description: "Calibrate the belt"
            value: [0xF7, 0xC1, 0x01]
            advanced: true
            advanced_reason: "Recalibrates the belt; step off first."
"#;

    #[test]
    fn parameter_semantics_and_auto_role_reach_the_dto() {
        let dto = load_device_spec(TREADMILL_YAML.into()).unwrap();
        let commands = &dto.services[0].characteristics[0].commands;
        let set_speed = commands.iter().find(|c| c.name == "set_speed").unwrap();

        let speed = set_speed
            .parameters
            .iter()
            .find(|p| p.name == "speed")
            .unwrap();
        assert_eq!(speed.value_type, "uint8");
        assert_eq!(speed.min, Some(0.0));
        assert_eq!(speed.max, Some(60.0));
        assert_eq!(speed.scale, Some(0.1));
        assert_eq!(speed.value_offset, None);
        assert_eq!(speed.unit.as_deref(), Some("km/h"));
        assert_eq!(speed.default, None);
        assert_eq!(speed.auto, None, "a caller-owned parameter has no role");

        let checksum = set_speed
            .parameters
            .iter()
            .find(|p| p.name == "checksum")
            .unwrap();
        assert_eq!(
            checksum.auto.as_deref(),
            Some("checksum"),
            "the UI hides the checksum byte based on this"
        );

        // The defaults applied on the Rust side must not leak phantom
        // metadata into the DTO.
        assert!(!set_speed.advanced);
        assert_eq!(set_speed.advanced_reason, None);
    }

    #[test]
    fn advanced_command_flags_reach_the_dto() {
        let dto = load_device_spec(TREADMILL_YAML.into()).unwrap();
        let commands = &dto.services[0].characteristics[0].commands;
        let calibrate = commands.iter().find(|c| c.name == "calibrate").unwrap();
        assert!(calibrate.advanced);
        assert_eq!(
            calibrate.advanced_reason.as_deref(),
            Some("Recalibrates the belt; step off first.")
        );
    }

    #[test]
    fn match_by_name_prefix_only() {
        let dto = load_device_spec(TEST_YAML.into()).unwrap();
        let results = match_device_to_spec(vec![dto], "TEST_Living_Room".into(), vec![]);
        assert_eq!(results.len(), 1);
        assert!(results[0].matched_by_name_prefix);
        assert!(results[0].matched_service_uuids.is_empty());
    }

    #[test]
    fn match_by_service_uuid_only() {
        let dto = load_device_spec(TEST_YAML.into()).unwrap();
        // Advertised UUID uses uppercase to exercise the case-insensitive
        // intersection, then assert the returned form is lowercased.
        let results = match_device_to_spec(
            vec![dto],
            "Unknown".into(),
            vec!["0000FFF0-0000-1000-8000-00805F9B34FB".into()],
        );
        assert_eq!(results.len(), 1);
        assert!(!results[0].matched_by_name_prefix);
        assert_eq!(
            results[0].matched_service_uuids,
            vec!["0000fff0-0000-1000-8000-00805f9b34fb".to_string()]
        );
    }

    #[test]
    fn match_on_both_axes() {
        let dto = load_device_spec(TEST_YAML.into()).unwrap();
        let results = match_device_to_spec(
            vec![dto],
            "TEST_Living_Room".into(),
            vec!["0000fff0-0000-1000-8000-00805f9b34fb".into()],
        );
        assert_eq!(results.len(), 1);
        assert!(results[0].matched_by_name_prefix);
        assert_eq!(results[0].matched_service_uuids.len(), 1);
    }

    #[test]
    fn match_no_results() {
        let dto = load_device_spec(TEST_YAML.into()).unwrap();
        let results = match_device_to_spec(vec![dto], "OTHER_Device".into(), vec![]);
        assert!(results.is_empty());
    }

    /// Shared with the daniao handler's unit tests — one fixture, so an edit
    /// to the command templates or framing cannot leave one test module
    /// exercising a stale spec shape while the other passes.
    const IMAGE_SPEC_YAML: &str = include_str!("../protocol/test_specs/smartdawn_doodle.yaml");

    #[test]
    fn image_upload_feature_parses_into_dto() {
        let dto = load_device_spec(IMAGE_SPEC_YAML.into()).unwrap();
        let img = dto.image_upload.expect("image_upload feature must surface");
        assert_eq!(img.handler.as_deref(), Some("daniao_ddp"));
        assert!(img.encodable, "daniao_ddp is implemented");
        assert_eq!(img.format.as_deref(), Some("rgb888"));
        assert_eq!(img.max_width, Some(255));
        assert!(img.resolution_device_reported);
        assert!(img.animation);
        assert_eq!(img.default_frame_interval_ms, Some(200));
        assert_eq!(img.min_frame_interval_ms, None);
    }

    #[test]
    fn spec_without_image_feature_has_no_image_upload() {
        let dto = load_device_spec(TEST_YAML.into()).unwrap();
        assert!(dto.image_upload.is_none());
    }

    #[test]
    fn unimplemented_handler_is_declared_not_encodable() {
        let yaml = IMAGE_SPEC_YAML.replace("daniao_ddp", "popled_json");
        let dto = load_device_spec(yaml).unwrap();
        let img = dto.image_upload.unwrap();
        assert_eq!(img.handler.as_deref(), Some("popled_json"));
        assert!(!img.encodable);
    }

    #[test]
    fn encode_image_frame_routes_to_daniao() {
        // Frame 0 opens the session (ui_end_sync + doodle_start on the DDP
        // char) then streams one pixel chunk on the BIN char — 3 packets.
        let plan = encode_image_frame(IMAGE_SPEC_YAML.into(), 1, 1, vec![0x10, 0x20, 0x30], 0, 509)
            .unwrap();
        assert_eq!(plan.service_uuid, "00000074-1972-1925-3022-077119514e44");
        assert_eq!(plan.writes.len(), 3);
        assert_eq!(
            plan.writes[0].characteristic_uuid,
            "01020074-1972-1925-3022-077119514e44"
        );
        assert_eq!(
            plan.writes[2].characteristic_uuid,
            "02020074-1972-1925-3022-077119514e44"
        );
        // The BIN chunk carries the palette color for the single pixel.
        assert!(plan.writes[2].bytes.ends_with(&[0x10, 0x20, 0x30, 0x01]));
        assert_eq!(plan.next_frame_index, 3, "2 session packets + 1 chunk");
    }

    #[test]
    fn encode_image_frame_advances_index_by_packets_consumed() {
        // Frame 0 consumes 3 serials (2 session + 1 chunk); the next frame,
        // started at that index, sends only its chunk (1 serial) — advancing
        // by less would make its serial collide and corrupt reassembly.
        let img = vec![0xAB; 20 * 20 * 3];
        let first =
            encode_image_frame(IMAGE_SPEC_YAML.into(), 20, 20, img.clone(), 0, 509).unwrap();
        assert_eq!(first.next_frame_index, 3);
        let next = encode_image_frame(
            IMAGE_SPEC_YAML.into(),
            20,
            20,
            img,
            first.next_frame_index,
            509,
        )
        .unwrap();
        assert_eq!(next.writes.len(), 1, "later frames skip session open");
        assert_eq!(next.next_frame_index, 4);
    }

    #[test]
    fn encode_image_frame_unknown_handler_errors_helpfully() {
        let yaml = IMAGE_SPEC_YAML.replace("daniao_ddp", "someday_handler");
        let err = encode_image_frame(yaml, 1, 1, vec![0; 3], 0, 20).unwrap_err();
        assert!(err.to_string().contains("someday_handler"), "{err}");
    }

    #[test]
    fn encode_image_frame_without_handler_errors_helpfully() {
        let err = encode_image_frame(TEST_YAML.into(), 1, 1, vec![0; 3], 0, 20).unwrap_err();
        assert!(err.to_string().contains("no protocol_handler"), "{err}");
    }

    #[test]
    fn match_by_name_prefix_is_ascii_case_insensitive() {
        // Vendors are not consistent about advertised-name casing across
        // firmware revisions (e.g. SmartDawn "DN"/"dn" units), and the UUID
        // axis is already case-insensitive; the name axis must agree.
        let dto = load_device_spec(TEST_YAML.into()).unwrap();
        let results = match_device_to_spec(vec![dto], "test_Living_Room".into(), vec![]);
        assert_eq!(results.len(), 1);
        assert!(results[0].matched_by_name_prefix);
    }

    #[test]
    fn match_by_name_prefix_survives_multibyte_device_names() {
        // A name shorter than the prefix, or one whose bytes at the prefix
        // length fall mid-way through a multi-byte character, must be a
        // non-match — not a panic from slicing off a char boundary.
        let dto = load_device_spec(TEST_YAML.into()).unwrap();
        for name in ["TE", "T\u{00E9}st_Bulb", "\u{1F4A1}\u{1F4A1}"] {
            let results = match_device_to_spec(vec![dto.clone()], name.into(), vec![]);
            assert!(results.is_empty(), "{name:?} must not match TEST_");
        }
    }

    #[test]
    fn empty_local_name_prefix_matches_nothing() {
        // `"x".starts_with("")` is true, so an empty prefix would otherwise
        // claim every scanned device; it must behave like an absent prefix.
        let mut dto = load_device_spec(TEST_YAML.into()).unwrap();
        dto.local_name_prefixes = vec![String::new()];
        dto.service_uuids.clear(); // no UUID axis either
        let results = match_device_to_spec(vec![dto], "AnyDeviceAtAll".into(), vec![]);
        assert!(
            results.is_empty(),
            "an empty local_name_prefix must not match by name"
        );
    }

    #[test]
    fn match_returns_each_matching_spec() {
        let a = load_device_spec(TEST_YAML.into()).unwrap();
        let b = load_device_spec(TEST_YAML.into()).unwrap();
        let results = match_device_to_spec(vec![a, b], "TEST_xx".into(), vec![]);
        assert_eq!(results.len(), 2);
    }

    // ── Pre-connect (scan) matching ─────────────────────────────────────────

    /// A spec that declares all four identification axes, so each test can pick
    /// exactly the one it means to exercise.
    const SCAN_YAML: &str = r#"
device:
  name: "Test Scanner Bulb"
  manufacturer: "Test"
  manufacturer_status: "abandoned"
  protocol: "ble"
  category: "light"
  identification:
    local_name_prefix: "TEST_"
    service_uuids:
      - "0000fff0-0000-1000-8000-00805f9b34fb"
    manufacturer_data:
      company_id: 961
      company_id_hex: "0x03C1"
      additional_company_ids: [89]
      description: "Descriptive keys here must not break the parse."
    mac_prefixes:
      - "C4:7C:8D"
services:
  - uuid: "0000fff0-0000-1000-8000-00805f9b34fb"
    name: "Control"
    characteristics:
      - uuid: "0000fff1-0000-1000-8000-00805f9b34fb"
        name: "Command"
        properties: ["write"]
"#;

    fn scan_identity() -> SpecIdentityDto {
        SpecIdentityDto::from(&load_device_spec(SCAN_YAML.into()).unwrap())
    }

    #[test]
    fn scan_identity_carries_the_spec_category() {
        assert_eq!(scan_identity().category.as_deref(), Some("light"));
    }

    #[test]
    fn a_scan_match_reports_the_matched_spec_category() {
        // The caller draws the device's icon from this. Reaching back through
        // `spec_index` would work too, right up until the catalogue the index
        // refers to is not the one the caller still has.
        let mut device = anonymous_device();
        device.name = "TEST_thing".into();
        let matches = match_scanned_device(vec![scan_identity()], device);
        assert_eq!(matches.len(), 1);
        assert_eq!(matches[0].category.as_deref(), Some("light"));
    }

    #[test]
    fn a_spec_with_no_category_still_matches() {
        // Categories arrived after the catalogue did. A spec pack cached by an
        // older build must still rank and still be usable — it just has no
        // icon to offer.
        let mut identity = scan_identity();
        identity.category = None;
        let mut device = anonymous_device();
        device.name = "TEST_thing".into();
        let matches = match_scanned_device(vec![identity], device);
        assert_eq!(matches.len(), 1);
        assert_eq!(matches[0].category, None);
    }

    /// The scan identity with its one OUI re-rated. Lets a test say which tier
    /// of block it is exercising without restating the whole spec.
    fn scan_identity_with_oui(confidence: MacPrefixConfidence) -> SpecIdentityDto {
        let mut identity = scan_identity();
        identity.mac_prefixes = vec![MacPrefixDto {
            prefix: "C4:7C:8D".into(),
            confidence,
        }];
        identity
    }

    /// A device that matches on no axis at all; tests opt into one field at a
    /// time from here.
    fn anonymous_device() -> ScannedDeviceDto {
        ScannedDeviceDto {
            name: "Anonymous".into(),
            service_uuids: vec![],
            company_ids: vec![],
            mac_address: None,
        }
    }

    /// The scan identity with its vendor UUID swapped for a SIG-assigned one.
    /// `181a` is Environmental Sensing — what xiaomi-lywsd03mmc really declares.
    fn scan_identity_with_sig_uuid() -> SpecIdentityDto {
        let mut identity = scan_identity();
        identity.service_uuids = vec!["0000181a-0000-1000-8000-00805f9b34fb".into()];
        identity
    }

    #[test]
    fn a_sig_assigned_service_uuid_alone_is_only_possible() {
        // Every thermometer on the market exposes Environmental Sensing; it
        // says the device reports a temperature, not who built it. While it
        // ranked as a vendor UUID, each of them came back Strong and was badged
        // "Xiaomi LYWSD03MMC".
        let device = ScannedDeviceDto {
            service_uuids: vec!["0000181A-0000-1000-8000-00805F9B34FB".into()],
            ..anonymous_device()
        };
        let matches = match_scanned_device(vec![scan_identity_with_sig_uuid()], device);
        assert_eq!(matches[0].confidence, MatchConfidence::Possible);
        assert_eq!(
            matches[0].matched_service_uuids,
            vec!["0000181a-0000-1000-8000-00805f9b34fb"],
            "still reported — the user asked what matched, and it did"
        );
    }

    #[test]
    fn a_sig_assigned_service_uuid_does_not_promote_a_name_prefix() {
        // The other half of the rule: a shared identifier cannot be one of the
        // two agreeing axes either, or the promotion sneaks back in.
        let device = ScannedDeviceDto {
            name: "TEST_Kitchen".into(),
            service_uuids: vec!["0000181a-0000-1000-8000-00805f9b34fb".into()],
            ..anonymous_device()
        };
        let matches = match_scanned_device(vec![scan_identity_with_sig_uuid()], device);
        assert_eq!(matches[0].confidence, MatchConfidence::Likely);
    }

    #[test]
    fn a_vendor_service_uuid_is_still_strong() {
        // The control. 0xfff0 sits inside the base UUID range but the SIG never
        // assigned it, so it is a squatted vendor value — weak against
        // collision, but still the only identifier such a device has, and the
        // strongest thing it volunteers.
        let device = ScannedDeviceDto {
            service_uuids: vec!["0000fff0-0000-1000-8000-00805f9b34fb".into()],
            ..anonymous_device()
        };
        let matches = match_scanned_device(vec![scan_identity()], device);
        assert_eq!(matches[0].confidence, MatchConfidence::Strong);
    }

    #[test]
    fn the_sig_registry_answers_in_every_uuid_spelling() {
        // Specs write these three ways interchangeably; a miss in any spelling
        // silently restores the Strong verdict for that spec alone.
        for spelling in [
            "181a",
            "0000181A-0000-1000-8000-00805F9B34FB",
            "0000181a-0000-1000-8000-00805f9b34fb",
        ] {
            assert!(is_sig_assigned_service(spelling), "{spelling}");
        }
        // Padding matters: 0x1800 is Generic Access, and normalize_uuid hands
        // back "1800" — but a two-digit assignment would come back stripped.
        assert!(is_sig_assigned_service("1800"));
        // Not assignments: the squatted range, and a full vendor UUID.
        assert!(!is_sig_assigned_service("fff0"));
        assert!(!is_sig_assigned_service(
            "0000fff0-0000-1000-8000-00805f9b34fb"
        ));
        assert!(!is_sig_assigned_service(
            "6e400001-b5a3-f393-e0a9-e50e24dcca9e"
        ));
    }

    #[test]
    fn identification_axes_reach_the_dto() {
        let dto = load_device_spec(SCAN_YAML.into()).unwrap();
        assert_eq!(dto.company_ids, vec![961, 89]);
        assert_eq!(
            dto.mac_prefixes,
            vec![MacPrefixDto {
                prefix: "C4:7C:8D".to_string(),
                // A bare string says nothing about the block, and a block
                // nobody has checked has to be assumed to be a shared one.
                confidence: MacPrefixConfidence::Low,
            }]
        );
    }

    #[test]
    fn every_declared_local_name_prefix_matches() {
        // The Inkbird case: one family, eight rebadged names, no shared prefix.
        // Each is an alternative, so a device carrying any one of them is a
        // match, and the singular and plural keys are read together.
        let yaml = SCAN_YAML.replace(
            "    local_name_prefix: \"TEST_\"",
            concat!(
                "    local_name_prefix: \"TEST_\"\n",
                "    local_name_prefixes: [\"IBT-\", \"IBBQ-\", \"TEST_\"]",
            ),
        );
        let identity = SpecIdentityDto::from(&load_device_spec(yaml).unwrap());
        assert_eq!(
            identity.local_name_prefixes,
            vec!["TEST_", "IBT-", "IBBQ-"],
            "singular first, then the plural entries, with the repeat dropped"
        );

        for name in ["TEST_Kitchen", "IBT-4XS", "IBBQ-4BW"] {
            let matches = match_scanned_device(
                vec![identity.clone()],
                ScannedDeviceDto {
                    name: name.into(),
                    ..anonymous_device()
                },
            );
            assert_eq!(
                matches.len(),
                1,
                "{name} should have matched on one of the declared prefixes"
            );
            assert!(matches[0].matched_by_name_prefix, "{name}");
        }

        assert!(
            match_scanned_device(
                vec![identity],
                ScannedDeviceDto {
                    name: "SomethingElse".into(),
                    ..anonymous_device()
                }
            )
            .is_empty(),
            "a name matching none of them is still not a match"
        );
    }

    #[test]
    fn a_detailed_mac_prefix_entry_carries_its_verdict() {
        // The other half of the schema's `oneOf`: a map with the spec author's
        // finding on it, plus the free-text `notes` that finding lives in.
        let yaml = SCAN_YAML.replace(
            "      - \"C4:7C:8D\"",
            concat!(
                "      - prefix: \"C4:7C:8D\"\n",
                "        confidence: \"high\"\n",
                "        notes: \"Unknown keys here must not break the parse.\"\n",
            ),
        );
        let dto = load_device_spec(yaml).unwrap();
        assert_eq!(
            dto.mac_prefixes,
            vec![MacPrefixDto {
                prefix: "C4:7C:8D".to_string(),
                confidence: MacPrefixConfidence::High,
            }]
        );
    }

    #[test]
    fn a_detailed_mac_prefix_entry_defaults_to_low() {
        // Writing the map form without a verdict is not a claim of confidence.
        let yaml = SCAN_YAML.replace(
            "      - \"C4:7C:8D\"",
            "      - prefix: \"C4:7C:8D\"\n        notes: \"Nobody has checked this block.\"\n",
        );
        let dto = load_device_spec(yaml).unwrap();
        assert_eq!(
            dto.mac_prefixes[0].confidence,
            MacPrefixConfidence::Low,
            "an unstated verdict is the pessimistic one"
        );
    }

    #[test]
    fn duplicate_company_ids_are_collapsed() {
        // A spec repeating its primary ID under additional_company_ids must not
        // make the device look like it agreed on two separate signals.
        let yaml = SCAN_YAML.replace(
            "additional_company_ids: [89]",
            "additional_company_ids: [961]",
        );
        let dto = load_device_spec(yaml).unwrap();
        assert_eq!(dto.company_ids, vec![961]);
    }

    #[test]
    fn service_uuid_alone_is_strong() {
        let device = ScannedDeviceDto {
            // Uppercase on purpose: advertised UUID casing varies by platform.
            service_uuids: vec!["0000FFF0-0000-1000-8000-00805F9B34FB".into()],
            ..anonymous_device()
        };
        let matches = match_scanned_device(vec![scan_identity()], device);
        assert_eq!(matches.len(), 1);
        assert_eq!(matches[0].confidence, MatchConfidence::Strong);
        assert_eq!(
            matches[0].matched_service_uuids,
            vec!["0000fff0-0000-1000-8000-00805f9b34fb".to_string()]
        );
    }

    #[test]
    fn name_prefix_alone_is_likely() {
        let device = ScannedDeviceDto {
            name: "TEST_Kitchen".into(),
            ..anonymous_device()
        };
        let matches = match_scanned_device(vec![scan_identity()], device);
        assert_eq!(matches.len(), 1);
        assert_eq!(matches[0].confidence, MatchConfidence::Likely);
        assert!(matches[0].matched_by_name_prefix);
    }

    #[test]
    fn company_id_alone_is_likely() {
        let device = ScannedDeviceDto {
            company_ids: vec![89],
            ..anonymous_device()
        };
        let matches = match_scanned_device(vec![scan_identity()], device);
        assert_eq!(matches.len(), 1);
        assert_eq!(matches[0].confidence, MatchConfidence::Likely);
        assert_eq!(matches[0].matched_company_ids, vec![89]);
    }

    #[test]
    fn mac_prefix_alone_is_only_possible() {
        // The whole point of the weakest tier: an OUI is a vendor, not a
        // product, so this must never be promoted into a claim of support.
        let device = ScannedDeviceDto {
            mac_address: Some("c4:7c:8d:11:22:33".into()),
            ..anonymous_device()
        };
        let matches = match_scanned_device(vec![scan_identity()], device);
        assert_eq!(matches.len(), 1);
        assert_eq!(matches[0].confidence, MatchConfidence::Possible);
        let matched = matches[0].matched_mac_prefix.as_ref().unwrap();
        assert_eq!(matched.prefix, "C4:7C:8D");
        assert_eq!(matched.confidence, MacPrefixConfidence::Low);
    }

    #[test]
    fn a_medium_confidence_oui_alone_is_still_only_possible() {
        // "Something Philips made" is not "a Philips bridge". A block being
        // genuinely the manufacturer's does not make it this product's.
        let device = ScannedDeviceDto {
            mac_address: Some("c4:7c:8d:11:22:33".into()),
            ..anonymous_device()
        };
        let matches = match_scanned_device(
            vec![scan_identity_with_oui(MacPrefixConfidence::Medium)],
            device,
        );
        assert_eq!(matches[0].confidence, MatchConfidence::Possible);
    }

    #[test]
    fn a_high_confidence_oui_alone_is_likely() {
        // A block a spec author checked and found to be this family's and
        // nothing else's is evidence in its own right — the same standing as a
        // local name, which users can rename anyway.
        let device = ScannedDeviceDto {
            mac_address: Some("c4:7c:8d:11:22:33".into()),
            ..anonymous_device()
        };
        let matches = match_scanned_device(
            vec![scan_identity_with_oui(MacPrefixConfidence::High)],
            device,
        );
        assert_eq!(matches[0].confidence, MatchConfidence::Likely);
    }

    #[test]
    fn a_low_confidence_oui_does_not_promote_a_name_prefix() {
        // The regression this whole flag exists for. C4:7C:8D is an IEEE
        // Registration Authority block subdivided among fifteen companies, so
        // a device sitting in it agreeing with a name prefix is one signal
        // plus a coincidence, not two signals agreeing.
        let device = ScannedDeviceDto {
            name: "TEST_Kitchen".into(),
            mac_address: Some("C4-7C-8D-11-22-33".into()),
            ..anonymous_device()
        };
        let matches = match_scanned_device(vec![scan_identity()], device);
        assert_eq!(matches[0].confidence, MatchConfidence::Likely);
        assert!(
            matches[0].matched_mac_prefix.is_some(),
            "the prefix still matched and is still reported — it just does not vote"
        );
    }

    #[test]
    fn two_weak_axes_agreeing_are_strong() {
        // A block that really is the vendor's, on a device also carrying the
        // vendor's name prefix: two independent signals, so this is the pile
        // of weak evidence that the promotion rule exists for.
        let device = ScannedDeviceDto {
            name: "TEST_Kitchen".into(),
            mac_address: Some("C4-7C-8D-11-22-33".into()),
            ..anonymous_device()
        };
        let matches = match_scanned_device(
            vec![scan_identity_with_oui(MacPrefixConfidence::Medium)],
            device,
        );
        assert_eq!(matches[0].confidence, MatchConfidence::Strong);
    }

    #[test]
    fn the_best_matching_prefix_wins() {
        // A spec may list a shared block and a vetted one. Which entry the
        // address lands in decides the verdict, not which was written first.
        let mut identity = scan_identity();
        identity.mac_prefixes = vec![
            MacPrefixDto {
                prefix: "C4:7C:8D".into(),
                confidence: MacPrefixConfidence::Low,
            },
            MacPrefixDto {
                prefix: "C4:7C:8D:6".into(),
                confidence: MacPrefixConfidence::High,
            },
        ];
        let device = ScannedDeviceDto {
            mac_address: Some("c4:7c:8d:6a:22:33".into()),
            ..anonymous_device()
        };
        let matches = match_scanned_device(vec![identity], device);
        assert_eq!(
            matches[0].matched_mac_prefix.as_ref().unwrap().prefix,
            "C4:7C:8D:6"
        );
        assert_eq!(matches[0].confidence, MatchConfidence::Likely);
    }

    #[test]
    fn a_core_bluetooth_uuid_is_not_read_as_a_mac() {
        // Apple platforms hand out a per-host UUID in place of the address.
        // Its hex digits must never be prefix-compared against an OUI list.
        let device = ScannedDeviceDto {
            mac_address: Some("C47C8DAB-1234-5678-9ABC-DEF012345678".into()),
            ..anonymous_device()
        };
        assert!(match_scanned_device(vec![scan_identity()], device).is_empty());
    }

    #[test]
    fn a_one_octet_mac_prefix_is_ignored() {
        // A single octet matches a sixteenth of all hardware, so a spec that
        // somehow carries one must match nothing rather than everything. Rated
        // `high` on purpose: a confidence flag is the spec author's opinion of
        // a block, and no opinion makes one octet a block.
        let mut identity = scan_identity();
        identity.mac_prefixes = vec![MacPrefixDto {
            prefix: "C4".into(),
            confidence: MacPrefixConfidence::High,
        }];
        let device = ScannedDeviceDto {
            mac_address: Some("c4:7c:8d:11:22:33".into()),
            ..anonymous_device()
        };
        assert!(match_scanned_device(vec![identity], device).is_empty());
    }

    #[test]
    fn scan_matches_come_back_best_first() {
        let strong = scan_identity();
        let mut weak = scan_identity();
        weak.device_name = "Weak".into();
        weak.service_uuids.clear();
        weak.local_name_prefixes = vec![];
        weak.company_ids = vec![];

        let device = ScannedDeviceDto {
            name: "TEST_Kitchen".into(),
            service_uuids: vec!["0000fff0-0000-1000-8000-00805f9b34fb".into()],
            company_ids: vec![],
            mac_address: Some("c4:7c:8d:11:22:33".into()),
        };
        // Weak is passed FIRST, so ordering can only come from confidence.
        let matches = match_scanned_device(vec![weak, strong], device);
        assert_eq!(matches.len(), 2);
        assert_eq!(matches[0].device_name, "Test Scanner Bulb");
        assert_eq!(matches[0].confidence, MatchConfidence::Strong);
        assert_eq!(matches[0].spec_index, 1, "spec_index must index the input");
        assert_eq!(matches[1].confidence, MatchConfidence::Possible);
    }

    #[test]
    fn scan_match_no_results() {
        assert!(match_scanned_device(vec![scan_identity()], anonymous_device()).is_empty());
    }

    // ── Local-network matching ──────────────────────────────────────────────

    const NETWORK_YAML: &str = r#"
device:
  name: "Test Bridge"
  manufacturer: "Test"
  manufacturer_status: "abandoned"
  protocol: "wifi"
  identification:
    local_name_prefix: "TestBridge-"
    mdns_service_type: "_testbridge._tcp.local."
    ssdp_search_targets:
      - "urn:test:device:bridge:1"
    default_port: 8081
http_endpoints:
  - method: "GET"
    path: "/"
    name: "Root"
"#;

    impl SpecIdentityDto {
        /// Drop the name axis so a test can isolate the network identifiers.
        fn local_name_prefix_clear(&mut self) {
            self.local_name_prefixes.clear();
        }
    }

    fn network_identity() -> SpecIdentityDto {
        SpecIdentityDto::from(&load_device_spec(NETWORK_YAML.into()).unwrap())
    }

    fn anonymous_host() -> NetworkDeviceDto {
        NetworkDeviceDto {
            name: String::new(),
            hostname: None,
            service_types: vec![],
            ssdp_targets: vec![],
            answered_lan_protocols: vec![],
            port: None,
        }
    }

    /// A network identity carrying only a LAN-protocol signal — every passive
    /// signal cleared, so a match can only come from an answered protocol.
    fn lan_protocol_identity() -> SpecIdentityDto {
        let mut identity = network_identity();
        identity.local_name_prefix_clear();
        identity.mdns_service_type = None;
        identity.ssdp_search_targets.clear();
        identity.lan_protocols = vec!["tplink-smarthome".into()];
        identity
    }

    #[test]
    fn a_lan_protocol_the_device_answered_is_strong() {
        // Only a Kasa plug answers the tplink-smarthome probe, so an answer is
        // as strong as a vendor service type — not the weak port it rode in on.
        let device = NetworkDeviceDto {
            answered_lan_protocols: vec!["TPLink-SmartHome".into()],
            port: Some(9999),
            ..anonymous_host()
        };
        let matches = match_network_device(vec![lan_protocol_identity()], device);
        assert_eq!(matches.len(), 1);
        assert_eq!(matches[0].confidence, MatchConfidence::Strong);
        assert_eq!(matches[0].matched_service_types, vec!["tplink-smarthome"]);
    }

    #[test]
    fn a_lan_protocol_not_answered_does_not_match_on_the_port_alone() {
        // A plain host listening on 9999 that never answered the probe must not
        // match — the port is not evidence, only the answer is.
        let device = NetworkDeviceDto {
            port: Some(9999),
            ..anonymous_host()
        };
        assert!(match_network_device(vec![lan_protocol_identity()], device).is_empty());
    }

    #[test]
    fn network_identity_axes_reach_the_dto() {
        let dto = load_device_spec(NETWORK_YAML.into()).unwrap();
        assert_eq!(
            dto.mdns_service_type.as_deref(),
            Some("_testbridge._tcp.local.")
        );
        assert_eq!(dto.ssdp_search_targets, vec!["urn:test:device:bridge:1"]);
        assert_eq!(dto.default_port, Some(8081));
    }

    #[test]
    fn an_mdns_service_type_alone_is_strong() {
        let device = NetworkDeviceDto {
            service_types: vec!["_testbridge._tcp.local".into()],
            ..anonymous_host()
        };
        let matches = match_network_device(vec![network_identity()], device);
        assert_eq!(matches.len(), 1);
        assert_eq!(matches[0].confidence, MatchConfidence::Strong);
        assert_eq!(matches[0].matched_service_types.len(), 1);
    }

    #[test]
    fn a_trailing_dot_is_not_a_missed_device() {
        // Specs and devices both write `_x._tcp`, `_x._tcp.local` and
        // `_x._tcp.local.` interchangeably.
        for advertised in ["_testbridge._tcp", "_TestBridge._TCP.local."] {
            let device = NetworkDeviceDto {
                service_types: vec![advertised.into()],
                ..anonymous_host()
            };
            let matches = match_network_device(vec![network_identity()], device);
            assert_eq!(matches.len(), 1, "{advertised} should have matched");
        }
    }

    #[test]
    fn an_ssdp_search_target_alone_is_strong() {
        let device = NetworkDeviceDto {
            ssdp_targets: vec!["urn:test:device:bridge:1".into()],
            ..anonymous_host()
        };
        let matches = match_network_device(vec![network_identity()], device);
        assert_eq!(matches[0].confidence, MatchConfidence::Strong);
    }

    #[test]
    fn a_hostname_prefix_alone_is_likely() {
        // Network devices carry their branding in the hostname rather than in
        // any advertised "name" field.
        let device = NetworkDeviceDto {
            hostname: Some("TestBridge-083e013d.local".into()),
            ..anonymous_host()
        };
        let matches = match_network_device(vec![network_identity()], device);
        assert_eq!(matches[0].confidence, MatchConfidence::Likely);
        assert!(matches[0].matched_by_name_prefix);
    }

    #[test]
    fn a_default_port_alone_matches_nothing() {
        // Port 8081 is not evidence of anything much, and port 80 is evidence
        // of nothing at all — so a port on its own does not admit a match. Two
        // specs in the catalogue declare a port and nothing else, and while the
        // port was admitting they claimed every host answering on it: any
        // router admin page came back "Possibly Rachio".
        let mut identity = network_identity();
        identity.mdns_service_type = None;
        identity.ssdp_search_targets = vec![];
        identity.local_name_prefixes = vec![];

        let device = NetworkDeviceDto {
            port: Some(8081),
            ..anonymous_host()
        };
        let matches = match_network_device(vec![identity], device);
        assert!(
            matches.is_empty(),
            "a matched port is not evidence of anything"
        );
    }

    #[test]
    fn a_network_match_reports_no_ble_axes() {
        let device = NetworkDeviceDto {
            service_types: vec!["_testbridge._tcp.local".into()],
            ..anonymous_host()
        };
        let matches = match_network_device(vec![network_identity()], device);
        assert!(matches[0].matched_service_uuids.is_empty());
        assert!(matches[0].matched_company_ids.is_empty());
        assert!(matches[0].matched_mac_prefix.is_none());
    }

    #[test]
    fn a_ble_only_spec_matches_no_network_device() {
        // scan_identity() has no mdns/ssdp/port, so it must never claim a host.
        let device = NetworkDeviceDto {
            name: "TEST_Kitchen".into(),
            service_types: vec!["_testbridge._tcp.local".into()],
            port: Some(8081),
            ..anonymous_host()
        };
        let matches = match_network_device(vec![scan_identity()], device);
        assert!(
            matches.is_empty(),
            "a BLE spec's local_name_prefix must not be enough on its own here"
        );
    }

    #[test]
    fn a_shared_search_target_alone_is_only_possible() {
        // The regression this whole split exists for. hue-bridge.yaml declares
        // `upnp:rootdevice`, and the Wi-Fi scan's M-SEARCH uses `ST: ssdp:all`,
        // which every UPnP responder answers with exactly that. Before this,
        // the router, the printer and the NAS were each reported Strong and
        // badged "Philips Hue Bridge".
        let mut identity = network_identity();
        identity.mdns_service_type = None;
        identity.ssdp_search_targets = vec!["upnp:rootdevice".into()];
        identity.local_name_prefix_clear();

        let device = NetworkDeviceDto {
            ssdp_targets: vec!["upnp:rootdevice".into()],
            ..anonymous_host()
        };
        let matches = match_network_device(vec![identity], device);
        assert_eq!(matches.len(), 1, "it still ranks — it just cannot claim");
        assert_eq!(matches[0].confidence, MatchConfidence::Possible);
        assert_eq!(
            matches[0].matched_service_types,
            vec!["upnp:rootdevice".to_string()],
            "still reported, so the UI can say what matched"
        );
    }

    #[test]
    fn a_shared_mdns_type_alone_is_only_possible() {
        // roku-ecp declares `_airplay._tcp`, lifx-z and rachio declare
        // `_hap._tcp`. An Apple TV is not a Roku; a HomeKit plug is not a
        // sprinkler controller.
        for shared in ["_airplay._tcp.local.", "_hap._tcp.local."] {
            let mut identity = network_identity();
            identity.mdns_service_type = Some(shared.into());
            identity.ssdp_search_targets = vec![];
            identity.local_name_prefix_clear();

            let device = NetworkDeviceDto {
                service_types: vec![shared.into()],
                ..anonymous_host()
            };
            let matches = match_network_device(vec![identity], device);
            assert_eq!(
                matches[0].confidence,
                MatchConfidence::Possible,
                "{shared} is answered by a whole ecosystem"
            );
        }
    }

    #[test]
    fn a_vendor_specific_mdns_type_is_still_strong() {
        // The other half of the contract: splitting shared identifiers out must
        // not weaken a real one. `_testbridge._tcp` belongs to one product.
        let device = NetworkDeviceDto {
            service_types: vec!["_testbridge._tcp.local".into()],
            ..anonymous_host()
        };
        let matches = match_network_device(vec![network_identity()], device);
        assert_eq!(matches[0].confidence, MatchConfidence::Strong);
    }

    #[test]
    fn a_shared_type_still_corroborates_a_real_signal() {
        // A shared identifier is not evidence on its own, but it does not
        // subtract either: the vendor-specific type still carries the match.
        let mut identity = network_identity();
        identity.ssdp_search_targets = vec!["upnp:rootdevice".into()];

        let device = NetworkDeviceDto {
            service_types: vec!["_testbridge._tcp.local".into()],
            ssdp_targets: vec!["upnp:rootdevice".into()],
            ..anonymous_host()
        };
        let matches = match_network_device(vec![identity], device);
        assert_eq!(matches[0].confidence, MatchConfidence::Strong);
        assert_eq!(
            matches[0].matched_service_types.len(),
            2,
            "both are reported even though only one of them ranks"
        );
    }

    #[test]
    fn a_default_port_does_not_promote_a_name_prefix() {
        // Port 80 says nothing about who is listening, which the DTO's own doc
        // comment states — so it must not be half of a "two signals agree"
        // promotion, for the same reason a shared block is not.
        let mut identity = network_identity();
        identity.mdns_service_type = None;
        identity.ssdp_search_targets = vec![];

        let device = NetworkDeviceDto {
            hostname: Some("TestBridge-1.local".into()),
            port: Some(8081),
            ..anonymous_host()
        };
        let matches = match_network_device(vec![identity], device);
        assert_eq!(matches[0].confidence, MatchConfidence::Likely);
    }

    #[test]
    fn network_matches_come_back_best_first() {
        // Weak matches on its shared search target alone, which ranks but never
        // promotes; the full identity matches on its own mDNS type.
        let mut weak = network_identity();
        weak.device_name = "Weak".into();
        weak.mdns_service_type = None;
        weak.ssdp_search_targets = vec!["upnp:rootdevice".into()];
        weak.local_name_prefixes = vec![];

        let device = NetworkDeviceDto {
            hostname: Some("TestBridge-1.local".into()),
            service_types: vec!["_testbridge._tcp.local".into()],
            ssdp_targets: vec!["upnp:rootdevice".into()],
            port: Some(8081),
            ..anonymous_host()
        };
        let matches = match_network_device(vec![weak, network_identity()], device);
        assert_eq!(matches.len(), 2);
        assert_eq!(matches[0].device_name, "Test Bridge");
        assert_eq!(matches[0].confidence, MatchConfidence::Strong);
        assert_eq!(matches[1].confidence, MatchConfidence::Possible);
    }

    #[test]
    fn network_match_no_results() {
        assert!(match_network_device(vec![network_identity()], anonymous_host()).is_empty());
    }

    #[test]
    fn post_connect_matches_carry_confidence() {
        // The two matchers share one core, so the post-connect path reports the
        // same confidence vocabulary as the scan path.
        let dto = load_device_spec(TEST_YAML.into()).unwrap();
        let results = match_device_to_spec(
            vec![dto],
            "Unknown".into(),
            vec!["0000fff0-0000-1000-8000-00805f9b34fb".into()],
        );
        assert_eq!(results[0].confidence, MatchConfidence::Strong);
    }

    #[test]
    fn encode_decode_roundtrip_via_spec() {
        let bytes = encode_command(
            Some(TEST_YAML.into()),
            None,
            "0000fff1-0000-1000-8000-00805f9b34fb".into(),
            "power_on".into(),
            HashMap::new(),
        )
        .unwrap();
        assert_eq!(bytes, vec![0x01, 0x01]);

        let values = decode_value(
            Some(TEST_YAML.into()),
            None,
            "0000fff2-0000-1000-8000-00805f9b34fb".into(),
            vec![1, 80],
        )
        .unwrap();
        assert_eq!(values.len(), 2);

        let power = values.iter().find(|v| v.name == "power_state").unwrap();
        assert_eq!(power.bool_value, Some(true));

        let brightness = values.iter().find(|v| v.name == "brightness").unwrap();
        assert_eq!(brightness.uint_value, Some(80));
    }

    #[test]
    fn identify_battery_and_device_info() {
        let uuids = vec![
            "0000180f-0000-1000-8000-00805f9b34fb".to_string(), // Battery
            "0000180a-0000-1000-8000-00805f9b34fb".to_string(), // Device Info
            "0000fff0-0000-1000-8000-00805f9b34fb".to_string(), // Custom (unknown)
        ];
        let profiles = identify_standard_profiles(uuids);
        assert_eq!(profiles.len(), 2);

        let battery = profiles
            .iter()
            .find(|p| p.profile_name == "Battery Service")
            .unwrap();
        assert_eq!(battery.characteristics.len(), 1);
        assert_eq!(battery.characteristics[0].name, "Battery Level");
        assert!(battery.characteristics[0].can_read);
        assert!(battery.characteristics[0].can_notify);

        let device_info = profiles
            .iter()
            .find(|p| p.profile_name == "Device Information")
            .unwrap();
        assert_eq!(device_info.characteristics.len(), 7);
    }

    #[test]
    fn identify_no_standard_profiles() {
        let uuids = vec!["0000fff0-0000-1000-8000-00805f9b34fb".to_string()];
        let profiles = identify_standard_profiles(uuids);
        assert!(profiles.is_empty());
    }

    #[test]
    fn identify_standard_profiles_lowercases_service_uuid() {
        // The scanner may report uppercase UUIDs; the DTO must come back
        // lowercased, matching match_device_to_spec's casing contract.
        let uuids = vec!["0000180F-0000-1000-8000-00805F9B34FB".to_string()];
        let profiles = identify_standard_profiles(uuids);
        assert_eq!(profiles.len(), 1);
        assert_eq!(
            profiles[0].service_uuid,
            "0000180f-0000-1000-8000-00805f9b34fb"
        );
    }

    #[test]
    fn decode_via_standard_battery_profile() {
        let values =
            decode_value(None, Some("180f".to_string()), "2a19".to_string(), vec![85]).unwrap();
        assert_eq!(values.len(), 1);
        assert_eq!(values[0].name, "battery_percent");
        assert_eq!(values[0].uint_value, Some(85));
    }

    #[test]
    fn decode_via_standard_device_info_profile() {
        let values = decode_value(
            None,
            Some("180a".to_string()),
            "2a29".to_string(),
            b"TestCorp".to_vec(),
        )
        .unwrap();
        assert_eq!(values.len(), 1);
        assert_eq!(values[0].name, "value");
        assert_eq!(values[0].string_value, Some("TestCorp".to_string()));
    }

    #[test]
    fn decode_unknown_service_with_no_spec_fails() {
        let result = decode_value(None, Some("fff0".to_string()), "fff1".to_string(), vec![0]);
        assert!(result.is_err());
    }

    #[test]
    fn decode_with_no_spec_or_service_fails() {
        let result = decode_value(None, None, "anything".to_string(), vec![0]);
        assert!(result.is_err());
    }

    #[test]
    fn decode_carries_format_scale_and_unit_across_the_boundary() {
        // The SIG temperature characteristic reports hundredths of a degree, and
        // upstream specs declare that on the format field. If the multiplier
        // does not cross the FFI boundary the UI has no way to recover it, and
        // 23.5 °C renders as 2350.
        let yaml = r#"
device:
  name: "SIG Thermometer"
  manufacturer: "Someone"
  manufacturer_status: "unsupported"
  protocol: "ble"
services:
  - uuid: "0000181a-0000-1000-8000-00805f9b34fb"
    name: "Environmental Sensing"
    characteristics:
      - uuid: "00002a6e-0000-1000-8000-00805f9b34fb"
        name: "Temperature"
        properties: ["read"]
        format:
          - offset: 0
            length: 2
            name: "temperature"
            type: "int16"
            scale: 0.01
            unit: "C"
"#;
        let values = decode_value(
            Some(yaml.to_string()),
            None,
            "00002a6e-0000-1000-8000-00805f9b34fb".to_string(),
            2350i16.to_le_bytes().to_vec(),
        )
        .unwrap();

        assert_eq!(values.len(), 1);
        // The raw reading stays raw — decoding is lossless and the caller
        // applies the conversion.
        assert_eq!(values[0].int_value, Some(2350));
        assert_eq!(values[0].scale, Some(0.01));
        assert_eq!(values[0].unit.as_deref(), Some("C"));
    }

    #[test]
    fn decode_reports_no_scale_when_the_spec_declares_none() {
        // Absence must stay absent: a defaulted scale of 1.0 would be
        // indistinguishable from a declared one, and would let a later bug
        // multiply a raw count silently.
        let values = decode_value(
            Some(TEST_YAML.to_string()),
            None,
            "0000fff2-0000-1000-8000-00805f9b34fb".to_string(),
            vec![1, 80],
        )
        .unwrap();
        assert!(values.iter().all(|v| v.scale.is_none()));
    }

    #[test]
    fn decoded_uint_within_i64_range_does_not_set_string_value() {
        let dto = DecodedValueDto::from(("battery", &DecodedValue::Uint(85)));
        assert_eq!(dto.uint_value, Some(85));
        assert_eq!(dto.string_value, None);
    }

    #[test]
    fn decoded_uint_above_i64_max_surfaces_truthful_value_as_string() {
        // u64::MAX exceeds i64::MAX; the clamp would silently lie about
        // the value. Surface the original via string_value so the UI can
        // show "18446744073709551615" instead of just i64::MAX.
        let dto = DecodedValueDto::from(("counter", &DecodedValue::Uint(u64::MAX)));
        assert_eq!(dto.uint_value, Some(i64::MAX));
        assert_eq!(dto.string_value, Some(u64::MAX.to_string()));
    }
}
