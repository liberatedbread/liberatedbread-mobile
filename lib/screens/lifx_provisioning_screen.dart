// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/error_text.dart';
import '../providers/network_control_provider.dart';
import '../providers/spec_codec_provider.dart';
import '../services/spec_codec.dart';

/// Onboard a factory-reset LIFX strip onto WiFi over its own setup AP.
///
/// This drives the legacy access-point exchange the spec documents: once the
/// phone is on the strip's setup network, the app asks the strip to scan
/// (`GetAccessPoints`), lets the user pick a network and enter its password, and
/// hands the credentials over (`SetAccessPoint`). The strip then drops its AP
/// and joins the home network.
///
/// Two honesty notes the UI makes plain, because the protocol is what it is:
/// joining the setup AP is a manual step (mobile platforms do not let an app
/// switch WiFi networks for you), and the passphrase is sent unencrypted — the
/// setup AP is the only protection — so it is sent once and never stored.
/// Matter-era firmware onboards over BLE and ignores this exchange entirely.
class LifxProvisioningScreen extends ConsumerStatefulWidget {
  const LifxProvisioningScreen({super.key});

  @override
  ConsumerState<LifxProvisioningScreen> createState() =>
      _LifxProvisioningScreenState();
}

enum _Step {
  joinAp,
  scanning,
  pickNetwork,
  enterPassword,
  sending,
  done,
  failed
}

