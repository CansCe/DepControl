import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/widgets/license_panel.dart';
import 'package:shared/shared.dart';

PackageLicense _license(
  String? spdxId,
  LicenseCategory category, {
  LicenseSource source = LicenseSource.installedVersion,
  String? readFromVersion,
}) =>
    PackageLicense(
      spdxId: spdxId,
      category: category,
      source: source,
      readFromVersion: readFromVersion,
    );

DepNode _node(String name, PackageLicense? license, {String version = '1.0.0'}) =>
    DepNode(
      name: name,
      kind: DepKind.direct,
      installed: version,
      license: license,
    );

LicenseReport _reportOf(
  List<DepNode> nodes, {
  LicensePolicy policy = LicensePolicy.standard,
}) =>
    LicenseReport.of(
      DepReport(
        projectId: 'p1',
        generatedAt: DateTime.utc(2026, 7, 28),
        nodes: nodes,
      ),
      policy,
    );

Future<void> pump(
  WidgetTester tester,
  LicenseReport report, {
  bool policyIsCustom = true,
  Future<String> Function()? onLoadManifest,
  Future<void> Function(LicensePolicy)? onSavePolicy,
  Future<void> Function()? onResetPolicy,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: LicensePanel(
            load: () async => (report: report, policyIsCustom: policyIsCustom),
            onLoadManifest: onLoadManifest,
            onSavePolicy: onSavePolicy,
            onResetPolicy: onResetPolicy,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  final agpl = _node(
    'copyleft_pkg',
    _license('AGPL-3.0-only', LicenseCategory.networkCopyleft),
    version: '2.0.0',
  );
  final mpl =
      _node('weak_pkg', _license('MPL-2.0', LicenseCategory.weakCopyleft));
  final mit = _node('http', _license('MIT', LicenseCategory.permissive));

  // An AGPL dependency nobody clicked to reveal has not been found, which is
  // why this panel loads with the report rather than behind a button.
  testWidgets('loads without being asked', (tester) async {
    var loaded = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LicensePanel(
            load: () async {
              loaded = true;
              return (report: _reportOf([mit]), policyIsCustom: true);
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(loaded, isTrue);
  });

  testWidgets('leads with the breakdown by verdict', (tester) async {
    await pump(tester, _reportOf([agpl, mpl, mit]));

    expect(find.text('License compliance'), findsOneWidget);
    expect(find.text('1 forbidden'), findsOneWidget);
    expect(find.text('1 needs review'), findsOneWidget);
    expect(find.text('1 allowed'), findsOneWidget);
  });

  testWidgets('names the forbidden package and why', (tester) async {
    await pump(tester, _reportOf([agpl, mit]));

    expect(find.textContaining('copyleft_pkg'), findsOneWidget);
    expect(find.textContaining('Forbidden'), findsOneWidget);
    expect(find.textContaining('AGPL-3.0-only'), findsWidgets);
    expect(find.textContaining('counts as distribution'), findsOneWidget);
  });

  // The panel is an exception list; the manifest is the inventory.
  testWidgets('does not list the packages that clear the policy',
      (tester) async {
    await pump(tester, _reportOf([agpl, mit]));

    expect(find.textContaining('http 1.0.0'), findsNothing);
    expect(find.textContaining('In use:'), findsOneWidget);
  });

  testWidgets('says so when everything clears', (tester) async {
    await pump(tester, _reportOf([mit]));

    expect(find.textContaining('clears the policy'), findsOneWidget);
  });

  // A reader looking at a forbidden dependency has to know whether they are
  // reading their company's decision or this app's default.
  testWidgets('says when nobody has written a policy', (tester) async {
    await pump(tester, _reportOf([agpl]), policyIsCustom: false);

    expect(find.textContaining('nobody has written a policy'), findsOneWidget);
  });

  testWidgets('says nothing about defaults once a policy exists',
      (tester) async {
    await pump(tester, _reportOf([agpl]));

    expect(find.textContaining('nobody has written a policy'), findsNothing);
  });

  // The one part of a finding that is inferred rather than read.
  testWidgets('flags a license read from a different release', (tester) async {
    await pump(
      tester,
      _reportOf([
        _node(
          'old_pin',
          _license(
            'GPL-3.0-only',
            LicenseCategory.strongCopyleft,
            source: LicenseSource.latestRelease,
            readFromVersion: '4.0.0',
          ),
          version: '0.1.0',
        ),
      ]),
    );

    expect(find.textContaining('Read from 4.0.0'), findsOneWidget);
  });

  // Never checked must not read the same as checked and clean — and an SDK
  // dependency must not sit in the review pile, where it would bury the
  // findings someone can actually act on.
  testWidgets('separates the packages it could not check', (tester) async {
    await pump(
      tester,
      _reportOf([
        mit,
        _node('legacy_pkg', null),
        _node('flutter', const PackageLicense.notFromPubDev('the SDK')),
      ]),
    );

    expect(find.textContaining('clears the policy'), findsOneWidget);
    expect(find.textContaining('2 packages could not be checked'),
        findsOneWidget);
    expect(find.text('1 allowed'), findsOneWidget);
    expect(find.text('2 needs review'), findsNothing);
  });

  testWidgets('shows the manifest on request', (tester) async {
    await pump(
      tester,
      _reportOf([mit]),
      onLoadManifest: () async => 'package,version,license\r\nhttp,1.0.0,MIT',
    );

    await tester.tap(find.text('Manifest for review'));
    await tester.pumpAndSettle();

    expect(find.text('License manifest'), findsOneWidget);
    expect(find.textContaining('http,1.0.0,MIT'), findsOneWidget);
  });

  group('the policy editor', () {
    testWidgets('is hidden when there is nothing to save to', (tester) async {
      await pump(tester, _reportOf([agpl]));
      expect(find.text('Policy'), findsNothing);
    });

    testWidgets('saves a changed rule', (tester) async {
      LicensePolicy? saved;
      await pump(
        tester,
        _reportOf([agpl]),
        onSavePolicy: (policy) async => saved = policy,
      );

      await tester.tap(find.text('Policy'));
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const ValueKey('rule-networkCopyleft')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Allowed').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(
        saved!.categories[LicenseCategory.networkCopyleft],
        LicenseRule.allowed,
      );
      // Untouched families are saved as they stood, not dropped.
      expect(
        saved!.categories[LicenseCategory.strongCopyleft],
        LicenseRule.forbidden,
      );
    });

    // Named exceptions have no editor here, so a save must carry them through
    // rather than quietly discarding them.
    testWidgets('keeps named-license exceptions it cannot edit',
        (tester) async {
      LicensePolicy? saved;
      await pump(
        tester,
        _reportOf(
          [agpl],
          policy: const LicensePolicy(
            licenses: {'SSPL-1.0': LicenseRule.allowed},
          ),
        ),
        onSavePolicy: (policy) async => saved = policy,
      );

      await tester.tap(find.text('Policy'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(saved!.licenses, {'SSPL-1.0': LicenseRule.allowed});
    });

    // Dropping the policy is a different act from saving a copy of the
    // standard rules, because the report tells the reader which they have.
    testWidgets('resets rather than saving a copy of the defaults',
        (tester) async {
      var reset = false;
      LicensePolicy? saved;
      await pump(
        tester,
        _reportOf([agpl]),
        onSavePolicy: (policy) async => saved = policy,
        onResetPolicy: () async => reset = true,
      );

      await tester.tap(find.text('Policy'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Reset to standard'));
      await tester.pumpAndSettle();

      expect(reset, isTrue);
      expect(saved, isNull);
    });

    testWidgets('offers no reset when there is nothing to reset',
        (tester) async {
      await pump(
        tester,
        _reportOf([agpl]),
        policyIsCustom: false,
        onSavePolicy: (_) async {},
        onResetPolicy: () async {},
      );

      await tester.tap(find.text('Policy'));
      await tester.pumpAndSettle();

      expect(find.text('Reset to standard'), findsNothing);
    });
  });
}
