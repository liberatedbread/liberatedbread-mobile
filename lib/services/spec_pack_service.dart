// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// Downloads and caches a "pack" of device-spec YAML files described by a remote
/// JSON manifest, so new device support can ship without an app-store update.
///
/// The manifest URL points at JSON of the shape
/// `{"name": str, "version": str, "specs": ["bulb.yaml", ...]}` where each entry
/// is a filename resolved *relative to the manifest URL*. Downloaded manifests
/// and YAML files are cached under the app documents directory; [loadCachedSpecs]
/// re-reads them for [deviceSpecsProvider] to merge with the bundled assets.
///
/// Every network and parse path is defensive: timeouts, non-2xx responses,
/// malformed JSON, malformed/oversized YAML, and partial failures all resolve to
/// a typed [InstallResult] — this class never throws for expected error paths.

/// A cache directory resolver. Injected so unit tests can point at a temp dir
/// instead of the real (platform-channel-backed) app documents directory.
typedef CacheDirResolver = Future<Directory> Function();

/// Validates that a downloaded spec's YAML actually parses as a device spec.
/// Injected (wired to the same codec the match provider uses) so install can
/// reject specs that would later fail to parse — otherwise a remote install can
/// visibly "succeed" while the match provider silently skips every spec. Returns
/// true when [yaml] is a usable device spec, false (or throws) otherwise.
typedef SpecValidator = Future<bool> Function(String yaml);

/// Hard limits on what we will download, to bound memory and disk use.
class SpecPackLimits {
  SpecPackLimits._();

  /// Largest manifest JSON we will accept.
  static const int maxManifestBytes = 256 * 1024;

  /// Largest single spec YAML we will accept.
  static const int maxSpecBytes = 512 * 1024;

  /// Largest combined size of all specs in one pack.
  static const int maxTotalBytes = 4 * 1024 * 1024;

  /// Most specs a single manifest may list.
  static const int maxSpecCount = 128;
}

/// Parsed remote manifest. Kept separate from the on-disk [SpecPack] record.
@immutable
class SpecPackManifest {
  final String name;
  final String version;
  final List<String> specs;

  const SpecPackManifest({
    required this.name,
    required this.version,
    required this.specs,
  });

  /// Parse and validate manifest JSON. Returns null when the bytes are not
  /// well-formed JSON of the expected shape.
  static SpecPackManifest? tryParse(String jsonText) {
    Object? decoded;
    try {
      decoded = jsonDecode(jsonText);
    } catch (_) {
      return null;
    }
    if (decoded is! Map<String, dynamic>) return null;
    final name = decoded['name'];
    final version = decoded['version'];
    final specs = decoded['specs'];
    if (name is! String || name.trim().isEmpty) return null;
    if (version is! String || version.trim().isEmpty) return null;
    if (specs is! List) return null;
    final specList = <String>[];
    for (final entry in specs) {
      if (entry is! String || entry.trim().isEmpty) return null;
      specList.add(entry.trim());
    }
    if (specList.length > SpecPackLimits.maxSpecCount) return null;
    return SpecPackManifest(
      name: name.trim(),
      version: version.trim(),
      specs: specList,
    );
  }
}

/// Metadata for a pack that has been installed to the local cache, persisted as
/// `manifest.json` alongside its YAML files.
@immutable
class SpecPack {
  final String name;
  final String version;
  final String sourceUrl;

  /// The spec filenames that were successfully cached (may be a subset of the
  /// manifest's list after a partial failure).
  final List<String> specFiles;
  final DateTime installedAt;

  const SpecPack({
    required this.name,
    required this.version,
    required this.sourceUrl,
    required this.specFiles,
    required this.installedAt,
  });

  int get specCount => specFiles.length;

  Map<String, dynamic> toJson() => {
        'name': name,
        'version': version,
        'source_url': sourceUrl,
        'spec_files': specFiles,
        'installed_at': installedAt.toIso8601String(),
      };

  static SpecPack? tryFromJson(String jsonText) {
    Object? decoded;
    try {
      decoded = jsonDecode(jsonText);
    } catch (_) {
      return null;
    }
    if (decoded is! Map<String, dynamic>) return null;
    final name = decoded['name'];
    final version = decoded['version'];
    final sourceUrl = decoded['source_url'];
    final specFiles = decoded['spec_files'];
    final installedAt = decoded['installed_at'];
    if (name is! String || version is! String || sourceUrl is! String) {
      return null;
    }
    if (specFiles is! List) return null;
    final files = <String>[];
    for (final f in specFiles) {
      if (f is String) files.add(f);
    }
    final parsedAt =
        installedAt is String ? DateTime.tryParse(installedAt) : null;
    return SpecPack(
      name: name,
      version: version,
      sourceUrl: sourceUrl,
      specFiles: files,
      installedAt: parsedAt ?? DateTime.fromMillisecondsSinceEpoch(0),
    );
  }
}

