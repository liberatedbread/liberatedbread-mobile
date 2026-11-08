// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
//! Read a Big Ass Fans SenseME discovery reply: the `field:N` identity dialect
//! of `big-ass-fans-senseme.yaml`.
//!
//! The reply is one ASCII datagram, `(name;DEVICE;ID;mac;model)`. It looks like
//! something to `split(';')` and is not quite: the name is user-assigned free
//! text in which `;` arrives as `\;`, and a device with a semicolon in its name
//! would otherwise push the MAC — what the device is remembered by — one column
//! along. So this implements the spec's `payload_formats.DiscoveryReply.
//! parse_rules` in full and refuses the rest.
//!
//! Discovery only. The spec declares no `protocol_handler`, so no control path
//! exists for these devices.

/// The port the probe goes to, and the one its answer is expected on: "send the
/// probe from local UDP port 31415". Whether a reply is unicast or broadcast is
/// not established, and only a socket bound here hears both.
pub const PORT: u16 = 31415;

/// The identity dialect this module reads.
pub const FIELD_DIALECT: &str = "field";

/// The fewest and most characters a reply may run to, per the spec's parse
/// rules (aiosenseme's own filter).
const MIN_REPLY: usize = 31;
const MAX_REPLY: usize = 200;

/// The reply's five fields, unescaped, or `None` when this is not one.
///
/// `None` is also the answer to the app's own probe heard back on a socket
/// bound to the probe's port: `<ALL;DEVICE;ID;GET>` has no parentheses.
pub fn parse_discovery_reply(datagram: &[u8]) -> Option<Vec<String>> {
    let text = std::str::from_utf8(datagram).ok()?;
    if !(MIN_REPLY..=MAX_REPLY).contains(&text.chars().count()) {
        return None;
    }
    let body = text.strip_prefix('(')?.strip_suffix(')')?;
    let fields = split_unescaped(body);
    let [_, category, attribute, mac, _] = fields.as_slice() else {
        return None;
    };
    if category != "DEVICE" || attribute != "ID" || !is_colon_mac(mac) {
        return None;
    }
    Some(fields)
}

/// Split on every `;` no backslash escapes, removing the escapes as it goes.
fn split_unescaped(body: &str) -> Vec<String> {
    let mut fields = vec![String::new()];
    let mut chars = body.chars();
    while let Some(c) = chars.next() {
        match c {
            '\\' => {
                if let Some(escaped) = chars.next() {
                    fields.last_mut().expect("starts non-empty").push(escaped);
                }
            }
            ';' => fields.push(String::new()),
            other => fields.last_mut().expect("starts non-empty").push(other),
        }
    }
    fields
}

/// "Wi-Fi MAC, upper-case hex, colon-separated." Case is not enforced: a
/// lower-case MAC is still the same identity, and nothing else looks like one.
fn is_colon_mac(text: &str) -> bool {
    let octets: Vec<&str> = text.split(':').collect();
    octets.len() == 6
        && octets
            .iter()
            .all(|o| o.len() == 2 && o.bytes().all(|b| b.is_ascii_hexdigit()))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// `payload_formats.DiscoveryReply.example`, byte for byte.
    #[test]
    fn reads_the_specs_literal_reply() {
        let fields = parse_discovery_reply(
            b"(Living Room Fan;DEVICE;ID;20:F8:5E:AA:BB:CC;FAN,HAIKU,SENSEME)",
        )
        .expect("the spec's own example");
        assert_eq!(
            fields,
            vec![
                "Living Room Fan",
                "DEVICE",
                "ID",
                "20:F8:5E:AA:BB:CC",
                "FAN,HAIKU,SENSEME",
            ]
        );
    }

    /// The case the parse rules single out, and the reason this is not a plain
    /// split: the identity must stay in column 3.
    #[test]
    fn an_escaped_delimiter_in_the_name_does_not_move_the_mac() {
        let fields = parse_discovery_reply(
            br"(Den\; Back\\Porch \(Fan\);DEVICE;ID;20:F8:5E:AA:BB:CC;FAN,HAIKU,SENSEME)",
        )
        .expect("an escaped name");
        assert_eq!(fields[0], r"Den; Back\Porch (Fan)");
        assert_eq!(fields[3], "20:F8:5E:AA:BB:CC");
        assert_eq!(fields.len(), 5);
    }

    #[test]
    fn the_model_field_is_kept_whole() {
        let fields =
            parse_discovery_reply(b"(Wall;DEVICE;ID;20:F8:5E:AA:BB:CC;WALL_CONTROL,HAIKU)")
                .unwrap();
        assert_eq!(fields[4], "WALL_CONTROL,HAIKU");
    }

    #[test]
    fn the_apps_own_probe_heard_back_is_not_a_device() {
        assert!(parse_discovery_reply(b"<ALL;DEVICE;ID;GET>").is_none());
    }

    #[test]
    fn anything_off_the_declared_shape_is_dropped() {
        for reply in [
            // No brackets at either end.
            "Fan Name;DEVICE;ID;20:F8:5E:AA:BB:CC;FAN,HAIKU,SENSEME",
            "(Fan Name;DEVICE;ID;20:F8:5E:AA:BB:CC;FAN,HAIKU,SENSEME",
            // Another reply shape on the same port.
            "(Living Room Fan;FAN;PWR;20:F8:5E:AA:BB:CC;ON,AND,MORE)",
            "(Living Room Fan;DEVICE;NAME;20:F8:5E:AA:BB:CC;FAN,HAIKU)",
            // Four fields, then six.
            "(Living Room Fan Name;DEVICE;ID;20:F8:5E:AA:BB:CC)",
            "(Living Room Fan;DEVICE;ID;20:F8:5E:AA:BB:CC;FAN,HAIKU;extra)",
            // A MAC column holding something else.
            "(Living Room Fan;DEVICE;ID;not-a-mac-at-all;FAN,HAIKU,SENSEME)",
            // Too short for any reply carrying a MAC.
            "(a;DEVICE;ID;bb;c)",
        ] {
            assert!(parse_discovery_reply(reply.as_bytes()).is_none(), "{reply}");
        }
    }

    #[test]
    fn the_length_bounds_are_the_specs() {
        let name = "n".repeat(200);
        let long = format!("({name};DEVICE;ID;20:F8:5E:AA:BB:CC;FAN,HAIKU,SENSEME)");
        assert!(parse_discovery_reply(long.as_bytes()).is_none());
    }

    #[test]
    fn a_binary_datagram_is_not_a_reply() {
        assert!(parse_discovery_reply(&[0xFF, 0x00, 0xFF]).is_none());
        assert!(parse_discovery_reply(&[]).is_none());
    }
}
