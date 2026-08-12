// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
//! Resolve a control entity's roles (`turn_on`, `set_brightness`, ...) to
//! concrete, sendable commands.
//!
//! Specs bind entities to commands two ways, both in real catalogue use:
//! an explicit `commands:` role map on the entity (`turn_on: power_on`), or
//! nothing — in which case conventional command names are searched
//! (SwitchBot declares `bot_turn_on`/`bot_turn_off` and no map at all).
//! Resolution ends at a *sendable* command: one whose every template
//! parameter is either owned by the control (`brightness`, `red`...) or
//! defaulted by the spec. That gate is what keeps a card honest — elk-bledom's
//! `set_light_on_off` takes an un-defaulted `cmd` byte the spec itself calls
//! ambiguous, so the strip gets brightness and color controls but no power
//! toggle until the spec pins that byte down.

use super::types::{
    Characteristic, CharacteristicProperty, Command, DeviceSpec, Entity, Service, SpecCommand,
    TemplateElement, ValueType,
};
use crate::codec::types::unsupported_encoding_kind;
use crate::protocol::{http, soap};

/// Whether a characteristic's payloads must pass through a byte transform
/// this crate does not implement, making any raw write to it wrong on the
/// wire.
///
/// `encryption` (shining-mask's AES-128-ECB, pax's OFB) and `framing`
/// (coolledx's length prefix, escaping and delimiters) are parsed and
/// preserved but never executed — see [`Characteristic`]. Encoding a template
/// for such a characteristic produces plaintext or unwrapped bytes the device
/// rejects, so the honest answer is that the control does not resolve yet.
/// Without this check the encoding gate only asks whether the *command* is
/// encodable, and a spec whose transform lives one level up slips through.
fn needs_unimplemented_transform(characteristic: &Characteristic) -> bool {
    characteristic.encryption.is_some() || characteristic.framing.is_some()
}

/// One resolved control action: the command to send for a role, and which
/// parameters the UI supplies when sending it.
#[derive(Debug)]
pub struct ResolvedAction<'a> {
    /// Canonical role name: `turn_on` | `turn_off` | `press` |
    /// `set_brightness` | `set_color` | `set_value`.
    pub role: &'static str,
    pub service: &'a Service,
    pub characteristic: &'a Characteristic,
    /// The command this role sends, or `None` for a `set_value` action that
    /// writes the encoded value straight to [`Self::characteristic`] — see
    /// [`resolve_set_value`] for when that is allowed.
    pub command_name: Option<&'a str>,
    /// Template parameters the UI owns, in template order — the subset of the
    /// role's vocabulary this command actually references. Empty for fixed
    /// commands. Everything else in the template is spec-defaulted.
    pub user_params: Vec<&'a str>,
    /// Declared bounds of the role's primary numeric parameter (brightness),
    /// so a slider can match the device's real range instead of assuming
    /// 0..255. `None` for roles without one.
    pub min: Option<i64>,
    pub max: Option<i64>,
}

/// How a role finds and qualifies its command.
struct RoleSpec {
    role: &'static str,
    /// Keys in the entity's `commands:` map that bind this role. Multiple
    /// because specs vary: govee-h6001 writes `power_on:` where most write
    /// `turn_on:`.
    aliases: &'static [&'static str],
    /// Command names tried, in order, when the entity declares no binding.
    fallback_exact: &'static [&'static str],
    /// Name suffixes tried after the exact names — SwitchBot prefixes its
    /// commands (`bot_turn_on`).
    fallback_suffixes: &'static [&'static str],
    /// Template parameters the UI can fill for this role.
    user_params: &'static [&'static str],
    /// Parameters that must appear in the template for the command to serve
    /// the role at all: a `set_color` that never takes red/green/blue would
    /// render a color picker that changes nothing.
    required_user_params: &'static [&'static str],
}

impl RoleSpec {
    /// Roles whose whole point is user input can't be served by a fixed
    /// byte sequence.
    fn needs_user_input(&self) -> bool {
        !self.required_user_params.is_empty()
    }
}

const TURN_ON: RoleSpec = RoleSpec {
    role: "turn_on",
    aliases: &["turn_on", "power_on"],
    fallback_exact: &["turn_on", "power_on", "screen_on"],
    fallback_suffixes: &["_turn_on", "_power_on"],
    user_params: &[],
    required_user_params: &[],
};

const TURN_OFF: RoleSpec = RoleSpec {
    role: "turn_off",
    aliases: &["turn_off", "power_off"],
    fallback_exact: &["turn_off", "power_off", "screen_off"],
    fallback_suffixes: &["_turn_off", "_power_off"],
    user_params: &[],
    required_user_params: &[],
};

const PRESS: RoleSpec = RoleSpec {
    role: "press",
    aliases: &["press"],
    fallback_exact: &["press"],
    fallback_suffixes: &["_press"],
    user_params: &[],
    required_user_params: &[],
};

const SET_BRIGHTNESS: RoleSpec = RoleSpec {
    role: "set_brightness",
    aliases: &["set_brightness"],
    fallback_exact: &["set_brightness"],
    fallback_suffixes: &[],
    // `level` is sp107e/sp110e's name for the same knob.
    user_params: &["brightness", "level"],
    required_user_params: &[],
};

const SET_COLOR: RoleSpec = RoleSpec {
    role: "set_color",
    aliases: &["set_color"],
    fallback_exact: &["set_color", "set_rgb_color"],
    fallback_suffixes: &[],
    // Ember's `set_led_color` packs brightness into the same write, so the
    // color role may carry the brightness value along.
    user_params: &["red", "green", "blue", "brightness"],
    required_user_params: &["red", "green", "blue"],
};

/// Resolve every control action a spec supports for one entity.
///
/// Only `switch` and `light` platforms resolve today; other platforms return
/// no actions and keep rendering as they already do. `set_brightness` is
/// special-cased to require a user parameter: a fixed "brightness" command
/// with no input is a button, not a slider, and pretending otherwise puts a
/// dead control on screen.
pub fn resolve_entity_actions<'a>(
    spec: &'a DeviceSpec,
    entity: &'a Entity,
) -> Vec<ResolvedAction<'a>> {
    // `number` and `climate` resolve a single setpoint action, which is
    // structural rather than vocabulary-based — see `resolve_set_value`.
    if matches!(entity.platform.as_deref(), Some("number") | Some("climate")) {
        return resolve_set_value(spec, entity).into_iter().collect();
    }

    let roles: &[&RoleSpec] = match entity.platform.as_deref() {
        Some("switch") => &[&TURN_ON, &TURN_OFF, &PRESS],
        Some("light") => &[&TURN_ON, &TURN_OFF, &SET_BRIGHTNESS, &SET_COLOR],
        _ => return Vec::new(),
    };

    roles
        .iter()
        .filter_map(|role| resolve_role(spec, entity, role))
        .collect()
}

/// Command names a setpoint entity's `commands:` map may bind, and the
/// conventional names tried when it binds nothing.
const SET_VALUE_ALIASES: &[&str] = &["set_value", "set_temperature", "set_target"];
const SET_VALUE_FALLBACKS: &[&str] = &[
    "set_value",
    "set_target_temp",
    "set_temperature",
    "set_level",
];

