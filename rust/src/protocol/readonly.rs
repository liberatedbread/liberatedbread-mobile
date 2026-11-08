// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0

//! The handlers this app implements for reading only, and the gate that keeps
//! them that way.
//!
//! These specs describe commands that drive mains equipment, a grid-connected
//! inverter, or a garage door. A handler here reads its device through its
//! own module's fixed encoders, and that module is the ONLY way bytes reach
//! the device: the generic spec encoders refuse every command of such a spec
//! ([`refuse_generic_send`]) and the surface resolvers offer no actions for
//! one ([`is_read_only`]). That covers the reads too, because their bare
//! templates are not valid frames either (`acinfinity-uis-controller` says a
//! client without the handler must not write them).
//!
//! The spec's commands stay listed, each with a plain statement of whether
//! this app sends it and why not, by [`command_policy`].

use crate::error::ProtocolError;
use crate::spec::types::DeviceSpec;

use super::{acinfinity, modbus_sunspec, yummly};

/// One command this app's read-only handler actually sends. `characteristic`
/// narrows the name on a BLE spec, where a name can repeat across generations
/// (`enter_probe_dfu` is on both Yummly services).
struct SentRead {
    characteristic: Option<&'static str>,
    name: &'static str,
}

const fn top_level(name: &'static str) -> SentRead {
    SentRead {
        characteristic: None,
        name,
    }
}

const fn on(characteristic: &'static str, name: &'static str) -> SentRead {
    SentRead {
        characteristic: Some(characteristic),
        name,
    }
}

/// A handler whose spec declares more than this app will send.
pub struct ReadOnlyHandler {
    pub name: &'static str,
    sent: &'static [SentRead],
    /// Why a command outside [`Self::sent`] is refused.
    refusal: &'static str,
}

const YUMMLY_XW2: &str = yummly::REQUEST_CHARACTERISTIC;
const ACINFINITY: &str = acinfinity::COMMAND_CHARACTERISTIC;

const READ_ONLY_HANDLERS: &[ReadOnlyHandler] = &[
    ReadOnlyHandler {
        name: modbus_sunspec::HANDLER_NAME,
        sent: &[
            top_level("read_common_block"),
            top_level("read_inverter_block"),
            top_level("read_meter_1_common"),
            top_level("read_meter_1_power"),
        ],
        refusal: "Read-only in this app: control registers change what a \
                  grid-connected inverter produces and exports.",
    },
    ReadOnlyHandler {
        name: yummly::HANDLER_NAME,
        sent: &[
            on(YUMMLY_XW2, "auth_reply"),
            on(YUMMLY_XW2, "get_base_firmware"),
            on(YUMMLY_XW2, "get_base_battery"),
            on(YUMMLY_XW2, "get_probe_mac"),
            on(YUMMLY_XW2, "get_probe_name"),
            on(YUMMLY_XW2, "get_probe_battery"),
        ],
        refusal: "Not sent by this app: it reads the T1 and P1 temperature \
                  stream only. Nothing that enters firmware update is \
                  sendable, and the T3 and P3 commands have never been run.",
    },
    ReadOnlyHandler {
        name: acinfinity::HANDLER_NAME,
        sent: &[on(ACINFINITY, "get_model_data")],
        refusal: "Read-only in this app: ports switch mains equipment such as \
                  heaters and humidifiers.",
    },
];

/// The read-only handler a spec names, if it names one.
pub fn read_only_handler(spec: &DeviceSpec) -> Option<&'static ReadOnlyHandler> {
    let name = spec.protocol_handler.as_deref()?;
    READ_ONLY_HANDLERS.iter().find(|h| h.name == name)
}

/// Whether this spec's device is read through a read-only handler. Actions
/// resolve to nothing for such a spec, whatever its entities bind.
pub fn is_read_only(spec: &DeviceSpec) -> bool {
    read_only_handler(spec).is_some()
}

/// The generic encoders' gate. A spec under a read-only handler has nothing
/// the spec-driven path may send: its own module is the only encoder.
pub fn refuse_generic_send(spec: &DeviceSpec, command: &str) -> Result<(), ProtocolError> {
    match read_only_handler(spec) {
        Some(handler) => Err(ProtocolError::ReadOnlyCommandRefused {
            handler: handler.name.to_string(),
            command: command.to_string(),
        }),
        None => Ok(()),
    }
}

/// One command the spec declares and what this app does about it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ReadOnlyCommandDto {
    pub name: String,
    pub description: Option<String>,
    /// True only for a read this app really sends through its own encoder.
    pub sent: bool,
    /// Why not, when `sent` is false.
    pub refusal: Option<String>,
}

