// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/error_text.dart';
import 'roomba_transport_screen.dart';
import '../providers/ha_provider.dart' show urlOpenerProvider;
import '../providers/roomba_provider.dart';
import '../services/ha_api_client.dart';
import '../services/irobot_cloud_service.dart';
import '../services/roomba_control_service.dart';
import '../services/roomba_credential_store.dart';

/// Where dorita980 lives. Shown, and tappable, on every step — the protocol
/// below is entirely koalazak's work and the app says so rather than
/// implying otherwise by silence.
final _dorita980 = Uri.parse('https://github.com/koalazak/dorita980');
final _rest980 = Uri.parse('https://github.com/koalazak/rest980');

/// Which way the owner is getting the robot's password.
enum _Route { chooser, button, account, paste }

/// Adopting a Roomba: get its password, show it to the owner, keep it.
///
/// The robot already speaks a complete local protocol; the only thing standing
/// between an owner and it is a credential the robot will hand over if you ask
/// correctly. This screen is that asking, in the three forms it takes.
///
/// The credential reveal at the end is not a confirmation dialog — it is the
/// point. The password changes only on a factory reset, and it is the same
/// pair Home Assistant, dorita980 and every other local client will want. An
/// owner who screenshots it there never has to do this again, on any device.
class RoombaAdoptionScreen extends ConsumerStatefulWidget {
  /// The robot's stable identity, from the discovery announcement.
  final String blid;

  /// Where it answered. A DHCP lease, so it is remembered as a convenience and
  /// never as identity.
  final String host;

  /// The owner's name for it, when discovery carried one.
  final String? robotName;

  /// Model code, when discovery carried one.
  final String? sku;

  /// How many times to ask the robot inside one disclosure window. Real
  /// callers keep the service default, which retries because j-series firmware
  /// drops the first connection or two; tests shrink it so a failure path does
  /// not spend the retry interval four times over.
  final int passwordAttempts;

  const RoombaAdoptionScreen({
    super.key,
    required this.blid,
    required this.host,
    this.robotName,
    this.sku,
    this.passwordAttempts = RoombaPasswordService.defaultAttempts,
  });

  @override
  ConsumerState<RoombaAdoptionScreen> createState() =>
      _RoombaAdoptionScreenState();
}

class _RoombaAdoptionScreenState extends ConsumerState<RoombaAdoptionScreen> {
  _Route _route = _Route.chooser;
  bool _busy = false;
  String? _error;

  /// True when the failure was the TLS cipher gap. Held separately from
  /// [_error] because it changes what to offer next: retrying cannot help, and
  /// the honest advice is a different tool or a rest980 server.
  bool _legacyTls = false;

  int _attempt = 0;

  /// Non-null once a password is in hand. Rendering the reveal is the whole
  /// end state of this screen.
  RoombaCredentials? _revealed;

  final _emailController = TextEditingController();
  final _accountPasswordController = TextEditingController();
  final _blidController = TextEditingController();
  final _passwordController = TextEditingController();

