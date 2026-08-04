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
///
/// It survives more than that now. The scan runs on the server as a job of its
/// own, so this object is a *view* of work that continues whether or not the
/// app is open at all: close the tab and the report still lands, and the next
/// client to sign in re-attaches to whatever is still going.
class ScanTask {
  ScanTask._({
    required this.id,
    required this.kind,
    required this.label,
    required this.detail,
    required Future<ScanStatus> Function() submit,
    required Future<ScanStatus?> Function() readStatus,
    required Future<({Project project, DepReport? report})> Function(String)
        readResult,
    this.projectId,
  })  : _submit = submit,
        _readStatus = readStatus,
        _readResult = readResult,
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

  /// Writes the scan down on the server. Returns as soon as it is recorded —
  /// the work itself starts there and does not need anybody here.
  final Future<ScanStatus> Function() _submit;

  final Future<ScanStatus?> Function() _readStatus;
  final Future<({Project project, DepReport? report})> Function(String)
      _readResult;

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

  /// Whether this task is watching a scan somebody else started — another
  /// device, or this one before it was closed.
  bool attached = false;

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

/// Watches the repository scans this account has running, and says what they
/// are doing.
///
/// Scans used to be awaited by the widget that started them, which made two
/// things true that should not have been. Adding a project held the form until
/// the analysis came back, so a second repository could not be queued behind
/// the first. And a re-analysis lived on the report screen, so pressing back
/// disposed the only thing waiting on the response — the request carried on to
/// the server, and its report was dropped on the floor.
///
/// Owning the work here fixed both. What this no longer owns is the work
/// itself: a scan is a row on the server, run by the server, and this holds a
/// view of it. Closing the app stops the watching and nothing else.
class ScanQueue extends ChangeNotifier {
  ScanQueue({
    this.successLinger = const Duration(seconds: 12),
    this.pollInterval = const Duration(milliseconds: 1200),
    this.pollBackoffLimit = const Duration(seconds: 15),
    this.pollGiveUpAfter = const Duration(minutes: 2),
  });

  /// The app-wide queue. Screens enqueue against this; [ScanOverlay] shows it.
  static final ScanQueue instance = ScanQueue();

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

  /// The slowest a poll gets while the server has nothing to say.
  ///
  /// A ceiling rather than unbounded doubling: a scan whose status is
  /// unreadable for a minute may well become readable again — the network comes
  /// back, or the machine finishes starting — and an interval that had grown to
  /// several minutes would catch up long after it mattered.
  final Duration pollBackoffLimit;

  /// How long the server may say nothing before this stops asking.
  ///
  /// Measured in time rather than in a count of replies, because [pollInterval]
  /// is not the gap between them once the backoff above starts stretching it,
  /// and the question worth answering is "how long has this been silent", not
  /// "how many times have we asked".
  ///
  /// Giving up abandons the *watching*, never the scan. The scan is a job on
  /// the server and finishes there; what is lost is this client's view of it,
  /// which the next [reattach] gets back.
  final Duration pollGiveUpAfter;

  final List<ScanTask> _tasks = [];
  final Map<String, Timer> _linger = {};

  /// The status poll for each running scan, by task id.
  final Map<String, Timer> _polls = {};

  /// What each running scan's watcher will complete with.
  final Map<String, Completer<ScanStatus?>> _watches = {};

  final StreamController<ScanTask> _finished =
      StreamController<ScanTask>.broadcast();

  var _nextId = 0;
  var _completions = 0;

  /// Whether this has been disposed while a scan was still being watched.
  ///
  /// Reachable in a way it was not before. Work used to end when the request
  /// holding it ended, so disposing the queue ended everything with it. A scan
  /// is a job on the server now, and [_run] goes on tidying up after a screen —
  /// or a test — has thrown the queue away. Notifying a disposed
  /// [ChangeNotifier] throws, and it would throw from somewhere with nothing to
  /// do with the mistake.
  var _disposed = false;

  void _notify() {
    if (_disposed) return;
    notifyListeners();
  }

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
    // Unique across app runs, not just within one: the server keys the *job* by
    // this, and two devices — or the same device restarted — must not collide
    // on `scan-0`.
    final scanId = _newScanId();
    return _enqueue(
      ScanTask._(
        id: scanId,
        kind: ScanKind.add,
        label: _repoName(gitUrl),
        detail: ref == null ? gitUrl : '$gitUrl @ $ref',
        submit: () => api.addProject(gitUrl, ref: ref, scanId: scanId),
        readStatus: () => api.scanStatus(scanId),
        readResult: api.projectWithReport,
      ),
    );
  }

