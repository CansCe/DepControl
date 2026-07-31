import 'package:shared/shared.dart';
import 'package:test/test.dart';

void main() {
  group('formatting', () {
    test('scales into the unit a package is discussed in', () {
      expect(PackageSize.formatBytes(512), '512 B');
      expect(PackageSize.formatBytes(2048), '2 KB');
      expect(PackageSize.formatBytes(1412415), '1.3 MB');
      expect(PackageSize.formatBytes(48 * 1024 * 1024), '48 MB');
    });

    test('drops the decimal past ten megabytes, where it is noise', () {
      expect(PackageSize.formatBytes(9 * 1024 * 1024), '9.0 MB');
      expect(PackageSize.formatBytes(11 * 1024 * 1024), '11 MB');
    });
  });

  group('json', () {
    test('round-trips', () {
      const size =
          PackageSize(bytes: 1412415, basis: SizeBasis.unpacked, fileCount: 1054);
      expect(PackageSize.fromJson(size.toJson()), size);
    });

    test('omits a file count nobody supplied', () {
      const size = PackageSize(bytes: 4096, basis: SizeBasis.archive);
      expect(size.toJson().containsKey('fileCount'), isFalse);
      expect(PackageSize.fromJson(size.toJson())?.fileCount, isNull);
    });

    test('reads a malformed entry as unmeasured rather than throwing', () {
      // A size is a nicety on a report whose advisories are the point, so one
      // bad row must not make the rest of it unreadable.
      expect(PackageSize.fromJson(null), isNull);
      expect(PackageSize.fromJson('1.4 MB'), isNull);
      expect(PackageSize.fromJson({'bytes': 'lots', 'basis': 'unpacked'}),
          isNull);
      expect(PackageSize.fromJson({'bytes': -5, 'basis': 'unpacked'}), isNull);
      expect(PackageSize.fromJson({'bytes': 10, 'basis': 'invented'}), isNull);
      expect(PackageSize.fromJson({'bytes': 10}), isNull);
    });

    test('a negative file count is dropped, not carried', () {
      final size = PackageSize.fromJson(
        {'bytes': 10, 'basis': 'archive', 'fileCount': -1},
      );
      expect(size?.bytes, 10);
      expect(size?.fileCount, isNull);
    });
  });

  group('DepNode', () {
    test('carries a size through json', () {
      const node = DepNode(
        name: 'lodash',
        kind: DepKind.direct,
        installed: '4.17.21',
        ecosystem: 'npm',
        size: PackageSize(
          bytes: 1412415,
          basis: SizeBasis.unpacked,
          fileCount: 1054,
        ),
      );

      final read = DepNode.fromJson(node.toJson());
      expect(read.size?.bytes, 1412415);
      expect(read.size?.basis, SizeBasis.unpacked);
      expect(read.size?.fileCount, 1054);
    });

    test('a report stored before size scanning reads back as unmeasured', () {
      // The field is omitted rather than written null, so an older report keeps
      // saying "nobody looked" instead of acquiring a zero.
      const node =
          DepNode(name: 'http', kind: DepKind.direct, installed: '1.6.0');

      expect(node.toJson().containsKey('size'), isFalse);
      expect(DepNode.fromJson(node.toJson()).size, isNull);
    });
  });

  group('SizeTally', () {
    test('keeps the two registries apart instead of adding them', () {
      final tally = SizeTally.of(const [
        PackageSize(bytes: 1000, basis: SizeBasis.unpacked),
        PackageSize(bytes: 400, basis: SizeBasis.unpacked),
        PackageSize(bytes: 250, basis: SizeBasis.archive),
      ]);

      expect(tally.bytesOn(SizeBasis.unpacked), 1400);
      expect(tally.bytesOn(SizeBasis.archive), 250);
      expect(tally.bases, [SizeBasis.unpacked, SizeBasis.archive]);
      expect(tally.display, '1 KB installed + 250 B compressed');
    });

    test('counts what it could not measure, and says so', () {
      final tally = SizeTally.of(const [
        PackageSize(bytes: 1000, basis: SizeBasis.unpacked),
        null,
        null,
      ]);

      expect(tally.measured, 1);
      expect(tally.unmeasured, 2);
      expect(tally.shortfall, contains('2 of 3'));
      expect(tally.shortfall, contains('higher'));
    });

    test('is silent about a shortfall when there is none', () {
      final tally = SizeTally.of(
        const [PackageSize(bytes: 10, basis: SizeBasis.archive)],
      );
      expect(tally.shortfall, isNull);
    });

    test('an all-unmeasured tally is empty rather than zero bytes', () {
      final tally = SizeTally.of([null, null]);

      expect(tally.isEmpty, isTrue);
      expect(tally.bases, isEmpty);
      expect(tally.unmeasured, 2);
    });
  });
}
