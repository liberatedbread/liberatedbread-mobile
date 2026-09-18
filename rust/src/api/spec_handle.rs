// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
//! Parsed specs that stay on this side of the FFI boundary.
//!
//! Every entry point in [`super::device_api`] takes its spec as YAML, which
//! was the right shape while a spec crossed once per screen. It is the wrong
//! shape for the two paths that ask repeatedly:
//!
//! * a BLE notification decodes a handful of bytes, and re-sent the whole
//!   spec (up to 123 KB) to do it, once per subscribed widget per packet;
//! * matching a connected device against the catalogue shipped all 203 parsed
//!   specs across the boundary per call, and the catalogue itself came back
//!   as 203 full DTOs to be decoded on the UI isolate.
//!
//! So the spec stays here and Dart holds a handle to it. [`LoadedSpec`] is
//! one spec; [`CatalogueHandle`] is the whole catalogue, matched by index.
//! Both
//! are `#[frb(opaque)]`: what crosses is a pointer, and the Dart object owns
//! an `Arc` clone that its finalizer (or an explicit `dispose()`) releases.
//!
//! Neither type reimplements anything. Every method delegates to the same
//! `*_with_spec` helper its by-YAML twin in [`super::device_api`] calls, so
//! an answer cannot depend on which door the caller came through — the Dart
//! suite asserts exactly that against the vendored catalogue.

use std::collections::HashMap;
use std::sync::Arc;

use flutter_rust_bridge::frb;

use crate::spec::parser::parse_device_spec;
use crate::spec::types::DeviceSpec;

use super::device_api::{
    decode_with_protocol, encode_command_with_spec, encode_entity_value_with_spec,
    list_network_instances_with_spec, match_connected_device, read_network_entity_with_spec,
    read_network_instance_with_spec, render_network_http_state_request_with_spec,
    render_network_state_request_with_spec, DecodedValueDto, DeviceSpecDto, EntityWriteDto,
    HttpRequestDto, MatchConfidence, NetworkInstanceDto, NetworkReadingDto, NetworkRoleReadingDto,
    ScannedDeviceDto, SoapRequestDto, SpecIdentityDto,
};

/// One parsed spec, held by Rust for as long as Dart holds the handle.
#[derive(Debug)]
#[frb(opaque)]
pub struct LoadedSpec {
    spec: Arc<DeviceSpec>,
}

/// Parse a spec and keep it, returning the handle that addresses it.
///
/// The YAML crosses the boundary once, here. Every later call about this
/// spec sends a pointer.
pub fn load_spec(yaml: String) -> anyhow::Result<LoadedSpec> {
    Ok(LoadedSpec {
        spec: Arc::new(parse_device_spec(&yaml)?),
    })
}

impl LoadedSpec {
    /// The full DTO for this spec — services, entities, commands and all.
    ///
    /// Fetched for the specs a screen actually renders, not for the whole
    /// catalogue: decoding 203 of these was the UI-isolate stall this module
    /// exists to remove.
    pub fn dto(&self) -> DeviceSpecDto {
        DeviceSpecDto::from(self.spec.as_ref())
    }

    /// Decode raw bytes from a BLE read or notification into named values.
    ///
    /// The hot one: a notify-driven sensor tile lands here several times a
    /// second, and this is the call that used to carry the spec with it.
    pub fn decode_value(
        &self,
        service_uuid: Option<String>,
        char_uuid: String,
        bytes: Vec<u8>,
    ) -> anyhow::Result<Vec<DecodedValueDto>> {
        let proto =
            crate::protocol::generic::GenericProtocol::scoped(self.spec.clone(), service_uuid);
        decode_with_protocol(&proto, &char_uuid, &bytes)
    }

    /// Encode a named command into the bytes for a BLE write.
    pub fn encode_command(
        &self,
        service_uuid: Option<String>,
        char_uuid: String,
        command_name: String,
        params: HashMap<String, f64>,
    ) -> anyhow::Result<Vec<u8>> {
        encode_command_with_spec(
            self.spec.clone(),
            service_uuid,
            char_uuid,
            command_name,
            params,
        )
    }

    /// Encode a setpoint the user picked, in decoded units, into the write
    /// that applies it.
    pub fn encode_entity_value(
        &self,
        entity_name: String,
        value: f64,
    ) -> anyhow::Result<EntityWriteDto> {
        encode_entity_value_with_spec(&self.spec, entity_name, value)
    }

