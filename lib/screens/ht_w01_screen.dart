// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/error_text.dart';
import '../models/network_device.dart';
import '../providers/network_control_provider.dart';
import '../services/ht_w01_client.dart';
import '../src/rust/api/ht_w01_api.dart';
import '../src/rust/protocol/ht_w01.dart';
import '../src/rust/protocol/readonly.dart';
import '../widgets/ad_banner_bar.dart';
import '../widgets/read_only_commands_card.dart';

/// Builds the client this screen drives. A provider so a test can hand it a
/// fake instead of a socket and the Rust codec.
final htW01ClientFactoryProvider =
    Provider<HtW01Client Function(String host, int port)>(
      (ref) =>
          (host, port) => HtW01CameraClient(host: host, port: port),
    );

/// A Vevor VT256 / HT-W01 thermal camera's settings: palette, measuring
/// range, emissivity, and a shutter refresh.
///
/// The configuration reset, the restart and the Wi-Fi channel are listed and
/// not offered: the spec cannot say what the reset clears, and the other two
/// drop the access point this phone is joined to. The thermal picture itself
/// is not here; its UDP layout is not recovered, and the camera's RTSP
/// stream is outside this screen.
class HtW01Screen extends ConsumerStatefulWidget {
  final NetworkDevice device;
  final NetworkControls controls;
  final String? category;
  final String? specKey;

  const HtW01Screen({
    super.key,
    required this.device,
    required this.controls,
    this.category,
    this.specKey,
  });

  @override
  ConsumerState<HtW01Screen> createState() => _HtW01ScreenState();
}

class _HtW01ScreenState extends ConsumerState<HtW01Screen> {
  /// The camera's fixed address on its own access point, and its port.
  static const _cameraHost = '192.168.1.10';
  static const _cameraPort = 8080;

  late final HtW01Client _client = ref.read(htW01ClientFactoryProvider)(
    widget.device.host.isEmpty ? _cameraHost : widget.device.host,
    widget.device.port ?? _cameraPort,
  );
  late final List<HtW01PaletteDto> _palettes = _client.palettes();
  final _emissivity = TextEditingController();
  List<ReadOnlyCommandDto>? _policy;
  HtW01Settings? _settings;
  String? _message;
  bool _messageIsError = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    unawaited(_loadPolicy());
  }

  @override
  void dispose() {
    _emissivity.dispose();
    super.dispose();
  }

  Future<void> _loadPolicy() async {
    try {
      final policy = await _client.commandPolicy(widget.controls.specYaml);
      if (mounted) setState(() => _policy = policy);
    } on Object catch (_) {
      // A courtesy list; nothing the screen sends depends on it.
    }
  }

  Future<void> _run(String what, Future<String> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final message = await action();
      if (!mounted) return;
      setState(() {
        _busy = false;
        _message = message;
        _messageIsError = false;
      });
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _messageIsError = true;
        _message = friendlyErrorText(
          e,
          context: 'HT-W01 $what',
          fallback: 'Could not $what.',
        );
      });
    }
  }

  String _ackText(HtW01Ack ack) => ack.answered
      ? 'Sent; the camera answered.'
      : 'Sent; the camera sent nothing back. Its reply format is not '
            'recovered, so this does not mean it refused.';

  Future<void> _read() => _run('read the settings', () async {
    final settings = await _client.readSettings();
    if (mounted) {
      setState(() {
        _settings = settings;
        final e = settings.emissivityHundredths;
        if (e != null) _emissivity.text = (e / 100).toStringAsFixed(2);
      });
    }
    return settings.palette == null &&
            settings.range == null &&
            settings.emissivityHundredths == null
        ? 'The camera answered, in a form this app cannot read values from.'
        : 'Read.';
  });

  Future<void> _setEmissivity() async {
    final value = double.tryParse(_emissivity.text.trim());
    if (value == null || value < 0 || value > 1) {
      setState(() {
        _message = 'Emissivity is a number from 0.00 to 1.00.';
        _messageIsError = true;
      });
      return;
    }
    await _run(
      'set the emissivity',
      () async => _ackText(await _client.setEmissivity((value * 100).round())),
    );
  }

  String _paletteName(int? value) =>
      _palettes.where((p) => p.value == value).firstOrNull?.name ?? 'not read';

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final settings = _settings;
    final policy = _policy;
    return Scaffold(
      bottomNavigationBar: DeviceAdBannerBar(
        category: widget.category,
        specKey: widget.specKey,
      ),
      appBar: AppBar(title: Text(widget.device.displayName)),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 40),
          children: [
            Text(
              "Join the camera's own HT-W01 Wi-Fi network first (the phone has "
              'no internet while joined). This screen changes the camera\'s '
              'image settings. It cannot reset, restart or re-channel the '
              'camera, and it does not show the thermal picture.',
              style: text.bodySmall,
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _busy ? null : () => unawaited(_read()),
              icon: const Icon(Icons.refresh),
              label: const Text('Read settings'),
            ),
            if (_message != null) ...[
              const SizedBox(height: 12),
              Text(
                _message!,
                style: _messageIsError ? TextStyle(color: scheme.error) : null,
              ),
            ],
            const SizedBox(height: 16),
            Text('Palette: ${_paletteName(settings?.palette)}'),
            const SizedBox(height: 4),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final palette in _palettes)
                  ChoiceChip(
                    label: Text(palette.name),
                    selected: settings?.palette == palette.value,
                    onSelected: _busy
                        ? null
                        : (_) => unawaited(
                            _run(
                              'set the palette',
                              () async => _ackText(
                                await _client.setPalette(palette.value),
                              ),
                            ),
                          ),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            const Text('Measuring range'),
            const SizedBox(height: 4),
            Wrap(
              spacing: 8,
              children: [
                for (final (range, label) in const [
                  (HtW01Range.small, 'Small, -20 to 120 °C'),
                  (HtW01Range.large, 'Large, 120 to 550 °C'),
                ])
                  ChoiceChip(
                    label: Text(label),
                    selected: settings?.range == range,
                    onSelected: _busy
                        ? null
                        : (_) => unawaited(
                            _run(
                              'set the range',
                              () async => _ackText(
                                await _client.setMeasuringRange(range),
                              ),
                            ),
                          ),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _emissivity,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: const InputDecoration(
                      labelText: 'Emissivity (0.00 to 1.00)',
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: _busy ? null : () => unawaited(_setEmissivity()),
                  child: const Text('Set'),
                ),
              ],
            ),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: _busy
                  ? null
                  : () => unawaited(
                      _run(
                        'refresh the shutter',
                        () async => _ackText(await _client.refreshShutter()),
                      ),
                    ),
              icon: const Icon(Icons.camera),
              label: const Text('Refresh shutter'),
            ),
            const SizedBox(height: 16),
            if (policy != null)
              ReadOnlyCommandsCard(
                commands: policy,
                sentLabel: 'Sent by this app.',
              ),
          ],
        ),
      ),
    );
  }
}
