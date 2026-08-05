/// Choosing a file, on a build that has no chooser.
///
/// The app build reaches this. Rather than pretend, it reports that it cannot —
/// [canPickFile] is what the UI asks, so the drop area is never offered where it
/// would do nothing. The CLI command beside it is shown either way, because that
/// is the half of the instructions that is true everywhere.
bool get canPickFile => false;

Future<String?> pickTextFile({String accept = '.json'}) async {
  throw UnsupportedError(
    'This build cannot choose files; check canPickFile first.',
  );
}