    /// Render the HTTP request that reads a state command's values — the
    /// other repeated caller, on a 4-second poll per network device.
    pub fn render_network_http_state_request(
        &self,
        state_command: String,
        values: HashMap<String, String>,
    ) -> anyhow::Result<HttpRequestDto> {
        render_network_http_state_request_with_spec(&self.spec, state_command, values)
    }

    /// Render the argument-less SOAP request that reads a state command's
    /// values.
    pub fn render_network_state_request(
        &self,
        state_command: String,
    ) -> anyhow::Result<SoapRequestDto> {
        render_network_state_request_with_spec(&self.spec, state_command)
    }

    /// Decode one entity's state from the name→value pairs a state call
    /// returned.
    pub fn read_network_entity(
        &self,
        entity_name: String,
        returned: HashMap<String, String>,
    ) -> anyhow::Result<Option<NetworkReadingDto>> {
        read_network_entity_with_spec(&self.spec, entity_name, returned)
    }

    /// Enumerate the children an instanced entity's state reply carries.
    pub fn list_network_instances(
        &self,
        entity_name: String,
        state_reply: String,
    ) -> anyhow::Result<Vec<NetworkInstanceDto>> {
        list_network_instances_with_spec(&self.spec, entity_name, state_reply)
    }

    /// Read one child's roles out of an instanced entity's state reply.
    pub fn read_network_instance(
        &self,
        entity_name: String,
        state_reply: String,
        instance_id: String,
    ) -> anyhow::Result<Vec<NetworkRoleReadingDto>> {
        read_network_instance_with_spec(&self.spec, entity_name, state_reply, instance_id)
    }
}

/// The spec catalogue, parsed once and held here.
///
/// Built incrementally by [`CatalogueHandle::add_specs`] rather than in one
/// call: Dart hands it a chunk of the catalogue per event-loop turn, so
/// neither the YAML it encodes nor the entries it decodes land as one long
/// synchronous burst on the UI isolate.
#[frb(opaque)]
pub struct CatalogueHandle {
    entries: Vec<CatalogueSpec>,
}

/// One catalogue member: the key Dart filed it under, and the parsed spec.
///
/// The YAML is deliberately NOT kept. Dart already holds every spec's text
/// (the by-YAML entry points still take it), and a second copy here would
/// double a 4.4 MB resident cost to buy nothing.
#[frb(ignore)]
struct CatalogueSpec {
    key: String,
    spec: Arc<DeviceSpec>,
    identity: SpecIdentityDto,
    protocol_handler: Option<String>,
    gatt_service_uuids: Vec<String>,
}

/// An empty catalogue, ready for [`CatalogueHandle::add_specs`].
pub fn new_catalogue() -> CatalogueHandle {
    CatalogueHandle {
        entries: Vec::new(),
    }
}

/// Parse a chunk of the catalogue across every core the device has, keeping
/// the caller's order.
///
/// Dart hands the catalogue over a chunk per event-loop turn so the UI
/// isolate never blocks, which means the chunks arrive one at a time and a
/// serial parse inside each one would make the catalogue READY later than the
/// old 200-way `Future.wait` did — trading a stall for a wait. Splitting each
/// chunk across the cores gets both: nothing blocks the isolate, and the
/// parse still uses the whole machine.
///
/// A panicking worker takes the chunk down rather than one spec, which is the
/// right trade: `parse_device_spec` returns its failures as errors, so a panic
/// there is a bug in this crate and not a spec's fault.
#[frb(ignore)]
fn parse_chunk(
    keys: Vec<String>,
    yamls: Vec<String>,
) -> Vec<(String, Result<DeviceSpec, crate::error::SpecError>)> {
    let items: Vec<(String, String)> = keys.into_iter().zip(yamls).collect();
    let workers = std::thread::available_parallelism()
        .map(|n| n.get())
        .unwrap_or(1)
        .min(items.len());
    if workers <= 1 {
        return items
            .into_iter()
            .map(|(key, yaml)| {
                let parsed = parse_device_spec(&yaml);
                (key, parsed)
            })
            .collect();
    }
    let per_worker = items.len().div_ceil(workers);
    std::thread::scope(|scope| {
        let workers: Vec<_> = items
            .chunks(per_worker)
            .map(|slice| {
                scope.spawn(move || {
                    slice
                        .iter()
                        .map(|(key, yaml)| (key.clone(), parse_device_spec(yaml)))
                        .collect::<Vec<_>>()
                })
            })
            .collect();
        workers
            .into_iter()
            .flat_map(|worker| worker.join().expect("spec parse worker panicked"))
            .collect()
    })
}