  /// Queues a re-analysis of an existing project.
  ///
  /// Returns the scan already in flight when there is one, rather than starting
  /// a second: pressing Re-analyze twice is someone checking whether the first
  /// press registered, not a request for two clones of the same repository.
  /// The server applies the same rule, because the first press can have come
  /// from a different device.
  ScanTask reanalyze(ApiClient api, Project project) {
    final existing = _firstOrNull(_pending, (t) => t.projectId == project.id);
    if (existing != null) return existing;

    final scanId = _newScanId();
    return _enqueue(
      ScanTask._(
        id: scanId,
        kind: ScanKind.reanalyze,
        label: project.name,
        detail: '${project.gitUrl} @ ${project.ref}',
        projectId: project.id,
        submit: () => api.refreshProject(project.id, scanId: scanId),
        readStatus: () => api.scanStatus(scanId),
        readResult: api.projectWithReport,
      ),
    );
  }

  /// Picks up the scans this account already has running on the server.
  ///
  /// Called when the app opens. Without it a durable scan is invisible: the
  /// work carried on while nobody was looking, and a client that shows an empty
  /// panel invites the person to start the same scan over again.
  ///
  /// Failure is silence. This runs on launch, and an account with nothing
  /// running — which is nearly always — must not be shown an error because the
  /// network was briefly away.
  Future<void> reattach(ApiClient api) async {
    final List<ScanStatus> running;
    try {
      running = await api.activeScans();
    } catch (_) {
      return;
    }
    if (_disposed) return;

    for (final status in running) {
      if (_tasks.any((t) => t.id == status.scanId)) continue;
      _enqueue(_taskFor(api, status)..attached = true);
    }
  }

  ScanTask _taskFor(ApiClient api, ScanStatus status) {
    final gitUrl = status.gitUrl;
    return ScanTask._(
      id: status.scanId,
      // Told apart by whether the job knew its project from the start, which is
      // exactly the difference between the two.
      kind: status.projectId == null ? ScanKind.add : ScanKind.reanalyze,
      label: gitUrl == null ? 'Scan in progress' : _repoName(gitUrl),
      detail: gitUrl ?? 'started elsewhere',
      projectId: status.projectId,
      // Already submitted — by another device, or by this one before it was
      // closed. Handing back what the server just said keeps [_run] one path
      // instead of two.
      submit: () async => status,
      readStatus: () => api.scanStatus(status.scanId),
      readResult: api.projectWithReport,
    );
  }

  /// Short, unique, and safe in a URL path — the server takes it as a path
  /// segment, caps its length, and now stores it as a primary key.
  String _newScanId() =>
      'scan-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}'
      '-${_nextId++}';

  ScanTask _enqueue(ScanTask task) {
    _tasks.add(task);
    _notify();
    unawaited(_run(task));
    return task;
  }

  /// Runs a failed scan again, in place.
  ///
  /// For a scan this client lost contact with rather than one that failed, this
  /// re-attaches rather than re-running: the id is the same, and the server
  /// answers a repeat submission with the job it already has.
  void retry(ScanTask task) {
    if (task.state != ScanState.failed) return;
    _linger.remove(task.id)?.cancel();
    task
      ..state = ScanState.queued
      ..error = null
      ..startedAt = null
      ..finishedAt = null;
    _notify();
    unawaited(_run(task));
  }

  /// Takes a finished scan off the panel. Running ones cannot be dismissed —
  /// hiding a scan would not stop it, and pretending otherwise is worse than
  /// leaving it on screen.
  void dismiss(String id) {
    final task = _firstOrNull(_tasks, (t) => t.id == id);
    if (task == null || !task.isFinished) return;
    _linger.remove(id)?.cancel();
    _tasks.remove(task);
    _notify();
  }

  void clearFinished() {
    for (final task in _tasks.where((t) => t.isFinished).toList()) {
      _linger.remove(task.id)?.cancel();
      _tasks.remove(task);
    }
    _notify();
  }