/// Why an install failed, for the UI to render a friendly message.
enum SpecPackErrorKind {
  /// The manifest URL is not a valid http/https URL.
  invalidUrl,

  /// A request exceeded the timeout.
  timeout,

  /// Could not reach the server (DNS, connection refused, TLS).
  network,

  /// A request returned a non-2xx status.
  http,

  /// The manifest was not well-formed JSON of the expected shape.
  malformedManifest,

  /// The manifest or a file exceeded the size caps.
  tooLarge,

  /// Not a single spec in the manifest could be downloaded.
  noSpecsInstalled,

  /// Reading or writing the local cache failed.
  cacheIo,
}

@immutable
class SpecPackError {
  final SpecPackErrorKind kind;
  final String message;
  const SpecPackError(this.kind, this.message);

  @override
  String toString() => message;
}

/// One spec that could not be downloaded/cached during an otherwise-successful
/// install.
@immutable
class SpecDownloadFailure {
  final String specFile;
  final String reason;
  const SpecDownloadFailure(this.specFile, this.reason);
}

/// Outcome of [SpecPackService.install]. A [InstallOk] may still carry
/// [InstallOk.partialFailures] for specs that individually failed.
sealed class InstallResult {
  const InstallResult();
}

class InstallOk extends InstallResult {
  final SpecPack pack;
  final List<SpecDownloadFailure> partialFailures;
  const InstallOk(this.pack, {this.partialFailures = const []});
}

class InstallFailed extends InstallResult {
  final SpecPackError error;
  const InstallFailed(this.error);
}

class SpecPackService {
  final http.Client _client;
  final CacheDirResolver _resolveCacheDir;

  /// Optional device-spec validator. When set, install rejects any downloaded
  /// spec it cannot parse. Null in low-level unit tests that exercise pure
  /// download/cache mechanics without the native codec.
  final SpecValidator? _validateSpec;
  final Duration timeout;

  SpecPackService({
    required http.Client client,
    required CacheDirResolver cacheDirResolver,
    SpecValidator? specValidator,
    this.timeout = const Duration(seconds: 15),
  })  : _client = client,
        _resolveCacheDir = cacheDirResolver,
        _validateSpec = specValidator;

  /// Whether [input] is a usable http/https manifest URL.
  static bool isValidManifestUrl(String input) {
    final trimmed = input.trim();
    if (trimmed.isEmpty || trimmed.contains(RegExp(r'\s'))) return false;
    final uri = Uri.tryParse(trimmed);
    return uri != null &&
        (uri.scheme == 'http' || uri.scheme == 'https') &&
        uri.host.isNotEmpty;
  }

