import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared/shared.dart';

import '../theme.dart';
import 'scan_queue.dart';

/// The floating panel that says what is being scanned, over whatever screen the
/// user is on.
///
/// Mounted from `MaterialApp.builder` rather than inside a screen, which is the
/// whole point: it sits above the [Navigator], so a scan started on the report
/// screen keeps reporting itself after the user presses back, and one started
/// in the registry keeps reporting itself while they open something else.
///
/// It shows itself only when there is something to say, and never covers the
/// bottom-right corner of an idle screen.
class ScanOverlay extends StatefulWidget {
  const ScanOverlay({required this.child, ScanQueue? queue, super.key})
      : _queue = queue;

  final Widget child;

  /// Defaults to the app-wide queue. Injectable for tests, which should not
  /// share state between cases.
  final ScanQueue? _queue;

  ScanQueue get queue => _queue ?? ScanQueue.instance;

  @override
  State<ScanOverlay> createState() => _ScanOverlayState();
}

class _ScanOverlayState extends State<ScanOverlay> {
  /// Redraws the elapsed times. Runs only while something is scanning — a timer
  /// ticking behind an idle app would rebuild this every second forever.
  Timer? _ticker;

  bool _collapsed = false;

  @override
  void initState() {
    super.initState();
    widget.queue.addListener(_onQueueChanged);
    // A hot reload, or a rebuild of the app above this, can mount the overlay
    // with scans already running. Without this the elapsed times would sit
    // frozen until the next queue event.
    _syncTicker();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    widget.queue.removeListener(_onQueueChanged);
    super.dispose();
  }

  void _onQueueChanged() {
    if (!mounted) return;
    setState(_syncTicker);
  }

  void _syncTicker() {
    final busy = widget.queue.isBusy;
    if (busy && _ticker == null) {
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    } else if (!busy) {
      _ticker?.cancel();
      _ticker = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final tasks = widget.queue.tasks;
    final media = MediaQuery.of(context);
    // Clears whichever is in the way. `padding` is the gesture bar, and goes to
    // zero in immersive mode because there is then nothing to clear; `viewInsets`
    // is the keyboard, which is up at the exact moment this panel first appears
    // — someone has just typed a Git URL and pressed Add.
    final bottomInset = media.padding.bottom > media.viewInsets.bottom
        ? media.padding.bottom
        : media.viewInsets.bottom;

    return Stack(
      children: [
        widget.child,
        if (tasks.isNotEmpty)
          Positioned(
            right: 16,
            bottom: 16 + bottomInset,
            child: _Panel(
              tasks: tasks,
              queue: widget.queue,
              collapsed: _collapsed,
              onToggle: () => setState(() => _collapsed = !_collapsed),
            ),
          ),
      ],
    );
  }
}

/// The panel itself: a pill when collapsed, a list of scans when not.
class _Panel extends StatelessWidget {
  const _Panel({
    required this.tasks,
    required this.queue,
    required this.collapsed,
    required this.onToggle,
  });

  final List<ScanTask> tasks;
  final ScanQueue queue;
  final bool collapsed;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final active = queue.activeCount;
    final failed = tasks.where((t) => t.state == ScanState.failed).length;
    // The longest of the running estimates, since the panel is done when the
    // last one is. Null unless every running scan can be estimated — saying
    // "40s left" while a second scan sits on an unknown would be wrong.
    final left = _longestRemaining(tasks);

    return Material(
      color: Palette.ink,
      elevation: 8,
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: AnimatedSize(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        alignment: Alignment.bottomRight,
        child: ConstrainedBox(
          // Wide enough for a package name and a line of status, narrow enough
          // that it stays a panel rather than becoming the screen. Capped
          // against the viewport so it does not run off a small phone.
          constraints: BoxConstraints(
            maxWidth: collapsed
                ? 260
                : (MediaQuery.sizeOf(context).width - 32).clamp(200.0, 320.0),
          ),
          child: collapsed
              ? _CollapsedPill(
                  active: active,
                  failed: failed,
                  remaining: left,
                  onTap: onToggle,
                )
              : _ExpandedPanel(
                  tasks: tasks,
                  queue: queue,
                  active: active,
                  onCollapse: onToggle,
                ),
        ),
      ),
    );
  }
}

