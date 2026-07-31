import 'package:backend/src/services/changelog_parser.dart';
import 'package:test/test.dart';

void main() {
  group('heading spellings', () {
    test('the plain one', () {
      final entries = ChangelogParser.parse('''
## 1.2.0

- Added a thing.

## 1.1.0

- Fixed a thing.
''');

      expect(entries.map((e) => e.version), ['1.2.0', '1.1.0']);
      expect(entries.first.notes, '- Added a thing.');
    });

    test('keep-a-changelog brackets and a date', () {
      final entries = ChangelogParser.parse('''
## [1.2.0] - 2024-05-01

### Added
- A thing.
''');

      expect(entries.single.version, '1.2.0');
      expect(entries.single.released, DateTime.utc(2024, 5, 1));
      expect(entries.single.notes, contains('### Added'));
    });

    test('a v prefix and a parenthesised date', () {
      final entries = ChangelogParser.parse('''
# v2.0.0 (2024-06-02)

Breaking.
''');

      expect(entries.single.version, '2.0.0');
      expect(entries.single.released, DateTime.utc(2024, 6, 2));
    });

    test('pre-release and build metadata survive', () {
      final entries = ChangelogParser.parse('''
## 1.0.0-beta.2

Nearly.
''');

      expect(entries.single.version, '1.0.0-beta.2');
    });

    test('any heading depth', () {
      final entries = ChangelogParser.parse('''
# 3.0.0
Top.

###### 2.0.0
Deep.
''');

      expect(entries.map((e) => e.version), ['3.0.0', '2.0.0']);
    });
  });

  group('what is not a release heading', () {
    test('prose that merely mentions a version', () {
      // `## Upgrading to 2.0.0` is a section of somebody's notes. Treating it
      // as a release boundary splits that release in half.
      final entries = ChangelogParser.parse('''
## 2.0.0

Breaking.

## Upgrading to 2.0.0

Do this first.

## 1.0.0

First.
''');

      expect(entries.map((e) => e.version), ['2.0.0', '1.0.0']);
      expect(entries.first.notes, contains('Upgrading to 2.0.0'));
      expect(entries.first.notes, contains('Do this first.'));
    });

    test('a heading with no version at all', () {
      final entries = ChangelogParser.parse('''
# Changelog

All notable changes.

## 1.0.0

First.
''');

      expect(entries.map((e) => e.version), ['1.0.0']);
    });

    test('a version inside a fenced code block', () {
      // Migration instructions routinely paste a pubspec, and a pasted
      // `## 1.2.3` would otherwise end the release it appears in.
      final entries = ChangelogParser.parse('''
## 2.0.0

Update your pubspec:

```yaml
## 1.9.9
dependencies:
  thing: ^2.0.0
```

That is all.

## 1.0.0

First.
''');

      expect(entries.map((e) => e.version), ['2.0.0', '1.0.0']);
      expect(entries.first.notes, contains('dependencies:'));
      expect(entries.first.notes, contains('That is all.'));
    });

    test('a tilde fence counts too', () {
      final entries = ChangelogParser.parse('''
## 2.0.0

~~~
## 1.5.0
~~~

Done.
''');

      expect(entries.map((e) => e.version), ['2.0.0']);
    });

    test('a bold line is not a heading', () {
      // Some projects use them, but matching them turns every emphasised line
      // into a release boundary.
      final entries = ChangelogParser.parse('''
**1.2.0**

Something.
''');

      expect(entries, isEmpty);
    });
  });

  group('the notes themselves', () {
    test('are kept verbatim', () {
      final entries = ChangelogParser.parse('''
## 1.0.0

- One
  - Nested

> A quote.

    indented code
''');

      final notes = entries.single.notes;
      expect(notes, contains('  - Nested'));
      expect(notes, contains('> A quote.'));
      expect(notes, contains('    indented code'));
    });

    test('a release with nothing written under it is empty, not missing', () {
      final entries = ChangelogParser.parse('''
## 1.1.0

## 1.0.0

First.
''');

      expect(entries, hasLength(2));
      expect(entries.first.isEmpty, isTrue);
    });

    test('an empty changelog parses to nothing rather than throwing', () {
      expect(ChangelogParser.parse(''), isEmpty);
      expect(ChangelogParser.parse('\n\n\n'), isEmpty);
    });
  });

  group('the range a move crosses', () {
    final entries = ChangelogParser.parse('''
## 2.0.0
Breaking.

## 1.2.0
Added.

## 1.1.0
Fixed.

## 1.0.0
First.
''');

    test('is open at the bottom and closed at the top', () {
      // 1.0.0's notes describe a release the project already had. Including
      // them would present old news as part of the upgrade.
      final crossed = ChangelogParser.entriesBetween(
        entries,
        from: '1.0.0',
        to: '1.2.0',
      );

      expect(crossed.map((e) => e.version), ['1.2.0', '1.1.0']);
    });

    test('is newest first', () {
      final crossed = ChangelogParser.entriesBetween(
        entries,
        from: '1.0.0',
        to: '2.0.0',
      );

      expect(crossed.map((e) => e.version), ['2.0.0', '1.2.0', '1.1.0']);
    });

    test('a move to a version with no section returns what it can', () {
      final crossed = ChangelogParser.entriesBetween(
        entries,
        from: '1.0.0',
        to: '1.5.0',
      );

      expect(crossed.map((e) => e.version), ['1.2.0', '1.1.0']);
    });

    test('no move is no notes', () {
      expect(
        ChangelogParser.entriesBetween(entries, from: '1.2.0', to: '1.2.0'),
        isEmpty,
      );
    });

    test('a downgrade returns the notes being given up', () {
      // Which direction the reader is going is their business.
      final crossed = ChangelogParser.entriesBetween(
        entries,
        from: '2.0.0',
        to: '1.1.0',
      );

      expect(crossed.map((e) => e.version), ['2.0.0', '1.2.0']);
    });

    test('an unreadable endpoint yields nothing rather than a guess', () {
      // `(unresolved)` is the sentinel for a project with no lockfile. Every
      // entry would be equally unplaceable against it.
      expect(
        ChangelogParser.entriesBetween(
          entries,
          from: '(unresolved)',
          to: '2.0.0',
        ),
        isEmpty,
      );
    });

    test('an entry whose version is unreadable is dropped, not guessed', () {
      final odd = ChangelogParser.parse('''
## 2.0.0
Real.

## Unreleased
Pending.
''');

      final crossed =
          ChangelogParser.entriesBetween(odd, from: '1.0.0', to: '2.0.0');
      expect(crossed.map((e) => e.version), ['2.0.0']);
    });

    test('pre-releases sort below their release', () {
      final withPre = ChangelogParser.parse('''
## 1.0.0
Final.

## 1.0.0-beta.1
Beta.
''');

      final crossed = ChangelogParser.entriesBetween(
        withPre,
        from: '0.9.0',
        to: '1.0.0',
      );
      expect(crossed.map((e) => e.version), ['1.0.0', '1.0.0-beta.1']);
    });
  });

  test('a real-shaped changelog reads end to end', () {
    // The shape pub.dev packages actually ship.
    final entries = ChangelogParser.parse('''
# Changelog

## 1.2.0

* Added `doThing()`.
* Deprecated `oldThing()`.

## 1.1.1

* Fixed a null dereference in `parse()` ([#42](https://example.com/42)).

## 1.1.0

* Requires Dart 3.6.

## 1.0.0

* Initial stable release.
''');

    expect(entries, hasLength(4));

    final crossed =
        ChangelogParser.entriesBetween(entries, from: '1.1.0', to: '1.2.0');
    expect(crossed.map((e) => e.version), ['1.2.0', '1.1.1']);
    expect(crossed.first.notes, contains('doThing()'));
    expect(crossed.last.notes, contains('#42'));
  });
}
