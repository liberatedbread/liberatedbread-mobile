// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';

import 'spec_codec.dart' show SoapRequestDto;

/// The transport half of network device control: fetch a UPnP device
/// description, resolve control URLs from it, POST a rendered SOAP request,
/// and parse the reply into name→value pairs.
///
/// Deliberately knows nothing about any device. What to send and what a
/// returned value means live in the spec and are answered by the Rust codec;
/// this class only moves bytes — the same division as BLE, where the platform
/// channel reads a characteristic and Rust decodes it. Everything here
/// follows rules the Wemo spec publishes (`soap_common`, `discovery`), but
/// none of them are Wemo-specific: they are how UPnP control works.
class SoapControlClient {
  final http.Client _http;

  /// One request's ceiling. Wemo devices have a handful of worker threads and
  /// crash when hammered, so the spec's guidance is patient timeouts over
  /// eager retries; 10 s matches pywemo's REQUESTS_TIMEOUT.
  static const timeout = Duration(seconds: 10);

  /// Largest response body this client will buffer. Descriptions and SOAP
  /// envelopes are a few KB; anything past half a megabyte is not a device
  /// we can drive, it is a broken or hostile host on the local network —
  /// and the host chooses the size, so an uncapped read is an allocation
  /// the LAN controls. (`package:http`'s convenience helpers buffer to
  /// completion with no cap, which is why requests go through [_bounded].)
  static const maxResponseBytes = 512 * 1024;

  SoapControlClient({http.Client? httpClient})
      : _http = httpClient ?? http.Client();

  /// Send [request] and buffer its body, refusing past [maxResponseBytes].
  ///
  /// The size cap has to sit on the stream read: the convenience helpers
  /// buffer the whole body before handing it over, so by the time a caller
  /// could measure it the allocation has happened. The deadline is one
  /// `Future.timeout` around the whole exchange, exactly the shape the old
  /// `get(...).timeout(...)` had — deliberately not `Stream.timeout` on the
  /// body, which never delivers events under flutter_test's fake async.
  Future<http.Response> _bounded(http.Request request) {
    return () async {
      final streamed = await _http.send(request);
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in streamed.stream) {
        bytes.add(chunk);
        if (bytes.length > maxResponseBytes) {
          throw SoapTransportException(
              '${request.url} sent more than $maxResponseBytes bytes; '
              'refusing to buffer further');
        }
      }
      return http.Response.bytes(
        bytes.takeBytes(),
        streamed.statusCode,
        request: request,
        headers: streamed.headers,
        reasonPhrase: streamed.reasonPhrase,
      );
    }()
        .timeout(timeout);
  }

  /// Fetch and parse `http://host:port/setup.xml`.
  ///
  /// The description is the device's own statement of where its services
  /// live. Control paths are resolved from it rather than hardcoded because
  /// the published spellings vary across firmware generations — the one rule
  /// the spec repeats more than any other.
  Future<SoapDeviceDescription> fetchDescription(String host, int port) async {
    final uri = Uri(scheme: 'http', host: host, port: port, path: '/setup.xml');
    final response = await _bounded(http.Request('GET', uri));
    if (response.statusCode != 200) {
      throw SoapTransportException(
          'description fetch failed: HTTP ${response.statusCode} from $uri');
    }
    return SoapDeviceDescription.parse(response.body, host: host, port: port);
  }

  /// POST one rendered request to the device and return the response values.
  ///
  /// [controlPath] is the path resolved from the device's description for
  /// [request]'s service — fall back to `request.path` only when the
  /// description does not list the service at all.
  Future<Map<String, String>> send(
    String host,
    int port,
    String controlPath,
    SoapRequestDto request,
  ) async {
    final uri = Uri(scheme: 'http', host: host, port: port, path: controlPath);
    final httpRequest = http.Request('POST', uri)
      ..headers.addAll({
        // The quotes in SOAPACTION are part of the value; the DTO carries
        // them already. Charset spelling is the one the spec publishes.
        'Content-Type': 'text/xml; charset="utf-8"',
        'SOAPACTION': request.soapAction,
      })
      ..body = request.body;
    final response = await _bounded(httpRequest);
    if (response.statusCode != 200) {
      // UPnP delivers action-level errors as HTTP 500 with a Fault body,
      // and that fault detail is the only diagnostics the device offers —
      // read it before writing the reply off as a transport failure.
      if (response.statusCode == 500) {
        try {
          parseSoapResponse(response.body, action: request.action);
        } on SoapFaultException {
          rethrow;
        } catch (_) {
          // Not a SOAP body after all; report the transport error below.
        }
      }
      throw SoapTransportException(
          '${request.action} failed: HTTP ${response.statusCode} from $uri');
    }
    return parseSoapResponse(response.body, action: request.action);
  }

  /// Parse a SOAP response envelope into its named return values.
  ///
  /// The spec's rule verbatim: envelope → Body → first child →
  /// `{child.tag: child.text}`, matching on local names because namespace
  /// prefixes vary. A Body whose child is a Fault is an error, and the fault
  /// text is worth surfacing — it is the only diagnostics the device offers.
  static Map<String, String> parseSoapResponse(String xml,
      {required String action}) {
    final XmlDocument document;
    try {
      document = XmlDocument.parse(xml);
    } on XmlException catch (e) {
      throw SoapTransportException('$action returned unparseable XML: $e');
    }
    final body = document.rootElement.childElements.where(
      (e) => e.localName == 'Body',
    );
    if (body.isEmpty) {
      throw SoapTransportException('$action response has no Body element');
    }
    final children = body.first.childElements;
    if (children.isEmpty) {
      throw SoapTransportException('$action response Body is empty');
    }
    final first = children.first;
    if (first.localName == 'Fault') {
      throw SoapFaultException(action: action, detail: first.innerText.trim());
    }
    return {
      for (final value in first.childElements) value.localName: value.innerText,
    };
  }
}

