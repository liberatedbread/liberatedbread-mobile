// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/real_spec_codec.dart';
import '../services/spec_codec.dart';

/// Provides the device-spec codec (Rust FFI in production). Override in tests
/// with a fake, mirroring [bleServiceProvider].
final specCodecProvider = Provider<SpecCodec>((ref) => const RealSpecCodec());