/// Resolve the one action a `number`/`climate` entity supports: writing a
/// value the user chose.
///
/// Two shapes qualify, in order:
///
/// 1. **A command taking exactly one value.** The entity binds a command (or
///    one of the conventional names resolves) whose template references
///    exactly one parameter the spec does not default. That parameter carries
///    the setpoint; everything else is protocol filler the encoder fills in.
///    A command needing *two* un-defaulted parameters does not qualify —
///    Ember splits its centi-°C target across `temp_low`/`temp_high` and
///    which byte is which is stated only in prose, so guessing would write a
///    wildly wrong temperature.
///
/// 2. **A direct write.** No command qualifies, but the entity explicitly
///    declares a `command_characteristic` that is writable and carries a
///    `format:` of exactly one field. The explicit declaration is the gate:
///    it is the spec author saying "this entity's writes go here", and with a
///    single field the byte layout is unambiguous. Gerbing's heat channels
///    are this shape — one `uint8` percentage, written and read through the
///    same characteristic.
fn resolve_set_value<'a>(spec: &'a DeviceSpec, entity: &'a Entity) -> Option<ResolvedAction<'a>> {
    // An explicit binding that names a real command settles it, exactly as in
    // `resolve_role`: falling past it could send a different command than the
    // author bound.
    for alias in SET_VALUE_ALIASES {
        let Some(bound) = entity.command_for_role(alias) else {
            continue;
        };
        if let Some((service, characteristic, name, command)) =
            find_command(spec, entity, |n| n == bound)
        {
            return qualify_set_value(service, characteristic, name, command);
        }
    }

    for fallback in SET_VALUE_FALLBACKS {
        if let Some((service, characteristic, name, command)) =
            find_command(spec, entity, |n| n == *fallback)
        {
            if let Some(action) = qualify_set_value(service, characteristic, name, command) {
                return Some(action);
            }
        }
    }

    resolve_direct_write(spec, entity)
}

/// Qualify a command for the `set_value` role: it must reference exactly one
/// un-defaulted parameter, which then receives the setpoint.
fn qualify_set_value<'a>(
    service: &'a Service,
    characteristic: &'a Characteristic,
    name: &'a str,
    command: &'a Command,
) -> Option<ResolvedAction<'a>> {
    if needs_unimplemented_transform(characteristic) || unsupported_encoding_kind(command).is_some()
    {
        return None;
    }
    // A fixed byte sequence cannot carry a value the user picked.
    let template = command.template.as_ref()?;

    let mut value_param: Option<&str> = None;
    for element in template {
        let TemplateElement::Param(param_name) = element else {
            continue;
        };
        let declared = command
            .parameters
            .as_ref()
            .and_then(|set| set.params.get(param_name.as_str()));
        // A default fills the parameter, and so does `auto`: the encoder
        // computes checksums, sequence numbers and packet lengths itself,
        // so neither shape leaves a blank the user must own.
        if declared.is_some_and(|p| p.default.is_some() || p.auto.is_some()) {
            continue;
        }
        match value_param {
            // A second un-defaulted parameter makes the mapping ambiguous.
            Some(first) if first != param_name => return None,
            Some(_) => {}
            None => value_param = Some(param_name),
        }
    }
    let value_param = value_param?;

    let declared = command
        .parameters
        .as_ref()
        .and_then(|set| set.params.get(value_param));
    Some(ResolvedAction {
        role: SET_VALUE_ROLE,
        service,
        characteristic,
        command_name: Some(name),
        user_params: vec![value_param],
        min: declared.and_then(|p| p.min),
        max: declared.and_then(|p| p.max),
    })
}

/// Resolve the direct-write shape described in [`resolve_set_value`].
fn resolve_direct_write<'a>(
    spec: &'a DeviceSpec,
    entity: &'a Entity,
) -> Option<ResolvedAction<'a>> {
    let uuid = entity.command_characteristic.as_deref()?;
    let (service, characteristic) =
        spec.find_characteristic_where(uuid, |c| c.format.as_ref().is_some_and(|f| f.len() == 1))?;
    // Same gate as the command path: a raw value written to a characteristic
    // that encrypts or frames its payloads lands as the wrong bytes.
    if needs_unimplemented_transform(characteristic) {
        return None;
    }
    let writable = characteristic
        .properties
        .contains(&CharacteristicProperty::Write)
        || characteristic
            .properties
            .contains(&CharacteristicProperty::WriteWithoutResponse);
    if !writable {
        return None;
    }
    let field = characteristic.format.as_ref()?;
    // Exactly one field: with two, which one the value belongs to is a guess.
    let [field] = field.as_slice() else {
        return None;
    };
    // The value has to be expressible as an integer of known width.
    let (type_min, type_max) = field.field_type.integer_range()?;

    Some(ResolvedAction {
        role: SET_VALUE_ROLE,
        service,
        characteristic,
        command_name: None,
        user_params: Vec::new(),
        min: Some(type_min),
        max: Some(type_max),
    })
}

const SET_VALUE_ROLE: &str = "set_value";

/// The linear map between raw wire values and the decoded values a user sees:
/// `value = raw * scale + value_offset`.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct ValueTransform {
    pub scale: f64,
    pub value_offset: f64,
}

impl ValueTransform {
    pub const IDENTITY: Self = Self {
        scale: 1.0,
        value_offset: 0.0,
    };

    /// Raw → decoded.
    pub fn decode(&self, raw: f64) -> f64 {
        raw * self.scale + self.value_offset
    }

    /// Decoded → raw, rounded to the nearest whole wire value. `None` when
    /// `scale` is zero: that map is not invertible, and quietly substituting
    /// 1.0 would write a number the user never asked for.
    pub fn encode(&self, value: f64) -> Option<f64> {
        if self.scale == 0.0 {
            return None;
        }
        Some(((value - self.value_offset) / self.scale).round())
    }
}

/// Resolve the raw↔decoded transform for a setpoint action.
///
/// Most specific wins, because each source describes a narrower thing than
/// the last:
/// 1. the command parameter's own number semantics — it describes this exact
///    write;
/// 2. the entity's `state_mapping.scale` — the entity layer's statement about
///    its own value (Ember declares `scale: 0.01` here);
/// 3. the bound state field's `scale`/`value_offset` — how the device encodes
///    the quantity generally (Gerbing's `raw * 0.5 + 85`);
/// 4. identity.
pub fn setpoint_transform(
    spec: &DeviceSpec,
    entity: &Entity,
    action: &ResolvedAction<'_>,
) -> ValueTransform {
    if let (Some(command_name), Some(param_name)) =
        (action.command_name, action.user_params.first())
    {
        let param = action
            .characteristic
            .commands
            .as_ref()
            .and_then(|cmds| cmds.get(command_name))
            .and_then(|cmd| cmd.parameters.as_ref())
            .and_then(|set| set.params.get(*param_name));
        if let Some(param) = param.filter(|p| p.has_number_semantics()) {
            return ValueTransform {
                scale: param.scale.unwrap_or(1.0),
                value_offset: param.value_offset.unwrap_or(0.0),
            };
        }
    }

    if let Some(scale) = entity.value_scale() {
        return ValueTransform {
            scale,
            value_offset: 0.0,
        };
    }

    // The field the value is written to — for a direct write that is the
    // action's own single field, otherwise the entity's state field.
    let field = if action.command_name.is_none() {
        action
            .characteristic
            .format
            .as_ref()
            .and_then(|fields| fields.first())
    } else {
        entity
            .state_characteristic
            .as_deref()
            .and_then(|uuid| spec.find_decodable_characteristic(uuid))
            .and_then(|(_, c)| c.format.as_ref())
            .and_then(|fields| {
                let wanted = entity.value_field();
                match wanted {
                    Some(name) => fields.iter().find(|f| f.name == name),
                    None => fields.first(),
                }
            })
    };

    field.map_or(ValueTransform::IDENTITY, |f| ValueTransform {
        scale: f.scale.unwrap_or(1.0),
        value_offset: f.value_offset.unwrap_or(0.0),
    })
}

