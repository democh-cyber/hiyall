import 'dart:async';

import '../../core/story_draft.dart';

/// Keeps the story draft on the device: reads it back, saves a moment after a change and
/// clears it. Holds no widget state; the screen decides when a save must not happen.
class StoryDraftKeeper {
  final StoryDraftStore store;
  final String? userId;
  Timer? _timer;
  StoryDraftKeeper(this.store, this.userId);

  /// A change is waiting for its save.
  bool get pending => _timer?.isActive ?? false;

  Future<StoryDraft?> read() async {
    final id = userId;
    return id == null ? null : store.read(id);
  }

  /// Runs [flush] a moment later; typing does not write on every key.
  void schedule(void Function() flush) {
    _timer?.cancel();
    _timer = Timer(const Duration(milliseconds: 250), flush);
  }

  void cancel() => _timer?.cancel();

  void save(StoryDraft draft) {
    final id = userId;
    if (id == null) return;
    unawaited(draft.hasContent ? store.write(id, draft) : store.clear(id));
  }

  void clear() {
    final id = userId;
    if (id != null) unawaited(store.clear(id));
  }
}
