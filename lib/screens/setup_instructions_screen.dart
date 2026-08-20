// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/material.dart';

import '../services/spec_codec.dart'
    show
        SetupInstructionsDto,
        SetupMethodDto,
        SetupStepDto,
        TroubleshootingDto,
        FactoryResetDto,
        FactoryResetProcedureDto,
        RejoinDto;

/// The page a failed/dropped connection opens to show the catalogue's own
/// pairing and troubleshooting instructions for the device — how to put it in
/// pairing mode, why it might refuse to connect, how to factory reset it, and
/// whether a dropped link comes back on its own.
///
/// Read-only prose from the matched spec's `device.setup` block: it does not
/// touch the device, so it is safe to reach from an error state where there is
/// no live connection. Sections a spec omits are simply absent — the screen
/// never renders an empty heading.
class SetupInstructionsScreen extends StatelessWidget {
  /// The matched product's name — "Ember Mug" — for the intro line.
  final String deviceName;
  final SetupInstructionsDto instructions;

  const SetupInstructionsScreen({
    super.key,
    required this.deviceName,
    required this.instructions,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    // Troubleshooting first: the user is here because a connect FAILED, so the
    // "why won't it connect" answers are the reason they opened this, above the
    // from-scratch pairing steps.
    final troubleshooting = [
      for (final m in instructions.methods) ...m.troubleshooting,
    ];
    final rejoin = instructions.rejoin;

    return Scaffold(
      backgroundColor: scheme.surface,
      appBar: AppBar(title: const Text('Setup & troubleshooting')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 40),
          children: [
            Text(deviceName,
                style: text.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            Text(
              'The catalogue’s notes for connecting and resetting this device.',
              style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 20),
            if (rejoin?.notes != null && rejoin!.notes!.trim().isNotEmpty)
              _RejoinCard(rejoin: rejoin),
            if (troubleshooting.isNotEmpty)
              _Section(
                icon: Icons.help_outline,
                title: 'If it won’t connect',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final t in troubleshooting) _Troubleshooting(item: t),
                  ],
                ),
              ),
            if ((instructions.notes ?? '').trim().isNotEmpty)
              _Section(
                icon: Icons.info_outline,
                title: 'Overview',
                child: Text(instructions.notes!.trim(),
                    style: text.bodyMedium?.copyWith(height: 1.4)),
              ),
            for (final method in instructions.methods)
              if (method.description != null || method.steps.isNotEmpty)
                _MethodSection(method: method),
            if (instructions.factoryReset != null)
              _FactoryResetSection(reset: instructions.factoryReset!),
          ],
        ),
      ),
    );
  }
}

/// The rejoin note gets its own accented card at the top: for many devices
/// (Ember's single-connection lock) it is the actual answer to "why won't it
/// connect", and it should not be buried under the from-scratch steps.
class _RejoinCard extends StatelessWidget {
  final RejoinDto rejoin;
  const _RejoinCard({required this.rejoin});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.tertiaryContainer.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.lightbulb_outline,
              size: 22, color: scheme.onTertiaryContainer),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Try this first',
                    style: text.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: scheme.onTertiaryContainer)),
                const SizedBox(height: 6),
                Text(rejoin.notes!.trim(),
                    style: text.bodyMedium?.copyWith(
                        color: scheme.onTertiaryContainer, height: 1.4)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A titled block with a leading icon, matching the security screen's cards.
class _Section extends StatelessWidget {
  final IconData icon;
  final String title;
  final Widget child;
  const _Section(
      {required this.icon, required this.title, required this.child});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(icon, size: 20, color: scheme.primary),
            const SizedBox(width: 8),
            Expanded(
              child: Text(title,
                  style:
                      text.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
            ),
          ]),
          const SizedBox(height: 10),
          child,
        ],
      ),
    );
  }
}

class _Troubleshooting extends StatelessWidget {
  final TroubleshootingDto item;
  const _Troubleshooting({required this.item});

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(item.symptom.trim(),
              style: text.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
          for (final cause in item.causes)
            Padding(
              padding: const EdgeInsets.only(top: 4, left: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('•  ',
                      style: text.bodyMedium
                          ?.copyWith(color: scheme.onSurfaceVariant)),
                  Expanded(
                    child: Text(cause.trim(),
                        style: text.bodyMedium?.copyWith(
                            color: scheme.onSurfaceVariant, height: 1.4)),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _MethodSection extends StatelessWidget {
  final SetupMethodDto method;
  const _MethodSection({required this.method});

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return _Section(
      icon: Icons.bluetooth_searching,
      title: 'How to pair',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if ((method.description ?? '').trim().isNotEmpty) ...[
            Text(method.description!.trim(),
                style: text.bodyMedium?.copyWith(height: 1.4)),
            if (method.steps.isNotEmpty) const SizedBox(height: 10),
          ],
          for (var i = 0; i < method.steps.length; i++)
            _Step(index: i + 1, step: method.steps[i]),
        ],
      ),
    );
  }
}

class _Step extends StatelessWidget {
  final int index;
  final SetupStepDto step;
  const _Step({required this.index, required this.step});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final expect = (step.expect ?? '').trim();
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // A numbered chip keeps the order legible when a step wraps to several
          // lines.
          Container(
            width: 22,
            height: 22,
            alignment: Alignment.center,
            decoration: BoxDecoration(
                color: scheme.primaryContainer, shape: BoxShape.circle),
            child: Text('$index',
                style: text.labelSmall?.copyWith(
                    color: scheme.onPrimaryContainer,
                    fontWeight: FontWeight.w700)),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(step.action.trim(),
                    style: text.bodyMedium?.copyWith(height: 1.4)),
                if (expect.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text('→ $expect',
                        style: text.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                            fontStyle: FontStyle.italic)),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _FactoryResetSection extends StatelessWidget {
  final FactoryResetDto reset;
  const _FactoryResetSection({required this.reset});

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return _Section(
      icon: Icons.restart_alt,
      title: 'Factory reset',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if ((reset.effect ?? '').trim().isNotEmpty) ...[
            Text(reset.effect!.trim(),
                style: text.bodyMedium?.copyWith(height: 1.4)),
            if (reset.procedures.isNotEmpty) const SizedBox(height: 12),
          ],
          for (final p in reset.procedures) _ResetProcedure(procedure: p),
        ],
      ),
    );
  }
}

class _ResetProcedure extends StatelessWidget {
  final FactoryResetProcedureDto procedure;
  const _ResetProcedure({required this.procedure});

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final indicator = (procedure.indicator ?? '').trim();
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(procedure.name.trim(),
              style: text.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
          for (var i = 0; i < procedure.steps.length; i++)
            Padding(
              padding: const EdgeInsets.only(top: 4, left: 2),
              child: _Step(index: i + 1, step: procedure.steps[i]),
            ),
          if (indicator.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4, left: 2),
              child: Text('Confirmed by: $indicator',
                  style: text.bodySmall
                      ?.copyWith(color: scheme.onSurfaceVariant, height: 1.4)),
            ),
        ],
      ),
    );
  }
}
