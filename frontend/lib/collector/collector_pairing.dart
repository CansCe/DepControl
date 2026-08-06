import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared/shared.dart';

import '../api/api_client.dart';
import '../platform/open_url.dart';
import '../scans/scan_queue.dart';
import '../theme.dart';

/// Where the collector's binaries are published, baked in at build time — see
/// `.github/workflows/release-collector.yml` for what publishes them and
/// under what names.
///
/// Empty is a real state, not a misconfiguration: a build made before a
/// release existed, or one where the variable was never set, degrades to the
/// `dart run` instructions rather than showing dead links. See
/// `deploy-frontend.yml` for where this is normally supplied.
const String kCollectorReleaseUrl =
    String.fromEnvironment('COLLECTOR_RELEASE_URL');

enum _CollectorAsset {
  windows('Windows', 'depcontrol-windows-x64.exe'),
  linux('Linux', 'depcontrol-linux-x64'),
  macArm('macOS, Apple Silicon', 'depcontrol-macos-arm64'),
  macIntel('macOS, Intel', 'depcontrol-macos-x64');

  const _CollectorAsset(this.label, this.fileName);
  final String label;
  final String fileName;
}

enum _Phase { idle, minting, waiting, claimed, expired, error }

/// Downloads the collector and pairs it to this account with nothing to
/// upload by hand.
///
/// Three things belong in one widget because they are one flow: get the tool
/// (or use `dart run` if a Dart SDK is already there), mint a one-shot code,
/// watch for it being claimed. Claiming needs no bespoke watching logic of
/// its own — the collector's upload creates an ordinary scan job owned by
/// this account, so handing off to [ScanQueue.reattach] (the same call a
/// reopened tab already makes) is the entire "web listens to the tool"
/// mechanism.
class CollectorPairing extends StatefulWidget {
  const CollectorPairing({
    required this.api,
    required this.scans,
    this.projectId,
    super.key,
  });

  final ApiClient api;
  final ScanQueue scans;

  /// Set to pair a re-upload to this project; null to pair a new one.
  final String? projectId;

  @override
  State<CollectorPairing> createState() => _CollectorPairingState();
}

class _CollectorPairingState extends State<CollectorPairing> {
  _Phase _phase = _Phase.idle;
  String? _sessionId;
  String? _code;
  DateTime? _expiresAt;
  String? _error;
  Timer? _poll;

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _mint() async {
    setState(() {
      _phase = _Phase.minting;
      _error = null;
    });
    try {
      final session =
          await widget.api.createCollectorSession(projectId: widget.projectId);
      if (!mounted) return;
      setState(() {
        _sessionId = session.id;
        _code = session.code;
        _expiresAt = session.expiresAt;
        _phase = _Phase.waiting;
      });
      // A couple of seconds: fast enough that claiming feels immediate,
      // cheap enough that fifteen minutes of it is a few hundred requests.
      _poll = Timer.periodic(const Duration(seconds: 2), (_) => _check());
    } on Object {
      if (!mounted) return;
      setState(() {
        _phase = _Phase.error;
        _error = 'Could not reach the server. Try again in a moment.';
      });
    }
  }

  Future<void> _check() async {
    final id = _sessionId;
    if (id == null) return;

    final CollectorSession session;
    try {
      session = await widget.api.collectorSession(id);
    } on Object {
      return; // A missed poll is not a failure; the next one tries again.
    }
    if (!mounted) return;

    switch (session.state) {
      case CollectorSessionState.waiting:
        return;
      case CollectorSessionState.claimed:
        _poll?.cancel();
        setState(() => _phase = _Phase.claimed);
        // Fire-and-forget: `reattach` reads back through `GET /scans` and adds
        // whatever it finds to the queue, which is what makes the overlay pick
        // this scan up. Nothing here needs to wait on it.
        unawaited(widget.scans.reattach(widget.api));
      case CollectorSessionState.expired:
        _poll?.cancel();
        setState(() => _phase = _Phase.expired);
    }
  }

  void _reset() {
    _poll?.cancel();
    setState(() {
      _phase = _Phase.idle;
      _sessionId = null;
      _code = null;
      _expiresAt = null;
      _error = null;
    });
  }

  void _copyCommand() {
    final code = _code;
    if (code == null) return;
    unawaited(
      Clipboard.setData(ClipboardData(text: 'depcontrol collect --pair $code')),
    );
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Command copied.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return switch (_phase) {
      _Phase.idle || _Phase.error => _StartCard(error: _error, onPair: _mint),
      _Phase.minting => const _MintingCard(),
      _Phase.waiting => _WaitingCard(
          code: _code!,
          expiresAt: _expiresAt!,
          onCopy: _copyCommand,
          onCancel: _reset,
        ),
      _Phase.claimed => _ClaimedCard(onDone: _reset),
      _Phase.expired => _ExpiredCard(onRetry: _mint),
    };
  }
}

class _StartCard extends StatelessWidget {
  const _StartCard({required this.error, required this.onPair});

