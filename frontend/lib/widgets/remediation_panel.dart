import 'package:flutter/material.dart';
import 'package:shared/shared.dart';

import '../theme.dart';

/// The verified fixes for a project's advisories.
///
/// Loaded on demand rather than with the report: each suggestion costs a full
/// resolution on the server, and most visits to a report are not about fixing
/// anything.
///
/// Every line here is something the server proved — it resolved the change and
/// checked that the vulnerable package actually landed on a fixed version.
/// Where it could not, that is stated instead of being quietly dropped, because
/// "no suggestion" and "no fix exists" are different situations.
class RemediationPanel extends StatefulWidget {
  const RemediationPanel({required this.load, super.key});

  final Future<RemediationPlan> Function() load;

  @override
  State<RemediationPanel> createState() => _RemediationPanelState();
}

class _RemediationPanelState extends State<RemediationPanel> {
  Future<RemediationPlan>? _plan;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (_plan == null) {
      return Align(
        alignment: Alignment.centerLeft,
        child: OutlinedButton.icon(
          // A block body, not an arrow: an arrow would return the assigned
          // Future out of the setState callback, which Flutter asserts against.
          onPressed: () {
            final plan = widget.load();
            // Attach a handler now. The FutureBuilder below does not subscribe
            // until the next frame, and a failure that lands before then would
            // otherwise surface as an unhandled async error rather than as the
            // message this widget wants to show.
            plan.then<void>((_) {}, onError: (Object _) {});
            setState(() {
              _plan = plan;
            });
          },
          icon: const Icon(Icons.build_outlined, size: 18),
          label: const Text('Work out how to fix these'),
        ),
      );
    }

    return FutureBuilder<RemediationPlan>(
      future: _plan,
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return Row(
            children: [
              const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 10),
              Text(
                'Resolving each candidate fix…',
                style: theme.textTheme.bodySmall,
              ),
            ],
          );
        }

        if (snap.hasError) {
          return Text(
            'Could not work out fixes for these advisories.',
            style: theme.textTheme.bodySmall,
          );
        }

        final plan = snap.data;
        if (plan == null || plan.remediations.isEmpty) {
          return const SizedBox.shrink();
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final fix in plan.actionable) _Fix(fix: fix),
            for (final fix in plan.blocked) _Blocked(fix: fix),
          ],
        );
      },
    );
  }
}

/// One verified fix: the pubspec line to change, and what it drags with it.
class _Fix extends StatelessWidget {
  const _Fix({required this.fix});

  final Remediation fix;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final surfaces = Surfaces.of(context);
    final green = surfaces.patch;
    final code = theme.textTheme.bodySmall?.copyWith(
      fontFamily: surfaces.faces.mono,
      fontFamilyFallback: surfaces.faces.monoFallback,
    );

    // Only the packages that move besides the one being edited.
    final knockOn =
        fix.resolves.where((c) => c.package != fix.editPackage).toList();

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: green.withValues(alpha: 0.5)),
        color: green.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.check_circle_outline, size: 16, color: green),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _headline(fix),
                  style: theme.textTheme.titleSmall?.copyWith(color: green),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          // The actual edit, as it would appear in pubspec.yaml.
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest
                  .withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('dependencies:', style: code),
                if (fix.fromConstraint != null)
                  Text(
                    '- ${fix.editPackage}: ${fix.fromConstraint}',
                    style: code?.copyWith(color: theme.colorScheme.error),
                  ),
                Text(
                  '+ ${fix.editPackage}: ${fix.toConstraint}',
                  style: code?.copyWith(color: green),
                ),
              ],
            ),
          ),
          if (fix.resolvedVersion != null) ...[
            const SizedBox(height: 8),
            Text(
              'Resolves ${fix.package} to ${fix.resolvedVersion}'
              '${knockOn.isEmpty ? '.' : ', and moves '
                  '${knockOn.length} other package'
                  '${knockOn.length == 1 ? '' : 's'}.'}',
              style: theme.textTheme.bodySmall,
            ),
          ],
          if (knockOn.isNotEmpty) ...[
            const SizedBox(height: 6),
            Wrap(
              spacing: 10,
              runSpacing: 4,
              children: [
                for (final change in knockOn.take(6))
                  Text(
                    '${change.package} ${change.from ?? '—'} → '
                    '${change.to ?? 'removed'}',
                    style: code,
                  ),
                if (knockOn.length > 6)
                  Text('+${knockOn.length - 6} more', style: code),
              ],
            ),
          ],
          if (fix.caveat != null) ...[
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.info_outline,
                  size: 14,
                  color: theme.textTheme.bodySmall?.color,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(fix.caveat!, style: theme.textTheme.bodySmall),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  static String _headline(Remediation fix) => switch (fix.kind) {
        RemediationKind.raiseConstraint =>
          'Raise ${fix.editPackage} to clear ${_count(fix)}',
        RemediationKind.bumpParent =>
          'Bump ${fix.editPackage} to clear ${fix.package}\'s ${_count(fix)}',
        RemediationKind.promoteToDirect =>
          'Pin ${fix.package} directly to clear ${_count(fix)}',
        null => fix.package,
      };

  static String _count(Remediation fix) => fix.advisoryIds.length == 1
      ? fix.advisoryIds.single
      : '${fix.advisoryIds.length} advisories';
}

/// A package whose advisory has no fix this can offer, and why.
class _Blocked extends StatelessWidget {
  const _Blocked({required this.fix});

  final Remediation fix;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.do_not_disturb_alt_outlined,
            size: 15,
            color: theme.textTheme.bodySmall?.color,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              switch (fix.blocker) {
                RemediationBlocker.noFixPublished =>
                  'No fixed version has been published for ${fix.package}. '
                      'Nothing to upgrade to yet.',
                RemediationBlocker.unreachable =>
                  'No change to this pubspec reaches a fixed ${fix.package} — '
                      'something in the tree holds it below the fix.',
                null => 'No fix could be worked out for ${fix.package}.',
              },
              style: theme.textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}
