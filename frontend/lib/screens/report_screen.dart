import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared/shared.dart';

import '../api/api_client.dart';
import '../auth/session_monitor.dart';
import '../export/file_download.dart';
import '../export/report_export.dart';
import '../main.dart' show routerOf;
import '../platform/breakpoints.dart';
import '../routing/app_route.dart';
import '../scans/scan_queue.dart';
import '../theme.dart';
import '../widgets/chrome.dart';
import '../widgets/dep_status_chip.dart';
import '../widgets/dep_table.dart';
import '../widgets/dependency_path.dart';
import '../widgets/dependency_spectrum.dart';
import '../widgets/dependency_tree.dart';
import '../widgets/license_panel.dart';
import '../widgets/remediation_panel.dart';
import '../widgets/severity_chip.dart';

/// The dependency report for one project: a summary, a sortable table, and the
/// dependency graph.
class ReportScreen extends StatefulWidget {
  const ReportScreen({
    required this.project,
    required this.api,
    this.tab = ReportTab.packages,
    this.scans,
    super.key,
  });

  final Project project;
  final ApiClient api;

  /// Which panel is open. Comes from the URL, so a link can name one.
  final ReportTab tab;

  /// Where re-analysis runs. Defaults to the app-wide queue; injectable so a
  /// test can drive one without the singleton leaking between cases.
  final ScanQueue? scans;

  @override
  State<ReportScreen> createState() => _ReportScreenState();
}

class _ReportScreenState extends State<ReportScreen> {
  late Future<DepReport?> _report;
  late Project _project;

  ScanQueue get _scans => widget.scans ?? ScanQueue.instance;
  StreamSubscription<ScanTask>? _scanResults;

  @override
  void initState() {
    super.initState();
    _project = widget.project;
    _report = widget.api.report(_project.id);
    _scans.addListener(_onScansChanged);
    // Picks up a re-analysis of this project whoever started it and wherever
    // they were standing — including one they started here, left, and came
    // back to.
    _scanResults = _scans.finished.listen(_onScanFinished);
  }

  @override
  void dispose() {
    _scanResults?.cancel();
    _scans.removeListener(_onScansChanged);
    super.dispose();
  }

  /// Keeps the app bar in step with the queue, so the button is a spinner for
  /// exactly as long as this project is being scanned.
  void _onScansChanged() {
    if (mounted) setState(() {});
  }

  void _onScanFinished(ScanTask task) {
    if (!mounted || task.projectId != _project.id) return;

    final project = task.project;
    final report = task.report;
    if (task.state == ScanState.done && project != null && report != null) {
      setState(() {
        _project = project;
        _report = Future.value(report);
      });
    }
    // Failures are not announced here. The panel is already showing this scan,
    // it carries the reason and a retry, and it is on screen whether or not the
    // user is still standing on the report that started it — so repeating it in
    // a snack bar would only be the half of the story that happens to be here.
  }

  void _reload() {
    // Assigned outside the callback: `setState(() => x = future)` hands the
    // future back as the callback's return value, which Flutter asserts on.
    // "Try again" threw here instead of re-reading the report.
    final report = widget.api.report(_project.id);
    setState(() {
      _report = report;
    });
  }

  /// Queues a re-fetch and re-analysis of the repository.
  ///
  /// Handing it to the queue rather than awaiting it here is what stops
  /// pressing back from throwing the scan away: the request used to be owned by
  /// this state object, so disposing it left the server working on a report
  /// nothing would ever read.
  void _reanalyze() => _scans.reanalyze(widget.api, _project);