/// The wire type a setpoint action's value is encoded as: the bound
/// parameter's declared type, or the single format field's for a direct
/// write.
pub fn setpoint_value_type(action: &ResolvedAction<'_>) -> Option<ValueType> {
    match (action.command_name, action.user_params.first()) {
        (Some(command_name), Some(param_name)) => action
            .characteristic
            .commands
            .as_ref()
            .and_then(|cmds| cmds.get(command_name))
            .and_then(|cmd| cmd.parameters.as_ref())
            .and_then(|set| set.params.get(*param_name))
            .map(|p| p.value_type.clone()),
        _ => action
            .characteristic
            .format
            .as_ref()
            .and_then(|fields| fields.first())
            .map(|f| f.field_type.clone()),
    }
}

fn resolve_role<'a>(
    spec: &'a DeviceSpec,
    entity: &'a Entity,
    role: &RoleSpec,
) -> Option<ResolvedAction<'a>> {
    // An explicit binding that names a real command settles the question:
    // qualify that command or resolve nothing. Falling back past it could
    // pick a *different* command than the one the spec author bound, and a
    // wrong write is worse than a missing control. A binding that names no
    // declared command (ember's switch carries prose here) proves nothing,
    // so the conventional-name search still runs.
    for alias in role.aliases {
        let Some(bound_name) = entity.command_for_role(alias) else {
            continue;
        };
        if let Some((service, characteristic, name, command)) =
            find_command(spec, entity, |n| n == bound_name)
        {
            return qualify(role, service, characteristic, name, command);
        }
    }

    for exact in role.fallback_exact {
        if let Some(found) = find_command(spec, entity, |n| n == *exact) {
            let (service, characteristic, name, command) = found;
            if let Some(action) = qualify(role, service, characteristic, name, command) {
                return Some(action);
            }
        }
    }
    for suffix in role.fallback_suffixes {
        if let Some(found) = find_command(spec, entity, |n| n.ends_with(suffix)) {
            let (service, characteristic, name, command) = found;
            if let Some(action) = qualify(role, service, characteristic, name, command) {
                return Some(action);
            }
        }
    }
    None
}

/// First command matching `pred`, searching the entity's declared
/// `command_characteristic` when it has one and the whole spec otherwise, in
/// declaration order.
fn find_command<'a>(
    spec: &'a DeviceSpec,
    entity: &'a Entity,
    pred: impl Fn(&str) -> bool,
) -> Option<(&'a Service, &'a Characteristic, &'a str, &'a Command)> {
    let restrict = entity.command_characteristic.as_deref();
    for service in &spec.services {
        for characteristic in &service.characteristics {
            if let Some(uuid) = restrict {
                if !characteristic.uuid.eq_ignore_ascii_case(uuid) {
                    continue;
                }
            }
            let Some(commands) = &characteristic.commands else {
                continue;
            };
            for (name, command) in commands {
                if pred(name) {
                    return Some((service, characteristic, name, command));
                }
            }
        }
    }
    None
}

/// Decide whether `command` can actually serve `role`, and with which UI
/// parameters.
fn qualify<'a>(
    role: &RoleSpec,
    service: &'a Service,
    characteristic: &'a Characteristic,
    name: &'a str,
    command: &'a Command,
) -> Option<ResolvedAction<'a>> {
    // JSON/protobuf/TLV commands can't be encoded at all yet, and neither can
    // any command on a characteristic whose bytes must be transformed on the
    // way out.
    if needs_unimplemented_transform(characteristic) || unsupported_encoding_kind(command).is_some()
    {
        return None;
    }

    // Fixed byte sequences (either envelope) take no input.
    if command.value.is_some() || command.payload_bytes().is_some() {
        if role.needs_user_input() || role.role == SET_BRIGHTNESS.role {
            return None;
        }
        return Some(ResolvedAction {
            role: role.role,
            service,
            characteristic,
            command_name: Some(name),
            user_params: Vec::new(),
            min: None,
            max: None,
        });
    }

    let template = command.template.as_ref()?;

    // Every referenced parameter must be either UI-owned or spec-defaulted;
    // one un-defaulted protocol byte disqualifies the command for automatic
    // sending.
    let mut user_params: Vec<&str> = Vec::new();
    for element in template {
        let TemplateElement::Param(param_name) = element else {
            continue;
        };
        if user_params.contains(&param_name.as_str()) {
            continue;
        }
        if role.user_params.contains(&param_name.as_str()) {
            user_params.push(param_name);
            continue;
        }
        // Spec-supplied either way: a default is a stated value, `auto` is a
        // value the encoder computes (checksum, sequence, packet_length).
        let supplied = command
            .parameters
            .as_ref()
            .and_then(|set| set.params.get(param_name.as_str()))
            .is_some_and(|p| p.default.is_some() || p.auto.is_some());
        if !supplied {
            return None;
        }
    }

    for required in role.required_user_params {
        if !user_params.contains(required) {
            return None;
        }
    }
    // A brightness command that takes no brightness input is a button
    // pretending to be a slider.
    if role.role == SET_BRIGHTNESS.role && user_params.is_empty() {
        return None;
    }

    // Slider bounds come from the primary numeric parameter's declaration,
    // falling back to its type's own range.
    let (min, max) = if role.role == SET_BRIGHTNESS.role {
        let primary = command
            .parameters
            .as_ref()
            .and_then(|set| set.params.get(user_params[0]));
        match primary {
            Some(p) => {
                let type_range = p.value_type.integer_range();
                (
                    p.min.or(type_range.map(|(lo, _)| lo)),
                    p.max.or(type_range.map(|(_, hi)| hi)),
                )
            }
            None => (None, None),
        }
    } else {
        (None, None)
    };

    Some(ResolvedAction {
        role: role.role,
        service,
        characteristic,
        command_name: Some(name),
        user_params,
        min,
        max,
    })
}

// ── The same job for a device with no GATT ──────────────────────────────────
//
// A Wemo plug has no characteristic to bind to, so its entities bind an
// endpoint and a command name, and the roles resolve against the spec's
// top-level `commands` instead of a characteristic's. Everything above this
// line — which role a platform offers, what makes a command sendable, that a
// valued control needs exactly one blank to fill — is the same on both sides,
// and is deliberately spelled the same way here so the two cannot drift into
// different ideas of what `turn_on` means.

/// One resolved control action on a network device.
///
/// The network sibling of [`ResolvedAction`], and a separate type on purpose:
/// that one borrows the service and characteristic a caller needs to talk to
/// the radio, and there is no honest value to put in either field here.
#[derive(Debug)]
pub struct NetworkAction<'a> {
    /// Canonical role name, from the same vocabulary the BLE path uses.
    pub role: &'static str,
    pub command_name: &'a str,
    pub command: &'a SpecCommand,
    /// The one value this control supplies, when it has one. Empty for a
    /// fixed action like `turn_off`.
    pub user_params: Vec<&'a str>,
    /// Parameters the command defaults but whose real value the client should
    /// read from the device first, as (parameter, `source`).
    ///
    /// Surfaced rather than left inside the command because it changes what a
    /// caller must DO: send this action without reading these back and the
    /// write silently overwrites settings the user never touched.
    pub read_back: Vec<(&'a str, &'a str)>,
    pub min: Option<f64>,
    pub max: Option<f64>,
}

