import 'package:flutter/material.dart';

import '../core/avatar_upload.dart';

enum AvatarAction { gallery, camera, remove }

/// What to do about a profile photo. The camera is offered on phones only,
/// and removing only when there is a photo to remove. When that leaves just
/// the gallery, there is nothing to choose between and it opens straight away.
Future<AvatarAction?> showAvatarSheet(
  BuildContext context, {
  required bool hasPhoto,
}) async {
  if (!canTakePhoto && !hasPhoto) return AvatarAction.gallery;
  return showModalBottomSheet<AvatarAction>(
    context: context,
    showDragHandle: true,
    builder: (sheet) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            key: const Key('avatar-gallery'),
            leading: const Icon(Icons.photo_library_outlined),
            title: const Text('Choose from gallery'),
            onTap: () => Navigator.pop(sheet, AvatarAction.gallery),
          ),
          if (canTakePhoto)
            ListTile(
              key: const Key('avatar-camera'),
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('Take a photo'),
              onTap: () => Navigator.pop(sheet, AvatarAction.camera),
            ),
          if (hasPhoto)
            ListTile(
              key: const Key('avatar-remove'),
              leading: const Icon(Icons.delete_outline_rounded),
              title: const Text('Remove photo'),
              onTap: () => Navigator.pop(sheet, AvatarAction.remove),
            ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
}