  /// Writes the report out as a file.
  ///
  /// CSV for a spreadsheet, JSON for a script. Failures are announced rather
  /// than swallowed: a download that does nothing looks identical to a browser
  /// that saved it somewhere unexpected, and the two want different responses.
  Future<void> _export(DepReport report, {required bool asCsv}) async {
    try {
      await downloadText(
        ReportExport.filename(
          _project,
          report,
          extension: asCsv ? 'csv' : 'json',
        ),
        asCsv ? ReportExport.toCsv(report) : ReportExport.toJson(report),
        mimeType: asCsv ? 'text/csv' : 'application/json',
      );
    } on Object catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text('Could not export: $error')));
    }
  }

  /// Shows how a package ends up in the project.
  ///
  /// A bottom sheet on a phone and a side panel on a desktop, which is a real
  /// difference rather than a stylistic one. A sheet rising from the bottom of
  /// a 1440-pixel-tall window either covers the table it is explaining or
  /// leaves most of itself empty, and the reader loses the row they clicked.
  /// A panel down the side keeps both on screen, which is the whole reason to
  /// have the width.
  void _explain(DepNode node, DepReport report) {
    final detail = PackageDetailView(
      package: node.name,
      nodes: report.nodes,
      selected: node,
      showCurrency: !_project.isArchived,
      // No loader for an archived project: the sheet then explains why the
      // package is present without asking what upgrading it would involve.
      onLoadDetails: _project.isArchived
          ? null
          : () => widget.api.upgradeDetails(_project.id, node.name),
    );

    if (Layout.of(context) == Layout.expanded) {
      showGeneralDialog<void>(
        context: context,
        barrierDismissible: true,
        barrierLabel: 'Close ${node.name}',
        barrierColor: Colors.black54,
        transitionDuration: const Duration(milliseconds: 180),
        pageBuilder: (_, __, ___) => _SidePanel(child: detail),
        transitionBuilder: (_, animation, __, child) => SlideTransition(
          position: Tween(
            begin: const Offset(1, 0),
            end: Offset.zero,
          ).animate(
            CurvedAnimation(parent: animation, curve: Curves.easeOutCubic),
          ),
          child: child,
        ),
      );
      return;
    }

    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => SingleChildScrollView(child: detail),
    );
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<DepReport?>(
      future: _report,
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snap.hasError) {
          if (snap.error case final ApiAuthException auth) {
            WidgetsBinding.instance.addPostFrameCallback(
              (_) => SessionMonitor.instance.reportExpired(auth.message),
            );
          }
          return _Message(
            icon: Icons.error_outline,
            text: snap.error is ApiException
                ? (snap.error! as ApiException).message
                : 'Could not load the report.',
            isError: true,
            onRetry: _reload,
          );
        }

        final report = snap.data;
        if (report == null || report.nodes.isEmpty) {
          return const _Message(
            icon: Icons.inbox_outlined,
            text: 'No dependency report for this project yet.',
          );
        }

        // Header, tabs, panel — the shape of a page rather than of a phone
        // screen. What used to be one column three thousand pixels tall is now
        // four peer views of the same report, and only the panel scrolls: the
        // summary a reader is checking against no longer scrolls away from the
        // table they are checking it with.
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Summary(
              project: _project,
              report: report,
              actions: _actions(report),
            ),
            _ReportTabs(
              current: widget.tab,
              advisories: report.vulnerable,
              onSelect: (tab) => routerOf(context).showTab(tab),
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
                child: BoundedWidth(max: 1280, child: _panel(report)),
              ),
            ),
          ],
        );
      },
    );
  }

  /// What the header offers: re-analysis, and the export.
  List<Widget> _actions(DepReport report) => [
        // An archived project is a snapshot; the server refuses to re-analyze
        // it, so offering the button would be a dead end.
        if (!_project.isArchived)
          if (_scans.isScanning(_project.id))
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 12),
              child: SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else
            TextButton.icon(
              onPressed: _reanalyze,
              style: TextButton.styleFrom(foregroundColor: Colors.white),
              icon: const Icon(Icons.sync, size: 16),
              label: const Text('Re-analyze'),
            ),
        // An archived project exports too: a snapshot is a thing people want to
        // take away precisely because it will not change.
        if (canDownload)
          PopupMenuButton<String>(
            icon: const Icon(
              Icons.download_outlined,
              color: Colors.white,
              size: 18,
            ),
            tooltip: 'Export',
            onSelected: (choice) => _export(report, asCsv: choice == 'csv'),
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'csv', child: Text('Download CSV')),
              PopupMenuItem(value: 'json', child: Text('Download JSON')),
            ],
          ),
      ];

  /// The open panel.
  Widget _panel(DepReport report) => switch (widget.tab) {
        ReportTab.packages => _PanelCard(
            title: 'Every package',
            note: _project.isArchived
                ? 'Select a package to see why it is here.'
                : 'Select a package to see why it is here and what upgrading '
                    'it involves.',
            child: DepTable(
              nodes: report.nodes,
              showCurrency: !_project.isArchived,
              onSelect: (node) => _explain(node, report),
            ),
          ),
        // Advisories are facts about the versions in the snapshot, so they stay
        // for an archived project. Planning a fix is not — it re-fetches the
        // repository, which archiving opted out of.
        ReportTab.advisories => report.vulnerable == 0
            ? const _Message(
                icon: Icons.verified_outlined,
                text: 'No advisory applies to any installed version.',
              )
            : _Advisories(
                report: report,
                onLoadRemediation: _project.isArchived
                    ? null
                    : () => widget.api.remediation(_project.id),
              ),
        ReportTab.licenses => LicensePanel(
            key: ValueKey('licenses-${_project.id}'),
            load: () => widget.api.licenseReport(_project.id),
            onLoadManifest: () => widget.api.licenseManifest(_project.id),
            onSavePolicy: widget.api.saveLicensePolicy,
            onResetPolicy: widget.api.resetLicensePolicy,
          ),
        ReportTab.tree => _PanelCard(
            title: 'The tree',
            child: DependencyTree(
              report: report,
              showCurrency: !_project.isArchived,
              onSelect: (node) => _explain(node, report),
            ),
          ),
      };
}

