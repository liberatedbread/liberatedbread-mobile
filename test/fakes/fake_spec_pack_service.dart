// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:liberated_bread_mobile/services/spec_pack_service.dart';

/// In-memory [SpecPackService] for widget tests: no network, no filesystem, so
/// providers resolve on the microtask queue and `pumpAndSettle` settles. The
/// real download/cache behaviour is exercised by the service unit tests.
class FakeSpecPackService implements SpecPackService {
  final List<SpecPack> packs;

  /// The next result returned by [install]/[refresh]. When it is an [InstallOk],
  /// its pack is also added to [packs] so the list reflects the install.
  InstallResult? nextResult;

  /// URLs passed to [install], in order.
  final List<String> installedUrls = [];

  /// URLs passed to [refresh], in order.
  final List<String> refreshedUrls = [];

  /// When set, [removePack] throws it, to exercise the UI error path.
  final Object? removeError;

  FakeSpecPackService(
      {List<SpecPack>? packs, this.nextResult, this.removeError})
      : packs = [...?packs];

  @override
  Duration get timeout => const Duration(seconds: 15);

  @override
  Future<InstallResult> install(String manifestUrl) async {
    installedUrls.add(manifestUrl);
    final result = nextResult ??
        const InstallFailed(
            SpecPackError(SpecPackErrorKind.network, 'no result configured'));
    if (result is InstallOk) {
      packs
        ..removeWhere((p) => p.name == result.pack.name)
        ..add(result.pack);
    }
    return result;
  }

  @override
  Future<InstallResult> refresh(String manifestUrl) async {
    refreshedUrls.add(manifestUrl);
    return install(manifestUrl);
  }

  @override
  Future<List<SpecPack>> listInstalledPacks() async => List.of(packs);

  @override
  Future<Map<String, String>> loadCachedSpecs() async => const {};

  @override
  Future<void> removePack(String name) async {
    if (removeError != null) throw removeError!;
    packs.removeWhere((p) => p.name == name);
  }

  @override
  Future<void> clearCache() async => packs.clear();
}
