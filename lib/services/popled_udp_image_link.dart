// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:typed_data';

import 'led_image_link.dart';
import 'popled_udp_control_service.dart';
import 'spec_codec.dart';

/// The image editor's link to a Wi-Fi LOY SPACE panel.
///
/// What goes over it is the BLE backpack's GIF upload — a GIF89a into
/// program slot 59, chunk by acknowledged chunk — carried in the spec's UDP
/// datagrams. led-space.yaml says its app sends a zlib-compressed BMP inside a
/// `pkts_program` JSON instead, but never gives that program's TLV layout, so
/// that path cannot be built. Same board family, same frame; untested over
/// Wi-Fi.
class PopledUdpImageLink implements LedImageLink {
  final SpecCodec _codec;
  final PopledUdpClient _client;
  final String host;
  final int port;

  PopledUdpImageLink(this._codec, this._client, this.host, this.port);

  @override
  Future<void> sendImage(
    Uint8List rgb,
    int width,
    int height,
    String specYaml,
  ) async {
    final bodies = await _codec.popledUdpUploadBodies(
      specYaml: specYaml,
      width: width,
      height: height,
      frames: [rgb],
      delayMs: 0,
    );
    await _client.sendAll(host, port, bodies);
  }

  @override
  Future<({int width, int height})?> panelSize() =>
      _client.panelSize(host, port);
}
