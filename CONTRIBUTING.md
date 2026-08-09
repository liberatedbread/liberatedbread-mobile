# Contributing to Liberated Bread Mobile

Thank you for your interest in contributing! We welcome contributions from everyone.
By participating you agree to our [Code of Conduct](CODE_OF_CONDUCT.md).

## How to Contribute

1. **Fork** the repository
2. **Create a branch** for your feature or fix: `git checkout -b feature/my-feature`
3. **Write tests** for your changes
4. **Run tests** to make sure everything passes: `flutter test` and `cd rust && cargo test`
5. **Run the linter**: `flutter analyze --fatal-infos` (CI treats infos as fatal) and `cd rust && cargo clippy --all-targets --all-features -- -D warnings`
6. **Format your code**: `dart format .` and `cd rust && cargo fmt --all`
7. **Commit** your changes with a clear message
8. **Push** to your fork and **open a Pull Request**

## Development Setup

### Flutter

```bash
flutter pub get
flutter test
```

### Rust

Install the stable Rust toolchain (see [README — Prerequisites](README.md#prerequisites)), then:

```bash
cd rust
cargo test
cargo clippy --all-targets --all-features -- -D warnings
cargo fmt --all
```

Before opening a PR, run the local CI mirror (covers both Flutter and Rust):

```bash
./scripts/test.sh
```

## Testing BLE without hardware

Almost nobody has the cloud-dead device you are fixing support for, and CI has
no Bluetooth radio at all. There are four ways to stand a device up, at four
different depths — pick the shallowest one that still runs the code you changed.

| What you get | Where | Runs the real `RealBleService`? | Runs the platform plugin? |
| --- | --- | --- | --- |
| `FakeBleService` | `test/fakes/fake_ble_service.dart` | no | no |
| Mock mode | `--dart-define=LIBERATED_BREAD_MOCK=true` | no (it IS the other implementation) | no |
| Emulated peripherals | `test/fakes/emulated_ble.dart` | **yes** | flutter_blue_plus's Dart core, yes |
| Virtual BlueZ | `scripts/linux-virtual-ble.sh` | **yes** | **yes**, `flutter_blue_plus_linux` |

**`FakeBleService`** replaces the app's own `BleService` interface. Right for
widget and screen tests, where the question is what the UI does with a given
answer.

**Mock mode** is a shipped product feature — demo mode — not a test double. The
integration suites run in it because it needs no radio, but it means
`real_ble_service.dart` never executes.

**Emulated peripherals** plug in one layer lower, at flutter_blue_plus's
federated platform seam, so the shipping service and the real plugin both run
against a virtual radio. A peripheral is a GATT table plus knobs for the ways
hardware misbehaves — refused connections, GATT errors, discovery that answers
empty while services are still resolving, a device that demands pairing:

```dart
final ble = EmulatedBleAdapter.install();          // once, in setUpAll
final bulb = ble.add(EmulatedPeripheral.bulb(id: 'AA:BB:CC:DD:EE:01'));
bulb.pushNotification(EmulatedUuids.batteryLevel, [84]);
```

See `test/services/real_ble_service_emulated_test.dart` for the service-level
use and `test/app_real_ble_path_test.dart` for the whole app over that path.
Both run under a plain `flutter test`.

**Virtual BlueZ** is for the Linux desktop target, where the real BLE path goes
through `flutter_blue_plus_linux` to BlueZ over D-Bus. `scripts/
ble_virtual_peripheral.py` serves `org.bluez` on a private bus — no radio, no
kernel module, no root — so that backend runs for real:

```bash
./scripts/linux-virtual-ble.sh bluetoothctl devices
./scripts/linux-virtual-ble.sh xvfb-run -a flutter test \
    integration_test/linux_virtual_ble_test.dart -d linux --tags=bluez
```

It needs `dbus` and `python3-dbus-next` (both in `LINUX_DESKTOP_PACKAGES`, so
`./scripts/setup.sh` installs them). Suites that need it are tagged
`@Tags(['bluez'])`, which keeps them out of the device jobs and tells
`scripts/ci-linux-tests.sh` to run them wrapped.

## Testing local-network discovery without a network

Half the catalogue is Wi-Fi hardware, and `RealNetworkScanService` finds it the
way the hardware expects: a DNS-SD meta-query over mDNS and an SSDP M-SEARCH.
Neither has a plugin seam to substitute — they are `dart:io` sockets and
`package:multicast_dns` — so the only way to run that code is to put something
on the wire that answers.

`scripts/net_virtual_device.py` is that: an mDNS/DNS-SD and SSDP responder for a
scenario of emulated devices, stdlib only. Both sides join their multicast group
over the loopback path, so it needs no second machine, no router and no
privileges. The bundled scenario is one device answering on both transports (a
Hue bridge — the coalescing case) and one that is SSDP-only (a Wemo plug — the
reason both transports run).

```bash
# Watch a scan happen, with every answered query logged
python3 scripts/net_virtual_device.py --verbose &
./scripts/run-linux.sh          # or: flutter test --tags=netdisco

# What CI runs
./scripts/ci-netdisco-tests.sh
```

These suites are tagged `@Tags(['netdisco'])` and are **excluded from
`flutter test`**, with a CI job of their own. Two reasons, both in
`scripts/ci-netdisco-tests.sh`: they bind ports 5353 and 1900, which a machine
running `avahi-daemon` or `systemd-resolved` cannot spare, and a scan window is
seconds of waiting for real datagrams rather than frames of a fake clock.

## Code Style

- Follow the [Effective Dart](https://dart.dev/effective-dart) guidelines
- Use `dart format` to format code
- Keep lines under 80 characters where reasonable
- Write descriptive variable and function names
- Rust: run `cargo fmt` and keep `cargo clippy -- -D warnings` clean; follow standard Rust naming (snake_case items, CamelCase types)

## Reporting Issues

- Use the [issue templates](.github/ISSUE_TEMPLATE/) provided
- Include steps to reproduce bugs
- Include device/OS information for BLE-related issues

## License

By contributing, you agree that your contributions will be licensed under the
Apache License 2.0.
