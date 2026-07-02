// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/constants.dart';
import '../core/ha_url.dart';
import '../models/ha_config.dart';
import '../providers/ha_provider.dart';
import '../services/ha_api_client.dart';
import '../widgets/tailscale_suggestion_card.dart';

/// Home Assistant companion-mode setup and status.
///
/// Unconfigured: URL + long-lived-token form with live Tailscale remote-
/// access hints. Registered: connection status, forwarding toggle, and
/// disconnect.
class HaSettingsScreen extends ConsumerStatefulWidget {
  const HaSettingsScreen({super.key});

  @override
  ConsumerState<HaSettingsScreen> createState() => _HaSettingsScreenState();
}

class _HaSettingsScreenState extends ConsumerState<HaSettingsScreen> {
  final _urlController = TextEditingController();
  final _tokenController = TextEditingController();
  bool _busy = false;
  String? _errorMessage;

  @override
  void dispose() {
    _urlController.dispose();
    _tokenController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final configAsync = ref.watch(haConfigProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Home Assistant')),
      body: configAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text('Could not load settings: $e',
                style: const TextStyle(color: Colors.red)),
          ),
        ),
        data: (config) => config != null && config.isRegistered
            ? _buildRegisteredView(config)
            : _buildSetupForm(),
      ),
    );
  }

  Widget _buildSetupForm() {
    final urlKind = classifyHaUrl(_urlController.text);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text(
          'Companion mode forwards live sensor readings from your BLE '
          'devices (battery, power state, and more) to Home Assistant.',
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _urlController,
          enabled: !_busy,
          keyboardType: TextInputType.url,
          autocorrect: false,
          onChanged: (_) => setState(() {}),
          decoration: const InputDecoration(
            labelText: 'Home Assistant URL',
            hintText: 'http://homeassistant.local:8123',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _tokenController,
          enabled: !_busy,
          obscureText: true,
          autocorrect: false,
          decoration: const InputDecoration(
            labelText: 'Long-lived access token',
            helperText: 'In Home Assistant: your profile -> Security -> '
                'Long-lived access tokens',
            helperMaxLines: 2,
            border: OutlineInputBorder(),
          ),
        ),
        TailscaleSuggestionCard(kind: urlKind, onLearnMore: _openTailscale),
        if (_errorMessage != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child:
                Text(_errorMessage!, style: const TextStyle(color: Colors.red)),
          ),
        const SizedBox(height: 8),
        FilledButton.icon(
          onPressed: _busy ? null : _connect,
          icon: _busy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.link),
          label: Text(_busy ? 'Connecting...' : 'Connect'),
        ),
      ],
    );
  }

  Widget _buildRegisteredView(HaConfig config) {
    final forwarder = ref.watch(haForwarderProvider);
    final webhookId = config.webhookId!;
    final maskedWebhook =
        webhookId.length > 8 ? '${webhookId.substring(0, 8)}...' : webhookId;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.check_circle, color: Colors.green.shade700),
                    const SizedBox(width: 8),
                    const Text('Connected',
                        style: TextStyle(fontWeight: FontWeight.w600)),
                  ],
                ),
                const SizedBox(height: 8),
                Text(config.baseUrl),
                Text('Webhook: $maskedWebhook',
                    style: const TextStyle(color: Colors.grey, fontSize: 12)),
              ],
            ),
          ),
        ),
        SwitchListTile(
          title: const Text('Forward sensor updates'),
          subtitle: const Text(
              'Send decoded values to Home Assistant while connected to '
              'devices'),
          value: config.enabled,
          onChanged: (v) => ref.read(haConfigProvider.notifier).setEnabled(v),
        ),
        ListenableBuilder(
          listenable: forwarder.status,
          builder: (context, _) {
            final status = forwarder.status;
            final String text;
            if (status.lastError != null) {
              text = 'Last error: ${status.lastError}';
            } else if (status.lastSuccess != null) {
              text = 'Last update sent: ${status.lastSuccess}';
            } else {
              text = 'No updates sent yet - connect to a device to start '
                  'forwarding.';
            }
            return Padding(
              padding: const EdgeInsets.all(12),
              child: Text(text,
                  style: TextStyle(
                      fontSize: 12,
                      color:
                          status.lastError != null ? Colors.red : Colors.grey)),
            );
          },
        ),
        TailscaleSuggestionCard(
          kind: classifyHaUrl(config.baseUrl),
          onLearnMore: _openTailscale,
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: _confirmDisconnect,
          icon: const Icon(Icons.link_off),
          label: const Text('Disconnect'),
        ),
      ],
    );
  }

  Future<void> _connect() async {
    final url = _urlController.text.trim();
    final token = _tokenController.text.trim();
    if (url.isEmpty || token.isEmpty) {
      setState(() => _errorMessage = 'Enter both a URL and an access token.');
      return;
    }
    setState(() {
      _busy = true;
      _errorMessage = null;
    });
    try {
      await ref
          .read(haConfigProvider.notifier)
          .register(baseUrl: url, token: token);
    } on HaApiException catch (e) {
      if (mounted) setState(() => _errorMessage = _friendlyError(e));
    } catch (e) {
      if (mounted) setState(() => _errorMessage = 'Unexpected error: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _friendlyError(HaApiException e) {
    return switch (e) {
      HaAuthException() => 'Home Assistant rejected the access token. '
          'Create a new long-lived token and try again.',
      HaNotFoundException() => 'That address does not look like a Home '
          'Assistant server (mobile_app API not found).',
      HaNetworkException() => 'Could not reach the server. Are you on the '
          'same network? For access away from home, see the Tailscale tip '
          'below.',
      HaServerException() => e.message,
    };
  }

  Future<void> _confirmDisconnect() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Disconnect from Home Assistant?'),
        content: const Text(
            'This forgets the connection on this phone. The OpenGreenIoT '
            'device entry in Home Assistant is not deleted - remove it '
            'under Settings -> Devices in Home Assistant if you want it '
            'gone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Disconnect'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await ref.read(haConfigProvider.notifier).disconnect();
    }
  }

  void _openTailscale() {
    final open = ref.read(urlOpenerProvider);
    unawaited(open(Uri.parse(AppConstants.tailscaleHaKbUrl)));
  }
}
