import 'dart:js_interop';

import 'package:web/web.dart' as web;

/// Saving a file from the browser.
///
/// `package:web` rather than a file-saver package: it is the SDK's own interop
/// binding, Flutter already depends on it, so declaring it adds nothing to the
/// resolution that was not there. In an app whose purpose is telling people
/// what their dependencies cost, a package for eight lines would be a poor
/// advertisement.
bool get canDownload => true;

/// Hands [contents] to the browser as a download named [filename].
///
/// A Blob and an object URL rather than a `data:` URI. Data URIs are capped at
/// a couple of megabytes in most browsers and silently truncate past it, and a
/// CSV of a large monorepo's dependencies passes that easily — the failure
/// would be a file that opens fine and is missing its last rows, which is the
/// worst way for an export to break.
Future<void> downloadText(
  String filename,
  String contents, {
  required String mimeType,
}) async {
  final blob = web.Blob(
    [contents.toJS].toJS,
    web.BlobPropertyBag(type: '$mimeType;charset=utf-8'),
  );

  final url = web.URL.createObjectURL(blob);
  final anchor = web.document.createElement('a') as web.HTMLAnchorElement
    ..href = url
    ..download = filename;

  // Must be in the document for the click to count in Firefox.
  web.document.body!.appendChild(anchor);
  anchor.click();
  anchor.remove();

  // The blob is held alive by the object URL until it is revoked, so a few
  // exports in one session would otherwise pin every file in memory for the
  // life of the tab.
  web.URL.revokeObjectURL(url);
}
