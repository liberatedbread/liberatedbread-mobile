// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/spec_pack_provider.dart';
import '../services/spec_pack_service.dart';
import '../core/error_text.dart';

/// Install and manage downloadable device-spec packs.
///
/// Shows the (editable, validated) manifest URL, an Install/Refresh action with
/// loading + success/error states, and the list of installed packs with a
/// per-pack remove and a clear-all action.
class SpecPackSettingsScreen extends ConsumerStatefulWidget {
  const SpecPackSettingsScreen({super.key});

  @override
  ConsumerState<SpecPackSettingsScreen> createState() =>
      _SpecPackSettingsScreenState();
}

class _SpecPackSettingsScreenState
    extends ConsumerState<SpecPackSettingsScreen> {
  final _urlController = TextEditingController();
  bool _seeded = false;
  bool _busy = false;
  String? _errorMessage;
  String? _successMessage;

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Seed the URL field once, when the persisted value first resolves.
    final urlAsync = ref.watch(specPackUrlProvider);
    if (!_seeded && urlAsync.hasValue) {
      _urlController.text = urlAsync.requireValue;
      _seeded = true;
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Device Spec Packs'),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_sweep_outlined),
            tooltip: 'Clear all packs',
            onPressed: _busy ? null : _confirmClearAll,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'Install a pack of device specs from a URL so new device support '
            'arrives without an app update. The URL points at a JSON manifest '
            'listing the spec files to download.',
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _urlController,
            enabled: !_busy,
            keyboardType: TextInputType.url,
            autocorrect: false,
            onChanged: (_) => setState(() {
              _errorMessage = null;
              _successMessage = null;
            }),
            decoration: const InputDecoration(
              labelText: 'Pack manifest URL',
              hintText: 'https://example.com/pack.json',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: _busy ? null : _install,
                  icon: _busy
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.download),
                  label: Text(_busy ? 'Installing...' : 'Install / Refresh'),
                ),
              ),
              const SizedBox(width: 8),
              TextButton(
                onPressed: _busy ? null : _resetUrl,
                child: const Text('Reset URL'),
              ),
            ],
          ),
          if (_errorMessage != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(_errorMessage!,
                  style: const TextStyle(color: Colors.red)),
            ),
          if (_successMessage != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(_successMessage!,
                  style: TextStyle(color: Colors.green.shade700)),
            ),
          const Divider(height: 32),
          Text('Installed packs',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          _buildPackList(),
        ],
      ),
    );
  }

  Widget _buildPackList() {
    final packsAsync = ref.watch(installedSpecPacksProvider);
    return packsAsync.when(
      loading: () => const Padding(
        padding: EdgeInsets.all(24),
        child: Center(child: CircularProgressIndicator()),
      ),
      error: (e, _) => Text(
          friendlyErrorText(e,
              context: 'list installed packs',
              fallback: 'Could not read the installed packs.'),
          style: const TextStyle(color: Colors.red)),
      data: (packs) {
        if (packs.isEmpty) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Text('No packs installed yet.',
                style: TextStyle(color: Colors.grey)),
          );
        }
        return Column(
          children: [
            for (final pack in packs)
              Card(
                child: ListTile(
                  title: Text('${pack.name}  ·  v${pack.version}'),
                  subtitle: Text(
                    '${pack.specCount} '
                    '${pack.specCount == 1 ? 'spec' : 'specs'} · updated '
                    '${_formatDate(pack.installedAt)}',
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.refresh),
                        tooltip: 'Update pack from its source',
                        onPressed: _busy ? null : () => _refreshPack(pack),
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete_outline),
                        tooltip: 'Remove pack',
                        onPressed: _busy ? null : () => _removePack(pack),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  Future<void> _install() async {
    final url = _urlController.text.trim();
    if (!SpecPackService.isValidManifestUrl(url)) {
      setState(() {
        _errorMessage = 'Enter a valid http:// or https:// URL.';
        _successMessage = null;
      });
      return;
    }
    setState(() {
      _busy = true;
      _errorMessage = null;
      _successMessage = null;
    });
    try {
      // Persist the URL so it survives even if the download fails.
      await ref.read(specPackUrlProvider.notifier).setUrl(url);
      // mounted check before touching ref again: ConsumerState.ref throws a
      // StateError once the screen is disposed.
      if (!mounted) return;
      final result = await ref.read(specPackServiceProvider).install(url);
      if (!mounted) return;
      switch (result) {
        case InstallOk(:final pack, :final partialFailures):
          ref.invalidate(installedSpecPacksProvider);
          ref.invalidate(cachedSpecPacksProvider);
          final base =
              'Installed "${pack.name}" v${pack.version} (${pack.specCount} '
              '${pack.specCount == 1 ? 'spec' : 'specs'}).';
          setState(() => _successMessage = partialFailures.isEmpty
              ? base
              : '$base ${partialFailures.length} file(s) were skipped.');
        case InstallFailed(:final error):
          setState(() => _errorMessage = _friendlyError(error));
      }
    } catch (e) {
      if (mounted) {
        setState(() => _errorMessage = friendlyErrorText(
              e,
              context: 'install spec pack',
              fallback: 'Something went wrong installing that pack.',
            ));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _resetUrl() async {
    await ref.read(specPackUrlProvider.notifier).resetToDefault();
    // mounted before the ref.read: ConsumerState.ref throws after dispose.
    if (!mounted) return;
    final url = ref.read(specPackUrlProvider).valueOrNull;
    setState(() {
      if (url != null) _urlController.text = url;
      _errorMessage = null;
      _successMessage = null;
    });
  }

  Future<void> _removePack(SpecPack pack) async {
    setState(() {
      _busy = true;
      _errorMessage = null;
      _successMessage = null;
    });
    try {
      await ref.read(specPackServiceProvider).removePack(pack.name);
      if (!mounted) return;
      ref.invalidate(installedSpecPacksProvider);
      ref.invalidate(cachedSpecPacksProvider);
      setState(() => _successMessage = 'Removed "${pack.name}".');
    } catch (e) {
      if (mounted) {
        setState(() => _errorMessage = friendlyErrorText(
              e,
              context: 'remove pack ${pack.name}',
              fallback: 'Could not remove "${pack.name}".',
            ));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Re-download a pack from its own stored source URL, so an updated remote
  /// pack can be pulled without re-typing the URL into the global field.
  Future<void> _refreshPack(SpecPack pack) async {
    final url = pack.sourceUrl;
    if (!SpecPackService.isValidManifestUrl(url)) {
      setState(() {
        _errorMessage = 'This pack has no valid source URL to update from.';
        _successMessage = null;
      });
      return;
    }
    setState(() {
      _busy = true;
      _errorMessage = null;
      _successMessage = null;
    });
    try {
      final result = await ref.read(specPackServiceProvider).refresh(url);
      if (!mounted) return;
      switch (result) {
        case InstallOk(:final pack, :final partialFailures):
          ref.invalidate(installedSpecPacksProvider);
          ref.invalidate(cachedSpecPacksProvider);
          final base =
              'Updated "${pack.name}" v${pack.version} (${pack.specCount} '
              '${pack.specCount == 1 ? 'spec' : 'specs'}).';
          setState(() => _successMessage = partialFailures.isEmpty
              ? base
              : '$base ${partialFailures.length} file(s) were skipped.');
        case InstallFailed(:final error):
          setState(() => _errorMessage = _friendlyError(error));
      }
    } catch (e) {
      if (mounted) {
        setState(() => _errorMessage = friendlyErrorText(
              e,
              context: 'refresh spec pack',
              fallback: 'Something went wrong updating that pack.',
            ));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _confirmClearAll() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear all packs?'),
        content: const Text(
            'This removes every downloaded spec pack from this device. Bundled '
            'device specs are unaffected. You can reinstall from the URL later.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Clear all'),
          ),
        ],
      ),
    );
    // mounted before the ref.read: ConsumerState.ref throws after dispose.
    if (confirmed != true || !mounted) return;
    await ref.read(specPackServiceProvider).clearCache();
    if (!mounted) return;
    ref.invalidate(installedSpecPacksProvider);
    ref.invalidate(cachedSpecPacksProvider);
    setState(() {
      _successMessage = 'Cleared all installed packs.';
      _errorMessage = null;
    });
  }

  String _friendlyError(SpecPackError error) {
    return switch (error.kind) {
      SpecPackErrorKind.invalidUrl => 'Enter a valid http:// or https:// URL.',
      SpecPackErrorKind.timeout =>
        'The download timed out. Check your connection and try again.',
      SpecPackErrorKind.network =>
        'Could not reach the server. Check the URL and your connection.',
      SpecPackErrorKind.http =>
        'The server rejected the request (${error.message}).',
      SpecPackErrorKind.malformedManifest =>
        'That URL did not return a valid spec-pack manifest.',
      SpecPackErrorKind.tooLarge =>
        'The pack is larger than allowed and was not installed.',
      SpecPackErrorKind.noSpecsInstalled =>
        'None of the specs could be downloaded.',
      SpecPackErrorKind.cacheIo => error.message,
    };
  }

  static String _formatDate(DateTime dt) {
    final local = dt.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}';
  }
}
