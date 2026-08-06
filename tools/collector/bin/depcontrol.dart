import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:collector/collector.dart';
import 'package:http/http.dart' as http;
import 'package:shared/shared.dart';

/// `depcontrol collect` — read a repository here, and write down what it
/// depends on.
///
/// For the repositories a hosted scanner cannot reach at all: Azure DevOps,
/// GitHub Enterprise, an internal GitLab, anything behind a VPN. And for the
/// lockfiles that are generated locally and never committed, which is what makes
/// the difference between an advisory matched against a resolved version and one
/// guessed at from a constraint.
///
/// It writes a file and stops. Sending it is a separate action with a separate
/// flag, because "produce a bundle" and "upload a bundle" are different
/// decisions and somebody should be able to read the first before taking the
/// second.
Future<void> main(List<String> arguments) async {
  // Set rather than returned: Dart ignores what `main` returns, and a CLI whose
  // failures all exit 0 is one no script can check.
  exitCode = await _run(arguments);
}

/// The hosted API `--pair` submits to when `--api` is not given.
const kDefaultApi = 'https://depcontrol-api.fly.dev';

Future<int> _run(List<String> arguments) async {
  final parser = ArgParser()
    ..addFlag(
      'help',
      abbr: 'h',
      negatable: false,
      help: 'Print this usage information.',
    );

  final collectParser = parser.addCommand('collect')
    ..addOption(
      'out',
      abbr: 'o',
      defaultsTo: 'depcontrol-bundle.json',
      help: 'Where to write the bundle. "-" writes to stdout.',
    )
    ..addFlag(
      'redact-paths',
      negatable: false,
      help: 'Replace manifest directories and package names with opaque ids. '
          'The report says it was redacted rather than quietly rendering the '
          'ids as names.',
    )
    ..addFlag(
      'exclude-private',
      negatable: false,
      help: 'Drop packages resolved from a private feed entirely, instead of '
          'listing them as unchecked. The report says how many were withheld.',
    )
    ..addFlag(
      'compact',
      negatable: false,
      help: 'Write the bundle on one line. The default is indented, because a '
          'file nobody can read is a file nobody can check before sending.',
    )
    ..addOption(
      'pair',
      help: 'After writing the bundle, submit it using a pairing code minted '
          'from the registry screen ("Add project" > run the collector). '
          'Pass "-" to read the code from stdin instead of the command line, '
          'for anyone who does not want it in their shell history. Mutually '
          'exclusive with --upload — a code already names the account.',
    )
    ..addOption(
      'api',
      defaultsTo: kDefaultApi,
      help: 'Base URL for --pair. Defaults to the hosted DepControl API.',
    )
    ..addOption(
      'upload',
      help: 'After writing the bundle, send it to this DepControl API — for '
          'example https://depcontrol.fly.dev. Off unless asked for. Needs '
          '--token; prefer --pair, which needs nothing but a code.',
    )
    ..addOption(
      'token',
      help: 'Access token for --upload. Defaults to \$DEPCONTROL_TOKEN. Read '
          'from the environment by preference, so it does not end up in a '
          'shell history.',
    )
    ..addOption(
      'project',
      help: 'With --upload, re-upload to an existing project by id instead of '
          'creating a new one. This is how a local project is brought up to '
          'date; it cannot be re-fetched.',
    );

  // A double-clicked binary arrives with no arguments at all, and on Windows
  // with a console freshly allocated just for it — there is no useful "print
  // usage and exit" for someone who just double-clicked an .exe. `collect .`
  // is the one thing worth doing by default; usage is still one --help away.
  if (arguments.isEmpty && stdout.hasTerminal) {
    return _collect(collectParser.parse(const []));
  }

  final ArgResults args;
  try {
    args = parser.parse(arguments);
  } on FormatException catch (e) {
    stderr.writeln(e.message);
    _usage(collectParser);
    return 64; // EX_USAGE
  }

  if (args['help'] as bool) {
    _usage(collectParser);
    return 0;
  }
  if (args.command?.name != 'collect') {
    _usage(collectParser);
    return 64;
  }

  final command = args.command!;
  if (command['pair'] != null && command['upload'] != null) {
    stderr.writeln(
      '--pair and --upload are mutually exclusive: a pairing code already '
      'names the account this bundle goes to.',
    );
    return 64;
  }

  return _collect(command);
}