class _LifxProvisioningScreenState
    extends ConsumerState<LifxProvisioningScreen> {
  /// The setup network is its own subnet with one device on it; a broadcast
  /// reaches it whether or not we know its address yet.
  static const _setupBroadcast = '255.255.255.255';

  _Step _step = _Step.joinAp;
  List<LifxAccessPointDto> _networks = const [];
  LifxAccessPointDto? _selected;
  bool _manual = false;
  final _ssidController = TextEditingController();
  final _passwordController = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _ssidController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _scan() async {
    setState(() {
      _step = _Step.scanning;
      _error = null;
    });
    try {
      final codec = ref.read(specCodecProvider);
      final client = ref.read(lifxControlClientProvider);
      final seq = client.nextSequence();
      final probe = await codec.buildLifxGetAccessPoints(sequence: seq);
      final replies =
          await client.collect(_setupBroadcast, probe, sequence: seq);

      final seen = <String>{};
      final networks = <LifxAccessPointDto>[];
      for (final reply in replies) {
        try {
          final ap = await codec.decodeLifxAccessPoint(bytes: reply);
          if (ap.ssid.isNotEmpty && seen.add(ap.ssid)) networks.add(ap);
        } catch (_) {
          // A malformed scan result is skipped, not fatal.
        }
      }
      networks.sort((a, b) => b.strength.compareTo(a.strength));
      if (!mounted) return;
      setState(() {
        _networks = networks;
        // No networks (some firmware scans lazily, or hidden SSIDs) is a real
        // outcome — fall straight to manual entry rather than a dead end.
        _manual = networks.isEmpty;
        _step = _Step.pickNetwork;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = friendlyErrorText(e,
            context: 'scan for networks',
            fallback: 'The strip did not answer. Confirm you are on its '
                'setup WiFi network and try again.');
        _step = _Step.failed;
      });
    }
  }

  Future<void> _send() async {
    final ssid = _manual ? _ssidController.text.trim() : _selected?.ssid;
    if (ssid == null || ssid.isEmpty) return;
    setState(() {
      _step = _Step.sending;
      _error = null;
    });
    try {
      final codec = ref.read(specCodecProvider);
      final client = ref.read(lifxControlClientProvider);
      // A manually-typed network has no scan entry to take a security byte from,
      // so try WPA2-AES, what home networks overwhelmingly run.
      final security =
          _manual ? await codec.lifxDefaultSecurity() : _selected!.security;
      final bytes = await codec.renderLifxSetAccessPoint(
        ssid: ssid,
        password: _passwordController.text,
        security: security,
        sequence: client.nextSequence(),
      );
      // Fire-and-forget: SetAccessPoint is not acknowledged — the strip drops
      // its AP and joins the home network. The password is not kept anywhere.
      await client.send(_setupBroadcast, bytes);
      _passwordController.clear();
      if (!mounted) return;
      setState(() => _step = _Step.done);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = friendlyErrorText(e,
            context: 'send credentials',
            fallback: 'Could not hand over the credentials. Try again.');
        _step = _Step.failed;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Set up a LIFX device')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: switch (_step) {
            _Step.joinAp => _joinApStep(),
            _Step.scanning => _busyStep('Asking the strip to scan…'),
            _Step.pickNetwork => _pickNetworkStep(),
            _Step.enterPassword => _passwordStep(),
            _Step.sending => _busyStep('Handing over the credentials…'),
            _Step.done => _doneStep(),
            _Step.failed => _failedStep(),
          },
        ),
      ),
    );
  }

  Widget _heading(String title, String body) {
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: text.headlineSmall),
        const SizedBox(height: 12),
        Text(body, style: text.bodyMedium),
        const SizedBox(height: 24),
      ],
    );
  }

  Widget _joinApStep() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _heading(
          'Join the strip’s WiFi',
          'Factory-reset the strip if it is not new: switch it off and on five '
              'times, about two seconds each, until it cycles colours.\n\n'
              'Then open your phone’s WiFi settings and join the network '
              'named after the product (for example “LIFX Z 04A3C1”). '
              'Come back here once you are connected to it.',
        ),
        FilledButton(
          onPressed: _scan,
          child: const Text('I’ve joined the LIFX network'),
        ),
      ],
    );
  }

  Widget _busyStep(String label) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 48),
      child: Column(
        children: [
          const Center(child: CircularProgressIndicator()),
          const SizedBox(height: 16),
          Center(child: Text(label)),
        ],
      ),
    );
  }

  Widget _pickNetworkStep() {
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _heading('Choose your home network',
            'Pick the WiFi network the strip should join.'),
        if (!_manual) ...[
          for (final ap in _networks)
            Card(
              margin: const EdgeInsets.only(bottom: 8),
              child: ListTile(
                leading: const Icon(Icons.wifi),
                title: Text(ap.ssid),
                subtitle: Text('Signal ${ap.strength}'),
                onTap: () => setState(() {
                  _selected = ap;
                  _step = _Step.enterPassword;
                }),
              ),
            ),
          const SizedBox(height: 8),
          TextButton.icon(
            onPressed: () => setState(() => _manual = true),
            icon: const Icon(Icons.edit),
            label: const Text('Enter a network name manually'),
          ),
        ] else ...[
          if (_networks.isEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                'The strip reported no networks. Type your network’s exact '
                'name; WPA/WPA2 is assumed.',
                style: text.bodySmall,
              ),
            ),
          TextField(
            controller: _ssidController,
            decoration: const InputDecoration(
              labelText: 'Network name (SSID)',
              border: OutlineInputBorder(),
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: _ssidController.text.trim().isEmpty
                ? null
                : () => setState(() => _step = _Step.enterPassword),
            child: const Text('Next'),
          ),
        ],
      ],
    );
  }

  Widget _passwordStep() {
    final ssid = _manual ? _ssidController.text.trim() : _selected?.ssid ?? '';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _heading('Password for “$ssid”',
            'The strip needs the network password to join.'),
        TextField(
          controller: _passwordController,
          obscureText: true,
          decoration: const InputDecoration(
            labelText: 'WiFi password',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            const Icon(Icons.lock_outline, size: 16),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Sent unencrypted over the strip’s setup network, and never '
                'stored on your phone.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),
        FilledButton(
          onPressed: _send,
          child: const Text('Send to the strip'),
        ),
      ],
    );
  }

  Widget _doneStep() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Icon(Icons.check_circle, color: Colors.green, size: 56),
        const SizedBox(height: 16),
        _heading(
            'Credentials sent',
            'The strip is joining your network now — its setup WiFi will '
                'disappear within about half a minute.\n\nReconnect your phone '
                'to your home WiFi, then run a scan to find the strip and control '
                'it.'),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Done'),
        ),
      ],
    );
  }

  Widget _failedStep() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(_error ?? 'Something went wrong.',
            style: Theme.of(context)
                .textTheme
                .bodyLarge
                ?.copyWith(color: Theme.of(context).colorScheme.error)),
        const SizedBox(height: 20),
        FilledButton(
          onPressed: () => setState(() => _step = _Step.joinAp),
          child: const Text('Start over'),
        ),
      ],
    );
  }
}