  /// The iRobot region to sign in against.
  ///
  /// iRobot runs several, and the wrong one answers with an empty robot list
  /// rather than an error — so a hardcoded default strands everyone outside it
  /// with a screen that says the account has no robots. Prefilled from the
  /// device locale and editable, because the phone's country and the account's
  /// are not always the same: someone can move, or hold an account opened
  /// elsewhere, and only they know which it is.
  final _countryController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _blidController.text = widget.blid;
    _countryController.text = _localeCountry();
  }

  /// The device's country, upper-cased, falling back to `US` — the same
  /// default the service carried before this field existed, so a locale that
  /// names no country behaves exactly as it used to.
  String _localeCountry() {
    final country = PlatformDispatcher.instance.locale.countryCode;
    return (country == null || country.isEmpty) ? 'US' : country.toUpperCase();
  }

  @override
  void dispose() {
    _countryController.dispose();
    _emailController.dispose();
    // The account password never leaves this widget; clearing it on the way
    // out means it is not sitting in a controller for the rest of the session.
    _accountPasswordController
      ..clear()
      ..dispose();
    _blidController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final revealed = _revealed;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.robotName ?? 'Adopt this Roomba'),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (revealed != null)
              _CredentialReveal(
                credentials: revealed,
                host: widget.host,
                onDone: () => Navigator.of(context).pop(revealed),
              )
            else ...[
              _header(context),
              const SizedBox(height: 16),
              if (_error != null) ...[
                _ErrorPanel(
                  message: _error!,
                  legacyTls: _legacyTls,
                  onOpen: _open,
                  onChooseTransport: _openTransportChooser,
                ),
                const SizedBox(height: 16),
              ],
              switch (_route) {
                _Route.chooser => _chooser(context),
                _Route.button => _buttonRoute(context),
                _Route.account => _accountRoute(context),
                _Route.paste => _pasteRoute(context),
              },
            ],
            const SizedBox(height: 24),
            _CreditLine(onOpen: _open),
          ],
        ),
      ),
    );
  }

  Widget _header(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'This robot already speaks a local protocol',
          style: theme.textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        Text(
          'It runs its own MQTT broker on ${widget.host}. To use it you need '
          'two values from the robot: its BLID and a password. The password '
          'only changes if the robot is factory reset, so this is a one-time '
          'job.',
          style: theme.textTheme.bodyMedium,
        ),
      ],
    );
  }

  Widget _chooser(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FilledButton.icon(
            onPressed: () => setState(() => _route = _Route.button),
            icon: const Icon(Icons.touch_app),
            label: const Text('Hold the HOME button'),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Text(
              'Works offline, needs no iRobot account. Try this first.',
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: () => setState(() => _route = _Route.account),
            icon: const Icon(Icons.cloud_outlined),
            label: const Text('Sign in to iRobot once'),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Text(
              'Reads the same two values from your account. Used once, then '
              'never again — and it stops working once you firewall the robot, '
              'so do it before that.',
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(height: 8),
          TextButton(
            onPressed: () => setState(() => _route = _Route.paste),
            child: const Text('I already have the BLID and password'),
          ),
        ],
      );

  // ── Route 1: the HOME button ───────────────────────────────────────────────

  Widget _buttonRoute(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Do this in order', style: theme.textTheme.titleMedium),
        const SizedBox(height: 12),
        const _Step(
          number: 1,
          text: 'Put the robot on its dock, powered on.',
        ),
        const _Step(
          number: 2,
          text: 'Close the iRobot app on every phone in the house. The robot '
              'only talks to one thing at a time, and the app will hold the '
              'slot.',
        ),
        const _Step(
          number: 3,
          text: 'Hold HOME for about two seconds, until the robot plays a '
              'series of tones. Release it.',
        ),
        const _Step(
          number: 4,
          text: 'Tap below straight away — the robot only answers for a few '
              'seconds.',
        ),
        const SizedBox(height: 16),
        if (_busy)
          Column(
            children: [
              const LinearProgressIndicator(),
              const SizedBox(height: 8),
              Text(
                _attempt <= 1
                    ? 'Asking the robot…'
                    : 'Asking the robot (try $_attempt)…',
                textAlign: TextAlign.center,
              ),
            ],
          )
        else
          FilledButton(
            onPressed: _runButtonRoute,
            child: const Text('I held HOME — ask the robot'),
          ),
        const SizedBox(height: 8),
        TextButton(
          onPressed:
              _busy ? null : () => setState(() => _route = _Route.chooser),
          child: const Text('Back'),
        ),
      ],
    );
  }

  Future<void> _runButtonRoute() async {
    setState(() {
      _busy = true;
      _error = null;
      _legacyTls = false;
      _attempt = 0;
    });
    try {
      final password =
          await ref.read(roombaPasswordServiceProvider).fetchPassword(
        widget.host,
        attempts: widget.passwordAttempts,
        onAttempt: (attempt) {
          if (mounted) setState(() => _attempt = attempt);
        },
      );
      await _adopt(RoombaCredentials(
        blid: widget.blid,
        password: password,
        name: widget.robotName,
        sku: widget.sku,
        lastIp: widget.host,
      ));
    } catch (e) {
      _fail(e, 'The robot did not hand over a password.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ── Route 2: the iRobot account ────────────────────────────────────────────

  Widget _accountRoute(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Signing in reads your robots\' BLIDs and passwords out of '
            'iRobot\'s API. Your account password is used for that one '
            'request and is never saved.',
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _emailController,
            enabled: !_busy,
            keyboardType: TextInputType.emailAddress,
            autocorrect: false,
            decoration: const InputDecoration(
              labelText: 'iRobot account email',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _accountPasswordController,
            enabled: !_busy,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: 'iRobot account password',
              border: OutlineInputBorder(),
              helperText: 'Not stored. Sent to iRobot once.',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _countryController,
            enabled: !_busy,
            autocorrect: false,
            textCapitalization: TextCapitalization.characters,
            decoration: const InputDecoration(
              labelText: 'Account region',
              border: OutlineInputBorder(),
              helperText: 'Two-letter country code for your iRobot account. '
                  'The wrong one signs in but finds no robots.',
            ),
          ),
          const SizedBox(height: 16),
          if (_busy)
            const LinearProgressIndicator()
          else
            FilledButton(
              onPressed: _runAccountRoute,
              child: const Text('Sign in and read my robots'),
            ),
          const SizedBox(height: 8),
          TextButton(
            onPressed:
                _busy ? null : () => setState(() => _route = _Route.chooser),
            child: const Text('Back'),
          ),
        ],
      );

  Future<void> _runAccountRoute() async {
    setState(() {
      _busy = true;
      _error = null;
      _legacyTls = false;
    });
    try {
      final country = _countryController.text.trim().toUpperCase();
      final robots =
          await ref.read(iRobotCloudServiceProvider).fetchCredentials(
                email: _emailController.text.trim(),
                password: _accountPasswordController.text,
                countryCode: country.isEmpty ? _localeCountry() : country,
              );
      // Clear it the moment it has been used, rather than at dispose: the
      // window in which it exists should be as short as the flow allows.
      _accountPasswordController.clear();

      // This screen was opened for ONE robot, and only that robot's credential
      // is any use here: the scan flow carries on to the device it started
      // from, and looks its password up by that BLID.
      //
      // Falling back to the account's first robot instead of failing is worse
      // than it sounds. It stores a different robot's password under that
      // robot's own BLID, so the adoption reports success, the robot the user
      // actually picked still has nothing saved, and the failure surfaces
      // later somewhere else entirely.
      final wanted = widget.blid.toUpperCase();
      final match = robots
          .where((robot) => robot.blid.toUpperCase() == wanted)
          .firstOrNull;
      if (match == null) {
        final names = robots
            .map((robot) => robot.name ?? robot.blid)
            .where((name) => name.isNotEmpty)
            .join(', ');
        throw IRobotCloudException(
          robots.isEmpty
              ? 'That account has no robots in this region. Check the account '
                  'region above — the wrong one signs in but finds nothing.'
              : 'This robot (${widget.blid}) is not on that account. It holds: '
                  '$names. Sign in with the account that owns this robot, or '
                  'use the HOME-button route instead.',
        );
      }
      await _adopt(match.copyWith(lastIp: widget.host));
    } catch (e) {
      _fail(e, 'Could not read your robots from iRobot.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Offer the transport chooser from the failure panel.
  ///
  /// This is the answer for the two failures that are NOT "try again": a robot
  /// whose firmware only speaks a cipher the phone cannot, and a robot already
  /// held by something else. Both are fixed by not talking to the robot
  /// directly — which is what the chooser is for.
  ///
  /// No credential is passed: reaching here means the app never got one. The
  /// chooser therefore shows only the Home Assistant route, which is the one
  /// that needs no password in this app at all.
  Future<void> _openTransportChooser() async {
    final entity = await Navigator.of(context).push<HaEntityState>(
      MaterialPageRoute(builder: (_) => const RoombaTransportScreen()),
    );
    if (entity == null || !mounted) return;
    // Adopted with no password of our own: Home Assistant holds it, and the
    // robot is reachable through the entity id alone.
    await _adopt(RoombaCredentials(
      blid: widget.blid,
      password: '',
      name: widget.robotName,
      sku: widget.sku,
      lastIp: widget.host,
      haEntityId: entity.entityId,
    ));
  }

  // ── Route 3: paste what you already have ───────────────────────────────────

  Widget _pasteRoute(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'If you already ran dorita980 or roombapy on a computer, or you '
            'have these in Home Assistant, paste them here.',
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _blidController,
            autocorrect: false,
            decoration: const InputDecoration(
              labelText: 'BLID',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _passwordController,
            autocorrect: false,
            decoration: const InputDecoration(
              labelText: 'Password',
              border: OutlineInputBorder(),
              // The mistake this field invites, named before it happens.
              helperText: 'Paste the whole thing, including the leading colon.',
            ),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _busy ? null : _savePasted,
            child: const Text('Save'),
          ),
          const SizedBox(height: 8),
          TextButton(
            onPressed:
                _busy ? null : () => setState(() => _route = _Route.chooser),
            child: const Text('Back'),
          ),
        ],
      );

  Future<void> _savePasted() async {
    final blid = _blidController.text.trim();
    final password = _passwordController.text.trim();
    if (blid.isEmpty || password.isEmpty) {
      setState(() => _error = 'Both the BLID and the password are needed.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _adopt(RoombaCredentials(
        blid: blid,
        password: password,
        name: widget.robotName,
        sku: widget.sku,
        lastIp: widget.host,
      ));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ── Shared ─────────────────────────────────────────────────────────────────

  Future<void> _adopt(RoombaCredentials credentials) async {
    await ref.read(roombaCredentialStoreProvider).save(credentials);
    ref.invalidate(roombaCredentialsProvider(credentials.blid));
    if (mounted) setState(() => _revealed = credentials);
  }

  void _fail(Object error, String fallback) {
    if (!mounted) return;
    setState(() {
      _legacyTls =
          error is RoombaConnectionException && error.legacyTlsSuspected;
      _error = friendlyErrorText(
        error,
        context: 'roomba adoption',
        fallback: fallback,
      );
    });
  }

  Future<void> _open(Uri url) => ref.read(urlOpenerProvider)(url);
}

/// One numbered instruction. A list rather than a paragraph because the order
/// genuinely matters — doing step 3 before step 2 is why the handshake fails.
class _Step extends StatelessWidget {
  final int number;
  final String text;

  const _Step({required this.number, required this.text});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CircleAvatar(
              radius: 12,
              child: Text('$number', style: const TextStyle(fontSize: 12)),
            ),
            const SizedBox(width: 12),
            Expanded(child: Text(text)),
          ],
        ),
      );
}

/// The end of the flow, and the reason it is a screen rather than a sheet.
///
/// These two values outlive the app, the phone, and quite possibly the
/// company. An owner who captures them here never repeats this — and every
/// other local client, Home Assistant included, asks for exactly these.
class _CredentialReveal extends StatelessWidget {
  final RoombaCredentials credentials;
  final String host;
  final VoidCallback onDone;

  const _CredentialReveal({
    required this.credentials,
    required this.host,
    required this.onDone,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(Icons.check_circle, color: theme.colorScheme.primary),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Adopted — saved to this device',
                style: theme.textTheme.titleMedium,
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Card(
          color: theme.colorScheme.surfaceContainerHighest,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Screenshot this',
                  style: theme.textTheme.titleSmall,
                ),
                const SizedBox(height: 4),
                Text(
                  'These only change if the robot is factory reset. They are '
                  'what Home Assistant, dorita980 and any other local client '
                  'will ask you for.',
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: 16),
                _Field(label: 'BLID', value: credentials.blid),
                _Field(label: 'Password', value: credentials.password),
                _Field(label: 'Address', value: host),
                if (credentials.sku != null)
                  _Field(label: 'Model', value: credentials.sku!),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        FilledButton(onPressed: onDone, child: const Text('Control the robot')),
      ],
    );
  }
}

