// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// Turning thrown objects into text a person should read.

import 'log.dart';

/// An exception whose [message] was written for a user to read.
///
/// Marker interface, so [friendlyErrorText] can tell "this app raised a
/// condition it knows how to explain" apart from "something threw".
abstract class UserFacingException implements Exception {
  String get message;
}

/// Text safe to render for [error].
///
/// Interpolating a caught object into UI (`'$e'`, `e.toString()`) leaks
/// implementation noise: a Dart `StateError` renders as "Bad state: ...", a
/// platform channel failure as "PlatformException(error, ...)", and a plugin
/// may put a file path or an internal code in there. None of that helps the
/// person holding the phone, and some of it shouldn't be on screen at all.
///
/// So: [UserFacingException] messages pass through, because they were written
/// for this. Everything else becomes [fallback] — and the real error goes to
/// the log, where it is useful, tagged with [context] to say which operation
/// failed.
///
/// The log line lands under [Log.ui] by default: "a user-visible operation
/// failed and we showed fallback text". A non-UI caller passes its own
/// category via [log] so the line is filed where a reader would look for it.
String friendlyErrorText(
  Object error, {
  required String fallback,
  String? context,
  Logger? log,
}) {
  if (error is UserFacingException) return error.message;
  (log ?? Log.ui).warning(context ?? 'operation failed', error: error);
  return fallback;
}
