// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
//! The small Service Discovery Protocol exchange needed to find Bluetooth
//! Classic Serial Port Profile's RFCOMM channel.

use crate::error::ProtocolError;

const SERVICE_SEARCH_ATTRIBUTE_REQUEST: u8 = 0x06;
const SERVICE_SEARCH_ATTRIBUTE_RESPONSE: u8 = 0x07;
const ERROR_RESPONSE: u8 = 0x01;

fn malformed(reason: impl Into<String>) -> ProtocolError {
    ProtocolError::MalformedReply(reason.into())
}

/// Search SPP (UUID 0x1101) for its ProtocolDescriptorList (attribute 0x0004).
pub fn spp_search_attribute_request(transaction_id: u16) -> Vec<u8> {
    vec![
        SERVICE_SEARCH_ATTRIBUTE_REQUEST,
        (transaction_id >> 8) as u8,
        transaction_id as u8,
        0x00,
        0x0d,
        0x35,
        0x03,
        0x19,
        0x11,
        0x01,
        0x00,
        0xff,
        0x35,
        0x03,
        0x09,
        0x00,
        0x04,
        0x00,
    ]
}

#[derive(Debug)]
struct Element {
    kind: u8,
    value: Vec<u8>,
    children: Vec<Element>,
}

impl Element {
    fn unsigned(&self) -> Option<u32> {
        match self.value.as_slice() {
            [a] => Some(u32::from(*a)),
            [a, b] => Some(u16::from_be_bytes([*a, *b]).into()),
            [a, b, c, d] => Some(u32::from_be_bytes([*a, *b, *c, *d])),
            _ => None,
        }
    }

    fn uuid(&self) -> Option<u32> {
        (self.kind == 3).then(|| self.unsigned()).flatten()
    }
}

fn element(bytes: &[u8], offset: usize) -> Result<(Element, usize), ProtocolError> {
    let header = *bytes
        .get(offset)
        .ok_or_else(|| malformed("short SDP element"))?;
    let kind = header >> 3;
    let descriptor = header & 7;
    if kind == 0 {
        return Ok((
            Element {
                kind,
                value: Vec::new(),
                children: Vec::new(),
            },
            offset + 1,
        ));
    }
    let mut offset = offset + 1;
    let mut size = 0usize;
    if descriptor <= 4 {
        size = 1 << descriptor;
    } else {
        let length_bytes = 1 << (descriptor - 5);
        let length = bytes
            .get(offset..offset + length_bytes)
            .ok_or_else(|| malformed("short SDP element length"))?;
        offset += length_bytes;
        for byte in length {
            size = (size << 8) | usize::from(*byte);
        }
    }
    let end = offset
        .checked_add(size)
        .filter(|end| *end <= bytes.len())
        .ok_or_else(|| malformed("truncated SDP element"))?;
    let value = bytes[offset..end].to_vec();
    let mut children = Vec::new();
    if kind == 6 || kind == 7 {
        let mut child = 0;
        while child < value.len() {
            let (element, next) = element(&value, child)?;
            children.push(element);
            child = next;
        }
    }
    Ok((
        Element {
            kind,
            value,
            children,
        },
        end,
    ))
}

fn rfcomm_channel(element: &Element) -> Option<u8> {
    let children = &element.children;
    if children.len() >= 2 && children[0].uuid() == Some(0x0003) {
        if let Some(channel @ 1..=30) = children[1].unsigned().and_then(|c| u8::try_from(c).ok()) {
            return Some(channel);
        }
    }
    children.iter().find_map(rfcomm_channel)
}

/// Extract the RFCOMM channel from a complete, uncontinued response. The PDU
/// carries an attribute-list byte count distinct from its attribute elements.
pub fn rfcomm_channel_from_sdp_response(bytes: &[u8]) -> Result<Option<u8>, ProtocolError> {
    if bytes.len() < 7 {
        return Err(malformed("short SDP response"));
    }
    match bytes[0] {
        ERROR_RESPONSE => return Err(malformed("the printer rejected the SDP request")),
        SERVICE_SEARCH_ATTRIBUTE_RESPONSE => {}
        _ => return Err(malformed("not an SDP service-search-attribute response")),
    }
    let parameter_length = usize::from(u16::from_be_bytes([bytes[3], bytes[4]]));
    if parameter_length < 3 || bytes.len() != parameter_length + 5 {
        return Err(malformed("SDP response parameter length does not match"));
    }
    let attribute_length = usize::from(u16::from_be_bytes([bytes[5], bytes[6]]));
    if attribute_length + 3 != parameter_length {
        return Err(malformed("SDP attribute-list length does not match"));
    }
    let attributes_end = 7 + attribute_length;
    if bytes[attributes_end] != 0 {
        return Err(malformed("a continued SDP response is not one SPP record"));
    }
    if attribute_length == 0 {
        return Ok(None);
    }
    let attributes = &bytes[7..attributes_end];
    let (root, next) = element(attributes, 0)?;
    if next != attributes.len() {
        return Err(malformed("trailing bytes in the SDP attribute list"));
    }
    Ok(rfcomm_channel(&root))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn response(channel: u8, continued: bool) -> Vec<u8> {
        vec![
            0x07,
            0x00,
            0x01,
            0x00,
            0x18,
            0x00,
            0x15,
            0x35,
            0x13,
            0x35,
            0x11,
            0x09,
            0x00,
            0x04,
            0x35,
            0x0c,
            0x35,
            0x03,
            0x19,
            0x01,
            0x00,
            0x35,
            0x05,
            0x19,
            0x00,
            0x03,
            0x08,
            channel,
            u8::from(continued),
        ]
    }

    #[test]
    fn spp_request_uses_search_attribute_and_asks_for_protocol_descriptors() {
        assert_eq!(
            spp_search_attribute_request(1),
            vec![
                0x06, 0x00, 0x01, 0x00, 0x0d, 0x35, 0x03, 0x19, 0x11, 0x01, 0x00, 0xff, 0x35, 0x03,
                0x09, 0x00, 0x04, 0x00,
            ]
        );
    }

    #[test]
    fn a_standards_shaped_response_yields_the_rfcomm_channel() {
        assert_eq!(
            rfcomm_channel_from_sdp_response(&response(7, false)).unwrap(),
            Some(7)
        );
        assert_eq!(
            rfcomm_channel_from_sdp_response(&response(0, false)).unwrap(),
            None
        );
    }

    #[test]
    fn incomplete_continued_and_error_responses_are_rejected() {
        assert!(rfcomm_channel_from_sdp_response(&response(5, true)).is_err());
        assert!(rfcomm_channel_from_sdp_response(&response(5, false)[..20]).is_err());
        assert!(rfcomm_channel_from_sdp_response(&[0x01, 0, 1, 0, 2, 0, 1]).is_err());
    }
}