Future<int> _upload(
  CollectedBundle bundle, {
  required String api,
  required String? token,
  required String? projectId,
}) async {
  if (token == null || token.isEmpty) {
    stderr.writeln(
      'Uploading needs an access token. Set DEPCONTROL_TOKEN, or pass '
      '--token. The bundle has been written either way.',
    );
    return 77; // EX_NOPERM
  }

  final base = Uri.tryParse(api);
  if (base == null || !base.isScheme('https') && !base.isScheme('http')) {
    stderr.writeln('--upload needs an https URL, e.g. https://depcontrol.fly.dev');
    return 64;
  }

  // The client invents its own scan id so it can watch without waiting for one
  // to come back, which is what the server's queue is keyed by.
  final scanId = 'collect-${DateTime.now().toUtc().millisecondsSinceEpoch}';
  final url = projectId == null
      ? base.resolve('/projects')
      : base.resolve('/projects/$projectId/bundle');

  final http.Response response;
  try {
    response = await http.post(
      url,
      headers: {
        'content-type': 'application/json',
        'authorization': 'Bearer $token',
      },
      body: jsonEncode({'scanId': scanId, 'bundle': bundle.toJson()}),
    );
  } on http.ClientException catch (e) {
    stderr.writeln('Could not reach $url: ${e.message}');
    return 69; // EX_UNAVAILABLE
  }

  if (response.statusCode >= 200 && response.statusCode < 300) {
    stderr.writeln(
      'Uploaded to $url. The scan runs on the server whether or not this '
      'process stays open; watch it as $scanId.',
    );
    return 0;
  }

  stderr.writeln('$url answered ${response.statusCode}: ${response.body}');
  return 65;
}

/// Submits a freshly written bundle against a pairing code minted from the
/// registry screen. The web page that minted it is already polling and picks
/// the scan up on its own — nothing here has to say where to look.
Future<int> _pair(
  CollectedBundle bundle, {
  required String api,
  required String code,
}) async {
  final base = Uri.tryParse(api);
  if (base == null || !base.isScheme('https') && !base.isScheme('http')) {
    stderr.writeln('--api needs an https URL, e.g. $kDefaultApi');
    return 64;
  }

  // The client invents its own scan id so it can watch without waiting for one
  // to come back, which is what the server's queue is keyed by — same as
  // `--upload`.
  final scanId = 'collect-${DateTime.now().toUtc().millisecondsSinceEpoch}';
  final url = base.resolve('/collector/bundles');

  final http.Response response;
  try {
    response = await http.post(
      url,
      headers: {'content-type': 'application/json'},
      body: jsonEncode({
        'code': code,
        'scanId': scanId,
        'bundle': bundle.toJson(),
      }),
    );
  } on http.ClientException catch (e) {
    stderr.writeln('Could not reach $url: ${e.message}');
    return 69; // EX_UNAVAILABLE
  }

  if (response.statusCode >= 200 && response.statusCode < 300) {
    stderr.writeln(
      'Submitted. The page that showed this code is already watching — scan '
      '$scanId runs on the server whether or not this window stays open.',
    );
    return 0;
  }

  if (response.statusCode == HttpStatus.unauthorized) {
    stderr.writeln(
      'That code was refused: ${response.body}\n'
      'It may be wrong, already used, or older than fifteen minutes. Mint a '
      'new one from the registry screen and pass it to --pair.',
    );
    return 77; // EX_NOPERM
  }

  stderr.writeln('$url answered ${response.statusCode}: ${response.body}');
  return 65;
}

/// Reads a pairing code from the command line, or from stdin when [raw] is
/// `-` — for anyone who does not want a bearer credential sitting in their
/// shell history. Null for anything blank either way.
String? _readCode(String raw) {
  final code = raw == '-' ? stdin.readLineSync() : raw;
  final trimmed = code?.trim();
  return trimmed == null || trimmed.isEmpty ? null : trimmed;
}