/// One role a network entity can bind, and how to tell whether a command can
/// serve it.
struct NetworkRole {
    /// Canonical name, reported to the caller.
    role: &'static str,
    /// Keys in the entity's `commands:` map that bind this role, in order.
    aliases: &'static [&'static str],
    /// Whether the control supplies a value. A valued role needs exactly one
    /// blank in the command; a fixed one needs none.
    takes_value: bool,
}

/// The setpoint role's aliases, shared by every platform that has one so a
/// `number` and a `climate` cannot drift into different vocabularies.
const SETPOINT_ALIASES: &[&str] = &["set_value", "set_temperature", "set_target"];

const NETWORK_SETPOINT: NetworkRole = NetworkRole {
    role: SET_VALUE_ROLE,
    aliases: SETPOINT_ALIASES,
    takes_value: true,
};

/// Roles each platform offers on the network path.
///
/// Kept beside the BLE `RoleSpec` table, and using the same role names on
/// purpose: two tables that disagreed about what `switch` offers would give
/// one device different controls depending on how it happened to connect.
const NETWORK_ROLES: &[(&str, &[NetworkRole])] = &[
    (
        "switch",
        &[
            NetworkRole {
                role: TURN_ON.role,
                aliases: TURN_ON.aliases,
                takes_value: false,
            },
            NetworkRole {
                role: TURN_OFF.role,
                aliases: TURN_OFF.aliases,
                takes_value: false,
            },
        ],
    ),
    (
        "button",
        &[NetworkRole {
            // A momentary action: one fixed role, nothing to fill in. The
            // platform a remote key is — Roku's whole control surface is
            // twenty-odd of these.
            role: PRESS.role,
            aliases: PRESS.aliases,
            takes_value: false,
        }],
    ),
    (
        "light",
        &[
            NetworkRole {
                role: TURN_ON.role,
                aliases: TURN_ON.aliases,
                takes_value: false,
            },
            NetworkRole {
                role: TURN_OFF.role,
                aliases: TURN_OFF.aliases,
                takes_value: false,
            },
            NetworkRole {
                role: SET_BRIGHTNESS.role,
                aliases: SET_BRIGHTNESS.aliases,
                takes_value: true,
            },
        ],
    ),
    (
        "select",
        &[NetworkRole {
            // The role a heat-level picker needs, and the one nothing in the
            // catalogue could resolve before a Crock-Pot turned up: its modes
            // are 0/50/51/52, which is a choice from a list and not a number
            // anybody can slide between.
            role: "select_option",
            aliases: &["select_option", "set_option"],
            takes_value: true,
        }],
    ),
    (
        "text",
        &[
            NetworkRole {
                // Text entry into whatever field the device has focused:
                // one valued send per keystroke (Roku's Lit_ key form),
                // because the wire carries no string type.
                role: "submit",
                aliases: &["submit", "type"],
                takes_value: true,
            },
            NetworkRole {
                // The deletion key beside the field — backspace. Optional:
                // a text entity without it simply cannot delete.
                role: PRESS.role,
                aliases: PRESS.aliases,
                takes_value: false,
            },
        ],
    ),
    ("number", &[NETWORK_SETPOINT]),
    ("climate", &[NETWORK_SETPOINT]),
    (
        "fan",
        &[NetworkRole {
            role: SET_VALUE_ROLE,
            aliases: &["set_value", "set_speed"],
            takes_value: true,
        }],
    ),
];

/// Resolve every control action a spec supports for one network entity.
///
/// Returns nothing for an entity that binds no `state_command` — that is a
/// BLE entity, or an entity that reaches nothing at all, and either way this
/// is not its path.
pub fn resolve_network_actions<'a>(
    spec: &'a DeviceSpec,
    entity: &'a Entity,
) -> Vec<NetworkAction<'a>> {
    if !on_network_surface(spec, entity) {
        return Vec::new();
    }
    let platform = entity.platform.as_deref().unwrap_or_default();
    let Some((_, roles)) = NETWORK_ROLES.iter().find(|(name, _)| *name == platform) else {
        return Vec::new();
    };

    roles
        .iter()
        .filter_map(|role| {
            let bound = role
                .aliases
                .iter()
                .find_map(|alias| entity.command_for_role(alias))?;
            let command = spec.commands.get(bound)?;
            qualify_network(role.role, bound, command, role.takes_value)
        })
        .collect()
}

/// Decide whether a command can serve a network role.
///
/// The gate is the one the BLE path applies, for the same reason: a control
/// may only offer what it can actually send. A fixed role cannot fill in a
/// blank, and a valued role with two blanks does not know which one its value
/// belongs in — Wemo's `SetCrockpotState` would be exactly that if the spec
/// did not default the argument the control is not changing.
fn qualify_network<'a>(
    role: &'static str,
    command_name: &'a str,
    command: &'a SpecCommand,
    takes_value: bool,
) -> Option<NetworkAction<'a>> {
    // Renderable at all: a command missing its transport's address, or one for
    // a transport this crate does not speak, resolves to nothing rather than
    // to a control that errors when pressed. Each transport is whole on its
    // own terms — SOAP needs the service URN and action its envelope is built
    // from, plain HTTP needs the method and path that ARE the request.
    match command.transport.as_deref().unwrap_or(soap::TRANSPORT) {
        soap::TRANSPORT => {
            if command.service.is_none() || command.action.is_none() {
                return None;
            }
        }
        http::TRANSPORT => {
            // The method must be one a client of this transport can actually
            // send, not merely present: the schema allows PUT/DELETE/PATCH,
            // and resolving a control for one would put a button on screen
            // whose every press fails inside the client.
            match command.method.as_deref() {
                Some(method) if http::is_sendable_method(method) => {}
                _ => return None,
            }
            command.path.as_ref()?;
        }
        _ => return None,
    }

    let user_params = command.user_params();
    match (takes_value, user_params.len()) {
        (false, 0) => {}
        (true, 1) => {}
        _ => return None,
    }

    let bounds = user_params
        .first()
        .and_then(|name| command.parameters.get(*name));
    Some(NetworkAction {
        role,
        command_name,
        command,
        min: bounds.and_then(|p| p.min),
        max: bounds.and_then(|p| p.max),
        user_params,
        read_back: command.read_back_params(),
    })
}

/// Whether an entity belongs on the network control surface at all.
///
/// The honesty rule with its three carve-outs: an entity is listed when it
/// says where its reading comes from (`state_command`), because a control
/// that can never update is worse than an absent one — except a `button`,
/// which is momentary and has no resulting state to read, a `text`, whose
/// surface is the input field itself (the device never reports what its
/// focused field holds), and a `select` carrying an `options_source`, whose
/// device-fetched options ARE its surface (the schema says so in the same
/// words). Requiring state of any of them would just push spec authors to
/// invent fake bindings.
///
/// The options-source carve-out demands the source actually resolve — the
/// named endpoint present and not sunset — because a select admitted on the
/// strength of a list that can never load is exactly the dead control the
/// rule exists to keep off screen.
fn on_network_surface(spec: &DeviceSpec, entity: &Entity) -> bool {
    entity.state_command.is_some()
        || matches!(entity.platform.as_deref(), Some("button") | Some("text"))
        || entity
            .options_source
            .as_ref()
            .is_some_and(|source| http::endpoint_request(spec, &source.command).is_some())
}

/// Entities a spec drives over the network — see [`on_network_surface`] for
/// the admission rule. The network counterpart of
/// [`DeviceSpec::resolved_entities`].
pub fn network_entities(spec: &DeviceSpec) -> Vec<&Entity> {
    spec.entities
        .iter()
        .filter(|e| on_network_surface(spec, e))
        .collect()
}