/// The row of panel names under the summary.
///
/// Tabs rather than four stacked sections: they are peers, a reader wants one
/// at a time, and the URL carries which — so "the advisories on widget-factory"
/// is a link somebody can paste into a ticket.
class _ReportTabs extends StatelessWidget {
  const _ReportTabs({
    required this.current,
    required this.advisories,
    required this.onSelect,
  });

  final ReportTab current;

  /// How many packages carry an advisory, for the count on that tab.
  final int advisories;
  final void Function(ReportTab tab) onSelect;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Palette.paper,
        border: Border(
          bottom: BorderSide(color: Color(0x1A151B2E), width: 0.5),
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 20),
      // Scrollable, so the narrow layout keeps tabs rather than reverting to a
      // long column. Four short words fit a phone; scrolling is the escape
      // hatch rather than the normal case.
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (final tab in ReportTab.values)
              _TabButton(
                label: tab.label,
                selected: tab == current,
                badge: tab == ReportTab.advisories && advisories > 0
                    ? advisories
                    : null,
                onTap: () => onSelect(tab),
              ),
          ],
        ),
      ),
    );
  }
}

class _TabButton extends StatefulWidget {
  const _TabButton({
    required this.label,
    required this.selected,
    required this.onTap,
    this.badge,
  });

  final String label;
  final bool selected;
  final int? badge;
  final VoidCallback onTap;

  @override
  State<_TabButton> createState() => _TabButtonState();
}

class _TabButtonState extends State<_TabButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          padding: const EdgeInsets.only(top: 12),
          margin: const EdgeInsets.only(right: 18),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                width: 2,
                color: widget.selected
                    ? Palette.ink
                    : _hovered
                        ? Palette.slate.withValues(alpha: 0.4)
                        : Colors.transparent,
              ),
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.only(bottom: 9),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  widget.label,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: widget.selected ? Palette.ink : Palette.slate,
                    fontWeight:
                        widget.selected ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
                if (widget.badge case final count?) ...[
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 1,
                    ),
                    decoration: BoxDecoration(
                      color: Palette.major,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      '$count',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A titled card around one panel's content.
class _PanelCard extends StatelessWidget {
  const _PanelCard({required this.title, required this.child, this.note});

  final String title;
  final String? note;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Eyebrow(title),
            if (note case final text?) ...[
              const SizedBox(height: 5),
              Text(text, style: Theme.of(context).textTheme.bodySmall),
            ],
            const SizedBox(height: 8),
            child,
          ],
        ),
      ),
    );
  }
}