  /// Submits the scan, watches it to the end, and collects what it produced.
  ///
  /// Three steps where there used to be one long request. Only the first is
  /// this client's to lose: once the submit returns, the scan exists on the
  /// server and finishing it is no longer conditional on anything here.
  Future<void> _run(ScanTask task) async {
    try {
      final queued = await task._submit();
      if (_disposed) return;
      task
        ..state = ScanState.running
        ..startedAt = DateTime.now();
      _absorb(task, queued);

      final finished = await _watch(task);
      if (_disposed) return;

      if (finished == null) {
        // Silence for two minutes. The scan is a job on the server and is very
        // likely still running, so the message must not claim otherwise —
        // "failed" here is a statement about this client's view of it.
        task
          ..state = ScanState.failed
          ..error = 'Lost contact with this scan. It is still running on the '
              'server — reopen the app to pick it up.';
        return;
      }

      if (finished.state == ScanJobState.failed) {
        task
          ..state = ScanState.failed
          ..error = finished.error ?? 'The scan failed.';
        return;
      }

      final projectId = finished.projectId;
      if (projectId == null) {
        task
          ..state = ScanState.failed
          ..error = 'The scan finished without saying what it produced.';
        return;
      }

      final result = await task._readResult(projectId);
      task
        ..project = result.project
        ..report = result.report
        ..projectId = result.project.id
        ..label = result.project.name
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
      _stopWatching(task);
      if (!_disposed) {
        task.finishedAt = DateTime.now();
        if (task.state == ScanState.done) {
          _completions++;
          _lingerThenClear(task);
        }
        if (!_finished.isClosed) _finished.add(task);
        _notify();
      }
    }
  }

  /// Asks the server what [task] is doing, for as long as it is doing it, and
  /// completes with the status that ended it — or null if this gave up asking.
  ///
  /// A cancellable [Timer] rather than a loop around `Future.delayed`, because
  /// a delay cannot be called off — the last one would outlive the scan by up
  /// to [pollInterval], which is both a pointless wakeup and, in a widget test,
  /// a pending timer that fails the case.
  ///
  /// One-shot and rescheduled rather than [Timer.periodic], because the gap
  /// between polls is not a constant: a server that keeps answering is asked
  /// every [pollInterval], and one that has stopped answering is asked less and
  /// less often until [pollGiveUpAfter] says to stop. A flat interval against a
  /// scan that cannot be read is fifty requests a minute for as long as the tab
  /// stays open, none of which will say anything different.
  Future<ScanStatus?> _watch(ScanTask task) {
    final watch = _watches[task.id] = Completer<ScanStatus?>();
    var delay = pollInterval;
    DateTime? silentSince;

    void finish(ScanStatus? status) {
      _polls.remove(task.id)?.cancel();
      _watches.remove(task.id);
      if (!watch.isCompleted) watch.complete(status);
    }

    void schedule() {
      _polls[task.id] = Timer(delay, () async {
        if (task.state != ScanState.running) return finish(null);
        final status = await task._readStatus();
        if (task.state != ScanState.running) return finish(null);

        // Nothing to report. A scan this account never asked for reads the
        // same as a poll that could not reach the server at all, and neither
        // says anything about the scan — so both wait rather than concluding.
        // Whatever was last known stays on screen.
        if (status == null) {
          final now = DateTime.now();
          silentSince ??= now;
          if (now.difference(silentSince!) >= pollGiveUpAfter) {
            return finish(null);
          }
          delay = _backOff(delay);
          schedule();
          return;
        }

        // Answered, so the clock starts again from here rather than from the
        // start of the scan — a scan that goes quiet, recovers, and goes quiet
        // again has not been silent throughout.
        silentSince = null;
        delay = pollInterval;
        if (status.isFinished) return finish(status);
        _absorb(task, status);
        schedule();
      });
    }

    schedule();
    return watch.future;
  }

  void _stopWatching(ScanTask task) {
    _polls.remove(task.id)?.cancel();
    final watch = _watches.remove(task.id);
    if (watch != null && !watch.isCompleted) watch.complete(null);
  }

  /// Takes what the server just said into the task.
  void _absorb(ScanTask task, ScanStatus status) {
    task.progress = status.progress;
    task.projectId ??= status.projectId;
    _notify();
  }

  /// The next gap after a poll that said nothing: double it, up to
  /// [pollBackoffLimit].
  Duration _backOff(Duration delay) {
    final next = delay * 2;
    return next > pollBackoffLimit ? pollBackoffLimit : next;
  }

  void _lingerThenClear(ScanTask task) {
    _linger[task.id] = Timer(successLinger, () {
      _linger.remove(task.id);
      // Guard against a retry having put it back to work in the meantime.
      if (task.state != ScanState.done) return;
      _tasks.remove(task);
      _notify();
    });
  }

  @override
  void dispose() {
    _disposed = true;
    for (final timer in [..._linger.values, ..._polls.values]) {
      timer.cancel();
    }
    for (final watch in _watches.values) {
      if (!watch.isCompleted) watch.complete(null);
    }
    _linger.clear();
    _polls.clear();
    _watches.clear();
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
