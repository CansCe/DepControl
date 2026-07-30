import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared/shared.dart';

import '../api/api_client.dart';
import '../auth/session_monitor.dart';

/// Why a scan is running.
enum ScanKind {
  /// A repository being ingested for the first time.
  add,

  /// An existing project being re-fetched and re-analyzed.
  reanalyze,
}

enum ScanState { queued, running, done, failed }

/// One repository scan, from the moment someone asks for it to the moment its
/// report lands.
///
/// Mutable and long-lived on purpose: the thing a scan must survive is the
/// screen that started it. Analyzing a repository of any size takes tens of
/// seconds, and the whole point of moving it here is that the person who asked
/// can go somewhere else — add a second project, open a different report, press
/// back — without the work being abandoned or its result thrown away.
class ScanTask {
  ScanTask._({
    required this.id,
    required this.kind,
    required this.label,
    required this.detail,
    required Future<(Project, DepReport)> Function() work,
    required Future<ScanProgress?> Function() readProgress,
    this.projectId,
  })  : _work = work,
        _readProgress = readProgress,
        queuedAt = DateTime.now();

  final String id;
  final ScanKind kind;

  /// What to call this in the panel — the repository name, replaced by the
  /// project's own name once the server has told us what that is.
  String label;

  /// The git URL, shown under the label so two forks of one name are telling
  /// apart.
  final String detail;

  /// Set for a re-analysis; filled in for an add once the project exists.
  String? projectId;

  final Future<(Project, DepReport)> Function() _work;
  final Future<ScanProgress?> Function() _readProgress;

  final DateTime queuedAt;
  DateTime? startedAt;
  DateTime? finishedAt;

  ScanState state = ScanState.queued;
  String? error;
  Project? project;
  DepReport? report;

  /// What the server last said it was doing, or null when it has not been
  /// asked yet or could not say.
  ///
  /// Null is load-bearing: it means "how far along this is cannot be known",
  /// which is a different thing from "no progress", and the panel has to render
  /// the two differently.
  ScanProgress? progress;

  bool get isFinished =>
      state == ScanState.done || state == ScanState.failed;

  /// How much longer this is likely to take, as far as anything measured can
  /// say. Null until there is evidence.
  Duration? get estimatedRemaining => progress?.estimatedRemaining();

  /// How long the scan itself has been going — not counting time spent queued
  /// behind another one, which is not the server being slow.
  Duration get elapsed {
    final start = startedAt;
    if (start == null) return Duration.zero;
    return (finishedAt ?? DateTime.now()).difference(start);
  }
}

/// Runs repository scans in the background and says what they are doing.
///
/// Scans used to be awaited by the widget that started them, which made two
/// things true that should not have been. Adding a project held the form until
/// the analysis came back, so a second repository could not be queued behind
/// the first. And a re-analysis lived on the report screen, so pressing back
/// disposed the only thing waiting on the response — the request carried on to
/// the server, and its report was dropped on the floor.
///
/// Owning the work here fixes both: the future is held by an object that
/// outlives every route, and anything that wants to know watches this.
class ScanQueue extends ChangeNotifier {
  ScanQueue({
    this.maxConcurrent = 2,
    this.successLinger = const Duration(seconds: 12),
    this.pollInterval = const Duration(milliseconds: 1200),
  });

  /// The app-wide queue. Screens enqueue against this; [ScanOverlay] shows it.
  static final ScanQueue instance = ScanQueue();

  /// How many scans run at once.
  ///
  /// More than one, because the complaint this exists to answer is "I have to
  /// wait for one repository before I can add the next". Not many more, because
  /// each one is a git clone plus a few hundred registry lookups on a server
  /// that rate-limits, and eight at once finishes no sooner than two — it just
  /// makes all eight look stuck.
  final int maxConcurrent;

  /// How long a finished scan stays on screen before clearing itself.
  ///
  /// Successes only. A failure is the one outcome the user has to actually read
  /// and decide about, so it stays until dismissed.
  final Duration successLinger;

  /// How often a running scan is asked what it is doing.
  ///
  /// A little over a second: fast enough that the bar moves rather than jumps,
  /// slow enough that watching a five-minute scan costs a couple of hundred
  /// tiny requests rather than thousands.
  final Duration pollInterval;

