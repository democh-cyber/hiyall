import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show CustomSemanticsAction;

import '../../core/api.dart';
import '../../core/avatar_upload.dart';
import '../../shared/chat_tokens.dart';
import '../../shared/person_avatar.dart' show photoProvider;
import '../../shared/press_scale.dart';
import 'profile_form_widgets.dart';
import 'profile_photos_controller.dart';

/// "Your photos": up to eight, the first one is the profile photo. Add, replace, delete and put in order without
/// dragging: every photo has actions "Make profile photo", "Move earlier", "Move later", "Replace" and "Remove",
/// in its menu and for screen readers.
class ProfilePhotosSection extends StatelessWidget {
  final ProfilePhotosController controller;
  final bool busy;
  const ProfilePhotosSection({
    super.key,
    required this.controller,
    required this.busy,
  });

  Future<AvatarSource?> _source(BuildContext context) async {
    if (!canTakePhoto) return AvatarSource.gallery;
    return showModalBottomSheet<AvatarSource>(
      context: context,
      showDragHandle: true,
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              key: const Key('photos-pick-gallery'),
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Choose from gallery'),
              onTap: () => Navigator.pop(sheet, AvatarSource.gallery),
            ),
            ListTile(
              key: const Key('photos-pick-camera'),
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('Take a photo'),
              onTap: () => Navigator.pop(sheet, AvatarSource.camera),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Future<void> _add(BuildContext context, {String? replace}) async {
    controller.clearError();
    final source = await _source(context);
    if (source != null) await controller.pick(source, replace: replace);
  }

  Future<void> _menu(BuildContext context, GalleryPhoto photo, int i) async {
    final last = controller.photos.length - 1;
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (i > 0)
              ListTile(
                key: const Key('photo-make-first'),
                leading: const Icon(Icons.account_circle_outlined),
                title: const Text('Make profile photo'),
                onTap: () => Navigator.pop(sheet, 'first'),
              ),
            if (i > 0)
              ListTile(
                key: const Key('photo-earlier'),
                leading: const Icon(Icons.arrow_back_rounded),
                title: const Text('Move earlier'),
                onTap: () => Navigator.pop(sheet, 'earlier'),
              ),
            if (i < last)
              ListTile(
                key: const Key('photo-later'),
                leading: const Icon(Icons.arrow_forward_rounded),
                title: const Text('Move later'),
                onTap: () => Navigator.pop(sheet, 'later'),
              ),
            ListTile(
              key: const Key('photo-replace'),
              leading: const Icon(Icons.swap_horiz_rounded),
              title: const Text('Replace'),
              onTap: () => Navigator.pop(sheet, 'replace'),
            ),
            ListTile(
              key: const Key('photo-remove'),
              leading: const Icon(Icons.delete_outline_rounded),
              title: const Text('Remove'),
              onTap: () => Navigator.pop(sheet, 'remove'),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (choice == null || !context.mounted) return;
    switch (choice) {
      case 'first':
        await controller.move(photo.mediaId, 0);
      case 'earlier':
        await controller.move(photo.mediaId, i - 1);
      case 'later':
        await controller.move(photo.mediaId, i + 1);
      case 'replace':
        await _add(context, replace: photo.mediaId);
      case 'remove':
        final sure =
            await showDialog<bool>(
              context: context,
              builder: (dialog) => AlertDialog(
                title: const Text('Remove this photo?'),
                content: Text(
                  i == 0
                      ? 'It is your profile photo. The next photo takes its place.'
                      : 'It leaves your profile.',
                ),
                actions: [
                  TextButton(
                    key: const Key('confirm-cancel'),
                    onPressed: () => Navigator.pop(dialog, false),
                    child: const Text('Cancel'),
                  ),
                  FilledButton(
                    key: const Key('confirm-ok'),
                    onPressed: () => Navigator.pop(dialog, true),
                    child: const Text('Remove'),
                  ),
                ],
              ),
            ) ??
            false;
        if (sure) await controller.delete(photo.mediaId);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = ChatTokens.of(context);
    final photos = controller.photos;
    final working = controller.busy;
    final failure = controller.failure;
    final upload = controller.upload;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const ProfileHeading('Your photos'),
        Text(
          'Add up to ${controller.max}. The first is your profile photo. They are public, like the rest of your profile.',
          style: TextStyle(fontSize: 13.5, height: 1.4, color: t.textSecondary),
        ),
        const SizedBox(height: 12),
        Wrap(
          key: const Key('photos-grid'),
          spacing: 10,
          runSpacing: 10,
          children: [
            for (var i = 0; i < photos.length; i++)
              _Tile(
                key: ValueKey('photo-${photos[i].mediaId}'),
                photo: photos[i],
                index: i,
                count: photos.length,
                replacing: controller.replacing == photos[i].mediaId,
                progress: upload.uploading ? upload.progress : null,
                enabled: !busy && !working,
                onMenu: () => _menu(context, photos[i], i),
                onMove: (to) => controller.move(photos[i].mediaId, to),
              ),
            if (!controller.full)
              _AddTile(
                enabled: !busy && !working,
                uploading: working && controller.replacing == null,
                progress: upload.uploading ? upload.progress : null,
                onTap: () => _add(context),
              ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          '${photos.length} of ${controller.max}',
          key: const Key('photos-count'),
          style: TextStyle(fontSize: 12.5, color: t.textSecondary),
        ),
        if (upload.uploading)
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton(
              key: const Key('photos-cancel'),
              onPressed: upload.clear,
              child: const Text('Cancel'),
            ),
          ),
        if (failure != null) ...[
          const SizedBox(height: 8),
          Text(
            failure,
            key: const Key('photos-error'),
            style: TextStyle(color: t.error),
          ),
          if (upload.photo != null && (upload.error?.canRetry ?? true))
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton(
                key: const Key('photos-retry'),
                onPressed: working ? null : controller.retry,
                child: const Text('Try again'),
              ),
            ),
        ],
      ],
    );
  }
}

const _tileSize = 96.0;

class _Tile extends StatelessWidget {
  final GalleryPhoto photo;
  final int index, count;
  final bool replacing, enabled;
  final double? progress;
  final VoidCallback onMenu;
  final void Function(int to) onMove;
  const _Tile({
    super.key,
    required this.photo,
    required this.index,
    required this.count,
    required this.replacing,
    required this.enabled,
    required this.progress,
    required this.onMenu,
    required this.onMove,
  });

  @override
  Widget build(BuildContext context) {
    final t = ChatTokens.of(context);
    final url = photo.thumbUrl.isNotEmpty ? photo.thumbUrl : photo.url;
    final label = index == 0
        ? 'Profile photo, photo 1 of $count'
        : 'Photo ${index + 1} of $count';
    return Semantics(
      container: true,
      button: true,
      label: label,
      hint: 'Opens options',
      onTap: enabled ? onMenu : null,
      customSemanticsActions: {
        if (enabled && index > 0) ...{
          const CustomSemanticsAction(label: 'Make profile photo'): () =>
              onMove(0),
          const CustomSemanticsAction(label: 'Move earlier'): () =>
              onMove(index - 1),
        },
        if (enabled && index < count - 1)
          const CustomSemanticsAction(label: 'Move later'): () =>
              onMove(index + 1),
      },
      child: ExcludeSemantics(
        child: PressScale(
          onTap: enabled ? onMenu : null,
          borderRadius: BorderRadius.circular(16),
          minHeight: 48,
          child: SizedBox(
            width: _tileSize,
            height: _tileSize,
            child: Stack(
              fit: StackFit.expand,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: ColoredBox(
                    color: t.elevated,
                    child: url.isEmpty
                        ? Icon(Icons.image_outlined, color: t.textTertiary)
                        : Image(
                            image: photoProvider(
                              url,
                              'photo:${photo.mediaId}:thumb',
                            ),
                            fit: BoxFit.cover,
                            gaplessPlayback: true,
                            errorBuilder: (_, _, _) => Icon(
                              Icons.image_outlined,
                              color: t.textTertiary,
                            ),
                          ),
                  ),
                ),
                if (index == 0)
                  PositionedDirectional(
                    start: 6,
                    bottom: 6,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: t.accent,
                        borderRadius: BorderRadius.circular(100),
                      ),
                      child: Text(
                        'Profile',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w800,
                          color: t.bg,
                        ),
                      ),
                    ),
                  ),
                if (replacing)
                  Positioned.fill(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(16),
                        color: Colors.black45,
                      ),
                      child: Center(
                        child: CircularProgressIndicator(
                          key: const Key('photos-progress'),
                          value: progress != null && progress! > 0
                              ? progress
                              : null,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _AddTile extends StatelessWidget {
  final bool enabled, uploading;
  final double? progress;
  final VoidCallback onTap;
  const _AddTile({
    required this.enabled,
    required this.uploading,
    required this.progress,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final t = ChatTokens.of(context);
    return PressScale(
      key: const Key('photos-add'),
      onTap: enabled ? onTap : null,
      borderRadius: BorderRadius.circular(16),
      minHeight: 48,
      semanticLabel: 'Add a photo',
      child: ExcludeSemantics(
        child: Container(
          width: _tileSize,
          height: _tileSize,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: t.textTertiary),
          ),
          child: Center(
            child: uploading
                ? CircularProgressIndicator(
                    key: const Key('photos-progress'),
                    value: progress != null && progress! > 0 ? progress : null,
                  )
                : Icon(Icons.add_photo_alternate_outlined, color: t.accent),
          ),
        ),
      ),
    );
  }
}
