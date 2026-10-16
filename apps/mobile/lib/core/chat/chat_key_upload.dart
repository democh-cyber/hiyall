import 'dart:math';

import '../../src/rust/api/e2ee.dart' show PublicKeyEntry;

/// The relay's request limit for one-time keys, and the most it holds for one device.
const oneTimeKeysPerRequest = 50, oneTimeKeysOnRelayMax = 100;

/// Uploads this device's unpublished one-time keys, and the fallback key when one is due, in requests of at
/// most [oneTimeKeysPerRequest] (audit CHAT-N9).
///
/// [generate] makes up to `count` keys and returns EVERY unpublished key: the core can hold more than one
/// request's worth when an earlier build left them (a pickle from before the core capped them), and a plain
/// "take 50" would then have them marked published without ever being sent. Here all of them are sent, chunk by
/// chunk, and only then marked published, so after a failure part-way nothing is marked and a retry sends them
/// again (the relay ignores a key it already holds, and does not count it twice against its cap of
/// [oneTimeKeysOnRelayMax]). A key that does not fit in the relay's room is not sent and not kept: it is marked
/// published with the rest and never becomes claimable, which costs nothing.
///
/// [onRelay] is how many one-time keys the relay already holds, [want] how many more to make, [save] writes
/// the account (the private halves are saved before the public halves are uploaded), [markPublished] marks
/// everything the core holds as published, and [fallbackPublished] records a fallback key the relay accepted.
Future<void> publishOneTimeKeys({
  required int onRelay,
  required int want,
  required PublicKeyEntry? fallback,
  required List<PublicKeyEntry> Function(int count) generate,
  required Map<String, String> Function(PublicKeyEntry key) sign,
  required Future<void> Function() save,
  required Future<void> Function(
    List<Map<String, String>> oneTimeKeys,
    Map<String, String>? fallbackKey,
  )
  upload,
  required void Function() markPublished,
  required Future<void> Function() fallbackPublished,
}) async {
  var first = true;
  do {
    final pending = generate(min(want, oneTimeKeysPerRequest));
    final room = max(0, oneTimeKeysOnRelayMax - onRelay);
    final send = pending.take(room).toList();
    final withFallback = first ? fallback : null;
    if (send.isEmpty && withFallback == null) {
      if (pending.isNotEmpty) {
        markPublished();
        await save();
      }
      break;
    }
    await save();
    // The fallback key travels with the first request, so it is not held back by the one-time keys, and
    // when only the fallback is due it goes alone.
    for (var at = 0; at == 0 || at < send.length; at += oneTimeKeysPerRequest) {
      final chunk = send.skip(at).take(oneTimeKeysPerRequest).map(sign);
      await upload(
        chunk.toList(),
        at == 0 && withFallback != null ? sign(withFallback) : null,
      );
    }
    markPublished();
    if (withFallback != null) await fallbackPublished();
    await save();
    first = false;
    onRelay += send.length;
    want = max(0, want - send.length);
  } while (want > 0);
}
