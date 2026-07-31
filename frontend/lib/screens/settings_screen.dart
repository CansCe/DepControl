import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../auth/session_monitor.dart';
import '../platform/app_surface.dart';
import '../security/app_lock.dart';
import '../security/pin_field.dart';
import '../security/pin_scope.dart';
import '../security/pin_store.dart';
import '../security/web_session_timeout.dart';
import '../theme.dart';
import '../widgets/chrome.dart';

/// Account, session and device settings.
///
/// Everything here is about the boundary between an account and the machine it
/// is being read on, which is why the session's real expiry is printed rather
/// than described: "you stay signed in for a while" is the kind of sentence
/// that survives a configuration change it was no longer true for.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    this.email,
    this.userId,
    this.sessionExpiresAt,
    this.lock,
    this.store,
    this.scope,
    this.surface,
    this.idleLimit = WebSessionTimeout.defaultIdleLimit,
    this.onSignOut,
    super.key,
  });

  /// All optional so the screen can be driven without Supabase. In the app they
  /// are read from the current session.
  final String? email;
  final String? userId;
  final DateTime? sessionExpiresAt;
  final AppLock? lock;
  final PinStore? store;

  /// Defaults to whichever build this is; passed explicitly by tests, which
  /// need to read both wordings without being compiled twice.
  final PinScope? scope;

  /// Which build this is — it decides whether a PIN is offered at all.
  /// Defaults to the real one; tests pass a value.
  final AppSurface? surface;

  /// How long the browser may idle before signing out. Only read on the
  /// browser build, where it is what replaced the PIN.
  final Duration idleLimit;

  final Future<void> Function()? onSignOut;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final AppLock _lock = widget.lock ?? AppLock.instance;
  late final PinStore _store = widget.store ?? PinStore();

  PinState _pin = PinState.none;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final state = await _store.read();
    if (!mounted) return;
    setState(() {
      _pin = state;
      _loading = false;
    });
  }

  String? get _email {
    if (widget.email != null) return widget.email;
    return _session()?.user.email;
  }

  String? get _userId {
    if (widget.userId != null) return widget.userId;
    return _session()?.user.id;
  }

  DateTime? get _expiresAt {
    if (widget.sessionExpiresAt != null) return widget.sessionExpiresAt;
    final expiresAt = _session()?.expiresAt;
    return expiresAt == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(expiresAt * 1000);
  }

  Session? _session() {
    try {
      return Supabase.instance.client.auth.currentSession;
    } catch (_) {
      return null;
    }
  }

  void _say(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _runPinTask(PinTask task) async {
    final userId = _userId;
    if (userId == null) {
      _say('Sign in again before changing the PIN.');
      return;
    }

    final done = await showDialog<bool>(
      context: context,
      builder: (context) => PinTaskDialog(
        task: task,
        store: _store,
        userId: userId,
      ),
    );

    if (!(done ?? false)) return;
    await _lock.refresh();
    await _load();
    _say(switch (task) {
      PinTask.create => 'PIN set. It is asked for when you open the app.',
      PinTask.change => 'PIN changed.',
      PinTask.remove => 'PIN removed from this device.',
    });
  }

  Future<void> _signOut() async {
    final handler = widget.onSignOut ?? SessionMonitor.instance.signOutRequested;
    await handler();
    if (mounted) Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final surface = widget.surface ?? AppSurface.current();

    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(title: const Text('Settings')),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkBand(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Eyebrow('Account', color: Palette.pub),
                const SizedBox(height: 6),
                Text(
                  _email ?? 'Signed in',
                  style: display(
                    theme.textTheme.headlineSmall,
                    color: Colors.white,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(24, 20, 24, 28),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 720),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _SessionCard(expiresAt: _expiresAt),
                      const SizedBox(height: 16),
                      // The browser has no PIN to offer: it is not built,
                      // cannot be set, and would not have locked anything the
                      // developer console could not reach anyway. What guards
                      // an unattended tab there is the idle sign-out, so that
                      // is what this card describes instead.
                      if (surface.isBrowser)
                        _IdleSignOutCard(idleLimit: widget.idleLimit)
                      else if (_loading)
                        const Card(
                          child: Padding(
                            padding: EdgeInsets.all(28),
                            child: Center(child: CircularProgressIndicator()),
                          ),
                        )
                      else
                        _PinCard(
                          pin: _pin,
                          appliesHere: _pin.appliesTo(_userId),
                          scope: widget.scope ?? PinScope.current(),
                          onCreate: () => _runPinTask(PinTask.create),
                          onChange: () => _runPinTask(PinTask.change),
                          onRemove: () => _runPinTask(PinTask.remove),
                          onLockNow: () {
                            _lock.lockNow();
                            Navigator.of(context).maybePop();
                          },
                        ),
                      const SizedBox(height: 16),
                      OutlinedButton.icon(
                        onPressed: _signOut,
                        icon: const Icon(Icons.logout, size: 18),
                        label: const Text('Sign out'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// How long this device stays signed in, in the only terms that are checkable:
/// the moment the current token stops being accepted.
class _SessionCard extends StatelessWidget {
  const _SessionCard({required this.expiresAt});

  final DateTime? expiresAt;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final expiry = expiresAt;

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Eyebrow('This session'),
            const SizedBox(height: 10),
            Text(
              expiry == null
                  ? 'No session token to report on.'
                  : 'The token this browser holds is good until '
                      '${_formatStamp(expiry)} — '
                      '${_describeGap(expiry.difference(DateTime.now()))} from '
                      'now.',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 8),
            Text(
              'While you have the app open it renews itself in the background, '
              'so this is how long an idle browser stays signed in, not how '
              'long you get before being interrupted.',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

/// The PIN section: what is set, what to do about it, and what it is worth.
/// What guards an unattended tab on the browser build, in place of the PIN.
///
/// Not presented as a setting, because it is not one: there is no control here.
/// It is stated rather than offered so that somebody who goes looking for the
/// PIN they had on their phone finds out what replaced it and why, instead of
/// concluding the web build simply has no protection.
class _IdleSignOutCard extends StatelessWidget {
  const _IdleSignOutCard({required this.idleLimit});

  final Duration idleLimit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final minutes = idleLimit.inMinutes;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.timer_outlined, size: 20),
                const SizedBox(width: 10),
                Text('Idle sign-out', style: theme.textTheme.titleMedium),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              'This browser signs out after $minutes minutes with no '
              'activity, so a tab left open on a shared machine does not stay '
              'signed in. You get a warning first.',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 14),
            Text(PinScope.heading, style: theme.textTheme.titleSmall),
            const SizedBox(height: 6),
            Text(
              // The same honesty the PIN's own explanation was written with:
              // say what the measure reaches and what it does not, because the
              // gap is where somebody makes a bad assumption.
              'It ends the session in this browser, which is more than a '
              'screen lock did — the old PIN sat in front of a token that was '
              'still readable from the developer console.\n\n'
              'It does not reach a token somebody has already copied. Signing '
              'out clears this browser\'s copy; it does not tell the API to '
              'refuse one taken earlier, and that stays usable until it '
              'expires on its own. If a machine is lost rather than merely '
              'left open, treat the session as compromised.',
              style: theme.textTheme.bodySmall?.copyWith(color: Palette.slate),
            ),
          ],
        ),
      ),
    );
  }
}

class _PinCard extends StatelessWidget {
  const _PinCard({
    required this.pin,
    required this.appliesHere,
    required this.scope,
    required this.onCreate,
    required this.onChange,
    required this.onRemove,
    required this.onLockNow,
  });

  final PinState pin;

  /// Whether the stored PIN belongs to the account signed in now.
  final bool appliesHere;

  /// What the PIN is worth on this build.
  final PinScope scope;

  final VoidCallback onCreate;
  final VoidCallback onChange;
  final VoidCallback onRemove;
  final VoidCallback onLockNow;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Eyebrow('Device PIN'),
            const SizedBox(height: 10),
            Row(
              children: [
                Icon(
                  appliesHere ? Icons.lock_outline : Icons.lock_open_outlined,
                  size: 18,
                  color: appliesHere ? Palette.patch : Palette.slate,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    appliesHere ? scope.whenOn : scope.whenOff,
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
              ],
            ),
            if (appliesHere && pin.setAt != null) ...[
              const SizedBox(height: 6),
              Text(
                'Set ${_formatStamp(pin.setAt!)}.',
                style: theme.textTheme.bodySmall,
              ),
            ],
            const SizedBox(height: 14),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                if (!appliesHere)
                  FilledButton.icon(
                    onPressed: onCreate,
                    icon: const Icon(Icons.pin_outlined, size: 18),
                    label: const Text('Set a PIN'),
                  )
                else ...[
                  FilledButton.icon(
                    onPressed: onLockNow,
                    icon: const Icon(Icons.lock_outline, size: 18),
                    label: const Text('Lock now'),
                  ),
                  OutlinedButton(
                    onPressed: onChange,
                    child: const Text('Change PIN'),
                  ),
                  OutlinedButton(
                    onPressed: onRemove,
                    child: const Text('Remove PIN'),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 16),
            const Divider(),
            const SizedBox(height: 12),
            // Said plainly, on the screen where someone decides whether to rely
            // on it. A lock that is oversold is worse than no lock, because it
            // is the one people leave their machine unattended for — and what
            // it is worth genuinely differs between the web build and the app,
            // so [PinScope] answers rather than one hardcoded paragraph.
            Text(PinScope.heading, style: theme.textTheme.titleSmall),
            const SizedBox(height: 6),
            Text(scope.explanation, style: theme.textTheme.bodySmall),
          ],
        ),
      ),
    );
  }
}