/// One labelled, copyable value.
class _Field extends StatelessWidget {
  final String label;
  final String value;

  const _Field({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: theme.textTheme.labelSmall),
                // Selectable and monospaced: these get read aloud, retyped and
                // pasted into other tools, and a password with a leading colon
                // is easy to mis-transcribe.
                SelectableText(
                  value,
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(fontFamily: 'monospace'),
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.copy, size: 18),
            tooltip: 'Copy $label',
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: value));
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('$label copied')),
              );
            },
          ),
        ],
      ),
    );
  }
}

/// A failure, and what to do about it.
class _ErrorPanel extends StatelessWidget {
  final String message;
  final bool legacyTls;
  final Future<void> Function(Uri) onOpen;
  final Future<void> Function() onChooseTransport;

  const _ErrorPanel({
    required this.message,
    required this.legacyTls,
    required this.onOpen,
    required this.onChooseTransport,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      color: theme.colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              message,
              style: TextStyle(color: theme.colorScheme.onErrorContainer),
            ),
            // The cipher gap is not a retry situation, so the panel offers the
            // things that actually work instead of implying "try again". The
            // button comes first: it is the one route that needs nothing from
            // this phone's TLS stack, because the robot is reached through
            // something else entirely.
            if (legacyTls) ...[
              const SizedBox(height: 12),
              Text(
                'This robot\'s firmware only offers a cipher this phone cannot '
                'use, so no amount of retrying will reach it directly. What '
                'does work is letting something else hold the robot: Home '
                'Assistant, or a rest980 server. Either one can use the old '
                'cipher, and then this app just asks it. Failing that, run '
                'dorita980 on a computer and paste the password in here.',
                style: TextStyle(color: theme.colorScheme.onErrorContainer),
              ),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: onChooseTransport,
                child: const Text('Reach it another way'),
              ),
              const SizedBox(height: 4),
              Wrap(
                spacing: 8,
                children: [
                  TextButton(
                    onPressed: () => onOpen(_dorita980),
                    child: const Text('dorita980'),
                  ),
                  TextButton(
                    onPressed: () => onOpen(_rest980),
                    child: const Text('rest980'),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Whose work this is. On every step, not tucked into an about screen.
class _CreditLine extends StatelessWidget {
  final Future<void> Function(Uri) onOpen;

  const _CreditLine({required this.onOpen});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        const Divider(),
        const SizedBox(height: 8),
        Text(
          'The password handshake and the local API are koalazak/dorita980\'s '
          'work (MIT). We only wrote the wrapper.',
          style: theme.textTheme.bodySmall,
          textAlign: TextAlign.center,
        ),
        TextButton(
          onPressed: () => onOpen(_dorita980),
          child: const Text('github.com/koalazak/dorita980'),
        ),
      ],
    );
  }
}
