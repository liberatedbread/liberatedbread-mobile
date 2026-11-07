// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';

import 'package:flutter/services.dart';
// The app's own patched copy, pulled in by dependency_overrides, which this
// lint does not count as a dependency.
// ignore: depend_on_referenced_packages
import 'package:flutter_blue_plus_darwin/flutter_blue_plus_darwin.dart';
import 'package:flutter_blue_plus_platform_interface/flutter_blue_plus_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';

/// An OnDescriptorRead as the patched Darwin plugin sends it, through the
/// package's own method-channel handler.
///
/// A failed descriptor read reaches CoreBluetooth's callback with no value.
/// The plugin used to send `value` as NSNull, but BmDescriptorData.fromMap
/// casts `value` to a non-nullable Uint8List: the handler threw, no event
/// arrived, and the caller's read() sat out its timeout holding
/// flutter_blue_plus's global mutex. The plugin now sends an empty value so
/// the success flag and error text reach the caller.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('flutter_blue_plus/methods');
  const codec = StandardMethodCodec();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late FlutterBluePlusDarwin plugin;

  setUp(() async {
    messenger.setMockMethodCallHandler(channel, (call) async => true);
    plugin = FlutterBluePlusDarwin();
    // Any call to the platform installs the plugin's incoming-call handler;
    // setLogLevel is the one that skips the restart handshake.
    await plugin.setLogLevel(
      BmSetLogLevelRequest(logLevel: LogLevel.none, logColor: false),
    );
  });

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  Future<ByteData?> deliver(Map<String, Object?> arguments) {
    final reply = Completer<ByteData?>();
    messenger.handlePlatformMessage(
      channel.name,
      codec.encodeMethodCall(MethodCall('OnDescriptorRead', arguments)),
      reply.complete,
    );
    return reply.future;
  }

  Map<String, Object?> failedRead(Object? value) => {
    'remote_id': '00000000-0000-0000-0000-000000000001',
    'service_uuid': '180f',
    'characteristic_uuid': '2a19',
    'instance_id': 0,
    'descriptor_uuid': '2902',
    'value': value,
    // `@(error == nil)` boxes the C comparison, an int.
    'success': 0,
    'error_string': 'The attribute could not be read.',
    'error_code': 2,
  };

  test(
    'a failed read with an empty value reaches the caller as a failure',
    () async {
      final event = plugin.onDescriptorRead.first;
      await deliver(failedRead(Uint8List(0)));
      final data = await event.timeout(const Duration(seconds: 1));
      expect(data.success, isFalse);
      expect(data.errorCode, 2);
      expect(data.errorString, 'The attribute could not be read.');
      expect(data.value, isEmpty);
    },
  );

  test('the NSNull value it replaced never became an event', () async {
    // Why the native side must not send NSNull: the handler throws on it and
    // the read it answers is never told.
    final events = <BmDescriptorData>[];
    final sub = plugin.onDescriptorRead.listen(events.add);
    addTearDown(sub.cancel);
    final reply = await deliver(failedRead(null));
    expect(
      () => codec.decodeEnvelope(reply!),
      throwsA(isA<PlatformException>()),
    );
    await pumpEventQueue();
    expect(events, isEmpty);
  });
}
