import 'dart:async';

import 'package:flutter/material.dart';

import '../theme.dart';
import '../widgets/chrome.dart';
import 'app_lock.dart';
import 'pin_field.dart';
import 'pin_store.dart';

/// What stands between a signed-in session and the screen when the PIN is on.
///
/// Built like the sign-in screen on purpose — same ink page, same paper card —
/// because it is doing the same job at a smaller scale, and someone arriving at
/// it should recognise where they are without reading a word.
class PinLockScreen extends StatefulWidget {
  const PinLockScreen({
    required this.lock,
    required this.onForgotten,
    this.email,
    super.key,
  });

  final AppLock lock;

  /// Clears the PIN and signs out. The only way past a PIN nobody remembers —
  /// and it has to exist, because a local lock with no escape is a way to lose
  /// an account to a typo.
  final Future<void> Function() onForgotten;

  /// Who is signed in, so the screen says whose session is behind it.
  final String? email;

  @override
  State<PinLockScreen> createState() => _PinLockScreenState();
}

class _PinLockScreenState extends State<PinLockScreen> {
  final _controller = TextEditingController();

  bool _busy = false;
  String? _error;
  Duration _wait = Duration.zero;
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _syncLockout(widget.lock.state.lockoutRemaining);
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _controller.dispose();
    super.dispose();
  }

  /// Counts a lockout down on screen. A disabled field with no explanation is
  /// indistinguishable from a broken one, so the wait is shown running out.
  void _syncLockout(Duration remaining) {
    _ticker?.cancel();
    _wait = remaining;
    if (remaining <= Duration.zero) return;

    _ticker = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) return timer.cancel();
      final left = widget.lock.state.lockoutRemaining;
      setState(() => _wait = left);
      if (left <= Duration.zero) timer.cancel();
    });
  }

  Future<void> _submit() async {
    final pin = _controller.text;
    if (pin.isEmpty || _busy || _wait > Duration.zero) return;

    setState(() {
      _busy = true;
      _error = null;
    });

    final result = await widget.lock.unlock(pin);
    if (!mounted) return;

    if (result.ok) {
      // The gate swaps this screen out; nothing to navigate.
      setState(() => _busy = false);
      return;
    }

    _controller.clear();
    setState(() {
      _busy = false;
      _error = _messageFor(result);
    });
    _syncLockout(result.retryIn);
  }

  String _messageFor(PinVerification result) {
    if (result.isLockedOut) {
      return 'Too many wrong tries.';
    }
    final left = PinStore.attemptsBeforeDelay - result.failures;
    return left > 0
        ? 'Wrong PIN. $left ${left == 1 ? 'try' : 'tries'} before it starts '
            'making you wait.'
        : 'Wrong PIN.';
  }

  String _formatWait(Duration wait) {
    final seconds = wait.inSeconds;
    if (seconds < 60) return '${seconds}s';
    final minutes = wait.inMinutes;
    return '${minutes}m ${seconds - minutes * 60}s';
  }

  Future<void> _forget() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Sign out instead?'),
        content: const Text(
          'This removes the PIN from this device and signs you out. You can '
          'sign in with your email and password, and set a new PIN afterwards.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Remove PIN and sign out'),
          ),
        ],
      ),
    );

    if (confirmed ?? false) await widget.onForgotten();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final waiting = _wait > Duration.zero;

    return Scaffold(
      backgroundColor: Palette.ink,
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 380),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Eyebrow('Locked', color: Palette.pub),
                const SizedBox(height: 8),
                Text(
                  'Enter your PIN.',
                  style: display(
                    theme.textTheme.headlineMedium,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  widget.email == null
                      ? 'You are still signed in — this is just the lock on '
                          'this device.'
                      : 'Still signed in as ${widget.email}. This is the lock '
                          'on this device, not on the account.',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: Colors.white.withValues(alpha: 0.62),
                  ),
                ),
                const SizedBox(height: 22),
                Container(
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    color: Palette.paper,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      PinField(
                        controller: _controller,
                        onSubmit: _submit,
                        enabled: !waiting && !_busy,
                        errorText: waiting
                            ? '$_error Try again in ${_formatWait(_wait)}.'
                            : _error,
                      ),
                      const SizedBox(height: 16),
                      FilledButton(
                        onPressed: waiting || _busy ? null : _submit,
                        child: _busy
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Text('Unlock'),
                      ),
                      const SizedBox(height: 4),
                      TextButton(
                        onPressed: _busy ? null : _forget,
                        child: const Text('Forgot your PIN?'),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
