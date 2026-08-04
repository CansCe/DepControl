import 'package:ecosystem/ecosystem.dart';
import 'package:test/test.dart';

void main() {
  const scanner = DotNetSourceScanner();

  group('C#', () {
    test('a using names every prefix of its namespace', () {
      // The package is `Newtonsoft.Json` and the code says
      // `Newtonsoft.Json.Linq`. Reporting only what was written would call the
      // package unused.
      final found = scanner.scan(['using Newtonsoft.Json.Linq;\n']);

      expect(found, {'Newtonsoft', 'Newtonsoft.Json', 'Newtonsoft.Json.Linq'});
    });

    test('global, static and aliased forms', () {
      final found = scanner.scan([
        'global using Serilog;\n'
            'using static System.Math;\n'
            'using J = Newtonsoft.Json;\n',
      ]);

      expect(found, contains('Serilog'));
      expect(found, contains('System.Math'));
      // The alias is discarded; what it points at is what counts.
      expect(found, contains('Newtonsoft.Json'));
      expect(found, isNot(contains('J')));
    });

    test('a using statement is not a using directive', () {
      final found = scanner.scan([
        'void M() {\n  using (var s = new StreamReader(p)) { }\n}\n',
      ]);

      expect(found, isEmpty);
    });

    test('a commented directive is not a directive', () {
      final found = scanner.scan([
        '// using Commented.Out;\n'
            '/*\n using Blocked.Out;\n*/\n'
            'using Real.One;\n',
      ]);

      expect(found, {'Real', 'Real.One'});
    });
  });

  group('F# and Visual Basic', () {
    test('open and Imports are read too', () {
      // Not for completeness: an ecosystem whose scanner reads none of a
      // project's source returns the empty set, and empty means "looked and
      // found nothing" — which reports every dependency as unused.
      expect(scanner.scan(['open Newtonsoft.Json\n']),
          {'Newtonsoft', 'Newtonsoft.Json'});
      expect(scanner.scan(['Imports Serilog\n']), {'Serilog'});
      expect(scanner.scan(['open type Serilog.Log\n']),
          {'Serilog', 'Serilog.Log'});
    });
  });

  test('source with no directives is an empty set, not a failure', () {
    expect(scanner.scan(['class C { }\n']), isEmpty);
  });
}
