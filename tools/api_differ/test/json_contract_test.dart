import 'package:api_differ/api_differ.dart';
import 'package:test/test.dart';

/// The `--json` output is consumed by the DepControl backend, which parses it
/// into `shared`'s `ApiDiff`. That package cannot depend on this one — this tool
/// pins an analyzer the app's pub workspace cannot resolve, which is why it
/// lives outside it — so nothing but these keys connects the two ends.
///
/// The consumer holds a recorded sample of this output
/// (`packages/shared/test/fixtures/`). Change the shape here and that test fails
/// too; change it in both and the stored diffs from before the change stop
/// parsing.
void main() {
  test('a diff serialises to the keys the backend reads', () {
    final json = const ApiDiff(
      package: 'yaml',
      from: '3.1.2',
      to: '3.1.3',
      changes: [
        ApiChange(
          kind: ApiChangeKind.removed,
          declaration: 'class Pair',
          before: 'Pair',
        ),
      ],
    ).toJson();

    expect(json.keys, containsAll(['package', 'from', 'to', 'changes']));
    expect(json['package'], 'yaml');
    expect(json['from'], '3.1.2');
    expect(json['to'], '3.1.3');

    final change = (json['changes'] as List).single as Map<String, dynamic>;
    expect(
        change.keys, containsAll(['kind', 'declaration', 'before', 'after']));
    expect(change['kind'], 'removed');
    expect(change['declaration'], 'class Pair');
    expect(change['before'], 'Pair');
    expect(change['after'], isNull);
  });

  // The consumer maps these onto an enum by name, so renaming one silently
  // turns every stored diff of that kind into a parse failure.
  test('the change kinds are named as the backend expects', () {
    expect(
      ApiChangeKind.values.map((k) => k.name),
      ['removed', 'changed', 'added'],
    );
  });
}
