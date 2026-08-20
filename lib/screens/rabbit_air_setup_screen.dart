// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/error_text.dart';
import '../models/iot_device.dart';
import '../providers/ble_provider.dart';
import '../providers/network_control_provider.dart';
import '../services/rabbit_air_provision_service.dart';
import '../widgets/device_list_tile.dart';

/// Guides a Rabbit Air purifier onto the home Wi-Fi over Bluetooth — the
/// BLE-provisioning counterpart of [AdoptDeviceScreen]'s setup-AP flow.
///
/// The screen only sequences and narrates: the conversation itself (info
/// read, network-list poll, join, key push, leave setup mode, LAN
/// verification) is [RabbitAirProvisionService]'s, rendered here from its
/// state stream. Entered with a preselected [device] from the BLE device
/// screen's "Set up Wi-Fi" card, or standalone from the Wi-Fi adoption
/// flow — in which case the first job is finding the unit advertising as
/// "RabbitAirSetup".
class RabbitAirSetupScreen extends ConsumerStatefulWidget {
  /// The purifier to provision, when the BLE device screen sent us. Null
  /// means scan for one.
  final IoTDevice? device;

  const RabbitAirSetupScreen({super.key, this.device});

  @override
  ConsumerState<RabbitAirSetupScreen> createState() =>
      _RabbitAirSetupScreenState();
}

enum _Stage { intro, scanning, working, pickNetwork, failed, done }

class _RabbitAirSetupScreenState extends ConsumerState<RabbitAirSetupScreen> {
  /// An unprovisioned purifier advertises under this name.
  static const setupNamePrefix = 'RabbitAirSetup';

  _Stage _stage = _Stage.intro;
  String _busyLabel = '';
  String? _error;

  final Map<String, IoTDevice> _found = {};
  bool _scanEnded = false;
  StreamSubscription<IoTDevice>? _scanSub;
  StreamSubscription<RabbitAirProvisionState>? _provisionSub;

  List<RabbitAirNetwork> _networks = const [];
  RabbitAirNetwork? _network;
  final _passwordController = TextEditingController();
  bool _obscure = true;

  /// Whether the network picker was ever reached — a failure after that
  /// returns there (the networks are still good), a failure before it offers
  /// to begin again.
  bool _reachedPicker = false;
  String? _doneThingId;
  bool _doneVerified = false;

  /// Read once in initState: ref is off-limits by dispose() time.
  late final RabbitAirProvisionService _service;

  @override
  void initState() {
    super.initState();
    // Read once up front: ref is off-limits by dispose() time.
    _service = ref.read(rabbitAirProvisionServiceProvider);
    _provisionSub = _service.states.listen(_onProvisionState);
    final device = widget.device;
    if (device != null) {
      // Preselected by the BLE device screen: no intro, no scan — begin.
      unawaited(_begin(device));
    }
  }

  @override
  void dispose() {
    unawaited(_scanSub?.cancel() ?? Future<void>.value());
    unawaited(_provisionSub?.cancel() ?? Future<void>.value());
    // Leaving mid-conversation drops the BLE link; the purifier simply stays
    // in setup mode until its own timeout.
    unawaited(_service.cancelLink());
    _passwordController.dispose();
    super.dispose();
  }

  void _onProvisionState(RabbitAirProvisionState state) {
    if (!mounted) return;
    setState(() {
      switch (state.step) {
        case RabbitAirProvisionStep.connecting:
          _stage = _Stage.working;
          _busyLabel = 'Connecting to the purifier...';
        case RabbitAirProvisionStep.readingInfo:
          _stage = _Stage.working;
          _busyLabel = 'Reading the purifier\u2019s info...';
        case RabbitAirProvisionStep.fetchingNetworks:
          _stage = _Stage.working;
          _busyLabel = 'Asking which Wi-Fi networks it can see...';
        case RabbitAirProvisionStep.awaitingNetworkChoice:
          _reachedPicker = true;
          _networks = state.networks;
          _error = null;
          _stage = _Stage.pickNetwork;
        case RabbitAirProvisionStep.joining:
          _stage = _Stage.working;
          _busyLabel = 'Sending your Wi-Fi details to the purifier...';
        case RabbitAirProvisionStep.pushingKey:
          _stage = _Stage.working;
          _busyLabel = 'Securing local control with a fresh key...';
        case RabbitAirProvisionStep.leaving:
          _stage = _Stage.working;
          _busyLabel = 'Leaving setup mode...';
        case RabbitAirProvisionStep.verifying:
          _stage = _Stage.working;
          _busyLabel = 'Watching for the purifier on your network...';
        case RabbitAirProvisionStep.done:
          _doneThingId = state.thingId;
          _doneVerified = state.verified;
          _stage = _Stage.done;
        case RabbitAirProvisionStep.failed:
          _error = state.message;
          if (_reachedPicker) {
            _stage = _Stage.pickNetwork;
          } else if (widget.device != null) {
            _stage = _Stage.failed;
          } else {
            _stage = _Stage.scanning;
          }
      }
    });
  }

