import 'package:flutter/material.dart';

import '../../core/avatar_upload.dart';
import '../../core/theme.dart';
import '../../shared/avatar_sheet.dart';
import '../../shared/person_avatar.dart';
import 'profile_avatar_controller.dart';

/// The profile photo at the top of the editor: tap to change it, with its progress, a way
/// to cancel and a message with a retry when something went wrong.
class ProfileAvatarEditor extends StatelessWidget {
  final ProfileAvatarController controller;

  /// The form is saving; the photo cannot be changed meanwhile.
  final bool busy;
  const ProfileAvatarEditor({
    super.key,
    required this.controller,
    required this.busy,
  });

  Future<void> _choose(BuildContext context) async {
    if (busy || controller.working) return;
    final action = await showAvatarSheet(
      context,
      hasPhoto:
          controller.current.avatarUrl != null ||
          controller.upload.photo != null,
    );
    if (action == null || !context.mounted) return;
    controller.clearError();
    switch (action) {
      case AvatarAction.gallery || AvatarAction.camera:
        await controller.pick(
          action == AvatarAction.camera
              ? AvatarSource.camera
              : AvatarSource.gallery,
        );
      case AvatarAction.remove:
        await controller.remove();
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final upload = controller.upload;
    final working = controller.working;
    final current = controller.current;
    final failure = controller.failure;
    return Column(
      children: [
        Semantics(
          button: true,
          label: 'Change profile photo',
          excludeSemantics: true,
          child: InkWell(
            key: const Key('edit-avatar'),
            customBorder: const CircleBorder(),
            onTap: busy || working ? null : () => _choose(context),
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                PersonAvatar(
                  name: current.displayName,
                  bytes: upload.photo?.bytes,
                  avatarUrl: current.avatarFor(112),
                  userId: current.userId,
                  radius: 56,
                ),
                if (working)
                  Positioned.fill(
                    child: DecoratedBox(
                      decoration: const BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.black38,
                      ),
                      child: Center(
                        child: CircularProgressIndicator(
                          key: const Key('avatar-progress'),
                          value: upload.uploading && upload.progress > 0
                              ? upload.progress
                              : null,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                PositionedDirectional(
                  end: 0,
                  bottom: 0,
                  child: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: VibeColors.lime,
                      shape: BoxShape.circle,
                      border: Border.all(color: scheme.surface, width: 3),
                    ),
                    child: const Icon(
                      Icons.photo_camera_rounded,
                      size: 18,
                      color: VibeColors.ink,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        if (upload.uploading)
          TextButton(
            key: const Key('avatar-cancel'),
            onPressed: upload.clear,
            child: const Text('Cancel'),
          )
        else
          Text(
            'Your photo is public, like the rest of your profile.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
        if (failure != null) ...[
          const SizedBox(height: 8),
          Text(
            failure,
            key: const Key('avatar-error'),
            textAlign: TextAlign.center,
            style: TextStyle(color: scheme.error),
          ),
          if (upload.photo != null && (upload.error?.canRetry ?? true))
            TextButton(
              key: const Key('avatar-retry'),
              onPressed: working ? null : controller.send,
              child: const Text('Try again'),
            ),
        ],
      ],
    );
  }
}
