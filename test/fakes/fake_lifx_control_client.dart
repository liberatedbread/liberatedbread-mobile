// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:typed_data';

import 'package:liberated_bread_mobile/services/lifx_control_service.dart';

/// A [LifxControlClient] that answers `collect`/`request` with canned replies
/// (no socket, no waiting) and records every `send` — so the adoption
/// orchestration's LIFX path runs with no UDP.
class FakeLifxControlClient extends LifxControlClient {
  final List<({String host, List<int> packet})> sent = [];

  /// What `collect` returns. Default: one non-empty datagram, enough for a
  /// discovery probe or a single scan result under a fake codec that decodes
  /// any bytes.
  List<Uint8List> collectReplies = [Uint8List(41)];

  int _seq = 0;

  @override
  int nextSequence() => ++_seq;

  @override
  Future<void> send(String host, Uint8List packet, {int sends = 2}) async {
    sent.add((host: host, packet: packet));
  }

  @override
  Future<List<Uint8List>> collect(
    String host,
    Uint8List packet, {
    required int sequence,
    Duration window = const Duration(seconds: 5),
    int sends = 2,
  }) async =>
      collectReplies;

  @override
  Future<Uint8List?> request(
    String host,
    Uint8List packet, {
    required int sequence,
    Duration timeout = const Duration(seconds: 1),
    int retries = 2,
  }) async =>
      collectReplies.isEmpty ? null : collectReplies.first;
}
