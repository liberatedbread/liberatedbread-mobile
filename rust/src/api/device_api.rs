// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
//! Public API exposed to Flutter via flutter_rust_bridge.
//! This module defines the FFI boundary — keep types simple and serializable.

use std::collections::HashMap;

use crate::codec::types::DecodedValue;
use crate::protocol::dispatch::select_protocol;
use crate::protocol::profiles;
use crate::spec::bindings;
use crate::spec::parser::parse_device_spec;
use crate::spec::types::{
    Characteristic, CharacteristicProperty, Command, DeviceSpec, Entity, FormatField, Parameter,
    Service,
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
    pub notes: Option<String>,
    pub local_name_prefix: Option<String>,
    pub service_uuids: Vec<String>,
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

/// The BLE writes that push one image frame to a device, in send order.
#[derive(Debug, Clone)]
pub struct ImageWritePlanDto {
    pub service_uuid: String,
    pub characteristic_uuid: String,
    /// Ordered write payloads. The caller sends them back-to-back on the
    /// characteristic; ordering is part of the protocol (fragment reassembly).
    pub writes: Vec<Vec<u8>>,
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

impl From<&DeviceSpec> for DeviceSpecDto {
    fn from(spec: &DeviceSpec) -> Self {
        let ident = spec.device.identification.as_ref();
        Self {
            image_upload: image_upload_dto(spec),
            device_name: spec.device.name.clone(),
            manufacturer: spec.device.manufacturer.clone(),
            manufacturer_status: spec.device.manufacturer_status.to_string(),
            protocol: spec.device.protocol.to_string(),
            notes: spec.device.notes.clone(),
            local_name_prefix: ident.and_then(|i| i.local_name_prefix.clone()),
            service_uuids: ident
                .and_then(|i| i.service_uuids.clone())
                .unwrap_or_default(),
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
                        .map(|(name, cmd)| CommandDto::from((name.as_str(), cmd)))
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

impl From<(&str, &Command)> for CommandDto {
    fn from((name, cmd): (&str, &Command)) -> Self {
        let enc = crate::codec::types::unsupported_encoding_kind(cmd);
        Self {
            name: name.to_string(),
            description: cmd.description.clone(),
            is_fixed: cmd.value.is_some(),
            is_encodable: enc.is_none(),
            unsupported_encoding: enc,
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
        // Direct write: the value IS the payload, at the width the single
        // format field declares.
        None => crate::codec::types::encode_scalar(raw, &value_type, &entity_name)?,
    };

    Ok(EntityWriteDto {
        service_uuid: action.service.uuid.clone(),
        characteristic_uuid: action.characteristic.uuid.clone(),
        bytes,
    })
}

/// Find every spec matching a scanned device, with the reasons it matched.
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
    specs
        .into_iter()
        .filter_map(|spec| {
            // An empty prefix is treated as absent, not as a wildcard: an
            // empty prefix matches every name, so a spec carrying
            // `local_name_prefix: ""` would otherwise claim every scanned
            // device.
            //
            // ASCII-case-insensitive, like the UUID axis below: BLE local
            // names for these devices are ASCII, and vendors are not
            // consistent about casing across firmware revisions (SmartDawn
            // units advertise DN*-style names and the vendor app itself
            // filters them case-insensitively). `get(..len)` rather than
            // slicing so a multi-byte device name can't panic mid-char — a
            // None there cannot equal an ASCII prefix anyway.
            let name_match = spec.local_name_prefix.as_ref().is_some_and(|prefix| {
                !prefix.is_empty()
                    && device_name
                        .get(..prefix.len())
                        .is_some_and(|head| head.eq_ignore_ascii_case(prefix))
            });

            // Return the lowercased intersection. Matches the docstring's
            // contract and gives Dart callers a predictable casing. We
            // only allocate the lowercased copy when a spec UUID actually
            // matches; the per-element compare uses `eq_ignore_ascii_case`.
            let matched_service_uuids: Vec<String> = spec
                .service_uuids
                .iter()
                .filter(|spec_uuid| {
                    advertised_service_uuids
                        .iter()
                        .any(|adv| adv.eq_ignore_ascii_case(spec_uuid))
                })
                .map(|spec_uuid| spec_uuid.to_ascii_lowercase())
                .collect();

            if name_match || !matched_service_uuids.is_empty() {
                Some(MatchResult {
                    spec,
                    matched_by_name_prefix: name_match,
                    matched_service_uuids,
                })
            } else {
                None
            }
        })
        .collect()
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
        &rgb,
        width,
        height,
        frame_index,
        max_payload_per_write as usize,
    )?;
    Ok(ImageWritePlanDto {
        service_uuid: handler.service_uuid.to_string(),
        characteristic_uuid: handler.characteristic_uuid.to_string(),
        next_frame_index: frame_index.wrapping_add(frame.packets),
        writes: frame.writes,
    })
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
            .join("assets/device_specs/example-bulb.yaml");
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

    const IMAGE_SPEC_YAML: &str = r#"
device:
  name: "Pixel Curtain"
  manufacturer: "Daniao"
  manufacturer_status: "active"
  protocol: "ble"

protocol_handler: "daniao_ddp"

features:
  - type: "image_upload"
    format: "rgb888"
    max_width: 255
    max_height: 255
    resolution_source: "device_reported"
    animation: true
    default_frame_interval_ms: 200

services: []
"#;

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
        let plan = encode_image_frame(IMAGE_SPEC_YAML.into(), 1, 1, vec![0x10, 0x20, 0x30], 0, 20)
            .unwrap();
        assert_eq!(plan.service_uuid, "00000074-1972-1925-3022-077119514e44");
        assert_eq!(
            plan.characteristic_uuid,
            "01020074-1972-1925-3022-077119514e44"
        );
        assert_eq!(plan.writes.len(), 1);
        assert!(plan.writes[0].ends_with(&[0x10, 0x20, 0x30]));
        assert_eq!(plan.next_frame_index, 1, "one packet consumed one serial");
    }

    #[test]
    fn encode_image_frame_advances_index_by_packets_consumed() {
        // 40x34 RGB at the 20-byte payload floor splits into two DDP packets
        // (serials 5 and 6), so the next frame must start at 7 — advancing by
        // one would make its first packet collide with this frame's second.
        let plan = encode_image_frame(
            IMAGE_SPEC_YAML.into(),
            40,
            34,
            vec![0xAB; 40 * 34 * 3],
            5,
            20,
        )
        .unwrap();
        assert_eq!(plan.next_frame_index, 7);
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
        dto.local_name_prefix = Some(String::new());
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
