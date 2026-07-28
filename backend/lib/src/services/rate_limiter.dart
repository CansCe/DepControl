import 'dart:io';

/// The outcome of asking a [RateLimiter] whether a request may proceed.
class RateDecision {
  const RateDecision.allowed()
      : allowed = true,
        retryAfter = Duration.zero;

  const RateDecision.denied(this.retryAfter) : allowed = false;

  final bool allowed;

  /// How long until the caller would be allowed again. Zero when allowed.
  final Duration retryAfter;

  /// `Retry-After` is expressed in whole seconds, and rounding down would
  /// invite a client to retry marginally too early and be refused again.
  int get retryAfterSeconds => retryAfter.inMilliseconds <= 0
      ? 1
      : (retryAfter.inMilliseconds / 1000).ceil();
}

/// Per-caller token bucket.
///
/// Each caller gets [burst] tokens and one more every [refill]. A request
/// spends one. That shape suits this API better than a flat cap per window:
/// adding a handful of projects in a row is normal, and a bucket permits it
/// while still holding the sustained rate down — whereas a window either
/// forbids the burst or lets someone spend the whole allowance instantly at
/// each boundary.
///
/// State is per process. Behind more than one instance, the effective limit is
/// this one multiplied by the instance count — enough to keep a single client
/// from monopolising a server, not a distributed quota.
class RateLimiter {
  RateLimiter({
    required this.burst,
    required this.refill,
    DateTime Function()? clock,
  })  : assert(burst > 0, 'burst must be positive'),
        _clock = clock ?? DateTime.now;

  /// Builds the limiter from the environment, or null when limiting is off.
  ///
  /// `RATE_LIMIT_PER_MINUTE=0` disables it — useful for a local dev loop, and
  /// explicit enough that nobody disables it by accident.
  static RateLimiter? fromEnvironment(
    Map<String, String> env, {
    DateTime Function()? clock,
  }) {
    final perMinute = int.tryParse(env['RATE_LIMIT_PER_MINUTE'] ?? '') ?? 20;
    if (perMinute <= 0) return null;

    final burst = int.tryParse(env['RATE_LIMIT_BURST'] ?? '') ?? perMinute;
    return RateLimiter(
      burst: burst > 0 ? burst : perMinute,
      refill:
          Duration(microseconds: Duration.microsecondsPerMinute ~/ perMinute),
      clock: clock,
    );
  }

  /// Most tokens a caller can hold, and so the largest burst allowed.
  final int burst;

  /// Time to earn one token back.
  final Duration refill;

  final DateTime Function() _clock;
  final _buckets = <String, _Bucket>{};

  /// Above this many tracked callers, idle ones are swept on the next check.
  /// Without it the map is a slow leak keyed by user id.
  static const _sweepThreshold = 1024;

  /// Spends one token for [key], or refuses and says when to come back.
  RateDecision check(String key) {
    final now = _clock();
    if (_buckets.length > _sweepThreshold) _sweep(now);

    final bucket = _buckets.putIfAbsent(
      key,
      () => _Bucket(tokens: burst.toDouble(), updatedAt: now),
    );

    bucket
      ..tokens = _tokensAt(bucket, now)
      ..updatedAt = now;

    if (bucket.tokens >= 1) {
      bucket.tokens -= 1;
      return const RateDecision.allowed();
    }

    final shortfall = 1 - bucket.tokens;
    return RateDecision.denied(refill * shortfall);
  }

  /// Tokens [bucket] holds at [now], capped at [burst].
  double _tokensAt(_Bucket bucket, DateTime now) {
    final elapsed = now.difference(bucket.updatedAt);
    if (elapsed <= Duration.zero) return bucket.tokens;
    final earned = elapsed.inMicroseconds / refill.inMicroseconds;
    final total = bucket.tokens + earned;
    return total > burst ? burst.toDouble() : total;
  }

  /// Forgets callers whose buckets have refilled: an idle caller is
  /// indistinguishable from one that was never seen.
  void _sweep(DateTime now) {
    _buckets.removeWhere((_, bucket) => _tokensAt(bucket, now) >= burst);
  }
}

class _Bucket {
  _Bucket({required this.tokens, required this.updatedAt});

  double tokens;
  DateTime updatedAt;
}

/// The `Retry-After` header value for a refusal.
Map<String, String> retryAfterHeaders(RateDecision decision) => {
      HttpHeaders.retryAfterHeader: '${decision.retryAfterSeconds}',
    };