/// [`network_entities`], further narrowed to the variants a device's own SSDP
/// answers say it is.
///
/// One spec covers a whole family — wemo-devices spans plugs, dimmers, a
/// bridge and a slow cooker — and its entities carry `variants` lists saying
/// which models each control applies to. A device announces its model in the
/// search targets it answers (`urn:Belkin:device:crockpot:1`), so the two can
/// be joined: a variant matches when any target equals its
/// `identification.device_type` (or an alternate), and an entity survives
/// when it is unscoped or names a matched variant.
///
/// The failure this exists to prevent is concrete: without it, every Wemo
/// plug gets a Cook Mode picker whose writes the plug answers with a SOAP
/// fault — or worse, doesn't. When no variant matches at all, scoped entities
/// are dropped rather than shown: an unidentified model gets no controls
/// instead of a stranger's.
pub fn network_entities_for_targets<'a>(
    spec: &'a DeviceSpec,
    ssdp_targets: &[String],
) -> Vec<&'a Entity> {
    let matched = matched_variant_names(spec, ssdp_targets);
    network_entities(spec)
        .into_iter()
        .filter(|entity| match entity_variants(entity) {
            None => true,
            Some(scoped) => scoped.iter().any(|name| matched.contains(name)),
        })
        .collect()
}

/// Names of the `device.variants` entries whose declared device type (or an
/// alternate) appears among the SSDP targets a device answered to.
fn matched_variant_names(spec: &DeviceSpec, ssdp_targets: &[String]) -> Vec<String> {
    let Some(variants) = spec.device.variants.as_ref().and_then(|v| v.as_sequence()) else {
        return Vec::new();
    };
    variants
        .iter()
        .filter_map(|variant| {
            let identification = variant.get("identification")?;
            let mut types: Vec<&str> = identification
                .get("device_type")
                .and_then(|t| t.as_str())
                .into_iter()
                .collect();
            if let Some(alternates) = identification
                .get("alternate_device_types")
                .and_then(|a| a.as_sequence())
            {
                types.extend(alternates.iter().filter_map(|t| t.as_str()));
            }
            let hit = types
                .iter()
                .any(|t| ssdp_targets.iter().any(|s| s.eq_ignore_ascii_case(t)));
            if !hit {
                return None;
            }
            // Display name first: that is what entity `variants` lists cite
            // (the spec's own tests hold it to that), with `model` accepted
            // for a spec that scopes by model number instead.
            variant
                .get("name")
                .or_else(|| variant.get("model"))
                .and_then(|n| n.as_str())
                .map(str::to_string)
        })
        .collect()
}

