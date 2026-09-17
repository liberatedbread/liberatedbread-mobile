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
import '../core/error_text.dart';

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
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Home Assistant')),
      // Landscape is declared for iPhone; the explicitly-padded ListViews below
      // ignore MediaQuery.padding, so without this the form's edge sat under
      // the notch / Dynamic Island and the last row under the home indicator.
      body: SafeArea(
        child: configAsync.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                friendlyErrorText(
                  e,
                  context: 'load HA settings',
                  fallback: 'Could not load your Home Assistant settings.',
                ),
                style: TextStyle(color: scheme.error),
              ),
            ),
          ),
          data: (config) => config != null && config.isRegistered
              ? _buildRegisteredView(config)
              : _buildSetupForm(),
        ),
      ),
    );
  }

  Widget _buildSetupForm() {
    final urlKind = classifyHaUrl(_urlController.text);
    final scheme = Theme.of(context).colorScheme;
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
            helperText:
                'In Home Assistant: your profile -> Security -> '
                'Long-lived access tokens',
            helperMaxLines: 2,
            border: OutlineInputBorder(),
          ),
        ),
        TailscaleSuggestionCard(kind: urlKind, onLearnMore: _openTailscale),
        if (_errorMessage != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(_errorMessage!, style: TextStyle(color: scheme.error)),
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
    // Theme roles, not Colors.* literals: grey and green fail contrast on the
    // light surface and none of them adapt to dark mode.
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final webhookId = config.webhookId!;
    final maskedWebhook = webhookId.length > 8
        ? '${webhookId.substring(0, 8)}...'
        : webhookId;
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
                    Icon(Icons.check_circle, color: scheme.tertiary),
                    const SizedBox(width: 8),
                    const Text(
                      'Connected',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(config.baseUrl),
                Text(
                  'Webhook: $maskedWebhook',
                  style: textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
        SwitchListTile(
          title: const Text('Forward sensor updates'),
          subtitle: const Text(
            'Send decoded values to Home Assistant while connected to '
            'devices',
          ),
          value: config.enabled,
          onChanged: (v) async {
            // The keystore write can fail; without a catch that is both a
            // silently-ignored toggle and an unhandled async error.
            try {
              await ref.read(haConfigProvider.notifier).setEnabled(v);
              if (mounted && _errorMessage != null) {
                setState(() => _errorMessage = null);
              }
            } catch (e) {
              if (!mounted) return;
              setState(
                () => _errorMessage = friendlyErrorText(
                  e,
                  context: 'HA setEnabled',
                  fallback: 'Could not save the forwarding setting.',
                ),
              );
            }
          },
        ),
        if (_errorMessage != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(_errorMessage!, style: TextStyle(color: scheme.error)),
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
              text =
                  'No updates sent yet - connect to a device to start '
                  'forwarding.';
            }
            return Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                text,
                style: textTheme.bodySmall?.copyWith(
                  color: status.lastError != null
                      ? scheme.error
                      : scheme.onSurfaceVariant,
                ),
              ),
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
      if (mounted) setState(() => _errorMessage = friendlyHaMessage(e));
    } catch (e) {
      if (mounted) {
        setState(
          () => _errorMessage = friendlyErrorText(
            e,
            context: 'HA register',
            fallback:
                'Something went wrong connecting to Home Assistant. '
                'Check the address and token, then try again.',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _confirmDisconnect() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Disconnect from Home Assistant?'),
        content: const Text(
          'This forgets the connection on this phone. The Liberated Bread '
          'device entry in Home Assistant is not deleted - remove it '
          'under Settings -> Devices in Home Assistant if you want it '
          'gone.',
        ),
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
    // mounted check: ConsumerState.ref throws a StateError if the screen was
    // disposed while the dialog was up (use_build_context_synchronously does
    // not catch ref-after-await).
    if (confirmed != true || !mounted) return;
    try {
      await ref.read(haConfigProvider.notifier).disconnect();
    } catch (e) {
      if (!mounted) return;
      setState(
        () => _errorMessage = friendlyErrorText(
          e,
          context: 'HA disconnect',
          fallback: 'Could not disconnect from Home Assistant.',
        ),
      );
    }
  }

  void _openTailscale() {
    final open = ref.read(urlOpenerProvider);
    unawaited(open(Uri.parse(AppConstants.tailscaleHaKbUrl)));
  }
}
