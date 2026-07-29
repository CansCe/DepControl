import 'package:flutter/material.dart';

import '../theme.dart';
import 'pin_scope.dart';
import 'pin_store.dart';

/// Offers a PIN to someone who has not set one.
///
/// Shown because the session it guards is now long: a browser that stays signed
/// in for a week is a browser that will be left signed in somewhere. Asked once
/// — [PinStore.dismissPrompt] remembers a no — because a prompt that returns
/// every time is one people learn to dismiss without reading, which is the
/// opposite of what it is for.
class PinPrompt extends StatefulWidget {
  const PinPrompt({
    required this.onSetUp,
    this.store,
    this.userId,
    this.scope,
    super.key,
  });

  /// Takes the user to where a PIN is set.
  final VoidCallback onSetUp;

  final PinStore? store;

  /// Who is signed in — a PIN belonging to a different account does not count
  /// as this one having answered.
  final String? userId;

  /// Defaults to whichever build this is; a browser tab and an installed app
  /// are left open in different ways and the offer says so.
  final PinScope? scope;

  @override
  State<PinPrompt> createState() => _PinPromptState();
}

class _PinPromptState extends State<PinPrompt> {
  late final PinStore _store = widget.store ?? PinStore();

  bool _show = false;

  @override
  void initState() {
    super.initState();
    _decide();
  }

  Future<void> _decide() async {
    final state = await _store.read();
    if (!mounted) return;
    setState(() {
      _show = widget.userId != null &&
          !state.appliesTo(widget.userId) &&
          !state.hasDeclinedPrompt(widget.userId);
    });
  }

  Future<void> _dismiss() async {
    final userId = widget.userId;
    setState(() => _show = false);
    if (userId != null) await _store.dismissPrompt(userId);
  }

  @override
  Widget build(BuildContext context) {
    if (!_show) return const SizedBox.shrink();
    final theme = Theme.of(context);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(24, 12, 12, 12),
      decoration: BoxDecoration(
        color: Palette.pub.withValues(alpha: 0.07),
        border: Border(
          bottom: BorderSide(color: Palette.pub.withValues(alpha: 0.24)),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const Icon(Icons.pin_outlined, size: 18, color: Palette.pub),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              (widget.scope ?? PinScope.current()).prompt,
              style: theme.textTheme.bodySmall,
            ),
          ),
          const SizedBox(width: 10),
          TextButton(onPressed: _dismiss, child: const Text('Not now')),
          const SizedBox(width: 4),
          FilledButton(
            onPressed: widget.onSetUp,
            child: const Text('Set a PIN'),
          ),
        ],
      ),
    );
  }
}
