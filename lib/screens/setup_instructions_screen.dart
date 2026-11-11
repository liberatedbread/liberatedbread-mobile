// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/log.dart';
import '../core/pairing_content.dart';
import '../core/setup_content.dart';
import '../services/print/os_print_service.dart';
import '../services/print/pdf_documents.dart';
import '../services/spec_codec.dart'
    show
        SetupInstructionsDto,
        SetupMethodDto,
        SetupStageDto,
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
/// Read-only prose from the matched spec's `device.setup` block, and the
/// `device.pairing` block beside it (whether a client must pair, the code,
/// the pairing-mode button, one-phone-at-a-time limits): it does not
/// touch the device, so it is safe to reach from an error state where there is
/// no live connection. Sections a spec omits are simply absent — the screen
/// never renders an empty heading.
///
/// Also the page the Bluetooth pairing guide opens for a device the user has
/// not tried yet ([afterFailedConnect] false), where the same sections are
/// read in a different order: how to pair first, what to do if it will not
/// connect after that.
class SetupInstructionsScreen extends ConsumerWidget {
  /// The matched product's name — "Ember Mug" — for the intro line.
  final String deviceName;
  final SetupInstructionsDto instructions;

  /// Whether the user got here because a connect just failed (the default),
  /// which puts the rejoin note and troubleshooting above the from-scratch
  /// pairing steps. False for someone setting up a new device, who needs the
  /// steps first and the troubleshooting only if those do not work.
  final bool afterFailedConnect;

  const SetupInstructionsScreen({
    super.key,
    required this.deviceName,
    required this.instructions,
    this.afterFailedConnect = true,
  });