/// An entity's `variants` scoping list, or `None` when it is unscoped.
///
/// `Some(vec![])` and `None` are different on purpose, mirroring the schema:
/// an empty list would claim "applies to no model at all", and the schema
/// forbids writing one (`minItems: 1`) precisely because it always means a
/// half-deleted edit rather than an intention.
fn entity_variants(entity: &Entity) -> Option<Vec<String>> {
    let value = entity.extensions.get("variants")?;
    let list = value.as_sequence()?;
    Some(
        list.iter()
            .filter_map(|v| v.as_str().map(str::to_string))
            .collect(),
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::spec::parser::parse_device_spec;

    fn spec_with(entities: &str, services: &str) -> DeviceSpec {
        let yaml = format!(
            r#"
device:
  name: Test Device
  manufacturer: Test
  manufacturer_status: abandoned
  protocol: ble
services:
{services}
entities:
{entities}
"#
        );
        parse_device_spec(&yaml).expect("test spec should parse")
    }

    fn actions_for<'a>(spec: &'a DeviceSpec) -> Vec<ResolvedAction<'a>> {
        resolve_entity_actions(spec, &spec.entities[0])
    }

    fn roles(actions: &[ResolvedAction<'_>]) -> Vec<&'static str> {
        actions.iter().map(|a| a.role).collect()
    }

    /// example-bulb's shape: explicit role map, fixed on/off, parameterized
    /// brightness and color.
    #[test]
    fn explicit_role_map_resolves_all_roles() {
        let spec = spec_with(
            r#"
  - name: Bulb
    platform: light
    state_characteristic: "0000fff2-0000-1000-8000-00805f9b34fb"
    commands:
      turn_on: power_on
      turn_off: power_off
      set_brightness: set_brightness
      set_color: set_color
"#,
            r#"
  - uuid: "0000fff0-0000-1000-8000-00805f9b34fb"
    name: Control
    characteristics:
      - uuid: "0000fff1-0000-1000-8000-00805f9b34fb"
        name: Write
        properties: [write]
        commands:
          power_on:
            description: On
            value: [204, 35, 51]
          power_off:
            description: Off
            value: [204, 36, 51]
          set_brightness:
            description: Brightness
            template: [86, "{brightness}", 170]
            parameters:
              brightness:
                type: uint8
                min: 0
                max: 100
          set_color:
            description: Color
            template: [86, "{red}", "{green}", "{blue}", 170]
            parameters:
              red: {type: uint8}
              green: {type: uint8}
              blue: {type: uint8}
"#,
        );
        let actions = actions_for(&spec);
        assert_eq!(
            roles(&actions),
            vec!["turn_on", "turn_off", "set_brightness", "set_color"]
        );

        let brightness = &actions[2];
        assert_eq!(brightness.command_name, Some("set_brightness"));
        assert_eq!(brightness.user_params, vec!["brightness"]);
        assert_eq!((brightness.min, brightness.max), (Some(0), Some(100)));

        let color = &actions[3];
        assert_eq!(color.user_params, vec!["red", "green", "blue"]);
    }

    /// SwitchBot's shape: no role map; prefixed command names resolve through
    /// the suffix fallback, and `press` resolves alongside on/off.
    #[test]
    fn suffix_fallback_resolves_prefixed_commands() {
        let spec = spec_with(
            r#"
  - name: Bot Press
    platform: switch
    state_characteristic: "cba20003-224d-11e6-9fb8-0002a5d5c51b"
"#,
            r#"
  - uuid: "cba20d00-224d-11e6-9fb8-0002a5d5c51b"
    name: Bot
    characteristics:
      - uuid: "cba20002-224d-11e6-9fb8-0002a5d5c51b"
        name: Command
        properties: [write]
        commands:
          bot_press:
            description: Press
            value: [87, 1, 0]
          bot_turn_on:
            description: On
            value: [87, 1, 1]
          bot_turn_off:
            description: Off
            value: [87, 1, 2]
"#,
        );
        let actions = actions_for(&spec);
        assert_eq!(roles(&actions), vec!["turn_on", "turn_off", "press"]);
        assert_eq!(actions[0].command_name, Some("bot_turn_on"));
        assert_eq!(actions[2].command_name, Some("bot_press"));
    }

    /// elk-bledom's shape: brightness/color commands are fully defaulted
    /// besides the UI-owned params, but the on/off command has an un-defaulted
    /// `cmd` byte — so power must NOT resolve.
    #[test]
    fn undefaulted_protocol_param_disqualifies_command() {
        let spec = spec_with(
            r#"
  - name: LED Strip
    platform: light
    state_characteristic: "0000fff4-0000-1000-8000-00805f9b34fb"
"#,
            r#"
  - uuid: "0000fff0-0000-1000-8000-00805f9b34fb"
    name: Control
    characteristics:
      - uuid: "0000fff3-0000-1000-8000-00805f9b34fb"
        name: Write
        properties: [write]
        commands:
          set_rgb_color:
            description: Color
            template: [126, "{seq}", 5, 3, "{red}", "{green}", "{blue}", "{flag}", 239]
            parameters:
              seq: {type: uint8, default: 0}
              red: {type: uint8}
              green: {type: uint8}
              blue: {type: uint8}
              flag: {type: uint8, default: 0}
          set_brightness:
            description: Brightness
            template: [126, "{seq}", 1, "{brightness}", "{light_mode}", 0, 0, "{flag}", 239]
            parameters:
              seq: {type: uint8, default: 0}
              brightness: {type: uint8, min: 0, max: 100}
              light_mode: {type: uint8, default: 255}
              flag: {type: uint8, default: 0}
          set_light_on_off:
            description: Power, but the command byte varies by app version.
            template: [126, "{seq}", "{cmd}", "{state}", 255, 255, 255, "{flag}", 239]
            parameters:
              seq: {type: uint8, default: 0}
              cmd: {type: uint8}
              state: {type: uint8}
              flag: {type: uint8, default: 0}
"#,
        );
        let actions = actions_for(&spec);
        // No power: set_light_on_off's `cmd`/`state` have no defaults and are
        // not part of any role vocabulary.
        assert_eq!(roles(&actions), vec!["set_brightness", "set_color"]);
        assert_eq!((actions[0].min, actions[0].max), (Some(0), Some(100)));
    }

    /// govee-h5080's shape: a stateless switch whose on/off commands are
    /// `encoding: bytes` + `payload.bytes`.
    #[test]
    fn payload_bytes_commands_resolve_for_switch() {
        let spec = spec_with(
            r#"
  - name: Plug Outlet
    platform: switch
    commands:
      turn_on: turn_on
      turn_off: turn_off
"#,
            r#"
  - uuid: "00010203-0405-0607-0809-0a0b0c0d1910"
    name: Control
    characteristics:
      - uuid: "00010203-0405-0607-0809-0a0b0c0d2b11"
        name: Control Write
        properties: [write_without_response]
        commands:
          turn_on:
            description: On
            encoding: bytes
            payload:
              bytes: [51, 1, 1, 205]
          turn_off:
            description: Off
            encoding: bytes
            payload:
              bytes: [51, 1, 0, 204]
"#,
        );
        let actions = actions_for(&spec);
        assert_eq!(roles(&actions), vec!["turn_on", "turn_off"]);
    }

    /// ember's switch shape: the role map carries prose, not command names.
    /// Prose proves nothing, and with no conventionally-named commands either,
    /// no action resolves.
    #[test]
    fn prose_role_binding_resolves_nothing() {
        let spec = spec_with(
            r#"
  - name: Temperature Control
    platform: switch
    state_characteristic: "fc540003-236c-4c94-8fa9-944a3e5353fa"
    commands:
      turn_off: set target temp raw to 0x0000
      turn_on: restore previous nonzero target temperature
"#,
            r#"
  - uuid: "fc543622-236c-4c94-8fa9-944a3e5353fa"
    name: Ember
    characteristics:
      - uuid: "fc540003-236c-4c94-8fa9-944a3e5353fa"
        name: Target Temperature
        properties: [read, write]
        commands:
          set_target_temp:
            description: Set target
            template: ["{temp_low}", "{temp_high}"]
            parameters:
              temp_low: {type: uint8}
              temp_high: {type: uint8}
"#,
        );
        assert!(actions_for(&spec).is_empty());
    }

    /// An explicit binding to a command that exists but is not sendable
    /// (protobuf) must not fall back to some other command — the author said
    /// which command serves the role.
    #[test]
    fn explicit_binding_to_unsendable_command_does_not_fall_back() {
        let spec = spec_with(
            r#"
  - name: Tip Over Flash
    platform: switch
    commands:
      turn_on: set_tipover
      turn_off: set_tipover
"#,
            r#"
  - uuid: "6e400001-b5a3-f393-e0a9-e50e24dcca9e"
    name: NUS
    characteristics:
      - uuid: "6e400002-b5a3-f393-e0a9-e50e24dcca9e"
        name: RX
        properties: [write]
        commands:
          set_tipover:
            description: Tip-over flash (protobuf)
            setting_id: SETTING_TIPOVER
          turn_on:
            description: A decoy that must not be picked.
            value: [1]
"#,
        );
        assert!(actions_for(&spec).is_empty());
    }

    /// A fixed command can serve on/off but never a color role: user input
    /// cannot flow into fixed bytes (xkglow's `set_rgb_color` declares both
    /// `value` and parameters; `value` wins at encode time).
    #[test]
    fn fixed_command_serves_power_but_not_color() {
        let spec = spec_with(
            r#"
  - name: LEDs
    platform: light
    commands:
      turn_on: set_rgb_color
      set_color: set_rgb_color
"#,
            r#"
  - uuid: "458a7133-0001-4e37-a4a4-5d8492586977"
    name: Control
    characteristics:
      - uuid: "458a7133-0002-4e37-a4a4-5d8492586977"
        name: Write
        properties: [write]
        commands:
          set_rgb_color:
            description: Fixed white
            value: [1, 255, 255, 255]
"#,
        );
        let actions = actions_for(&spec);
        assert_eq!(roles(&actions), vec!["turn_on"]);
    }

    /// A `command_characteristic` restricts the search: a same-named command
    /// on another characteristic must not resolve.
    #[test]
    fn command_characteristic_restricts_search() {
        let spec = spec_with(
            r#"
  - name: Grow Light
    platform: light
    state_characteristic: "0000ff01-0000-1000-8000-00805f9b34fb"
    command_characteristic: "0000ff02-0000-1000-8000-00805f9b34fb"
"#,
            r#"
  - uuid: "0000ff00-0000-1000-8000-00805f9b34fb"
    name: Control
    characteristics:
      - uuid: "0000ff01-0000-1000-8000-00805f9b34fb"
        name: Status
        properties: [read, notify]
        commands:
          turn_on:
            description: Wrong characteristic
            value: [1]
      - uuid: "0000ff02-0000-1000-8000-00805f9b34fb"
        name: Command
        properties: [write]
"#,
        );
        assert!(actions_for(&spec).is_empty());
    }

    /// ember's LED shape: the color command packs brightness into the same
    /// write; `brightness` rides along as a user param without its own
    /// `set_brightness` action.
    #[test]
    fn color_command_may_carry_brightness() {
        let spec = spec_with(
            r#"
  - name: LED
    platform: light
    commands:
      set_color: set_led_color
"#,
            r#"
  - uuid: "fc543622-236c-4c94-8fa9-944a3e5353fa"
    name: Ember
    characteristics:
      - uuid: "fc540014-236c-4c94-8fa9-944a3e5353fa"
        name: LED Color
        properties: [read, write]
        commands:
          set_led_color:
            description: Set LED color
            template: ["{red}", "{green}", "{blue}", "{brightness}"]
            parameters:
              red: {type: uint8}
              green: {type: uint8}
              blue: {type: uint8}
              brightness: {type: uint8}
"#,
        );
        let actions = actions_for(&spec);
        assert_eq!(roles(&actions), vec!["set_color"]);
        assert_eq!(
            actions[0].user_params,
            vec!["red", "green", "blue", "brightness"]
        );
    }

    // ── set_value (number / climate setpoints) ─────────────────────────────

    /// Gerbing's shape: no commands anywhere, but the entity nominates a
    /// writable characteristic whose format is a single field.
    #[test]
    fn direct_write_resolves_when_the_entity_nominates_a_writable_field() {
        let spec = spec_with(
            r#"
  - name: Heat Level 1
    platform: number
    unit: "%"
    min: 0
    max: 100
    step: 1
    state_characteristic: "90759319-1668-44da-9ef3-492d593bd1e5"
    command_characteristic: "90759319-1668-44da-9ef3-492d593bd1e5"
"#,
            r#"
  - uuid: "0313fb4e-198b-4f64-a883-52b218c10ccc"
    name: Heat Service
    characteristics:
      - uuid: "90759319-1668-44da-9ef3-492d593bd1e5"
        name: Heat Channel 1
        properties: [read, write]
        format:
          - offset: 0
            length: 1
            name: heat_percent
            type: uint8
            unit: "%"
"#,
        );
        let actions = actions_for(&spec);
        assert_eq!(roles(&actions), vec!["set_value"]);
        let action = &actions[0];
        assert_eq!(
            action.command_name, None,
            "a direct write has no command to name"
        );
        assert_eq!(
            action.characteristic.uuid,
            "90759319-1668-44da-9ef3-492d593bd1e5"
        );
        // Identity transform: the raw byte already is the percentage.
        let transform = setpoint_transform(&spec, &spec.entities[0], action);
        assert_eq!(transform, ValueTransform::IDENTITY);
    }

    /// A nominated characteristic that is read-only must not resolve: the
    /// entity would render a control that cannot possibly land.
    #[test]
    fn direct_write_requires_a_writable_characteristic() {
        let spec = spec_with(
            r#"
  - name: Heat Level
    platform: number
    command_characteristic: "90759319-1668-44da-9ef3-492d593bd1e5"
"#,
            r#"
  - uuid: "0313fb4e-198b-4f64-a883-52b218c10ccc"
    name: Heat Service
    characteristics:
      - uuid: "90759319-1668-44da-9ef3-492d593bd1e5"
        name: Heat Channel 1
        properties: [read]
        format:
          - offset: 0
            length: 1
            name: heat_percent
            type: uint8
"#,
        );
        assert!(actions_for(&spec).is_empty());
    }

    /// Two format fields make the byte layout ambiguous — which one the
    /// setpoint belongs to would be a guess.
    #[test]
    fn direct_write_requires_a_single_format_field() {
        let spec = spec_with(
            r#"
  - name: Heat Level
    platform: number
    command_characteristic: "90759319-1668-44da-9ef3-492d593bd1e5"
"#,
            r#"
  - uuid: "0313fb4e-198b-4f64-a883-52b218c10ccc"
    name: Heat Service
    characteristics:
      - uuid: "90759319-1668-44da-9ef3-492d593bd1e5"
        name: Heat Channel 1
        properties: [read, write]
        format:
          - offset: 0
            length: 1
            name: channel
            type: uint8
          - offset: 1
            length: 1
            name: heat_percent
            type: uint8
"#,
        );
        assert!(actions_for(&spec).is_empty());
    }

    /// Without an explicit `command_characteristic` nothing resolves: writing
    /// to a characteristic the author never nominated is not ours to infer.
    #[test]
    fn direct_write_requires_an_explicit_command_characteristic() {
        let spec = spec_with(
            r#"
  - name: Heat Level
    platform: number
    state_characteristic: "90759319-1668-44da-9ef3-492d593bd1e5"
"#,
            r#"
  - uuid: "0313fb4e-198b-4f64-a883-52b218c10ccc"
    name: Heat Service
    characteristics:
      - uuid: "90759319-1668-44da-9ef3-492d593bd1e5"
        name: Heat Channel 1
        properties: [read, write]
        format:
          - offset: 0
            length: 1
            name: heat_percent
            type: uint8
"#,
        );
        assert!(actions_for(&spec).is_empty());
    }

    /// A command whose template has exactly one un-defaulted parameter is
    /// unambiguous: that parameter takes the setpoint.
    #[test]
    fn command_with_one_undefaulted_param_resolves_as_setpoint() {
        let spec = spec_with(
            r#"
  - name: Target Temperature
    platform: number
    unit: C
    state_characteristic: "0000fff2-0000-1000-8000-00805f9b34fb"
    commands:
      set_value: set_target
"#,
            r#"
  - uuid: "0000fff0-0000-1000-8000-00805f9b34fb"
    name: Control
    characteristics:
      - uuid: "0000fff1-0000-1000-8000-00805f9b34fb"
        name: Write
        properties: [write]
        commands:
          set_target:
            description: Set target temperature
            template: [170, "{seq}", "{target}", 85]
            parameters:
              seq: {type: uint8, default: 0}
              target:
                type: uint8
                min: 0
                max: 60
                scale: 0.5
                value_offset: 10
      - uuid: "0000fff2-0000-1000-8000-00805f9b34fb"
        name: Status
        properties: [read, notify]
        format:
          - offset: 0
            length: 1
            name: target_raw
            type: uint8
"#,
        );
        let actions = actions_for(&spec);
        assert_eq!(roles(&actions), vec!["set_value"]);
        let action = &actions[0];
        assert_eq!(action.command_name, Some("set_target"));
        assert_eq!(action.user_params, vec!["target"]);

        // The parameter's own semantics win over the state field's.
        let transform = setpoint_transform(&spec, &spec.entities[0], action);
        assert_eq!(transform.scale, 0.5);
        assert_eq!(transform.value_offset, 10.0);
        // 25 °C -> raw 30, and back again.
        assert_eq!(transform.encode(25.0), Some(30.0));
        assert_eq!(transform.decode(30.0), 25.0);
    }

    /// Ember's shape: the target is split across two un-defaulted byte
    /// parameters and only prose says which is which, so it must not resolve.
    #[test]
    fn command_needing_two_undefaulted_params_does_not_resolve() {
        let spec = spec_with(
            r#"
  - name: Target Temperature
    platform: number
    unit: C
    min: 49
    max: 63
    state_characteristic: "fc540003-236c-4c94-8fa9-944a3e5353fa"
    state_mapping:
      value: target_temp_raw
      scale: 0.01
    commands:
      set_value: set_target_temp
"#,
            r#"
  - uuid: "fc543622-236c-4c94-8fa9-944a3e5353fa"
    name: Ember
    characteristics:
      - uuid: "fc540003-236c-4c94-8fa9-944a3e5353fa"
        name: Target Temperature
        properties: [read, write]
        commands:
          set_target_temp:
            description: Set target temperature
            template: ["{temp_low}", "{temp_high}"]
            parameters:
              temp_low: {type: uint8, min: 0, max: 255}
              temp_high: {type: uint8, min: 0, max: 255}
        format:
          - offset: 0
            length: 2
            name: target_temp_raw
            type: uint16
            scale: 0.01
"#,
        );
        assert!(
            actions_for(&spec).is_empty(),
            "a two-byte split stated only in prose must not be guessed at"
        );
    }

    /// With no parameter-level semantics, the entity's own `state_mapping`
    /// scale describes the value — it is the entity layer's statement about
    /// what its number means.
    #[test]
    fn entity_scale_supplies_the_transform_when_the_parameter_is_bare() {
        let spec = spec_with(
            r#"
  - name: Target Temperature
    platform: number
    unit: C
    state_characteristic: "0000fff2-0000-1000-8000-00805f9b34fb"
    state_mapping:
      value: target_raw
      scale: 0.01
    commands:
      set_value: set_target
"#,
            r#"
  - uuid: "0000fff0-0000-1000-8000-00805f9b34fb"
    name: Control
    characteristics:
      - uuid: "0000fff1-0000-1000-8000-00805f9b34fb"
        name: Write
        properties: [write]
        commands:
          set_target:
            description: Set target
            template: ["{target}"]
            parameters:
              target: {type: uint16, min: 0, max: 10000}
      - uuid: "0000fff2-0000-1000-8000-00805f9b34fb"
        name: Status
        properties: [read]
        format:
          - offset: 0
            length: 2
            name: target_raw
            type: uint16
            scale: 0.01
"#,
        );
        let actions = actions_for(&spec);
        let transform = setpoint_transform(&spec, &spec.entities[0], &actions[0]);
        assert_eq!(transform.scale, 0.01);
        assert_eq!(transform.encode(55.0), Some(5500.0));
    }

    /// A `scale: 0` cannot be inverted, so encoding refuses rather than
    /// substituting 1.0 and writing a number nobody chose.
    #[test]
    fn zero_scale_is_not_invertible() {
        let transform = ValueTransform {
            scale: 0.0,
            value_offset: 5.0,
        };
        assert_eq!(transform.encode(10.0), None);
    }

    /// A characteristic-level transform disqualifies every command on it,
    /// even one whose own bytes are perfectly encodable. The obstacle lives a
    /// level above the command, which is exactly the case the command-level
    /// encoding gate cannot see.
    #[test]
    fn characteristic_transforms_disqualify_otherwise_sendable_commands() {
        for transform in [
            "encryption:\n          algorithm: aes-128-ecb",
            "framing:\n          length_prefix: true",
        ] {
            let spec = spec_with(
                r#"
  - name: Mask Display
    platform: light
    commands:
      set_brightness: set_brightness
"#,
                &format!(
                    r#"
  - uuid: "0000fff0-0000-1000-8000-00805f9b34fb"
    name: Control
    characteristics:
      - uuid: "0000fff1-0000-1000-8000-00805f9b34fb"
        name: Command
        properties: [write]
        {transform}
        commands:
          set_brightness:
            description: Brightness
            template: [6, "{{brightness}}"]
            parameters:
              brightness: {{type: uint8, min: 0, max: 255}}
"#
                ),
            );
            assert!(
                actions_for(&spec).is_empty(),
                "a command on a {transform:?} characteristic must not resolve"
            );
        }
    }

    /// The same gate applies to a direct write: the value would land as the
    /// wrong bytes just as surely as a command would.
    #[test]
    fn characteristic_transforms_disqualify_direct_writes() {
        let spec = spec_with(
            r#"
  - name: Heat Level
    platform: number
    command_characteristic: "0000fff1-0000-1000-8000-00805f9b34fb"
"#,
            r#"
  - uuid: "0000fff0-0000-1000-8000-00805f9b34fb"
    name: Control
    characteristics:
      - uuid: "0000fff1-0000-1000-8000-00805f9b34fb"
        name: Command
        properties: [read, write]
        encryption:
          algorithm: "aes-128-ecb"
        format:
          - offset: 0
            length: 1
            name: heat_percent
            type: uint8
"#,
        );
        assert!(actions_for(&spec).is_empty());
    }

    /// Sensors and unknown platforms resolve nothing — their rendering is
    /// unchanged by this module.
    #[test]
    fn non_control_platforms_resolve_nothing() {
        let spec = spec_with(
            r#"
  - name: Battery
    platform: sensor
    state_characteristic: "00002a19-0000-1000-8000-00805f9b34fb"
"#,
            r#"
  - uuid: "0000180f-0000-1000-8000-00805f9b34fb"
    name: Battery
    characteristics:
      - uuid: "00002a19-0000-1000-8000-00805f9b34fb"
        name: Battery Level
        properties: [read]
        commands:
          turn_on:
            description: Nonsense on a battery, but present to prove the
              platform gate.
            value: [1]
"#,
        );
        assert!(actions_for(&spec).is_empty());
    }

    // ── The network path's transport gates ───────────────────────────────

    /// A miniature network spec: one stateless button per command shape.
    fn network_spec(commands: &str) -> DeviceSpec {
        let yaml = format!(
            r#"
device:
  name: Test Remote
  manufacturer: Test
  manufacturer_status: active
  protocol: wifi
commands:
{commands}
entities:
  - name: Press Me
    platform: button
    commands:
      press: press_me
"#
        );
        parse_device_spec(&yaml).expect("test spec should parse")
    }

    /// A stateless `button` is on the network surface — the one platform the
    /// where-is-your-state rule excuses — and resolves its press over HTTP.
    #[test]
    fn a_button_resolves_a_press_with_no_state() {
        let spec = network_spec(
            r#"
  press_me:
    description: Fixed HTTP invocation.
    transport: http
    method: POST
    path: /keypress/Select
"#,
        );
        let entities = network_entities(&spec);
        assert_eq!(entities.len(), 1, "the button must be on the surface");
        let actions = resolve_network_actions(&spec, entities[0]);
        assert_eq!(actions.len(), 1);
        assert_eq!(actions[0].role, "press");
    }

    /// An HTTP command without its address is not sendable, so the control
    /// must not be offered — the same gate SOAP applies to a missing service.
    #[test]
    fn an_http_command_missing_its_method_resolves_nothing() {
        let spec = network_spec(
            r#"
  press_me:
    description: No method — half a request.
    transport: http
    path: /keypress/Select
"#,
        );
        let entities = network_entities(&spec);
        assert!(resolve_network_actions(&spec, entities[0]).is_empty());
    }

    /// A method the schema allows but no client of this transport sends is
    /// the same dead control as a missing one, and must be gated the same.
    #[test]
    fn an_http_command_using_an_unsendable_method_resolves_nothing() {
        for method in ["PUT", "DELETE", "PATCH"] {
            let spec = network_spec(&format!(
                r#"
  press_me:
    description: A method no client here implements.
    transport: http
    method: {method}
    path: /keypress/Select
"#
            ));
            let entities = network_entities(&spec);
            assert!(
                resolve_network_actions(&spec, entities[0]).is_empty(),
                "{method} must not resolve a control"
            );
        }
        // And the sendable ones still do, case-insensitively.
        for method in ["POST", "get"] {
            let spec = network_spec(&format!(
                r#"
  press_me:
    description: A method the client implements.
    transport: http
    method: {method}
    path: /keypress/Select
"#
            ));
            let entities = network_entities(&spec);
            assert_eq!(
                resolve_network_actions(&spec, entities[0]).len(),
                1,
                "{method} must resolve"
            );
        }
    }

    /// A stateless platform that is NOT button keeps the old rule: a switch
    /// with no state source stays off the network surface entirely.
    #[test]
    fn statelessness_excuses_only_buttons() {
        let spec = network_spec(
            r#"
  press_me:
    description: Fixed HTTP invocation.
    transport: http
    method: POST
    path: /keypress/Select
"#,
        );
        // Same spec, but the entity claims to be a switch.
        let yaml = ROKUISH_SWITCH;
        let switch_spec = parse_device_spec(yaml).expect("test spec should parse");
        assert!(network_entities(&switch_spec).is_empty());
        // Sanity: the button variant IS on the surface.
        assert_eq!(network_entities(&spec).len(), 1);
    }

    const ROKUISH_SWITCH: &str = r#"
device:
  name: Test Remote
  manufacturer: Test
  manufacturer_status: active
  protocol: wifi
commands:
  press_me:
    description: Fixed HTTP invocation.
    transport: http
    method: POST
    path: /keypress/Select
entities:
  - name: Press Me
    platform: switch
    commands:
      turn_on: press_me
"#;
}
