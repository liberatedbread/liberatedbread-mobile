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
import '../models/radio_target.dart';
import '../providers/ble_provider.dart';
import '../providers/radio_programmer_provider.dart';
import '../providers/saved_radio_provider.dart';
import '../providers/serial_port_provider.dart';
import '../services/codeplug_backup_store.dart';
import '../services/radio_programmer.dart';
import '../services/radio_recognition.dart';
import '../services/serial_port_service.dart';

/// The backup store. Overridden in tests with a temp directory.
final codeplugBackupStoreProvider = Provider<CodeplugBackupStore>(
  (ref) => CodeplugBackupStore(dirResolver: getApplicationDocumentsDirectory),
);

/// Find the radio, then read it, back it up, and write the plan.
///
/// Opened from a plan, it looks for the radio the way that radio is reached:
/// a Bluetooth scan, or the cables plugged in. Opened from a radio's own
/// screen, it is handed [target] and goes straight to that radio.
class RadioProgramScreen extends ConsumerStatefulWidget {
  final ChannelPlan plan;
  final RadioProfile profile;

  /// The radio to write to, when the caller already knows it. Null scans.
  final RadioTarget? target;

  const RadioProgramScreen({
    super.key,
    required this.plan,
    required this.profile,
    this.target,
  });

  @override
  ConsumerState<RadioProgramScreen> createState() => _RadioProgramScreenState();
}

class _RadioProgramScreenState extends ConsumerState<RadioProgramScreen> {
  StreamSubscription<IoTDevice>? _scan;
  final Map<String, IoTDevice> _found = {};
  bool _scanning = false;
  String? _scanError;

  /// The cables plugged in, for a radio programmed over one. Null while
  /// they are being listed.
  List<SerialPortInfo>? _ports;
  String? _portsError;

  /// Set while a session is running; nothing else may start one.
  RadioProgressEvent? _progress;
  String? _sessionError;
  String? _outcome;
  CodeplugBackup? _lastBackup;

  @override
  void initState() {
    super.initState();
    if (widget.target != null) return;
    if (_overCable) {
      unawaited(_listPorts());
    } else {
      unawaited(_startScan());
    }
  }

  /// This plan's radio is reached through a cable, not over the air.
  bool get _overCable =>
      widget.profile.programmingTransport == RadioTransport.usb;

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
    final target = widget.target;

