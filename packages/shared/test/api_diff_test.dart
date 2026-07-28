import 'dart:convert';
import 'dart:io';

import 'package:shared/shared.dart';
import 'package:test/test.dart';

/// Real output of `dart run api_differ yaml 3.1.2 3.1.3 --json`, recorded
/// verbatim. `tools/api_differ` pins its own analyzer outside this workspace and
/// cannot be depended on from here, so this file is the only thing holding the
/// two ends of the contract together — if the differ's JSON drifts, re-record it
/// and this test says what broke.
const _fixture = 'test/fixtures/api_differ_yaml_3.1.2_3.1.3.json';

void main() {
  late Map<String, dynamic> recorded;

  setUpAll(() {
    recorded =
        jsonDecode(File(_fixture).readAsStringSync()) as Map<String, dynamic>;
  });

  group('parsing the differ output', () {
    test('reads the package and the versions compared', () {
      final diff = ApiDiff.fromJson(recorded);

      expect(diff.package, 'yaml');
      expect(diff.from, '3.1.2');
      expect(diff.to, '3.1.3');
      expect(diff.changes, hasLength(12));
    });

    test('sorts the changes into kinds', () {
      final diff = ApiDiff.fromJson(recorded);

      expect(diff.removed.map((c) => c.declaration), contains('class Pair'));
      expect(diff.changed.map((c) => c.declaration), contains('YamlMap.wrap'));
      expect(diff.added.map((c) => c.declaration), contains('isHighSurrogate'));
      expect(
        diff.removed.length + diff.changed.length + diff.added.length,
        diff.changes.length,
      );
    });

    test('keeps both signatures of a changed declaration', () {
      final diff = ApiDiff.fromJson(recorded);
      final change =
          diff.changed.firstWhere((c) => c.declaration == 'YamlMap.new');

      expect(change.before, '({sourceUrl})');
      expect(change.after, '({Object? sourceUrl})');
    });

    test('a removed declaration has no "after" signature', () {
      final diff = ApiDiff.fromJson(recorded);

      expect(diff.removed.every((c) => c.after == null), isTrue);
      expect(diff.removed.every((c) => c.before != null), isTrue);
    });

    test('the differ does not stamp a time — the store does', () {
      expect(ApiDiff.fromJson(recorded).generatedAt, isNull);
    });
  });

  group('hasBreakingChanges', () {
    test('is true when a declaration was removed or changed', () {
      expect(ApiDiff.fromJson(recorded).hasBreakingChanges, isTrue);
    });

    // A release that only adds is not worth putting in front of anyone.
    test('is false when everything is an addition', () {
      const diff = ApiDiff(
        package: 'collection',
        from: '1.18.0',
        to: '1.19.0',
        changes: [
          ApiChange(
            kind: ApiChangeKind.added,
            declaration: 'stableSortBy',
            after: 'void (Iterable elements)',
          ),
        ],
      );

      expect(diff.hasBreakingChanges, isFalse);
    });

    test('is false when nothing changed at all', () {
      const diff = ApiDiff(package: 'async', from: '2.11.0', to: '2.12.0');
      expect(diff.hasBreakingChanges, isFalse);
    });
  });

  group('round trip', () {
    test('survives toJson/fromJson unchanged', () {
      final original = ApiDiff.fromJson(recorded);
      final restored = ApiDiff.fromJson(original.toJson());

      expect(restored.package, original.package);
      expect(restored.changes, hasLength(original.changes.length));
      for (var i = 0; i < original.changes.length; i++) {
        expect(restored.changes[i].kind, original.changes[i].kind);
        expect(
          restored.changes[i].declaration,
          original.changes[i].declaration,
        );
        expect(restored.changes[i].before, original.changes[i].before);
        expect(restored.changes[i].after, original.changes[i].after);
      }
    });

    test('carries the ingest timestamp when one was stamped', () {
      final stamped = ApiDiff(
        package: 'yaml',
        from: '3.1.2',
        to: '3.1.3',
        generatedAt: DateTime.utc(2026, 7, 28, 9, 30),
      );

      expect(
        ApiDiff.fromJson(stamped.toJson()).generatedAt,
        DateTime.utc(2026, 7, 28, 9, 30),
      );
    });
  });
}
