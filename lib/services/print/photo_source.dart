// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

/// Where a photo for a label comes from. Tests override the provider.
abstract class PhotoSource {
  /// Whether this platform has a camera the picker can open (not Linux).
  bool get canUseCamera;

  /// The chosen photo's encoded bytes, or null when the user backed out.
  Future<Uint8List?> pick({required bool camera});

  /// An image file from a file dialog, or null when none was chosen.
  Future<Uint8List?> pickFile();
}

class PlatformPhotoSource implements PhotoSource {
  final ImagePicker _picker = ImagePicker();

  @override
  bool get canUseCamera => _picker.supportsImageSource(ImageSource.camera);

  @override
  Future<Uint8List?> pick({required bool camera}) async {
    final file = await _picker.pickImage(
      source: camera ? ImageSource.camera : ImageSource.gallery,
      // A label printer is at most a couple of thousand dots wide; a full
      // camera frame is only memory.
      maxWidth: 2400,
      maxHeight: 2400,
    );
    return file?.readAsBytes();
  }

  @override
  Future<Uint8List?> pickFile() async {
    final file = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(
          label: 'Images',
          extensions: ['png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp'],
          mimeTypes: ['image/*'],
          uniformTypeIdentifiers: ['public.image'],
        ),
      ],
    );
    return file?.readAsBytes();
  }
}

final photoSourceProvider = Provider<PhotoSource>(
  (ref) => PlatformPhotoSource(),
);
