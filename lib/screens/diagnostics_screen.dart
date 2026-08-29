// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/log.dart';

/// What the app has been saying, on the device it is saying it on.
///
/// [debugPrint] reaches a desktop console and nothing else, which is the wrong
/// place: the failures this app is about — a device that answers discovery and
/// refuses control, a scan that comes back empty on a segment that provably has
/// robots on it — happen on somebody's phone, on their LAN, and every line
/// explaining why has been going nowhere.
///
/// Two halves, deliberately separate. CAPTURE decides what is recorded at all
/// and is a live setting on [Log]; VIEW decides what is shown of it. Turning a
/// category up does not retroactively fill the buffer, so the capture controls
/// are at the top where they are seen before the reading starts.
class DiagnosticsScreen extends StatefulWidget {
  const DiagnosticsScreen({super.key});

  @override
  State<DiagnosticsScreen> createState() => _DiagnosticsScreenState();
}

class _DiagnosticsScreenState extends State<DiagnosticsScreen> {
  /// View filter: hide anything below this. Independent of the capture level —
  /// a reader narrowing to warnings must not stop the app recording debug
  /// lines they may want a moment later.
  LogLevel _showFrom = LogLevel.debug;

  /// View filter: empty means every category.
  final Set<String> _showOnly = {};

  List<LogRecord> get _visible {
    final buffer = Log.buffer;
    if (buffer == null) return const [];
    return buffer.records
        .where((r) => r.level.index >= _showFrom.index)
        .where((r) => _showOnly.isEmpty || _showOnly.contains(r.category))
        // Newest first: this screen is opened right after the thing happened,
        // and the answer is at the end of the log.
        .toList()
        .reversed
        .toList();
  }

  Future<void> _copy() async {
    final buffer = Log.buffer;
    final messenger = ScaffoldMessenger.of(context);
    if (buffer == null) return;
    // What was on screen, not everything: a report of thirty relevant lines
    // gets read and one of five hundred does not.
    final text = buffer.export(
      minLevel: _showFrom,
      categories: _showOnly.isEmpty ? null : _showOnly,
    );
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    messenger.showSnackBar(SnackBar(
      content: Text(text.isEmpty
          ? 'Nothing to copy'
          : 'Copied ${_visible.length} line(s)'),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final records = _visible;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Diagnostics'),
        actions: [
          IconButton(
            icon: const Icon(Icons.copy_all_outlined),
            tooltip: 'Copy for a bug report',
            onPressed: records.isEmpty ? null : _copy,
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Clear',
            onPressed: () => setState(() => Log.buffer?.clear()),
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
            // The buffer fills from every corner of the app and nothing here
            // is listening to it — a pull rather than a stream, because a log
            // view that rebuilt on every record would be its own busiest
            // source of work.
            onPressed: () => setState(() {}),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _CaptureControls(onChanged: () => setState(() {})),
            const Divider(height: 1),
            _ViewControls(
              showFrom: _showFrom,
              showOnly: _showOnly,
              onLevel: (level) => setState(() => _showFrom = level),
              onCategory: (category, selected) => setState(() {
                selected ? _showOnly.add(category) : _showOnly.remove(category);
              }),
            ),
            const Divider(height: 1),
            Expanded(
              child: records.isEmpty
                  ? const _Empty()
                  : ListView.separated(
                      itemCount: records.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (_, i) => _RecordTile(record: records[i]),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// What gets recorded. Live settings on [Log], not view state.
class _CaptureControls extends StatelessWidget {
  final VoidCallback onChanged;

  const _CaptureControls({required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('Capture', style: theme.textTheme.titleSmall),
              const Spacer(),
              DropdownButton<LogLevel>(
                value: Log.minLevel,
                isDense: true,
                onChanged: (level) {
                  if (level == null) return;
                  Log.minLevel = level;
                  onChanged();
                },
                items: [
                  for (final level in LogLevel.values)
                    DropdownMenuItem(value: level, child: Text(level.label)),
                ],
              ),
            ],
          ),
          Text(
            'Tap a category to record its finest detail, whatever the level '
            'above says. Nothing already dropped comes back — turn it up '
            'before reproducing the problem.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              for (final logger in Log.categories)
                FilterChip(
                  label: Text(logger.category),
                  selected: Log.categoryLevel(logger) == LogLevel.debug,
                  onSelected: (selected) {
                    Log.setCategoryLevel(
                        logger, selected ? LogLevel.debug : null);
                    onChanged();
                  },
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// What is shown of what was recorded.
class _ViewControls extends StatelessWidget {
  final LogLevel showFrom;
  final Set<String> showOnly;
  final ValueChanged<LogLevel> onLevel;
  final void Function(String category, bool selected) onCategory;

  const _ViewControls({
    required this.showFrom,
    required this.showOnly,
    required this.onLevel,
    required this.onCategory,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Only the categories actually present, so the filter row describes this
    // session rather than the catalogue of categories.
    final present = {
      for (final r in Log.buffer?.records ?? const <LogRecord>[]) r.category
    }.toList()
      ..sort();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('Show', style: theme.textTheme.titleSmall),
              const Spacer(),
              DropdownButton<LogLevel>(
                value: showFrom,
                isDense: true,
                onChanged: (level) => level == null ? null : onLevel(level),
                items: [
                  for (final level in LogLevel.values)
                    DropdownMenuItem(
                        value: level, child: Text('${level.label} and up')),
                ],
              ),
            ],
          ),
          if (present.isNotEmpty)
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                for (final category in present)
                  FilterChip(
                    label: Text(category),
                    selected: showOnly.contains(category),
                    onSelected: (selected) => onCategory(category, selected),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

class _RecordTile extends StatelessWidget {
  final LogRecord record;

  const _RecordTile({required this.record});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colour = switch (record.level) {
      LogLevel.error => scheme.error,
      LogLevel.warning => scheme.tertiary,
      LogLevel.info => scheme.onSurface,
      LogLevel.debug => scheme.onSurfaceVariant,
    };
    final detail = [
      if (record.error != null) record.error.toString().trimRight(),
      if (record.stackTrace != null) record.stackTrace.toString().trimRight(),
    ].join('\n');
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${formatLogTime(record.time)}  ${record.level.label}  '
            '[${record.category}]',
            style: theme.textTheme.labelSmall?.copyWith(color: colour),
          ),
          const SizedBox(height: 2),
          // Selectable so one line can be lifted out without copying the lot —
          // an address or a device name is often the whole thing someone needs.
          SelectableText(
            record.message,
            style: theme.textTheme.bodySmall?.copyWith(color: colour),
          ),
          if (detail.isNotEmpty) ...[
            const SizedBox(height: 4),
            SelectableText(
              detail,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: scheme.error, fontFamily: 'monospace'),
            ),
          ],
        ],
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final recording = Log.buffer != null;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Text(
          recording
              ? 'Nothing recorded at this level yet. Use the app, then come '
                  'back — or widen the filters above.'
              : 'Log recording is off in this build.',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium,
        ),
      ),
    );
  }
}
