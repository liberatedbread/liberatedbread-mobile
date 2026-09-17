// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
//! Resolve a spec's `initialization` blocks into the ordered handshake a
//! client runs once it is connected and before it touches anything else.
//!
//! The schema has described this since the beginning — "ordered handshake /
//! setup steps executed after connecting and before normal commands", allowed
//! at the top level and per-service — and six vendored specs declare one, but
//! nothing parsed it: `Service` had no field for it (so serde dropped the
//! per-service blocks outright) and the top-level one sat in
//! `DeviceSpec::extensions` where nothing looked. A SpotLED panel's three
//! writes to `ff21` and a SmartDawn's two subscriptions therefore never
//! happened, while every command on those devices was reported fully
//! encodable.
//!
//! What lives here is the DECISION: which steps exist, in what order, against
//! which service, and which of them a GATT client can actually carry out. What
//! deliberately does not live here is I/O — the executor is the caller's, and
//! is meant to be thin enough to have no opinions of its own.

use crate::spec::types::{DeviceSpec, InitializationStep, Service};

/// One resolved handshake step, addressed and ready to run.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HandshakeStep {
    /// The service the characteristic lives under, resolved from the spec's
    /// own service list; `None` when no service declares it and the step came
    /// from the top level, so the caller has nothing to address the write to
    /// and must skip rather than guess.
    pub service_uuid: Option<String>,
    /// The characteristic to act on, as the spec spells it.
    pub characteristic_uuid: String,
    /// Bytes to write, or `None` for a read/subscribe-only step.
    pub write: Option<Vec<u8>>,
    /// Read the characteristic after (or instead of) the write.
    pub read: bool,
    /// Open notifications on the characteristic.
    pub subscribe: bool,
    /// Milliseconds to wait once the step is done; 0 for no wait.
    pub delay_ms: u32,
}

/// A spec's whole handshake: what to run, and what it could not express.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Handshake {
    /// The executable steps, in the order they must run.
    pub steps: Vec<HandshakeStep>,
    /// Steps the spec states only in prose — a `characteristic` with a
    /// `description` and no write/read/subscribe. Schlage's session
    /// resumption is the case: the bytes are a fresh SPAKE2 exchange per
    /// session and no spec can hold them. Carried rather than dropped so a
    /// caller can say "this device's handshake is only half a handshake"
    /// instead of running the executable prefix and believing it finished.
    pub described: Vec<String>,
}

impl Handshake {
    /// Whether there is nothing at all to run or report.
    pub fn is_empty(&self) -> bool {
        self.steps.is_empty() && self.described.is_empty()
    }
}

/// The ordered handshake `spec` declares.
///
/// Order is the spec's, read in one pass: the top-level block first, because
/// it is the DEVICE's handshake (schlage resumes a session before any service
/// is touched), then each service's own block in the order the services are
/// declared. Within a block the steps keep their written order, which is the
/// only thing the schema says about them — "ordered".
///
/// A step's service is resolved by looking for the characteristic in the
/// spec's own service list, so a top-level step is addressable at all and a
/// per-service step whose characteristic is really declared elsewhere is
/// addressed where it actually lives. Only when no service declares it does a
/// per-service step fall back to its owning service, which is the spec
/// author's own claim about where it sits (kingsmith's vendor preamble is
/// declared under the FTMS service and nowhere else — an upstream problem
/// noted in SPECS_TO_FIX.md, not one to paper over here).
pub fn handshake(spec: &DeviceSpec) -> Handshake {
    let mut out = Handshake::default();
    for step in &spec.initialization {
        push(&mut out, spec, step, None);
    }
    for service in &spec.services {
        for step in &service.initialization {
            push(&mut out, spec, step, Some(service));
        }
    }
    out
}