  final List<ScanTask> _tasks = [];
  final Map<String, Timer> _linger = {};

  /// The progress poll for each running scan, by task id.
  final Map<String, Timer> _polls = {};
  final StreamController<ScanTask> _finished =
      StreamController<ScanTask>.broadcast();

  var _nextId = 0;
  var _completions = 0;

  /// How many scans have succeeded since the app started.
  ///
  /// A number rather than only an event, so a screen can tell it missed
  /// something. A broadcast stream delivers to whoever is listening *at that
  /// moment* and to nobody else: a screen rebuilt between the scan starting and
  /// finishing, or one that had not been built yet, never hears about it and
  /// goes on showing a list that is out of date. Comparing this against the
  /// last value it acted on cannot miss.
  int get completions => _completions;

  /// Every scan the panel should show, oldest first.
  List<ScanTask> get tasks => List.unmodifiable(_tasks);

  Iterable<ScanTask> get _pending => _tasks.where((t) => !t.isFinished);

  /// Scans that have not finished — what the collapsed pill counts.
  int get activeCount => _pending.length;

  bool get isBusy => _pending.isNotEmpty;

  bool get hasFinished => _tasks.any((t) => t.isFinished);

  /// Fires as each scan lands, successfully or not.
  ///
  /// Screens listen rather than poll: the registry reloads its list, and a
  /// report screen showing that project swaps in the new report.
  Stream<ScanTask> get finished => _finished.stream;

  /// Whether [projectId] has a scan queued or running, so a screen can show a
  /// spinner instead of a button that would start a second one.
  bool isScanning(String projectId) =>
      _pending.any((t) => t.projectId == projectId);

  /// Queues a repository to be ingested by git URL.
  ScanTask addProject(ApiClient api, String gitUrl, {String? ref}) {
    // Unique across app runs, not just within one: the server keys progress by
    // this, and two devices — or the same device restarted — must not collide
    // on `scan-0`.
    final scanId = _newScanId();
    final task = ScanTask._(
      id: scanId,
      kind: ScanKind.add,
      label: _repoName(gitUrl),
      detail: ref == null ? gitUrl : '$gitUrl @ $ref',
      work: () => api.addProject(gitUrl, ref: ref, scanId: scanId),
      readProgress: () => api.scanProgress(scanId),
    );
    return _enqueue(task);
  }

  /// Queues a re-analysis of an existing project.
  ///
  /// Returns the scan already in flight when there is one, rather than starting
  /// a second: pressing Re-analyze twice is someone checking whether the first
  /// press registered, not a request for two clones of the same repository.
  ScanTask reanalyze(ApiClient api, Project project) {
    final existing = _firstOrNull(_pending, (t) => t.projectId == project.id);
    if (existing != null) return existing;

    final scanId = _newScanId();
    final task = ScanTask._(
      id: scanId,
      kind: ScanKind.reanalyze,
      label: project.name,
      detail: '${project.gitUrl} @ ${project.ref}',
      projectId: project.id,
      work: () => api.refreshProject(project.id, scanId: scanId),
      readProgress: () => api.scanProgress(scanId),
    );
    return _enqueue(task);
  }

  /// Short, unique, and safe in a URL path — the server takes it as a path
  /// segment and caps its length.
  String _newScanId() =>
      'scan-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}'
      '-${_nextId++}';

  ScanTask _enqueue(ScanTask task) {
    _tasks.add(task);
    notifyListeners();
    _pump();
    return task;
  }

  /// Runs a failed scan again, in place.
  void retry(ScanTask task) {
    if (task.state != ScanState.failed) return;
    _linger.remove(task.id)?.cancel();
    task
      ..state = ScanState.queued
      ..error = null
      ..startedAt = null
      ..finishedAt = null;
    notifyListeners();
    _pump();
  }

  /// Takes a finished scan off the panel. Running ones cannot be dismissed —
  /// hiding a scan would not stop it, and pretending otherwise is worse than
  /// leaving it on screen.
  void dismiss(String id) {
    final task = _firstOrNull(_tasks, (t) => t.id == id);
    if (task == null || !task.isFinished) return;
    _linger.remove(id)?.cancel();
    _tasks.remove(task);
    notifyListeners();
  }

