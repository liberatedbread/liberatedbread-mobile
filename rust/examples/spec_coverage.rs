// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
//! Report how much of the vendored spec catalogue the app can actually render.
//!
//! An entity produces a reading only when its `state_characteristic` resolves
//! to a characteristic that declares a `format:` block. Everything else is a
//! gap in the spec data, not in the app — and the difference is invisible from
//! the UI, where both look like a device with nothing to show.
//!
//! Run with `scripts/spec_coverage.sh`, or:
//!     cargo run --example spec_coverage -- ../assets/device_specs
//!
//! Uses the app's own parser, so the numbers are what the app will do rather
//! than what a separate YAML reader thinks.

use std::collections::BTreeMap;
use std::path::PathBuf;

use liberated_bread_core::spec::parser::parse_device_spec;
use liberated_bread_core::spec::types::DeviceSpec;

struct Row {
    file: String,
    entities: usize,
    decodable: usize,
    sensors_decodable: usize,
    unresolved: usize,
    no_format: usize,
}

impl Row {
    fn is_live(&self) -> bool {
        self.decodable > 0
    }
}

fn analyze(file: String, spec: &DeviceSpec) -> Row {
    let mut row = Row {
        file,
        entities: spec.entities.len(),
        decodable: 0,
        sensors_decodable: 0,
        unresolved: 0,
        no_format: 0,
    };

    for entity in &spec.entities {
        let Some(uuid) = entity.state_characteristic.as_deref() else {
            row.unresolved += 1;
            continue;
        };
        match spec.find_decodable_characteristic(uuid) {
            None => row.unresolved += 1,
            Some((_, characteristic)) if characteristic.format.is_none() => row.no_format += 1,
            Some(_) => {
                row.decodable += 1;
                if entity.platform.as_deref() == Some("sensor") {
                    row.sensors_decodable += 1;
                }
            }
        }
    }
    row
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let dir = PathBuf::from(
        std::env::args()
            .nth(1)
            .unwrap_or_else(|| "../assets/device_specs".to_string()),
    );

    // BTreeMap so the report is stable between runs — directory order is not.
    let mut specs = BTreeMap::new();
    let mut unparseable = Vec::new();

    for entry in std::fs::read_dir(&dir)? {
        let path = entry?.path();
        if path.extension().and_then(|e| e.to_str()) != Some("yaml") {
            continue;
        }
        let name = path
            .file_name()
            .and_then(|n| n.to_str())
            .unwrap_or_default()
            .to_string();
        match parse_device_spec(&std::fs::read_to_string(&path)?) {
            Ok(spec) => {
                specs.insert(name, spec);
            }
            Err(e) => unparseable.push((name, e.to_string())),
        }
    }

    let rows: Vec<Row> = specs
        .iter()
        .map(|(name, spec)| analyze(name.clone(), spec))
        .filter(|row| row.entities > 0)
        .collect();

    let live: Vec<&Row> = rows.iter().filter(|r| r.is_live()).collect();
    let blocked: Vec<&Row> = rows.iter().filter(|r| !r.is_live()).collect();

    println!("# Device spec coverage\n");
    println!(
        "{} specs parsed, {} declare entities, {} can render at least one reading today.\n",
        specs.len(),
        rows.len(),
        live.len()
    );

    println!("## Renderable today\n");
    println!("| spec | entities | decodable | sensor readings |");
    println!("|---|---:|---:|---:|");
    for row in &live {
        println!(
            "| {} | {} | {} | {} |",
            row.file, row.entities, row.decodable, row.sensors_decodable
        );
    }

    println!("\n## Blocked on spec data\n");
    println!("These declare entities, but no entity resolves to a characteristic with a");
    println!("`format:` block, so there is nothing to decode.\n");
    println!("| spec | entities | no format block | unresolved characteristic |");
    println!("|---|---:|---:|---:|");
    for row in &blocked {
        println!(
            "| {} | {} | {} | {} |",
            row.file, row.entities, row.no_format, row.unresolved
        );
    }

    if !unparseable.is_empty() {
        println!("\n## Failed to parse\n");
        for (name, err) in &unparseable {
            println!("- `{name}`: {err}");
        }
    }

    Ok(())
}
