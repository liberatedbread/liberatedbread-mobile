// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/device_category.dart';
import '../core/hex.dart';
import '../core/log.dart';
import '../models/ble_discovered_service.dart';
import '../providers/device_description_provider.dart';
import '../providers/device_spec_match_provider.dart';
import '../providers/spec_choice_provider.dart';
import '../services/number_registry.dart';
import '../services/spec_codec.dart';
import 'binary_sensor_card.dart';
import 'entity_sensor_card.dart';
import 'led_image_widget.dart';
import 'light_control_card.dart';
import 'raw_characteristic_widget.dart';
import 'setpoint_control_card.dart';
import 'switch_control_card.dart';
import 'treadmill_control_card.dart';
import 'typed_characteristic_widget.dart';

/// Displays the services/characteristics of a connected device. When the device
/// matches a bundled device spec, characteristics are rendered as typed
/// controls (command buttons, sliders, decoded values); anything unmatched
/// falls back to the raw GATT/hex browser.
class DeviceControlPanel extends ConsumerWidget {
  final String deviceId;
  final String deviceName;
  final List<BleDiscoveredService> services;

  const DeviceControlPanel({
    super.key,
    required this.deviceId,
    required this.deviceName,
    required this.services,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (services.isEmpty) {
      return const Center(
        child: Text('No services found on this device.'),
      );
    }

    // Normalize (lowercase) + sort the UUIDs so the family cache key is stable
    // regardless of discovery order/casing; the Rust matcher is already
    // case-insensitive, so this only affects the key's stability.
    final serviceUuids = [for (final s in services) normalizeUuid(s.uuid)]
      ..sort();

    // Names standard services the spec does not describe. Watched, not read:
    // it resolves a frame or two after the first build, and the cards should
    // gain their names when it does rather than on the next unrelated
    // rebuild.
    final registry = ref.watch(numberRegistryProvider);

    // valueOrNull rather than asData: on a recompute (e.g. a spec choice was
    // just saved) riverpod re-emits AsyncLoading, and asData would go null —
    // momentarily unmounting typed controls and the LED editor (destroying
    // its drawn frames) before the fresh result lands. valueOrNull keeps the
    // previous outcome through the reload; a first load still starts null,
    // showing the raw browser until the match resolves.
    final outcome = ref
        .watch(matchedDeviceSpecProvider(
          SpecMatchRequest(
            deviceId: deviceId,
            deviceName: deviceName,
            serviceUuids: serviceUuids,
          ),
        ))
        .valueOrNull;
    final match = outcome?.chosen;

    // Entities the spec declares, paired with the discovered service that
    // actually carries them. An entity whose characteristics were not
    // discovered on this device is dropped: the spec may describe a variant
    // with more hardware than the unit in front of us.
    //
    // Sensors and binary sensors become readings; `switch` and `light`
    // entities become control cards when the spec resolved something for
    // them (a sendable action, or at least readable state for a switch).
    // Anything else still comes through the typed command widgets below.
    //
    // One display name renders once. A family spec declares the same logical
    // reading once per variant-specific binding — Airthings' "Radon 24h
    // Average" exists against the Gen 1 radon characteristic AND each model's
    // combined packet, with disjoint variants — and real hardware carries
    // exactly one of those characteristics, so the bindings dedupe themselves.
    // The mock does not: it exposes every service in the YAML at once, and
    // anything else that carries two variants' services would likewise show
    // one reading three times. First spec-order binding that resolved wins.
    final seen = <String>{};
    final readings = <({EntityDto entity, String serviceUuid})>[];
    final controls = <({EntityDto entity, String? stateServiceUuid})>[];
    for (final entity in match?.spec.entities ?? const <EntityDto>[]) {
      // The discovered service owning the entity's state characteristic,
      // when it has one and this device carries it.
      final stateChar = entity.stateCharacteristic;
      final owningState = stateChar == null
          ? null
          : services
              .where(
                (s) => s.characteristics.any(
                  (c) => normalizeUuid(c.uuid) == normalizeUuid(stateChar),
                ),
              )
              .firstOrNull;

      switch (entity.platform) {
        case null || 'sensor' || 'binary_sensor':
          if (owningState == null) continue;
          if (!seen.add('${entity.platform}|${entity.name}')) continue;
          readings.add((entity: entity, serviceUuid: owningState.uuid));
        case 'switch' || 'light' || 'number' || 'climate':
          // At least one action must target a characteristic this device
          // actually has; a switch or setpoint may instead ride on readable
          // state alone (ember's temperature control has no sendable command,
          // and its target temperature cannot be encoded yet — both are still
          // worth showing as live readings).
          final actionsDiscovered = entity.actions.any(
            (a) => services.any(
              (s) => s.characteristics.any(
                (c) =>
                    normalizeUuid(c.uuid) ==
                    normalizeUuid(a.characteristicUuid),
              ),
            ),
          );
          final stateOnly = entity.platform != 'light' && owningState != null;
          if (!actionsDiscovered && !stateOnly) continue;
          if (!seen.add('${entity.platform}|${entity.name}')) continue;
          controls.add((entity: entity, stateServiceUuid: owningState?.uuid));
        default:
          continue;
      }
    }

    // A sensor device's product is its readings; the GATT tree below them is
    // plumbing. When the matched spec says this is a sensor and its readings
    // are on screen, the raw service cards start folded so the first screen
    // is radon and CO₂, not the OAD firmware service — still one tap away.
    final foldRawServices = readings.isNotEmpty &&
        DeviceCategory.parse(match?.spec.category) == DeviceCategory.sensor;

    // Leading slots above the raw service list: the spec chooser when several
    // specs tie (raw controls stay usable below it), a banner when the active
    // spec is a saved user choice (with the way to change it), the LED image
    // editor for specs declaring a pixel surface, then any spec-declared
    // readings once a spec is chosen. Chooser and banner are mutually
    // exclusive today — no spec is chosen while a choice is pending — but
    // built as a list so that isn't load-bearing.
    // Every slot is keyed: leading slots appear/disappear as the match
    // resolves or the user answers the chooser, and without keys Flutter
    // re-pairs the STATEFUL service cards positionally — a card labeled with
    // service B would keep service A's element state (including notify
    // subscriptions bound in initState) after the shift.
    final leading = <Widget>[
      if (outcome != null && outcome.needsChoice)
        _SpecChoicePrompt(
          key: const ValueKey('spec-choice-prompt'),
          deviceId: deviceId,
          candidates: outcome.candidates,
        ),
      if (outcome != null && outcome.source == SpecChoiceSource.saved)
        _SavedChoiceBanner(
          key: const ValueKey('saved-choice-banner'),
          deviceId: deviceId,
          chosen: outcome.chosen!,
        ),
      // Which spec is driving this screen, when the app worked it out on its
      // own. The scan list stated a device's name and type before the tap;
      // arriving here and finding neither — just controls, appearing — leaves
      // the user to infer what the app decided and no way to check it. The
      // banner above already answers this for a spec the user picked.
      if (outcome != null && outcome.source == SpecChoiceSource.auto)
        _MatchedSpecHeader(
          key: const ValueKey('matched-spec-header'),
          chosen: outcome.chosen!,
        ),
      if (match != null && match.spec.imageUpload != null)
        LedImageWidget(
          key: const ValueKey('led-image-editor'),
          deviceId: deviceId,
          imageUpload: match.spec.imageUpload!,
          specYaml: match.yaml,
        ),
      // A treadmill gets its transport-and-speed card above everything else:
      // the per-characteristic command widgets below expose the same commands,
      // but start/stop on a moving belt should not require finding the right
      // characteristic first. The card decides for itself whether the matched
      // spec resolves any verbs and renders nothing when it does not.
      if (match != null &&
          DeviceCategory.parse(match.spec.category) == DeviceCategory.treadmill)
        TreadmillControlCard(
          key: const ValueKey('treadmill-control-card'),
          deviceId: deviceId,
          specYaml: match.yaml,
          spec: match.spec,
          services: services,
        ),
      if (controls.isNotEmpty)
        _ControlsSection(
          key: const ValueKey('controls-section'),
          deviceId: deviceId,
          controls: controls,
          specYaml: match!.yaml,
        ),
      if (readings.isNotEmpty)
        _ReadingsSection(
          key: const ValueKey('readings-section'),
          deviceId: deviceId,
          readings: readings,
          specYaml: match!.yaml,
        ),
    ];

    // The keys above are only half the job. A lazy builder's delegate has no
    // way back from a key to an index unless it is given one, so it still
    // reconciles strictly per-index: at index i the old child holds
    // `service:B` and the new one wants `service:A`, `Widget.canUpdate` is
    // false, and the element is torn down and re-inflated rather than carried
    // across. That is not a cosmetic rebuild here. Every notify-capable
    // characteristic subscribes in `initState` and unsubscribes in `dispose`;
    // the incoming element's `setNotifyValue(true)` runs during the rebuild
    // and the outgoing one's `setNotifyValue(false)` in `finalizeTree` later
    // in the same frame, against the same characteristic, with no reference
    // counting between them. When the disable lands last that characteristic
    // goes quiet for the rest of the session. And `leading.length` changes on
    // essentially every connect: the match provider is `AsyncLoading` for the
    // first frame, so the list starts empty and grows a slot a microtask
    // later. It also throws away whatever the user had typed into a raw write
    // field. `findChildIndexCallback` closes that: the delegate looks the key
    // up, finds the child at its new index, and updates it in place.
    final childIndexByKey = <Key, int>{
      for (var i = 0; i < leading.length; i++)
        if (leading[i].key case final key?) key: i,
      // The index is part of the key, not just the value. GATT permits a
      // peripheral to expose several instances of one service UUID, and a
      // UUID-only key made those instances collide: two children built with
      // the same key, and a map that kept only the last of them — so
      // `findChildIndexCallback` handed both cards the same index and the
      // per-index reconciliation this callback exists to prevent came
      // straight back.
      for (var i = 0; i < services.length; i++)
        ValueKey('service:$i:${normalizeUuid(services[i].uuid)}'):
            i + leading.length,
    };

    return ListView.builder(
      padding: const EdgeInsets.all(8),
      itemCount: services.length + leading.length,
      findChildIndexCallback: (key) => childIndexByKey[key],
      itemBuilder: (context, index) {
        if (index < leading.length) return leading[index];
        // Keyed on the service's own position, NOT the list index: the list
        // index shifts by `leading.length` as slots appear and disappear, and
        // a key that shifts with it is not a key — it remounts the very cards
        // findChildIndexCallback exists to carry across.
        final position = index - leading.length;
        final service = services[position];
        return _ServiceCard(
          key: ValueKey('service:$position:${normalizeUuid(service.uuid)}'),
          deviceId: deviceId,
          service: service,
          matched: match,
          registry: registry,
          foldedForReadings: foldRawServices,
        );
      },
    );
  }
}

/// Fire off a spec-choice write, logging rather than throwing if the store
/// cannot take it.
///
/// Both `choose` and `clear` await `SharedPreferences.setString`, which throws
/// on a platform-channel or storage failure. Dropped, that surfaces as an
/// unhandled async error — a red screen in debug, a stray `FlutterError` log in
/// release — while the chooser sits there as if nothing happened. The choice is
/// a convenience, not the point of the screen: the controls the user picked
/// still render for this session, they simply will not be remembered. Same
/// shape as the `savedDevicesProvider` write in `device_screen.dart`.
void _remember(Future<void> write, String deviceId) {
  unawaited(write.catchError((Object e) {
    Log.spec.warning('could not save the spec choice for $deviceId', error: e);
  }));
}

/// Names the spec the app matched this device to, and what kind of device that
/// makes it.
///
/// Same icon and same wording as the scan list, now backed by the device's real
/// GATT database rather than an advertisement — this is where the row's claim
/// gets kept.
class _MatchedSpecHeader extends StatelessWidget {
  final MatchedSpec chosen;

