// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/error_text.dart';
import '../models/network_device.dart';
import '../providers/hub_control_provider.dart';
import '../providers/network_control_provider.dart';
import '../providers/spec_codec_provider.dart';
import '../services/hub_credential_store.dart';
import '../services/hub_http_client.dart';
import '../services/spec_codec.dart';
import '../widgets/hub_child_light_card.dart';
import '../widgets/hub_pairing_sheet.dart';

/// Controls for a hub — a device that fronts a population of children the
/// spec cannot enumerate. The Hue Bridge is the first one.
///
/// The flow, each step owned by the layer that knows it:
/// 1. establish the bridge's identity (bridgeid, from the mDNS TXT record or
///    the unauthenticated config probe) and whether we are paired with it;
/// 2. unpaired: one card, one button, the link-button sheet — pairing is the
///    entire setup, no account anywhere;
/// 3. paired: ONE state GET per instanced entity enumerates every child and
///    carries all their state (the spec's `instances:` shape — per-child
///    polling is how a client gets throttled), then a card per light;
/// 4. every write is followed by one re-read, because a v1 write's reply
///    acknowledges the request rather than reporting the resulting state.
///
/// Error type 1 (the stored username no longer exists on the bridge — a
/// factory reset, or a pruned whitelist) flips the screen back to unpaired
/// with its reason stated, and re-pairing overwrites the stale credential.
class HubDeviceScreen extends ConsumerStatefulWidget {
  final NetworkDevice device;
  final NetworkControls controls;

  const HubDeviceScreen({
    super.key,
    required this.device,
    required this.controls,
  });

  @override
  ConsumerState<HubDeviceScreen> createState() => _HubDeviceScreenState();
}

class _HubDeviceScreenState extends ConsumerState<HubDeviceScreen> {
  String? _bridgeId;
  HubCredentials? _credentials;

  /// Raw state replies per state_command — handed back to the codec, which
  /// is the only layer that parses them.
  final Map<String, String> _stateBodies = {};

  /// Children per instanced entity name, in the hub's own order.
  final Map<String, List<NetworkInstanceDto>> _childrenByEntity = {};

  /// role → reading, keyed by "entity/childId".
  final Map<String, Map<String, NetworkReadingDto>> _readings = {};

  /// "entity/childId" a send is in flight for, disabling that child's card.
  String? _sending;
  bool _loading = true;
  String? _error;