class _Summary extends StatelessWidget {
  const _Summary({
    required this.project,
    required this.report,
    this.actions = const [],
  });

  final Project project;
  final DepReport report;

  /// Re-analyze and export. They sit on this band rather than in the header:
  /// the header belongs to the app and these belong to the project on screen,
  /// and putting them there would leave the header changing its mind about what
  /// it is every time somebody opened a report.
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final unknown =
        report.nodes.where((n) => n.status == DepStatus.unknown).length;
    final inferred =
        report.nodes.where((n) => n.source == DepSource.constraint).length;
    // Both empty when the scan never read any source, which is the right
    // silence: a report that could not look must not imply it looked and found
    // nothing.
    final undeclared = report.undeclaredImports;
    final unimported = report.unimportedDeclarations;

    // What the tree weighs, and what dropping the unused part of it would give
    // back. Both are empty on a report from before size scanning, and on one
    // whose registries published no sizes — which reads as no figure at all
    // rather than as a zero.
    final graph = DependencyGraph.of(report);
    final weight = graph.weight;
    final reclaimable = unimported.isEmpty
        ? SizeTally.empty
        : graph.reclaimableFrom([for (final n in unimported) n.name]);

    return InkBand(
      // Tighter than it was. The band sits below a header that already carries
      // the product's name, so it no longer has to be a screen's whole title
      // block — and every pixel it gives back is one the table gets.
      padding: const EdgeInsets.fromLTRB(20, 14, 12, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // The project's name, which used to be the app bar's title. It moves
          // here with the actions, so the band names what it describes rather
          // than relying on chrome that is now shared with every other screen.
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Text(
                  project.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: display(
                    theme.textTheme.titleLarge,
                    color: Colors.white,
                  ),
                ),
              ),
              ...actions,
            ],
          ),
          const SizedBox(height: 2),
          Text(
            '${project.gitUrl} @ ${project.ref}',
            style: mono(
              theme.textTheme.bodySmall,
              color: Colors.white.withValues(alpha: 0.62),
            ),
          ),
          const SizedBox(height: 2),
          Text(
            project.isArchived
                ? 'Archived ${_ago(project.archivedAt!)} — a snapshot of what '
                    'this depended on, not kept up to date.'
                : project.lastCheckedAt != null
                    ? 'Last analyzed ${_ago(project.lastCheckedAt!)}'
                    : 'Analyzed when added',
            style: theme.textTheme.bodySmall?.copyWith(
              color: project.isArchived
                  ? const Color(0xFFFFD48A)
                  : Colors.white.withValues(alpha: 0.62),
              fontWeight: project.isArchived ? FontWeight.w600 : null,
            ),
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 26,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _Stat(label: 'dependencies', value: report.total),
              // "Outdated" is a comparison against pub.dev as it is now, which
              // is what archiving stepped away from. Advisories are facts about
              // the snapshot, so they stay.
              if (!project.isArchived)
                _Stat(
                  label: 'outdated',
                  value: report.outdated,
                  color: report.outdated > 0 ? Palette.minorOnInk : null,
                ),
              _Stat(
                label: 'vulnerable',
                value: report.vulnerable,
                color: report.vulnerable > 0 ? Palette.alarmOnInk : null,
              ),
              if (unknown > 0 && !project.isArchived)
                _Stat(label: 'unknown', value: unknown),
              // Install weight, not bundle weight, labelled with the scale it
              // was measured on. Shown as a stat only where the repository is
              // one ecosystem and there is therefore one scale; where it holds
              // both, the two figures do not belong side by side pretending to
              // be one number, and the note below carries them instead.
              if (weight.bases.length == 1)
                _Stat.text(
                  figure: PackageSize.formatBytes(
                    weight.bytesOn(weight.bases.single),
                  ),
                  label: weight.bases.single.label,
                ),
            ],
          ),
          const SizedBox(height: 18),
          // The tree itself, one mark per package. The counts above say how
          // many; this says out of how many, and what the rest are.
          DependencySpectrum(
            nodes: report.nodes,
            showCurrency: !project.isArchived,
          ),
          if (report.manifests.length > 1) ...[
            const SizedBox(height: 14),
            _Note(
              icon: Icons.folder_copy_outlined,
              // The count is of distinct name+version pairs, so a package
              // resolved at two versions is genuinely two of them.
              text: 'Covers ${report.manifests.length} pubspecs in this '
                  'repository (${report.manifests.join(', ')}). A package '
                  'resolved at two versions is counted once per version.',
            ),
          ],
          if (report.coverageNote != null) ...[
            const SizedBox(height: 10),
            _Note(
              icon: Icons.warning_amber_outlined,
              text: report.coverageNote!,
              isWarning: true,
            ),
          ],
          if (inferred > 0) ...[
            const SizedBox(height: 10),
            _Note(
              icon: Icons.info_outline,
              text: 'This repository has no pubspec.lock, so versions were '
                  'inferred by resolving its constraints — what a fresh '
                  'pub get would install today.',
            ),
          ],
          // The build that breaks for a reason nothing in the pubspec predicts,
          // so it is a warning rather than a remark.
          if (undeclared.isNotEmpty) ...[
            const SizedBox(height: 10),
            _Note(
              icon: Icons.link_off,
              isWarning: true,
              text: '${_count(undeclared.length, 'package')} imported without '
                  'being declared: ${_names(undeclared)}. These resolve only '
                  'while another dependency keeps pulling them in — declare '
                  'them to stop that being luck.',
            ),
          ],
          if (unimported.isNotEmpty) ...[
            const SizedBox(height: 10),
            _Note(
              icon: Icons.delete_sweep_outlined,
              // Deliberately not "no Dart source": this report covers npm too,
              // and naming the wrong language is how a true finding gets read
              // as a bug in the scanner.
              text:
                  'Nothing in this repository imports ${_names(unimported)} — '
                  '${_count(unimported.length, 'declared dependency', plural: 'declared dependencies')} '
                  'to consider dropping. Build tooling and lint sets are '
                  'already excluded.'
                  '${_reclaimNote(reclaimable, unimported.length)}',
            ),
          ],
          // What the sizes are, and what they are not. Kept to one line and
          // shown only where something was measured.
          if (!weight.isEmpty) ...[
            const SizedBox(height: 10),
            _Note(
              icon: Icons.scale_outlined,
              text: 'Weight is ${weight.display} — what these packages take to '
                  'install, not what a bundler would ship after tree-shaking. '
                  '${weight.bases.map((b) => b.caveat).join(' ')}'
                  '${weight.shortfall == null ? '' : ' ${weight.shortfall}'}',
            ),
          ],
        ],
      ),
    );
  }
}

