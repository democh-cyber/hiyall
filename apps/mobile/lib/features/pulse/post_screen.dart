import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/api.dart';
import '../../core/pulse7.dart';
import '../../shared/widgets.dart';
import 'post_card.dart';

/// One post opened by its id: from a search result or a My activity row. A post that is gone, or that the member
/// can no longer see, reads "This post isn’t available" (the server answers 404 for both).
class PostScreen extends ConsumerStatefulWidget {
  final String postId;
  const PostScreen({super.key, required this.postId});
  @override
  ConsumerState<PostScreen> createState() => _PostScreenState();
}

class _PostScreenState extends ConsumerState<PostScreen> {
  Post? post;
  Object? error;
  bool gone = false;

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    setState(() {
      error = null;
      gone = false;
    });
    try {
      final loaded = await ref
          .read(pulse7Provider)
          .post(pulse7SessionOf(ref), widget.postId);
      if (mounted) setState(() => post = loaded);
    } on ApiFailure catch (e) {
      if (!mounted) return;
      setState(() {
        if (e.status == 404) {
          gone = true;
        } else {
          error = e;
        }
      });
    } catch (e) {
      if (mounted) setState(() => error = e);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Post'),
      leading: BackButton(
        onPressed: () => context.canPop() ? context.pop() : context.go('/home'),
      ),
    ),
    body: SafeArea(
      child: ReadingWidth(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (post != null)
              PostCard(post: post!, mode: 'everyone')
            else if (gone)
              const EmptyCard(
                icon: Icons.visibility_off_outlined,
                title: 'This post isn’t available',
                description: 'It was removed, or you can’t see it any more.',
              )
            else if (error != null)
              FailureCard(error: error!, retry: load)
            else
              const Center(child: CircularProgressIndicator()),
          ],
        ),
      ),
    ),
  );
}