/// A spec the catalogue could not parse, named so the load can report it
/// rather than silently shrinking.
#[derive(Debug, Clone)]
pub struct SpecLoadFailureDto {
    /// The key the caller filed the spec under (an asset path, or
    /// `pack:<name>/<file>`).
    pub key: String,
    /// What the parser said.
    pub message: String,
}

/// One catalogue entry as Dart sees it: everything the scan, adopt, group and
/// network paths ask of a spec they are not rendering, and nothing else.
///
/// This is the projection that replaced 203 full [`DeviceSpecDto`]s on the
/// startup path. A screen that actually renders a spec asks for its handle
/// (and its DTO) by index.
#[derive(Debug, Clone)]
pub struct CatalogueEntryDto {
    /// Position in the catalogue — the index every other call here takes.
    pub index: u32,
    /// The key the caller filed this spec under.
    pub key: String,
    /// The identifying projection the scan matchers already take by value.
    pub identity: SpecIdentityDto,
    /// `device.protocol_handler`, which the adopt and Rabbit Air paths select
    /// specs by.
    pub protocol_handler: Option<String>,
    /// UUIDs of the GATT services the spec declares, as declared. The
    /// post-connect ranking drops a name-only match that none of these
    /// corroborates, and it must be able to ask that without the whole spec.
    pub gatt_service_uuids: Vec<String>,
}

/// One catalogue entry's match against a connected device.
///
/// Indices, not specs: this is what [`CatalogueHandle::match_device`] returns
/// instead of the 203 `DeviceSpecDto`s that went in and the matched ones that
/// came back.
#[derive(Debug, Clone)]
pub struct CatalogueMatchDto {
    /// Index into the catalogue.
    pub index: u32,
    pub matched_by_name_prefix: bool,
    pub confidence: MatchConfidence,
    pub matched_service_uuids: Vec<String>,
}

impl CatalogueHandle {
    /// Parse and append a chunk of the catalogue, in the order given.
    ///
    /// Returns the specs in this chunk that did not parse; the rest are
    /// appended. A spec that fails is skipped rather than failing the whole
    /// catalogue, which is what the Dart loader did before and why one bad
    /// vendored spec cannot take matching out.
    ///
    /// `keys` and `yamls` are parallel lists. A length mismatch is a caller
    /// bug, so it is an error rather than a silent truncation.
    pub fn add_specs(
        &mut self,
        keys: Vec<String>,
        yamls: Vec<String>,
    ) -> anyhow::Result<Vec<SpecLoadFailureDto>> {
        if keys.len() != yamls.len() {
            anyhow::bail!(
                "add_specs got {} key(s) for {} spec(s)",
                keys.len(),
                yamls.len()
            );
        }
        let mut failures = Vec::new();
        for (key, parsed) in parse_chunk(keys, yamls) {
            match parsed {
                Ok(spec) => {
                    // The identity projection and the GATT service list are
                    // built here, once, off the UI isolate. They come from
                    // the same `DeviceSpecDto` the by-value path would have
                    // produced, so the catalogue's answers are that path's
                    // answers; the DTO is then dropped rather than crossing.
                    let dto = DeviceSpecDto::from(&spec);
                    self.entries.push(CatalogueSpec {
                        key,
                        identity: SpecIdentityDto::from(&dto),
                        protocol_handler: dto.protocol_handler.clone(),
                        gatt_service_uuids: dto
                            .services
                            .iter()
                            .map(|service| service.uuid.clone())
                            .collect(),
                        spec: Arc::new(spec),
                    });
                }
                Err(e) => failures.push(SpecLoadFailureDto {
                    key,
                    message: e.to_string(),
                }),
            }
        }
        Ok(failures)
    }

    /// Every entry's light projection, in catalogue order.
    pub fn entries(&self) -> Vec<CatalogueEntryDto> {
        self.entries
            .iter()
            .enumerate()
            .map(|(index, entry)| CatalogueEntryDto {
                index: index as u32,
                key: entry.key.clone(),
                identity: entry.identity.clone(),
                protocol_handler: entry.protocol_handler.clone(),
                gatt_service_uuids: entry.gatt_service_uuids.clone(),
            })
            .collect()
    }