fn policy_row(
    handler: &ReadOnlyHandler,
    characteristic: Option<&str>,
    name: &str,
    description: Option<&str>,
) -> ReadOnlyCommandDto {
    let sent = handler.sent.iter().any(|read| {
        read.name == name
            && match (read.characteristic, characteristic) {
                (None, None) => true,
                (Some(a), Some(b)) => a.eq_ignore_ascii_case(b),
                _ => false,
            }
    });
    ReadOnlyCommandDto {
        name: name.to_string(),
        description: description.map(str::to_string),
        sent,
        refusal: (!sent).then(|| handler.refusal.to_string()),
    }
}

/// Every command the spec declares, top-level and per-characteristic, in spec
/// order. Empty for a spec under no read-only handler.
pub fn command_policy(spec: &DeviceSpec) -> Vec<ReadOnlyCommandDto> {
    let Some(handler) = read_only_handler(spec) else {
        return Vec::new();
    };
    let mut rows: Vec<ReadOnlyCommandDto> = spec
        .commands
        .iter()
        .map(|(name, command)| policy_row(handler, None, name, command.description.as_deref()))
        .collect();
    for service in &spec.services {
        for characteristic in &service.characteristics {
            for (name, command) in characteristic.commands.iter().flatten() {
                rows.push(policy_row(
                    handler,
                    Some(&characteristic.uuid),
                    name,
                    Some(command.description.as_str()),
                ));
            }
        }
    }
    rows
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::api::device_api::{
        encode_command, encode_command_writes, load_device_spec, network_entities_for_device,
    };
    use crate::spec::parser::parse_device_spec;
    use std::collections::{BTreeSet, HashMap};

    fn spec_text(file: &str) -> String {
        std::fs::read_to_string(format!(
            "{}/../vendor/protocol-specs/device-specs/devices/{file}",
            env!("CARGO_MANIFEST_DIR")
        ))
        .unwrap()
    }

    /// (file, handler, the names this app sends).
    const SPECS: &[(&str, &str, &[&str])] = &[
        (
            "solaredge-modbus-tcp.yaml",
            modbus_sunspec::HANDLER_NAME,
            &[
                "read_common_block",
                "read_inverter_block",
                "read_meter_1_common",
                "read_meter_1_power",
            ],
        ),
        (
            "yummly-smart-thermometer.yaml",
            yummly::HANDLER_NAME,
            &[
                "auth_reply",
                "get_base_firmware",
                "get_base_battery",
                "get_probe_mac",
                "get_probe_name",
                "get_probe_battery",
            ],
        ),
        (
            "acinfinity-uis-controller.yaml",
            acinfinity::HANDLER_NAME,
            &["get_model_data"],
        ),
    ];

    /// The commands that must never go out, named one by one so that renaming
    /// or widening the allow list cannot quietly let one through. A line here
    /// is a door, a heater, or an inverter's export limit.
    const NEVER_SENT: &[(&str, &[&str])] = &[
        (
            "solaredge-modbus-tcp.yaml",
            &[
                "set_active_power_limit",
                "set_export_site_limit",
                "enable_advanced_power_control",
                "set_reactive_power_rrcr",
                "commit_power_control",
                "restore_power_control_defaults",
            ],
        ),
        ("yummly-smart-thermometer.yaml", &["enter_probe_dfu"]),
        (
            "acinfinity-uis-controller.yaml",
            &[
                "set_port_mode",
                "set_port_on_level",
                "set_port_off_level",
                "set_auto_triggers",
                "set_vpd_triggers",
                "set_timer_to_on",
                "set_timer_to_off",
                "set_cycle",
                "set_schedule",
                "write_settings_bundle",
            ],
        ),
    ];

    /// The pin. Exactly the listed reads are sent; every other command the
    /// spec declares, today or after a refresh, is listed and refused.
    #[test]
    fn only_the_listed_reads_are_sent_and_everything_else_is_refused() {
        for (file, handler, sent) in SPECS {
            let spec = parse_device_spec(&spec_text(file)).unwrap();
            assert_eq!(spec.protocol_handler.as_deref(), Some(*handler));
            let rows = command_policy(&spec);
            assert!(!rows.is_empty(), "{file} lists its commands");

            let actual: BTreeSet<&str> = rows
                .iter()
                .filter(|row| row.sent)
                .map(|row| row.name.as_str())
                .collect();
            let expected: BTreeSet<&str> = sent.iter().copied().collect();
            assert_eq!(actual, expected, "{file}");

            for row in rows.iter().filter(|row| !row.sent) {
                assert!(
                    row.refusal.as_deref().is_some_and(|r| !r.is_empty()),
                    "{file}: {} is refused without saying why",
                    row.name
                );
            }
        }
    }

    #[test]
    fn the_dangerous_commands_exist_in_the_spec_and_are_refused() {
        for (file, never) in NEVER_SENT {
            let spec = parse_device_spec(&spec_text(file)).unwrap();
            let rows = command_policy(&spec);
            for name in *never {
                let matching: Vec<_> = rows.iter().filter(|r| r.name == *name).collect();
                assert!(!matching.is_empty(), "{file} no longer declares {name}");
                assert!(
                    matching.iter().all(|row| !row.sent),
                    "{file}: {name} must not be sendable"
                );
            }
        }
    }

    /// `enter_probe_dfu` repeats across Yummly generations, and the XW3 reads
    /// are named like XW2's. The allow list is per characteristic so a name on
    /// the wrong characteristic does not inherit a yes.
    #[test]
    fn an_allowed_name_on_another_characteristic_is_still_refused() {
        let spec = parse_device_spec(&spec_text("yummly-smart-thermometer.yaml")).unwrap();
        let handler = read_only_handler(&spec).unwrap();
        let elsewhere = "6f2f0100-a6b6-4571-8bfd-5fe8a70600f0";
        assert!(!policy_row(handler, Some(elsewhere), "get_probe_battery", None).sent);
        assert!(policy_row(handler, Some(YUMMLY_XW2), "get_probe_battery", None).sent);
        assert!(!policy_row(handler, None, "get_probe_battery", None).sent);
    }

    /// No control is drawn for any of these, on either transport's surface.
    #[test]
    fn neither_surface_resolves_an_action() {
        for (file, _, _) in SPECS {
            let yaml = spec_text(file);
            let ble = load_device_spec(yaml.clone()).unwrap();
            for entity in &ble.entities {
                assert!(
                    entity.actions.is_empty(),
                    "{file}: BLE entity {} resolved an action",
                    entity.name
                );
            }
            let network = network_entities_for_device(yaml, Vec::new()).unwrap();
            for entity in &network.entities {
                assert!(
                    entity.actions.is_empty(),
                    "{file}: network entity {} resolved an action",
                    entity.name
                );
            }
        }
    }

    /// The generic encoders refuse every command of these specs, reads and
    /// writes alike, however the caller reaches them: a raw call with real
    /// parameters comes back as the refusal rather than as bytes.
    #[test]
    fn the_generic_encoders_refuse_every_command() {
        for (file, _, _) in SPECS {
            let yaml = spec_text(file);
            let spec = parse_device_spec(&yaml).unwrap();
            let params: HashMap<String, f64> = [
                ("port", 1.0),
                ("work_type", 2.0),
                ("on_level", 10.0),
                ("off_level", 0.0),
                ("limit", 50.0),
            ]
            .into_iter()
            .map(|(k, v)| (k.to_string(), v))
            .collect();
            for service in &spec.services {
                for characteristic in &service.characteristics {
                    for (name, _) in characteristic.commands.iter().flatten() {
                        for result in [
                            encode_command(
                                Some(yaml.clone()),
                                Some(service.uuid.clone()),
                                characteristic.uuid.clone(),
                                name.clone(),
                                params.clone(),
                            ),
                            encode_command_writes(
                                Some(yaml.clone()),
                                Some(service.uuid.clone()),
                                characteristic.uuid.clone(),
                                name.clone(),
                                params.clone(),
                            )
                            .map(|writes| writes.concat()),
                        ] {
                            let error = result.expect_err(name).to_string();
                            assert!(error.contains("read-only"), "{file}: {name} gave: {error}");
                        }
                    }
                }
            }
        }
    }

    /// The network renderers look a command up through `top_level_command`,
    /// which refuses for these specs: an inverter's write cannot be rendered.
    #[test]
    fn top_level_commands_cannot_be_looked_up_for_rendering() {
        let spec = parse_device_spec(&spec_text("solaredge-modbus-tcp.yaml")).unwrap();
        for name in spec.commands.keys() {
            let error = crate::protocol::top_level_command(&spec, name)
                .err()
                .unwrap_or_else(|| panic!("{name} was handed to a renderer"));
            assert!(error.to_string().contains("read-only"), "{name}: {error}");
        }
    }

    #[test]
    fn a_spec_under_no_such_handler_is_untouched() {
        let spec = parse_device_spec(&spec_text("tplink-kasa-smart-plug.yaml")).unwrap();
        assert!(!is_read_only(&spec));
        assert!(command_policy(&spec).is_empty());
        assert!(refuse_generic_send(&spec, "anything").is_ok());
    }
}
