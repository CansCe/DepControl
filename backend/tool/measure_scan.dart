import 'dart:async';
import 'dart:io';

import 'package:backend/src/ecosystem/ecosystems.dart';
import 'package:backend/src/services/dependency_analyzer.dart';
import 'package:backend/src/services/git_fetcher.dart';

/// Scans a real repository and reports what it cost — wall clock, peak RSS and
/// node count.
///
/// ```
/// dart compile exe tool/measure_scan.dart -o /tmp/measure
/// /tmp/measure https://github.com/opengeos/GeoLibre
/// ```
///
/// **Compile it.** `dart run` measures the JIT VM, which carries machinery the
/// deployment does not: the same GeoLibre scan reads 574 MB under `dart run`
/// and 350 MB as a compiled binary. `backend/Dockerfile` ships
/// `dart compile exe`, so only the compiled number says anything about whether
/// a scan fits in the machine — and reading the JIT figure as though it did is
/// how you talk yourself into paying for memory you do not need.
///
/// Peak RSS is resident set rather than live heap, and Dart does not hand pages
/// back eagerly, so it reads high by nature. It is still the right number to
/// watch, because it is the one the host OOM-kills on.
///
/// Not a test: it hits the network, it is slow, and the timings move with the
/// weather. Its job is before-and-after on the same machine.
Future<void> main(List<String> args) async {
  final url = args.isEmpty ? 'https://github.com/opengeos/GeoLibre' : args.first;
  final ecosystems = Ecosystems.standard();
  final fetcher = GitFetcher(ecosystems: ecosystems);
  final analyzer = DependencyAnalyzer(ecosystems);

  var peak = 0;
  final sampler = Stopwatch()..start();
  final timer = Timer.periodic(const Duration(seconds: 2), (_) {
    final rss = ProcessInfo.currentRss;
    if (rss > peak) peak = rss;
  });

  stdout.writeln('fetching $url ...');
  final clock = Stopwatch()..start();
  final repo = await fetcher.fetchAll(url);
  final fetched = clock.elapsed;
  stdout.writeln(
    'fetched in ${fetched.inSeconds}s — ${repo.manifests.length} manifest(s)'
    '${repo.discoveryNote == null ? '' : ' (${repo.discoveryNote})'}',
  );

  final report = await analyzer.analyzeRepository('measure', repo);
  clock.stop();
  timer.cancel();
  sampler.stop();

  stdout
    ..writeln('')
    ..writeln('nodes         ${report.nodes.length}')
    ..writeln('outdated      ${report.outdated}')
    ..writeln('vulnerable    ${report.vulnerable}')
    ..writeln('fetch         ${fetched.inSeconds}s')
    ..writeln('analyse       ${(clock.elapsed - fetched).inSeconds}s')
    ..writeln('total         ${clock.elapsed.inSeconds}s')
    ..writeln('peak RSS      ${(peak / 1024 / 1024).round()} MB')
    ..writeln('final RSS     ${(ProcessInfo.currentRss / 1024 / 1024).round()} MB');
  exit(0);
}
