import 'package:flutter/material.dart';

import '../theme.dart';
import '../widgets/console_shell.dart';

/// The registry, laid out for the console.
///
/// Only the furniture lives here — the hero, the filter, the banner. The grid
/// itself is still the registry screen's, because the rows own optimistic
/// archive and delete and splitting that across two files would put the undo
/// somewhere other than the list it undoes into.
class RegistryConsole extends StatelessWidget {
  const RegistryConsole({
    required this.controller,
    required this.onSubmit,
    required this.archived,
    required this.onFilter,
    required this.grid,
    this.onUpload,
    this.error,
    this.pinPrompt,
    this.trackedCount,
    super.key,
  });

  final TextEditingController controller;
  final VoidCallback onSubmit;

  /// Chooses a collected bundle and queues it, where this build can choose
  /// files at all.
  final VoidCallback? onUpload;

  /// Whether the archived half is on show.
  final bool archived;
  final ValueChanged<bool> onFilter;

  /// The project list, supplied by the screen that owns it.
  final Widget grid;

  final String? error;

  /// The offer to set a device PIN, where there is one to make.
  final Widget? pinPrompt;

  /// How many projects are tracked, once that is known.
  final int? trackedCount;

  @override
  Widget build(BuildContext context) {
    return ConsolePage(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Hero(
            controller: controller,
            onSubmit: onSubmit,
            onUpload: onUpload,
            archived: archived,
            error: error,
          ),
          if (pinPrompt != null) ...[
            const SizedBox(height: 20),
            pinPrompt!,
          ],
          const SizedBox(height: 28),
          _FilterBar(archived: archived, onFilter: onFilter),
          const SizedBox(height: 20),
          grid,
          const SizedBox(height: 32),
          _Insights(trackedCount: trackedCount, archived: archived),
        ],
      ),
    );
  }
}

/// The second way in: for a repository this server cannot reach.
///
/// `GitFetcher` accepts github.com and gitlab.com and nothing else, so an Azure
/// DevOps repository, a GitHub Enterprise one, or anything behind a VPN cannot
/// be scanned by URL at all. It is read where it lives instead, by a CLI, and
/// what arrives here is the dependency list rather than the repository.
///
/// The command is shown rather than explained, because it is the whole of what
/// somebody has to do and a paragraph about it would be longer than it is.
class _LocalRepositoryHint extends StatelessWidget {
  const _LocalRepositoryHint({required this.onUpload});

  final VoidCallback? onUpload;

  static const command = 'dart run depcontrol collect .';

  @override
  Widget build(BuildContext context) {
    final surfaces = Surfaces.of(context);
    final theme = Theme.of(context);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Icon(Icons.vpn_lock_outlined, size: 15, color: surfaces.muted),
        const SizedBox(width: 8),
        Expanded(
          // `Text.rich` rather than a bare `RichText`: it inherits the ambient
          // text style, and it is what widget finders can read — a line nobody
          // can assert on is a line that quietly disappears in a refactor.
          child: Text.rich(
            TextSpan(
              style: theme.textTheme.bodySmall?.copyWith(color: surfaces.muted),
              children: [
                const TextSpan(
                  text: 'Repository we cannot reach, or a lockfile that is not '
                      'committed? Run ',
                ),
                TextSpan(
                  text: command,
                  style: monoOf(
                    context,
                    theme.textTheme.bodySmall,
                    color: surfaces.text,
                  ),
                ),
                const TextSpan(
                  text: ' where it lives and upload the bundle. It sends the '
                      'dependency list, not the code.',
                ),
              ],
            ),
          ),
        ),
        if (onUpload != null) ...[
          const SizedBox(width: 12),
          OutlinedButton.icon(
            onPressed: onUpload,
            icon: const Icon(Icons.upload_file_outlined, size: 17),
            label: const Text('Upload bundle'),
          ),
        ],
      ],
    );
  }
}

/// The card the page opens with: what this screen is, and the one action it
/// exists to offer.
class _Hero extends StatelessWidget {
  const _Hero({
    required this.controller,
    required this.onSubmit,
    required this.onUpload,
    required this.archived,
    required this.error,
  });

  final TextEditingController controller;
  final VoidCallback onSubmit;