  /// Fetch [manifestUrl], download the specs it lists, and cache the lot. Any
  /// previously-cached pack with the same name is replaced. Never throws.
  Future<InstallResult> install(String manifestUrl) async {
    final url = manifestUrl.trim();
    if (!isValidManifestUrl(url)) {
      return const InstallFailed(SpecPackError(
          SpecPackErrorKind.invalidUrl, 'Enter a valid http(s) URL.'));
    }
    final manifestUri = Uri.parse(url);

    // 1. Fetch the manifest.
    final Uint8List manifestBytes;
    try {
      manifestBytes =
          await _fetch(manifestUri, SpecPackLimits.maxManifestBytes);
    } on _FetchException catch (e) {
      return InstallFailed(e.toError());
    }
    final SpecPackManifest? manifest;
    try {
      manifest = SpecPackManifest.tryParse(utf8.decode(manifestBytes));
    } on FormatException {
      return const InstallFailed(SpecPackError(
          SpecPackErrorKind.malformedManifest,
          'The manifest was not valid UTF-8 text.'));
    }
    if (manifest == null) {
      return const InstallFailed(SpecPackError(
          SpecPackErrorKind.malformedManifest,
          'The manifest is not a valid spec-pack manifest.'));
    }

    // 2. Download each spec, capping per-file and total size.
    final downloaded = <String, Uint8List>{};
    final failures = <SpecDownloadFailure>[];
    var totalBytes = 0;
    for (final specFile in manifest.specs) {
      // SSRF guard: spec entries must be RELATIVE, same-origin references. An
      // absolute URL ('https://evil/x'), a scheme-relative one ('//evil/x'), or
      // a rooted path ('/other', '\\x') could otherwise smuggle a cross-origin
      // fetch past the scheme check below.
      if (specFile.contains('://') ||
          specFile.startsWith('/') ||
          specFile.startsWith('\\')) {
        failures.add(SpecDownloadFailure(
            specFile, 'spec path must be relative and same-origin'));
        continue;
      }
      final specUri = manifestUri.resolve(specFile);
      if (specUri.scheme != 'http' && specUri.scheme != 'https') {
        failures.add(SpecDownloadFailure(specFile, 'unsupported URL scheme'));
        continue;
      }
      if (!_sameOrigin(manifestUri, specUri)) {
        failures.add(
            SpecDownloadFailure(specFile, 'cross-origin spec URL rejected'));
        continue;
      }
      final remaining = SpecPackLimits.maxTotalBytes - totalBytes;
      if (remaining <= 0) {
        failures.add(
            SpecDownloadFailure(specFile, 'total download size cap reached'));
        continue;
      }
      final cap = remaining < SpecPackLimits.maxSpecBytes
          ? remaining
          : SpecPackLimits.maxSpecBytes;
      try {
        final bytes = await _fetch(specUri, cap);
        // Reject content that is not decodable UTF-8 text (a corrupt/binary
        // "YAML" file); the Rust codec parses YAML later, but must get text.
        final String text;
        try {
          text = utf8.decode(bytes);
        } on FormatException {
          failures.add(SpecDownloadFailure(specFile, 'not valid UTF-8 text'));
          continue;
        }
        if (bytes.isEmpty) {
          failures.add(SpecDownloadFailure(specFile, 'empty file'));
          continue;
        }
        // Reject content that does not parse as a device spec, using the same
        // codec the match provider uses at runtime. Without this, invalid YAML
        // is "installed" and reported as success, yet silently skipped later.
        if (_validateSpec != null) {
          bool valid;
          try {
            valid = await _validateSpec(text);
          } catch (_) {
            valid = false;
          }
          if (!valid) {
            failures
                .add(SpecDownloadFailure(specFile, 'not a valid device spec'));
            continue;
          }
        }
        downloaded[specFile] = bytes;
        totalBytes += bytes.length;
      } on _FetchException catch (e) {
        failures.add(SpecDownloadFailure(specFile, e.error.message));
      }
    }

    if (downloaded.isEmpty) {
      return const InstallFailed(SpecPackError(
          SpecPackErrorKind.noSpecsInstalled,
          'None of the specs in the manifest could be downloaded.'));
    }

    // 3. Persist to the cache (replace any same-named pack).
    final SpecPack pack;
    try {
      final persisted = await _persist(manifest, url, downloaded);
      pack = persisted.pack;
      // Specs dropped at write time (on-disk name collisions) join the
      // download-time partial failures so the UI can surface every skip.
      failures.addAll(persisted.failures);
    } on Object catch (e) {
      // cacheIo is the one error kind whose message the settings screen shows
      // verbatim, so it has to read like a sentence; the raw failure (a path,
      // an errno) is for the log, not the user.
      debugPrint('[opengreeniot] spec pack persist failed: $e');
      return const InstallFailed(SpecPackError(SpecPackErrorKind.cacheIo,
          'Could not save the pack to this device\'s storage.'));
    }
    return InstallOk(pack, partialFailures: failures);
  }

  /// Alias for [install]; refreshing re-fetches from the same URL.
  Future<InstallResult> refresh(String manifestUrl) => install(manifestUrl);

