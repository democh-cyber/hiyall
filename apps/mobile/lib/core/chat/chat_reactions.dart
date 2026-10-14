import 'chat_attachment.dart' show isCanonicalUuid;
import 'chat_text.dart';

/// The six quick reactions, as exact strings. A received reaction is accepted
/// only if it equals one of these byte for byte (so `❤` without its variation
/// selector, skin-toned thumbs and every other emoji are ignored, never
/// rendered), and the picker offers nothing else.
const reactionEmojis = <String>[
  '\u2764\uFE0F', // red heart
  '\u{1F602}', // face with tears of joy
  '\u{1F44D}', // thumbs up
  '\u{1F62E}', // face with open mouth
  '\u{1F622}', // crying face
  '\u{1F525}', // fire
];

/// The reaction a double tap toggles.
const quickReaction = '\u2764\uFE0F';

bool isAllowedReaction(Object? value) =>
    value is String && reactionEmojis.contains(value);

/// A reaction is not a conversation turn: the relay is told so with this
/// metadata hint (`aux`) so it neither counts it as unread nor pushes it.
const auxReaction = 'reaction';

/// How long a reaction waits for a message this device has not received yet.
const pendingReactionLife = Duration(days: 7);

/// How many messages can have a waiting reaction in one conversation.
const pendingReactionCap = 200;

/// The longest quoted snippet, in code points.
const maxReplySnippet = 120;

/// Where one member's reaction to one message stands, as the latest event this
/// device has seen from them: last writer wins by (sentAt, then messageId) of
/// the reaction message, so a late `add` can never undo a newer `remove`. An
/// [emoji] of null is a removal, kept (a tombstone) so the ordering holds.
class ReactionState {
  final String? emoji;
  final DateTime at;
  final String id;
  const ReactionState({
    required this.emoji,
    required this.at,
    required this.id,
  });

  /// Whether this event beats [other]: later `at`, ties broken by message id.
  bool beats(ReactionState other) {
    final c = at.compareTo(other.at);
    return c > 0 || (c == 0 && id.compareTo(other.id) > 0);
  }

  Map<String, dynamic> toJson() => {
    'e': emoji,
    'at': at.toUtc().toIso8601String(),
    'id': id,
  };

  /// A stored state, or null if it is not one this app wrote.
  static ReactionState? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final e = raw['e'], id = raw['id'];
    final at = DateTime.tryParse(
      raw['at'] is String ? raw['at'] as String : '',
    );
    if (at == null || id is! String || !isCanonicalUuid(id)) return null;
    if (e != null && !isAllowedReaction(e)) return null;
    return ReactionState(emoji: e as String?, at: at, id: id);
  }

  @override
  bool operator ==(Object other) =>
      other is ReactionState &&
      other.emoji == emoji &&
      other.at == at &&
      other.id == id;
  @override
  int get hashCode => Object.hash(emoji, at, id);
}

/// [states] with [next] applied for [sender] if it beats what is there;
/// returns the same map when it does not.
Map<String, ReactionState> mergeReaction(
  Map<String, ReactionState> states,
  String sender,
  ReactionState next,
) {
  final current = states[sender];
  if (current != null && !next.beats(current)) return states;
  return {...states, sender: next};
}

/// One reaction received (or sent) for a message.
class ReactionEvent {
  final String target, sender;
  final ReactionState state;
  const ReactionEvent({
    required this.target,
    required this.sender,
    required this.state,
  });
}

/// The quote a reply carries inside its encrypted payload. It is attributed
/// text, not proof: the receiver cannot check it against the original, and a
/// sender can quote their own words however they like. When the original is in
/// this device's history the local text wins (see [ChatReply.resolved]).
class ChatReply {
  /// The quoted message's id, who wrote it, a short plain snippet and its kind.
  final String id, by, snippet, kind;
  const ChatReply({
    required this.id,
    required this.by,
    required this.snippet,
    required this.kind,
  });

  static const kinds = {'text', 'image'};
  bool get isImage => kind == 'image';

  Map<String, dynamic> toJson() => {
    'id': id,
    'by': by,
    'snip': snippet,
    'k': kind,
  };

  /// This reply with [by], [snippet] and [kind] taken from the original.
  ChatReply resolved({
    required String by,
    required String snippet,
    required String kind,
  }) => ChatReply(id: id, by: by, snippet: snippet, kind: kind);

  /// Parses a received `re`. Anything that is not exactly right yields null
  /// and the message shows without a quote: the id is a canonical UUID, `by` is
  /// one of the [members] (or any UUID when they are not known), the snippet
  /// is plain text of at most [maxReplySnippet] code points and `k` is on the
  /// allow-list. Unknown extra keys are ignored.
  static ChatReply? parse(Object? raw, {Set<String>? members}) {
    if (raw is! Map) return null;
    final id = raw['id'], by = raw['by'], snip = raw['snip'], k = raw['k'];
    if (id is! String || !isCanonicalUuid(id)) return null;
    if (by is! String || !isCanonicalUuid(by)) return null;
    if (members != null && !members.contains(by)) return null;
    if (snip is! String || !isPlainSnippet(snip)) return null;
    if (k is! String || !kinds.contains(k)) return null;
    return ChatReply(
      id: id,
      by: by,
      snippet: sanitizeText(snip, multiline: false),
      kind: k,
    );
  }
}

final _unsafeSnippet = RegExp(
  // Controls, line and paragraph separators, and bidirectional overrides and
  // isolates (which can reorder surrounding text).
  r'[\u0000-\u001F\u007F-\u009F\u2028\u2029\u200E\u200F\u202A-\u202E\u2066-\u2069]',
);

/// Whether [text] is a legal snippet: plain (no control or bidi characters,
/// no line breaks) and at most [maxReplySnippet] code points.
bool isPlainSnippet(String text) =>
    text.length <= maxReplySnippet * 2 &&
    text.runes.length <= maxReplySnippet &&
    !_unsafeSnippet.hasMatch(text);

/// The text a reply embeds for [text]: whitespace and line breaks collapsed to
/// single spaces, unsafe characters removed, then cut to [maxReplySnippet]
/// code points with an ellipsis.
String snippetOf(String text) {
  final plain = sanitizeText(text.replaceAll(_unsafeSnippet, ' '))
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  final runes = plain.runes.toList();
  if (runes.length <= maxReplySnippet) return plain;
  var cut = runes.sublist(0, maxReplySnippet - 1);
  // Do not end on a joiner or selector: that would leave half an emoji.
  while (cut.isNotEmpty && (cut.last == 0x200D || cut.last == 0xFE0F)) {
    cut = cut.sublist(0, cut.length - 1);
  }
  return '${String.fromCharCodes(cut).trimRight()}…';
}
