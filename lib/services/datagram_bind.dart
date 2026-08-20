// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:io';

/// Bind a UDP datagram socket, tolerating platforms that reject SO_REUSEPORT.
///
/// Desktop Linux and macOS support SO_REUSEPORT and need it so several listeners
/// can share the mDNS 5353 port. Android's bionic libc does not implement it, so
/// `RawDatagramSocket.bind(..., reusePort: true)` THROWS a `SocketException`
/// there ("reusePort not supported on this platform") rather than falling back.
/// package:multicast_dns's `MDnsClient.start()` always asks for
/// `reusePort: true`, so on Android the whole mDNS transport threw and was lost —
/// the SSDP/LIFX/Kasa transports (which never set reusePort) still ran, which is
/// why a scan found some devices but never the mDNS-only ones.
///
/// The signature matches multicast_dns's `RawDatagramSocketFactory` typedef so
/// this can be passed straight to `MDnsClient(rawDatagramSocketFactory: ...)`.
/// When `reusePort` is requested it is tried first and, if the platform rejects
/// it, the bind is retried once without it — a single MDnsClient owns the port
/// on mobile, so dropping SO_REUSEPORT there costs nothing. `reuseAddress` is
/// honoured unchanged: it is supported everywhere and is the option that lets a
/// bind coexist with a well-behaved holder of the port.
Future<RawDatagramSocket> bindDatagramSocket(
  dynamic host,
  int port, {
  bool reuseAddress = true,
  bool reusePort = false,
  int ttl = 1,
}) {
  Future<RawDatagramSocket> bind({required bool reusePort}) =>
      RawDatagramSocket.bind(host, port,
          reuseAddress: reuseAddress, reusePort: reusePort, ttl: ttl);
  if (!reusePort) return bind(reusePort: false);
  return withReusePortFallback(bind);
}

/// Run [bind] with SO_REUSEPORT enabled; on the `SocketException` a platform
/// without SO_REUSEPORT support throws (Android), run it again with the option
/// disabled and return that instead.
///
/// Kept separate from [bindDatagramSocket] so the fallback decision is testable
/// without a real socket: [bind] is any function of `reusePort`. Only a
/// `SocketException` triggers the retry — any other error (and a second failure
/// of the retry itself) propagates unchanged, so a genuinely unavailable port
/// still surfaces its error instead of being masked.
Future<T> withReusePortFallback<T>(
    Future<T> Function({required bool reusePort}) bind) async {
  try {
    return await bind(reusePort: true);
  } on SocketException {
    return await bind(reusePort: false);
  }
}