Future<int> _collect(ArgResults args) async {
  final rest = args.rest;
  if (rest.length > 1) {
    stderr.writeln('collect takes one directory at most.');
    return 64;
  }

  final root = Directory(rest.isEmpty ? '.' : rest.single);
  if (!root.existsSync()) {
    stderr.writeln('${root.path} does not exist.');
    return 66; // EX_NOINPUT
  }

  final collector = Collector(
    root: root,
    redactPaths: args['redact-paths'] as bool,
    excludePrivate: args['exclude-private'] as bool,
  );

  final CollectedBundleResult result;
  try {
    result = CollectedBundleResult(collector.collect());
  } on StateError catch (e) {
    stderr.writeln(e.message);
    return 65; // EX_DATAERR — the repository, not the invocation
  }

  final json = args['compact'] as bool
      ? jsonEncode(result.bundle.toJson())
      : const JsonEncoder.withIndent('  ').convert(result.bundle.toJson());

  final out = args['out'] as String;
  final File? outFile = out == '-' ? null : File(out);
  if (outFile == null) {
    stdout.writeln(json);
  } else {
    outFile.writeAsStringSync('$json\n');
  }

  // To stderr, so `--out -` still pipes clean JSON. This summary — and the
  // path, when there is one — is the whole of the "read it before it goes
  // anywhere" promise being kept: it says what the file contains and exactly
  // where it sits before anybody decides to send it. The absolute path
  // matters specifically for a double-clicked binary, whose working directory
  // is not obviously anywhere.
  if (outFile != null) {
    stderr.writeln('Written to ${outFile.absolute.path}.');
  }
  stderr.writeln(result.summary);

  final pairCode = args['pair'] as String?;
  if (pairCode != null) {
    final code = _readCode(pairCode);
    if (code == null) {
      stderr.writeln('--pair needs a code; none was given on stdin.');
      return 64;
    }
    return _pair(result.bundle, api: args['api'] as String, code: code);
  }

  final api = args['upload'] as String?;
  if (api == null) {
    // The default, and the reason `--upload`/`--pair` are separate flags:
    // producing a bundle and sending one are different decisions, and
    // somebody should be able to read the first before taking the second.
    if (outFile == null) stderr.writeln();
    stderr.writeln('Nothing has been sent anywhere.');
    return 0;
  }

  return _upload(
    result.bundle,
    api: api,
    token: (args['token'] as String?) ??
        Platform.environment['DEPCONTROL_TOKEN'],
    projectId: args['project'] as String?,
  );
}

/// A bundle and the sentence describing it.
class CollectedBundleResult {
  CollectedBundleResult(this.bundle);

  final CollectedBundle bundle;

  String get summary {
    final manifests = bundle.manifests.length;
    final packages = bundle.packageCount;
    final lines = <String>[
      'Read $manifests manifest${manifests == 1 ? '' : 's'}, '
          '$packages package reference${packages == 1 ? '' : 's'}'
          '${bundle.rootPackageName == null ? '' : ' in '
              '${bundle.rootPackageName}'}.',
    ];
    if (bundle.pathsRedacted) {
      lines.add('Manifest directories and package names are redacted.');
    }
    if (bundle.privatePackagesWithheld > 0) {
      lines.add(
        '${bundle.privatePackagesWithheld} private-feed package '
        'reference(s) withheld.',
      );
    }
    if (bundle.coverageNote case final note?) lines.add(note);
    return lines.join('\n');
  }
}

void _usage(ArgParser parser) {
  stderr
    ..writeln('depcontrol collect [directory] [options]')
    ..writeln()
    ..writeln(
      'Reads a repository where it lives and writes down what it depends on:\n'
      'package names, the versions they resolved to, and where each manifest\n'
      'sits. No source, no file contents, no URLs, no absolute paths, no\n'
      'credentials, and no internal feed hostnames. Nothing is executed and\n'
      'nothing is sent.',
    )
    ..writeln()
    ..writeln(parser.usage);
}
