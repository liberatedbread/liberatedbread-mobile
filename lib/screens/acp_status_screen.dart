// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/error_text.dart';
import '../models/network_device.dart';
import '../providers/network_control_provider.dart';
import '../providers/spec_codec_provider.dart';
import '../services/acp_status_client.dart';
import '../services/spec_codec.dart';
import '../src/rust/protocol/apple_acp.dart';
import '../widgets/ad_banner_bar.dart';
import '../widgets/read_only_commands_card.dart';

/// Builds the client this screen reads through. A provider so a test can hand
/// it a fake instead of a socket.
final acpClientFactoryProvider =
    Provider<AcpStatusClient Function(String host, int port)>(
      (ref) =>
          (host, port) => AcpStatusClient(host: host, port: port),
    );

/// An AirPort base station's status: name, model, firmware, uptime and Wi-Fi
/// network name.
///
/// Read-only. Nothing here writes a setting or restarts the base station,
/// because either can drop the whole network, this phone's way back to it
/// included. It reads when asked, over SRP; the password lives in the text
/// field while the screen is open and is stored nowhere.
class AcpStatusScreen extends ConsumerStatefulWidget {
  final NetworkDevice device;
  final NetworkControls controls;
  final String? category;
  final String? specKey;

  const AcpStatusScreen({
    super.key,
    required this.device,
    required this.controls,
    this.category,
    this.specKey,
  });

  @override
  ConsumerState<AcpStatusScreen> createState() => _AcpStatusScreenState();
}

class _AcpStatusScreenState extends ConsumerState<AcpStatusScreen> {
  static const _fallbackPort = 5009;

  final _password = TextEditingController();
  ReadOnlySurfaceDto? _surface;
  AcpStatusDto? _status;
  String? _error;
  bool _reading = false;

  @override
  void initState() {
    super.initState();
    unawaited(_loadSurface());
  }

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  Future<void> _loadSurface() async {
    try {
      final surface = await ref
          .read(specCodecProvider)
          .readOnlySurface(specYaml: widget.controls.specYaml);
      if (mounted) setState(() => _surface = surface);
    } on Object catch (_) {
      // The refused-commands list is a courtesy; the reading does not need it.
    }
  }

  Future<void> _read() async {
    if (_reading) return;
    if (_password.text.isEmpty) {
      setState(() => _error = 'Enter the base station password first.');
      return;
    }
    setState(() {
      _reading = true;
      _error = null;
    });
    final client = ref.read(acpClientFactoryProvider)(
      widget.device.host,
      widget.device.port ?? _surface?.defaultPort ?? _fallbackPort,
    );
    try {
      final status = await client.read(password: _password.text);
      if (!mounted) return;
      setState(() {
        _status = status;
        _reading = false;
      });
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _reading = false;
        _error = friendlyErrorText(
          e,
          context: 'ACP read ${widget.device.host}',
          fallback: 'Could not read the base station.',
        );
      });
    }
  }

  static String _uptime(int seconds) {
    final days = seconds ~/ 86400;
    final hours = (seconds % 86400) ~/ 3600;
    final minutes = (seconds % 3600) ~/ 60;
    if (days > 0) return '$days d $hours h';
    if (hours > 0) return '$hours h $minutes min';
    return '$minutes min';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final status = _status;
    final surface = _surface;
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
            ReadOnlyNotice(advisory: surface?.safetyAdvisory),
            const SizedBox(height: 12),
            TextField(
              controller: _password,
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(
                labelText: 'Base station password',
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Checked with SRP, so the password itself does not cross the '
              'network, and the session is encrypted. This app does not use '
              'the older mode that sends it in a reversible form, and does not '
              'store it.',
              style: text.bodySmall,
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _reading ? null : () => unawaited(_read()),
              icon: const Icon(Icons.refresh),
              label: Text(_reading ? 'Reading…' : 'Read status'),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                status == null
                    ? _error!
                    : '$_error These are the last readings.',
                style: TextStyle(color: scheme.error),
              ),
            ],
            if (status != null) ...[
              const SizedBox(height: 12),
              Card(
                margin: EdgeInsets.zero,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(status.name ?? 'Unnamed', style: text.titleMedium),
                      if (status.productName != null ||
                          status.productId != null)
                        Text(
                          status.productName ??
                              'Product id ${status.productId}',
                        ),
                      if (status.firmware != null)
                        Text('Firmware ${status.firmware}'),
                      if (status.uptimeSeconds != null)
                        Text('Up ${_uptime(status.uptimeSeconds!)}'),
                      if (status.wifiName != null)
                        Text('Wi-Fi network: ${status.wifiName}'),
                      for (final missing in status.unavailable)
                        Text(missing, style: text.bodySmall),
                    ],
                  ),
                ),
              ),
            ],
            const SizedBox(height: 12),
            if (surface != null)
              ReadOnlyCommandsCard(commands: surface.commands),
          ],
        ),
      ),
    );
  }
}
