// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import '../core/error_text.dart';
import '../core/log.dart';
import '../providers/adopt_provider.dart';
import '../services/adopt_service.dart';
import '../widgets/device_list_tile.dart';
import 'rabbit_air_setup_screen.dart';

/// Guides a person through putting a factory-reset Wi-Fi device onto their home
/// network — the one thing a discovery-and-control app otherwise cannot do,
/// because an un-provisioned device is invisible to every scan until it holds
/// credentials.
///
/// The hard truth the flow is shaped around: neither iOS nor modern Android
/// lets an app silently join a Wi-Fi network on the user's behalf, so the user
/// joins the device's setup AP themselves in system settings. Everything before
/// that is instruction; everything after is the spec-driven conversation in
/// [AdoptService], which this screen only sequences and narrates.
class AdoptDeviceScreen extends ConsumerStatefulWidget {
  const AdoptDeviceScreen({super.key});

  @override
  ConsumerState<AdoptDeviceScreen> createState() => _AdoptDeviceScreenState();
}

enum _Stage { pickDevice, connecting, pickNetwork, credentials, working, done }

/// Which screen drives each spec-declared BLE provisioning conversation, keyed
/// by the spec's `protocol_handler`.
///
/// The counterpart of [AdoptFamily] for the Bluetooth path: those two
/// conversations are declarative enough for [AdoptService] to speak from the
/// spec, whereas a BLE provisioning handshake is stateful enough to need its
/// own service and screen — the sanctioned protocol-handler shape. What stays
/// out of Dart is everything about the device: only the handler key is here,
/// and a family whose handler is missing simply is not offered.
const _bleSetupScreens = <String, WidgetBuilder>{
  'rabbit_air_lan': _rabbitAirSetupScreen,
};

Widget _rabbitAirSetupScreen(BuildContext _) => const RabbitAirSetupScreen();

class _AdoptDeviceScreenState extends ConsumerState<AdoptDeviceScreen> {
  _Stage _stage = _Stage.pickDevice;

  AdoptableDevice? _device;
  AdoptSession? _session;
  List<SetupNetwork> _networks = const [];
  SetupNetwork? _network;
  AdoptOutcome? _outcome;

  final _ssidController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _obscure = true;

  // A one-line status the busy stages show, and the error the recoverable
  // stages surface without leaving the flow.
  String _busyLabel = '';
  String? _error;

