import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/api.dart';
import '../../core/pulse7.dart';
import '../../core/pulse_tabs.dart';
import '../../core/user_error.dart';
import '../../shared/chat_tokens.dart';
import '../../shared/press_scale.dart';
import '../../shared/widgets.dart';
import 'pulse_common.dart';
import 'story_tray.dart' show openStories;
import 'topic_widgets.dart';

/// Search over the text of posts and stories you can see (`GET /v1/search/pulse`). Typing waits for a pause,
/// every page is one request the server counts against a daily limit and a page cap, so more results come only
/// when asked for ("Show more"), and a daily limit or an expired search is said in words.
class PulseSearchScreen extends ConsumerStatefulWidget {
  /// How long typing must pause before a search starts.
  final Duration debounce;
  const PulseSearchScreen({
    super.key,
    this.debounce = const Duration(milliseconds: 450),
  });
  @override
  ConsumerState<PulseSearchScreen> createState() => _PulseSearchScreenState();
}

class _PulseSearchScreenState extends ConsumerState<PulseSearchScreen> {
  final input = TextEditingController();
  Timer? timer;
  SearchScope scope = SearchScope.posts;
  String? topic;
  String query = '';

  /// What the last search found; [searched] says whether one has run for [query].
  List<Post> posts = [];
  List<ExploreStory> stories = [];
  String? next;
  bool loading = false, loadingMore = false, searched = false;
  Object? error;
  int epoch = 0;

  @override
  void dispose() {
    timer?.cancel();
    input.dispose();
    super.dispose();
  }

  void changed(String value) {
    timer?.cancel();
    timer = Timer(widget.debounce, () => start(value.trim()));
  }

  /// A new search: forget the old results and their cursor.
  Future<void> start(String text) async {
    final mine = ++epoch;
    if (text.runes.length < 2) {
      setState(() {
        query = text;
        posts = [];
        stories = [];
        next = null;
        searched = false;
        loading = false;
        error = null;
      });
      return;
    }
    setState(() {
      query = text;
      loading = true;
      error = null;
    });
    await _run(mine, null);
  }

  Future<void> _run(int mine, String? cursor) async {
    try {
      final page = await ref
          .read(pulse7Provider)
          .search(
            pulse7SessionOf(ref),
            q: query,
            scope: scope,
            topic: topic,
            cursor: cursor,
          );
      if (!mounted || mine != epoch) return;
      setState(() {
        if (cursor == null) {
          posts = page.posts;
          stories = page.stories;
        } else {
          final seenPosts = {for (final p in posts) p.postId};
          final seenStories = {for (final s in stories) s.story.storyId};
          posts = [
            ...posts,
            ...page.posts.where((p) => seenPosts.add(p.postId)),
          ];
          stories = [
            ...stories,
            ...page.stories.where((s) => seenStories.add(s.story.storyId)),
          ];
        }
        next = page.nextCursor;
        searched = true;
        loading = loadingMore = false;
      });
    } catch (e) {
      if (!mounted || mine != epoch) return;
      setState(() {
        error = e;
        loading = loadingMore = false;
      });
    }
  }

  Future<void> more() async {
    if (next == null || loadingMore) return;
    setState(() => loadingMore = true);
    await _run(epoch, next);
  }

  void setScope(SearchScope value) {
    if (value == scope) return;
    scope = value;
    start(query);
  }

  void setTopic(String? value) {
    topic = value;
    start(query);
  }

