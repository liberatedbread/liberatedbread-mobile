// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:liberated_bread_mobile/models/network_device.dart';
import 'package:liberated_bread_mobile/providers/network_control_provider.dart';
import 'package:liberated_bread_mobile/providers/settings_store_provider.dart';
import 'package:liberated_bread_mobile/providers/spec_codec_provider.dart';
import 'package:liberated_bread_mobile/screens/network_device_screen.dart';
import 'package:liberated_bread_mobile/services/http_control_service.dart';
import 'package:liberated_bread_mobile/services/spec_codec.dart';

import '../fakes/fake_spec_codec.dart';
import '../fakes/in_memory_settings_store.dart';

const _capabilities = NetworkCapabilitiesDto(
  defaultPort: 443,
  defaultScheme: 'https',
  tlsVerification: 'trust_on_first_use',
  tlsSelfSigned: true,
  advertisedPortUnreliable: false,
  mqttClientIdGenerated: false,
);

const _entity = NetworkEntityDto(
  isInstanced: false,
  name: 'Production',
  platform: 'sensor',
  stateCommand: 'get_production_v1',
  valueField: 'production',
  options: [],
  actions: [],
  transport: 'http',
);

void main() {
  testWidgets('forget certificate clears its pin and retries the device', (
    tester,
  ) async {
    final store = InMemorySettingsStore({
      'tls.pin.host:192.168.1.60': 'old-fingerprint',
    });
    var calls = 0;
    final httpClient = HttpControlClient(
      httpsClient: MockClient((request) async {
        calls++;
        if (calls == 1) throw const ControlCertificateChangedException();
        return http.Response('{"production": 1}', 200);
      }),
    );
    final device = NetworkDevice(
      host: '192.168.1.60',
      name: 'Envoy',
      port: 443,
      sources: const {NetworkDiscoverySource.mdns},
      discoveredAt: DateTime(2026),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsStoreProvider.overrideWithValue(store),
          httpControlClientProvider.overrideWithValue(httpClient),
          specCodecProvider.overrideWithValue(
            FakeSpecCodec(
              networkEntities: (_) => [_entity],
              networkCapabilitiesResult: _capabilities,
              networkHttpRequest: (_, _) => const HttpRequestDto(
                method: 'GET',
                path: '/production',
                body: '',
                scheme: 'https',
              ),
            ),
          ),
        ],
        child: MaterialApp(
          home: NetworkDeviceScreen(
            device: device,
            controls: const NetworkControls(
              specYaml: 'envoy',
              entities: [_entity],
              capabilities: _capabilities,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(calls, 1);
    expect(
      find.textContaining('different security certificate'),
      findsOneWidget,
    );
    expect(find.text('Forget certificate & retry'), findsOneWidget);

    await tester.tap(find.text('Forget certificate & retry'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Forget & retry').last);
    await tester.pumpAndSettle();

    expect(calls, 2);
    expect(store.values.containsKey('tls.pin.host:192.168.1.60'), isFalse);
    expect(find.text('Forget certificate & retry'), findsNothing);
    expect(find.textContaining('different security certificate'), findsNothing);
  });
}
