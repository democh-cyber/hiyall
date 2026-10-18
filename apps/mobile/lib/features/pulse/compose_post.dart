import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/feed_state.dart';
import '../../core/picked_file.dart';
import '../../core/pulse7.dart' show VoiceUpload;
import '../../core/state.dart';
import '../../core/user_error.dart';
import '../../shared/widgets.dart';
import 'pending_photo.dart';
import 'profile_content.dart';
import 'pulse_actions.dart';
import 'pulse_common.dart';
import 'topic_widgets.dart';
import 'voice_recorder.dart';

/// Writing a post: text, up to 10 photos, and who sees it.
class ComposePostScreen extends ConsumerStatefulWidget {
  final ImagePicker? picker;
  const ComposePostScreen({super.key, this.picker});
  @override
  ConsumerState<ComposePostScreen> createState() => _ComposePostScreenState();
}

class _ComposePostScreenState extends ConsumerState<ComposePostScreen> {
  final body = TextEditingController();
  final photos = <PendingPhoto>[];
  String? audience;
  bool sharing = false;

  /// The optional topic and voice note of the post.
  String? topic;
  VoiceUpload? voice;

  ImagePicker get picker => widget.picker ?? ImagePicker();

  @override
  void dispose() {
    body.dispose();
    super.dispose();
  }

  bool get ready =>
      !sharing &&
      photos.every((p) => p.done) &&
      (body.text.trim().isNotEmpty || photos.isNotEmpty || voice != null);

  /// Text, photos or a voice note that leaving would throw away.
  bool get dirty =>
      body.text.trim().isNotEmpty || photos.isNotEmpty || voice != null;

  void close() => context.canPop() ? context.pop() : context.go('/home');

  /// Asks before discarding a draft, then leaves.
  Future<void> leave() async {
    if (!dirty || sharing) return close();
    final discard = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Discard this post?'),
        content: const Text(
          'What you wrote, and any photos or voice note, will be lost.',
        ),
        actions: [
          TextButton(
            key: const Key('keep-editing'),
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep editing'),
          ),
          FilledButton(
            key: const Key('discard-post'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Discard'),
          ),
        ],
      ),
    );
    if (discard == true && mounted) close();
  }

  Future<void> addPhotos() async {
    final room = 10 - photos.length;
    if (room <= 0) return;
    final files = await picker.pickMultiImage(
      limit: room > 1 ? room : null,
      maxWidth: 2048,
      maxHeight: 2048,
      imageQuality: 85,
    );
    try {
      for (final f in files.take(room)) {
        final p = PendingPhoto(await readAndDeletePick(f));
        if (!mounted) return;
        setState(() => photos.add(p));
        unawaited(
          uploadPendingPhoto(ref, p, 'post', () {
            if (mounted) setState(() {});
          }, onLimit: (m) => mounted ? showMessage(context, m) : null),
        );
      }
    } finally {
      // The copies of picks beyond [room], or of the originals of resized ones, go too.
      unawaited(sweepPickerTemp());
    }
  }

  void retry(PendingPhoto p) => uploadPendingPhoto(ref, p, 'post', () {
    if (mounted) setState(() {});
  });

  Future<void> share(String chosen) async {
    setState(() => sharing = true);
    try {
      final post = await ref
          .read(pulseActionsProvider)
          .createPost(
            body: body.text.trim(),
            audience: chosen,
            mediaIds: [for (final p in photos) p.mediaId!],
            topic: topic,
            voiceMediaId: voice?.mediaId,
          );
      ref.read(feedProvider('following').notifier).prepend(post);
      ref.invalidate(profilePostsProvider);
      if (chosen == 'public') {
        ref.read(feedProvider('everyone').notifier).prepend(post);
      }
      if (mounted) {
        showMessage(context, 'Shared.');
        context.canPop() ? context.pop() : context.go('/home');
      }
    } catch (e) {
      if (mounted) showFailure(context, e);
    } finally {
      if (mounted) setState(() => sharing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final profile = ref.watch(profileProvider).asData?.value;
    final chosen =
        audience ??
        defaultAudience(
          ref.watch(privacyProvider).asData?.value.values['profileAudience']
              as String?,
        );
    return PopScope(
      // System Back and the swipe gesture ask first when there is a draft.
      canPop: !dirty || sharing,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) leave();
      },
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            tooltip: 'Close',
            icon: const Icon(Icons.close_rounded),
            onPressed: leave,
          ),
          title: const Text('New post'),
          actions: [
            Padding(
              padding: const EdgeInsetsDirectional.only(end: 12),
              child: FilledButton(
                key: const Key('share-post'),
                onPressed: ready ? () => share(chosen) : null,
                child: Text(sharing ? 'Sharing…' : 'Share'),
              ),
            ),
          ],
        ),
        body: ReadingWidth(
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  PulseAvatar(
                    profile?.displayName ?? '?',
                    userId: profile?.userId ?? '',
                    avatarUrl: profile?.avatarUrl,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      key: const Key('post-body'),
                      controller: body,
                      autofocus: true,
                      maxLength: 2200,
                      minLines: 3,
                      maxLines: 12,
                      onChanged: (_) => setState(() {}),
                      decoration: const InputDecoration(
                        hintText: 'What’s the vibe?',
                        border: InputBorder.none,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              _PhotoStrip(
                photos: photos,
                onAdd: addPhotos,
                onRetry: retry,
                onRemove: (p) => setState(() => photos.remove(p)),
              ),
              const SizedBox(height: 12),
              VoiceNoteField(
                value: voice,
                onChanged: (v) => setState(() => voice = v),
              ),
              const SizedBox(height: 20),
              Text(
                'Topic (optional)',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 4),
              TopicPicker(
                selected: topic,
                onChanged: (t) => setState(() => topic = t),
              ),
              const SizedBox(height: 16),
              Text(
                'Who can see this?',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              SegmentedButton<String>(
                key: const Key('post-audience'),
                segments: [
                  for (final e in audienceLabels.entries)
                    ButtonSegment(
                      value: e.key,
                      label: Text(e.value),
                      icon: Icon(audienceIcon(e.key)),
                    ),
                ],
                selected: {chosen},
                onSelectionChanged: (s) => setState(() => audience = s.single),
              ),
              const SizedBox(height: 12),
              Text(
                'Photos are re-saved without location or camera details before anyone sees them.',
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The picked photos in a row, then the add tile while there is room.
class _PhotoStrip extends StatelessWidget {
  final List<PendingPhoto> photos;
  final VoidCallback onAdd;
  final void Function(PendingPhoto) onRetry, onRemove;
  const _PhotoStrip({
    required this.photos,
    required this.onAdd,
    required this.onRetry,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: 110,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        itemCount: photos.length + (photos.length < 10 ? 1 : 0),
        itemBuilder: (context, i) {
          if (i < photos.length) {
            final p = photos[i];
            return PendingPhotoTile(
              photo: p,
              onRetry: () => onRetry(p),
              onRemove: () => onRemove(p),
            );
          }
          return InkWell(
            key: const Key('add-photos'),
            borderRadius: BorderRadius.circular(14),
            onTap: onAdd,
            child: Container(
              width: 110,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: scheme.outlineVariant),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.add_photo_alternate_outlined),
                  const SizedBox(height: 6),
                  Text(
                    photos.isEmpty ? 'Add photos' : '${photos.length}/10',
                    style: const TextStyle(fontSize: 12),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
