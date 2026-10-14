import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api.dart';
import 'pulse_actions.dart';

/// A photo picked for a post or story, uploading as soon as it's chosen.
class PendingPhoto {
  final Uint8List bytes;
  String? mediaId;
  double progress = 0;
  String? error;

  /// Set when a limit stopped the upload: retrying at once cannot work, so the tile offers no retry.
  bool limited = false;
  PendingPhoto(this.bytes);
  bool get done => mediaId != null;
}

Future<void> uploadPendingPhoto(
  WidgetRef ref,
  PendingPhoto p,
  String purpose,
  void Function() changed, {
  void Function(String message)? onLimit,
}) async {
  final type = sniffImageType(p.bytes);
  if (type == null) {
    p.error = 'Use a JPEG, PNG or WebP photo';
    changed();
    return;
  }
  try {
    p.error = null;
    p.mediaId = await ref
        .read(pulseActionsProvider)
        .uploadPhoto(
          p.bytes,
          contentType: type,
          purpose: purpose,
          onProgress: (v) {
            p.progress = v;
            changed();
          },
        );
  } catch (e) {
    if (e is ApiFailure && e.code == 'QUOTA') {
      // The server's own calm words go in a message; the tile only says why it stopped.
      p.limited = true;
      p.error = 'Photo limit reached';
      onLimit?.call(e.displayMessage);
    } else {
      p.error = e is ApiFailure ? e.displayMessage : 'Upload failed';
    }
  }
  changed();
}

/// One picked photo in the composer: a thumbnail with its upload progress, a
/// retry when it failed, and a way to take it out.
class PendingPhotoTile extends StatelessWidget {
  final PendingPhoto photo;
  final VoidCallback onRetry, onRemove;
  const PendingPhotoTile({
    super.key,
    required this.photo,
    required this.onRetry,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final p = photo;
    return Padding(
      padding: const EdgeInsetsDirectional.only(end: 8),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: SizedBox(
          width: 110,
          child: Stack(
            fit: StackFit.expand,
            children: [
              Image.memory(p.bytes, fit: BoxFit.cover, cacheWidth: 330),
              if (!p.done && p.error == null)
                ColoredBox(
                  color: Colors.black38,
                  child: Center(
                    child: CircularProgressIndicator(
                      value: p.progress > 0 ? p.progress : null,
                      color: Colors.white,
                    ),
                  ),
                ),
              if (p.error != null)
                Material(
                  color: Colors.black54,
                  child: InkWell(
                    onTap: p.limited ? null : onRetry,
                    child: Center(
                      child: Padding(
                        padding: const EdgeInsets.all(6),
                        child: Text(
                          p.limited ? p.error! : '${p.error!}\nTap to retry',
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              PositionedDirectional(
                top: 4,
                end: 4,
                child: IconButton.filled(
                  tooltip: 'Remove photo',
                  visualDensity: VisualDensity.compact,
                  iconSize: 16,
                  style: IconButton.styleFrom(backgroundColor: Colors.black54),
                  onPressed: onRemove,
                  icon: const Icon(Icons.close_rounded, color: Colors.white),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
