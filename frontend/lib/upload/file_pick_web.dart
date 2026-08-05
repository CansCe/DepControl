import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

/// Reading a file the person chooses, in the browser.
///
/// The mirror of `file_download_web.dart`, and `package:web` for the same
/// reason: it is the SDK's own interop binding and Flutter already depends on
/// it, so a file-picker package would add a dependency to an application whose
/// purpose is telling people what their dependencies cost.
bool get canPickFile => true;

/// Opens the browser's file chooser and returns the file's text, or null when
/// the person cancels.
///
/// Text rather than bytes: a bundle is JSON somebody is meant to be able to read
/// before they send it, and nothing here should encourage handling it as an
/// opaque blob.
Future<String?> pickTextFile({String accept = '.json'}) {
  final completer = Completer<String?>();

  final input = web.document.createElement('input') as web.HTMLInputElement
    ..type = 'file'
    ..accept = accept;

  // `cancel` is not universally implemented, so a chooser that is dismissed can
  // leave this future pending. That is survivable — the button simply does
  // nothing — where completing early with null would race a slow `change` and
  // discard a file the person did choose.
  input.oncancel = ((web.Event _) {
    if (!completer.isCompleted) completer.complete(null);
  }).toJS;

  input.onchange = ((web.Event _) {
    final file = input.files?.item(0);
    if (file == null) {
      if (!completer.isCompleted) completer.complete(null);
      return;
    }

    final reader = web.FileReader();
    reader.onload = ((web.Event _) {
      if (completer.isCompleted) return;
      final result = reader.result;
      completer.complete(result.isA<JSString>() ? (result! as JSString).toDart : null);
    }).toJS;
    reader.onerror = ((web.Event _) {
      if (!completer.isCompleted) completer.complete(null);
    }).toJS;
    reader.readAsText(file);
  }).toJS;

  input.click();
  return completer.future;
}