/// The longest time left across the running scans, or null when any of them
/// cannot be estimated.
Duration? _longestRemaining(List<ScanTask> tasks) {
  Duration? longest;
  for (final task in tasks) {
    if (task.state != ScanState.running) continue;
    final left = task.estimatedRemaining;
    if (left == null) return null;
    if (longest == null || left > longest) longest = left;
  }
  return longest;
}

class _CollapsedPill extends StatelessWidget {
  const _CollapsedPill({
    required this.active,
    required this.failed,
    required this.remaining,
    required this.onTap,
  });

  final int active;
  final int failed;
  final Duration? remaining;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 11, 12, 11),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (active > 0)
              const SizedBox(
                width: 15,
                height: 15,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Palette.minorOnInk,
                ),
              )
            else
              Icon(
                failed > 0 ? Icons.error_outline : Icons.check_circle_outline,
                size: 17,
                color: failed > 0 ? Palette.alarmOnInk : Palette.patch,
              ),
            const SizedBox(width: 10),
            Flexible(
              child: Text(
                switch ((active, failed)) {
                  (0, final f) when f > 0 =>
                    f == 1 ? '1 scan failed' : '$f scans failed',
                  (0, _) => 'Scan finished',
                  // The estimate is the reason to leave it collapsed: it is the
                  // one thing someone wants from the corner of their eye.
                  (1, _) when remaining != null =>
                    'Scanning · ~${_TaskRow._rough(remaining!)} left',
                  (1, _) => 'Scanning 1 repository',
                  (final a, _) when remaining != null =>
                    'Scanning $a · ~${_TaskRow._rough(remaining!)} left',
                  (final a, _) => 'Scanning $a repositories',
                },
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: 6),
            const Icon(Icons.expand_less, size: 17, color: Colors.white70),
          ],
        ),
      ),
    );
  }
}

class _ExpandedPanel extends StatelessWidget {
  const _ExpandedPanel({
    required this.tasks,
    required this.queue,
    required this.active,
    required this.onCollapse,
  });

  final List<ScanTask> tasks;
  final ScanQueue queue;
  final int active;
  final VoidCallback onCollapse;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 6, 6),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  active > 0 ? 'Scanning' : 'Scans',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.6,
                  ),
                ),
              ),
              if (queue.hasFinished)
                _IconAction(
                  icon: Icons.clear_all,
                  label: 'Clear finished',
                  onPressed: queue.clearFinished,
                ),
              _IconAction(
                icon: Icons.expand_more,
                label: 'Collapse',
                onPressed: onCollapse,
              ),
            ],
          ),
        ),
        // Five scans is already an unusual number to have going; past that the
        // panel scrolls rather than growing to the height of the window.
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 260),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final task in tasks)
                  _TaskRow(key: ValueKey(task.id), task: task, queue: queue),
              ],
            ),
          ),
        ),
        const SizedBox(height: 6),
      ],
    );
  }
}

/// One scan: what it is, how it is going, and what came of it.
class _TaskRow extends StatelessWidget {
  const _TaskRow({required this.task, required this.queue, super.key});