  /// All packs currently in the cache, newest first.
  ///
  /// A failure reading the cache directory itself (permissions, platform
  /// channel unavailable, etc.) PROPAGATES so the settings UI can show an error
  /// state instead of an indistinguishable "no packs installed". Only individual
  /// corrupt/unreadable pack records are tolerated — each is skipped with a
  /// visible diagnostic rather than silently dropped.
  Future<List<SpecPack>> listInstalledPacks() async {
    final packs = <SpecPack>[];
    final root = await _cacheRoot();
    if (!await root.exists()) return packs;
    await for (final entry in root.list()) {
      if (entry is! Directory) continue;
      final manifestFile = File('${entry.path}/manifest.json');
      if (!await manifestFile.exists()) continue;
      try {
        final pack = SpecPack.tryFromJson(await manifestFile.readAsString());
        if (pack != null) {
          packs.add(pack);
        } else {
          debugPrint(
              'SpecPackService: skipping corrupt pack record ${manifestFile.path}');
        }
      } catch (e) {
        // Skip an unreadable/corrupt pack record, but make the drop visible.
        debugPrint('SpecPackService: skipping unreadable pack record '
            '${manifestFile.path}: $e');
      }
    }
    packs.sort((a, b) => b.installedAt.compareTo(a.installedAt));
    return packs;
  }

  /// Every cached spec YAML, keyed by a namespaced id `pack:<name>/<file>` so
  /// remote specs never collide with bundled asset keys.
  ///
  /// This feeds live device matching, which must always fall back to the bundled
  /// specs, so a catastrophic cache-read failure is tolerated (empty map) rather
  /// than propagated — but it is logged, not silently swallowed. Individual
  /// unreadable spec files are likewise skipped with a diagnostic.
  Future<Map<String, String>> loadCachedSpecs() async {
    final result = <String, String>{};
    final List<SpecPack> packs;
    try {
      packs = await listInstalledPacks();
    } catch (e) {
      debugPrint('SpecPackService: could not list cached packs, falling back '
          'to bundled specs only: $e');
      return result;
    }
    for (final pack in packs) {
      final dir = _packDir(await _cacheRoot(), pack.name);
      for (final file in pack.specFiles) {
        try {
          final f = File('${dir.path}/specs/${_safeFileName(file)}');
          if (await f.exists()) {
            result['pack:${pack.name}/$file'] = await f.readAsString();
          } else {
            debugPrint('SpecPackService: cached spec missing on disk for '
                'pack:${pack.name}/$file');
          }
        } catch (e) {
          debugPrint('SpecPackService: skipping unreadable cached spec '
              'pack:${pack.name}/$file: $e');
        }
      }
    }
    return result;
  }

  /// Remove one cached pack by name.
  ///
  /// A real filesystem failure (permissions, I/O) PROPAGATES so the UI can show
  /// the user a failure instead of a false "Removed" message. The path-safety
  /// guard still refuses (silently, as a no-op) to recursively delete anything
  /// that is not strictly inside the cache root.
  Future<void> removePack(String name) async {
    final root = await _cacheRoot();
    final dir = _packDir(root, name);
    // Never recursively delete a path that isn't strictly inside the cache
    // root, mirroring the guard in _persist.
    if (!_isStrictlyInside(root, dir)) return;
    if (await dir.exists()) await dir.delete(recursive: true);
  }

  /// Delete every cached pack. Never throws.
  Future<void> clearCache() async {
    try {
      final root = await _cacheRoot();
      if (await root.exists()) await root.delete(recursive: true);
    } catch (_) {
      // Best-effort.
    }
  }

  // --- internals ---

  Future<Directory> _cacheRoot() async {
    final base = await _resolveCacheDir();
    return Directory('${base.path}/spec_packs');
  }

  Directory _packDir(Directory root, String packName) =>
      Directory('${root.path}/${_slug(packName)}');

