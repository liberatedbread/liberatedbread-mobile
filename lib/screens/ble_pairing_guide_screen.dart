// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/device_pictogram.dart';
import '../providers/ble_pairing_guide_provider.dart';
import '../widgets/device_list_tile.dart';
import 'setup_instructions_screen.dart';

/// How to get a new Bluetooth device ready to connect, per device, from the
/// catalogue's own `device.setup` prose — the Nearby tab's counterpart of the
/// Wi-Fi tab's adopt picker.
///
/// A guide rather than a flow: a BLE device takes no credentials, so there is
/// nothing for the app to send. What the person needs is how to wake THIS
/// device into pairing mode (hold which button, for how long, what the light
/// does), and then the scan they came from. The general steps sit at the top;
/// each row opens that device's own instructions.
class BlePairingGuideScreen extends ConsumerStatefulWidget {
  const BlePairingGuideScreen({super.key});

  @override
  ConsumerState<BlePairingGuideScreen> createState() =>
      _BlePairingGuideScreenState();
}

class _BlePairingGuideScreenState extends ConsumerState<BlePairingGuideScreen> {
  final _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  /// Name or maker, case-insensitively — "ember" finds the mug, "govee" every
  /// Govee light. Whitespace-separated terms must all match, so "govee strip"
  /// narrows rather than widens.
  static bool _matches(BlePairingGuideEntry entry, String query) {
    final haystack = '${entry.deviceName} ${entry.manufacturer}'.toLowerCase();
    return query
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .where((t) => t.isNotEmpty)
        .every(haystack.contains);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final guide = ref.watch(blePairingGuideProvider);

    return Scaffold(
      backgroundColor: scheme.surface,
      appBar: AppBar(title: const Text('Pair a Bluetooth device')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 24, 20, 40),
          children: [
            Center(
              child: Icon(
                Icons.bluetooth_searching,
                size: 56,
                color: scheme.secondary,
              ),
            ),
            const SizedBox(height: 24),
            Text(
              'Pairing a new device',
              textAlign: TextAlign.center,
              style: text.headlineSmall?.copyWith(
                fontWeight: FontWeight.w700,
                letterSpacing: -0.4,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'Bluetooth devices connect from inside this app — there is no '
              'Wi-Fi to set up. Three steps:',
              textAlign: TextAlign.center,
              style: text.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 20),
            _instruction(
              context,
              '1',
              'Put the device in pairing mode. Find it below for how — many '
                  'need nothing more than switching on.',
            ),
            _instruction(
              context,
              '2',
              'Close the maker’s app if it is open. Many of these devices '
                  'take one connection at a time.',
            ),
            _instruction(
              context,
              '3',
              'Go back to Nearby and scan. Tap the device when it appears. If '
                  'your phone asks to pair or for a PIN, accept it.',
            ),
            const SizedBox(height: 28),
            ...guide.when(
              loading: () => const [
                Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: CircularProgressIndicator(),
                  ),
                ),
              ],
              error: (_, _) => [
                _note(context, 'Could not read the device catalogue.'),
              ],
              data: (entries) => _list(context, entries),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _list(BuildContext context, List<BlePairingGuideEntry> all) {
    if (all.isEmpty) {
      return [
        _note(context, 'No pairing instructions are in the catalogue yet.'),
      ];
    }
    final shown = _query.trim().isEmpty
        ? all
        : all.where((e) => _matches(e, _query)).toList();
    return [
      TextField(
        controller: _search,
        // A product name, not prose: autocorrect turning "Govee" into
        // "Give" empties the list.
        autocorrect: false,
        enableSuggestions: false,
        textInputAction: TextInputAction.search,
        decoration: InputDecoration(
          labelText: 'Search by name or maker',
          prefixIcon: const Icon(Icons.search),
          border: const OutlineInputBorder(),
          suffixIcon: _query.isEmpty
              ? null
              : IconButton(
                  tooltip: 'Clear search',
                  icon: const Icon(Icons.clear),
                  onPressed: () => setState(() {
                    _search.clear();
                    _query = '';
                  }),
                ),
        ),
        onChanged: (value) => setState(() => _query = value),
      ),
      const SizedBox(height: 20),
      SectionHeader(label: 'Which device?', count: shown.length),
      const SizedBox(height: 12),
      if (shown.isEmpty)
        _note(
          context,
          'Nothing matches "${_query.trim()}". The catalogue may not know '
          'this device yet — it can still be scanned for and connected to.',
        ),
      for (final entry in shown) ...[
        _deviceCard(context, entry),
        const SizedBox(height: 10),
      ],
    ];
  }

  Widget _deviceCard(BuildContext context, BlePairingGuideEntry entry) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Card(
      margin: EdgeInsets.zero,
      child: ListTile(
        leading: Icon(
          DevicePictogram.forDevice(
            pictogram: entry.pictogram,
            category: entry.category,
          ),
          color: scheme.secondary,
        ),
        title: Text(
          entry.deviceName,
          style: text.titleMedium?.copyWith(fontWeight: FontWeight.w600),
        ),
        subtitle: entry.manufacturer.trim().isEmpty
            ? null
            : Text(
                entry.manufacturer,
                style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => SetupInstructionsScreen(
              deviceName: entry.deviceName,
              instructions: entry.instructions,
              afterFailedConnect: false,
            ),
          ),
        ),
      ),
    );
  }

  Widget _note(BuildContext context, String message) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Text(
        message,
        style: text.bodyMedium?.copyWith(
          color: scheme.onSurfaceVariant,
          height: 1.5,
        ),
      ),
    );
  }

  /// A numbered step, drawn like the Wi-Fi adopt screen's so the two guides
  /// read as one family.
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
            child: Text(
              number,
              style: text.labelLarge?.copyWith(
                color: scheme.onSecondaryContainer,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(body, style: text.bodyMedium?.copyWith(height: 1.5)),
          ),
        ],
      ),
    );
  }
}
