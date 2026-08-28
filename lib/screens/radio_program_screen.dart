// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// Finding the radio, and putting a plan on it.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../core/error_text.dart';
import '../models/channel_plan.dart';
import '../models/iot_device.dart';
import '../models/radio_profile.dart';
import '../providers/ble_provider.dart';
import '../providers/radio_programmer_provider.dart';
import '../services/baofeng_ble_programmer.dart';
import '../services/codeplug_backup_store.dart';
import '../services/radio_programmer.dart';

/// The backup store. Overridden in tests with a temp directory.
final codeplugBackupStoreProvider = Provider<CodeplugBackupStore>(
  (ref) => CodeplugBackupStore(dirResolver: getApplicationDocumentsDirectory),
);

/// Scan for the radio, then read it, back it up, and write the plan.
class RadioProgramScreen extends ConsumerStatefulWidget {
  final ChannelPlan plan;
  final RadioProfile profile;

  const RadioProgramScreen({
    super.key,
    required this.plan,
    required this.profile,
  });

  @override
  ConsumerState<RadioProgramScreen> createState() => _RadioProgramScreenState();
}

class _RadioProgramScreenState extends ConsumerState<RadioProgramScreen> {
  StreamSubscription<IoTDevice>? _scan;
  final Map<String, IoTDevice> _found = {};
  bool _scanning = false;
  String? _scanError;

  /// Set while a session is running; nothing else may start one.
  RadioProgressEvent? _progress;
  String? _sessionError;
  String? _outcome;
  CodeplugBackup? _lastBackup;

  @override
  void initState() {
    super.initState();
    unawaited(_startScan());
  }

  @override
  void dispose() {
    unawaited(_scan?.cancel());
    super.dispose();
  }

  bool get _busy => _progress != null;