  final ScanTask task;
  final ScanQueue queue;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 6, 8, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: _StateIcon(state: task.state),
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      task.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 1),
                    Text(
                      _status(task),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontSize: 11,
                        color: task.state == ScanState.failed
                            ? Palette.alarmOnInk
                            : Colors.white.withValues(alpha: 0.66),
                      ),
                    ),
                  ],
                ),
              ),
              if (task.state == ScanState.failed)
                _IconAction(
                  icon: Icons.refresh,
                  label: 'Try again',
                  onPressed: () => queue.retry(task),
                ),
              if (task.isFinished)
                _IconAction(
                  icon: Icons.close,
                  label: 'Dismiss',
                  onPressed: () => queue.dismiss(task.id),
                ),
            ],
          ),
          if (task.state == ScanState.running) ...[
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(2),
              // Determinate once the server has counted something, and
              // indeterminate until then — because until the manifests have
              // been read there is genuinely no denominator, and a bar that
              // starts at 0% would be claiming to know that.
              child: LinearProgressIndicator(
                value: task.progress?.fraction,
                minHeight: 3,
                backgroundColor: Colors.white.withValues(alpha: 0.12),
                valueColor:
                    const AlwaysStoppedAnimation<Color>(Palette.minorOnInk),
              ),
            ),
          ],
        ],
      ),
    );
  }

  static String _status(ScanTask task) {
    final what = task.kind == ScanKind.add ? 'Adding' : 'Re-analyzing';
    return switch (task.state) {
      ScanState.queued => 'Queued — $what next',
      ScanState.running => _running(task, what),
      ScanState.failed => task.error ?? 'The scan failed.',
      ScanState.done => _summary(task),
    };
  }

  /// What a running scan is doing, in as much detail as the server has given.
  ///
  /// Degrades in one direction only, and never invents the missing half: with
  /// counts and a rate it reads `412 of 1444 · ~2m left`; with counts alone,
  /// `412 of 1444 packages`; with neither, the phase and how long it has been
  /// going. A scan whose progress cannot be read at all — an older server, or
  /// one behind a load balancer — lands on that last form and is still useful.
  static String _running(ScanTask task, String what) {
    final progress = task.progress;
    if (progress == null) return '$what · ${_duration(task.elapsed)}';

    final phase = switch (progress.phase) {
      ScanPhase.queued => 'Starting',
      ScanPhase.fetching => 'Fetching the repository',
      ScanPhase.resolving => 'Resolving versions',
      ScanPhase.saving => 'Saving the report',
      ScanPhase.analyzing || ScanPhase.done || ScanPhase.failed => null,
    };
    if (phase != null) return '$phase · ${_duration(task.elapsed)}';

    final total = progress.projectedPackages;
    if (total == null) return '$what · ${_duration(task.elapsed)}';

    final counted = '${progress.packagesDone} of $total packages';
    final left = task.estimatedRemaining;
    // Tilde and not a countdown: this is an extrapolation from the rate so
    // far, and rounding it to the nearest five seconds stops the last digit
    // flickering with every poll and inviting more trust than it deserves.
    return left == null ? counted : '$counted · ~${_rough(left)} left';
  }

  /// A duration rounded to something worth reading aloud.
  static String _rough(Duration left) {
    if (left.inSeconds < 10) return 'a few seconds';
    if (left.inSeconds < 60) return '${(left.inSeconds / 5).round() * 5}s';
    if (left.inMinutes < 10) {
      final minutes = left.inMinutes;
      final seconds = (left.inSeconds % 60 / 15).round() * 15;
      return seconds == 0 || seconds == 60
          ? '${minutes + (seconds == 60 ? 1 : 0)}m'
          : '${minutes}m ${seconds}s';
    }
    return '${left.inMinutes}m';
  }

  static String _summary(ScanTask task) {
    final report = task.report;
    if (report == null) return 'Done';
    final parts = <String>['${report.total} dependencies'];
    if (report.vulnerable > 0) parts.add('${report.vulnerable} vulnerable');
    return '${parts.join(' · ')} · ${_duration(task.elapsed)}';
  }

  static String _duration(Duration d) {
    final seconds = d.inSeconds;
    if (seconds < 60) return '${seconds}s';
    return '${d.inMinutes}m ${(seconds % 60).toString().padLeft(2, '0')}s';
  }
}

class _StateIcon extends StatelessWidget {
  const _StateIcon({required this.state});

  final ScanState state;

  @override
  Widget build(BuildContext context) {
    return switch (state) {
      ScanState.running => const SizedBox(
          width: 13,
          height: 13,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: Palette.minorOnInk,
          ),
        ),
      ScanState.queued => const SizedBox(
          width: 13,
          height: 13,
          child: Icon(Icons.schedule, size: 13, color: Colors.white54),
        ),
      ScanState.done => const SizedBox(
          width: 13,
          height: 13,
          child: Icon(Icons.check_circle, size: 13, color: Palette.patch),
        ),
      ScanState.failed => const SizedBox(
          width: 13,
          height: 13,
          child: Icon(Icons.error, size: 13, color: Palette.alarmOnInk),
        ),
    };
  }
}

/// A small chrome button sized for a panel this dense — [IconButton]'s default
/// 48px target would be taller than the row it sits in.
///
/// Labelled through [Semantics] rather than [Tooltip]. A tooltip floats itself
/// into the nearest [Overlay], and this panel deliberately has none above it:
/// it is mounted beside the [Navigator] so that it survives route changes, and
/// the Overlay lives *inside* that navigator. A tooltip here throws on build.
class _IconAction extends StatelessWidget {
  const _IconAction({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: label,
      button: true,
      child: InkResponse(
        onTap: onPressed,
        radius: 18,
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Icon(icon, size: 16, color: Colors.white70),
        ),
      ),
    );
  }
}