  @override
  void dispose() {
    _ssidController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _connect(AdoptableDevice device) async {
    setState(() {
      _device = device;
      _stage = _Stage.connecting;
      _busyLabel = 'Looking for the ${device.profile.specName} on its setup '
          'network...';
      _error = null;
    });
    final service = ref.read(adoptServiceProvider);
    // The head of every adoption transcript: which family, and the spec-derived
    // address the probe below is about to use. Without it the first line in the
    // log is a probe against an IP with no stated origin.
    Log.adopt.info('adopt: connecting to a ${device.profile.specName} '
        '(${device.family.name}) — ssid prefix "${device.profile.ssidPrefix}", '
        'gateway ${device.profile.gatewayIp ?? '<spec says none>'}, '
        'ports ${device.profile.ports.isEmpty ? '<spec says none>' : device.profile.ports.join(', ')}');
    try {
      final session = await service.connect(
        family: device.family,
        specYaml: device.specYaml,
        // Where and on which ports to probe come from the spec's softap
        // profile, not a constant in the service — the setup port varies.
        gatewayIp: device.profile.gatewayIp,
        ports: device.profile.ports.toList(),
      );
      if (!mounted) return;
      if (session == null) {
        // The service has already logged which of the two causes it was; this
        // line is what closes the stage, so a reader can see the flow returned
        // to the picker rather than hung.
        Log.adopt.info('adopt: no device answered on the setup network; back '
            'to the device picker');
        setState(() {
          _stage = _Stage.pickDevice;
          _error = "Couldn't reach the device. Make sure you joined its "
              '"${device.profile.ssidPrefix}…" Wi-Fi network in Settings, then '
              'try again.';
        });
        return;
      }
      _session = session;
      await _loadNetworks();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _stage = _Stage.pickDevice;
        _error = friendlyErrorText(e,
            context: 'adopt connect',
            log: Log.adopt,
            fallback: 'Something went wrong reaching the device. Try again.');
      });
    }
  }

  Future<void> _loadNetworks() async {
    setState(() {
      _stage = _Stage.connecting;
      _busyLabel = 'Asking the device which Wi-Fi networks it can see...';
    });
    final service = ref.read(adoptServiceProvider);
    try {
      final networks = await service.listNetworks(_session!);
      if (!mounted) return;
      setState(() {
        _networks = networks;
        _stage = _Stage.pickNetwork;
        _error = _missingMetaInfoWarning();
      });
    } catch (e) {
      if (!mounted) return;
      // A failed scan is not the end: the user can still type their SSID. Land
      // on the picker with an empty list and an explanation.
      setState(() {
        _networks = const [];
        _stage = _Stage.pickNetwork;
        // Logged, not just shown: this is the one recoverable failure in the
        // flow, and recovering from it (typing an SSID) means the rest of the
        // transcript is a Wemo join with guessed auth/cipher/channel — which
        // is worth knowing when that join then does not happen.
        _error = friendlyErrorText(e,
            context: 'adopt list networks',
            log: Log.adopt,
            fallback: "The device didn't return a network list. You can type "
                'your Wi-Fi name below instead.');
      });
    }
  }

  /// The warning to show at the picker when connecting could not read the
  /// device metadata a secured join needs.
  ///
  /// Said here rather than after a password is typed and a two-minute
  /// credential sweep has run: this is the one setup exchange with no
  /// workaround, and its answer is already known by the time this screen
  /// draws. Hedged, because provisioning asks again with a retry budget and
  /// the second ask often lands — the point is that the user is not surprised
  /// by it later.
  String? _missingMetaInfoWarning() {
    final session = _session;
    if (session == null ||
        session.family != AdoptFamily.wemo ||
        session.metaInfo != null) {
      return null;
    }
    return "The device didn't answer when asked for the details needed to "
        'encrypt a Wi-Fi password. An open network will still work, and we '
        'will ask again when you pick a network — if that fails too, factory '
        'reset the device and start over.';
  }

  void _chooseNetwork(SetupNetwork network) {
    setState(() {
      _network = network;
      _passwordController.clear();
      _error = null;
      _stage = _Stage.credentials;
    });
    // An open network needs no password — provision straight away.
    if (network.isOpen) unawaited(_provision());
  }

  void _chooseTypedNetwork() {
    final ssid = _ssidController.text.trim();
    if (ssid.isEmpty) {
      setState(() => _error = 'Enter your Wi-Fi network name.');
      return;
    }
    // A typed network carries no auth/cipher/channel. For Wemo that is a real
    // gap — its ConnectHomeNetwork needs them — so a typed SSID is offered only
    // as a fallback and defaults are filled: WPA2 is what home networks run.
    Log.adopt.info('adopt: using a typed SSID "$ssid" with assumed '
        'WPA2PSK/AES and no channel — the device did not supply these, so a '
        'failed join here may simply mean the assumption is wrong');
    _chooseNetwork(SetupNetwork(
      ssid: ssid,
      joinable: true,
      isOpen: false,
      auth: 'WPA2PSK',
      encrypt: 'AES',
      channel: '',
    ));
  }

  Future<void> _provision() async {
    final network = _network!;
    final password = _passwordController.text;
    setState(() {
      _stage = _Stage.working;
      _busyLabel = 'Sending your Wi-Fi details to the device...';
      _error = null;
    });
    final service = ref.read(adoptServiceProvider);
    try {
      final outcome = await service.provision(_session!, network, password);
      if (!mounted) return;
      Log.adopt.info('adopt: provisioning finished as ${outcome.status.name}');
      setState(() {
        _outcome = outcome;
        _stage = _Stage.done;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _stage = _Stage.credentials;
        _error = friendlyErrorText(e,
            context: 'adopt provision failed',
            log: Log.adopt,
            fallback: 'Sending the settings failed. Try again.');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: scheme.surface,
      appBar: AppBar(title: const Text('Adopt a Wi-Fi device')),
      body: SafeArea(
        child: switch (_stage) {
          _Stage.pickDevice => _buildPickDevice(context),
          _Stage.connecting || _Stage.working => _buildBusy(context),
          _Stage.pickNetwork => _buildPickNetwork(context),
          _Stage.credentials => _buildCredentials(context),
          _Stage.done => _buildDone(context),
        },
      ),
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

  Widget _buildPickDevice(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final devicesAsync = ref.watch(adoptableDevicesProvider);
    // The ambient hint: when the OS can see a setup network, surface which
    // family it belongs to so the matching card can call attention to itself.
    final nearby = ref.watch(nearbySetupNetworkProvider).valueOrNull;

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 40),
      children: [
        Center(
          child: Icon(Icons.wifi_tethering, size: 56, color: scheme.secondary),
        ),
        const SizedBox(height: 24),
        Text('Put a reset device on your Wi-Fi',
            textAlign: TextAlign.center,
            style: text.headlineSmall
                ?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.4)),
        const SizedBox(height: 12),
        Text(
          'A device that has been factory reset broadcasts its own temporary '
          'Wi-Fi network. Two steps:',
          textAlign: TextAlign.center,
          style: text.bodyMedium
              ?.copyWith(color: scheme.onSurfaceVariant, height: 1.5),
        ),
        const SizedBox(height: 20),
        _instruction(context, '1',
            'Factory reset the device so it starts advertising its setup network.'),
        _instruction(
            context,
            '2',
            'Open Settings and join that network. Then come back and pick your '
                'device below.'),
        const SizedBox(height: 12),
        Center(
          child: TextButton.icon(
            onPressed: () =>
                unawaited(openAppSettings().catchError((Object _) => false)),
            icon: const Icon(Icons.settings),
            label: const Text('Open Settings'),
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          _errorBanner(context, _error!),
        ],
        const SizedBox(height: 28),
        const SectionHeader(label: 'Which device?'),
        const SizedBox(height: 12),
        devicesAsync.when(
          loading: () => const Center(
              child: Padding(
                  padding: EdgeInsets.all(24),
                  child: CircularProgressIndicator())),
          error: (e, _) =>
              _errorBanner(context, 'Could not read the device catalogue.'),
          data: (devices) {
            if (devices.isEmpty) {
              return Text(
                'No adoptable device types are in the catalogue yet.',
                style:
                    text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
              );
            }
            return Column(
              children: [
                for (final device in devices) ...[
                  _deviceCard(
                    context,
                    device,
                    isNearby:
                        nearby?.profile.ssidPrefix == device.profile.ssidPrefix,
                  ),
                  const SizedBox(height: 10),
                ],
              ],
            );
          },
        ),
        ..._bleSection(context),
      ],
    );
  }

  /// The "sets up over Bluetooth instead" section, one card per catalogue
  /// family whose provisioning conversation this app can actually drive.
  ///
  /// The whole section disappears when there is nothing to show — a heading
  /// over an empty space reads as a bug — and each card's name, icon and
  /// wording come from the spec, so a second BLE-provisioned family is a spec
  /// upstream plus one entry in [_bleSetupScreens].
  List<Widget> _bleSection(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final devices = ref.watch(bleAdoptableDevicesProvider).valueOrNull ??
        const <BleAdoptableDevice>[];
    final drivable = devices
        .where((d) => _bleSetupScreens.containsKey(d.protocolHandler))
        .toList();
    if (drivable.isEmpty) return const [];

    return [
      const SizedBox(height: 28),
      const SectionHeader(label: 'Sets up over Bluetooth instead'),
      const SizedBox(height: 12),
      for (final device in drivable) ...[
        Card(
          margin: EdgeInsets.zero,
          child: ListTile(
            leading: Icon(_iconFor(device.profile.category),
                color: scheme.secondary),
            title: Text(device.profile.specName,
                style: text.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
            subtitle: Text(
              'No setup network to join — provisioning talks to it over '
              'Bluetooth, while it advertises as '
              '"${device.profile.advertisedName}".',
              style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: _bleSetupScreens[device.protocolHandler]!,
              ),
            ),
          ),
        ),
        const SizedBox(height: 10),
      ],
    ];
  }

  Widget _deviceCard(
    BuildContext context,
    AdoptableDevice device, {
    required bool isNearby,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Card(
      margin: EdgeInsets.zero,
      color: isNearby ? scheme.secondaryContainer : null,
      child: ListTile(
        leading: Icon(_iconFor(device.profile.category),
            color: isNearby ? scheme.onSecondaryContainer : scheme.secondary),
        title: Text(device.profile.specName,
            style: text.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
        subtitle: Text(
          isNearby
              ? 'Setup network "${device.profile.ssidPrefix}…" is in range now'
              : 'Setup network starts with "${device.profile.ssidPrefix}…"',
          style: text.bodySmall?.copyWith(
            color: isNearby
                ? scheme.onSecondaryContainer
                : scheme.onSurfaceVariant,
          ),
        ),
        trailing: isNearby
            ? Icon(Icons.wifi_tethering, color: scheme.onSecondaryContainer)
            : const Icon(Icons.chevron_right),
        onTap: () => unawaited(_connect(device)),
      ),
    );
  }

  Widget _buildPickNetwork(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final joinable = _networks.where((n) => n.joinable).toList();
    final unjoinable = _networks.where((n) => !n.joinable).toList();

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 40),
      children: [
        Text('Choose your home Wi-Fi',
            style: text.headlineSmall
                ?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.4)),
        const SizedBox(height: 8),
        Text(
          'This is the network the ${_device?.profile.specName ?? 'device'} '
          'will join once setup finishes. It must be 2.4 GHz — these radios '
          'do not use 5 GHz.',
          style: text.bodyMedium
              ?.copyWith(color: scheme.onSurfaceVariant, height: 1.5),
        ),
        if (_error != null) ...[
          const SizedBox(height: 16),
          _errorBanner(context, _error!),
        ],
        const SizedBox(height: 24),
        if (joinable.isNotEmpty) ...[
          SectionHeader(
              label: 'Networks the device sees', count: joinable.length),
          const SizedBox(height: 12),
          for (final network in joinable) ...[
            _networkTile(context, network),
            const SizedBox(height: 8),
          ],
          const SizedBox(height: 16),
        ],
        const SectionHeader(label: 'Or enter it manually'),
        const SizedBox(height: 12),
        TextField(
          controller: _ssidController,
          decoration: const InputDecoration(
            labelText: 'Wi-Fi network name (SSID)',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (_) => _chooseTypedNetwork(),
        ),
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerLeft,
          child: ActionPillButton(
            icon: Icons.arrow_forward,
            label: 'Use this network',
            onPressed: _chooseTypedNetwork,
          ),
        ),
        if (unjoinable.isNotEmpty) ...[
          const SizedBox(height: 24),
          SectionHeader(label: "Can't be used", count: unjoinable.length),
          const SizedBox(height: 8),
          Text(
            'The device reported it cannot join these — usually WPA3. Switch '
            'the network to WPA2 for setup, or use a different one.',
            style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 8),
          for (final network in unjoinable)
            ListTile(
              dense: true,
              enabled: false,
              leading: const Icon(Icons.lock_outline),
              title: Text(network.ssid),
              subtitle: Text(network.auth ?? 'Unsupported security'),
            ),
        ],
      ],
    );
  }

  Widget _networkTile(BuildContext context, SetupNetwork network) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      child: ListTile(
        leading: Icon(network.isOpen ? Icons.lock_open : Icons.lock_outline,
            color: scheme.secondary),
        title: Text(network.ssid),
        subtitle: Text(_securityLabel(network)),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => _chooseNetwork(network),
      ),
    );
  }

  Widget _buildCredentials(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final network = _network!;
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 40),
      children: [
        Text('Password for "${network.ssid}"',
            style: text.headlineSmall
                ?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.4)),
        const SizedBox(height: 8),
        Text(
          'Sent to the device over its own setup network so it can join your '
          'Wi-Fi. It is not stored by this app.',
          style: text.bodyMedium
              ?.copyWith(color: scheme.onSurfaceVariant, height: 1.5),
        ),
        const SizedBox(height: 24),
        TextField(
          controller: _passwordController,
          obscureText: _obscure,
          autofocus: true,
          decoration: InputDecoration(
            labelText: 'Wi-Fi password',
            border: const OutlineInputBorder(),
            suffixIcon: IconButton(
              tooltip: _obscure ? 'Show password' : 'Hide password',
              icon: Icon(_obscure ? Icons.visibility : Icons.visibility_off),
              onPressed: () => setState(() => _obscure = !_obscure),
            ),
          ),
          onSubmitted: (_) => unawaited(_provision()),
        ),
        if (_error != null) ...[
          const SizedBox(height: 16),
          _errorBanner(context, _error!),
        ],
        const SizedBox(height: 24),
        ActionPillButton(
          icon: Icons.send,
          label: 'Send and connect',
          onPressed: () => unawaited(_provision()),
        ),
      ],
    );
  }

  Widget _buildDone(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final outcome = _outcome!;
    final good = outcome.status == AdoptStatus.joined ||
        outcome.status == AdoptStatus.sentUnconfirmed;
    return Center(
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.all(32),
        children: [
          Icon(good ? Icons.check_circle_outline : Icons.error_outline,
              size: 64, color: good ? scheme.primary : scheme.error),
          const SizedBox(height: 24),
          Text(
            switch (outcome.status) {
              AdoptStatus.joined => 'Connected',
              AdoptStatus.sentUnconfirmed => 'Details sent',
              AdoptStatus.rejected => 'Password rejected',
              AdoptStatus.unreachable => 'Device not reachable',
            },
            textAlign: TextAlign.center,
            style: text.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 12),
          Text(outcome.message,
              textAlign: TextAlign.center,
              style: text.bodyMedium
                  ?.copyWith(color: scheme.onSurfaceVariant, height: 1.5)),
          const SizedBox(height: 28),
          if (good)
            Center(
              child: ActionPillButton(
                icon: Icons.done,
                label: 'Finish',
                onPressed: () => Navigator.of(context).pop(),
              ),
            )
          else
            Center(
              child: ActionPillButton(
                icon: Icons.refresh,
                label: 'Try again',
                onPressed: () => setState(() {
                  _stage = _Stage.credentials;
                  _error = null;
                }),
              ),
            ),
        ],
      ),
    );
  }

  Widget _instruction(BuildContext context, String number, String body) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 14,
            backgroundColor: scheme.secondaryContainer,
            child: Text(number,
                style: text.labelLarge?.copyWith(
                    color: scheme.onSecondaryContainer,
                    fontWeight: FontWeight.w700)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(body, style: text.bodyMedium?.copyWith(height: 1.5)),
          ),
        ],
      ),
    );
  }

  Widget _errorBanner(BuildContext context, String message) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline, color: scheme.onErrorContainer, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(message,
                style: TextStyle(color: scheme.onErrorContainer, height: 1.4)),
          ),
        ],
      ),
    );
  }

  static String _securityLabel(SetupNetwork network) {
    if (network.isOpen) return 'Open — no password';
    // Wemo carries an auth string; LIFX carries only a security byte, which
    // reads as a secured network without a finer label.
    return network.auth ?? 'Secured';
  }

  static IconData _iconFor(String? category) => switch (category) {
        'light' => Icons.lightbulb_outline,
        'switch' => Icons.toggle_on_outlined,
        'appliance' => Icons.kitchen_outlined,
        _ => Icons.wifi,
      };
}