    // Leaving mid-write would not stop the write — it carries on behind the
    // popped route — but it would hide it, and a radio switched off because
    // the screen looked idle is the one outcome worth designing against.
    return PopScope(
      canPop: !_busy,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Wait for the radio to finish — do not turn it off '
              'or unplug it.',
            ),
          ),
        );
      },
      child: Scaffold(
        appBar: AppBar(title: Text('Program ${widget.profile.displayName}')),
        body: ListView(
          children: [
            _intro(),
            if (_sessionError case final String error)
              ListTile(
                leading: Icon(
                  Icons.error_outline,
                  color: Theme.of(context).colorScheme.error,
                ),
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
            if (target != null)
              ListTile(
                leading: const Icon(Icons.settings_input_antenna),
                title: Text(target.displayName),
                subtitle: Text(target.transport.label),
                trailing: _busy
                    ? null
                    : FilledButton(
                        onPressed: () => _program(target),
                        child: const Text('Write'),
                      ),
              )
            else if (_overCable)
              ..._cableSection()
            else ...[
              _scanHeader(),
              if (_scanError case final String error)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Text(
                    error,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
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
                  onTap: _busy
                      ? null
                      : () => _program(
                          RadioTarget(
                            transport: RadioTransport.ble,
                            id: radio.id,
                            name: radio.name,
                          ),
                        ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _intro() => Padding(
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${widget.plan.name} · '
          '${widget.plan.length} channels',
        ),
        const SizedBox(height: 8),
        Text(
          'The radio is read first and that copy is saved, so whatever is '
          'on it now can be put back. '
          '${widget.target != null
              ? 'Press Write to start.'
              : _overCable
              ? 'Pick the cable below to start.'
              : 'Pick your radio below to start.'}',
        ),
        if (widget.profile.programmerSupport == ProgrammerSupport.unverified)
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

  List<Widget> _cableSection() {
    final ports = _ports;
    String bridgeLine(SerialPortInfo port) => [
      port.name,
      if (port.bridge != null && port.bridge!.name != port.displayName)
        port.bridge!.name,
    ].join(' · ');
    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 8, 0),
        child: Row(
          children: [
            Expanded(
              child: Text(
                'Cables',
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
              ),
            ),
            if (ports == null)
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else
              TextButton(
                onPressed: _busy ? null : _listPorts,
                child: const Text('Look again'),
              ),
          ],
        ),
      ),
      if (_portsError case final String error)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            error,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ),
      if (ports != null && ports.isEmpty && _portsError == null)
        const Padding(
          padding: EdgeInsets.all(16),
          child: Text(
            'No cable found. Plug the programming cable into the radio and '
            'into this device — on a phone, through a USB-OTG adapter — then '
            'look again.',
          ),
        ),
      for (final port in ports ?? const <SerialPortInfo>[])
        ListTile(
          leading: const Icon(Icons.usb),
          title: Text(port.displayName),
          subtitle: Text(bridgeLine(port)),
          trailing: _busy ? null : const Icon(Icons.chevron_right),
          onTap: _busy
              ? null
              : () => _program(
                  RadioTarget(
                    transport: RadioTransport.usb,
                    id: port.id,
                    name: port.displayName,
                  ),
                ),
        ),
    ];
  }

  Future<void> _listPorts() async {
    final service = ref.read(serialPortServiceProvider);
    setState(() {
      _ports = null;
      _portsError = null;
    });
    final availability = service.availability;
    if (!availability.supported) {
      setState(() {
        _ports = const [];
        _portsError = availability.reason;
      });
      return;
    }
    try {
      final ports = await service.listPorts();
      if (mounted) setState(() => _ports = ports);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _ports = const [];
        _portsError = friendlyErrorText(
          error,
          fallback: 'Could not list the cables plugged in.',
          context: 'serial port list',
        );
      });
    }
  }

  Widget _scanHeader() => Padding(
    padding: const EdgeInsets.fromLTRB(16, 0, 8, 0),
    child: Row(
      children: [
        Expanded(
          child: Text(
            'Radios nearby',
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
          ),
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

  /// Scan, keeping only what might be one of these radios.
  ///
  /// [mightBeRadio] is the loose test — the UART service alone qualifies —
  /// because this screen is already looking for a radio. It is a hint rather
  /// than an identity: what settles which radio this is, is the ident
  /// exchange once connected.
  Future<void> _startScan() async {
    await _scan?.cancel();
    setState(() {
      _scanning = true;
      _scanError = null;
      _found.clear();
    });

    final ble = ref.read(bleServiceProvider);
    _scan = ble
        .scan(timeout: const Duration(seconds: 12))
        .listen(
          (device) {
            if (!mightBeRadio(
              name: device.name,
              serviceUuids: device.serviceUuids,
            )) {
              return;
            }
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

  /// Read, back up, write.
  Future<void> _program(RadioTarget radio) async {
    final programmer = ref.read(
      radioProgrammerForTransportProvider(radio.transport),
    );
    final backups = ref.read(codeplugBackupStoreProvider);
    final savedRadios = ref.read(savedRadiosProvider.notifier);
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

      // A full read is the radio answering, which is what saves it — the same
      // save-on-connect rule as every other device list.
      await savedRadios.touch(
        target: radio,
        seenAt: DateTime.now(),
        radioProfileId: widget.profile.id,
      );

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
        _outcome =
            '${widget.plan.length} channels written to '
            '${radio.displayName}.';
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

  Future<bool> _confirm(RadioTarget radio) async {
    final name = radio.displayName;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Write to $name?'),
        content: Text(
          'This replaces the ${widget.profile.channelCapacity} memory '
          'channels on the radio with the ${widget.plan.length} in '
          '"${widget.plan.name}". Its other settings are left alone.\n\n'
          'A copy of what is on the radio now is saved first. To put it '
          'back, open the radio under Saved devices and choose Restore a '
          'backup.',
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
