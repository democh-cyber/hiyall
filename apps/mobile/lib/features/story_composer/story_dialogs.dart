import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

/// Asks what to do with an unsent story: 'keep', 'save' (only when [keepable]) or 'discard'.
/// Null when the dialog is dismissed.
Future<String?> showStoryDiscardDialog(
  BuildContext context, {
  required bool keepable,
}) => showDialog<String>(
  context: context,
  builder: (dialog) => AlertDialog(
    title: const Text('Discard draft?'),
    content: Text(
      keepable
          ? 'This story isn’t shared yet. Save it for later or throw it away.'
          : 'This story isn’t shared yet. Your photo will be thrown away.',
    ),
    actions: [
      TextButton(
        key: const Key('keep-editing'),
        onPressed: () => Navigator.pop(dialog, 'keep'),
        child: const Text('Keep editing'),
      ),
      if (keepable)
        TextButton(
          key: const Key('save-draft'),
          onPressed: () => Navigator.pop(dialog, 'save'),
          child: const Text('Save draft'),
        ),
      FilledButton(
        key: const Key('discard-draft'),
        style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
        onPressed: () => Navigator.pop(dialog, 'discard'),
        child: const Text('Discard'),
      ),
    ],
  ),
);

/// Library or camera, for changing the photo. Null when the sheet is dismissed.
Future<ImageSource?> showStoryPhotoSourceSheet(BuildContext context) =>
    showModalBottomSheet<ImageSource>(
      context: context,
      showDragHandle: true,
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library_rounded),
              title: const Text('Photo library'),
              onTap: () => Navigator.pop(sheet, ImageSource.gallery),
            ),
            ListTile(
              leading: const Icon(Icons.photo_camera_rounded),
              title: const Text('Camera'),
              onTap: () => Navigator.pop(sheet, ImageSource.camera),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
