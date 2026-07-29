import 'package:backend/src/repository/postgres_pool.dart';
import 'package:test/test.dart';

// `postgresPoolFromUrl` opens no connections — the pool is lazy — so these
// exercise the parsing without needing a database.
void main() {
  const url = 'postgresql://postgres.abc:pw@db.pooler.supabase.com:5432/postgres';

  group('postgresPoolFromUrl', () {
    test('accepts a Supabase connection string', () {
      expect(() => postgresPoolFromUrl(url), returnsNormally);
    });

    test('accepts the postgres:// scheme too', () {
      expect(
        () => postgresPoolFromUrl(url.replaceFirst('postgresql', 'postgres')),
        returnsNormally,
      );
    });

    // A secret set through a shell or a dashboard arrives wrapped. Every one of
    // these used to surface as "Scheme not starting with alphabetic character",
    // which sends you looking at the scheme rather than at the quoting.
    test('tolerates the packaging a secret store adds', () {
      for (final wrapped in <String>[
        '"$url"',
        "'$url'",
        ' $url ',
        '\n$url\n',
        '\u{feff}$url',
      ]) {
        expect(
          () => postgresPoolFromUrl(wrapped),
          returnsNormally,
          reason: 'should have unwrapped ${wrapped.codeUnits.take(2)}',
        );
      }
    });

    test('keeps an unbalanced quote, which means a truncated value', () {
      expect(() => postgresPoolFromUrl('"$url'), throwsArgumentError);
    });

    test('rejects an unreplaced password placeholder', () {
      expect(
        () => postgresPoolFromUrl(
          'postgresql://postgres:[YOUR-PASSWORD]@db.pooler.supabase.com:5432/postgres',
        ),
        throwsArgumentError,
      );
    });

    test('rejects a non-postgres scheme', () {
      expect(
        () => postgresPoolFromUrl('https://db.pooler.supabase.com:5432/postgres'),
        throwsArgumentError,
      );
    });
  });
}
