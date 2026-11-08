// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/log.dart';
import '../../core/mono_text.dart';
import '../../core/web_link.dart';

/// How to make a printer available to every app, for this platform.
///
/// The app does not add printers to the system itself: iOS has no API for it,
/// Android's built-in print service already finds network printers, and on
/// Linux it would need admin rights. So this explains, and offers the one
/// shortcut each platform has. Label printers stay in this app — no system
/// print path drives a raw raster or BLE printer.
Future<void> showAddSystemPrinterSheet(
  BuildContext context, {
  required String printerName,
  required String host,
  int port = 631,
  String resourcePath = 'ipp/print',
  bool labelPrinter = false,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (_) => AddSystemPrinterSheet(
    printerName: printerName,
    host: host,
    port: port,
    resourcePath: resourcePath,
    labelPrinter: labelPrinter,
  ),
);

String ippDeviceUri({
  required String host,
  int port = 631,
  String resourcePath = 'ipp/print',
}) {
  final path = resourcePath.startsWith('/')
      ? resourcePath.substring(1)
      : resourcePath;
  return Uri(scheme: 'ipp', host: host, port: port, path: '/$path').toString();
}

/// The CUPS command that adds [host]'s IPP Everywhere queue on Linux.
String lpadminCommand({
  required String printerName,
  required String host,
  int port = 631,
  String resourcePath = 'ipp/print',
}) {
  final queue = printerName
      .replaceAll(RegExp(r'[^A-Za-z0-9_-]+'), '_')
      .replaceAll(RegExp(r'_+'), '_')
      .replaceAll(RegExp(r'^_|_$'), '');
  return 'lpadmin -p ${queue.isEmpty ? 'Printer' : queue} -E '
      '-v ${ippDeviceUri(host: host, port: port, resourcePath: resourcePath)} '
      '-m everywhere';
}

class AddSystemPrinterSheet extends StatelessWidget {
  final String printerName;
  final String host;
  final int port;
  final String resourcePath;
  final bool labelPrinter;

  const AddSystemPrinterSheet({
    super.key,
    required this.printerName,
    required this.host,
    this.port = 631,
    this.resourcePath = 'ipp/print',
    this.labelPrinter = false,
  });

  static const _settings = MethodChannel(
    'ca.pigscanfly.liberatedbread/print_settings',
  );

  Future<void> _openAndroidPrintSettings(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    var opened = false;
    try {
      opened = await _settings.invokeMethod<bool>('open') ?? false;
    } on Object catch (e) {
      Log.ui.warning('could not open print settings', error: e);
    }
    if (!opened) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text('Open Settings and search for "Printing".'),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final platform = defaultTargetPlatform;

    Widget para(String s) => Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Text(s, style: text.bodyMedium?.copyWith(height: 1.4)),
    );

    final children = <Widget>[
      Text('Use $printerName from other apps', style: text.titleMedium),
      const SizedBox(height: 12),
    ];

    if (labelPrinter) {
      children
        ..add(
          para(
            'Label printers print from this app: open the printer and choose '
            '"Compose a label". The system print dialog cannot drive them.',
          ),
        )
        ..add(
          para(
            'Some network label printers (Brother QL models among them) can '
            'also turn on AirPrint in their own settings. If yours has, it '
            'shows up in other apps like any printer.',
          ),
        );
    } else {
      switch (platform) {
        case TargetPlatform.iOS:
          children.add(
            para(
              'Nothing to add. AirPrint printers on the same Wi-Fi as this '
              'phone appear automatically in every app — tap Share, then '
              'Print.',
            ),
          );
        case TargetPlatform.android:
          children
            ..add(
              para(
                'Android finds network printers itself once its print service '
                'is on: Settings → Connected devices → Connection preferences '
                '→ Printing → Default Print Service.',
              ),
            )
            ..add(
              para(
                'If the printer still does not show up, install "Mopria Print '
                'Service" from the Play Store and turn it on there too.',
              ),
            )
            ..add(
              FilledButton.icon(
                onPressed: () => unawaited(_openAndroidPrintSettings(context)),
                icon: const Icon(Icons.settings_outlined),
                label: const Text('Open print settings'),
              ),
            );
        case TargetPlatform.linux:
          final command = lpadminCommand(
            printerName: printerName,
            host: host,
            port: port,
            resourcePath: resourcePath,
          );
          final deviceUri = ippDeviceUri(
            host: host,
            port: port,
            resourcePath: resourcePath,
          );
          children
            ..add(
              para(
                'Most desktops add network printers by themselves. If yours '
                'has not, this adds it to CUPS as a driverless printer (it may '
                'ask for your password):',
              ),
            )
            ..add(
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: SelectableText(
                        'sudo $command',
                        style: text.bodySmall?.monospaced,
                      ),
                    ),
                    IconButton(
                      tooltip: 'Copy command',
                      icon: const Icon(Icons.copy),
                      onPressed: () => unawaited(
                        Clipboard.setData(ClipboardData(text: 'sudo $command')),
                      ),
                    ),
                  ],
                ),
              ),
            )
            ..add(const SizedBox(height: 10))
            ..add(
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.tonalIcon(
                    onPressed: () => unawaited(
                      Clipboard.setData(ClipboardData(text: deviceUri)),
                    ),
                    icon: const Icon(Icons.copy),
                    label: const Text('Copy IPP URI'),
                  ),
                  OutlinedButton.icon(
                    onPressed: () => unawaited(
                      openWebLink(context, 'http://localhost:631/admin'),
                    ),
                    icon: const Icon(Icons.open_in_new),
                    label: const Text('Open CUPS'),
                  ),
                ],
              ),
            )
            ..add(const SizedBox(height: 10))
            ..add(
              para(
                'Or paste the IPP URI into your desktop\'s printer settings '
                'or CUPS.',
              ),
            );
        default:
          children.add(
            para(
              'Add it in your system\'s printer settings; it advertises '
              'itself as a driverless (IPP Everywhere / AirPrint) printer.',
            ),
          );
      }
    }

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: children,
        ),
      ),
    );
  }
}