/// A parsed UPnP device description — the identity fields the app shows and
/// the service list control URLs are resolved from.
class SoapDeviceDescription {
  final String host;
  final int port;
  final String? friendlyName;
  final String? deviceType;
  final String? udn;
  final String? serialNumber;
  final String? firmwareVersion;

  /// serviceType URN → controlURL, exactly as the device stated them.
  final Map<String, String> controlUrls;

  const SoapDeviceDescription({
    required this.host,
    required this.port,
    required this.controlUrls,
    this.friendlyName,
    this.deviceType,
    this.udn,
    this.serialNumber,
    this.firmwareVersion,
  });

  /// Parse a description document.
  ///
  /// Matches on local element names throughout: the spec records that some
  /// firmware serves the document without the UPnP namespace, and requiring
  /// it would lose exactly those devices.
  factory SoapDeviceDescription.parse(String xml,
      {required String host, required int port}) {
    final XmlDocument document;
    try {
      document = XmlDocument.parse(xml);
    } on XmlException catch (e) {
      throw SoapTransportException('setup.xml is unparseable: $e');
    }
    final device = document.descendantElements
        .where((e) => e.localName == 'device')
        .firstOrNull;
    if (device == null) {
      throw const SoapTransportException('setup.xml has no <device> element');
    }

    String? text(String name) => device.childElements
        .where((e) => e.localName == name)
        .firstOrNull
        ?.innerText
        .trim();

    final controlUrls = <String, String>{};
    for (final service
        in device.descendantElements.where((e) => e.localName == 'service')) {
      String? field(String name) => service.childElements
          .where((e) => e.localName == name)
          .firstOrNull
          ?.innerText
          .trim();
      final type = field('serviceType');
      final url = field('controlURL');
      if (type != null && url != null && type.isNotEmpty && url.isNotEmpty) {
        controlUrls[type] = url;
      }
    }

    return SoapDeviceDescription(
      host: host,
      port: port,
      friendlyName: text('friendlyName'),
      deviceType: text('deviceType'),
      udn: text('UDN'),
      serialNumber: text('serialNumber'),
      firmwareVersion: text('firmwareVersion'),
      controlUrls: controlUrls,
    );
  }

  /// The control path for one request: the device's own answer for the
  /// request's service, else the spec's conventional path.
  ///
  /// Null when neither knows — a real outcome (the WiFiSetup service is only
  /// listed in setup mode), and the caller should say the device does not
  /// offer the service rather than POST to a guessed path.
  String? controlPathFor(SoapRequestDto request) =>
      controlUrls[request.service] ?? request.path;
}

/// The transport failed: unreachable host, non-200, unparseable reply.
class SoapTransportException implements Exception {
  final String message;
  const SoapTransportException(this.message);
  @override
  String toString() => 'SoapTransportException: $message';
}

/// The device answered with a SOAP Fault — it understood the request and
/// refused it, which is different from not being reachable at all.
class SoapFaultException implements Exception {
  final String action;
  final String detail;
  const SoapFaultException({required this.action, required this.detail});
  @override
  String toString() => 'SoapFaultException: $action was refused'
      '${detail.isEmpty ? '' : ' ($detail)'}';
}

extension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
