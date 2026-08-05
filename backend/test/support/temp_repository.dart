import 'dart:io';

import 'package:test/test.dart';

/// A throwaway working tree holding [files], keyed by repo-relative path.
///
/// The collector reads a directory rather than an archive, so a test of the
/// bundle path needs a real one. Registered for deletion with the test that
/// built it.
Directory tempRepository(Map<String, String> files) {
  final root = Directory.systemTemp.createTempSync('depcontrol-test-');
  addTearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  for (final entry in files.entries) {
    final file = File('${root.path}/${entry.key}');
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(entry.value);
  }
  return root;
}