/// A panel down the right-hand edge, full height.
///
/// Built from [showGeneralDialog] rather than an `endDrawer`, because the
/// Scaffold's drawer is one per screen and this has to be able to show a
/// different package each time without the screen owning which.
class _SidePanel extends StatelessWidget {
  const _SidePanel({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;

    return Align(
      alignment: Alignment.centerRight,
      child: SizedBox(
        // Wide enough for the version tables inside, and never more than a
        // third of a very wide monitor — a panel that took half of a 4K screen
        // would be a second page rather than an aside.
        width: (width * 0.34).clamp(420.0, 620.0),
        height: double.infinity,
        child: Material(
          color: Theme.of(context).colorScheme.surface,
          elevation: 16,
          child: SafeArea(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Align(
                  alignment: Alignment.centerRight,
                  child: IconButton(
                    tooltip: 'Close',
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ),
                Expanded(
                  child: SingleChildScrollView(child: child),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The package names, at most a handful, then a count of the rest.
///
/// A note is read at a glance or not at all, and forty names in a paragraph is
/// not read at all.
String _names(List<DepNode> nodes, {int limit = 6}) {
  final names = nodes.map((n) => n.name).toList();
  if (names.length <= limit) return names.join(', ');
  return '${names.take(limit).join(', ')} and ${names.length - limit} more';
}

String _count(int n, String noun, {String? plural}) =>
    n == 1 ? '1 $noun' : '$n ${plural ?? '${noun}s'}';

/// What dropping the unused declarations would actually give back, appended to
/// the note that lists them.
///
/// The interesting number is rarely the packages named: it is the transitive
/// tail that comes out with them, which is why this counts [SizeTally.measured]
/// rather than [dropped]. Empty when nothing was measured — a report that
/// cannot say must not imply the saving is nil.
String _reclaimNote(SizeTally reclaimable, int dropped) {
  if (reclaimable.isEmpty) return '';

  final extra = reclaimable.measured + reclaimable.unmeasured - dropped;
  final tail = extra > 0
      ? ' with ${_count(extra, 'package')} nothing else pulls in'
      : '';

  return ' Dropping them frees ${reclaimable.display}$tail.'
      '${reclaimable.shortfall == null ? '' : ' ${reclaimable.shortfall}'}';
}

/// A line of context inside the header band: what the report covers, or what it
/// could not.
///
/// Set against the ink rather than on paper, because these are qualifications
/// on the numbers directly above them and they lose their referent the moment
/// they are moved out of the band.
class _Note extends StatelessWidget {
  const _Note({
    required this.icon,
    required this.text,
    this.isWarning = false,
  });

  final IconData icon;
  final String text;
  final bool isWarning;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = isWarning
        ? const Color(0xFFFFC26B)
        : Colors.white.withValues(alpha: 0.62);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 15, color: color),
        const SizedBox(width: 7),
        Expanded(
          child: Text(
            text,
            style: theme.textTheme.bodySmall?.copyWith(color: color),
          ),
        ),
      ],
    );
  }
}

/// Coarse relative time — a report's age only matters in broad strokes.
String _ago(DateTime time) {
  final delta = DateTime.now().toUtc().difference(time.toUtc());
  if (delta.inMinutes < 1) return 'just now';
  if (delta.inHours < 1) return '${delta.inMinutes}m ago';
  if (delta.inDays < 1) return '${delta.inHours}h ago';
  return '${delta.inDays}d ago';
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required int value, this.color})
      : figure = '$value';

  /// A stat whose figure is not a count — `1.4 MB` beside `installed`.
  ///
  /// Never coloured: the palette here means "this needs attention", and a
  /// dependency tree having a size is not a finding.
  const _Stat.text({required this.label, required this.figure}) : color = null;

  final String label;

  /// What to print large. A string rather than a number because the tree's
  /// weight is measured in bytes and reads in megabytes.
  final String figure;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Text(
          figure,
          style: display(
            theme.textTheme.headlineSmall,
            color: color ?? Colors.white,
          ),
        ),
        const SizedBox(width: 7),
        Text(
          label,
          style: theme.textTheme.bodySmall?.copyWith(
            color: Colors.white.withValues(alpha: 0.7),
          ),
        ),
      ],
    );
  }
}