  Future<void> _begin(IoTDevice device) async {
    // Fire-and-forget teardown of the scan, the repo's cancel idiom: awaiting
    // the subscription's cancel here would stall the begin behind it.
    unawaited(_scanSub?.cancel() ?? Future<void>.value());
    _scanSub = null;
    unawaited(ref.read(bleServiceProvider).stopScan());
    setState(() {
      _stage = _Stage.working;
      _busyLabel = 'Connecting to the purifier...';
      _error = null;
    });
    await _service.begin(device.id);
  }

  void _startScan() {
    unawaited(_scanSub?.cancel() ?? Future<void>.value());
    setState(() {
      _stage = _Stage.scanning;
      _found.clear();
      _scanEnded = false;
      _error = null;
    });
    _scanSub = ref.read(bleServiceProvider).scan().listen(
      (device) {
        if (!device.name.startsWith(setupNamePrefix)) return;
        setState(() => _found[device.id] = device);
      },
      onError: (Object e) {
        if (!mounted) return;
        setState(() {
          _scanEnded = true;
          _error = friendlyErrorText(
            e,
            context: 'rabbit air setup scan',
            fallback: 'The Bluetooth scan failed. Try again.',
          );
        });
      },
      onDone: () {
        if (!mounted || _stage != _Stage.scanning) return;
        setState(() => _scanEnded = true);
      },
    );
  }

  Future<void> _provision() async {
    final network = _network!;
    setState(() => _error = null);
    await _service.join(
      ssid: network.ssid,
      passphrase: _passwordController.text,
      security: network.security,
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: scheme.surface,
      appBar: AppBar(title: const Text('Set up a Rabbit Air purifier')),
      body: SafeArea(
        child: switch (_stage) {
          _Stage.intro => _buildIntro(context),
          _Stage.scanning => _buildScanning(context),
          _Stage.working => _buildBusy(context),
          _Stage.pickNetwork => _buildPickNetwork(context),
          _Stage.failed => _buildFailed(context),
          _Stage.done => _buildDone(context),
        },
      ),
    );
  }

