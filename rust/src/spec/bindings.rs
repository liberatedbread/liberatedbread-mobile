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

use super::types::{Characteristic, Command, DeviceSpec, Entity, Service, TemplateElement};
use crate::codec::types::unsupported_encoding_kind;

/// One resolved control action: the command to send for a role, and which
/// parameters the UI supplies when sending it.
#[derive(Debug)]
pub struct ResolvedAction<'a> {
    /// Canonical role name: `turn_on` | `turn_off` | `press` |
    /// `set_brightness` | `set_color`.
    pub role: &'static str,
    pub service: &'a Service,
    pub characteristic: &'a Characteristic,
    pub command_name: &'a str,
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
    // JSON/protobuf/TLV commands can't be encoded at all yet.
    if unsupported_encoding_kind(command).is_some() {
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
            command_name: name,
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
        let defaulted = command
            .parameters
            .as_ref()
            .and_then(|set| set.params.get(param_name.as_str()))
            .is_some_and(|p| p.default.is_some());
        if !defaulted {
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
        command_name: name,
        user_params,
        min,
        max,
    })
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
        assert_eq!(brightness.command_name, "set_brightness");
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
        assert_eq!(actions[0].command_name, "bot_turn_on");
        assert_eq!(actions[2].command_name, "bot_press");
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
}