/// Lists the packages carrying advisories that apply to the installed version,
/// worst first.
class _Advisories extends StatelessWidget {
  const _Advisories({required this.report, this.onLoadRemediation});

  final DepReport report;

  /// Fetches verified fixes. Optional so the card renders without a backend.
  final Future<RemediationPlan> Function()? onLoadRemediation;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final affected = report.affectedNodes;
    if (affected.isEmpty) return const SizedBox.shrink();

    final worst = report.worstSeverity ?? AdvisorySeverity.unknown;
    final accent = severityColor(worst, theme);
    final counts = report.advisoryCounts;

    return SpineCard(
      accent: accent,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionHeading(
            icon: Icons.gpp_maybe_outlined,
            title: 'Security advisories',
            accent: accent,
            // The breakdown, so the headline is the shape of the problem
            // rather than a single count that treats every finding alike.
            trailing: Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                for (final entry in counts.entries)
                  _SeverityCount(severity: entry.key, count: entry.value),
              ],
            ),
          ),
          const SizedBox(height: 14),
          for (final node in affected) ...[
            _AffectedPackage(node: node, nodes: report.nodes),
            const SizedBox(height: 14),
          ],
          if (onLoadRemediation != null) ...[
            const Divider(height: 8),
            const SizedBox(height: 10),
            RemediationPanel(load: onLoadRemediation!),
          ],
        ],
      ),
    );
  }
}

