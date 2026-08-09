// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// Loads the BUNDLED Rust core on the device under test and calls through it.
//
// WHAT THIS COVERS THAT NOTHING ELSE DID
//
// scripts/verify_apk.sh, scripts/verify_ios_app.sh and
// scripts/verify_linux_bundle.sh all assert that the native artifact is
// present in the built package and exports the flutter_rust_bridge entry
// points. That is a STATIC check on a file. Nothing in CI ever dlopen'd the
// thing and called it on a real device — so every runtime way the bridge can
// fail was uncovered:
//
//   * iOS: a framework that is inside Runner.app but has the wrong install
//     name, or is missing from the "Embed Frameworks" phase, so dyld cannot
//     resolve it at launch. The symbol check passes; the app cannot load it.
//   * Android: an .so packaged for the wrong ABI set, or extractNativeLibs /
//     page-size alignment problems that only bite the loader.
//   * Linux: a bundle whose RUNPATH is right but whose .so was built against
//     a host library the runtime image doesn't have.
//   * Any platform: an ABI mismatch between the generated Dart bindings and
//     the compiled crate — the exact drift the `flutter` job's codegen check
//     guards at compile time, unverified at run time.
//
// lib/main.dart CATCHES a failed RustLib.init() and carries on against the
// Dart-side mock, deliberately (a broken bridge should not brick the app).
// That is also why none of the above would ever have turned CI red: the app
// launches, the widget tests pass, and the only trace is a WARN line in a log
// nobody reads. This suite is the counterpart to that leniency — here a
// bridge that will not load is a hard failure.
//
// It runs on every device job at near-zero marginal cost: it is imported into
// ci_all_test.dart, so the iOS simulator and Android emulator jobs pick it up
// inside the single build/install cycle they already pay for, and the
// linux-desktop job runs it as its own (cheap, headless) invocation.
//
// Deliberately LAST in the aggregate's group order. RustLib is process-wide
// and initializing it changes how the earlier suites behave — MockBleService
// switches from its Dart fallback table to the real codec — so initializing
// it first would silently change what those suites test.
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:liberated_bread_mobile/providers/device_spec_provider.dart'
    show fallbackSpecPath, specAssetPath;
import 'package:liberated_bread_mobile/services/mock_ble_service.dart';
import 'package:liberated_bread_mobile/src/rust/api/device_api.dart'
    show identifyStandardProfiles, loadDeviceSpec;
import 'package:liberated_bread_mobile/src/rust/frb_generated.dart'
    show RustLib;

/// The Battery Service, whose 16-bit UUID is expanded to the full base UUID by
/// every platform scanner. A standard profile the Rust side recognises without
/// any spec being loaded, so it isolates "the bridge answers" from "the spec
/// parser works".
const String _batteryService = '0000180f-0000-1000-8000-00805f9b34fb';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // testWidgets rather than test: on a device, `integration_test` only drives
  // the app through the widget tester's binding, and a bare test() does not
  // get the same lifecycle. Nothing is pumped here — the tester is the harness,
  // not the subject.
  testWidgets('the bundled Rust core loads and answers over FFI',
      (tester) async {
    // No try/catch on purpose. main() swallows this failure by design; the
    // whole point of this suite is that CI does not.
    //
    // No externalLibrary either, unlike test/helpers/host_rust_lib.dart: that
    // helper opens rust/target/**/libliberated_bread_core.* by path because a
    // host `flutter test` bundles nothing. Here the default loader is the
    // subject — resolving the library the way the shipped app will is exactly
    // what is being tested, so pointing it at a known-good file would test
    // nothing.
    if (!MockBleService.rustAvailable) {
      await RustLib.init();
    }
    expect(
      MockBleService.rustAvailable,
      isTrue,
      reason: 'RustLib.init() returned without throwing but the bridge still '
          'reports itself uninitialized.',
    );

    // A call with a non-empty result, so a bridge that loads but returns
    // nothing (a stubbed or mismatched symbol table) still fails.
    final profiles =
        await identifyStandardProfiles(serviceUuids: <String>[_batteryService]);
    expect(profiles, hasLength(1));
    expect(profiles.single.profileName, 'Battery Service');
    expect(profiles.single.characteristics, isNotEmpty);

    // A round trip that carries a real payload across the bridge in both
    // directions: a multi-kilobyte YAML string in, a nested struct out. The
    // call above passes one short string and gets a small list back, which a
    // partially-working bridge can survive; this one exercises the generated
    // (de)serialisation for the types the app actually uses.
    //
    // rootBundle also proves the spec assets shipped in the package — on iOS
    // they live in Runner.app/flutter_assets, and an asset-declaration
    // regression in pubspec.yaml is invisible to every host test.
    // Built from the provider's own constants rather than a literal: the
    // specs are bundled straight out of the vendored subtree now, and a
    // hardcoded path here would keep asserting an asset directory that no
    // longer exists.
    final yaml =
        await rootBundle.loadString(specAssetPath(fallbackSpecPath));
    final spec = await loadDeviceSpec(yaml: yaml);
    expect(spec.deviceName, 'Example Smart Bulb');
    expect(spec.localNamePrefixes, contains('ACME_'));
    expect(spec.services, isNotEmpty);
  });
}
