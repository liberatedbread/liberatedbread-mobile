// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/error_text.dart';
import '../providers/ha_provider.dart' show urlOpenerProvider;
import '../providers/roomba_provider.dart';
import '../services/ha_api_client.dart';
import '../services/ha_roomba_client.dart';
import '../services/rest980_client.dart';
import '../services/roomba_credential_store.dart';

/// Home Assistant's own docs for the integration that owns the robot.
final _haRoomba = Uri.parse(
  'https://www.home-assistant.io/integrations/roomba/',
);
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
  /// two need a password this app does not have. The same holds for a robot
  /// adopted through Home Assistant, whose credentials carry no password.
  final RoombaCredentials? credentials;

  const RoombaTransportScreen({super.key, this.credentials});

  @override
  ConsumerState<RoombaTransportScreen> createState() =>
      _RoombaTransportScreenState();
}

class _RoombaTransportScreenState extends ConsumerState<RoombaTransportScreen> {
  final _rest980Controller = TextEditingController();

  List<HaEntityState>? _vacuums;
  String? _error;
  bool _busy = false;

  /// Whether the direct and rest980 paths can be offered. Keyed on a stored
  /// password, not on credentials being passed: a robot adopted through Home
  /// Assistant arrives with credentials and an EMPTY password, and choosing
  /// either path cleared its HA entity — leaving the store with nothing
  /// usable, so the robot silently fell back to un-adopted.
  bool get _hasPassword => widget.credentials?.password.isNotEmpty ?? false;

  @override
  void initState() {
    super.initState();
    _rest980Controller.text = widget.credentials?.rest980BaseUrl ?? '';
    // Listened, not read once: the HA config is an AsyncNotifier nothing
    // warms at startup, so on a cold open the client is still null here.
    // A one-shot read returned early and, when the config landed a frame
    // later, the recommended card flipped to "connected" with no robots, no
    // spinner and no way to load them. Reload on ANY client change too, so
    // an edited HA address does not leave the old list up.
    ref.listenManual<HaRoombaClient?>(haRoombaClientProvider, (prev, next) {
      // A microtask, not a direct call: with fireImmediately this runs inside
      // initState, where the load's setState is not allowed yet.
      if (next != null && !identical(prev, next)) {
        unawaited(Future.microtask(_loadVacuums));
      }
    }, fireImmediately: true);
  }

  @override
  void dispose() {
    _rest980Controller.dispose();
    super.dispose();
  }

  /// Watched, not read: the HA client resolves from stored config that can
  /// land after the first build, and a `ref.read` here left the screen
  /// showing "not connected" until something else happened to rebuild it.
  bool get _haConnected => ref.watch(haRoombaClientProvider) != null;

  /// Bumped per load, so a slow answer from a client that has since been
  /// replaced cannot overwrite the newer one's list.
  int _loadGeneration = 0;

  Future<void> _loadVacuums() async {
    if (!mounted) return;
    final client = ref.read(haRoombaClientProvider);
    if (client == null) return;
    final generation = ++_loadGeneration;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final vacuums = await client.vacuums();
      if (generation != _loadGeneration) return;
      if (mounted) setState(() => _vacuums = vacuums);
    } catch (e) {
      if (generation != _loadGeneration) return;
      if (mounted) {
        setState(
          () => _error = friendlyErrorText(
            e,
            context: 'home assistant',
            fallback: 'Could not read the robot list from Home Assistant.',
          ),
        );
      }
    } finally {
      if (generation == _loadGeneration && mounted) {
        setState(() => _busy = false);
      }
    }
  }

  /// Store a routing choice and leave, in the same shape as [_saveRest980]:
  /// busy while the keychain writes run, so a second tap in that window
  /// cannot run the writes again and pop the route UNDERNEATH this one; and
  /// a refused write lands in the error card instead of escaping the tap as
  /// an unhandled error with the screen sitting there unchanged.
  Future<void> _storeChoice(
    Future<void> Function(RoombaCredentialStore store) write,
    Object? popResult,
  ) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await write(ref.read(roombaCredentialStoreProvider));
      if (mounted) Navigator.of(context).pop(popResult);
    } catch (e) {
      if (mounted) {
        setState(
          () => _error = friendlyErrorText(
            e,
            context: 'keychain',
            fallback: 'Could not save this choice.',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _chooseHa(HaEntityState entity) async {
    final credentials = widget.credentials;
    if (credentials == null) {
      // Adding a robot: nothing to store, the wizard takes the entity.
      Navigator.of(context).pop(entity);
      return;
    }
    await _storeChoice((store) async {
      await store.setHaEntityId(credentials.blid, entity.entityId);
      // Clear the other transport, like its two siblings do. Leaving a stale
      // rest980 address behind means two are configured at once — harmless
      // only because the factory happens to prefer HA, which is a coincidence
      // this screen should not depend on.
      await store.setRest980BaseUrl(credentials.blid, null);
    }, entity);
  }

  Future<void> _saveRest980() async {
    final credentials = widget.credentials;
    if (credentials == null || !_hasPassword) return;
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
        setState(
          () => _error = friendlyErrorText(
            e,
            context: 'rest980',
            fallback: 'That address did not answer as a rest980 server.',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _chooseDirect() async {
    final credentials = widget.credentials;
    if (credentials == null || !_hasPassword) return;
    await _storeChoice((store) async {
      await store.setHaEntityId(credentials.blid, null);
      await store.setRest980BaseUrl(credentials.blid, null);
    }, null);
  }

  @override
  Widget build(BuildContext context) {
    final open = ref.read(urlOpenerProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('How to reach this robot')),
      // Landscape is declared for iPhone; an explicitly-padded ListView ignores
      // MediaQuery.padding, so without this the cards' edge sat under the
      // notch / Dynamic Island and the last one under the home indicator.
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (_error != null) ...[
              _ErrorCard(message: _error!),
              const SizedBox(height: 16),
            ],
            _haSection(context, open),
            if (_hasPassword) ...[
              const SizedBox(height: 24),
              _directSection(context),
              const SizedBox(height: 24),
              _rest980Section(context, open),
            ],
          ],
        ),
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
                Icon(
                  Icons.home_outlined,
                  color: theme.colorScheme.onPrimaryContainer,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Home Assistant — recommended',
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: theme.colorScheme.onPrimaryContainer,
                    ),
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
            else if (_vacuums == null)
              // The load failed (the error card says why) or has not run:
              // never an empty card with nothing to press.
              TextButton(
                onPressed: _busy ? null : () => unawaited(_loadVacuums()),
                child: const Text('Try again'),
              )
            else if (_vacuums!.isEmpty)
              Text(
                'Home Assistant is connected, but reports no vacuums. Add the '
                'Roomba integration there first.',
                style: TextStyle(color: theme.colorScheme.onPrimaryContainer),
              )
            else
              for (final vacuum in _vacuums!)
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
    final direct =
        !(widget.credentials?.usesHomeAssistant ?? false) &&
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
    BuildContext context,
    Future<bool> Function(Uri) open,
  ) {
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
        child: Text(
          message,
          style: TextStyle(color: theme.colorScheme.onErrorContainer),
        ),
      ),
    );
  }
}
