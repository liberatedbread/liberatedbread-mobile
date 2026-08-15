// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
//! Wemo adoption driven from the vendored catalogue.
//!
//! The unit tests in `protocol::wemo_setup` pin the encryption against constants
//! copied into that file. This closes the loop the other way: it reads the SAME
//! numbers out of the vendored spec YAML and asserts the crate reproduces them,
//! so a spec refresh that moves a test vector or the SSID prefix fails here
//! instead of drifting silently. The LIFX SoftAP path is main's; its coverage
//! lives in `lifx_control.rs`.

use std::collections::BTreeMap;

use liberated_bread_core::api::device_api::{
    render_wemo_connect_requests, wemo_network_status, WemoJoinStatus,
};
use liberated_bread_core::protocol::wemo_setup::{self, KeydataMethod};
use liberated_bread_core::spec::parser::parse_device_spec;
use liberated_bread_core::spec::setup::soft_ap_profiles;

fn vendored(device: &str) -> String {
    let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .unwrap()
        .join("vendor/protocol-specs/device-specs/devices")
        .join(device);
    std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("reading {path:?}: {e}"))
}

/// Walk to `device.setup.methods[0].softap.credential_encryption` in the Wemo
/// spec — the block the crate transcribes.
fn wemo_credential_encryption() -> serde_yaml::Value {
    let spec: serde_yaml::Value = serde_yaml::from_str(&vendored("wemo-devices.yaml")).unwrap();
    spec["device"]["setup"]["methods"][0]["softap"]["credential_encryption"].clone()
}

#[test]
fn the_wemo_spec_still_declares_the_softap_method_this_crate_speaks() {
    let spec = parse_device_spec(&vendored("wemo-devices.yaml")).expect("Wemo spec parses");
    let profiles = soft_ap_profiles([&spec]);
    let profile = profiles
        .iter()
        .find(|p| p.method_type == "softap_soap")
        .expect("Wemo declares a softap_soap method");
    assert!(
        profile.matches_ssid("Wemo.Mini.4A2") && profile.matches_ssid("WeMo.Switch.A1B"),
        "the vendored prefix no longer matches the SSIDs the spec's own examples use"
    );
    assert_eq!(profile.gateway_ip.as_deref(), Some("10.22.22.1"));
    assert_eq!(
        profile.ports.first().copied(),
        Some(49153),
        "the documented setup port drifted"
    );
}

#[test]
fn the_lifx_spec_still_declares_a_softap_udp_method() {
    // The LIFX SoftAP *implementation* is main's (protocol::lifx); this only
    // pins that the softap-profile extraction the hint relies on still finds
    // LIFX in the catalogue, so the unified adopt picker keeps offering it.
    let spec = parse_device_spec(&vendored("lifx-z.yaml")).expect("LIFX spec parses");
    let profiles = soft_ap_profiles([&spec]);
    let profile = profiles
        .iter()
        .find(|p| p.method_type == "softap_udp")
        .expect("LIFX declares a softap_udp method");
    assert!(profile.matches_ssid("LIFX Z 04A3C1"));
}

#[test]
fn the_crate_reproduces_every_wemo_test_vector_in_the_vendored_spec() {
    let enc = wemo_credential_encryption();
    let input = &enc["test_vectors"]["input"];
    let meta_info = input["meta_info"].as_str().expect("meta_info");
    let passphrase = input["passphrase"].as_str().expect("passphrase");
    let (mac, serial) = wemo_setup::parse_meta_info(meta_info).expect("meta_info parses");

    let vectors = enc["test_vectors"]["vectors"]
        .as_sequence()
        .expect("vectors is a sequence");
    assert_eq!(vectors.len(), 3, "the spec should publish three vectors");

    for vector in vectors {
        let method = match vector["method"].as_u64().expect("method number") {
            1 => KeydataMethod::Method1,
            2 => KeydataMethod::Method2,
            3 => KeydataMethod::Method3,
            other => panic!("unknown method {other}"),
        };
        let add_lengths = vector["add_lengths"].as_bool().expect("add_lengths");
        let expected = vector["password_argument"]
            .as_str()
            .expect("password_argument");

        let got = wemo_setup::encrypt_password(&mac, &serial, passphrase, method, add_lengths)
            .expect("encryption succeeds");
        assert_eq!(
            got,
            expected,
            "method {} (add_lengths={add_lengths}) diverged from the vendored spec vector",
            method.number()
        );
    }
}

#[test]
fn the_wemo_candidate_sweep_leads_with_the_spec_default_vector() {
    let enc = wemo_credential_encryption();
    let input = &enc["test_vectors"]["input"];
    let meta_info = input["meta_info"].as_str().unwrap();
    let passphrase = input["passphrase"].as_str().unwrap();

    let candidates = wemo_setup::password_candidates(meta_info, passphrase, None, None).unwrap();
    let first_vector = &enc["test_vectors"]["vectors"][0];
    assert_eq!(candidates[0].method, 1);
    assert!(candidates[0].add_lengths);
    assert_eq!(
        candidates[0].password,
        first_vector["password_argument"].as_str().unwrap()
    );
}

