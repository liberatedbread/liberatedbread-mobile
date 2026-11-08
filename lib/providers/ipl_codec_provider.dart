// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/ipl_codec.dart';

final iplCodecProvider = Provider<IplCodec>((ref) => const RustIplCodec());
