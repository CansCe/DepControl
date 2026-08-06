import 'package:web/web.dart' as web;

/// Opening a download link, in the browser.
///
/// `package:web` rather than `url_launcher`: it is the SDK's own interop
/// binding and Flutter already depends on it, the same reasoning as
/// `file_pick_web.dart` and `file_download_web.dart`.
bool get canOpenUrl => true;

/// Opens [url] in a new tab. The only thing this is used for is the
/// collector's own release binaries — a build where [canOpenUrl] is false has
/// nothing to call this with.
void openUrl(String url) => web.window.open(url, '_blank');
