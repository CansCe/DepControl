/// Saving a file, on a build that has nowhere to save one to.
///
/// The app build reaches this. There is no browser download directory to write
/// to and no share sheet wired up, so rather than pretend, this reports that it
/// did nothing and the caller keeps the button off the screen — [canDownload]
/// is what the UI asks, so nobody is offered an export that silently fails.
bool get canDownload => false;

Future<void> downloadText(
  String filename,
  String contents, {
  required String mimeType,
}) async {
  throw UnsupportedError(
    'This build cannot download files; check canDownload first.',
  );
}