fn push(
    out: &mut Handshake,
    spec: &DeviceSpec,
    step: &InitializationStep,
    owner: Option<&Service>,
) {
    if !step.is_executable() {
        out.described.push(
            step.description.clone().unwrap_or_else(|| {
                format!("a step on {} with nothing to send", step.characteristic)
            }),
        );
        return;
    }
    let service_uuid = spec
        .find_characteristic(&step.characteristic)
        .map(|(service, _)| service.uuid.clone())
        .or_else(|| owner.map(|service| service.uuid.clone()));
    out.steps.push(HandshakeStep {
        service_uuid,
        characteristic_uuid: step.characteristic.clone(),
        write: step.write.clone(),
        read: step.read,
        subscribe: step.subscribe,
        delay_ms: step.delay_ms.unwrap_or(0),
    });
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::spec::parser::parse_device_spec as parse_spec;

    /// The shape the catalogue actually holds: a per-service block of writes
    /// (spotled), which `Service` used to drop on the floor because it had no
    /// field for it and no extensions bag either.
    #[test]
    fn a_per_service_block_survives_deserialization_and_is_addressed() {
        let spec = parse_spec(
            r#"
device:
  name: "Panel"
  manufacturer: "SpotLED"
  manufacturer_status: active
  protocol: ble
services:
  - uuid: "0000ff20-0000-1000-8000-00805f9b34fb"
    name: "Control"
    initialization:
      - characteristic: "0000FF21-0000-1000-8000-00805f9b34fb"
        write: [0, 0, 0, 1]
        delay_ms: 30
      - characteristic: "0000ff21-0000-1000-8000-00805f9b34fb"
        write: [4, 20, 0, 0]
        read: true
    characteristics:
      - uuid: "0000ff21-0000-1000-8000-00805f9b34fb"
        name: "Command"
        properties: ["write", "notify"]
"#,
        )
        .unwrap();
        assert_eq!(spec.services[0].initialization.len(), 2);
        let handshake = handshake(&spec);
        assert_eq!(handshake.described, Vec::<String>::new());
        assert_eq!(
            handshake.steps,
            vec![
                HandshakeStep {
                    service_uuid: Some("0000ff20-0000-1000-8000-00805f9b34fb".into()),
                    characteristic_uuid: "0000FF21-0000-1000-8000-00805f9b34fb".into(),
                    write: Some(vec![0, 0, 0, 1]),
                    read: false,
                    subscribe: false,
                    delay_ms: 30,
                },
                HandshakeStep {
                    service_uuid: Some("0000ff20-0000-1000-8000-00805f9b34fb".into()),
                    characteristic_uuid: "0000ff21-0000-1000-8000-00805f9b34fb".into(),
                    write: Some(vec![4, 20, 0, 0]),
                    read: true,
                    subscribe: false,
                    delay_ms: 0,
                },
            ]
        );
    }

    /// The device's own block runs before any service's, and a top-level step
    /// is addressed from wherever the spec declares its characteristic.
    #[test]
    fn the_top_level_block_runs_first_and_resolves_its_service() {
        let spec = parse_spec(
            r#"
device:
  name: "Lock"
  manufacturer: "Schlage"
  manufacturer_status: active
  protocol: ble
initialization:
  - characteristic: "26002998-e001-4812-8c08-5cd2afda0830"
    read: true
services:
  - uuid: "883f45ec-14cb-46aa-9864-9a4e782b33d0"
    name: "DataTransfer"
    initialization:
      - characteristic: "ff530c78-cd50-4bb9-bbd4-0712f32b3796"
        subscribe: true
    characteristics:
      - uuid: "26002998-e001-4812-8c08-5cd2afda0830"
        name: "RxData"
        properties: ["write", "notify"]
      - uuid: "ff530c78-cd50-4bb9-bbd4-0712f32b3796"
        name: "TxData"
        properties: ["write", "notify"]
"#,
        )
        .unwrap();
        let steps = handshake(&spec).steps;
        assert_eq!(
            steps
                .iter()
                .map(|s| (s.characteristic_uuid.as_str(), s.read, s.subscribe))
                .collect::<Vec<_>>(),
            vec![
                ("26002998-e001-4812-8c08-5cd2afda0830", true, false),
                ("ff530c78-cd50-4bb9-bbd4-0712f32b3796", false, true),
            ]
        );
        assert!(steps
            .iter()
            .all(|s| s.service_uuid.as_deref() == Some("883f45ec-14cb-46aa-9864-9a4e782b33d0")));
    }

    /// A step with nothing to send is prose, and prose is reported rather
    /// than executed: schlage's SPAKE2 exchange cannot be written from YAML,
    /// and a caller that ran the executable prefix and stopped would believe
    /// it had completed a handshake it had not started.
    #[test]
    fn a_prose_step_is_reported_not_executed() {
        let spec = parse_spec(
            r#"
device:
  name: "Lock"
  manufacturer: "Schlage"
  manufacturer_status: active
  protocol: ble
initialization:
  - characteristic: "26002998-e001-4812-8c08-5cd2afda0830"
    read: true
  - characteristic: "ff530c78-cd50-4bb9-bbd4-0712f32b3796"
    description: "Send the secure connection request with a fresh clientRandom."
services:
  - uuid: "883f45ec-14cb-46aa-9864-9a4e782b33d0"
    name: "DataTransfer"
    characteristics:
      - uuid: "26002998-e001-4812-8c08-5cd2afda0830"
        name: "RxData"
        properties: ["write", "notify"]
      - uuid: "ff530c78-cd50-4bb9-bbd4-0712f32b3796"
        name: "TxData"
        properties: ["write", "notify"]
"#,
        )
        .unwrap();
        let handshake = handshake(&spec);
        assert_eq!(handshake.steps.len(), 1);
        assert_eq!(
            handshake.described,
            vec!["Send the secure connection request with a fresh clientRandom.".to_string()]
        );
    }

    /// A characteristic no service declares still gets the owning service of
    /// its block — the only claim the spec makes about where it sits.
    #[test]
    fn an_undeclared_characteristic_falls_back_to_its_own_service() {
        let spec = parse_spec(
            r#"
device:
  name: "Treadmill"
  manufacturer: "KingSmith"
  manufacturer_status: active
  protocol: ble
services:
  - uuid: "00001826-0000-1000-8000-00805f9b34fb"
    name: "FTMS"
    initialization:
      - characteristic: "d18d2c10-c44c-11e8-a355-529269fb1459"
        write: [1, 0, 13]
    characteristics:
      - uuid: "00002ad9-0000-1000-8000-00805f9b34fb"
        name: "Control Point"
        properties: ["write", "notify"]
"#,
        )
        .unwrap();
        let steps = handshake(&spec).steps;
        assert_eq!(
            steps[0].service_uuid.as_deref(),
            Some("00001826-0000-1000-8000-00805f9b34fb")
        );
    }

    /// A spec that declares no handshake asks for none — the overwhelming
    /// majority of the catalogue, and the case where a connect must not grow
    /// a single extra round trip.
    #[test]
    fn a_spec_with_no_initialization_has_no_handshake() {
        let spec = parse_spec(
            r#"
device:
  name: "Bulb"
  manufacturer: "Example"
  manufacturer_status: active
  protocol: ble
services:
  - uuid: "0000ffe0-0000-1000-8000-00805f9b34fb"
    name: "Control"
    characteristics:
      - uuid: "0000ffe1-0000-1000-8000-00805f9b34fb"
        name: "Command"
        properties: ["write", "notify"]
"#,
        )
        .unwrap();
        assert!(handshake(&spec).is_empty());
    }

    /// Unknown keys on a service no longer fail the parse — the doc comment
    /// claiming they sweep into `extensions` is now true.
    #[test]
    fn a_service_keeps_its_unknown_keys() {
        let spec = parse_spec(
            r#"
device:
  name: "Bulb"
  manufacturer: "Example"
  manufacturer_status: active
  protocol: ble
services:
  - uuid: "0000ffe0-0000-1000-8000-00805f9b34fb"
    name: "Control"
    verification: "captured 2026-01-01"
    characteristics: []
"#,
        )
        .unwrap();
        assert!(spec.services[0].extensions.contains_key("verification"));
    }
}
