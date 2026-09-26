// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// Say where you are; get channels worth programming.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/error_text.dart';
import '../core/geo.dart';
import '../core/maidenhead.dart';
import '../models/channel_plan.dart';
import '../models/radio_profile.dart';
import '../models/suggested_channel.dart';
import '../providers/channel_plan_provider.dart';
import '../providers/location_provider.dart';
import '../providers/radio_bundled_data_provider.dart';
import '../providers/radio_profile_provider.dart';
import '../providers/radio_source_settings_provider.dart';
import '../providers/radio_suggestion_provider.dart';
import '../services/channel_suggestion_service.dart';
import '../services/repeater_source.dart';
import '../services/us_state_resolver.dart';
import '../widgets/suggested_channel_card.dart';
import 'radio_source_settings_screen.dart';

class RadioSuggestionScreen extends ConsumerStatefulWidget {
  final RadioProfile profile;

  const RadioSuggestionScreen({super.key, required this.profile});

  @override
  ConsumerState<RadioSuggestionScreen> createState() =>
      _RadioSuggestionScreenState();
}

class _RadioSuggestionScreenState extends ConsumerState<RadioSuggestionScreen> {
  SavedLocation? _location;
  bool _locating = false;
  String? _locationError;

  /// Set once the user asks to search, so the screen does not fetch anything
  /// merely because it was opened.
  SuggestionRequest? _request;

  final Set<String> _selected = {};

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(radioSourceSettingsProvider).value;
    final remembered = ref.watch(lastLocationProvider).value;
    final location = _location ?? remembered;