  Future<({SpecPack pack, List<SpecDownloadFailure> failures})> _persist(
    SpecPackManifest manifest,
    String sourceUrl,
    Map<String, Uint8List> specs,
  ) async {
    final root = await _cacheRoot();
    final dir = _packDir(root, manifest.name);
    // Defense-in-depth: never create or (recursively!) delete a directory that
    // is not strictly inside the spec_packs cache root. _slug already prevents
    // '..'/'.'/separators, but a hostile pack name must never be able to point
    // delete() at the documents dir or its parent.
    if (!_isStrictlyInside(root, dir)) {
      throw StateError('refusing unsafe pack directory: ${dir.path}');
    }
    // Before replacing, verify any existing pack has the same name.
    final manifestFile = File('${dir.path}/manifest.json');
    if (await manifestFile.exists()) {
      try {
        final stored = SpecPack.tryFromJson(await manifestFile.readAsString());
        if (stored != null && stored.name != manifest.name) {
          throw StateError(
              'Pack "${manifest.name}" collides with existing "${stored.name}" at ${dir.path}');
        }
      } catch (e) {
        if (e is StateError) rethrow;
        // Corrupt manifest: delete and replace.
      }
    }

    // Write into a staging directory and swap atomically so a partial write
    // never replaces a valid cached pack.
    final stagingDir = Directory('${dir.path}.staging');
    if (await stagingDir.exists()) await stagingDir.delete(recursive: true);
    final specsDir = Directory('${stagingDir.path}/specs');
    await specsDir.create(recursive: true);

    final storedFiles = <String>[];
    final failures = <SpecDownloadFailure>[];
    // On-disk names must stay 1:1 with manifest entries: if two entries reduce
    // to the same sanitized filename they would overwrite each other on disk
    // while both keys survived in metadata, so loadCachedSpecs would return the
    // wrong content for one of them. Track used names and skip (annotate)
    // collisions instead of silently clobbering.
    final usedNames = <String>{};
    for (final entry in specs.entries) {
      final safeName = _safeFileName(entry.key);
      if (!usedNames.add(safeName)) {
        failures.add(SpecDownloadFailure(entry.key,
            'on-disk name "$safeName" collides with another spec in this pack'));
        continue;
      }
      final file = File('${specsDir.path}/$safeName');
      // Belt-and-suspenders: the written file must land inside <pack>/specs/.
      if (!_isStrictlyInside(specsDir, file)) {
        failures.add(SpecDownloadFailure(entry.key, 'unsafe on-disk path'));
        continue;
      }
      await file.writeAsBytes(entry.value, flush: true);
      storedFiles.add(entry.key);
    }
    if (storedFiles.isEmpty) {
      throw StateError('no spec files could be safely written');
    }

    final pack = SpecPack(
      name: manifest.name,
      version: manifest.version,
      sourceUrl: sourceUrl,
      specFiles: storedFiles,
      installedAt: DateTime.now(),
    );
    await File('${stagingDir.path}/manifest.json')
        .writeAsString(jsonEncode(pack.toJson()), flush: true);

    // Atomic swap: only after all writes succeed.
    if (await dir.exists()) await dir.delete(recursive: true);
    await stagingDir.rename(dir.path);
    return (pack: pack, failures: failures);
  }

  /// Largest number of redirect hops we will follow (all same-origin).
  static const int _maxRedirects = 5;

  /// GET [uri], enforcing [timeout] and a [maxBytes] size cap. Redirects are NOT
  /// auto-followed by the client; we follow them manually and ONLY when they
  /// stay on the original origin, so a redirect can't be used to reach a
  /// cross-origin/internal host. Translates every failure into a
  /// [_FetchException].
  Future<Uint8List> _fetch(Uri uri, int maxBytes) async {
    final origin = uri;
    var current = uri;
    for (var hop = 0;; hop++) {
      http.StreamedResponse response;
      try {
        final request = http.Request('GET', current)..followRedirects = false;
        response = await _client.send(request).timeout(timeout);
      } on TimeoutException {
        throw _FetchException(const SpecPackError(
            SpecPackErrorKind.timeout, 'The request timed out.'));
      } on http.ClientException catch (e) {
        throw _FetchException(SpecPackError(
            SpecPackErrorKind.network, 'Could not connect: ${e.message}'));
      } on SocketException catch (e) {
        throw _FetchException(SpecPackError(
            SpecPackErrorKind.network, 'Could not connect: ${e.message}'));
      } on Object catch (e) {
        throw _FetchException(
            SpecPackError(SpecPackErrorKind.network, 'Request failed: $e'));
      }

      // Manual, same-origin-only redirect handling.
      if (response.statusCode >= 300 && response.statusCode < 400) {
        unawaited(response.stream.drain<void>().catchError((_) {}));
        final location = response.headers['location'];
        if (location == null || location.isEmpty) {
          throw _FetchException(SpecPackError(SpecPackErrorKind.http,
              'Redirect (HTTP ${response.statusCode}) without a location.'));
        }
        if (hop >= _maxRedirects) {
          throw _FetchException(const SpecPackError(
              SpecPackErrorKind.network, 'Too many redirects.'));
        }
        final next = current.resolve(location);
        if (!_sameOrigin(origin, next)) {
          throw _FetchException(const SpecPackError(
              SpecPackErrorKind.network, 'Refused a cross-origin redirect.'));
        }
        current = next;
        continue;
      }

      if (response.statusCode < 200 || response.statusCode >= 300) {
        // Drain so the connection can be reused/closed cleanly.
        unawaited(response.stream.drain<void>().catchError((_) {}));
        throw _FetchException(SpecPackError(SpecPackErrorKind.http,
            'Server returned HTTP ${response.statusCode}.'));
      }

      final contentLength = response.contentLength;
      if (contentLength != null && contentLength > maxBytes) {
        unawaited(response.stream.drain<void>().catchError((_) {}));
        throw _FetchException(const SpecPackError(
            SpecPackErrorKind.tooLarge, 'The file is larger than allowed.'));
      }

      final bytes = <int>[];
      try {
        await for (final chunk in response.stream.timeout(timeout)) {
          bytes.addAll(chunk);
          if (bytes.length > maxBytes) {
            throw _FetchException(const SpecPackError(
                SpecPackErrorKind.tooLarge,
                'The file is larger than allowed.'));
          }
        }
      } on _FetchException {
        rethrow;
      } on TimeoutException {
        throw _FetchException(const SpecPackError(
            SpecPackErrorKind.timeout, 'The download stalled.'));
      } on Object catch (e) {
        throw _FetchException(
            SpecPackError(SpecPackErrorKind.network, 'Download failed: $e'));
      }
      return Uint8List.fromList(bytes);
    }
  }

