// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/ble_discovered_service.dart';
import '../providers/ble_provider.dart';
import '../providers/ipl_codec_provider.dart';
import '../providers/spec_codec_provider.dart';
import '../services/ipl_setup_session.dart';
import '../services/spec_codec.dart';

class IplSetupPanel extends ConsumerStatefulWidget {
  final String deviceId;
  final String specYaml;
  final DeviceSpecDto spec;
  final List<BleDiscoveredService> services;

  const IplSetupPanel({
    super.key,
    required this.deviceId,
    required this.specYaml,
    required this.spec,
    required this.services,
  });

  @override
  ConsumerState<IplSetupPanel> createState() => _IplSetupPanelState();
}

class _IplSetupPanelState extends ConsumerState<IplSetupPanel>
    with AutomaticKeepAliveClientMixin {
  late IplSetupSession _session;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _startSession();
  }

  void _startSession() {
    _session = IplSetupSession(
      ble: ref.read(bleServiceProvider),
      specCodec: ref.read(specCodecProvider),
      iplCodec: ref.read(iplCodecProvider),
      deviceId: widget.deviceId,
      specYaml: widget.specYaml,
      spec: widget.spec,
      discoveredServices: widget.services,
    )..start();
  }

  @override
  void didUpdateWidget(IplSetupPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.deviceId != widget.deviceId ||
        oldWidget.specYaml != widget.specYaml) {
      _session.dispose();
      _startSession();
    }
  }

  @override
  void dispose() {
    _session.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 12),
      child: ListenableBuilder(
        listenable: _session,
        builder: (context, _) => switch (widget.spec.protocolHandler) {
          'ipl_foreo' => _foreo(context, _session.state),
          'ipl_silkn' => _silkn(context, _session.state),
          'ipl_braun' => _braun(context, _session.state),
          _ => const SizedBox.shrink(),
        },
      ),
    );
  }

  Widget _frame({
    required String title,
    required IconData icon,
    required List<Widget> children,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: scheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: scheme.secondary),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                if (_session.state.phase != IplSetupPhase.working)
                  IconButton(
                    tooltip: 'Check again',
                    onPressed: _session.start,
                    icon: const Icon(Icons.refresh, size: 20),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            ...children,
          ],
        ),
      ),
    );
  }

  Widget _foreo(BuildContext context, IplSetupState state) {
    final actionLabel = state.phase == IplSetupPhase.error
        ? 'Retry activation'
        : state.locked == true
        ? 'Activate device'
        : 'Enable wake-up';
    return _frame(
      title: 'FOREO activation',
      icon: state.locked == false ? Icons.lock_open : Icons.lock_outline,
      children: [
        Text(switch (state.phase) {
          IplSetupPhase.checking => 'Checking activation and wake-up…',
          IplSetupPhase.needsAction =>
            state.locked == true
                ? 'This device is locked and needs offline activation.'
                : 'Activation is present, but wake-up is disabled.',
          IplSetupPhase.ready => 'Activated · wake-up enabled',
          IplSetupPhase.working => 'Activating and checking the result…',
          IplSetupPhase.error => 'Setup could not be verified.',
        }),
        const SizedBox(height: 8),
        const Text(
          'Activation uses the device BLE MAC locally. No account or cloud is required. Setup does not fire a flash.',
        ),
        if (state.notice != null) ...[
          const SizedBox(height: 8),
          Text(state.notice!, style: Theme.of(context).textTheme.bodySmall),
        ],
        if (state.error != null) ...[
          const SizedBox(height: 8),
          Text(
            state.error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ],
        if (state.phase == IplSetupPhase.needsAction ||
            state.phase == IplSetupPhase.error) ...[
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _session.activate,
            icon: const Icon(Icons.lock_open),
            label: Text(actionLabel),
          ),
        ],
        if (state.phase == IplSetupPhase.working)
          const Padding(
            padding: EdgeInsets.only(top: 12),
            child: LinearProgressIndicator(),
          ),
      ],
    );
  }

  Widget _silkn(BuildContext context, IplSetupState state) {
    return _frame(
      title: 'Silk’n device lock',
      icon: state.locked == false ? Icons.lock_open : Icons.lock_outline,
      children: [
        Text(switch (state.phase) {
          IplSetupPhase.checking => 'Checking the optional app lock…',
          IplSetupPhase.needsAction => 'The optional app lock is enabled.',
          IplSetupPhase.ready => 'Released and unlocked',
          IplSetupPhase.working => 'Unlocking and checking the result…',
          IplSetupPhase.error => 'The lock state could not be verified.',
        }),
        const SizedBox(height: 8),
        const Text(
          'Only the documented Released + Unlocked write is used. Energy level and flash triggering stay on the device.',
        ),
        if (state.notice != null) ...[
          const SizedBox(height: 8),
          Text(state.notice!, style: Theme.of(context).textTheme.bodySmall),
        ],
        if (state.error != null) ...[
          const SizedBox(height: 8),
          Text(
            state.error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ],
        if (state.phase == IplSetupPhase.needsAction ||
            state.phase == IplSetupPhase.error) ...[
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _session.activate,
            icon: const Icon(Icons.lock_open),
            label: const Text('Release and unlock'),
          ),
        ],
      ],
    );
  }

  Widget _braun(BuildContext context, IplSetupState state) {
    final text = Theme.of(context).textTheme;
    return _frame(
      title: 'Skin tone & patch test',
      icon: Icons.sensors,
      children: [
        const Text(
          'Use the device’s own sensors. Results stay raw; no skin-tone category is inferred.',
        ),
        if (state.notice != null) ...[
          const SizedBox(height: 8),
          Text(state.notice!, style: text.bodySmall),
        ],
        if (state.error != null) ...[
          const SizedBox(height: 8),
          Text(
            state.error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ],
        if (state.skinTone != null ||
            state.operationState != null ||
            state.energyLevel != null) ...[
          const SizedBox(height: 12),
          Wrap(
            spacing: 16,
            runSpacing: 6,
            children: [
              if (state.operationState != null)
                Text('Operation state ${state.operationState}'),
              if (state.skinTone != null)
                Text('Raw skin tone ${state.skinTone}'),
              if (state.energyLevel != null)
                Text('Energy level ${state.energyLevel}'),
              if (state.mountedHead != null)
                Text('Mounted head ${state.mountedHead}'),
              if (state.flashes != null)
                Text('Flashes this session ${state.flashes}'),
            ],
          ),
        ],
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.icon(
              onPressed: state.phase == IplSetupPhase.working
                  ? null
                  : _session.measureSkinTone,
              icon: const Icon(Icons.sensors),
              label: const Text('Measure skin tone'),
            ),
            OutlinedButton.icon(
              onPressed: state.phase == IplSetupPhase.working
                  ? null
                  : _confirmPatchTest,
              icon: const Icon(Icons.fact_check_outlined),
              label: const Text('Start patch test'),
            ),
          ],
        ),
        if (state.phase == IplSetupPhase.working)
          const Padding(
            padding: EdgeInsets.only(top: 12),
            child: LinearProgressIndicator(),
          ),
      ],
    );
  }

  Future<void> _confirmPatchTest() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Start a patch test?'),
        content: const Text(
          'This starts a device-guided patch test. Position the device only as its manual instructs, do not look at the flashes, and follow the recommended observation period.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Start patch test'),
          ),
        ],
      ),
    );
    if (confirmed == true) await _session.startPatchTest();
  }
}