  void clearFinished() {
    for (final task in _tasks.where((t) => t.isFinished).toList()) {
      _linger.remove(task.id)?.cancel();
      _tasks.remove(task);
    }
    notifyListeners();
  }

  /// Starts whatever the concurrency cap has room for.
  void _pump() {
    var running = _tasks.where((t) => t.state == ScanState.running).length;
    for (final task in _tasks) {
      if (running >= maxConcurrent) return;
      if (task.state != ScanState.queued) continue;
      task
        ..state = ScanState.running
        ..startedAt = DateTime.now();
      running++;
      unawaited(_run(task));
    }
  }

  /// Asks the server what [task] is doing, for as long as it is doing it.
  ///
  /// Runs alongside the scan rather than as part of it: the scan is one long
  /// request that says nothing until it is finished, so the only way to learn
  /// what it is doing is to ask on a second connection.
  ///
  /// A cancellable [Timer] rather than a loop around `Future.delayed`, because
  /// a delay cannot be called off — the last one would outlive the scan by up
  /// to [pollInterval], which is both a pointless wakeup and, in a widget test,
  /// a pending timer that fails the case.
  void _startPolling(ScanTask task) {
    _polls[task.id] = Timer.periodic(pollInterval, (_) async {
      if (task.state != ScanState.running) return;
      final progress = await task._readProgress();
      // Ignored when the server cannot say, which is an ordinary outcome
      // rather than a failure: progress is held per-instance and expires, so a
      // poll that finds nothing means "no news", not "no progress". Whatever
      // was last known stays on screen.
      if (progress == null || progress.isFinished) return;
      if (task.state != ScanState.running) return;
      task.progress = progress;
      notifyListeners();
    });
  }

  void _stopPolling(ScanTask task) => _polls.remove(task.id)?.cancel();

  Future<void> _run(ScanTask task) async {
    _startPolling(task);
    try {
      final (project, report) = await task._work();
      task
        ..project = project
        ..report = report
        ..projectId = project.id
        ..label = project.name
        ..state = ScanState.done;
    } on ApiAuthException catch (e) {
      // The session died mid-scan. Recorded as a failure so the panel says so,
      // and reported to the monitor, which asks before taking the screen away.
      task
        ..state = ScanState.failed
        ..error = e.message;
      SessionMonitor.instance.reportExpired(e.message);
    } on ApiException catch (e) {
      task
        ..state = ScanState.failed
        ..error = e.message;
    } catch (e) {
      task
        ..state = ScanState.failed
        ..error = 'The scan failed: $e';
    } finally {
      _stopPolling(task);
      task.finishedAt = DateTime.now();
      if (task.state == ScanState.done) {
        _completions++;
        _lingerThenClear(task);
      }
      if (!_finished.isClosed) _finished.add(task);
      notifyListeners();
      // Whatever was waiting behind this one can go now.
      _pump();
    }
  }

  void _lingerThenClear(ScanTask task) {
    _linger[task.id] = Timer(successLinger, () {
      _linger.remove(task.id);
      // Guard against a retry having put it back to work in the meantime.
      if (task.state != ScanState.done) return;
      _tasks.remove(task);
      notifyListeners();
    });
  }

  @override
  void dispose() {
    for (final timer in [..._linger.values, ..._polls.values]) {
      timer.cancel();
    }
    _linger.clear();
    _polls.clear();
    _finished.close();
    super.dispose();
  }
}

/// The first match, or null. `package:collection` would supply this, and the
/// frontend does not depend on it for two uses.
ScanTask? _firstOrNull(Iterable<ScanTask> tasks, bool Function(ScanTask) test) {
  for (final task in tasks) {
    if (test(task)) return task;
  }
  return null;
}

/// `owner/repo.git` -> `repo`, so a scan has something to be called before the
/// server has told us the project's name.
String _repoName(String gitUrl) {
  final segments = Uri.tryParse(gitUrl)?.pathSegments ?? const <String>[];
  if (segments.isEmpty) return gitUrl;
  return segments.last.replaceAll('.git', '');
}
