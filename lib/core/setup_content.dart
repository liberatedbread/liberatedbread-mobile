// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import '../services/spec_codec.dart' show SetupMethodDto;

/// Non-blank text: the test for whether a piece of `device.setup` prose says
/// anything at all.
bool hasSetupText(String? s) => (s ?? '').trim().isNotEmpty;

/// Whether a setup route says how to do it: a description or some steps.
///
/// The ONE test for "this route has content", shared by the instructions
/// screen (which draws a card only for such a route), its printout, and the
/// Bluetooth pairing guide (which lists a device only when it has one). Kept
/// apart, they drift: a guide row that opens onto a page with no pairing card
/// is a broken link.
bool setupMethodHasContent(SetupMethodDto method) =>
    hasSetupText(method.description) ||
    method.steps.isNotEmpty ||
    method.stages.isNotEmpty;
