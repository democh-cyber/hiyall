import 'package:flutter/material.dart';

import '../../core/theme.dart';
import 'story_tap.dart';

/// Photo and Camera while there is no photo; Change photo and Remove once there is one.
class StoryMediaRow extends StatelessWidget {
  final bool hasPhoto;
  final VoidCallback onGallery, onCamera, onChange, onRemove;
  const StoryMediaRow({
    super.key,
    required this.hasPhoto,
    required this.onGallery,
    required this.onCamera,
    required this.onChange,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
    child: Row(
      children: hasPhoto
          ? [
              _BigButton(
                buttonKey: const Key('story-change-photo'),
                label: 'Change photo',
                icon: Icons.swap_horiz_rounded,
                onTap: onChange,
              ),
              const SizedBox(width: 10),
              _BigButton(
                buttonKey: const Key('story-remove-photo'),
                label: 'Remove',
                icon: Icons.close_rounded,
                onTap: onRemove,
              ),
            ]
          : [
              _BigButton(
                buttonKey: const Key('story-gallery'),
                label: 'Photo',
                icon: Icons.photo_library_rounded,
                onTap: onGallery,
              ),
              const SizedBox(width: 10),
              _BigButton(
                buttonKey: const Key('story-camera'),
                label: 'Camera',
                icon: Icons.photo_camera_rounded,
                onTap: onCamera,
              ),
            ],
    ),
  );
}

class _BigButton extends StatelessWidget {
  final Key buttonKey;
  final String label;
  final IconData icon;
  final VoidCallback onTap;
  const _BigButton({
    required this.buttonKey,
    required this.label,
    required this.icon,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) => Expanded(
    child: StoryTap(
      key: buttonKey,
      label: label,
      radius: 20,
      onTap: onTap,
      builder: (_) => Container(
        height: 52,
        alignment: Alignment.center,
        decoration: storyPill(context, radius: 20),
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 30,
                height: 30,
                decoration: const BoxDecoration(
                  color: VibeColors.lime,
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, size: 18, color: VibeColors.ink),
              ),
              const SizedBox(width: 10),
              Text(label, style: storyPillText(context, size: 15)),
            ],
          ),
        ),
      ),
    ),
  );
}
