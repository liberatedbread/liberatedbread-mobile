// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/error_text.dart';
import '../providers/ha_provider.dart' show urlOpenerProvider;
import '../providers/roomba_provider.dart';
import '../services/ha_api_client.dart';
import '../services/rest980_client.dart';
import '../services/roomba_credential_store.dart';

/// Home Assistant's own docs for the integration that owns the robot.
final _haRoomba =
    Uri.parse('https://www.home-assistant.io/integrations/roomba/');
final _rest980 = Uri.parse('https://github.com/koalazak/rest980');

/// How this robot should be driven: through Home Assistant, through a rest980
/// server, or straight at it.
///
/// # Why this is one screen and not three settings
///
/// All three exist to answer the SAME question, and the robot makes it a real
/// question: it serves one local client at a time, and a new connection evicts
/// the old. Whatever holds that slot should be the only thing holding it. Three
/// separate address fields scattered across the app would let someone
/// configure two at once and then wonder why their iRobot app keeps logging
/// out.
///
/// Home Assistant is listed first, and recommended, whenever it is connected.
/// Not a preference: if HA is in the house it is ALREADY talking to the robot,
/// so the app either asks HA or fights it. Asking is strictly better — and it
/// is the only option that works at all for a robot on a network segment the
/// phone cannot reach, which is where anyone who followed the firewall guide
/// ends up.
class RoombaTransportScreen extends ConsumerStatefulWidget {
  /// The robot being configured. Null when this screen is being used to ADD a
  /// robot from Home Assistant's list rather than to re-point a known one — in
  /// which case only the Home Assistant section makes sense, because the other
  /// two need a password this app does not have.
  final RoombaCredentials? credentials;

  /// Called with the chosen Home Assistant entity, once stored.
  final void Function(HaEntityState entity)? onHaEntityChosen;

  const RoombaTransportScreen({
    super.key,
    this.credentials,
    this.onHaEntityChosen,
  });

  @override
  ConsumerState<RoombaTransportScreen> createState() =>
      _RoombaTransportScreenState();
}

class _RoombaTransportScreenState extends ConsumerState<RoombaTransportScreen> {
  final _rest980Controller = TextEditingController();

