import 'package:flutter/foundation.dart';

import '../../core/api.dart';

/// A list read a page at a time from the server's signed cursor. The server
/// decides who may read it and what it leaves out; this only holds the pages.
class PagedList<T> extends ChangeNotifier {
  final Future<ApiPage<T>> Function(String? cursor) fetch;
  PagedList(this.fetch);

  List<T> items = const [];
  String? cursor;
  bool loaded = false, loading = false, loadingMore = false;

  /// Why the first page could not be read; null once it was.
  Object? error;
  int _epoch = 0;
  bool _disposed = false;

  void _tell() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  /// Reads the first page again. The old rows stay on screen until it lands.
  Future<void> load() async {
    final epoch = ++_epoch;
    loading = true;
    error = null;
    _tell();
    try {
      final page = await fetch(null);
      if (epoch != _epoch) return;
      items = page.items;
      cursor = page.nextCursor;
      loaded = true;
    } catch (e) {
      if (epoch != _epoch) return;
      error = e;
    } finally {
      if (epoch == _epoch) {
        loading = false;
        loadingMore = false;
        _tell();
      }
    }
  }

  /// Reads the next page; returns what went wrong, if anything.
  Future<Object?> more() async {
    final next = cursor;
    if (next == null || loadingMore || loading) return null;
    final epoch = _epoch;
    loadingMore = true;
    _tell();
    try {
      final page = await fetch(next);
      if (epoch != _epoch) return null;
      items = [...items, ...page.items];
      cursor = page.nextCursor;
      return null;
    } catch (e) {
      return e;
    } finally {
      if (epoch == _epoch) {
        loadingMore = false;
        _tell();
      }
    }
  }

  void removeWhere(bool Function(T item) test) {
    items = [
      for (final i in items)
        if (!test(i)) i,
    ];
    _tell();
  }

  void replaceWhere(bool Function(T item) test, T Function(T item) change) {
    items = [for (final i in items) test(i) ? change(i) : i];
    _tell();
  }
}
