// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/real_spec_codec.dart';
import '../services/spec_codec.dart';

/// Provides the device-spec codec (Rust FFI in production). Override in tests
/// with a fake, mirroring [bleServiceProvider].
/// One codec per container, not a shared const: the real one holds the
/// parses it is asked about repeatedly (see [RealSpecCodec]), and that state
/// belongs to the container that owns the catalogue.
final specCodecProvider = Provider<SpecCodec>((ref) => RealSpecCodec());