  List<HaEntityState>? _vacuums;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _rest980Controller.text = widget.credentials?.rest980BaseUrl ?? '';
    unawaited(_loadVacuums());
  }

  @override
  void dispose() {
    _rest980Controller.dispose();
    super.dispose();
  }

  bool get _haConnected => ref.read(haRoombaClientProvider) != null;

  Future<void> _loadVacuums() async {
    final client = ref.read(haRoombaClientProvider);
    if (client == null) return;
    setState(() => _busy = true);
    try {
      final vacuums = await client.vacuums();
      if (mounted) setState(() => _vacuums = vacuums);
    } catch (e) {
      if (mounted) {
        setState(() => _error = friendlyErrorText(
              e,
              context: 'home assistant',
              fallback: 'Could not read the robot list from Home Assistant.',
            ));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _chooseHa(HaEntityState entity) async {
    final credentials = widget.credentials;
    if (credentials != null) {
      await ref
          .read(roombaCredentialStoreProvider)
          .setHaEntityId(credentials.blid, entity.entityId);
    }
    widget.onHaEntityChosen?.call(entity);
    if (mounted) Navigator.of(context).pop(entity);
  }

  Future<void> _saveRest980() async {
    final credentials = widget.credentials;
    if (credentials == null) return;
    final url = Rest980Client.normalizeBaseUrl(_rest980Controller.text);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      // Probed before it is stored, so a URL that saves is a URL that works.
      // A typo here otherwise surfaces much later as a robot that will not
      // respond, which reads like a broken robot rather than a wrong address.
      await ref.read(rest980ClientProvider).state(url);
      final store = ref.read(roombaCredentialStoreProvider);
      await store.setRest980BaseUrl(credentials.blid, url);
      await store.setHaEntityId(credentials.blid, null);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        setState(() => _error = friendlyErrorText(
              e,
              context: 'rest980',
              fallback: 'That address did not answer as a rest980 server.',
            ));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _chooseDirect() async {
    final credentials = widget.credentials;
    if (credentials == null) return;
    final store = ref.read(roombaCredentialStoreProvider);
    await store.setHaEntityId(credentials.blid, null);
    await store.setRest980BaseUrl(credentials.blid, null);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final open = ref.read(urlOpenerProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('How to reach this robot')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_error != null) ...[
            _ErrorCard(message: _error!),
            const SizedBox(height: 16),
          ],
          _haSection(context, open),
          if (widget.credentials != null) ...[
            const SizedBox(height: 24),
            _directSection(context),
            const SizedBox(height: 24),
            _rest980Section(context, open),
          ],
        ],
      ),
    );
  }

  Widget _haSection(BuildContext context, Future<bool> Function(Uri) open) {
    final theme = Theme.of(context);
    return Card(
      // Visually first AND visually different: this is the recommendation, not
      // one of three equal options.
      color: theme.colorScheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.home_outlined,
                    color: theme.colorScheme.onPrimaryContainer),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Home Assistant — recommended',
                    style: theme.textTheme.titleMedium
                        ?.copyWith(color: theme.colorScheme.onPrimaryContainer),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'The robot accepts one local connection at a time, and a new one '
              'evicts the old. If Home Assistant is already talking to it, '
              'anything else — this app, your iRobot app — takes turns being '
              'locked out. Letting Home Assistant hold the robot and asking it '
              'instead is the way out. It also works when the robot is on a '
              'network this phone cannot reach.',
              style: TextStyle(color: theme.colorScheme.onPrimaryContainer),
            ),
            const SizedBox(height: 12),
            if (!_haConnected)
              Text(
                'Home Assistant is not connected in this app yet. Connect it '
                'in Settings, then come back — your robot\'s password stays '
                'with Home Assistant and never needs to be here at all.',
                style: TextStyle(color: theme.colorScheme.onPrimaryContainer),
              )
            else if (_busy && _vacuums == null)
              const LinearProgressIndicator()
            else if (_vacuums != null && _vacuums!.isEmpty)
              Text(
                'Home Assistant is connected, but reports no vacuums. Add the '
                'Roomba integration there first.',
                style: TextStyle(color: theme.colorScheme.onPrimaryContainer),
              )
            else
              for (final vacuum in _vacuums ?? const <HaEntityState>[])
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(vacuum.friendlyName),
                  subtitle: Text(vacuum.entityId),
                  trailing: widget.credentials?.haEntityId == vacuum.entityId
                      ? const Icon(Icons.check)
                      : null,
                  onTap: _busy ? null : () => _chooseHa(vacuum),
                ),
            const SizedBox(height: 4),
            TextButton(
              onPressed: () => open(_haRoomba),
              child: const Text('Home Assistant\'s Roomba integration'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _directSection(BuildContext context) {
    final theme = Theme.of(context);
    final direct = !(widget.credentials?.usesHomeAssistant ?? false) &&
        !(widget.credentials?.usesRest980 ?? false);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Straight at the robot', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            const Text(
              'This app talks the robot\'s own protocol, using the password '
              'you adopted it with. Nothing else can hold the robot while it '
              'does. Fine when this app is the only thing driving it.',
            ),
            const SizedBox(height: 12),
            if (direct)
              const Text('Currently in use.')
            else
              FilledButton.tonal(
                onPressed: _busy ? null : _chooseDirect,
                child: const Text('Use the direct connection'),
              ),
          ],
        ),
      ),
    );
  }

  Widget _rest980Section(
      BuildContext context, Future<bool> Function(Uri) open) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('A rest980 server', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            const Text(
              'rest980 is koalazak\'s own HTTP wrapper around dorita980 — the '
              'same author as the protocol. It holds the robot and answers '
              'plain HTTP, so it solves the one-client problem the same way '
              'Home Assistant does. It is also the answer for older firmware '
              'this phone\'s TLS cannot negotiate at all: Node can use the old '
              'cipher, a phone cannot.',
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _rest980Controller,
              enabled: !_busy,
              autocorrect: false,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                labelText: 'rest980 address',
                hintText: 'http://pi.local:3000',
                border: OutlineInputBorder(),
                helperText: 'Checked before it is saved.',
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              children: [
                FilledButton.tonal(
                  onPressed: _busy ? null : _saveRest980,
                  child: const Text('Use this server'),
                ),
                TextButton(
                  onPressed: () => open(_rest980),
                  child: const Text('rest980'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorCard extends StatelessWidget {
  final String message;
  const _ErrorCard({required this.message});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      color: theme.colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Text(message,
            style: TextStyle(color: theme.colorScheme.onErrorContainer)),
      ),
    );
  }
}