  @override
  Widget build(BuildContext context) {
    final radios = _found.values.toList()
      ..sort((a, b) => b.rssi.compareTo(a.rssi));

    return Scaffold(
      appBar: AppBar(title: Text('Program ${widget.profile.displayName}')),
      body: ListView(
        children: [
          _intro(),
          if (_sessionError case final String error)
            ListTile(
              leading: Icon(Icons.error_outline,
                  color: Theme.of(context).colorScheme.error),
              title: Text(error),
            ),
          if (_outcome case final String outcome)
            ListTile(
              leading: const Icon(Icons.check_circle_outline),
              title: Text(outcome),
              subtitle: _lastBackup == null
                  ? null
                  : Text('Backup saved as ${_lastBackup!.displayName}'),
            ),
          if (_progress case final RadioProgressEvent event)
            _progressTile(event),
          const Divider(height: 24),
          _scanHeader(),
          if (_scanError case final String error)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(error,
                  style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ),
          if (radios.isEmpty && !_scanning)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'No radios found yet. Turn the radio on, and make sure its '
                'Bluetooth is enabled in its own menu.',
              ),
            ),
          for (final radio in radios)
            ListTile(
              leading: const Icon(Icons.radio_outlined),
              title: Text(radio.name.isEmpty ? radio.id : radio.name),
              subtitle: Text('${radio.id} · ${radio.rssi} dBm'),
              trailing: _busy ? null : const Icon(Icons.chevron_right),
              onTap: _busy ? null : () => _program(radio),
            ),
        ],
      ),
    );
  }

  Widget _intro() => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${widget.plan.name} · '
                '${widget.plan.length} channels'),
            const SizedBox(height: 8),
            const Text(
              'The radio is read first and that copy is saved, so whatever is '
              'on it now can be put back. Pick your radio below to start.',
            ),
            if (widget.profile.programmerSupport ==
                ProgrammerSupport.unverified)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text(
                  'Programming has not been confirmed on this exact model. '
                  'The backup is the thing to rely on.',
                ),
              ),
          ],
        ),
      );

  Widget _progressTile(RadioProgressEvent event) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(event.message),
            const SizedBox(height: 8),
            LinearProgressIndicator(value: event.progress),
          ],
        ),
      );

  Widget _scanHeader() => Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 8, 0),
        child: Row(
          children: [
            Expanded(
              child: Text('Radios nearby',
                  style: Theme.of(context)
                      .textTheme
                      .titleMedium
                      ?.copyWith(fontWeight: FontWeight.bold)),
            ),
            if (_scanning)
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else
              TextButton(
                onPressed: _busy ? null : _startScan,
                child: const Text('Scan again'),
              ),
          ],
        ),
      );

  /// Scan, keeping only what looks like one of these radios.
  ///
  /// The filter is by advertised service and name, and it is a hint rather
  /// than an identity — what settles which radio this is, is the ident
  /// exchange once connected.
  Future<void> _startScan() async {
    await _scan?.cancel();
    setState(() {
      _scanning = true;
      _scanError = null;
      _found.clear();
    });

    final ble = ref.read(bleServiceProvider);
    _scan = ble.scan(timeout: const Duration(seconds: 12)).listen(
      (device) {
        if (!_looksLikeARadio(device)) return;
        setState(() => _found[device.id] = device);
      },
      onError: (Object error) {
        if (!mounted) return;
        setState(() {
          _scanning = false;
          _scanError = friendlyErrorText(
            error,
            fallback: 'Could not scan for radios.',
            context: 'radio programming scan',
          );
        });
      },
      onDone: () {
        if (mounted) setState(() => _scanning = false);
      },
    );
  }

  static bool _looksLikeARadio(IoTDevice device) {
    final name = device.name.toLowerCase();
    if (device.serviceUuids
        .any((uuid) => uuid.toLowerCase() == baofengUartService)) {
      return true;
    }
    return baofengAdvertisedNamePrefixes.any(name.contains);
  }

  /// Read, back up, write.
  Future<void> _program(IoTDevice radio) async {
    final programmer = ref.read(radioProgrammerProvider);
    final backups = ref.read(codeplugBackupStoreProvider);
    final messenger = ScaffoldMessenger.of(context);

    if (!programmer.supports(widget.profile)) {
      setState(() => _sessionError = const RadioUnsupportedException().message);
      return;
    }
    if (!await _confirm(radio)) return;

    // Fire-and-forget: tearing a scan down can outlive the frame it was
    // asked on, and making the user wait for it before the radio is even
    // contacted buys nothing. Clearing the field first means a late callback
    // from the old subscription cannot resurrect the list mid-session.
    final scan = _scan;
    _scan = null;
    unawaited(scan?.cancel());
    setState(() {
      _scanning = false;
      _sessionError = null;
      _outcome = null;
      _progress = const RadioProgressEvent(
        stage: RadioProgressStage.connecting,
        message: 'Starting…',
      );
    });

    try {
      RadioCodeplug? current;
      await programmer
          .readCodeplug(
            deviceId: radio.id,
            profile: widget.profile,
            onResult: (codeplug) => current = codeplug,
          )
          .forEach(_onProgress);

      final base = current;
      if (base == null) throw const RadioProtocolException();

      // Saved before a single byte goes back, which is the whole point.
      final backup = await backups.save(base);
      if (mounted) setState(() => _lastBackup = backup);

      await programmer
          .writeChannels(
            deviceId: radio.id,
            profile: widget.profile,
            base: base,
            channels: widget.plan.channels,
          )
          .forEach(_onProgress);

      if (!mounted) return;
      setState(() {
        _progress = null;
        _outcome = '${widget.plan.length} channels written to '
            '${radio.name.isEmpty ? radio.id : radio.name}.';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _progress = null;
        _sessionError = friendlyErrorText(
          error,
          fallback: 'Programming did not finish.',
          context: 'radio programming',
        );
      });
      messenger.showSnackBar(SnackBar(content: Text(_sessionError!)));
    }
  }

  void _onProgress(RadioProgressEvent event) {
    if (mounted) setState(() => _progress = event);
  }

  Future<bool> _confirm(IoTDevice radio) async {
    final name = radio.name.isEmpty ? radio.id : radio.name;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Write to $name?'),
        content: Text(
          'This replaces the ${widget.profile.channelCapacity} memory '
          'channels on the radio with the ${widget.plan.length} in '
          '"${widget.plan.name}". Its other settings are left alone.\n\n'
          'A copy of what is on the radio now is saved first, and can be '
          'restored from the Radio tab.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Write'),
          ),
        ],
      ),
    );
    return confirmed ?? false;
  }
}