  /// Chooses a bundle file and queues it. Null on a build with no file chooser,
  /// which hides the button and leaves the instructions — the CLI command is
  /// true everywhere, and the browser is where the file goes.
  final VoidCallback? onUpload;
  final bool archived;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final surfaces = Surfaces.of(context);
    final theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.all(30),
      decoration: BoxDecoration(
        color: surfaces.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: surfaces.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              ConsoleEyebrow(archived ? 'Archived' : 'Registry'),
              const SizedBox(width: 12),
              Expanded(
                child: Divider(color: surfaces.hairline, height: 1),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Text(
            archived
                ? 'Projects you have put out of the way.'
                : 'Every project you track, and what it depends on.',
            style: displayOf(context, theme.textTheme.headlineSmall),
          ),
          // Nothing is added from the archived view: a project arrives active,
          // and an add form here would either contradict the filter it sits
          // under or silently switch away from it.
          if (!archived) ...[
            const SizedBox(height: 26),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: TextField(
                    controller: controller,
                    style: monoOf(context, theme.textTheme.bodyMedium),
                    decoration: InputDecoration(
                      hintText: 'https://github.com/organization/repo.git',
                      hintStyle: monoOf(
                        context,
                        theme.textTheme.bodyMedium,
                        color: surfaces.faint,
                      ),
                      prefixIcon: Icon(Icons.link, size: 19, color: surfaces.muted),
                      contentPadding:
                          const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
                    ),
                    onSubmitted: (_) => onSubmit(),
                  ),
                ),
                const SizedBox(width: 14),
                SizedBox(
                  height: 56,
                  child: FilledButton.icon(
                    onPressed: onSubmit,
                    icon: const Icon(Icons.add, size: 19),
                    label: const Text('Add project'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 18),
            _LocalRepositoryHint(onUpload: onUpload),
          ],
          if (error != null) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                Icon(Icons.error_outline, size: 16, color: surfaces.alarm),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    error!,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: surfaces.alarm),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// Active / Archived, as a segmented pair.
class _FilterBar extends StatelessWidget {
  const _FilterBar({required this.archived, required this.onFilter});

  final bool archived;
  final ValueChanged<bool> onFilter;

  @override
  Widget build(BuildContext context) {
    final surfaces = Surfaces.of(context);

    return Row(
      children: [
        Container(
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: surfaces.isDark ? Console.sidebar : surfaces.inset,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: surfaces.hairline),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _FilterPill(
                label: 'Active',
                selected: !archived,
                onTap: () => onFilter(false),
              ),
              _FilterPill(
                label: 'Archived',
                selected: archived,
                onTap: () => onFilter(true),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _FilterPill extends StatelessWidget {
  const _FilterPill({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final surfaces = Surfaces.of(context);
    final theme = Theme.of(context);

    return Material(
      color: selected
          ? (surfaces.isDark ? Console.chip : surfaces.card)
          : Colors.transparent,
      borderRadius: BorderRadius.circular(6),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 7),
          child: Text(
            label,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: selected ? surfaces.text : surfaces.muted,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }
}

/// The dashed panel at the foot of the registry.
///
/// Says only what the registry can actually see. The drawing this comes from
/// had it claim a number of services were "currently healthy", which is a
/// verdict from reports this screen never loaded — so it says how many projects
/// are tracked and where the verdicts live instead.
class _Insights extends StatelessWidget {
  const _Insights({required this.trackedCount, required this.archived});

  final int? trackedCount;
  final bool archived;

  @override
  Widget build(BuildContext context) {
    if (archived || trackedCount == null || trackedCount == 0) {
      return const SizedBox.shrink();
    }

    final surfaces = Surfaces.of(context);
    final theme = Theme.of(context);
    final count = trackedCount!;

    return Container(
      padding: const EdgeInsets.all(26),
      decoration: BoxDecoration(
        color: surfaces.isDark ? Console.abyss : surfaces.inset,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: surfaces.hairline),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.security_update_good_outlined,
              size: 20, color: surfaces.accent),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Automated registry insights',
                  style: theme.textTheme.titleSmall,
                ),
                const SizedBox(height: 6),
                Text(
                  count == 1
                      ? 'One project tracked. Open it for its advisories, '
                          'licenses and dependency tree.'
                      : '$count projects tracked. Open one for its advisories, '
                          'licenses and dependency tree.',
                  style:
                      theme.textTheme.bodySmall?.copyWith(color: surfaces.muted),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A small tracked-out label in the display face — the console's section mark.
class ConsoleEyebrow extends StatelessWidget {
  const ConsoleEyebrow(this.text, {this.tint, super.key});

  final String text;
  final Color? tint;

  @override
  Widget build(BuildContext context) {
    final surfaces = Surfaces.of(context);
    final color = tint ?? surfaces.accent;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: surfaces.wash(color),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withValues(alpha: 0.22)),
      ),
      child: Text(
        text.toUpperCase(),
        style: monoOf(
          context,
          Theme.of(context).textTheme.labelSmall,
          color: color,
          weight: FontWeight.w700,
        ).copyWith(letterSpacing: 0.9, fontSize: 10),
      ),
    );
  }
}