  /// Why the screen is showing the pairing card for a bridge that was paired
  /// a moment ago (error type 1), so the user knows this is not a bug.
  String? _authNote;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  List<NetworkEntityDto> get _instancedEntities =>
      widget.controls.entities.where((e) => e.isInstanced).toList();

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final bridgeId = _bridgeId ??= await _resolveBridgeId();
      _credentials =
          await ref.read(hubCredentialStoreProvider).credentials(bridgeId);
      if (_credentials != null) {
        await _refreshState();
      }
      if (mounted) setState(() => _loading = false);
    } on HubAuthException {
      // The stored username no longer exists on the bridge — a factory reset
      // or a pruned whitelist. This can surface on the very first load (or a
      // refresh), not only mid-session, so it must flip to pairing here too:
      // without this clause the screen would sit paired-but-empty behind a
      // "try scanning again" banner that a re-scan cannot fix.
      if (!mounted) return;
      setState(() {
        _loading = false;
        _credentials = null;
        _authNote = 'The bridge no longer recognizes this app — its '
            'whitelist entry is gone (a factory reset does that). '
            'Pair again to continue.';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = friendlyErrorText(
          e,
          context: 'hub control',
          fallback: e is HubTlsException
              ? 'The bridge failed its security check: it presented a '
                  'different certificate than the one this app pinned. If '
                  'you replaced the bridge, forget it below and pair again.'
              : 'Could not reach the bridge. It may have a new address — '
                  'try scanning again.',
        );
      });
    }
  }

  /// The bridge's stable identity. mDNS TXT carries it outright; an
  /// SSDP-only sighting asks the bridge itself, cross-checking the answer
  /// against the certificate CN observed while fetching it.
  Future<String> _resolveBridgeId() async {
    final advertised = widget.device.txt['bridgeid'];
    if (advertised != null && advertised.length == 16) {
      return advertised.toUpperCase();
    }
    final probe =
        await ref.read(hubHttpClientProvider).fetchConfig(widget.device.host);
    final claimed = _bridgeIdFromConfig(probe.body);
    if (claimed == null) {
      throw HubTransportException(
          'the device did not identify itself as a bridge');
    }
    final seenCn = probe.observedCn;
    if (seenCn != null && seenCn.toUpperCase() != claimed) {
      throw HubTlsException(
          'the bridge claims id $claimed but its certificate says $seenCn');
    }
    return claimed;
  }

  static String? _bridgeIdFromConfig(String body) {
    try {
      final parsed = jsonDecode(body);
      if (parsed is Map<String, dynamic>) {
        final id = parsed['bridgeid'];
        if (id is String && id.length == 16) return id.toUpperCase();
      }
    } on FormatException {
      // Fall through: not a config document.
    }
    return null;
  }

  /// One GET per instanced entity's state command, then enumerate and read
  /// every child from that single reply.
  Future<void> _refreshState() async {
    final codec = ref.read(specCodecProvider);
    final client = ref.read(hubHttpClientProvider);
    final bridgeId = _bridgeId!;
    final credentials = _credentials!;

    for (final entity in _instancedEntities) {
      final request = await codec.renderNetworkHttpStateRequest(
        specYaml: widget.controls.specYaml,
        stateCommand: entity.stateCommand,
        values: _credentialValues(entity.actions, credentials),
      );
      final body = await client.send(widget.device.host, bridgeId, request);
      _stateBodies[entity.stateCommand] = body;

      final children = await codec.listNetworkInstances(
        specYaml: widget.controls.specYaml,
        entityName: entity.name,
        stateReply: body,
      );
      _childrenByEntity[entity.name] = children;
      for (final child in children) {
        final readings = await codec.readNetworkInstance(
          specYaml: widget.controls.specYaml,
          entityName: entity.name,
          stateReply: body,
          instanceId: child.id,
        );
        _readings['${entity.name}/${child.id}'] = {
          for (final reading in readings) reading.role: reading.reading,
        };
      }
    }
    if (mounted) setState(() {});
  }

  /// The credential values an action's `credentials` list names, resolved
  /// from the pairing store's fields. Only `username` exists today; an
  /// unknown name fails the send visibly, which is the spec's own rule for
  /// a `source` nothing can fill.
  Map<String, String> _credentialValues(
    List<NetworkActionDto> actions,
    HubCredentials credentials,
  ) {
    final values = <String, String>{};
    for (final action in actions) {
      for (final credential in action.credentials) {
        final value = switch (credential.name) {
          'username' => credentials.username,
          'clientkey' => credentials.clientKey,
          _ => null,
        };
        if (value != null) values[credential.param] = value;
      }
    }
    return values;
  }

  Future<void> _send(
    NetworkEntityDto entity,
    NetworkInstanceDto child,
    NetworkActionDto action, {
    String? value,
  }) async {
    final key = '${entity.name}/${child.id}';
    setState(() {
      _sending = key;
      _error = null;
    });
    try {
      final codec = ref.read(specCodecProvider);
      final client = ref.read(hubHttpClientProvider);
      final credentials = _credentials!;

      final values = <String, String>{
        ..._credentialValues([action], credentials),
        for (final instanceParam in action.instanceParams)
          instanceParam.param: child.id,
      };
      if (value != null && action.userParams.isNotEmpty) {
        values[action.userParams.first] = value;
      }

      final request = await codec.renderNetworkHttpCommand(
        specYaml: widget.controls.specYaml,
        commandName: action.commandName,
        values: values,
      );
      await client.send(widget.device.host, _bridgeId!, request);
      // The reply acknowledges the request; state comes from re-reading the
      // one enumerating GET.
      await _refreshState();
    } on HubAuthException {
      if (!mounted) return;
      setState(() {
        _credentials = null;
        _authNote = 'The bridge no longer recognizes this app — its '
            'whitelist entry is gone (a factory reset does that). '
            'Pair again to continue.';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = friendlyErrorText(
          e,
          context: 'hub control',
          fallback: 'The bridge did not accept that. Try again.',
        );
      });
    } finally {
      if (mounted) setState(() => _sending = null);
    }
  }

  Future<void> _pair() async {
    final bridgeId = _bridgeId;
    if (bridgeId == null) return;
    final result = await HubPairingSheet.show(
      context,
      specYaml: widget.controls.specYaml,
      host: widget.device.host,
      bridgeId: bridgeId,
    );
    if (result == null || !mounted) return;
    final credentials = HubCredentials(
      username: result.username,
      clientKey: result.clientKey,
    );
    await ref
        .read(hubCredentialStoreProvider)
        .saveCredentials(bridgeId, credentials);
    ref.invalidate(hubCredentialsProvider(bridgeId));
    if (!mounted) return;
    setState(() {
      _credentials = credentials;
      _authNote = null;
    });
    await _loadSafely();
  }

  Future<void> _forget() async {
    final bridgeId = _bridgeId;
    if (bridgeId == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Forget this bridge?'),
        content: const Text(
            'Removes the stored pairing, certificate pin and settings from '
            'this app. The bridge itself keeps its whitelist entry; pairing '
            'again mints a new one.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Forget'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await ref.read(hubCredentialStoreProvider).forget(bridgeId);
    ref.invalidate(hubCredentialsProvider(bridgeId));
    if (!mounted) return;
    setState(() {
      _credentials = null;
      _authNote = null;
      _childrenByEntity.clear();
      _readings.clear();
    });
  }

  Future<void> _loadSafely() async {
    try {
      setState(() => _loading = true);
      await _refreshState();
    } on HubAuthException {
      _credentials = null;
      _authNote = 'The bridge no longer recognizes this app. Pair again.';
    } catch (e) {
      _error = friendlyErrorText(
        e,
        context: 'hub control',
        fallback: 'Could not read the lights. Pull refresh to retry.',
      );
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  NetworkActionDto? _actionFor(NetworkEntityDto entity, String role) {
    for (final action in entity.actions) {
      if (action.role == role) return action;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final paired = _credentials != null;

    return Scaffold(
      backgroundColor: scheme.surface,
      appBar: AppBar(
        title: Text(widget.device.displayName),
        actions: [
          if (paired)
            IconButton(
              tooltip: 'Refresh',
              onPressed: _loading ? null : () => unawaited(_load()),
              icon: const Icon(Icons.refresh),
            ),
          PopupMenuButton<String>(
            onSelected: (choice) {
              if (choice == 'forget') unawaited(_forget());
            },
            itemBuilder: (_) => [
              const PopupMenuItem(
                value: 'forget',
                child: Text('Forget this bridge'),
              ),
            ],
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 40),
          children: [
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Text(
                  _error!,
                  style: text.bodyMedium?.copyWith(color: scheme.error),
                ),
              ),
            if (_loading) ...[
              const SizedBox(height: 48),
              const Center(child: CircularProgressIndicator()),
              const SizedBox(height: 16),
              Center(
                child: Text('Asking the bridge...',
                    style: text.bodyMedium
                        ?.copyWith(color: scheme.onSurfaceVariant)),
              ),
            ] else if (!paired) ...[
              _pairingCard(),
            ] else ...[
              for (final entity in _instancedEntities) ...[
                for (final child in _childrenByEntity[entity.name] ??
                    const <NetworkInstanceDto>[]) ...[
                  _childCard(entity, child),
                  const SizedBox(height: 12),
                ],
                if ((_childrenByEntity[entity.name] ?? const []).isEmpty)
                  _emptyCard(entity),
              ],
              const SizedBox(height: 16),
              _bridgeInfo(),
            ],
          ],
        ),
      ),
    );
  }

  Widget _pairingCard() {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.hub_outlined, color: scheme.primary),
                const SizedBox(width: 12),
                Expanded(
                  child: Text('Not paired yet',
                      style: text.titleMedium
                          ?.copyWith(fontWeight: FontWeight.w600)),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              _authNote ??
                  'This bridge controls its lights locally. Pairing is one '
                      'press of its link button — no account, and it keeps '
                      'working if the vendor cloud goes away.',
              style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _bridgeId == null ? null : () => unawaited(_pair()),
              icon: const Icon(Icons.link),
              label: const Text('Pair with bridge'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _childCard(NetworkEntityDto entity, NetworkInstanceDto child) {
    final readings = _readings['${entity.name}/${child.id}'] ?? const {};
    final isOn = readings['is_on']?.isOn;
    final brightness = readings['brightness']?.number;
    final turnOn = _actionFor(entity, 'turn_on');
    final turnOff = _actionFor(entity, 'turn_off');
    final setBrightness = _actionFor(entity, 'set_brightness');
    final busy = _sending == '${entity.name}/${child.id}';

    return HubChildLightCard(
      label: child.label,
      isOn: isOn,
      brightness: brightness,
      brightnessMin: setBrightness?.min ?? 1,
      brightnessMax: setBrightness?.max ?? 254,
      busy: busy,
      onToggle: (turnOn == null || turnOff == null)
          ? null
          : (wantOn) =>
              unawaited(_send(entity, child, wantOn ? turnOn : turnOff)),
      onBrightness: setBrightness == null
          ? null
          : (value) => unawaited(_send(entity, child, setBrightness,
              value: value.round().toString())),
    );
  }

  Widget _emptyCard(NetworkEntityDto entity) {
    final text = Theme.of(context).textTheme;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Text(
          'The bridge lists no ${entity.name.toLowerCase()}s yet. Lights '
          'joined to it appear here.',
          style: text.bodyMedium,
        ),
      ),
    );
  }

  Widget _bridgeInfo() {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final rows = <(String, String)>[
      ('Address', widget.device.host),
      if (_bridgeId != null) ('Bridge ID', _bridgeId!),
      ('Pairing', 'Stored on this phone, keyed by bridge ID'),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final (label, value) in rows)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 90,
                  child: Text(label,
                      style: text.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                          fontWeight: FontWeight.w600)),
                ),
                Expanded(child: SelectableText(value, style: text.bodySmall)),
              ],
            ),
          ),
      ],
    );
  }
}