  Future<void> _print(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref
          .read(osPrintServiceProvider)
          .printDocument(
            name: '$deviceName setup',
            build: (format) => setupInstructionsPdf(
              format: format,
              deviceName: deviceName,
              instructions: instructions,
              afterFailedConnect: afterFailedConnect,
            ),
          );
    } on Object catch (e) {
      Log.app.warning('printing setup notes failed', error: e);
      messenger.showSnackBar(
        const SnackBar(content: Text('Could not open the print dialog.')),
      );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    // After a failed connect, troubleshooting leads: the "why won't it
    // connect" answers are the reason the user opened this, above the
    // from-scratch pairing steps. From the pairing guide the steps lead
    // instead — see [afterFailedConnect].
    final troubleshooting = [
      for (final m in instructions.methods) ...[
        ...m.troubleshooting,
        for (final stage in m.stages) ...stage.troubleshooting,
      ],
    ];
    final rejoin = instructions.rejoin;
    final hasRejoin = _hasText(rejoin?.notes);

    final troubleshootingSection = troubleshooting.isEmpty
        ? null
        : _Section(
            icon: Icons.help_outline,
            title: 'If it won’t connect',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final t in troubleshooting) _Troubleshooting(item: t),
              ],
            ),
          );
    final pairingFacts = switch (instructions.pairing) {
      final p? => PairingContent.of(p),
      null => null,
    };
    final pairingSection = pairingFacts != null && pairingFacts.hasContent
        ? _PairingSection(content: pairingFacts)
        : null;
    final pairing = <Widget>[
      if (_hasText(instructions.notes))
        _Section(
          icon: Icons.info_outline,
          title: 'Overview',
          child: Text(
            instructions.notes!.trim(),
            style: text.bodyMedium?.copyWith(height: 1.4),
          ),
        ),
      for (final method in instructions.methods)
        if (_MethodSection.hasContent(method)) _MethodSection(method: method),
    ];

    return Scaffold(
      backgroundColor: scheme.surface,
      appBar: AppBar(
        title: Text(
          afterFailedConnect
              ? 'Setup & troubleshooting'
              : 'Pairing instructions',
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.print_outlined),
            tooltip: 'Print',
            onPressed: () => unawaited(_print(context, ref)),
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 40),
          children: [
            Text(
              deviceName,
              style: text.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            Text(
              'The catalogue’s notes for connecting and resetting this device.',
              style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 20),
            if (afterFailedConnect) ...[
              if (hasRejoin) _RejoinCard(rejoin: rejoin!),
              ?troubleshootingSection,
              // Above the from-scratch routes: "it only talks to one phone
              // at a time" and "it remembers the last phone" are the usual
              // answers to a failed connect.
              ?pairingSection,
              ...pairing,
            ] else ...[
              // Whether to pair at all, and the button that opens the
              // window, come before the routes that assume it is open.
              ?pairingSection,
              ...pairing,
              ?troubleshootingSection,
              // A new device has no link to drop yet, so the rejoin note is
              // what to know for later — not "try this first".
              if (hasRejoin)
                _Section(
                  icon: Icons.sync,
                  title: 'If it disconnects later',
                  child: Text(
                    rejoin!.notes!.trim(),
                    style: text.bodyMedium?.copyWith(height: 1.4),
                  ),
                ),
            ],
            if (instructions.factoryReset case final reset?
                when _FactoryResetSection.hasContent(reset))
              _FactoryResetSection(reset: reset),
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
          Icon(
            Icons.lightbulb_outline,
            size: 22,
            color: scheme.onTertiaryContainer,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Try this first',
                  style: text.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: scheme.onTertiaryContainer,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  rejoin.notes!.trim(),
                  style: text.bodyMedium?.copyWith(
                    color: scheme.onTertiaryContainer,
                    height: 1.4,
                  ),
                ),
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
  const _Section({
    required this.icon,
    required this.title,
    required this.child,
  });

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
          Row(
            children: [
              Icon(icon, size: 20, color: scheme.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: text.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
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
          Text(
            item.symptom.trim(),
            style: text.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
          ),
          for (final cause in item.causes)
            Padding(
              padding: const EdgeInsets.only(top: 4, left: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '•  ',
                    style: text.bodyMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  Expanded(
                    child: Text(
                      cause.trim(),
                      style: text.bodyMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                        height: 1.4,
                      ),
                    ),
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

  /// Whether the card would say anything; see [setupMethodHasContent].
  static bool hasContent(SetupMethodDto method) =>
      setupMethodHasContent(method);

  /// What a `role` means to the reader. `primary` (and absent) get no label:
  /// the first card needs no qualifier, and a label saying "the normal way"
  /// would only make people look for a catch. A role this build has never
  /// heard of shows the spec's own word — unlabeled is what primary looks
  /// like, and a route the catalogue deliberately ranked below primary must
  /// not dress as it.
  static String? roleLabel(String? role) => switch (role) {
    null || 'primary' => null,
    'alternative' => 'Also works',
    'variant' => 'Depends on the hardware',
    'historical' => 'No longer current',
    final other => other,
  };

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    // The spec's own name for the route ("HomeKit pairing with the app's
    // 8-digit code") beats a generic heading — with several routes on the
    // page, "How to pair" four times over is unchoosable.
    final title = (method.name ?? '').trim().isNotEmpty
        ? method.name!.trim()
        : 'How to pair';
    final role = roleLabel(method.role);
    return _Section(
      icon: Icons.bluetooth_searching,
      title: title,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (role != null) ...[
            Text(
              role,
              style: text.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.4,
              ),
            ),
            const SizedBox(height: 6),
          ],
          if (_hasText(method.description)) ...[
            Text(
              method.description!.trim(),
              style: text.bodyMedium?.copyWith(height: 1.4),
            ),
            if (method.steps.isNotEmpty || method.stages.isNotEmpty)
              const SizedBox(height: 10),
          ],
          for (var i = 0; i < method.steps.length; i++)
            _Step(index: i + 1, step: method.steps[i]),
          // A staged route renders every phase, in order, under its own
          // subhead — the phases are consecutive halves of ONE procedure, and
          // a reader who stops after the first has not set the device up.
          for (var i = 0; i < method.stages.length; i++)
            _StageBlock(
              index: i + 1,
              total: method.stages.length,
              stage: method.stages[i],
            ),
        ],
      ),
    );
  }
}

class _StageBlock extends StatelessWidget {
  final int index;
  final int total;
  final SetupStageDto stage;
  const _StageBlock({
    required this.index,
    required this.total,
    required this.stage,
  });

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final name = (stage.name ?? '').trim();
    final description = (stage.description ?? '').trim();
    return Padding(
      padding: EdgeInsets.only(top: index == 1 ? 2 : 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            name.isNotEmpty
                ? '$index of $total — $name'
                : 'Stage $index of $total',
            style: text.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
          ),
          if (description.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                description,
                style: text.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                  height: 1.4,
                ),
              ),
            ),
          const SizedBox(height: 8),
          for (var i = 0; i < stage.steps.length; i++)
            _Step(index: i + 1, step: stage.steps[i]),
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
              color: scheme.primaryContainer,
              shape: BoxShape.circle,
            ),
            child: Text(
              '$index',
              style: text.labelSmall?.copyWith(
                color: scheme.onPrimaryContainer,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  step.action.trim(),
                  style: text.bodyMedium?.copyWith(height: 1.4),
                ),
                if (expect.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      '→ $expect',
                      style: text.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
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

  /// Whether the section would say anything. A reset block with a blank
  /// effect and no procedures used to render a bare "Factory reset" heading;
  /// the catalogue's `effect: "n/a"` (not applicable) with none reads the
  /// same way to a user.
  static bool hasContent(FactoryResetDto reset) =>
      reset.procedures.isNotEmpty || _hasEffect(reset.effect);

  /// Whether [effect] says something: [_hasText], less the catalogue's
  /// "n/a". The ONE test [hasContent] and [build] share — build used plain
  /// [_hasText], so an "n/a" effect beside a procedure drew a literal "n/a"
  /// paragraph above it.
  static bool _hasEffect(String? effect) =>
      _hasText(effect) && effect!.trim().toLowerCase() != 'n/a';

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return _Section(
      icon: Icons.restart_alt,
      title: 'Factory reset',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_hasEffect(reset.effect)) ...[
            Text(
              reset.effect!.trim(),
              style: text.bodyMedium?.copyWith(height: 1.4),
            ),
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
    final meta = procedureMeta(procedure);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            procedure.name.trim(),
            style: text.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
          ),
          if (meta != null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                meta,
                style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ),
          for (var i = 0; i < procedure.steps.length; i++)
            Padding(
              padding: const EdgeInsets.only(top: 4, left: 2),
              child: _Step(index: i + 1, step: procedure.steps[i]),
            ),
          if (indicator.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4, left: 2),
              child: Text(
                'Confirmed by: $indicator',
                style: text.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                  height: 1.4,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// The spec's `device.pairing` answer: whether to pair at all, how, the code,
/// the pairing-mode button and the one-phone-at-a-time limits. Worded by
/// [PairingContent], which the printout shares.
class _PairingSection extends StatelessWidget {
  final PairingContent content;
  const _PairingSection({required this.content});

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final body = text.bodyMedium?.copyWith(height: 1.4);
    final muted = text.bodySmall?.copyWith(
      color: scheme.onSurfaceVariant,
      height: 1.4,
    );
    Widget subhead(String label) => Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 6),
      child: Text(
        label,
        style: text.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
      ),
    );
    Widget bullet(String line) => Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('•  ', style: body?.copyWith(color: scheme.onSurfaceVariant)),
          Expanded(child: Text(line, style: body)),
        ],
      ),
    );

    return _Section(
      icon: Icons.link,
      title: 'Pairing',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (content.headline case final headline?)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(
                headline,
                style: body?.copyWith(fontWeight: FontWeight.w700),
              ),
            ),
          for (final fact in content.facts) bullet(fact),
          if (content.pinNotes case final notes?)
            Padding(
              padding: const EdgeInsets.only(left: 16, bottom: 4),
              child: Text(notes, style: muted),
            ),
          if (content.recovery case final recovery?) ...[
            subhead('If another phone or app has it'),
            Text(recovery, style: body),
          ],
          if (content.hasPairingMode) ...[
            subhead('Pairing mode'),
            for (final fact in content.pairingModeFacts) bullet(fact),
            for (final p in content.pairingModeProcedures)
              _ResetProcedure(procedure: p),
          ],
          if (content.hasUnpair) ...[
            subhead('Forgetting a paired phone'),
            for (final fact in content.unpairFacts) bullet(fact),
            for (final p in content.unpairProcedures)
              _ResetProcedure(procedure: p),
          ],
          if (content.technicalNotes.isNotEmpty)
            // Its own transparent Material: the card's coloured box would
            // otherwise hide the tile's ink.
            Material(
              type: MaterialType.transparency,
              child: Theme(
                // The tile's own dividers would draw lines through the card.
                data: Theme.of(
                  context,
                ).copyWith(dividerColor: Colors.transparent),
                child: ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  childrenPadding: const EdgeInsets.only(bottom: 4),
                  expandedCrossAxisAlignment: CrossAxisAlignment.start,
                  title: Text(
                    'Technical notes',
                    style: text.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  children: [
                    for (final note in content.technicalNotes)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Text(note, style: muted),
                      ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Non-blank text. The ONE test both the section filters and the widgets
/// use: the method filter once admitted any non-null description while the
/// widget hid a blank one, giving a titled card with nothing under it.
bool _hasText(String? s) => hasSetupText(s);