    /// Match every spec in the catalogue against a device we are already
    /// connected to, by advertised name and discovered GATT services.
    ///
    /// Two strings in, matched indices out. The by-value twin
    /// (`match_device_to_spec`) shares the axes rule through
    /// [`match_connected_device`], so the two agree by construction.
    pub fn match_device(
        &self,
        device_name: String,
        service_uuids: Vec<String>,
    ) -> Vec<CatalogueMatchDto> {
        let device = ScannedDeviceDto {
            name: device_name,
            service_uuids,
            // Neither is observable here: this runs against a connected
            // device, where the advertisement is long gone.
            company_ids: Vec::new(),
            mac_address: None,
        };
        self.entries
            .iter()
            .enumerate()
            .filter_map(|(index, entry)| {
                let hit = match_connected_device(&entry.identity, &device)?;
                Some(CatalogueMatchDto {
                    index: index as u32,
                    matched_by_name_prefix: hit.matched_by_name_prefix,
                    confidence: hit.confidence,
                    matched_service_uuids: hit.matched_service_uuids,
                })
            })
            .collect()
    }

    /// A handle to the spec at `index`, sharing the catalogue's parse.
    ///
    /// This is how a screen goes from "spec 41 matched" to driving the
    /// device: no re-parse, and no YAML crossing in either direction.
    pub fn spec_at(&self, index: u32) -> anyhow::Result<LoadedSpec> {
        Ok(LoadedSpec {
            spec: self.entry_at(index)?.spec.clone(),
        })
    }

    /// The full DTO of the spec at `index`.
    pub fn dto_at(&self, index: u32) -> anyhow::Result<DeviceSpecDto> {
        Ok(DeviceSpecDto::from(self.entry_at(index)?.spec.as_ref()))
    }

