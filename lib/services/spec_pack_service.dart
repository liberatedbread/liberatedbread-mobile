// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../core/ha_url.dart' show isPrivateIpv4;
import '../core/log.dart';
import 'mqtt_session.dart' show effectiveMqttTransportSecurity;
import 'spec_codec.dart';
import 'ws_control_service.dart' show wsCredentialAliasPlaceholder;

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

/// Why a pack spec's YAML would weaken the security of the BUNDLED spec it
/// shadows, or null when it shadows none or is at least as strict. See
/// [SpecPackService.bundledSecurityFloor]; a throw is treated as a refusal.
typedef SpecSecurityFloor = Future<String?> Function(String yaml);

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
    final parsedAt = installedAt is String
        ? DateTime.tryParse(installedAt)
        : null;
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
  /// The manifest URL is not one an install accepts: malformed, not
  /// http(s), or plain `http://` to a host off the local network. The
  /// [SpecPackError.message] says which — see
  /// [SpecPackService.manifestUrlProblem].
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

  /// The floor a pack spec that shadows a bundled one must not go below —
  /// see [bundledSecurityFloor]. Applied at install AND every time the cache
  /// is read ([loadCachedSpecs]), so neither a pack installed by a build
  /// that did not check, nor an app update that made a bundled spec
  /// stricter, lets the weaker copy into the catalogue. Null in unit tests
  /// of the download mechanics.
  final SpecSecurityFloor? _securityFloor;
  final Duration timeout;

  SpecPackService({
    required this._client,
    required CacheDirResolver cacheDirResolver,
    SpecValidator? specValidator,
    this._securityFloor,
    this.timeout = const Duration(seconds: 15),
  }) : _resolveCacheDir = cacheDirResolver,
       _validateSpec = specValidator;

  /// Why [pack]'s transport security is weaker than [bundled]'s, or null.
  ///
  /// A pack spec that shadows a bundled one wins the catalogue (pack-wins,
  /// `specEntriesByKey`), and stored credentials and certificate pins are
  /// keyed by the DEVICE, not the spec — so a pack that said
  /// `tls.verification: none`, or dropped `default_scheme: https`, had the
  /// bundle's Envoy token or Hue username sent under a policy that accepts
  /// any certificate, or in clear. Ranked by what the client can actually
  /// enforce: unstated verification is the blanket-trust fallback, the same
  /// as `none`; `vendor_ca` is served as trust-on-first-use (TlsPolicy).
  ///
  /// [bundledSocket] and [packSocket] are the two specs' WebSocket surfaces
  /// (null when a spec declares none); see [_websocketDowngrade].
  static String? securityDowngrade({
    required NetworkCapabilitiesDto bundled,
    required NetworkCapabilitiesDto pack,
    WebSocketSurfaceDto? bundledSocket,
    WebSocketSurfaceDto? packSocket,
  }) {
    if (bundled.defaultScheme == 'https' && pack.defaultScheme != 'https') {
      return 'plain http where the built-in spec requires https';
    }
    // What the broker socket will actually speak, the declaration or else
    // the port convention — the connector's own rule. Reading only the
    // declaration let a copy of the undeclared Roomba (8883) or Hisense
    // (36669) spec say `plaintext`, or move to 1883, and have the stored
    // broker login sent in clear. An unknown bundled port (discovery
    // decides) is no floor unless the pack pins plaintext.
    final bundledMqtt = effectiveMqttTransportSecurity(
      declared: bundled.mqttTransportSecurity,
      port: bundled.defaultPort,
    );
    final packMqtt = effectiveMqttTransportSecurity(
      declared: pack.mqttTransportSecurity,
      port: pack.defaultPort,
    );
    if ((bundledMqtt == 'tls' && packMqtt != 'tls') ||
        (bundledMqtt == null && packMqtt == 'plaintext')) {
      return 'MQTT without TLS where the built-in spec requires it';
    }

    if (_tlsRank(pack.tlsVerification, pack.tlsSelfSigned) <
        _tlsRank(bundled.tlsVerification, bundled.tlsSelfSigned)) {
      return 'TLS verification '
          '"${pack.tlsVerification ?? 'unstated'}" where the built-in spec '
          'requires "${bundled.tlsVerification}"';
    }
    if (pack.tlsSelfSigned &&
        !bundled.tlsSelfSigned &&
        bundled.tlsVerification != null) {
      return 'a self-signed certificate where the built-in spec does not '
          'allow one';
    }
    return _websocketDowngrade(
      bundled: bundledSocket,
      pack: packSocket,
      bundledHttps: bundled.defaultScheme == 'https',
    );
  }

  /// How strictly a TLS policy checks the certificate: 0 accepts any, 1
  /// pins it, 2 validates the chain. Ranked by what the client can
  /// actually enforce: unstated verification is the blanket-trust fallback,
  /// the same as `none`; `vendor_ca` is served as trust-on-first-use.
  static int _tlsRank(String? verification, bool selfSigned) {
    // A self-signed claim is how the WebSocket path decides to accept
    // any certificate, whatever `verification` says.
    if (selfSigned && verification == null) return 0;
    return switch (verification) {
      null || 'none' => 0,
      'standard' => 2,
      // trust_on_first_use, vendor_ca, and anything newer (TlsPolicy
      // resolves an unknown value to trust-on-first-use).
      _ => 1,
    };
  }

  /// The schemes of [surface]'s connects that carry the stored credential
  /// (named [credentialName] or the surface's own): every connect for
  /// `register_frame` pairing, whose frame sends the key on whatever socket
  /// opened; for a query token, the connects whose path names it.
  static Set<String> _credentialSchemes(
    WebSocketSurfaceDto surface,
    Set<String> credentialNames,
  ) {
    // Every placeholder the sender fills with the credential, not only the
    // spec's own name — see [wsCredentialAliasPlaceholder].
    final names = {
      ...credentialNames,
      ?surface.credentialName,
      wsCredentialAliasPlaceholder,
    };
    bool carries(String path) =>
        surface.pairingMode == 'register_frame' ||
        names.any((n) => path.contains('{$n}'));
    // The fallback exists when it has a port, and inherits the primary's
    // scheme and path when it states none — as WsControlService dials it.
    return {
      if (carries(surface.path)) surface.scheme.toLowerCase(),
      if (surface.fallbackPort != null &&
          carries(surface.fallbackPath ?? surface.path))
        (surface.fallbackScheme ?? surface.scheme).toLowerCase(),
    };
  }

  /// Why [pack]'s WebSocket surface sends the device credential under a
  /// weaker policy than [bundled]'s, or null.
  ///
  /// Samsung's token rides only the wss:8002 connect; a pack moving
  /// `&token={samsung_token}` onto the ws:8001 fallback passed a floor that
  /// read only the HTTP scheme, and the token went out in clear. The floor
  /// is relative: a bundled spec that already sends its key over ws (LG's
  /// register frame on 3000) sets none. With no bundled surface, an https
  /// spec is the floor — a pack must not add a clear socket carrying a
  /// credential the bundle only sent under TLS.
  static String? _websocketDowngrade({
    required WebSocketSurfaceDto? bundled,
    required WebSocketSurfaceDto? pack,
    required bool bundledHttps,
  }) {
    if (pack == null) return null;
    final names = {?bundled?.credentialName, ?pack.credentialName};
    final packSchemes = _credentialSchemes(pack, names);
    if (!packSchemes.contains('ws')) {
      if (bundled == null) return null;
      if (_tlsRank(pack.tlsVerification, pack.tlsSelfSigned) <
          _tlsRank(bundled.tlsVerification, bundled.tlsSelfSigned)) {
        return 'WebSocket TLS verification '
            '"${pack.tlsVerification ?? 'unstated'}" where the built-in '
            'spec requires "${bundled.tlsVerification}"';
      }
      return null;
    }
    final bundledSchemes = bundled == null
        ? (bundledHttps ? const {'wss'} : const <String>{})
        : _credentialSchemes(bundled, names);
    if (bundledSchemes.isNotEmpty && !bundledSchemes.contains('ws')) {
      return 'a WebSocket credential over plain ws where the built-in spec '
          'sends it only over wss';
    }
    return null;
  }

  /// The production [SpecSecurityFloor]: the pack spec is compared with the
  /// bundled spec of the same identity (device name + manufacturer — the
  /// shadowing key), and refused when [securityDowngrade] finds it weaker.
  ///
  /// [bundledSpecs] must be the bundled catalogue ONLY: the floor runs while
  /// the merged one is still being built. It is parsed once, lazily, on the
  /// first pack spec checked — a user with no packs never pays for it.
  static SpecSecurityFloor bundledSecurityFloor({
    required SpecCodec codec,
    required Future<Map<String, String>> Function() bundledSpecs,
  }) {
    Future<Map<(String, String), String>>? byIdentity;
    Future<Map<(String, String), String>> load() async {
      final catalogue = await codec.loadCatalogue(await bundledSpecs());
      return {
        for (final e in catalogue.specs) (e.deviceName, e.manufacturer): e.yaml,
      };
    }

    return (yaml) async {
      final spec = await codec.loadDeviceSpec(yaml);
      // Not latched on failure: a bundle read that failed once must not
      // refuse every pack for the life of the process.
      final bundled = await (byIdentity ??= load().catchError((Object e) {
        byIdentity = null;
        throw e;
      }));
      final original = bundled[(spec.deviceName, spec.manufacturer)];
      if (original == null) return null;
      return securityDowngrade(
        bundled: await codec.networkCapabilities(specYaml: original),
        pack: await codec.networkCapabilities(specYaml: yaml),
        bundledSocket: await codec.websocketSurface(original),
        packSocket: await codec.websocketSurface(yaml),
      );
    };
  }

  /// [_securityFloor]'s verdict on [yaml], failing closed: a check that
  /// throws is a refusal, because the alternative is letting an unchecked
  /// pack spec shadow a bundled one.
  Future<String?> _belowFloor(String yaml) async {
    final floor = _securityFloor;
    if (floor == null) return null;
    try {
      return await floor(yaml);
    } catch (e) {
      Log.packs.warning('could not check a pack spec\'s security', error: e);
      return 'its security could not be checked';
    }
  }

  /// Whether [input] is a manifest URL an install would accept — see
  /// [manifestUrlProblem] for the reason when it is not.
  static bool isValidManifestUrl(String input) =>
      manifestUrlProblem(input) == null;

  /// Why [input] cannot be installed from, or null when it can.
  ///
  /// A well-formed `https://` URL always can. A plain `http://` one can only
  /// when its host is on the user's own network (loopback, RFC 1918,
  /// link-local — the address of a laptop serving a pack under development),
  /// because a pack decides what the app sends to LAN devices, which
  /// stored credentials fill the requests, and each device's TLS policy —
  /// and nothing on the install path checks a hash or a signature. Fetched
  /// in clear across the internet, all of that is whatever the network on
  /// the way chose to hand over; the banner check, which decides far less,
  /// has refused non-https since it was written. Redirects are followed only
  /// to the same origin ([_fetch]), so an https install cannot be downgraded
  /// on the way either.
  static SpecPackError? manifestUrlProblem(String input) {
    const invalid = SpecPackError(
      SpecPackErrorKind.invalidUrl,
      'Enter a valid http(s) URL.',
    );
    final trimmed = input.trim();
    if (trimmed.isEmpty || trimmed.contains(RegExp(r'\s'))) return invalid;
    final uri = Uri.tryParse(trimmed);
    if (uri == null || uri.host.isEmpty) return invalid;
    switch (uri.scheme) {
      case 'https':
        return null;
      case 'http':
        if (isLocalNetworkHost(uri.host)) return null;
        return const SpecPackError(
          SpecPackErrorKind.invalidUrl,
          'Spec packs are installed over https only. A plain http:// address '
          'is accepted just for a server on your own network (a private or '
          'loopback address such as 192.168.x.x or localhost).',
        );
      default:
        return invalid;
    }
  }

  /// Whether [host] (as [Uri.host] spells it — an IPv6 literal without its
  /// brackets) names something on the user's own network: `localhost`, an
  /// RFC 1918 / loopback / link-local IPv4 literal, or an IPv6 loopback,
  /// unique-local or link-local literal. A DNS name other than `localhost`
  /// is not, whatever it resolves to: the resolution is the attacker's too.
  @visibleForTesting
  static bool isLocalNetworkHost(String host) {
    final lower = host.toLowerCase();
    if (lower == 'localhost' || lower.endsWith('.localhost')) return true;
    if (isPrivateIpv4(lower)) return true;
    // An IPv6 literal, with any zone id (`fe80::1%en0`) set aside.
    final address = InternetAddress.tryParse(lower.split('%').first);
    if (address == null || address.type != InternetAddressType.IPv6) {
      return false;
    }
    if (address.isLoopback || address.isLinkLocal) return true;
    // fc00::/7 — unique local.
    return (address.rawAddress[0] & 0xfe) == 0xfc;
  }

  /// Fetch [manifestUrl], download the specs it lists, and cache the lot. Any
  /// previously-cached pack with the same name is replaced. Never throws.
  Future<InstallResult> install(String manifestUrl) async {
    final url = manifestUrl.trim();
    final problem = manifestUrlProblem(url);
    if (problem != null) {
      Log.packs.warning('install refused: ${problem.kind.name}');
      return InstallFailed(problem);
    }
    final manifestUri = Uri.parse(url);
    Log.packs.info('installing from ${logSafeUrl(manifestUri)}');

    // 1. Fetch the manifest.
    final Uint8List manifestBytes;
    // Where the manifest was actually SERVED from. A same-origin redirect
    // that moves the path (/pack.json -> /v2/pack.json, a canonicalised
    // trailing slash) changes the base every relative spec entry resolves
    // against; resolving against the URL the user typed fetched from the
    // wrong directory and reported that none of the specs could be
    // downloaded. The same-origin guard below still uses the original.
    final Uri manifestBase;
    try {
      final fetched = await _fetch(
        manifestUri,
        SpecPackLimits.maxManifestBytes,
      );
      manifestBytes = fetched.bytes;
      manifestBase = fetched.uri;
    } on _FetchException catch (e) {
      Log.packs.warning('manifest fetch failed: ${e.error.message}');
      return InstallFailed(e.toError());
    }
    final SpecPackManifest? manifest;
    try {
      manifest = SpecPackManifest.tryParse(utf8.decode(manifestBytes));
    } on FormatException {
      Log.packs.warning('manifest rejected: not valid UTF-8 text');
      return const InstallFailed(
        SpecPackError(
          SpecPackErrorKind.malformedManifest,
          'The manifest was not valid UTF-8 text.',
        ),
      );
    }
    if (manifest == null) {
      Log.packs.warning('manifest rejected: not a valid spec-pack manifest');
      return const InstallFailed(
        SpecPackError(
          SpecPackErrorKind.malformedManifest,
          'The manifest is not a valid spec-pack manifest.',
        ),
      );
    }
    Log.packs.debug(
      'manifest "${manifest.name}" v${manifest.version} lists '
      '${manifest.specs.length} spec(s)',
    );

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
        failures.add(
          SpecDownloadFailure(
            specFile,
            'spec path must be relative and same-origin',
          ),
        );
        continue;
      }
      final specUri = manifestBase.resolve(specFile);
      if (specUri.scheme != 'http' && specUri.scheme != 'https') {
        failures.add(SpecDownloadFailure(specFile, 'unsupported URL scheme'));
        continue;
      }
      if (!_sameOrigin(manifestUri, specUri)) {
        failures.add(
          SpecDownloadFailure(specFile, 'cross-origin spec URL rejected'),
        );
        continue;
      }
      final remaining = SpecPackLimits.maxTotalBytes - totalBytes;
      if (remaining <= 0) {
        failures.add(
          SpecDownloadFailure(specFile, 'total download size cap reached'),
        );
        continue;
      }
      final cap = remaining < SpecPackLimits.maxSpecBytes
          ? remaining
          : SpecPackLimits.maxSpecBytes;
      try {
        final bytes = (await _fetch(specUri, cap)).bytes;
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
            failures.add(
              SpecDownloadFailure(specFile, 'not a valid device spec'),
            );
            continue;
          }
        }
        final weaker = await _belowFloor(text);
        if (weaker != null) {
          failures.add(
            SpecDownloadFailure(
              specFile,
              'weakens the built-in spec it replaces: $weaker',
            ),
          );
          continue;
        }
        downloaded[specFile] = bytes;
        totalBytes += bytes.length;
      } on _FetchException catch (e) {
        failures.add(SpecDownloadFailure(specFile, e.error.message));
      }
    }

    if (downloaded.isEmpty) {
      Log.packs.warning(
        'install failed: none of the ${manifest.specs.length} '
        'spec(s) could be downloaded — ${_summarize(failures)}',
      );
      return const InstallFailed(
        SpecPackError(
          SpecPackErrorKind.noSpecsInstalled,
          'None of the specs in the manifest could be downloaded.',
        ),
      );
    }

    // 3. Persist to the cache (replace any same-named pack).
    final SpecPack pack;
    try {
      final persisted = await _persist(manifest, url, downloaded);
      pack = persisted.pack;
      // Specs dropped at write time (on-disk name collisions) join the
      // download-time partial failures so the UI can surface every skip.
      failures.addAll(persisted.failures);
    } on _PackNameCollision catch (e) {
      Log.packs.warning('install refused: ${e.message}');
      return InstallFailed(SpecPackError(SpecPackErrorKind.cacheIo, e.message));
    } on Object catch (e) {
      // cacheIo is the one error kind whose message the settings screen shows
      // verbatim, so it has to read like a sentence; the raw failure (a path,
      // an errno) is for the log, not the user.
      Log.packs.error(
        'install failed: could not write the pack to storage',
        error: e,
      );
      return const InstallFailed(
        SpecPackError(
          SpecPackErrorKind.cacheIo,
          'Could not save the pack to this device\'s storage.',
        ),
      );
    }
    // One aggregate line, not one per spec: a manifest may list up to
    // SpecPackLimits.maxSpecCount entries and this must not become a wall.
    if (failures.isNotEmpty) {
      Log.packs.warning(
        '${failures.length} spec(s) skipped: ${_summarize(failures)}',
      );
    }
    Log.packs.info(
      'installed "${pack.name}" v${pack.version}: '
      '${pack.specCount} spec(s) cached',
    );
    return InstallOk(pack, partialFailures: failures);
  }

  /// The first few [failures] as one line, for a log that must stay scannable.
  static String _summarize(List<SpecDownloadFailure> failures) {
    const shown = 3;
    final head = failures
        .take(shown)
        .map((f) => '${f.specFile} (${f.reason})')
        .join(', ');
    return failures.length > shown
        ? '$head, and ${failures.length - shown} more'
        : head;
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
    await _restoreSwappedAside(root);
    await for (final entry in root.list()) {
      if (entry is! Directory) continue;
      // `.staging-<slug>` and `.old-<slug>` hold a manifest too, and are no
      // pack: a staging directory left by a crash mid-install was listed as
      // a second copy of the pack, one that "remove" could never delete.
      if (entry.uri.pathSegments
          .lastWhere((p) => p.isNotEmpty)
          .startsWith('.')) {
        continue;
      }
      final manifestFile = File('${entry.path}/manifest.json');
      if (!await manifestFile.exists()) continue;
      try {
        final pack = SpecPack.tryFromJson(await manifestFile.readAsString());
        if (pack != null) {
          packs.add(pack);
        } else {
          Log.packs.warning(
            'skipping corrupt pack record ${manifestFile.path}',
          );
        }
      } catch (e) {
        // Skip an unreadable/corrupt pack record, but make the drop visible.
        Log.packs.warning(
          'skipping unreadable pack record ${manifestFile.path}',
          error: e,
        );
      }
    }
    packs.sort((a, b) => b.installedAt.compareTo(a.installedAt));
    return packs;
  }

  /// Where [_persist] moves the installed pack while it swaps the new one
  /// in. Dot-prefixed, which `_slug` strips, so no pack can own the name.
  static const String _asidePrefix = '.old-';

  /// Put back a pack [_persist] had renamed aside when it died before the
  /// new one took its place; drop one whose replacement did land.
  Future<void> _restoreSwappedAside(Directory root) async {
    try {
      await for (final entry in root.list()) {
        if (entry is! Directory) continue;
        final name = entry.uri.pathSegments.lastWhere((p) => p.isNotEmpty);
        if (!name.startsWith(_asidePrefix)) continue;
        final slug = name.substring(_asidePrefix.length);
        final home = Directory('${root.path}/$slug');
        if (await home.exists()) {
          await entry.delete(recursive: true);
        } else {
          await entry.rename(home.path);
        }
      }
    } catch (e) {
      Log.packs.warning('could not tidy an interrupted pack swap', error: e);
    }
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
      Log.packs.warning(
        'could not list cached packs; falling back to bundled specs only',
        error: e,
      );
      return result;
    }
    if (packs.isEmpty) return result;
    // One root resolution for the whole walk, not one per pack.
    final root = await _cacheRoot();
    for (final pack in packs) {
      final dir = _packDir(root, pack.name);
      for (final file in pack.specFiles) {
        try {
          final f = File('${dir.path}/specs/${_safeFileName(file)}');
          if (await f.exists()) {
            final yaml = await f.readAsString();
            // Re-checked on every read, not only at install: see
            // [_securityFloor] for the two ways past an install-only check.
            final weaker = await _belowFloor(yaml);
            if (weaker != null) {
              Log.packs.warning(
                'skipping pack:${pack.name}/$file: it weakens the built-in '
                'spec it replaces ($weaker)',
              );
              continue;
            }
            result['pack:${pack.name}/$file'] = yaml;
          } else {
            Log.packs.warning(
              'cached spec missing on disk: pack:${pack.name}/$file',
            );
          }
        } catch (e) {
          Log.packs.warning(
            'skipping unreadable cached spec pack:${pack.name}/$file',
            error: e,
          );
        }
      }
    }
    Log.packs.debug(
      'loaded ${result.length} cached spec(s) from '
      '${packs.length} pack(s)',
    );
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
    if (!_isStrictlyInside(root, dir)) {
      Log.packs.warning('refusing to remove pack "$name": unsafe path');
      return;
    }
    if (await dir.exists()) await dir.delete(recursive: true);
    Log.packs.info('removed pack "$name"');
  }

  /// Delete every cached pack. Never throws.
  Future<void> clearCache() async {
    try {
      final root = await _cacheRoot();
      if (await root.exists()) await root.delete(recursive: true);
      Log.packs.info('pack cache cleared');
    } catch (e) {
      // Best-effort.
      Log.packs.warning('could not clear the pack cache', error: e);
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
          // R-062: a real answer, not a storage failure. Two pack names can
          // reduce to the same directory slug ("My Pack" and "My/Pack"), and
          // the user was told their device could not save the pack — which
          // is untrue, unactionable, and sends them looking at free space.
          throw _PackNameCollision(manifest.name, stored.name);
        }
      } catch (e) {
        // Only a manifest we could not READ is "corrupt: delete and replace".
        // An answer this method deliberately raised — the unsafe-directory
        // StateError above, or the name collision — has to travel: swallowing
        // _PackNameCollision here let _persist carry on and recursively delete
        // the OTHER pack's directory, which is exactly what it exists to
        // prevent, and made the `on _PackNameCollision` handler in install()
        // unreachable.
        if (e is StateError || e is _PackNameCollision) rethrow;
        // Corrupt manifest: delete and replace.
      }
    }

    // Write into a staging directory and swap atomically so a partial write
    // never replaces a valid cached pack.
    //
    // R-062: the staging name is dot-prefixed, which `_slug` strips, so no
    // pack can ever be given this directory. It used to be `<slug>.staging`,
    // a name a pack could hold itself — installing "foo" then deleted the
    // installed pack "foo.staging" without a word.
    final stagingDir = Directory(
      '${root.path}/.staging-${_slug(manifest.name)}',
    );
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
    //
    // R-061: compared case-INSENSITIVELY, because the volume this writes to
    // is. On iOS and macOS the app's Application Support directory is
    // case-insensitive, so "Bulb.yaml" and "bulb.yaml" passed a
    // case-sensitive check and then clobbered each other on disk, leaving
    // both keys in the metadata and one of them serving the other's spec.
    final usedNames = <String>{};
    for (final entry in specs.entries) {
      final safeName = _safeFileName(entry.key);
      if (!usedNames.add(safeName.toLowerCase())) {
        failures.add(
          SpecDownloadFailure(
            entry.key,
            'on-disk name "$safeName" collides with another spec in this pack',
          ),
        );
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
    await File(
      '${stagingDir.path}/manifest.json',
    ).writeAsString(jsonEncode(pack.toJson()), flush: true);

    // The swap, only after all writes succeed. The old pack is renamed
    // aside, not deleted first: deleting it and then failing the rename (or
    // dying between the two) lost the installed pack. A crash between the
    // renames leaves `.old-<slug>` and no `<slug>`, which
    // [listInstalledPacks] puts back.
    final aside = Directory(
      '${root.path}/$_asidePrefix${_slug(manifest.name)}',
    );
    if (await aside.exists()) await aside.delete(recursive: true);
    final hadOld = await dir.exists();
    if (hadOld) await dir.rename(aside.path);
    try {
      await stagingDir.rename(dir.path);
    } catch (_) {
      if (hadOld) await aside.rename(dir.path);
      rethrow;
    }
    if (hadOld) {
      try {
        await aside.delete(recursive: true);
      } catch (e) {
        Log.packs.debug('could not delete ${aside.path}', error: e);
      }
    }
    return (pack: pack, failures: failures);
  }

  /// Largest number of redirect hops we will follow (all same-origin).
  static const int _maxRedirects = 5;

  /// Where the pack cache lives, moving it once out of where it used to.
  ///
  /// Packs were cached under the app's Documents directory, which iOS backs
  /// up to iCloud and Finder and which Apple reserves for user-created data;
  /// a pack is app-managed, re-downloadable content (up to 4 MB each, no
  /// count limit). Application Support is the directory for exactly that.
  /// Caches would not be backed up at all, but the system may purge it, and
  /// a pack the user installed vanishing between launches is worse than a
  /// few megabytes in a backup.
  ///
  /// The move is a rename, so it is atomic on the same volume and costs
  /// nothing after the first launch; a rename that fails leaves the packs
  /// where they were and the resolver keeps answering the old location, so
  /// nothing is lost either way. Pure over its two inputs, so the unit test
  /// can run it against temp directories.
  static Future<Directory> migrateCacheDir({
    required Directory legacyBase,
    required Directory base,
  }) async {
    final legacy = Directory('${legacyBase.path}/spec_packs');
    final target = Directory('${base.path}/spec_packs');
    if (await legacy.exists() && !await target.exists()) {
      try {
        await base.create(recursive: true);
        await legacy.rename(target.path);
        Log.packs.info('moved the spec-pack cache out of Documents');
      } catch (e) {
        Log.packs.warning(
          'could not move the spec-pack cache; keeping it '
          'where it is',
          error: e,
        );
        return legacyBase;
      }
    }
    return base;
  }

  /// GET [uri], enforcing [timeout] and a [maxBytes] size cap. Redirects are NOT
  /// auto-followed by the client; we follow them manually and ONLY when they
  /// stay on the original origin, so a redirect can't be used to reach a
  /// cross-origin/internal host. Translates every failure into a
  /// [_FetchException]. Returns the bytes with the URI they were finally
  /// served from, which after a redirect is not [uri].
  Future<({Uint8List bytes, Uri uri})> _fetch(Uri uri, int maxBytes) async {
    final origin = uri;
    var current = uri;
    for (var hop = 0; ; hop++) {
      http.StreamedResponse response;
      try {
        final request = http.Request('GET', current)..followRedirects = false;
        response = await _client.send(request).timeout(timeout);
      } on TimeoutException {
        throw _FetchException(
          const SpecPackError(
            SpecPackErrorKind.timeout,
            'The request timed out.',
          ),
        );
      } on http.ClientException catch (e) {
        throw _FetchException(
          SpecPackError(
            SpecPackErrorKind.network,
            'Could not connect: ${e.message}',
          ),
        );
      } on SocketException catch (e) {
        throw _FetchException(
          SpecPackError(
            SpecPackErrorKind.network,
            'Could not connect: ${e.message}',
          ),
        );
      } on Object catch (e) {
        throw _FetchException(
          SpecPackError(SpecPackErrorKind.network, 'Request failed: $e'),
        );
      }

      // Manual, same-origin-only redirect handling.
      if (response.statusCode >= 300 && response.statusCode < 400) {
        unawaited(response.stream.drain<void>().catchError((_) {}));
        final location = response.headers['location'];
        if (location == null || location.isEmpty) {
          throw _FetchException(
            SpecPackError(
              SpecPackErrorKind.http,
              'Redirect (HTTP ${response.statusCode}) without a location.',
            ),
          );
        }
        if (hop >= _maxRedirects) {
          throw _FetchException(
            const SpecPackError(
              SpecPackErrorKind.network,
              'Too many redirects.',
            ),
          );
        }
        final next = current.resolve(location);
        if (!_sameOrigin(origin, next)) {
          throw _FetchException(
            const SpecPackError(
              SpecPackErrorKind.network,
              'Refused a cross-origin redirect.',
            ),
          );
        }
        current = next;
        continue;
      }

      if (response.statusCode < 200 || response.statusCode >= 300) {
        // Drain so the connection can be reused/closed cleanly.
        unawaited(response.stream.drain<void>().catchError((_) {}));
        throw _FetchException(
          SpecPackError(
            SpecPackErrorKind.http,
            'Server returned HTTP ${response.statusCode}.',
          ),
        );
      }

      final contentLength = response.contentLength;
      if (contentLength != null && contentLength > maxBytes) {
        unawaited(response.stream.drain<void>().catchError((_) {}));
        throw _FetchException(
          const SpecPackError(
            SpecPackErrorKind.tooLarge,
            'The file is larger than allowed.',
          ),
        );
      }

      final bytes = <int>[];
      try {
        await for (final chunk in response.stream.timeout(timeout)) {
          bytes.addAll(chunk);
          if (bytes.length > maxBytes) {
            throw _FetchException(
              const SpecPackError(
                SpecPackErrorKind.tooLarge,
                'The file is larger than allowed.',
              ),
            );
          }
        }
      } on _FetchException {
        rethrow;
      } on TimeoutException {
        throw _FetchException(
          const SpecPackError(
            SpecPackErrorKind.timeout,
            'The download stalled.',
          ),
        );
      } on Object catch (e) {
        throw _FetchException(
          SpecPackError(SpecPackErrorKind.network, 'Download failed: $e'),
        );
      }
      return (bytes: Uint8List.fromList(bytes), uri: current);
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

/// Two pack names that reduce to the same cache directory.
///
/// Its own type so the install path can tell it from a storage failure: the
/// device is fine, the two packs simply cannot both be called what they are
/// called (R-062).
class _PackNameCollision implements Exception {
  final String incoming;
  final String existing;

  const _PackNameCollision(this.incoming, this.existing);

  String get message =>
      'A pack called "$existing" is already installed under the same name on '
      'disk, so "$incoming" cannot be installed alongside it. Remove the '
      'other pack first.';

  @override
  String toString() => message;
}
