// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// Where the repeater directories are switched on, and where RepeaterBook's
// token gets set up.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/error_text.dart';
import '../providers/ha_provider.dart' show urlOpenerProvider;
import '../providers/radio_source_settings_provider.dart';
import '../services/repeaterbook_client.dart';

/// Source toggles, search radius, and the RepeaterBook token walkthrough.
class RadioSourceSettingsScreen extends ConsumerStatefulWidget {
  const RadioSourceSettingsScreen({super.key});

  @override
  ConsumerState<RadioSourceSettingsScreen> createState() =>
      _RadioSourceSettingsScreenState();
}

class _RadioSourceSettingsScreenState
    extends ConsumerState<RadioSourceSettingsScreen> {
  late final TextEditingController _token;
  bool _verifying = false;
  TokenCheck? _lastCheck;
  bool _tokenLoaded = false;

  @override
  void initState() {
    super.initState();
    _token = TextEditingController();
  }

  @override
  void dispose() {
    _token.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(radioSourceSettingsProvider);
    final storedToken = ref.watch(repeaterBookTokenProvider);

    // Seed the field once from the keychain, and never again -- re-seeding on
    // every rebuild would fight the user's typing.
    if (!_tokenLoaded && storedToken.hasValue) {
      _tokenLoaded = true;
      _token.text = storedToken.value ?? '';
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Repeater sources')),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          ...settings.when(
            data: _sourceSection,
            loading: () => const [
              Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              ),
            ],
            error: (error, _) => [
              ListTile(
                leading: const Icon(Icons.error_outline),
                title: Text(
                  friendlyErrorText(
                    error,
                    fallback: 'Could not read your source settings.',
                    context: 'radio source settings',
                  ),
                ),
              ),
            ],
          ),
          const Divider(height: 32),
          ..._repeaterBookWalkthrough(storedToken.value),
          const Divider(height: 32),
          _cacheSection(),
        ],
      ),
    );
  }

  List<Widget> _sourceSection(RadioSourceSettings settings) {
    final sources = ref.watch(repeaterSourcesProvider);
    return [
      const Padding(
        padding: EdgeInsets.fromLTRB(16, 8, 16, 4),
        child: Text(
          'Where suggestions come from',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
      ),
      const Padding(
        padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
        child: Text(
          'The standard channels — FRS, GMRS, MURS, the weather channels and '
          'the calling frequencies — are built in and always available, with '
          'or without a network.',
        ),
      ),
      for (final source in sources)
        SwitchListTile(
          title: Text(source.displayName),
          subtitle: Text(switch (source.id) {
            RepeaterBookClient.sourceId =>
              'Amateur repeaters worldwide. Needs a free token — see below.',
            _ => 'GMRS repeaters. No account needed.',
          }),
          value: settings.isEnabled(source.id),
          onChanged: (enabled) => ref
              .read(radioSourceSettingsProvider.notifier)
              .setSourceEnabled(source.id, enabled),
        ),
      ListTile(
        title: const Text('Search radius'),
        subtitle: Text('${settings.radiusKm.round()} km'),
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
                onSelected: (_) => ref
                    .read(radioSourceSettingsProvider.notifier)
                    .setRadiusKm(radius),
              ),
          ],
        ),
      ),
    ];
  }

  /// The four steps: what it is, how to get one, paste and check, and the
  /// attribution their terms require.
  List<Widget> _repeaterBookWalkthrough(String? storedToken) {
    final hasToken = storedToken != null && storedToken.isNotEmpty;
    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
        child: Row(
          children: [
            Expanded(
              child: Text(
                'RepeaterBook access token',
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
              ),
            ),
            if (hasToken)
              const Chip(
                avatar: Icon(Icons.check, size: 18),
                label: Text('Saved'),
              ),
          ],
        ),
      ),
      const Padding(
        padding: EdgeInsets.fromLTRB(16, 0, 16, 12),
        child: Text(
          '1. RepeaterBook has asked apps to identify themselves since March '
          '2026. The token is free. It is not an account you log into here — '
          'you request it on their site, paste it below once, and it stays in '
          'this device\'s keychain.',
        ),
      ),
      const Padding(
        padding: EdgeInsets.fromLTRB(16, 0, 16, 4),
        child: Text(
          '2. Request one on their site. You will need to be '
          'signed in to RepeaterBook.',
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        child: Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              onPressed: _openTokenPage,
              icon: const Icon(Icons.open_in_new),
              label: const Text('Request a token'),
            ),
            OutlinedButton.icon(
              onPressed: _copyUserAgent,
              icon: const Icon(Icons.copy_all_outlined),
              label: const Text('Copy app details'),
            ),
          ],
        ),
      ),
      const Padding(
        padding: EdgeInsets.fromLTRB(16, 8, 16, 4),
        child: Text('3. Paste it here and check it.'),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
        child: TextField(
          controller: _token,
          decoration: const InputDecoration(
            labelText: 'Access token',
            border: OutlineInputBorder(),
            hintText: 'rbuapp_…',
          ),
          autocorrect: false,
          enableSuggestions: false,
          onChanged: (_) => setState(() => _lastCheck = null),
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
        child: Row(
          children: [
            FilledButton(
              onPressed: _verifying ? null : _saveAndVerify,
              child: Text(_verifying ? 'Checking…' : 'Save and check'),
            ),
            const SizedBox(width: 8),
            if (hasToken)
              TextButton(
                onPressed: _verifying ? null : _clearToken,
                child: const Text('Remove'),
              ),
          ],
        ),
      ),
      if (_lastCheck case final TokenCheck check)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                check == TokenCheck.valid
                    ? Icons.check_circle_outline
                    : Icons.error_outline,
                size: 20,
                color: check == TokenCheck.valid
                    ? Theme.of(context).colorScheme.primary
                    : Theme.of(context).colorScheme.error,
              ),
              const SizedBox(width: 8),
              Expanded(child: Text(_tokenCheckMessage(check))),
            ],
          ),
        ),
      const Padding(
        padding: EdgeInsets.fromLTRB(16, 8, 16, 8),
        child: Text(
          '4. ${RepeaterBookClient.attributionLine} — shown '
          'wherever their listings appear, as their terms ask.',
        ),
      ),
    ];
  }

  Widget _cacheSection() => ListTile(
    leading: const Icon(Icons.delete_sweep_outlined),
    title: const Text('Clear cached listings'),
    subtitle: const Text(
      'Repeater lists are kept on this device so a search works offline '
      'and does not ask the directories twice for the same state.',
    ),
    onTap: _clearCache,
  );

  /// Said in the user's terms rather than the API's: each of these is a
  /// different thing to be stuck on, and "invalid token" for all of them
  /// would send someone to re-request a token they already have.
  static String _tokenCheckMessage(TokenCheck check) => switch (check) {
    TokenCheck.valid => 'That token works. RepeaterBook is ready to use.',
    TokenCheck.missing => 'Enter a token first.',
    TokenCheck.malformed =>
      'RepeaterBook did not recognise that as a token. Check you copied '
          'the whole thing — they usually start with "rbuapp_".',
    TokenCheck.rejected =>
      'RepeaterBook refused that token. It may have expired or been '
          'issued for another app; request a new one.',
    TokenCheck.rateLimited =>
      'RepeaterBook asked us to slow down, so the token could not be '
          'checked. It has been saved — try again in a few minutes.',
    TokenCheck.unreachable =>
      'Could not reach RepeaterBook to check. The token has been saved; '
          'it will be used next time you search.',
  };

  Future<void> _openTokenPage() async {
    final messenger = ScaffoldMessenger.of(context);
    final open = ref.read(urlOpenerProvider);
    final uri = Uri.parse(RepeaterBookClient.tokenRequestUrl);
    if (!await open(uri)) {
      messenger.showSnackBar(SnackBar(content: Text('Could not open $uri')));
    }
  }

  Future<void> _copyUserAgent() async {
    final messenger = ScaffoldMessenger.of(context);
    await Clipboard.setData(const ClipboardData(text: radioSourceUserAgent));
    if (!mounted) return;
    messenger.showSnackBar(
      const SnackBar(
        content: Text(
          'App name and contact copied — paste them into the '
          'token request form.',
        ),
      ),
    );
  }

  /// Save first, then check.
  ///
  /// Saving first is deliberate: a rate limit or a dead connection is not a
  /// verdict on the token, and losing what the user pasted because their
  /// train went into a tunnel would be its own small disaster.
  Future<void> _saveAndVerify() async {
    final token = _token.text.trim();
    final messenger = ScaffoldMessenger.of(context);
    final notifier = ref.read(repeaterBookTokenProvider.notifier);
    final client = ref.read(repeaterBookClientProvider);

    if (token.isEmpty) {
      setState(() => _lastCheck = TokenCheck.missing);
      return;
    }

    setState(() => _verifying = true);
    try {
      await notifier.setToken(token);
      final check = await client.verifyToken(token);
      if (!mounted) return;
      setState(() => _lastCheck = check);
    } catch (error) {
      if (!mounted) return;
      setState(() => _lastCheck = TokenCheck.unreachable);
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            friendlyErrorText(
              error,
              fallback: 'Could not check that token.',
              context: 'repeaterbook token check',
            ),
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _verifying = false);
    }
  }

  Future<void> _clearToken() async {
    await ref.read(repeaterBookTokenProvider.notifier).clear();
    if (!mounted) return;
    setState(() {
      _token.clear();
      _lastCheck = null;
    });
  }

  Future<void> _clearCache() async {
    final messenger = ScaffoldMessenger.of(context);
    await ref.read(radioSourceCacheProvider).clear();
    if (!mounted) return;
    messenger.showSnackBar(
      const SnackBar(content: Text('Cached repeater listings cleared.')),
    );
  }
}