  /// Filesystem-safe directory slug for a pack name: a SINGLE path segment that
  /// can never be '', '.', '..', a hidden ('.'-prefixed) name, or contain path
  /// separators. Separators are already mapped to '_'; we then strip leading and
  /// trailing dots/underscores and fall back to 'pack'.
  static String _slug(String name) {
    var slug = name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9._-]+'), '_');
    slug = slug
        .replaceAll(RegExp(r'^[._]+'), '')
        .replaceAll(RegExp(r'[._]+$'), '');
    if (slug.length > 64) slug = slug.substring(0, 64);
    if (slug.isEmpty || slug == '.' || slug == '..') return 'pack';
    return slug;
  }

  /// Reduce a manifest spec entry (which may contain path segments) to a single
  /// safe filename that stays inside the specs/ directory. Unlike a plain
  /// basename, the relative directory structure is FLATTENED into the name (path
  /// separators become '_') so entries that differ only by directory —
  /// 'a/sensor.yaml' vs 'b/sensor.yaml' — map to distinct on-disk files
  /// ('a_sensor.yaml' vs 'b_sensor.yaml') instead of clobbering one another.
  /// '.'/'..'/empty path segments are dropped so no traversal survives, and the
  /// result can never be '', '.', '..', hidden, or contain a separator.
  static String _safeFileName(String entry) {
    // Normalize both separators, then drop dot- and empty segments so a
    // traversal component ('..') can never contribute to the name.
    final segments = entry
        .replaceAll('\\', '/')
        .split('/')
        .where((s) => s.isNotEmpty && s != '.' && s != '..');
    var safe = segments.join('_');
    safe = safe.replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_');
    safe = safe.replaceAll(RegExp(r'^[._]+'), '');
    if (safe.length > 128) safe = safe.substring(0, 128);
    if (safe.isEmpty || safe == '.' || safe == '..') return 'spec.yaml';
    return safe;
  }

  /// Same web origin (scheme + host + port). Host is compared case-insensitively
  /// per RFC 3986. [Uri.port] resolves the default port for the scheme, so
  /// http/https compare correctly.
  static bool _sameOrigin(Uri a, Uri b) =>
      a.scheme == b.scheme &&
      a.host.toLowerCase() == b.host.toLowerCase() &&
      a.port == b.port;

  /// Whether [child] resolves to a location strictly inside [parent]. Paths are
  /// made absolute and dot-segment-normalized before the prefix check, so no
  /// '..' component can slip a write/delete outside [parent].
  static bool _isStrictlyInside(Directory parent, FileSystemEntity child) {
    final parentPath = _canonical(parent.path);
    final childPath = _canonical(child.path);
    final sep = Platform.pathSeparator;
    final prefix = parentPath.endsWith(sep) ? parentPath : '$parentPath$sep';
    return childPath.startsWith(prefix);
  }

  /// Absolute, dot-segment-normalized filesystem path (no symlink resolution, so
  /// it works for paths that do not exist yet).
  static String _canonical(String path) {
    final absolute = Directory(path).absolute.path;
    return Uri.file(absolute).normalizePath().toFilePath();
  }
}

/// Internal control-flow exception; never escapes [SpecPackService].
class _FetchException implements Exception {
  final SpecPackError error;
  _FetchException(this.error);
  SpecPackError toError() => error;
}
