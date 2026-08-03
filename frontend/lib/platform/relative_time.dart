/// Coarse relative time — when a project was last looked at only matters in
/// broad strokes.
///
/// Pulled out of the report screen because the console draws the same figure in
/// three places now: on every card in the registry grid, in the detail header,
/// and beside the ref. Three copies of this would be three chances for `2h ago`
/// and `2 hours ago` to appear on the same screen.
String relativeAge(DateTime time) {
  final delta = DateTime.now().toUtc().difference(time.toUtc());
  if (delta.inMinutes < 1) return 'just now';
  if (delta.inHours < 1) return '${delta.inMinutes}m ago';
  if (delta.inDays < 1) return '${delta.inHours}h ago';
  return '${delta.inDays}d ago';
}
