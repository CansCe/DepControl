import 'package:backend/src/env.dart';
import 'package:test/test.dart';

void main() {
  group('unwrapEnvValue', () {
    test('leaves a clean value alone', () {
      expect(
        unwrapEnvValue('https://abc.supabase.co'),
        'https://abc.supabase.co',
      );
    });

    // The shape that crashed the deployed server on boot: `cmd.exe` does not
    // treat single quotes as quoting, so they landed in the secret verbatim.
    test('removes quotes a shell failed to strip', () {
      for (final quoted in <String>[
        "'https://abc.supabase.co'",
        '"https://abc.supabase.co"',
      ]) {
        expect(unwrapEnvValue(quoted), 'https://abc.supabase.co');
      }
    });

    test('removes surrounding whitespace and a BOM', () {
      expect(unwrapEnvValue('  https://abc.supabase.co\n'),
          'https://abc.supabase.co');
      expect(unwrapEnvValue('\u{feff}https://abc.supabase.co'),
          'https://abc.supabase.co');
    });

    test('keeps an unbalanced quote so the value still fails', () {
      expect(unwrapEnvValue("'https://abc.supabase.co"),
          "'https://abc.supabase.co");
    });

    test('keeps quotes that are part of the value', () {
      expect(unwrapEnvValue("pa'ss"), "pa'ss");
    });
  });

  group('readEnvironment', () {
    test('unwraps every value', () {
      final env = readEnvironment({
        'SUPABASE_URL': "'https://abc.supabase.co'",
        'ENV': '"production"',
        'CLEAN': 'as-is',
      });
      expect(env['SUPABASE_URL'], 'https://abc.supabase.co');
      // A quoted 'production' is not `production`: without this the deployed
      // server would quietly stay in development mode.
      expect(env['ENV'], 'production');
      expect(env['CLEAN'], 'as-is');
    });
  });
}