  Widget _buildIntro(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 40),
      children: [
        Center(
          child: Icon(Icons.air, size: 56, color: scheme.secondary),
        ),
        const SizedBox(height: 24),
        Text('Put the purifier in setup mode',
            textAlign: TextAlign.center,
            style: text.headlineSmall
                ?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.4)),
        const SizedBox(height: 12),
        Text(
          'Setup talks to the purifier over Bluetooth — no temporary Wi-Fi '
          'network to join.',
          textAlign: TextAlign.center,
          style: text.bodyMedium
              ?.copyWith(color: scheme.onSurfaceVariant, height: 1.5),
        ),
        const SizedBox(height: 20),
        _instruction(context, '1',
            'Plug the purifier in and let it finish starting up.'),
        _instruction(
            context,
            '2',
            'Hold the Speed and Wireless buttons until the wireless LED '
                'blinks — the purifier now advertises as "$setupNamePrefix".'),
        const SizedBox(height: 24),
        Center(
          child: ActionPillButton(
            onPressed: _startScan,
            icon: Icons.bluetooth_searching,
            label: 'Find the purifier',
          ),
        ),
      ],
    );
  }

  Widget _instruction(BuildContext context, String number, String text_) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(radius: 13, child: Text(number)),
          const SizedBox(width: 12),
          Expanded(
            child: Text(text_,
                style: text.bodyMedium
                    ?.copyWith(color: scheme.onSurfaceVariant, height: 1.4)),
          ),
        ],
      ),
    );
  }

  Widget _buildScanning(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final devices = _found.values.toList();
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 40),
      children: [
        if (!_scanEnded) ...[
          const Center(child: CircularProgressIndicator()),
          const SizedBox(height: 24),
        ],
        Text(
          devices.isEmpty
              ? (_scanEnded
                  ? 'No purifier in setup mode answered.'
                  : 'Looking for a purifier in setup mode...')
              : 'Which purifier?',
          textAlign: TextAlign.center,
          style: text.titleLarge?.copyWith(fontWeight: FontWeight.w700),
        ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(_error!,
              textAlign: TextAlign.center,
              style: text.bodyMedium?.copyWith(color: scheme.error)),
        ],
        const SizedBox(height: 16),
        for (final device in devices) ...[
          Card(
            margin: EdgeInsets.zero,
            child: ListTile(
              leading: Icon(Icons.air, color: scheme.secondary),
              title: Text(device.displayName),
              subtitle: Text(device.id,
                  style:
                      text.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => unawaited(_begin(device)),
            ),
          ),
          const SizedBox(height: 8),
        ],
        if (_scanEnded) ...[
          const SizedBox(height: 12),
          Center(
            child: ActionPillButton(
              onPressed: _startScan,
              icon: Icons.refresh,
              label: 'Scan again',
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildBusy(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 24),
            Text(_busyLabel,
                textAlign: TextAlign.center,
                style: text.bodyLarge?.copyWith(height: 1.5)),
          ],
        ),
      ),
    );
  }

  Widget _buildPickNetwork(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 40),
      children: [
        Text('Choose your home Wi-Fi',
            style: text.headlineSmall
                ?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.4)),
        const SizedBox(height: 8),
        Text(
          'This is the network the purifier will join once setup finishes. '
          'It must be 2.4 GHz — these radios do not use 5 GHz.',
          style: text.bodyMedium
              ?.copyWith(color: scheme.onSurfaceVariant, height: 1.5),
        ),
        if (_error != null) ...[
          const SizedBox(height: 16),
          Text(_error!, style: text.bodyMedium?.copyWith(color: scheme.error)),
        ],
        const SizedBox(height: 24),
        SectionHeader(
            label: 'Networks the purifier sees', count: _networks.length),
        const SizedBox(height: 12),
        for (final network in _networks) ...[
          Card(
            margin: EdgeInsets.zero,
            color: _network == network ? scheme.secondaryContainer : null,
            child: ListTile(
              leading: Icon(
                  network.security == 0 ? Icons.wifi : Icons.wifi_lock,
                  color: _network == network
                      ? scheme.onSecondaryContainer
                      : scheme.secondary),
              title: Text(network.ssid),
              trailing: _network == network
                  ? const Icon(Icons.check_circle)
                  : const Icon(Icons.chevron_right),
              onTap: () {
                setState(() {
                  _network = network;
                  _error = null;
                });
                // An open network needs no password — provision straight
                // away, the adopt flow's rule for the same case.
                if (network.security == 0) unawaited(_provision());
              },
            ),
          ),
          const SizedBox(height: 8),
        ],
        if (_network != null && _network!.security != 0) ...[
          const SizedBox(height: 16),
          TextField(
            controller: _passwordController,
            obscureText: _obscure,
            autocorrect: false,
            decoration: InputDecoration(
              labelText: 'Password for ${_network!.ssid}',
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                tooltip: _obscure ? 'Show password' : 'Hide password',
                icon: Icon(_obscure ? Icons.visibility_off : Icons.visibility),
                onPressed: () => setState(() => _obscure = !_obscure),
              ),
            ),
            onSubmitted: (_) => unawaited(_provision()),
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: ActionPillButton(
              icon: Icons.arrow_forward,
              label: 'Join this network',
              onPressed: () => unawaited(_provision()),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildFailed(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final device = widget.device!;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 48, color: scheme.error),
            const SizedBox(height: 16),
            Text(_error ?? 'Setup failed.',
                textAlign: TextAlign.center,
                style: text.bodyLarge?.copyWith(height: 1.5)),
            const SizedBox(height: 24),
            ActionPillButton(
              onPressed: () => unawaited(_begin(device)),
              icon: Icons.refresh,
              label: 'Try again',
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDone(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
                _doneVerified ? Icons.check_circle_outline : Icons.help_outline,
                size: 56,
                color: _doneVerified ? scheme.secondary : scheme.outline),
            const SizedBox(height: 24),
            Text(
              _doneVerified
                  ? 'The purifier is on your Wi-Fi.'
                  : 'Setup is sent — confirmation pending.',
              textAlign: TextAlign.center,
              style: text.titleLarge?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 12),
            Text(
              _doneVerified
                  ? 'It answered on your network with the new key. The '
                      'Wi-Fi tab now shows it${_doneThingId == null ? '' : ' '
                          'as $_doneThingId'}.'
                  : 'The purifier did not announce itself before the watch '
                      'timed out — that is often just a slow join. The Wi-Fi '
                      'tab will show it once it appears.',
              textAlign: TextAlign.center,
              style: text.bodyMedium
                  ?.copyWith(color: scheme.onSurfaceVariant, height: 1.5),
            ),
            const SizedBox(height: 24),
            ActionPillButton(
              onPressed: () => Navigator.of(context).pop(),
              icon: Icons.check,
              label: 'Done',
            ),
          ],
        ),
      ),
    );
  }
}