/// Which change to the PIN a dialog is collecting.
enum PinTask { create, change, remove }

/// Sets, changes or removes the PIN.
///
/// Changing or removing asks for the current one first. Someone at an unlocked
/// screen is already past the lock, so this does not stop an attacker — it
/// stops the lock from being silently altered by someone who walked up to an
/// open laptop and would otherwise leave no trace at all.
class PinTaskDialog extends StatefulWidget {
  const PinTaskDialog({
    required this.task,
    required this.store,
    required this.userId,
    super.key,
  });

  final PinTask task;
  final PinStore store;
  final String userId;

  @override
  State<PinTaskDialog> createState() => _PinTaskDialogState();
}

class _PinTaskDialogState extends State<PinTaskDialog> {
  final _current = TextEditingController();
  final _next = TextEditingController();
  final _confirm = TextEditingController();

  bool _busy = false;
  String? _error;

  bool get _needsCurrent => widget.task != PinTask.create;
  bool get _needsNew => widget.task != PinTask.remove;

  @override
  void dispose() {
    _current.dispose();
    _next.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      if (_needsCurrent) {
        final check = await widget.store.verify(_current.text);
        if (!check.ok) {
          setState(() => _error = check.isLockedOut
              ? 'Too many wrong tries. Wait and try again.'
              : 'That is not your current PIN.');
          return;
        }
      }

      if (_needsNew) {
        final problem = PinStore.validate(_next.text);
        if (problem != null) {
          setState(() => _error = problem);
          return;
        }
        if (_next.text != _confirm.text) {
          setState(() => _error = 'The two PINs do not match.');
          return;
        }
        await widget.store.setPin(_next.text, userId: widget.userId);
      } else {
        await widget.store.clear();
      }

      if (mounted) Navigator.of(context).pop(true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AlertDialog(
      title: Text(switch (widget.task) {
        PinTask.create => 'Set a PIN',
        PinTask.change => 'Change your PIN',
        PinTask.remove => 'Remove your PIN',
      }),
      content: SizedBox(
        width: 340,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.task == PinTask.create) ...[
              Text(
                'Between ${PinStore.minLength} and ${PinStore.maxLength} '
                'digits. It is asked for when you open the app.',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 14),
            ],
            if (widget.task == PinTask.remove) ...[
              Text(
                'The app will stop asking for anything when it opens.',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 14),
            ],
            if (_needsCurrent)
              PinField(
                controller: _current,
                onSubmit: _submit,
                label: 'Current PIN',
              ),
            if (_needsCurrent && _needsNew) const SizedBox(height: 12),
            if (_needsNew) ...[
              PinField(
                controller: _next,
                onSubmit: _submit,
                label: 'New PIN',
                autofocus: !_needsCurrent,
              ),
              const SizedBox(height: 12),
              PinField(
                controller: _confirm,
                onSubmit: _submit,
                label: 'Repeat it',
                autofocus: false,
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.error),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _busy ? null : _submit,
          style: widget.task == PinTask.remove
              ? FilledButton.styleFrom(
                  backgroundColor: theme.colorScheme.error,
                )
              : null,
          child: Text(switch (widget.task) {
            PinTask.create => 'Set PIN',
            PinTask.change => 'Change PIN',
            PinTask.remove => 'Remove PIN',
          }),
        ),
      ],
    );
  }
}

/// `29 Jul 2026, 14:30` — a date someone can check against a clock, in local
/// time, since that is the clock they are looking at.
String _formatStamp(DateTime time) {
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  final local = time.toLocal();
  final minute = local.minute.toString().padLeft(2, '0');
  return '${local.day} ${months[local.month - 1]} ${local.year}, '
      '${local.hour}:$minute';
}

/// A duration in the roughest terms that are still true.
String _describeGap(Duration gap) {
  if (gap.isNegative) return 'already past';
  if (gap.inMinutes < 60) return '${gap.inMinutes} minutes';
  if (gap.inHours < 48) return '${gap.inHours} hours';
  // Rounded, not truncated: a token issued for seven days is six days and
  // twenty-three hours away by the time this renders, and reporting "6 days"
  // for a week-long session reads as a bug in the setting.
  return '${(gap.inMinutes / 1440).round()} days';
}