  const _MatchedSpecHeader({super.key, required this.chosen});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final category = DeviceCategory.parse(chosen.spec.category);

    return Card(
      margin: const EdgeInsets.fromLTRB(8, 8, 8, 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: scheme.secondaryContainer,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                category?.icon ?? unknownDeviceIcon,
                color: scheme.onSecondaryContainer,
                size: 20,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    chosen.spec.deviceName,
                    style:
                        text.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    // Reads as a plain noun beside the maker, e.g.
                    // "Light · Govee". A spec predating `category` gets the
                    // manufacturer alone rather than a placeholder that says
                    // nothing.
                    [
                      if (category != null) category.label,
                      chosen.spec.manufacturer,
                    ].join(' · '),
                    style: text.bodySmall
                        ?.copyWith(color: scheme.onSurfaceVariant),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Shows that this device's controls come from a spec the user picked, with
/// the way to change it.
///
/// Without this, a saved choice is invisible — the panel simply renders the
/// chosen spec's controls, indistinguishable from a confident automatic
/// match — so a wrong pick would be permanent with nothing to revisit.
/// Clearing the stored choice re-runs matching in place: if the candidates
/// still tie, the chooser card returns; if matching has since become
/// unambiguous, the automatic winner takes over and this banner disappears.
class _SavedChoiceBanner extends ConsumerWidget {
  final String deviceId;
  final MatchedSpec chosen;

  const _SavedChoiceBanner(
      {super.key, required this.deviceId, required this.chosen});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    return Card(
      margin: const EdgeInsets.fromLTRB(8, 8, 8, 12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
        child: Row(
          children: [
            Icon(Icons.bookmark_outlined, size: 20, color: scheme.secondary),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    chosen.spec.deviceName,
                    style:
                        text.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    'Device type you picked',
                    style: text.bodySmall
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            TextButton(
              style: TextButton.styleFrom(minimumSize: const Size(0, 44)),
              onPressed: () => _remember(
                  ref.read(specChoicesProvider.notifier).clear(deviceId),
                  deviceId),
              child: const Text('Change'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Asks the user which spec a device is when ranking cannot decide.
///
/// White-label hardware is why this state exists at all: several brands ship
/// the same GATT platform (identical service UUIDs), each with its own spec.
/// Guessing silently would pin another brand's name — and possibly command
/// set — to the device with nothing telling the user. The choice is stored
/// per device id ([specChoicesProvider]) and honored on future connections;
/// the raw GATT browser stays available below while the question is open.
class _SpecChoicePrompt extends ConsumerWidget {
  final String deviceId;
  final List<MatchedSpec> candidates;

  const _SpecChoicePrompt(
      {super.key, required this.deviceId, required this.candidates});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    return Card(
      margin: const EdgeInsets.fromLTRB(8, 8, 8, 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.help_outline, color: scheme.secondary),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Which device is this?',
                    style:
                        text.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              '${candidates.length} device types match equally well — they '
              'share the same Bluetooth services. Pick one to get named '
              'controls; your choice is remembered for this device.',
              style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 12),
            for (final candidate in candidates)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: SizedBox(
                  width: double.infinity,
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(0, 44),
                      alignment: Alignment.centerLeft,
                    ),
                    onPressed: () => _remember(
                        ref
                            .read(specChoicesProvider.notifier)
                            .choose(deviceId, specKeyFor(candidate.spec)),
                        deviceId),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(candidate.spec.deviceName),
                        Text(
                          candidate.spec.manufacturer,
                          style: text.bodySmall
                              ?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Spec-declared readings, shown above the raw GATT services.
///
/// These come straight from the spec's `entities:` block, so a device gains a
/// named, unit-labelled reading purely by its spec being vendored — no
/// per-device code. `binary_sensor` entities get the on/off presentation;
/// everything else the numeric one.
///
/// Two or more numeric readings render as a grid of compact tiles rather than
/// a scroll of full-width banners: a sensor device is its dashboard, and an
/// Airthings' radon, CO₂, VOC, temperature, humidity and battery should be
/// one glance, not six swipes. A lone reading keeps the roomier row, and
/// binary sensors keep their full-width on/off presentation below the grid —
/// a state line, not a measurement tile.
class _ReadingsSection extends StatelessWidget {
  final String deviceId;
  final List<({EntityDto entity, String serviceUuid})> readings;
  final String specYaml;

  const _ReadingsSection({
    super.key,
    required this.deviceId,
    required this.readings,
    required this.specYaml,
  });

  /// Tiles narrower than this stop fitting a reading and its unit.
  static const double _minTileWidth = 170;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final numeric = [
      for (final r in readings)
        if (r.entity.platform != 'binary_sensor') r,
    ];
    final binary = [
      for (final r in readings)
        if (r.entity.platform == 'binary_sensor') r,
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Readings',
            style: text.titleSmall?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 10),
          if (numeric.length == 1)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: EntitySensorCard(
                deviceId: deviceId,
                serviceUuid: numeric.single.serviceUuid,
                entity: numeric.single.entity,
                specYaml: specYaml,
              ),
            )
          else if (numeric.length > 1)
            LayoutBuilder(
              builder: (context, constraints) =>
                  _grid(numeric, constraints.maxWidth),
            ),
          for (final reading in binary) ...[
            BinarySensorCard(
              deviceId: deviceId,
              serviceUuid: reading.serviceUuid,
              entity: reading.entity,
              specYaml: specYaml,
            ),
            const SizedBox(height: 10),
          ],
        ],
      ),
    );
  }

  Widget _grid(
    List<({EntityDto entity, String serviceUuid})> numeric,
    double maxWidth,
  ) {
    // As many columns as keep every tile at least [_minTileWidth] wide,
    // capped at three — past that a reading gets smaller than its label.
    // A width too narrow for two tiles falls back to full-width rows.
    final fit = maxWidth.isFinite ? maxWidth ~/ _minTileWidth : 1;
    final columns = fit.clamp(1, 3);
    return Column(
      children: [
        for (var row = 0; row < numeric.length; row += columns)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            // IntrinsicHeight + stretch gives every tile in a row the height
            // of its tallest sibling, so a tile whose value is still loading
            // does not sit shorter than a settled neighbour.
            child: IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var i = row; i < row + columns; i++) ...[
                    if (i > row) const SizedBox(width: 10),
                    Expanded(
                      child: i < numeric.length
                          ? EntitySensorCard(
                              deviceId: deviceId,
                              serviceUuid: numeric[i].serviceUuid,
                              entity: numeric[i].entity,
                              specYaml: specYaml,
                              compact: columns > 1,
                            )
                          // Keeps a short last row's tiles the same width as
                          // every other row's.
                          : const SizedBox.shrink(),
                    ),
                  ],
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// Spec-declared controls (switches, lights), shown above the readings.
///
/// Same payoff as the readings section, for the write direction: the spec's
/// resolved actions become working toggles, sliders and color pickers with no
/// per-device code.
class _ControlsSection extends StatelessWidget {
  final String deviceId;
  final List<({EntityDto entity, String? stateServiceUuid})> controls;
  final String specYaml;

  const _ControlsSection({
    super.key,
    required this.deviceId,
    required this.controls,
    required this.specYaml,
  });

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Controls',
            style: text.titleSmall?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 10),
          for (final control in controls) ...[
            switch (control.entity.platform) {
              'light' => LightControlCard(
                  deviceId: deviceId,
                  stateServiceUuid: control.stateServiceUuid,
                  entity: control.entity,
                  specYaml: specYaml,
                ),
              'number' || 'climate' => SetpointControlCard(
                  deviceId: deviceId,
                  stateServiceUuid: control.stateServiceUuid,
                  entity: control.entity,
                  specYaml: specYaml,
                ),
              _ => SwitchControlCard(
                  deviceId: deviceId,
                  stateServiceUuid: control.stateServiceUuid,
                  entity: control.entity,
                  specYaml: specYaml,
                ),
            },
            const SizedBox(height: 10),
          ],
        ],
      ),
    );
  }
}

class _ServiceCard extends StatefulWidget {
  final String deviceId;
  final BleDiscoveredService service;
  final MatchedSpec? matched;

  /// The vendored Bluetooth SIG registry, for naming standard services the
  /// matched spec does not describe. `AsyncValue` because it is indexed once
  /// on a background load: until it lands the card shows the bare UUID, which
  /// is what it showed for every unlisted service before.
  final AsyncValue<NumberRegistry> registry;

  /// Whether this card should sit folded because spec-declared readings own
  /// the screen (a matched sensor device). See the panel's `foldRawServices`.
  final bool foldedForReadings;

  const _ServiceCard({
    super.key,
    required this.deviceId,
    required this.service,
    required this.matched,
    required this.registry,
    required this.foldedForReadings,
  });

  @override
  State<_ServiceCard> createState() => _ServiceCardState();
}

class _ServiceCardState extends State<_ServiceCard> {
  /// Owned here, not left to the tile: `initiallyExpanded` only speaks at
  /// mount, and on essentially every connect the cards mount a frame before
  /// the spec match resolves — so a sensor device's cards would mount
  /// expanded and stay that way, and the fold would never happen.
  final ExpansibleController _expansion = ExpansibleController();

  @override
  void didUpdateWidget(_ServiceCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Fold exactly on the transition into readings-own-the-screen, so a user
    // who reopens a card afterwards is not fought. The reverse transition
    // (a cleared spec choice) deliberately leaves cards as they are: closed
    // but tappable is still usable, while auto-expanding would yank open
    // cards the user folded personally.
    if (widget.foldedForReadings && !oldWidget.foldedForReadings) {
      // After this frame, not during it: controller methods rebuild the
      // tile, which is not legal from inside the tree's own rebuild.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _expansion.isExpanded) _expansion.collapse();
      });
    }
  }

  @override
  void dispose() {
    _expansion.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final matched = widget.matched;
    final service = widget.service;
    final specService =
        matched == null ? null : findServiceForUuid(matched.spec, service.uuid);

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: ExpansionTile(
        controller: _expansion,
        leading: const Icon(Icons.account_tree),
        title: Text(
          specService?.name ?? _serviceDisplayName(service.uuid),
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        subtitle: Text(
          service.uuid,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
        ),
        initiallyExpanded: !widget.foldedForReadings,
        // Collapsing must hide the children, never dispose them. Notify-capable
        // characteristic widgets subscribe in initState and cancel in dispose,
        // and RealBleService answers a cancel with setNotifyValue(false) on the
        // peripheral — with no reference counting. The readings cards above
        // this tile subscribe to the SAME characteristics, so a disposal here
        // (the automatic fold, or a user collapsing a card by hand) would mute
        // the very characteristics the dashboard is showing live: every
        // notify-driven tile silently freezes at its first read. Keeping the
        // children mounted offstage preserves their subscriptions — the same
        // steady state the always-expanded panel had before folding existed.
        maintainState: true,
        children: service.characteristics.map((char) {
          final specChar = specService == null
              ? null
              : findCharForUuid(specService, char.uuid);
          if (matched != null && specChar != null) {
            return TypedCharacteristicWidget(
              deviceId: widget.deviceId,
              serviceUuid: service.uuid,
              specYaml: matched.yaml,
              specChar: specChar,
              discovered: char,
            );
          }
          return RawCharacteristicWidget(
            deviceId: widget.deviceId,
            serviceUuid: service.uuid,
            characteristic: char,
          );
        }).toList(),
      ),
    );
  }

  /// What to call a service the matched spec does not name.
  ///
  /// Read from the vendored Bluetooth SIG registry rather than a hardcoded
  /// switch. The switch knew four assigned numbers; the registry — already
  /// bundled, already indexed, and already what the scan list names services
  /// from — knows every one the SIG has published, so a Heart Rate or Human
  /// Interface Device service stops rendering as the anonymous "Service".
  ///
  /// The registry answers in the same vocabulary either UUID spelling folds
  /// to, so both the spec's 128-bit form and flutter_blue_plus's short form
  /// resolve. A vendor's own 128-bit UUID is in no registry and keeps the
  /// generic label — there is nothing true to say about it here, which is the
  /// spec matcher's job one level up.
  ///
  /// The registry is an async asset load, so before it resolves — and if it
  /// ever fails to — the four names the old switch guaranteed still hold via
  /// the compiled-in fallback: a Battery Service card must never render as
  /// the anonymous "Service" just because an asset read lost a race.
  String _serviceDisplayName(String uuid) =>
      widget.registry.valueOrNull?.serviceName(uuid) ??
      _compiledInServiceNames[shortUuid(uuid)] ??
      'Service';
}

/// The service names the panel guaranteed synchronously before the registry
/// existed, kept as the fallback for the registry's loading/error states.
const Map<String, String> _compiledInServiceNames = {
  '180f': 'Battery Service',
  '1800': 'Generic Access',
  '1801': 'Generic Attribute',
  '181a': 'Environmental Sensing',
};
