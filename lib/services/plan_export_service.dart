// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// Turning a plan into a file on disk, ready to hand to something else.

import 'dart:io';

import '../models/channel_plan.dart';
import 'chirp_csv.dart';
import 'spec_pack_service.dart' show CacheDirResolver;

/// A file written for the user to keep.
class ExportedFile {
  final File file;

  /// What to call it in a share sheet or a snackbar.
  final String displayName;

  const ExportedFile({required this.file, required this.displayName});
}

/// Writes plans out as CHIRP CSV.
///
/// Separate from the screen so the file-naming and the writing are testable
/// without a widget tree, and separate from [encodeChirpCsv] so the encoder
/// stays a pure function over channels.
class PlanExportService {
  final CacheDirResolver _resolveDir;

  PlanExportService({required CacheDirResolver dirResolver})
      : _resolveDir = dirResolver;

  Future<ExportedFile> exportChirpCsv(ChannelPlan plan) async {
    final base = await _resolveDir();
    final dir = Directory('${base.path}/radio_exports');
    await dir.create(recursive: true);

    final name = '${fileNameFor(plan)}.csv';
    final file = File('${dir.path}/$name');
    await file.writeAsString(encodeChirpCsv(plan.channels), flush: true);
    return ExportedFile(file: file, displayName: name);
  }

  /// A filename from the plan's name that no filesystem will object to.
  ///
  /// Users name plans things like "Dad's truck / GMRS", and a slash in a path
  /// component is a different directory rather than a character.
  static String fileNameFor(ChannelPlan plan) {
    final cleaned = plan.name
        .replaceAll(RegExp(r'[^A-Za-z0-9 _-]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim()
        .replaceAll(' ', '-');
    final safe = cleaned.isEmpty ? 'channel-plan' : cleaned;
    // Long enough to stay recognisable, short enough for every filesystem.
    return safe.length <= 60 ? safe : safe.substring(0, 60);
  }
}