    return Scaffold(
      appBar: AppBar(title: const Text('Suggest channels')),
      body: ListView(
        children: [
          _locationSection(location),
          const Divider(height: 24),
          if (settings != null) _radiusSection(settings),
          const Divider(height: 24),
          if (location != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: FilledButton.icon(
                onPressed: settings == null
                    ? null
                    : () => _search(location, settings),
                icon: const Icon(Icons.search),
                label: const Text('Find channels'),
              ),
            ),
          if (_request case final SuggestionRequest request)
            ..._results(request),
          const SizedBox(height: 96),
        ],
      ),
      bottomNavigationBar: _selected.isEmpty ? null : _addBar(),
    );
  }

  // --- location -----------------------------------------------------------

  Widget _locationSection(SavedLocation? location) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      ListTile(
        leading: const Icon(Icons.place_outlined),
        title: Text(location?.label ?? 'Where are you?'),
        subtitle: Text(
          location == null
              ? 'Use your position, or enter it by hand.'
              : '${location.point.lat.toStringAsFixed(4)}, '
                    '${location.point.lon.toStringAsFixed(4)}',
        ),
      ),
      if (_locationError case final String error)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text(
            error,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.tonalIcon(
              onPressed: _locating ? null : _useGps,
              icon: _locating
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.my_location),
              label: Text(_locating ? 'Locating…' : 'Use my location'),
            ),
            OutlinedButton.icon(
              onPressed: _enterByHand,
              icon: const Icon(Icons.edit_location_alt_outlined),
              label: const Text('Enter by hand'),
            ),
          ],
        ),
      ),
    ],
  );

  Future<void> _useGps() async {
    final service = ref.read(locationServiceProvider);
    setState(() {
      _locating = true;
      _locationError = null;
    });
    try {
      final point = await service.currentPosition();
      await _remember(point);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _locationError = friendlyErrorText(
          error,
          fallback: 'Could not get your position. Enter it by hand instead.',
          context: 'radio suggestion location',
        );
      });
    } finally {
      if (mounted) setState(() => _locating = false);
    }
  }

  /// Name the position by the state it falls in, so the remembered location
  /// reads as somewhere rather than as two numbers.
  Future<void> _remember(GeoPoint point) async {
    final bundled = ref.read(radioBundledDataProvider);
    final notifier = ref.read(lastLocationProvider.notifier);
    final state = await stateContaining(bundled, point);
    final grid = pointToMaidenhead(point);
    final label = state?.name ?? grid ?? 'Manual position';
    final saved = SavedLocation(point: point, label: label);

    await notifier.remember(saved);
    if (!mounted) return;
    setState(() {
      _location = saved;
      _locationError = null;
      // A new position invalidates the results that were on screen.
      _request = null;
      _selected.clear();
    });
  }

  Future<void> _enterByHand() async {
    final point = await showDialog<GeoPoint>(
      context: context,
      builder: (context) => const _ManualLocationDialog(),
    );
    if (point != null) await _remember(point);
  }

  // --- radius -------------------------------------------------------------

  Widget _radiusSection(RadioSourceSettings settings) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      ListTile(
        leading: const Icon(Icons.radar_outlined),
        title: const Text('Search radius'),
        subtitle: Text('${settings.radiusKm.round()} km'),
        trailing: IconButton(
          tooltip: 'Repeater sources',
          icon: const Icon(Icons.tune),
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => const RadioSourceSettingsScreen(),
            ),
          ),
        ),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Wrap(
          spacing: 8,
          children: [
            for (final radius in RadioSourceSettings.radiusChoices)
              ChoiceChip(
                label: Text('${radius.round()} km'),
                selected: settings.radiusKm == radius,
                onSelected: (_) {
                  ref
                      .read(radioSourceSettingsProvider.notifier)
                      .setRadiusKm(radius);
                  setState(() {
                    _request = null;
                    _selected.clear();
                  });
                },
              ),
          ],
        ),
      ),
    ],
  );

  void _search(SavedLocation location, RadioSourceSettings settings) {
    final sources = ref.read(repeaterSourcesProvider);
    setState(() {
      _selected.clear();
      _request = SuggestionRequest(
        where: location.point,
        radiusKm: settings.radiusKm,
        profile: widget.profile,
        enabledSourceIds: {
          for (final source in sources)
            if (settings.isEnabled(source.id)) source.id,
        },
        txUnlockEnabled: ref.read(txUnlockEnabledProvider),
      );
    });
  }

  // --- results ------------------------------------------------------------

  List<Widget> _results(SuggestionRequest request) {
    final async = ref.watch(radioSuggestionProvider(request));
    return async.when(
      loading: () => const [
        Padding(
          padding: EdgeInsets.all(32),
          child: Center(child: CircularProgressIndicator()),
        ),
      ],
      error: (error, _) => [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            friendlyErrorText(
              error,
              fallback: 'Could not put a list together.',
              context: 'radio suggestions',
            ),
          ),
        ),
      ],
      data: (result) => _resultBody(result),
    );
  }

  List<Widget> _resultBody(SuggestionResult result) {
    final sources = ref.read(repeaterSourcesProvider);
    return [
      for (final failure in result.sourceFailures)
        _FailureTile(
          failure: failure,
          onFix: failure.isActionable
              ? () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const RadioSourceSettingsScreen(),
                  ),
                )
              : null,
        ),
      if (result.usedStaleCache)
        const ListTile(
          leading: Icon(Icons.history_outlined),
          title: Text('Showing saved listings'),
          subtitle: Text(
            'A directory could not be reached, so results include a copy '
            'kept on this device. It may be out of date.',
          ),
        ),
      for (final category in categoryOrderFor(widget.profile))
        ..._categorySection(category, result.forCategory(category)),
      for (final line in result.attributionsFor(sources))
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Text(line, style: Theme.of(context).textTheme.bodySmall),
        ),
    ];
  }

  List<Widget> _categorySection(
    SuggestionCategory category,
    List<SuggestedChannel> channels,
  ) {
    if (channels.isEmpty) return const [];
    final keys = [for (final channel in channels) _keyFor(channel)];
    final allSelected = keys.every(_selected.contains);

    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 8, 0),
        child: Row(
          children: [
            Expanded(
              child: Text(
                '${category.label} (${channels.length})',
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
              ),
            ),
            TextButton(
              onPressed: () => setState(() {
                if (allSelected) {
                  _selected.removeAll(keys);
                } else {
                  _selected.addAll(keys);
                }
              }),
              child: Text(allSelected ? 'None' : 'All'),
            ),
          ],
        ),
      ),
      for (final channel in channels)
        SuggestedChannelTile(
          suggestion: channel,
          selected: _selected.contains(_keyFor(channel)),
          onSelected: (value) => setState(() {
            if (value) {
              _selected.add(_keyFor(channel));
            } else {
              _selected.remove(_keyFor(channel));
            }
          }),
        ),
    ];
  }

  /// Identity for selection. Includes the category because a frequency can
  /// legitimately appear in two of them -- a GMRS main channel is both a
  /// simplex preset and a repeater output.
  static String _keyFor(SuggestedChannel channel) =>
      '${channel.category.name}/${channel.dedupeKey}/${channel.channel.name}';

  // --- adding to a plan ---------------------------------------------------

  Widget _addBar() => SafeArea(
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: FilledButton.icon(
        onPressed: _addSelected,
        icon: const Icon(Icons.playlist_add),
        label: Text(
          'Add ${_selected.length} '
          '${_selected.length == 1 ? 'channel' : 'channels'}',
        ),
      ),
    ),
  );

  Future<void> _addSelected() async {
    final request = _request;
    if (request == null || _selected.isEmpty) return;

    final messenger = ScaffoldMessenger.of(context);
    final plansNotifier = ref.read(channelPlansProvider.notifier);
    final result = ref.read(radioSuggestionProvider(request)).value;
    if (result == null) return;

    final chosen = [
      for (final category in SuggestionCategory.values)
        for (final channel in result.forCategory(category))
          if (_selected.contains(_keyFor(channel))) channel,
    ];
    if (chosen.isEmpty) return;

    final plan = await _pickPlan();
    if (plan == null || !mounted) return;

    final outcome = await plansNotifier.appendChannels(
      plan.id,
      [for (final channel in chosen) channel.channelForPlan],
      profile: widget.profile,
      builtWithTxUnlock: chosen.any((c) => c.requiresTxUnlock),
    );
    if (!mounted) return;

    setState(_selected.clear);
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          outcome.hitCapacity
              ? 'Added ${outcome.added} to "${plan.name}". '
                    '${outcome.rejected} did not fit — '
                    '${widget.profile.displayName} holds ${outcome.capacity}.'
              : 'Added ${outcome.added} to "${plan.name}".',
        ),
      ),
    );
  }

  /// Choose an existing plan or make one. Returns null if dismissed.
  Future<ChannelPlan?> _pickPlan() async {
    final plans = ref.read(channelPlansProvider);
    final notifier = ref.read(channelPlansProvider.notifier);

    if (plans.isEmpty) {
      return notifier.create(
        name: 'Near ${_location?.label ?? 'me'}',
        radioProfileId: widget.profile.id,
      );
    }

    return showModalBottomSheet<ChannelPlan>(
      context: context,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const ListTile(title: Text('Add to which plan?')),
            for (final plan in plans)
              ListTile(
                leading: const Icon(Icons.list_alt_outlined),
                title: Text(plan.name),
                subtitle: Text('${plan.length} channels'),
                onTap: () => Navigator.of(context).pop(plan),
              ),
            ListTile(
              leading: const Icon(Icons.add),
              title: const Text('New plan'),
              onTap: () async {
                final navigator = Navigator.of(context);
                final plan = await notifier.create(
                  name: 'Near ${_location?.label ?? 'me'}',
                  radioProfileId: widget.profile.id,
                );
                navigator.pop(plan);
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _FailureTile extends StatelessWidget {
  final SourceFailure failure;
  final VoidCallback? onFix;

  const _FailureTile({required this.failure, this.onFix});

  @override
  Widget build(BuildContext context) => ListTile(
    leading: Icon(
      failure.isActionable ? Icons.settings_outlined : Icons.cloud_off_outlined,
    ),
    title: Text(failure.displayName),
    subtitle: Text(failure.message),
    trailing: onFix == null
        ? null
        : TextButton(onPressed: onFix, child: const Text('Set up')),
    onTap: onFix,
  );
}

/// Latitude and longitude, or a grid square — whichever the operator has.
class _ManualLocationDialog extends StatefulWidget {
  const _ManualLocationDialog();

  @override
  State<_ManualLocationDialog> createState() => _ManualLocationDialogState();
}

class _ManualLocationDialogState extends State<_ManualLocationDialog> {
  final _lat = TextEditingController();
  final _lon = TextEditingController();
  final _grid = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _lat.dispose();
    _lon.dispose();
    _grid.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Where are you?'),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _grid,
            decoration: const InputDecoration(
              labelText: 'Grid square',
              hintText: 'FN31pr',
              border: OutlineInputBorder(),
            ),
            autocorrect: false,
            onChanged: (_) => setState(() => _error = null),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Text('or'),
          ),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _lat,
                  decoration: const InputDecoration(
                    labelText: 'Latitude',
                    border: OutlineInputBorder(),
                  ),
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                    signed: true,
                  ),
                  onChanged: (_) => setState(() => _error = null),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: _lon,
                  decoration: const InputDecoration(
                    labelText: 'Longitude',
                    border: OutlineInputBorder(),
                  ),
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                    signed: true,
                  ),
                  onChanged: (_) => setState(() => _error = null),
                ),
              ),
            ],
          ),
          if (_error case final String error)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                error,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      FilledButton(onPressed: _submit, child: const Text('Use this')),
    ],
  );

  void _submit() {
    // The grid square wins when both are filled: it is the more deliberate of
    // the two to have typed.
    final grid = _grid.text.trim();
    if (grid.isNotEmpty) {
      final point = maidenheadToPoint(grid);
      if (point == null) {
        setState(
          () => _error =
              'That is not a grid square. They look like '
              'FN31 or FN31pr.',
        );
        return;
      }
      Navigator.of(context).pop(point);
      return;
    }

    final lat = double.tryParse(_lat.text.trim());
    final lon = double.tryParse(_lon.text.trim());
    if (lat == null || lon == null) {
      setState(() => _error = 'Enter a grid square, or both coordinates.');
      return;
    }
    final point = GeoPoint(lat, lon);
    if (!point.isValid) {
      setState(
        () => _error =
            'Latitude runs -90 to 90 and longitude -180 '
            'to 180.',
      );
      return;
    }
    Navigator.of(context).pop(point);
  }
}
