// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0

pub mod device_api;
pub mod mock_api;
pub mod radio_api;
pub mod spec_handle;

/// Runs once, when Dart calls `RustLib.init()` — flutter_rust_bridge's
/// generated `executeRustInitializers` calls every `#[frb(init)]`.
///
/// Without this the core had no logger and only std's default panic hook,
/// both of which write to stderr — which iOS discards. A panic reached Dart
/// as a `PanicException` (FRB catches it) and left no trace in the device
/// console, so the only record of a Rust failure was whatever the Dart
/// caller chose to log. `setup_default_user_utils` routes the `log` macros to
/// os_log on Apple platforms and logcat on Android, and turns
/// `RUST_BACKTRACE` on; the hook below then puts the panic message itself
/// through that logger before handing on to FRB's own hook (which captures
/// the backtrace it attaches to the exception).
#[flutter_rust_bridge::frb(init)]
pub fn init_app() {
    flutter_rust_bridge::setup_default_user_utils();
    let previous = std::panic::take_hook();
    std::panic::set_hook(Box::new(move |info| {
        log::error!("Rust panic: {info}");
        previous(info);
    }));
}
