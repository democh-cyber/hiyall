/// How long a story has left: "23h left", "40m left".
String storyTimeLeft(DateTime expiresAt, [DateTime? now]) {
  final d = expiresAt.difference(now ?? DateTime.now());
  if (d.inMinutes < 1) return 'Ends in under a minute';
  if (d.inHours < 1) return '${d.inMinutes}m left';
  return '${d.inHours}h left';
}