  @override
  Widget build(BuildContext context) {
    final t = ChatTokens.of(context);
    final names = ref.watch(topicListProvider).asData?.value;
    final count = scope == SearchScope.posts ? posts.length : stories.length;
    return Scaffold(
      appBar: AppBar(
        leading: BackButton(
          onPressed: () =>
              context.canPop() ? context.pop() : context.go('/home'),
        ),
        title: TextField(
          key: const Key('pulse-search-input'),
          controller: input,
          autofocus: true,
          maxLength: 80,
          textInputAction: TextInputAction.search,
          onChanged: changed,
          onSubmitted: (v) {
            timer?.cancel();
            start(v.trim());
          },
          decoration: const InputDecoration(
            hintText: 'Search posts and stories',
            counterText: '',
            border: InputBorder.none,
          ),
        ),
      ),
      body: SafeArea(
        child: ReadingWidth(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                child: SegmentedButton<SearchScope>(
                  key: const Key('pulse-search-scope'),
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(
                      value: SearchScope.posts,
                      label: Text('Posts'),
                    ),
                    ButtonSegment(
                      value: SearchScope.stories,
                      label: Text('Stories'),
                    ),
                  ],
                  selected: {scope},
                  onSelectionChanged: (s) => setScope(s.first),
                ),
              ),
              SizedBox(
                height: 52,
                child: ListView(
                  key: const Key('pulse-search-topics'),
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  children: [
                    Padding(
                      padding: const EdgeInsetsDirectional.only(end: 8),
                      child: TopicChip(
                        key: const Key('search-topic-all'),
                        topic: null,
                        selected: topic == null,
                        onTap: () => setTopic(null),
                      ),
                    ),
                    for (final name in names ?? const <String>[])
                      Padding(
                        padding: const EdgeInsetsDirectional.only(end: 8),
                        child: TopicChip(
                          key: Key('search-topic-$name'),
                          topic: name,
                          selected: topic == name,
                          onTap: () => setTopic(topic == name ? null : name),
                        ),
                      ),
                  ],
                ),
              ),
              Expanded(child: _results(context, t, count)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _results(BuildContext context, ChatTokens t, int count) {
    if (error != null && count == 0) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: _SearchError(error: error!, retry: () => start(query)),
        ),
      );
    }
    if (loading) return const Center(child: CircularProgressIndicator());
    if (!searched) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'Type at least 2 letters to search what people are posting.',
            textAlign: TextAlign.center,
            style: TextStyle(color: t.textSecondary),
          ),
        ),
      );
    }
    if (count == 0) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'Nothing found for “$query”. Try another word.',
            key: const Key('pulse-search-empty'),
            textAlign: TextAlign.center,
            style: TextStyle(color: t.textSecondary),
          ),
        ),
      );
    }
    return ListView(
      key: const Key('pulse-search-results'),
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
      children: [
        if (scope == SearchScope.posts)
          for (final p in posts) _PostResult(post: p),
        if (scope == SearchScope.stories)
          for (var i = 0; i < stories.length; i++)
            _StoryResult(
              item: stories[i],
              onTap: () =>
                  openStories(context, [for (final s in stories) s.group], i),
            ),
        if (error != null) _SearchError(error: error!, retry: more),
        if (next != null)
          TextButton(
            key: const Key('pulse-search-more'),
            onPressed: loadingMore ? null : more,
            child: Text(loadingMore ? 'Loading…' : 'Show more'),
          ),
      ],
    );
  }
}

class _SearchError extends StatelessWidget {
  final Object error;
  final VoidCallback retry;
  const _SearchError({required this.error, required this.retry});
  @override
  Widget build(BuildContext context) {
    // A daily limit and an expired search are not "try again" problems: the server's own words say what to do.
    final text = friendlyError(error);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          text,
          key: const Key('pulse-search-error'),
          textAlign: TextAlign.center,
        ),
        if (!(error is ApiFailure &&
            (error as ApiFailure).code == 'DAILY_LIMIT'))
          TextButton(onPressed: retry, child: const Text('Try again')),
      ],
    );
  }
}

class _PostResult extends StatelessWidget {
  final Post post;
  const _PostResult({required this.post});
  @override
  Widget build(BuildContext context) {
    final t = ChatTokens.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: PressScale(
        key: Key('search-post-${post.postId}'),
        minHeight: 48,
        semanticLabel: 'Post by ${post.author.name}',
        onTap: () => context.push('/post/${post.postId}'),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: t.elevated,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: t.hairline),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              PulseAvatar.of(post.author, radius: 18),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(
                            text: post.author.name,
                            style: const TextStyle(fontWeight: FontWeight.w800),
                          ),
                          TextSpan(
                            text: '  ${shortAgo(post.createdAt)}',
                            style: TextStyle(
                              fontSize: 12,
                              color: t.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      post.body,
                      maxLines: 4,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: t.text, height: 1.35),
                    ),
                    if (post.topic != null) ...[
                      const SizedBox(height: 6),
                      TopicLabel(post.topic!),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StoryResult extends StatelessWidget {
  final ExploreStory item;
  final VoidCallback onTap;
  const _StoryResult({required this.item, required this.onTap});
  @override
  Widget build(BuildContext context) {
    final t = ChatTokens.of(context);
    final s = item.story;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: PressScale(
        key: Key('search-story-${s.storyId}'),
        minHeight: 48,
        semanticLabel: 'Story by ${item.author.name}',
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: t.elevated,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: t.hairline),
          ),
          child: Row(
            children: [
              PulseAvatar.of(item.author, radius: 18),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.author.name,
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                    Text(
                      s.body,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: t.text, height: 1.35),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