  final String? error;
  final VoidCallback onPair;

  @override
  Widget build(BuildContext context) {
    final surfaces = Surfaces.of(context);
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (canOpenUrl && kCollectorReleaseUrl.isNotEmpty) ...[
          Text(
            'Download the collector for your machine:',
            style: theme.textTheme.bodySmall?.copyWith(color: surfaces.muted),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final asset in _CollectorAsset.values)
                OutlinedButton.icon(
                  onPressed: () =>
                      openUrl('$kCollectorReleaseUrl/${asset.fileName}'),
                  icon: const Icon(Icons.download_outlined, size: 16),
                  label: Text(asset.label),
                ),
            ],
          ),
          const SizedBox(height: 4),
          _ChecksumLink(),
          const SizedBox(height: 16),
        ],
        Row(
          children: [
            Expanded(
              child: Text(
                'Then pair it to this account — no file to find or upload.',
                style:
                    theme.textTheme.bodySmall?.copyWith(color: surfaces.muted),
              ),
            ),
            const SizedBox(width: 12),
            FilledButton.icon(
              onPressed: onPair,
              icon: const Icon(Icons.link, size: 17),
              label: const Text('Pair the collector'),
            ),
          ],
        ),
        if (error != null) ...[
          const SizedBox(height: 10),
          Text(error!, style: theme.textTheme.bodySmall?.copyWith(color: surfaces.alarm)),
        ],
      ],
    );
  }
}

class _ChecksumLink extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final surfaces = Surfaces.of(context);
    final theme = Theme.of(context);

    return Text.rich(
      TextSpan(
        style: theme.textTheme.bodySmall?.copyWith(color: surfaces.faint),
        children: [
          const TextSpan(
            text: 'These are unsigned binaries — Windows and macOS will warn '
                'before running one. Verify the download against the ',
          ),
          TextSpan(
            text: '.sha256 checksum',
            style: monoOf(context, theme.textTheme.bodySmall, color: surfaces.faint),
          ),
          const TextSpan(text: ' published beside each file.'),
        ],
      ),
    );
  }
}

class _MintingCard extends StatelessWidget {
  const _MintingCard();

  @override
  Widget build(BuildContext context) {
    final surfaces = Surfaces.of(context);
    return Row(
      children: [
        const SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        const SizedBox(width: 12),
        Text(
          'Minting a pairing code…',
          style: TextStyle(color: surfaces.muted),
        ),
      ],
    );
  }
}

class _WaitingCard extends StatelessWidget {
  const _WaitingCard({
    required this.code,
    required this.expiresAt,
    required this.onCopy,
    required this.onCancel,
  });

  final String code;
  final DateTime expiresAt;
  final VoidCallback onCopy;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final surfaces = Surfaces.of(context);
    final theme = Theme.of(context);
    final command = 'depcontrol collect --pair $code';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Run this where the repository lives:',
          style: theme.textTheme.bodySmall?.copyWith(color: surfaces.muted),
        ),
        const SizedBox(height: 8),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: surfaces.isDark ? Console.abyss : surfaces.inset,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: surfaces.hairline),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  command,
                  style: monoOf(context, theme.textTheme.bodyMedium),
                ),
              ),
              IconButton(
                tooltip: 'Copy',
                icon: const Icon(Icons.copy_outlined, size: 17),
                onPressed: onCopy,
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Waiting for the collector — this code is single-use and '
                'expires ${_expiry(expiresAt)}.',
                style:
                    theme.textTheme.bodySmall?.copyWith(color: surfaces.muted),
              ),
            ),
            TextButton(onPressed: onCancel, child: const Text('Cancel')),
          ],
        ),
      ],
    );
  }

  static String _expiry(DateTime expiresAt) {
    final remaining = expiresAt.difference(DateTime.now().toUtc());
    if (remaining.inMinutes <= 0) return 'any moment';
    return 'in ${remaining.inMinutes} minute${remaining.inMinutes == 1 ? '' : 's'}';
  }
}

class _ClaimedCard extends StatelessWidget {
  const _ClaimedCard({required this.onDone});

  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    final surfaces = Surfaces.of(context);
    final theme = Theme.of(context);

    return Row(
      children: [
        Icon(Icons.check_circle_outline, size: 18, color: surfaces.accent),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            'Collector connected — the scan is running.',
            style: theme.textTheme.bodyMedium,
          ),
        ),
        TextButton(onPressed: onDone, child: const Text('Done')),
      ],
    );
  }
}

class _ExpiredCard extends StatelessWidget {
  const _ExpiredCard({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final surfaces = Surfaces.of(context);
    final theme = Theme.of(context);

    return Row(
      children: [
        Icon(Icons.error_outline, size: 18, color: surfaces.alarm),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            'That code expired before the collector used it.',
            style: theme.textTheme.bodyMedium,
          ),
        ),
        OutlinedButton(onPressed: onRetry, child: const Text('New code')),
      ],
    );
  }
}