/// `3 critical` in that band's colour.
class _SeverityCount extends StatelessWidget {
  const _SeverityCount({required this.severity, required this.count});

  final AdvisorySeverity severity;
  final int count;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = severityColor(severity, theme);

    return Text(
      '$count ${severityLabel(severity).toLowerCase()}',
      style: theme.textTheme.labelMedium
          ?.copyWith(color: color, fontWeight: FontWeight.w700),
    );
  }
}

/// One vulnerable package: what is wrong, what fixes it, and — when the project
/// does not declare it — what would have to be bumped to get the fix.
class _AffectedPackage extends StatelessWidget {
  const _AffectedPackage({required this.node, required this.nodes});

  final DepNode node;

  /// The whole report, needed to trace a transitive package back to a
  /// dependency the project actually declares.
  final List<DepNode> nodes;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text: node.name,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    TextSpan(text: ' ${node.installed}'),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 8),
            DepStatusChip(status: node.status),
          ],
        ),
        for (final advisory in node.advisories) ...[
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.only(left: 2),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SeverityChip(
                      severity: advisory.severity,
                      score: advisory.cvssScore,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        [advisory.id, ...advisory.aliases].join('  ·  '),
                        style: theme.textTheme.bodySmall
                            ?.copyWith(fontWeight: FontWeight.w600),
                      ),
                    ),
                  ],
                ),
                if (advisory.summary != null)
                  Text(advisory.summary!, style: theme.textTheme.bodySmall),
                Text(
                  // A missing fix version means the advisory did not say, not
                  // that the package is unfixable — worth the extra words.
                  advisory.fixedIn != null
                      ? 'Fixed in ${advisory.fixedIn}.'
                      : 'No fixed version is published in this advisory.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: advisory.fixedIn != null
                        ? Colors.green.shade800
                        : theme.textTheme.bodySmall?.color,
                    fontWeight:
                        advisory.fixedIn != null ? FontWeight.w600 : null,
                  ),
                ),
              ],
            ),
          ),
        ],
        ..._blame(context),
      ],
    );
  }

  /// For a package the project does not declare, names what does pull it in.
  ///
  /// Bumping the vulnerable package itself is not an option here — nothing in
  /// `pubspec.yaml` mentions it. The fix has to come through whatever depends
  /// on it, so that is the useful thing to print.
  List<Widget> _blame(BuildContext context) {
    if (node.kind != DepKind.transitive) return const [];

    final culprits = {
      for (final path in dependencyPathsTo(node.name, nodes))
        if (path.length > 1) path.first,
    };
    if (culprits.isEmpty) return const [];

    final theme = Theme.of(context);
    return [
      const SizedBox(height: 4),
      Text(
        culprits.length == 1
            ? 'You do not depend on ${node.name} directly — it arrives through '
                '${culprits.single}, which is what has to move.'
            : 'You do not depend on ${node.name} directly — it arrives through '
                '${culprits.join(' and ')}.',
        style: theme.textTheme.bodySmall,
      ),
    ];
  }
}

class _Message extends StatelessWidget {
  const _Message({
    required this.icon,
    required this.text,
    this.isError = false,
    this.onRetry,
  });

  final IconData icon;
  final String text;
  final bool isError;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 40,
              color: isError ? theme.colorScheme.error : null,
            ),
            const SizedBox(height: 12),
            Text(
              text,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: isError ? theme.colorScheme.error : null,
              ),
            ),
            if (onRetry != null) ...[
              const SizedBox(height: 16),
              OutlinedButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh),
                label: const Text('Try again'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
