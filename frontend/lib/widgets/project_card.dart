import 'package:flutter/material.dart';
import 'package:shared/shared.dart';

import '../platform/relative_time.dart';
import '../theme.dart';

/// One tracked project, as a card in the console's registry grid.
///
/// Deliberately says less than the mockup it comes from. That drawing gave each
/// card a status word and a version number, and the registry has neither: both
/// are facts about a *report*, and listing the projects does not fetch fifty of
/// those. A card that guessed them would be inventing the one thing this app
/// exists to be trusted about.
///
/// So it carries what the registry genuinely knows — what the repository is,
/// which ref was read, and when it was last looked at — and leaves the counts
/// to the screen that has actually loaded them.
class ProjectCard extends StatelessWidget {
  const ProjectCard({
    required this.project,
    required this.onOpen,
    required this.onArchive,
    required this.onDelete,
    this.archived = false,
    super.key,
  });

  final Project project;
  final VoidCallback onOpen;
  final VoidCallback onArchive;
  final Future<void> Function() onDelete;

  /// Whether this is the archived view, which swaps archiving for restoring.
  final bool archived;

  @override
  Widget build(BuildContext context) {
    final surfaces = Surfaces.of(context);
    final theme = Theme.of(context);
    final tint = archived ? surfaces.muted : surfaces.accent;

    return Material(
      color: surfaces.isDark ? Console.sidebar : surfaces.card,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onOpen,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: surfaces.hairline),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: surfaces.wash(tint),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: surfaces.hairline),
                    ),
                    child: Icon(
                      archived
                          ? Icons.inventory_2_outlined
                          : Icons.folder_outlined,
                      size: 20,
                      color: tint,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          project.name,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleMedium,
                        ),
                        const SizedBox(height: 3),
                        Row(
                          children: [
                            Icon(
                              project.isLocal
                                  ? Icons.upload_file_outlined
                                  : Icons.terminal,
                              size: 13,
                              color: surfaces.muted,
                            ),
                            const SizedBox(width: 5),
                            Expanded(
                              child: Text(
                                project.gitUrl ?? 'uploaded bundle',
                                overflow: TextOverflow.ellipsis,
                                style: monoOf(
                                  context,
                                  theme.textTheme.bodySmall,
                                  color: surfaces.muted,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  _CardMenu(
                    archived: archived,
                    onArchive: onArchive,
                    onDelete: onDelete,
                  ),
                ],
              ),
              const SizedBox(height: 18),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (archived)
                    ConsoleTag(
                      label: 'Archived',
                      tint: surfaces.muted,
                      filled: true,
                    ),
                  ConsoleTag(label: project.ref),
                  if (_lastLooked case final looked?)
                    ConsoleTag(label: looked, icon: Icons.schedule),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// When this project was last read, phrased for whichever kind it is.
  String? get _lastLooked {
    if (project.archivedAt case final at?) return 'archived ${relativeAge(at)}';
    if (project.lastCheckedAt case final at?) return relativeAge(at);
    if (project.addedAt case final at?) return 'added ${relativeAge(at)}';
    return null;
  }
}

/// A small monospaced tag — the console's one chip shape.
///
/// Mono because everything it ever holds is a string a machine assigned: a git
/// ref, a timestamp, a count. Same rule as everywhere else in the app.
class ConsoleTag extends StatelessWidget {
  const ConsoleTag({
    required this.label,
    this.tint,
    this.icon,
    this.filled = false,
    super.key,
  });

  final String label;
  final Color? tint;
  final IconData? icon;

  /// Whether the tag carries its tint as a wash, which is how a *judgement*
  /// reads. A plain tag is just a fact and stays neutral.
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final surfaces = Surfaces.of(context);
    final theme = Theme.of(context);
    final color = tint ?? surfaces.muted;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: filled
            ? surfaces.wash(color)
            : (surfaces.isDark ? Console.chip : surfaces.inset),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(
          color: filled ? color.withValues(alpha: 0.3) : surfaces.hairline,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 12, color: color),
            const SizedBox(width: 4),
          ],
          Text(
            label,
            style: monoOf(
              context,
              theme.textTheme.labelSmall,
              color: filled ? color : surfaces.muted,
              weight: filled ? FontWeight.w700 : FontWeight.w500,
            ).copyWith(fontSize: 10.5),
          ),
        ],
      ),
    );
  }
}

class _CardMenu extends StatelessWidget {
  const _CardMenu({
    required this.archived,
    required this.onArchive,
    required this.onDelete,
  });

  final bool archived;
  final VoidCallback onArchive;
  final Future<void> Function() onDelete;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      tooltip: 'Actions',
      icon: Icon(Icons.more_vert, size: 19, color: Surfaces.of(context).muted),
      onSelected: (value) {
        if (value == 'archive') {
          onArchive();
        } else {
          onDelete();
        }
      },
      itemBuilder: (context) => [
        PopupMenuItem(
          value: 'archive',
          child: Text(archived ? 'Restore' : 'Archive'),
        ),
        PopupMenuItem(
          value: 'delete',
          child: Text(
            'Delete',
            style: TextStyle(color: Surfaces.of(context).alarm),
          ),
        ),
      ],
    );
  }
}