    fn entry_at(&self, index: u32) -> anyhow::Result<&CatalogueSpec> {
        self.entries.get(index as usize).ok_or_else(|| {
            anyhow::anyhow!(
                "spec index {index} is past the end of a {}-spec catalogue",
                self.entries.len()
            )
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::api::device_api::{decode_value, encode_command, match_device_to_spec};

    const BULB_YAML: &str = r#"
device:
  name: "Test Bulb"
  manufacturer: "Acme"
  manufacturer_status: "abandoned"
  protocol: "ble"
  identification:
    local_name_prefix: "ACME-"
    service_uuids: ["0000ffe0-0000-1000-8000-00805f9b34fb"]
services:
  - uuid: "0000ffe0-0000-1000-8000-00805f9b34fb"
    name: "Control"
    characteristics:
      - uuid: "0000ffe1-0000-1000-8000-00805f9b34fb"
        name: "State"
        properties: ["read", "notify", "write"]
        format:
          - offset: 0
            length: 1
            name: "level"
            type: "uint8"
        commands:
          set_level:
            description: "set the level"
            template: ["{level}"]
            parameters:
              level: { type: "uint8" }
"#;

    const OTHER_YAML: &str = r#"
device:
  name: "Other Thing"
  manufacturer: "Beta"
  manufacturer_status: "abandoned"
  protocol: "ble"
  identification:
    local_name_prefix: "BETA-"
"#;

    fn catalogue() -> CatalogueHandle {
        let mut catalogue = new_catalogue();
        let failures = catalogue
            .add_specs(
                vec!["bulb.yaml".into(), "other.yaml".into()],
                vec![BULB_YAML.into(), OTHER_YAML.into()],
            )
            .unwrap();
        assert!(failures.is_empty(), "{failures:?}");
        catalogue
    }

    #[test]
    fn load_spec_decodes_the_same_bytes_as_the_by_yaml_path() {
        let handle = load_spec(BULB_YAML.to_string()).unwrap();
        let through_handle = handle
            .decode_value(
                Some("0000ffe0-0000-1000-8000-00805f9b34fb".into()),
                "0000ffe1-0000-1000-8000-00805f9b34fb".into(),
                vec![42],
            )
            .unwrap();
        let through_yaml = decode_value(
            Some(BULB_YAML.to_string()),
            Some("0000ffe0-0000-1000-8000-00805f9b34fb".into()),
            "0000ffe1-0000-1000-8000-00805f9b34fb".into(),
            vec![42],
        )
        .unwrap();
        assert_eq!(through_handle.len(), 1);
        assert_eq!(through_handle[0].name, through_yaml[0].name);
        assert_eq!(through_handle[0].uint_value, through_yaml[0].uint_value);
        assert_eq!(through_handle[0].uint_value, Some(42));
    }

    #[test]
    fn load_spec_encodes_the_same_bytes_as_the_by_yaml_path() {
        let handle = load_spec(BULB_YAML.to_string()).unwrap();
        let params = HashMap::from([("level".to_string(), 7.0)]);
        let through_handle = handle
            .encode_command(
                Some("0000ffe0-0000-1000-8000-00805f9b34fb".into()),
                "0000ffe1-0000-1000-8000-00805f9b34fb".into(),
                "set_level".into(),
                params.clone(),
            )
            .unwrap();
        let through_yaml = encode_command(
            Some(BULB_YAML.to_string()),
            Some("0000ffe0-0000-1000-8000-00805f9b34fb".into()),
            "0000ffe1-0000-1000-8000-00805f9b34fb".into(),
            "set_level".into(),
            params,
        )
        .unwrap();
        assert_eq!(through_handle, through_yaml);
        assert_eq!(through_handle, vec![7]);
    }

    #[test]
    fn a_spec_that_does_not_parse_is_reported_not_silently_dropped() {
        let mut catalogue = new_catalogue();
        let failures = catalogue
            .add_specs(
                vec!["good.yaml".into(), "bad.yaml".into()],
                vec![BULB_YAML.into(), "this: is: not: a spec".into()],
            )
            .unwrap();
        assert_eq!(catalogue.entries().len(), 1);
        assert_eq!(failures.len(), 1);
        assert_eq!(failures[0].key, "bad.yaml");
        assert!(!failures[0].message.is_empty());
    }

    #[test]
    fn mismatched_key_and_spec_counts_are_an_error() {
        let mut catalogue = new_catalogue();
        assert!(catalogue
            .add_specs(vec!["a".into()], vec![BULB_YAML.into(), OTHER_YAML.into()])
            .is_err());
    }

    #[test]
    fn entries_carry_the_identity_projection_and_the_gatt_services() {
        let entries = catalogue().entries();
        assert_eq!(entries.len(), 2);
        assert_eq!(entries[0].index, 0);
        assert_eq!(entries[0].key, "bulb.yaml");
        assert_eq!(entries[0].identity.device_name, "Test Bulb");
        assert_eq!(entries[0].identity.manufacturer, "Acme");
        assert_eq!(entries[0].identity.local_name_prefixes, vec!["ACME-"]);
        assert_eq!(
            entries[0].gatt_service_uuids,
            vec!["0000ffe0-0000-1000-8000-00805f9b34fb"]
        );
        assert_eq!(entries[1].index, 1);
        assert!(entries[1].gatt_service_uuids.is_empty());
    }

    #[test]
    fn match_device_agrees_with_the_by_value_matcher() {
        let catalogue = catalogue();
        let name = "ACME-1234".to_string();
        let uuids = vec!["0000ffe0-0000-1000-8000-00805f9b34fb".to_string()];

        let by_index = catalogue.match_device(name.clone(), uuids.clone());
        let by_value = match_device_to_spec(
            vec![
                load_spec(BULB_YAML.to_string()).unwrap().dto(),
                load_spec(OTHER_YAML.to_string()).unwrap().dto(),
            ],
            name,
            uuids,
        );

        assert_eq!(by_index.len(), by_value.len());
        assert_eq!(by_index.len(), 1);
        assert_eq!(by_index[0].index, 0);
        assert_eq!(
            by_index[0].matched_by_name_prefix,
            by_value[0].matched_by_name_prefix
        );
        assert_eq!(by_index[0].confidence, by_value[0].confidence);
        assert_eq!(
            by_index[0].matched_service_uuids,
            by_value[0].matched_service_uuids
        );
    }

    #[test]
    fn match_device_returns_nothing_for_a_device_no_spec_claims() {
        assert!(catalogue()
            .match_device("Nothing In Particular".into(), vec![])
            .is_empty());
    }

    #[test]
    fn spec_at_hands_back_a_working_handle_and_refuses_a_bad_index() {
        let catalogue = catalogue();
        let handle = catalogue.spec_at(0).unwrap();
        assert_eq!(handle.dto().device_name, "Test Bulb");
        assert_eq!(catalogue.dto_at(1).unwrap().device_name, "Other Thing");
        let err = catalogue.spec_at(9).unwrap_err().to_string();
        assert!(err.contains("past the end"), "{err}");
        assert!(catalogue.dto_at(9).is_err());
    }

    #[test]
    fn a_handle_from_the_catalogue_shares_the_catalogue_parse() {
        let catalogue = catalogue();
        let first = catalogue.spec_at(0).unwrap();
        let second = catalogue.spec_at(0).unwrap();
        assert!(Arc::ptr_eq(&first.spec, &second.spec));
    }

    #[test]
    fn an_empty_catalogue_says_so() {
        let catalogue = new_catalogue();
        assert!(catalogue.entries().is_empty());
        assert!(catalogue.match_device("anything".into(), vec![]).is_empty());
    }
}
