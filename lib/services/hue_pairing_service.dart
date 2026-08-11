// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';

import '../core/log.dart';
import 'hub_http_client.dart';
import 'spec_codec.dart';

/// What a successful link-button pairing issued.
class PairingResult {
  final String username;
  final String? clientKey;

  const PairingResult({required this.username, this.clientKey});
}

/// The pairing window closed without the button being pressed.
class PairingTimeoutException implements Exception {
  @override
  String toString() =>
      'PairingTimeoutException: link button was not pressed in time';
}

/// The link-button pairing flow, exactly as the spec's `create_user` command
/// states it: render the POST once, then poll it — the same request answers
/// error 101 ("link button not pressed", the keep-waiting signal) until the
/// physical button is pressed, and the credentials afterwards.
///
/// Store-free on purpose: this class proves proximity and returns what the
/// bridge issued; persisting it (keyed by bridgeid, never IP) is the
/// caller's job, which keeps the polling loop testable without a keychain.
class HuePairingService {
  final SpecCodec _codec;
  final HubHttpClient _client;

  /// The identity the whitelist entry is filed under, spelled
  /// `application#instance` per the spec's `devicetype` parameter.
  static const deviceType = 'opengreeniot#mobile';

  /// The bridge's window is ~30 s from the button press; polling a little
  /// longer costs nothing and forgives a slow thumb.
  static const defaultWindow = Duration(seconds: 45);
  static const defaultInterval = Duration(seconds: 2);

  HuePairingService({required SpecCodec codec, required HubHttpClient client})
      : _codec = codec,
        _client = client;

  /// Poll `create_user` until the button is pressed, the [window] closes, or
  /// [cancelled] completes (the user dismissed the sheet).
  ///
  /// [onAttempt] fires before each poll with the attempt number — what a
  /// pairing sheet drives its countdown from.
  Future<PairingResult> pair({
    required String specYaml,
    required String host,
    required String bridgeId,
    Duration window = defaultWindow,
    Duration interval = defaultInterval,
    Future<void>? cancelled,
    void Function(int attempt)? onAttempt,
  }) async {
    final request = await _codec.renderNetworkHttpCommand(
      specYaml: specYaml,
      commandName: 'create_user',
      values: const {'devicetype': deviceType},
    );

    final deadline = DateTime.now().add(window);
    var attempt = 0;
    var wasCancelled = false;
    unawaited(cancelled?.then((_) => wasCancelled = true));

    while (DateTime.now().isBefore(deadline)) {
      if (wasCancelled) throw PairingCancelledException();
      attempt += 1;
      onAttempt?.call(attempt);

      // Sent raw rather than through the envelope check: 101 is this flow's
      // keep-waiting signal, not an error to throw on.
      final body = await _client.sendUnchecked(host, bridgeId, request);
      final outcomes = HubHttpClient.parseV1Envelope(body) ?? const [];
      for (final outcome in outcomes) {
        final success = outcome.success;
        if (success != null && success['username'] is String) {
          Log.hub.info('paired with bridge $bridgeId');
          return PairingResult(
            username: success['username'] as String,
            clientKey: success['clientkey']?.toString(),
          );
        }
        final error = outcome.error;
        if (error != null && !error.isLinkButtonNotPressed) {
          throw HubApiException(error.type, error.description);
        }
      }

      await Future<void>.delayed(interval);
    }
    if (wasCancelled) throw PairingCancelledException();
    throw PairingTimeoutException();
  }
}

/// The user dismissed the pairing flow before it finished.
class PairingCancelledException implements Exception {
  @override
  String toString() => 'PairingCancelledException: pairing was cancelled';
}