#[test]
fn the_wemo_ap_list_example_parses_into_the_arguments_connecthomenetwork_wants() {
    let spec: serde_yaml::Value = serde_yaml::from_str(&vendored("wemo-devices.yaml")).unwrap();
    let example = spec["device"]["setup"]["methods"][0]["payload_formats"]["ApList"]["example"]
        .as_str()
        .expect("the spec carries an ApList example");

    let networks = wemo_setup::parse_ap_list(example);
    let home = networks
        .iter()
        .find(|n| n.ssid == "HomeNet")
        .expect("HomeNet is in the example");
    assert_eq!(home.auth, "WPA2PSK");
    assert_eq!(home.encrypt.as_deref(), Some("AES"));
    assert_eq!(home.channel, "6");
    assert!(home.joinable && !home.is_open());

    // Those columns are exactly the ConnectHomeNetwork arguments. Render the
    // real command from the real spec with them plus an encrypted password.
    let device_spec = parse_device_spec(&vendored("wemo-devices.yaml")).unwrap();
    let mut values = BTreeMap::new();
    values.insert("ssid".to_string(), home.ssid.clone());
    values.insert("auth".to_string(), home.auth.clone());
    values.insert("encrypt".to_string(), home.encrypt.clone().unwrap());
    values.insert("channel".to_string(), home.channel.clone());
    values.insert("password".to_string(), "ENC".to_string());
    let request = liberated_bread_core::protocol::soap::render_request(
        &device_spec,
        "setup_connect_home_network",
        &values,
    )
    .expect("the setup command renders");
    assert_eq!(
        request.soap_action,
        "\"urn:Belkin:service:WiFiSetup:1#ConnectHomeNetwork\""
    );
    assert!(request.body.contains("<ssid>HomeNet</ssid>"));
    assert!(request.body.contains("<channel>6</channel>"));
    assert!(request.body.contains("<password>ENC</password>"));
}

#[test]
fn render_connect_requests_assembles_the_whole_credential_send_in_rust() {
    // The Dart caller hands network + passphrase and gets back ready-to-POST
    // ConnectHomeNetwork requests — encryption and XML both done here, the
    // Wemo counterpart of render_lifx_set_access_point.
    let spec = vendored("wemo-devices.yaml");
    let enc = wemo_credential_encryption();
    let input = &enc["test_vectors"]["input"];
    let meta_info = input["meta_info"].as_str().unwrap();
    let passphrase = input["passphrase"].as_str().unwrap();

    let requests = render_wemo_connect_requests(
        spec.clone(),
        meta_info.to_string(),
        "HomeNet".to_string(),
        "WPA2PSK".to_string(),
        "AES".to_string(),
        "6".to_string(),
        passphrase.to_string(),
    )
    .unwrap();
    // One rendered request per encryption variant of the sweep.
    assert_eq!(requests.len(), 6);
    for request in &requests {
        assert_eq!(request.action, "ConnectHomeNetwork");
        assert!(request.body.contains("<ssid>HomeNet</ssid>"));
        assert!(request.body.contains("<channel>6</channel>"));
        assert!(
            !request.body.contains(passphrase),
            "the passphrase must ride encrypted, never in the clear"
        );
    }
    // The first request carries the spec's first published vector, encrypted.
    let first_vector = enc["test_vectors"]["vectors"][0]["password_argument"]
        .as_str()
        .unwrap();
    assert!(requests[0].body.contains(first_vector));

    // An open network is one request: OPEN / NONE / empty password, no metadata.
    let open = render_wemo_connect_requests(
        spec,
        String::new(),
        "Guest".to_string(),
        "OPEN".to_string(),
        "NONE".to_string(),
        "1".to_string(),
        String::new(),
    )
    .unwrap();
    assert_eq!(open.len(), 1);
    assert!(open[0].body.contains("<auth>OPEN</auth>"));
    assert!(open[0].body.contains("<encrypt>NONE</encrypt>"));
    assert!(open[0].body.contains("<password></password>"));
}

#[test]
fn network_status_codes_map_to_the_spec_vocabulary() {
    assert_eq!(wemo_network_status("0".into()), WemoJoinStatus::Connecting);
    assert_eq!(wemo_network_status("1".into()), WemoJoinStatus::Connected);
    assert_eq!(wemo_network_status("2".into()), WemoJoinStatus::Rejected);
    assert_eq!(wemo_network_status("3".into()), WemoJoinStatus::Handshaking);
    assert_eq!(wemo_network_status(" 1 ".into()), WemoJoinStatus::Connected);
    assert_eq!(wemo_network_status("9".into()), WemoJoinStatus::Unknown);
}
