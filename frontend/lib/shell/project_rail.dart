import 'package:flutter/material.dart';
import 'package:shared/shared.dart';

import '../theme.dart';

/// The project list, kept on screen beside whatever is open.
///
/// This is the change that makes the app read as a web application rather than
/// a phone one. Before, opening a report *replaced* the registry: switching
/// projects meant going back and picking again, which is the right trade on a
/// phone — where a second column would leave neither readable — and pure loss
/// on a screen with fourteen hundred spare pixels. Here the list never leaves,
/// so switching is one click and the reader keeps their place in the set.
///
/// Below the breakpoint the same widget is what the drawer contains, so there
/// is one list rather than two that can disagree.
class ProjectRail extends StatelessWidget {
  const ProjectRail({
    required this.projects,
    required this.selectedId,
    required this.onSelect,
    required this.onAdd,
    this.error,
    this.loading = false,
    super.key,
  });

  final List<Project> projects;

  /// Which project is open, or null on the registry itself.
  final String? selectedId;

  final void Function(Project project) onSelect;
  final VoidCallback onAdd;

  final String? error;
  final bool loading;

  static const width = 236.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final active = [for (final p in projects) if (!p.isArchived) p];
    final archived = [for (final p in projects) if (p.isArchived) p];

    return Container(
      width: width,
      color: Palette.paper,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 8, 6),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Projects',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: Palette.slate,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.6,
                    ),
                  ),
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.add, size: 18, color: Palette.pub),
                  onPressed: onAdd,
                ),
              ],
            ),
          ),
          if (loading)
            const Padding(
              padding: EdgeInsets.all(20),
              child: Center(
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            )
          else if (error case final message?)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 4, 14, 12),
              child: Text(
                message,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.error),
              ),
            )
          else if (projects.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 4, 14, 12),
              child: Text(
                // An empty screen is an invitation, not a report of absence.
                'Add a repository by its Git URL to see what it depends on.',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: Palette.slate),
              ),
            )
          else
            Expanded(
              child: ListView(
                padding: const EdgeInsets.only(bottom: 12),
                children: [
                  for (final project in active)
                    _RailRow(
                      project: project,
                      selected: project.id == selectedId,
                      onTap: () => onSelect(project),
                    ),
                  if (archived.isNotEmpty) ...[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(14, 14, 14, 6),
                      child: Text(
                        'Archived',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: Palette.slate,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.6,
                        ),
                      ),
                    ),
                    for (final project in archived)
                      _RailRow(
                        project: project,
                        selected: project.id == selectedId,
                        onTap: () => onSelect(project),
                      ),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// One project in the rail.
///
/// Two lines: the name a person chose, and the repository a machine did — so
/// the second is monospaced, by the same rule the rest of the app follows.
class _RailRow extends StatefulWidget {
  const _RailRow({
    required this.project,
    required this.selected,
    required this.onTap,
  });

  final Project project;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_RailRow> createState() => _RailRowState();
}

class _RailRowState extends State<_RailRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final project = widget.project;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          decoration: BoxDecoration(
            color: widget.selected
                ? Palette.mist
                : _hovered
                    ? Palette.mist.withValues(alpha: 0.55)
                    : null,
            border: Border(
              left: BorderSide(
                width: 2,
                // The marker rides the left edge rather than filling the row,
                // so a selected project and a hovered one are told apart by
                // shape instead of by two shades of the same fill.
                color: widget.selected ? Palette.pub : Colors.transparent,
              ),
            ),
          ),
          padding: const EdgeInsets.fromLTRB(12, 7, 12, 7),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                project.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: project.isArchived ? Palette.slate : Palette.ink,
                  fontWeight:
                      widget.selected ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
              Text(
                project.ref,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: mono(theme.textTheme.labelSmall, color: Palette.slate),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
