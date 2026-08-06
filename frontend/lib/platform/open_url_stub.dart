/// Opening a download link, on a build with no browser to open it in.
bool get canOpenUrl => false;

void openUrl(String url) {
  throw UnsupportedError('This build cannot open URLs; check canOpenUrl first.');
}
